import hashlib
import json
import os
import subprocess
import sys
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "sync-workflow.py"


class SyncWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.source = self.base / "source"
        self.target = self.base / "target"
        for repo in (self.source, self.target):
            repo.mkdir()
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.email", "test@example.com")
            self.git(repo, "config", "user.name", "Test")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, cwd, *args):
        return subprocess.check_output(["git", "-C", str(cwd), *args], text=True).strip()

    def source_commit(self, files, version="1.0.0"):
        bundle = self.source / "bundle"
        bundle.mkdir(exist_ok=True)
        for name, content in files.items():
            path = bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        (bundle / "manifest.json").write_text(
            json.dumps({"schema": 1, "version": version, "files": sorted(files)})
        )
        self.git(self.source, "add", "bundle")
        self.git(self.source, "commit", "-qm", "bundle")
        return self.git(self.source, "rev-parse", "HEAD")

    def run_sync(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *map(str, args)],
            text=True,
            capture_output=True,
        )

    def test_imports_exact_commit_and_records_hash_and_mode(self):
        ref = self.source_commit({"AGENTS.md": "old\n", "tools/run.sh": "#!/bin/sh\necho ok\n"})
        os.chmod(self.source / "bundle/tools/run.sh", 0o755)
        self.git(self.source, "add", "bundle/tools/run.sh")
        self.git(self.source, "commit", "-qm", "mode")
        ref = self.git(self.source, "rev-parse", "HEAD")
        (self.source / "bundle/AGENTS.md").write_text("dirty source\n")
        result = self.run_sync("--source", self.source, "--ref", ref, "--target", self.target)
        self.assertEqual(result.returncode, 0, result.stderr)
        copied = self.target / ".workflow/vendor/AGENTS.md"
        self.assertEqual(copied.read_text(), "old\n")
        lock = json.loads((self.target / ".workflow/lock.json").read_text())
        self.assertEqual(lock["schema"], 1)
        self.assertEqual(lock["source_revision"], ref)
        self.assertEqual(lock["bundle_version"], "1.0.0")
        self.assertEqual(
            lock["files"]["AGENTS.md"]["sha256"],
            hashlib.sha256(b"old\n").hexdigest(),
        )
        self.assertTrue(lock["files"]["tools/run.sh"]["executable"])

    def test_rejects_traversal_before_mutating_target(self):
        (self.source / "bundle").mkdir()
        (self.source / "bundle/manifest.json").write_text(
            '{"schema":1,"version":"1","files":["../outside"]}'
        )
        self.git(self.source, "add", "bundle")
        self.git(self.source, "commit", "-qm", "bad")
        ref = self.git(self.source, "rev-parse", "HEAD")
        result = self.run_sync("--source", self.source, "--ref", ref, "--target", self.target)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.target / ".workflow").exists())

    def test_check_detects_modified_and_extra_files(self):
        ref = self.source_commit({"guide.md": "hello\n"})
        self.assertEqual(self.run_sync("--source", self.source, "--ref", ref, "--target", self.target).returncode, 0)
        (self.target / ".workflow/vendor/guide.md").write_text("changed\n")
        result = self.run_sync("--check", "--target", self.target)
        self.assertNotEqual(result.returncode, 0)
        (self.target / ".workflow/vendor/guide.md").write_text("hello\n")
        (self.target / ".workflow/vendor/extra.txt").write_text("x")
        result = self.run_sync("--check", "--target", self.target)
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_non_full_revision(self):
        self.source_commit({"guide.md": "hello\n"})
        result = self.run_sync("--source", self.source, "--ref", "HEAD", "--target", self.target)
        self.assertNotEqual(result.returncode, 0)

    def test_repeat_sync_and_upgrade_remove_only_old_managed_files(self):
        ref = self.source_commit({"old.md": "old\n", "keep.txt": "keep\n"})
        self.assertEqual(self.run_sync("--source", self.source, "--ref", ref, "--target", self.target).returncode, 0)
        self.assertEqual(self.run_sync("--source", self.source, "--ref", ref, "--target", self.target).returncode, 0)
        (self.target / ".workflow/project-settings.json").write_text("unrelated")
        (self.source / "bundle/old.md").unlink()
        (self.source / "bundle/new.md").write_text("new\n")
        (self.source / "bundle/manifest.json").write_text(
            json.dumps({"schema": 1, "version": "1.1.0", "files": ["keep.txt", "new.md"]})
        )
        self.git(self.source, "add", "bundle")
        self.git(self.source, "commit", "-qm", "upgrade")
        new_ref = self.git(self.source, "rev-parse", "HEAD")
        self.assertEqual(self.run_sync("--source", self.source, "--ref", new_ref, "--target", self.target).returncode, 0)
        self.assertFalse((self.target / ".workflow/vendor/old.md").exists())
        self.assertTrue((self.target / ".workflow/project-settings.json").exists())
        self.assertTrue((self.target / ".workflow/vendor/new.md").exists())

    def test_refuses_modified_or_deleted_managed_file(self):
        ref = self.source_commit({"guide.md": "hello\n"})
        self.assertEqual(self.run_sync("--source", self.source, "--ref", ref, "--target", self.target).returncode, 0)
        managed = self.target / ".workflow/vendor/guide.md"
        managed.write_text("edited\n")
        self.assertNotEqual(self.run_sync("--source", self.source, "--ref", ref, "--target", self.target).returncode, 0)
        managed.unlink()
        self.assertNotEqual(self.run_sync("--source", self.source, "--ref", ref, "--target", self.target).returncode, 0)

    def test_check_detects_executable_mode_drift(self):
        ref = self.source_commit({"tools/run.sh": "#!/bin/sh\n"})
        os.chmod(self.source / "bundle/tools/run.sh", 0o755)
        self.git(self.source, "add", "bundle/tools/run.sh")
        self.git(self.source, "commit", "-qm", "mode")
        ref = self.git(self.source, "rev-parse", "HEAD")
        self.assertEqual(self.run_sync("--source", self.source, "--ref", ref, "--target", self.target).returncode, 0)
        os.chmod(self.target / ".workflow/vendor/tools/run.sh", 0o644)
        self.assertNotEqual(self.run_sync("--check", "--target", self.target).returncode, 0)

    def test_refuses_symlink_parent_and_unsafe_manifest_paths(self):
        ref = self.source_commit({"guide.md": "hello\n"})
        self.assertEqual(self.run_sync("--source", self.source, "--ref", ref, "--target", self.target).returncode, 0)
        vendor = self.target / ".workflow/vendor"
        shutil = __import__("shutil")
        shutil.rmtree(vendor)
        vendor.parent.mkdir(exist_ok=True)
        vendor.symlink_to(self.base / "elsewhere", target_is_directory=True)
        self.assertNotEqual(self.run_sync("--source", self.source, "--ref", ref, "--target", self.target).returncode, 0)
        for unsafe in ("../x", "/tmp/x", "C:/x", "a//b", "a/./b", ".git/config"):
            bad = self.base / ("src-" + str(len(unsafe)).replace("/", "_"))
            if bad.exists():
                __import__("shutil").rmtree(bad)
            bad.mkdir()
            self.git(bad, "init", "-q")
            self.git(bad, "config", "user.email", "test@example.com")
            self.git(bad, "config", "user.name", "Test")
            (bad / "bundle").mkdir()
            (bad / "bundle/manifest.json").write_text(json.dumps({"schema": 1, "version": "1", "files": [unsafe]}))
            self.git(bad, "add", "bundle")
            self.git(bad, "commit", "-qm", "bad")
            bad_ref = self.git(bad, "rev-parse", "HEAD")
            self.assertNotEqual(self.run_sync("--source", bad, "--ref", bad_ref, "--target", self.target).returncode, 0)

    def test_rejects_casefold_manifest_collision_and_malformed_manifest(self):
        for manifest in (
            {"schema": 1, "version": "1", "files": ["Foo/a", "foo/b"]},
            [],
        ):
            source = self.base / ("malformed-" + str(len(str(manifest))))
            source.mkdir()
            self.git(source, "init", "-q")
            self.git(source, "config", "user.email", "test@example.com")
            self.git(source, "config", "user.name", "Test")
            (source / "bundle").mkdir()
            (source / "bundle/manifest.json").write_text(json.dumps(manifest))
            self.git(source, "add", "bundle")
            self.git(source, "commit", "-qm", "bad")
            ref = self.git(source, "rev-parse", "HEAD")
            result = self.run_sync("--source", source, "--ref", ref, "--target", self.target)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
