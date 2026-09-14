#!/usr/bin/env python3
"""Tally the fixture-masked-green gate's verdict log.

This is the read side of the gate's success measurement. ``classify.py`` appends
one JSONL line per run to ``.claude/metrics/classify_failures.jsonl``; this
script counts the real gate runs (``source == review``) and surfaces every block
so a human can adjudicate it as a TRUE CATCH (a genuine fixture-masked green) or
a FALSE POSITIVE (a legit PR wrongly blocked) — that judgement cannot be
automated, only counted and presented.

Decision rule when you review the tally:
  * caught >=1 real masked-green, false-positive rate <~15%, SKIP rate ~0 -> KEEP
  * zero catches + nonzero false positives or rising SKIP usage          -> CUT

Usage:
    python -m scripts.classify_failures.tally_metrics [--source review] [LOG]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from scripts.classify_failures.split_diff import REPO_ROOT


DEFAULT_LOG = REPO_ROOT / ".claude" / "metrics" / "classify_failures.jsonl"


def summarize(log_path: Path, source: str = "review") -> dict[str, object]:
    """Return verdict counts (filtered to ``source``) and the blocked runs."""
    counts = {"total": 0, "blocked": 0, "clean": 0, "invalid": 0}
    blocked_runs: list[dict[str, object]] = []
    if not log_path.exists():
        return {**counts, "blocked_runs": blocked_runs}
    for line in log_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("source") != source:
            continue
        counts["total"] += 1
        verdict = rec.get("verdict")
        if verdict in counts:
            counts[verdict] += 1
        if verdict == "blocked":
            blocked_runs.append(rec)
    return {**counts, "blocked_runs": blocked_runs}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", nargs="?", default=str(DEFAULT_LOG), help="log path")
    parser.add_argument("--source", default="review", help="source tag to count")
    args = parser.parse_args(argv)

    s = summarize(Path(args.log), source=args.source)
    print(f"=== fixture-masked-green gate tally (source={args.source}) ===")
    print(f"  total runs : {s['total']}")
    print(f"  blocked    : {s['blocked']}")
    print(f"  clean      : {s['clean']}")
    print(f"  invalid    : {s['invalid']}")
    blocked_runs = s["blocked_runs"]
    assert isinstance(blocked_runs, list)
    if blocked_runs:
        print("\n  BLOCKED runs — adjudicate each: TRUE CATCH or FALSE POSITIVE")
        for r in blocked_runs:
            print(
                f"    {r.get('ts')}  {r.get('base')}..{r.get('head')}  "
                f"fixture_masked={r.get('fixture_masked')}"
            )
    else:
        print("\n  (no blocks yet — zero catches so far)")
    print(
        "\n  Also check: SKIP_FIXTURE_CHECK usage in merged PRs over the window "
        "(skips short-circuit before this log, so a rising skip rate = the gate\n"
        "  being routed around). Decision rule in module docstring."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
