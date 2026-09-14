#!/usr/bin/env python3
"""Classify a diff for fixture-masked greens.

A *fixture-masked green* is a test that newly passes only because the diff
edited the test/fixture/baseline — not the production code. It is the exact
failure mode of a prior incident: one change rewrote both the eval cases and a
production parse-retry branch, the suite went green, and the green came from the
eval rewrites — the fix's branch was never exercised.

Detection runs the targeted suite three ways:

  HEAD               working tree as the diff was written
  BASE + test-overlay base production reverted, only the test/fixture edits laid on
  BASE pure          base with nothing from the diff applied

For each test green on HEAD:

  newly_green = not green on BASE pure        (the PR changed its outcome)
  masked      = green on BASE + test-overlay  (the test edit alone suffices)

  net-new (absent on BASE pure) and masked     -> new_tests  (new coverage; OK)
  net-new and not masked                       -> earned     (exercised the fix)
  pre-existing and masked                      -> fixture_masked  (BLOCK)
  pre-existing and not masked (newly green)    -> earned          (fix needed)
  otherwise (already green pre-PR)             -> stable          (ignored)

A test that did not exist at base CANNOT mask pre-existing behavior, so it is
bucketed as new_tests/earned, never fixture_masked. To distinguish "net-new"
from "the whole pure-base run collapsed", the pure-base run is taken over only
targets that EXIST at base (a net-new file would make pytest exit 4 and emit no
report, zeroing every outcome) — see ``base_pure_target`` below.

The third (pure-base) run is what stops every unchanged-but-passing test in a
touched file from being a false positive — the gap the literal two-run sketch
left open (see this gate's own "$100 bet": uncertainty was *false positives*,
and this is the mitigation).

Reds on HEAD are returned for the skill layer to bucket
(real_bug / intentional / flaky) with agent reasoning; this script does not
guess intent.

Usage:
    python -m scripts.classify_failures.classify --base <ref> [--head <ref>]
        -> verdict JSON on stdout; exit 1 if any fixture-masked test is found.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess  # nosec B404 - fixed git args, no shell
import sys
from datetime import UTC, datetime
from pathlib import Path

from scripts.classify_failures.run_isolated import (
    PytestRun,
    isolated_base_run,
    path_exists_at_ref,
    run_pytest,
)
from scripts.classify_failures.split_diff import (
    REPO_ROOT,
    changed_paths,
    split_paths,
)


def _rev_parse(ref: str, repo_root: Path) -> str:
    """Resolve ``ref`` to a commit SHA in ``repo_root``'s context."""
    return subprocess.run(  # nosec B603 B607 - fixed git args, no shell
        ["git", "rev-parse", ref],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def classify(
    base: str,
    head: str,
    repo_root: Path,
    test_paths: list[str] | None = None,
    target: list[str] | None = None,
) -> dict[str, object]:
    """Return a verdict dict for the ``base..head`` diff.

    ``target`` is the pytest invocation (defaults to the changed test files).
    Pass an explicit ``target`` — e.g. an eval ``-k`` filter — when the changed
    test files are parametrized data the suite reads indirectly.
    """
    # Resolve symbolic refs (the CLI default is the literal string "HEAD") to a
    # SHA up front: ``isolated_base_run`` re-evaluates ``head`` INSIDE its
    # detached-at-base throwaway worktree, where a symbolic "HEAD" means BASE —
    # crashing the overlay on net-new test paths and silently turning it into a
    # no-op for co-edited ones (neutralizing mask detection). Found on a prior
    # incident.
    head = _rev_parse(head, repo_root)
    resolved_test_paths: list[str] = (
        split_paths(changed_paths(base, head, repo_root))["test"]
        if test_paths is None
        else test_paths
    )
    resolved_target: list[str] = list(resolved_test_paths) if target is None else target

    def _result(verdict: str, **extra: object) -> dict[str, object]:
        base_fields: dict[str, object] = {
            "verdict": verdict,
            "fixture_masked": [],
            "newly_skipped": [],
            "new_tests": [],
            "earned": [],
            "head_failures": [],
            "base_pure_incomplete": False,
        }
        base_fields.update(extra)
        return base_fields

    # No test/fixture edits -> nothing can be fixture-masked (prod-only diff).
    if not resolved_test_paths or not resolved_target:
        return _result("clean")

    head_run = run_pytest(resolved_target, cwd=repo_root)
    # Only this leg (BASE production + HEAD's test/fixture overlay) tolerates a
    # collection error: a HEAD-only import in an overlaid test file must not
    # void the leg — see run_pytest's docstring. HEAD and BASE-pure below stay
    # strict (default False).
    base_test_run = isolated_base_run(
        base,
        head,
        resolved_test_paths,
        resolved_target,
        repo_root,
        continue_on_collection_errors=True,
    )

    # The pure-base run must use ONLY targets that exist at base. A net-new
    # changed-test file does not exist there; including it makes pytest exit 4
    # and emit NO JUnit report, collapsing the ENTIRE pure-base run to zero
    # outcomes. A co-edited existing test would then read as net-new and its
    # fixture-mask would slip through as "clean". Filtering net-new paths out
    # lets pure-base execute cleanly, so a key absent from it is a GENUINE
    # net-new test, not an artifact of a collapsed run.
    net_new_paths = {
        p for p in resolved_test_paths if not path_exists_at_ref(repo_root, base, p)
    }
    base_pure_target = [t for t in resolved_target if t not in net_new_paths]
    if base_pure_target:
        base_pure_run = isolated_base_run(base, head, [], base_pure_target, repo_root)
    else:
        # Every target is net-new (nothing existed at base) — there is no
        # pure-base suite to run, and every HEAD test is legitimately net-new.
        base_pure_run = PytestRun()

    # HEAD, the test-overlay run, and the pure-base run (when it has any
    # base-existing target) MUST execute cleanly — an empty/errored run would
    # silently pass the gate (the false-green this gate exists to catch).
    required_runs = [(head_run, "HEAD"), (base_test_run, "BASE+test-overlay")]
    if base_pure_target:
        required_runs.append((base_pure_run, "BASE-pure"))
    for run, label in required_runs:
        if not run.ok:
            return _result(
                "invalid",
                reason=(
                    f"{label} run did not execute cleanly (pytest exit "
                    f"{run.returncode}, {len(run.outcomes)} tests parsed) — a "
                    f"green here would be unverified"
                ),
            )

    head_outcomes = head_run.outcomes
    base_test = base_test_run.outcomes
    base_pure = base_pure_run.outcomes

    fixture_masked: list[str] = []
    newly_skipped: list[str] = []
    new_tests: list[str] = []
    earned: list[str] = []
    head_failures: list[str] = []

    for key, outcome in head_outcomes.items():
        if outcome == "skipped":
            # A test that USED to run (passed or failed on pure base) but is now
            # skipped on HEAD is a skip-to-green / lost-coverage move — flag it.
            if base_pure.get(key) in ("passed", "failed"):
                newly_skipped.append(key)
            continue
        if outcome != "passed":
            head_failures.append(key)
            continue
        passes_on_overlay = base_test.get(key) == "passed"
        if base_pure.get(key) is None:
            # Absent from the (clean) pure-base run: the test did not exist under
            # this key at base. That is normally net-new and CANNOT mask
            # pre-existing behavior. The one exception is a RENAME: editing an
            # existing file to rename a previously-RED test (test_old -> test_new)
            # gives the new key no base-pure match, so a fixture-mask could ride
            # in under a fresh name. Detect it structurally: a red test in the
            # SAME module/class disappeared on HEAD. If so and the new test
            # passes with production reverted, it is a masked green, not net-new.
            cls = key.split("::", 1)[0]
            renamed_from_red = any(
                base_pure[bk] in ("failed", "error")
                and bk not in head_outcomes
                and bk.split("::", 1)[0] == cls
                for bk in base_pure
            )
            if renamed_from_red and passes_on_overlay:
                fixture_masked.append(key)
            else:
                (new_tests if passes_on_overlay else earned).append(key)
            continue
        if base_pure.get(key) == "passed":
            continue  # stable — already green before the PR, not the PR's doing
        # Existed and was failing/erroring at base, now passes on HEAD:
        # masked iff it passes with production reverted (the test edit alone).
        (fixture_masked if passes_on_overlay else earned).append(key)

    blocked = bool(fixture_masked) or bool(newly_skipped)
    return _result(
        "blocked" if blocked else "clean",
        fixture_masked=sorted(fixture_masked),
        newly_skipped=sorted(newly_skipped),
        new_tests=sorted(new_tests),
        earned=sorted(earned),
        head_failures=sorted(head_failures),
        base_pure_incomplete=not base_pure_run.ok,
    )


def log_verdict(
    result: dict[str, object],
    *,
    base: str,
    head: str,
    source: str,
    repo_root: Path,
    log_path: Path | None = None,
    now: str | None = None,
) -> Path | None:
    """Append one JSONL verdict record to the metrics log; return its path.

    The log is how the gate is measured (true catches vs false positives vs
    skip-rate, tallied by ``tally_metrics.py``). It lives at
    ``<repo_root>/.claude/metrics/classify_failures.jsonl`` (gitignored) unless
    ``$CLASSIFY_FAILURES_LOG`` or ``log_path`` overrides it.
    ``source`` tags the run (``review`` = real gate, ``replay``/``cli`` filtered
    out by the tally). A metrics write must NEVER break the gate, so any failure
    is swallowed and returns ``None``.
    """
    try:
        path = (
            log_path
            or (Path(env) if (env := os.environ.get("CLASSIFY_FAILURES_LOG")) else None)
            or repo_root / ".claude" / "metrics" / "classify_failures.jsonl"
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        record = {
            "ts": now or datetime.now(UTC).isoformat(),
            "source": source,
            "base": base,
            "head": head,
            "verdict": result.get("verdict"),
            "fixture_masked": result.get("fixture_masked", []),
            "newly_skipped": result.get("newly_skipped", []),
            "new_tests": result.get("new_tests", []),
            "base_pure_incomplete": result.get("base_pure_incomplete", False),
        }
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
        return path
    except OSError:
        return None


def head_ref_mismatch(repo_root: Path, head: str) -> str | None:
    """Return a reason if ``repo_root``'s working tree is not at ``head``.

    The HEAD leg runs pytest in ``repo_root`` (the working tree), while the base
    legs check out ``base``/``head`` in throwaway worktrees. So the verdict only
    describes the diff-as-written when the working tree IS at ``head`` — running
    ``--base main --head feature`` from a ``main`` checkout would test main's code
    under feature's overlaid tests. ``"HEAD"`` is the working tree itself and
    always matches. Returns ``None`` on match (or if git can't resolve a ref,
    leaving the existing run-validity checks to surface the problem).
    """
    if head == "HEAD":
        return None
    try:
        want = subprocess.run(  # nosec B603 B607 - fixed git args, no shell
            ["git", "rev-parse", "--verify", f"{head}^{{commit}}"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        have = subprocess.run(  # nosec B603 B607 - fixed git args, no shell
            ["git", "rev-parse", "--verify", "HEAD^{commit}"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return None
    if want != have:
        return (
            f"working tree (HEAD={have[:8]}) is not at --head {head} ({want[:8]}); "
            f"check out --head or set CLASSIFY_FAILURES_REPO_ROOT to a worktree at "
            f"that ref, else the verdict describes the wrong code"
        )
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="base git ref (e.g. merge-base)")
    parser.add_argument("--head", default="HEAD", help="head git ref (default HEAD)")
    parser.add_argument(
        "--target",
        action="append",
        default=None,
        help="explicit pytest target/arg (repeatable); default = changed test files",
    )
    parser.add_argument(
        "--source",
        default="cli",
        help="metrics-log tag for this run: 'review' (real gate), 'replay', "
        "or 'cli' (default, ad-hoc — filtered out by the tally)",
    )
    args = parser.parse_args(argv)

    mismatch = head_ref_mismatch(REPO_ROOT, args.head)
    if mismatch:
        result: dict[str, object] = {
            "verdict": "invalid",
            "fixture_masked": [],
            "newly_skipped": [],
            "new_tests": [],
            "earned": [],
            "head_failures": [],
            "base_pure_incomplete": False,
            "reason": mismatch,
        }
    else:
        result = classify(
            base=args.base,
            head=args.head,
            repo_root=REPO_ROOT,
            target=args.target,
        )
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    # Record the verdict for the measurement tally (never breaks the gate).
    log_verdict(
        result,
        base=args.base,
        head=args.head,
        source=args.source,
        repo_root=REPO_ROOT,
    )
    # Anything other than a verified-clean verdict blocks (blocked OR invalid).
    return 0 if result["verdict"] == "clean" else 1


if __name__ == "__main__":
    raise SystemExit(main())
