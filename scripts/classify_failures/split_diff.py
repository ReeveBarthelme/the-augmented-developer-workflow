#!/usr/bin/env python3
"""Partition a diff's changed paths into PROD vs TEST.

The fixture-masked-green gate works by re-applying ONLY the test-side changes
of a diff onto the base commit and re-running. To do that it must first decide,
per changed file, whether the file is production code or
test/fixture/baseline material.

Granularity is **file-level by design** (hunk-level splitting is
over-engineering). A path is classified wholly by its location and
name; a single file that genuinely mixes production logic and inline fixtures is
rare and is surfaced for manual review by the runner, never guessed at here.

The TEST globs assume a conventional pytest layout. Adjust
``_TEST_DIR_COMPONENTS`` and the name rules below if your project puts fixtures
or baselines elsewhere:

    */tests/*        any file under a ``tests`` directory (eval cases included)
    */baselines/*    any file under a ``baselines`` directory (eval JSON baselines)
    test_*.py        pytest-discovered test modules
    conftest.py      pytest fixtures/config
    *fixture*        a basename containing "fixture" (case-insensitive)

Usage:
    python -m scripts.classify_failures.split_diff --base <ref> --head <ref>
        -> {"prod": [...], "test": [...]} as JSON on stdout
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess  # nosec B404 - hardcoded trusted git args only
import sys
from pathlib import Path, PurePosixPath


# Path components that mark an entire subtree as test material.
_TEST_DIR_COMPONENTS = frozenset({"tests", "baselines"})

# Resolve repo root from this file by default; tests override via env to point
# at a synthetic tempdir repo (a ``*_REPO_ROOT`` env override idiom).
_ROOT_OVERRIDE = os.environ.get("CLASSIFY_FAILURES_REPO_ROOT", "")
REPO_ROOT = (
    Path(_ROOT_OVERRIDE)
    if _ROOT_OVERRIDE
    else Path(__file__).resolve().parent.parent.parent
)


def classify_path(path: str) -> str:
    """Return ``"TEST"`` or ``"PROD"`` for a single repo-relative path."""
    posix = PurePosixPath(path)
    name = posix.name.lower()

    if any(part in _TEST_DIR_COMPONENTS for part in posix.parts):
        return "TEST"
    if name == "conftest.py":
        return "TEST"
    if name.startswith("test_") and name.endswith(".py"):
        return "TEST"
    # "fixture" in the basename marks fixture DATA files (json/yaml/csv/...), not
    # arbitrary production modules — a prod `fixture_loader.py` must stay PROD or
    # the runner would overlay real production code as if it were a test edit.
    # Python fixtures live under a tests/ dir and are already caught above.
    if "fixture" in name and not name.endswith(".py"):
        return "TEST"
    return "PROD"


def split_paths(paths: list[str]) -> dict[str, list[str]]:
    """Partition ``paths`` into ``{"prod": [...], "test": [...]}``.

    Order within each class is preserved from the input.
    """
    prod: list[str] = []
    test: list[str] = []
    for path in paths:
        (test if classify_path(path) == "TEST" else prod).append(path)
    return {"prod": prod, "test": test}


def changed_paths(base: str, head: str, repo_root: Path = REPO_ROOT) -> list[str]:
    """Repo-relative paths changed between ``base`` and ``head`` (git)."""
    result = subprocess.run(  # nosec B603 B607 - fixed git subcommand, refs validated by git
        ["git", "diff", "--name-only", f"{base}...{head}"],
        capture_output=True,
        text=True,
        check=True,
        cwd=repo_root,
    )
    return [line for line in result.stdout.splitlines() if line.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="base git ref")
    parser.add_argument("--head", default="HEAD", help="head git ref (default HEAD)")
    args = parser.parse_args(argv)

    paths = changed_paths(args.base, args.head)
    json.dump(split_paths(paths), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
