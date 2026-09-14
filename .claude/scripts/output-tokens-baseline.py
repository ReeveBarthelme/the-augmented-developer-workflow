#!/usr/bin/env python3
"""Baseline: output tokens per assistant turn, per session.

Usage:  python3 .claude/scripts/output-tokens-baseline.py [N_SESSIONS] [ISO_CUTOVER_DATE]
Example: python3 .claude/scripts/output-tokens-baseline.py 40 2026-08-20
Run before and after an output-style change to see if it moved OUTPUT cost
(billed 50x cache-read). Observational, not controlled: task mix varies by session.
"""

import glob
import json
import os
import statistics as st
import subprocess
import sys


def session_dir() -> str:
    """Claude Code stores session JSONLs under ~/.claude/projects/<cwd with / and . as ->."""
    env = os.environ.get("CLAUDE_SESSION_DIR")
    if env:
        return env
    # Sessions are keyed to the MAIN working tree, not a linked worktree, so
    # resolve through git-common-dir before slugging. Running this from
    # .worktrees/<x> would otherwise derive a slug with no sessions under it.
    root = os.path.abspath(os.getcwd())
    try:
        # S607: resolving git from PATH is intentional. This is a developer
        # script run by hand, not a privileged runtime path.
        common = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],  # noqa: S607
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if common.endswith("/.git"):
            root = os.path.dirname(common)
    except Exception:
        pass
    slug = root.replace("/", "-").replace(".", "-")
    return os.path.expanduser(f"~/.claude/projects/{slug}")


SDIR = session_dir()
files = sorted(glob.glob(os.path.join(SDIR, "*.jsonl")), key=os.path.getmtime)
if not files:
    sys.exit(
        f"no session JSONLs under {SDIR}\n"
        "Run from the repo root, or set CLAUDE_SESSION_DIR to the project's "
        "~/.claude/projects/<slug> directory."
    )
N = int(sys.argv[1]) if len(sys.argv) > 1 else 30
CUT = sys.argv[2] if len(sys.argv) > 2 else None  # ISO date, e.g. 2026-08-19
rows = []
for f in files[-N:]:
    outs = []
    # Iterate lazily inside the context manager: session logs reach 14 MB and
    # readlines() would hold a whole file in memory to count a few integers.
    with open(f, errors="ignore") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue
            u = (d.get("message") or {}).get("usage")
            if u and u.get("output_tokens"):
                outs.append(u["output_tokens"])
    if len(outs) >= 10:
        import datetime as _dt

        day = (
            _dt.datetime.fromtimestamp(os.path.getmtime(f), tz=_dt.UTC)
            .astimezone()
            .date()
            .isoformat()
        )
        rows.append(
            (
                os.path.basename(f)[:8],
                day,
                len(outs),
                st.median(outs),
                round(st.mean(outs)),
            )
        )

print(f"{'session':<10}{'date':<12}{'turns':>7}{'median':>9}{'mean':>8}")
for r in rows:
    print(f"{r[0]:<10}{r[1]:<12}{r[2]:>7}{r[3]:>9.0f}{r[4]:>8}")


def summarize(label, rs):
    if len(rs) < 3:
        print(f"{label:<10} n={len(rs)}  (too few sessions to compare)")
        return
    meds = [r[3] for r in rs]
    q = st.quantiles(meds, n=4)
    print(
        f"{label:<10} n={len(rs):<3} median-of-medians {st.median(meds):>6.0f}   IQR {q[0]:.0f}-{q[2]:.0f}"
    )


print()
if CUT:
    summarize("BEFORE", [r for r in rows if r[1] < CUT])
    summarize("AFTER", [r for r in rows if r[1] >= CUT])
    print("\nObservational, not controlled: task mix varies by session.")
    print(
        "A clean test is toggling settings.local.json and repeating identical prompts same-day."
    )
else:
    summarize("ALL", rows)
