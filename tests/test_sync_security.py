import json
import importlib.util
from unittest.mock import patch
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "scripts/sync-workflow.py"


class TestSyncSecurity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.source = self.new_repo("source")
        self.target = self.new_repo("target")

    def tearDown(self):
        self.tmp.cleanup()

    def new_repo(self, name):
        path = self.base / name
        path.mkdir()
        self.git(path, "init", "-q")
        self.git(path, "config", "user.email", "security@example.test")
        self.git(path, "config", "user.name", "Security Test")
        return path

    def git(self, cwd, *args):
        return subprocess.check_output(["git", "-C", str(cwd), *args], text=True).strip()

    def commit_bundle(self, files, manifest_files=None, manifest_mode=0o644):
        bundle = self.source / "bundle"
        bundle.mkdir(exist_ok=True)
        for name, content in files.items():
            path = bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content.encode())
        names = manifest_files if manifest_files is not None else sorted(files)
        manifest = bundle / "manifest.json"
        manifest.write_text(json.dumps({"schema": 1, "version": "1", "files": names}))
        os.chmod(manifest, manifest_mode)
        self.git(self.source, "add", "bundle")
        self.git(self.source, "commit", "-qm", "bundle")
        return self.git(self.source, "rev-parse", "HEAD")

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(CLI), *map(str, args)], text=True, capture_output=True)

    def install(self, files=None):
        ref = self.commit_bundle(files or {"guide.md": "guide\n", "run.sh": "#!/bin/sh\n"})
        result = self.run_cli("--source", self.source, "--ref", ref, "--target", self.target)
        self.assertEqual(result.returncode, 0, result.stderr)
        return ref

    def test_symlink_leaves_lock_and_dangling_entries_never_escape_vendor(self):
        ref = self.install()
        outside = self.base / "outside"
        outside.write_text("guide\n")
        paths = [self.target / ".workflow/vendor/guide.md",
                 self.target / ".workflow/lock.json",
                 self.target / ".workflow/lock.json.tmp",
                 self.target / ".workflow/.sync-incomplete"]
        for path in paths:
            with self.subTest(path=path):
                original = path.read_bytes() if path.exists() else None
                if path.exists():
                    path.unlink()
                path.symlink_to(outside)
                result = self.run_cli("--source", self.source, "--ref", ref, "--target", self.target)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("symlink", result.stderr)
                self.assertEqual(outside.read_text(), "guide\n")
                self.assertEqual(self.run_cli("--check", "--target", self.target).returncode, 2)
                path.unlink()
                if original is not None:
                    path.write_bytes(original)
                self.assertEqual(self.run_cli("--check", "--target", self.target).returncode, 0)
        dangling = self.target / ".workflow/vendor/dangling"
        dangling.symlink_to(self.base / "does-not-exist")
        result = self.run_cli("--check", "--target", self.target)
        self.assertIn("symlink", result.stderr)

    def test_source_check_fails_when_locked_vendor_file_is_removed(self):
        self.install({"one.txt": "one\n", "two.txt": "two\n"})
        lock_path = self.target / ".workflow/lock.json"
        lock = json.loads(lock_path.read_text())
        del lock["files"]["two.txt"]
        (self.target / ".workflow/vendor/two.txt").unlink()
        lock_path.write_text(json.dumps(lock))
        result = self.run_cli("--check", "--source", self.source, "--target", self.target)
        self.assertNotEqual(result.returncode, 0)

    def test_malformed_lock_and_casefold_parent_collision_are_rejected(self):
        self.install()
        (self.target / ".workflow/lock.json").write_text("[]")
        malformed = self.run_cli("--check", "--target", self.target)
        self.assertEqual(malformed.returncode, 2)
        self.assertIn("lock must be an object", malformed.stderr)
        source = self.new_repo("casefold")
        bundle = source / "bundle"
        bundle.mkdir()
        for name in ("Foo/a", "foo/b"):
            path = bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("x")
        (bundle / "manifest.json").write_text(json.dumps({"schema": 1, "version": "1", "files": ["Foo/a", "foo/b"]}))
        self.git(source, "add", "bundle")
        self.git(source, "commit", "-qm", "collision")
        ref = self.git(source, "rev-parse", "HEAD")
        result = self.run_cli("--source", source, "--ref", ref, "--target", self.target)
        self.assertIn("case-insensitive path collision", result.stderr)

    def test_interrupted_marker_blocks_check_and_manifest_executable_mode_is_locked(self):
        ref = self.commit_bundle({"run.sh": "#!/bin/sh\n"}, manifest_mode=0o755)
        result = self.run_cli("--source", self.source, "--ref", ref, "--target", self.target)
        self.assertEqual(result.returncode, 0, result.stderr)
        lock = json.loads((self.target / ".workflow/lock.json").read_text())
        self.assertTrue(lock["files"]["manifest.json"]["executable"])
        os.chmod(self.target / ".workflow/vendor/run.sh", 0o755)
        marker = self.target / ".workflow/.sync-incomplete"
        marker.write_text("interrupted")
        result = self.run_cli("--check", "--target", self.target)
        self.assertNotEqual(result.returncode, 0)
        marker.unlink()
        result = self.run_cli("--check", "--source", self.source, "--target", self.target)
        self.assertNotEqual(result.returncode, 0)

    def load_sync(self):
        spec = importlib.util.spec_from_file_location("sync_security", ROOT / "bundle/sync.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_interleaved_update_revalidates_removal_list_under_lock(self):
        self.install({"guide.md": "v1"})
        second = self.commit_bundle({"guide.md": "v2", "extra.md": "second"})
        third = self.commit_bundle({"guide.md": "v3"})
        module = self.load_sync()
        original = module.inspect_state
        interleaved = False

        def inspect_with_other_update(target, **kwargs):
            nonlocal interleaved
            state = original(target, **kwargs)
            if not interleaved:
                interleaved = True
                module.sync(self.source, second, self.target)
            return state

        with patch.object(module, "inspect_state", side_effect=inspect_with_other_update):
            module.sync(self.source, third, self.target)
        module.check(self.target, self.source)
        self.assertFalse((self.target / ".workflow/vendor/extra.md").exists())

    def test_publication_failure_leaves_blocking_marker(self):
        self.install({"guide.md": "v1"})
        changed = self.commit_bundle({"guide.md": "v2"})
        module = self.load_sync()
        original = module.os.replace
        writes = 0

        def fail_second_write(source, destination):
            nonlocal writes
            writes += 1
            if writes == 2:
                raise OSError("simulated disk write failure")
            return original(source, destination)

        with patch.object(module.os, "replace", side_effect=fail_second_write):
            with self.assertRaisesRegex(OSError, "simulated"):
                module.sync(self.source, changed, self.target)
        with self.assertRaisesRegex(module.SyncError, "incomplete workflow update"):
            module.check(self.target)


if __name__ == "__main__":
    unittest.main()
