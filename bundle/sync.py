#!/usr/bin/env python3
"""Distribute a committed workflow bundle without network or global configuration."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class SyncError(Exception):
    """Invalid source or unsafe consumer state."""


def git(repo, *args):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=False)
    if result.returncode:
        raise SyncError(result.stderr.decode(errors="replace").strip() or "git command failed")
    return result.stdout


def repo_root(path):
    path = Path(path).resolve()
    found = Path(git(path, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if found != path:
        raise SyncError(f"expected Git repository root: {path}")
    return found


def safe_rel(value):
    if not isinstance(value, str) or not value or re.search(r'[\\:\x00-\x1f]', value):
        raise SyncError(f"invalid bundle path: {value!r}")
    parts = value.split("/")
    if any(part in ("", ".", "..") or part.casefold() == ".git" for part in parts):
        raise SyncError(f"invalid bundle path: {value!r}")
    return Path(value)


def checked_paths(values):
    paths = [safe_rel(value) for value in values]
    spellings = {}
    files = set()
    for path in paths:
        for index in range(1, len(path.parts) + 1):
            part = Path(*path.parts[:index]).as_posix()
            key = part.casefold()
            if key in spellings and spellings[key] != part:
                raise SyncError("case-insensitive path collision")
            spellings[key] = part
        if path in files:
            raise SyncError("duplicate bundle path")
        files.add(path)
    if any(parent in files for path in paths for parent in path.parents):
        raise SyncError("bundle file is also a parent directory")
    return paths


def read_json(raw, description):
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as exc:
        raise SyncError(f"invalid {description}") from exc
    if not isinstance(value, dict):
        raise SyncError(f"{description} must be an object")
    return value


def parse_manifest(raw):
    manifest = read_json(raw, "manifest")
    if type(manifest.get("schema")) is not int or manifest["schema"] != 1:
        raise SyncError("unsupported manifest schema")
    if not isinstance(manifest.get("version"), str) or not manifest["version"]:
        raise SyncError("manifest version must be nonempty")
    if not isinstance(manifest.get("files"), list):
        raise SyncError("manifest files must be a list")
    paths = checked_paths(["manifest.json", *manifest["files"]])
    return manifest, paths


def committed_file(source, ref, path):
    name = f"bundle/{path.as_posix()}"
    # -z keeps spaces and other Git-quoted filenames unambiguous.
    tree = git(source, "ls-tree", "-z", ref, "--", name)
    records = tree.rstrip(b"\0").split(b"\0")
    if len(records) != 1 or b"\t" not in records[0]:
        raise SyncError(f"missing committed bundle file: {path}")
    metadata, actual = records[0].split(b"\t", 1)
    mode, kind, _object = metadata.split()
    if actual.decode() != name or kind != b"blob" or mode not in (b"100644", b"100755"):
        raise SyncError(f"bundle path must be a regular file: {path}")
    return git(source, "show", f"{ref}:{name}"), mode == b"100755"


def source_payload(source, ref):
    if not isinstance(ref, str) or not HEX40.fullmatch(ref):
        raise SyncError("revision must be a full lowercase 40 character commit ID")
    git(source, "cat-file", "-e", f"{ref}^{{commit}}")
    raw, executable = committed_file(source, ref, Path("manifest.json"))
    manifest, paths = parse_manifest(raw)
    payload = {Path("manifest.json"): (raw, executable)}
    for path in paths[1:]:
        payload[path] = committed_file(source, ref, path)
    return manifest, payload


def sha(data):
    return hashlib.sha256(data).hexdigest()


def lock_data(ref, manifest, payload):
    return {"schema": 1, "source_revision": ref, "bundle_version": manifest["version"],
            "files": {path.as_posix(): {"sha256": sha(data), "executable": executable}
                      for path, (data, executable) in sorted(payload.items())}}


def require_plain(path, directory=False):
    if path.is_symlink():
        raise SyncError(f"refusing symlink: {path}")
    if path.exists() and not (path.is_dir() if directory else path.is_file()):
        raise SyncError(f"unexpected file type: {path}")


def inspect_state(target, *, owns_marker=False):
    workflow = target / ".workflow"
    vendor = workflow / "vendor"
    require_plain(workflow, directory=True)
    require_plain(vendor, directory=True)
    for name in ("lock.json", ".sync-incomplete", "lock.json.tmp"):
        require_plain(workflow / name)
    if ((workflow / ".sync-incomplete").exists() and not owns_marker) or (workflow / "lock.json.tmp").exists():
        raise SyncError("incomplete workflow update; preserve edits and restore the committed bundle before retrying")
    entries = set()
    if vendor.exists():
        for path in vendor.rglob("*"):
            require_plain(path, directory=path.is_dir())
            if path.is_file():
                entries.add(path.relative_to(vendor))
    lock_path = workflow / "lock.json"
    if not lock_path.exists():
        if entries:
            raise SyncError("unowned vendor files without lock")
        return None
    lock = read_json(lock_path.read_bytes(), "lock")
    if type(lock.get("schema")) is not int or lock["schema"] != 1:
        raise SyncError("unsupported lock schema")
    if not isinstance(lock.get("source_revision"), str) or not HEX40.fullmatch(lock["source_revision"]):
        raise SyncError("invalid locked revision")
    if not isinstance(lock.get("bundle_version"), str) or not isinstance(lock.get("files"), dict):
        raise SyncError("invalid lock structure")
    expected = set(checked_paths(list(lock["files"])))
    if Path("manifest.json") not in expected or entries != expected:
        raise SyncError("vendor files do not match lock")
    for path in expected:
        meta = lock["files"][path.as_posix()]
        if (not isinstance(meta, dict) or not isinstance(meta.get("sha256"), str)
                or not HEX64.fullmatch(meta["sha256"]) or type(meta.get("executable")) is not bool):
            raise SyncError("invalid file metadata in lock")
        item = vendor / path
        if sha(item.read_bytes()) != meta["sha256"] or bool(item.stat().st_mode & 0o111) != meta["executable"]:
            raise SyncError(f"modified managed file: {path}")
    manifest, paths = parse_manifest((vendor / "manifest.json").read_bytes())
    if set(paths) != expected or manifest["version"] != lock["bundle_version"]:
        raise SyncError("vendor manifest does not match lock")
    return lock


def validate_destinations(vendor, payload):
    # Structural transitions require explicit maintenance, not directory deletion.
    for path in payload:
        require_plain(vendor / path)
        for parent in path.parents:
            require_plain(vendor / parent, directory=True)


def sync(source, ref, target):
    source, target = repo_root(source), repo_root(target)
    manifest, payload = source_payload(source, ref)
    old = inspect_state(target)
    workflow, vendor = target / ".workflow", target / ".workflow/vendor"
    validate_destinations(vendor, payload)
    workflow.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sync-", dir=workflow) as stage_name:
        stage = Path(stage_name)
        for path, (data, executable) in payload.items():
            dest = stage / "vendor" / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            dest.chmod(0o755 if executable else 0o644)
        (stage / "lock.json").write_text(json.dumps(lock_data(ref, manifest, payload), indent=2, sort_keys=True) + "\n")
        marker = workflow / ".sync-incomplete"
        # Exclusive creation serializes updates. Any failed/interrupted publication leaves a visible blocker.
        with marker.open("x") as handle:
            handle.write("Restore the committed lock/vendor and remove this marker only after inspecting the failed update.\n")
        try:
            # Another updater may have completed while this source was staged.
            old = inspect_state(target, owns_marker=True)
            validate_destinations(vendor, payload)
        except (SyncError, OSError):
            marker.unlink()
            raise
        vendor.mkdir(exist_ok=True)
        for name in old["files"] if old else []:
            if Path(name) not in payload:
                (vendor / name).unlink()
        for path in payload:
            dest = vendor / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            os.replace(stage / "vendor" / path, dest)
        os.replace(stage / "lock.json", workflow / "lock.json")
        marker.unlink()


def check(target, source=None):
    target = repo_root(target)
    lock = inspect_state(target)
    if lock is None:
        raise SyncError("missing .workflow/lock.json")
    if source:
        manifest, payload = source_payload(repo_root(source), lock["source_revision"])
        if lock != lock_data(lock["source_revision"], manifest, payload):
            raise SyncError("source verification failed: lock differs from committed source")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--ref")
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        if args.check:
            if args.ref:
                parser.error("--check uses the locked revision; omit --ref")
            check(args.target, args.source)
        else:
            if args.source is None or args.ref is None:
                parser.error("sync requires --source and --ref")
            sync(args.source, args.ref, args.target)
        print("workflow bundle verified" if args.check else "workflow bundle synced")
    except (SyncError, OSError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
