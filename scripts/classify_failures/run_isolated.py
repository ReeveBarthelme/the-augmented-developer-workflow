#!/usr/bin/env python3
"""Run a targeted test suite with the diff's PRODUCTION changes reverted.

The fixture-masked-green check needs two signals for the same suite:

  * the outcomes on HEAD (the diff as written), and
  * the outcomes on BASE-with-only-the-test-changes-applied.

This module produces the second. It checks out a throwaway ``git worktree`` at
the base commit (so production code is the OLD version), overlays HEAD's
*test/fixture* files on top of it (``git checkout <head> -- <test_paths>``), and
runs the targeted suite there. Any test that is green in BOTH signals never
needed the production change — it is fixture-masked.

File-level overlay via ``git checkout -- <paths>`` is deliberate: it is the
30-line primitive, not a bespoke patch engine. Uses a plain subprocess+capture
idiom and a ``*_REPO_ROOT`` env override for tests.
"""

from __future__ import annotations

import subprocess  # nosec B404 - hardcoded trusted git/pytest args only
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class PytestRun:
    """Outcome of one pytest invocation, plus whether it ran validly.

    ``ok`` is False when pytest could not actually execute the targeted tests —
    a collection/import error, a usage error, or zero tests collected. The
    classifier MUST treat a not-ok run as invalid rather than "clean": an empty
    outcome set would otherwise silently pass the gate (the exact false-green
    this gate exists to prevent).
    """

    outcomes: dict[str, str] = field(default_factory=dict)
    returncode: int = 0

    @property
    def ok(self) -> bool:
        # pytest exit codes: 0=all passed, 1=some failed (both valid runs);
        # 2=interrupted, 3=internal error, 4=usage error, 5=no tests collected.
        return self.returncode in (0, 1) and bool(self.outcomes)


def _git(repo_root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # nosec B603 B607 - fixed git subcommands, no shell
        ["git", *args],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=True,
    )


def path_exists_at_ref(repo_root: Path, ref: str, path: str) -> bool:
    """True if ``path`` is a tracked file in the git tree at ``ref``.

    Used to tell a genuinely *net-new* changed-test file (absent at base) apart
    from one that existed at base. A net-new path must be kept out of the
    pure-base pytest target: a missing path makes pytest exit 4 and emit NO
    JUnit report, collapsing the whole run to zero outcomes — which would make a
    co-edited existing test look net-new and slip its fixture-mask through.
    """
    proc = subprocess.run(  # nosec B603 B607 - fixed git args, no shell
        ["git", "cat-file", "-e", f"{ref}:{path}"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode == 0


def run_pytest(
    target: list[str],
    cwd: Path,
    *,
    continue_on_collection_errors: bool = False,
) -> PytestRun:
    """Run pytest on ``target`` in ``cwd``; return a ``PytestRun``.

    Outcomes are parsed from a JUnit XML report (a built-in pytest feature) so
    the result is structured and run-location independent — the key is
    ``"<classname>::<name>"`` which is stable across the HEAD and base runs as
    long as the same relative target is used. The pytest return code is captured
    so the caller can distinguish a real pass/fail run from a run that never
    executed (collection error, no tests collected).

    ``continue_on_collection_errors`` must stay scoped to the BASE+test-overlay
    leg (the only caller that opts in): a HEAD-only import legitimately fails
    collection there, and an errored module's tests must read as not-green on
    base, i.e. earned, rather than voiding the whole leg. The HEAD leg and the
    base-pure leg stay strict by leaving this False — a collection error on
    either means the run itself is broken and must be invalid, not clean.
    """
    with tempfile.NamedTemporaryFile(suffix=".xml", delete=False) as tmp:
        junit_path = Path(tmp.name)
    try:
        args = [
            sys.executable,
            "-m",
            "pytest",
            *target,
            f"--junitxml={junit_path}",
            "-o",
            "junit_family=xunit2",
            "-p",
            "no:cacheprovider",
            "-q",
        ]
        if continue_on_collection_errors:
            args.append("--continue-on-collection-errors")
        proc = subprocess.run(  # nosec B603 - fixed args, no shell
            args,
            cwd=cwd,
            capture_output=True,
            text=True,
            check=False,
        )
        return PytestRun(outcomes=_parse_junit(junit_path), returncode=proc.returncode)
    finally:
        junit_path.unlink(missing_ok=True)


def _parse_junit(junit_path: Path) -> dict[str, str]:
    if not junit_path.exists() or junit_path.stat().st_size == 0:
        return {}
    outcomes: dict[str, str] = {}
    root = ET.parse(junit_path).getroot()  # nosec B314 - pytest-generated local file
    for case in root.iter("testcase"):
        classname = case.get("classname", "")
        name = case.get("name", "")
        key = f"{classname}::{name}" if classname else name
        if case.find("failure") is not None:
            outcomes[key] = "failed"
        elif case.find("error") is not None:
            outcomes[key] = "error"
        elif case.find("skipped") is not None:
            outcomes[key] = "skipped"
        else:
            outcomes[key] = "passed"
    return outcomes


def isolated_base_run(
    base: str,
    head: str,
    test_paths: list[str],
    target: list[str],
    repo_root: Path,
    *,
    continue_on_collection_errors: bool = False,
) -> PytestRun:
    """Run ``target`` at ``base`` with HEAD's ``test_paths`` overlaid.

    Creates a detached throwaway worktree at ``base``, applies the head version
    of the test files, runs the suite, and always removes the worktree.
    ``continue_on_collection_errors`` is forwarded to ``run_pytest`` as-is —
    see its docstring for why only the BASE+test-overlay caller should pass
    True.
    """
    parent = Path(tempfile.mkdtemp(prefix="classify_failures_"))
    worktree = parent / "wt"
    try:
        _git(repo_root, "worktree", "add", "--detach", str(worktree), base)
        if test_paths:
            # Overlay HEAD's test/fixture files onto the BASE production tree.
            _git(worktree, "checkout", head, "--", *test_paths)
        return run_pytest(
            target,
            cwd=worktree,
            continue_on_collection_errors=continue_on_collection_errors,
        )
    finally:
        # Remove the worktree registration, then the tempdir. --force is needed
        # because the overlay left the worktree dirty.
        subprocess.run(  # nosec B603 B607 - fixed git args, cleanup must not raise
            ["git", "worktree", "remove", "--force", str(worktree)],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=False,
        )
        subprocess.run(  # nosec B603 B607 - rm the tempdir parent
            ["rm", "-rf", str(parent)],
            capture_output=True,
            text=True,
            check=False,
        )
