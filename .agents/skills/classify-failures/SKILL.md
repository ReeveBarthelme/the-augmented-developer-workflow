---
name: classify-failures
description: Detect fixture-masked greens — a test that newly passes only because the diff edited the test/fixture/baseline, not the production code. Use in pre-merge review before trusting a green suite.
allowed-tools:
  - Bash
  - Read
  - Grep
---

# Classify Failures — Fixture-Masked-Green Gate

## What this catches

One change rewrites both a production branch *and* the tests that cover it. The
suite goes green. The green comes from the test rewrite, and the fix's own branch
was never exercised. The prose rule is:

> A fix bundled with a test-fixture change must NOT merge unless the fix's OWN
> branch is exercised. Ask: which change made this green?

This skill **mechanizes** that rule. It answers, per test: *did the production
change cause the green, or did the test/fixture edit alone?*

## Requirements

The classifier is **pytest-specific**. It parses pytest's JUnit XML report and
keys off pytest exit codes (0 pass, 1 some failed, 4 usage error, 5 nothing
collected). A project on another runner must replace `run_isolated.run_pytest`
with an equivalent that returns the same `PytestRun` shape: a
`{test_key: "passed"|"failed"|"error"|"skipped"}` map plus a return code, where
`ok` is False whenever the run did not actually execute the targets.

It also needs `git worktree` (it checks out throwaway worktrees at the base
commit) and a repo whose test files are identifiable by path. `split_diff.py`
classifies a path as TEST when it sits under a `tests/` or `baselines/`
directory, is named `conftest.py` or `test_*.py`, or has "fixture" in a
non-`.py` basename. Edit `_TEST_DIR_COMPONENTS` and those rules if your layout
differs. Err on the strict side. A production file misread as TEST gets overlaid
onto the base tree, and the gate then detects nothing at all.

## How it works (three runs, one question)

For the `merge-base(main, HEAD)..HEAD` diff, the suite is run three ways:

| Run | Production code | Test/fixture edits |
|-----|-----------------|--------------------|
| **HEAD** | new | new |
| **BASE + test-overlay** | old (reverted) | new (overlaid) |
| **BASE pure** | old | old |

Per test green on HEAD:

- `newly_green` = NOT green on BASE-pure (the PR changed its outcome)
- `masked` = green on BASE+test-overlay (the test edit alone is enough)
- **`pre-existing AND masked` → `fixture_masked` → BLOCK**
- `pre-existing AND NOT masked` → `earned` (the production change was needed)
- `net-new` (the test's file is absent at base) → `new_tests`/`earned` — a test
  that did not exist at base CANNOT mask pre-existing behavior, so it never blocks
- ran before but now skipped → `newly_skipped` → BLOCK (skip-to-green / lost coverage)
- otherwise → stable (already green before the PR; ignored — this third run is
  the false-positive guard the naive two-run check lacks)

Net-new is decided structurally (the changed test file is absent at base), NOT
from a key being missing in the pure-base run: a net-new file would otherwise
collapse the whole pure-base run (pytest exit 4 → no report) and make a
co-edited existing test look net-new. `base_pure_incomplete: true` flags the
all-net-new case (no base suite existed to run).

## Procedure

1. **Escape hatch first.** If `SKIP_FIXTURE_CHECK` is set (`1`/`true`/`yes`,
   case-insensitive — the same convention the `.githooks/pre-commit` guards use),
   print a one-line skip notice with the stated reason and exit clean. Never
   silently skip.

2. **Run the classifier** from the repo root, on a checkout that is actually at
   `--head`:

   ```bash
   BASE=$(git merge-base main HEAD)
   python -m scripts.classify_failures.classify --base "$BASE" --source review
   ```

   `--source review` tags this as a real gate run in the metrics log
   (`.claude/metrics/classify_failures.jsonl`, gitignored) so
   `python -m scripts.classify_failures.tally_metrics` counts it. Ad-hoc runs
   default to `cli` and are excluded from the tally.

   For a suite whose changed test files are *parametrized data read indirectly*
   (case tables a single test module consumes), pass an explicit target so the
   right suite actually runs:

   ```bash
   python -m scripts.classify_failures.classify --base "$BASE" --source review \
     --target path/to/test_suite.py --target -k --target "CASE-1 or CASE-2"
   ```

   **Adopter obligation.** If your suite needs environment (a live database, API
   credentials, a service on a port), export it before invoking the classifier.
   `<your test/eval runner>` must also be reachable from a *throwaway git
   worktree*, since two of the three runs happen there rather than in the primary
   checkout. The runner must exit non-zero on failure and emit a per-test JUnit
   XML report. A runner that prints a summary but always exits 0 makes this gate
   report clean on every input.

3. **Read the verdict JSON** (`classify.py` exits 1 when blocked):

   ```json
   { "verdict": "blocked|clean|invalid",
     "fixture_masked": [...], "newly_skipped": [...], "new_tests": [...],
     "earned": [...], "head_failures": [...], "base_pure_incomplete": false }
   ```

4. **Bucket the reds.** For each key in `head_failures`, reason about intent —
   the script reports reds but does NOT guess. Read the failing test and the
   diff, then classify each as:
   - `real_bug` — production behavior is wrong; the diff regressed something.
   - `intentional` — the test asserts old behavior the diff deliberately changed
     (the test should be updated *in this PR*, with the change justified).
   - `flaky` — non-deterministic (timing, ordering, network); re-run to confirm
     before trusting either outcome.

5. **The $100 gate.** Before returning a verdict, ask: *would I bet $100 that
   every test in `fixture_masked` truly never exercised the production change?*
   If a flagged test sits in a file that mixes production logic and inline
   fixtures (the file-level splitter cannot separate those — it surfaces them
   for manual review, it does not guess), say so and recommend a human look
   rather than asserting masked.

## Output

Report:
- **BLOCKED** if `fixture_masked` is non-empty — list each masked test and the
  one-line reason (green on HEAD, still green with production reverted, was not
  green before the PR). Recommend: exercise the fix's own branch with a test
  that is RED before the fix, or split the PR.
- **CLEAN** otherwise — note the `earned` count as positive evidence the fix was
  exercised, and surface any `head_failures` buckets that need attention.

Never assert "clean" without having actually run the classifier and read its
output. Paste the verdict JSON.
