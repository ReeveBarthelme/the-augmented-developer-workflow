#!/usr/bin/env bash
# session-cost-report.sh — offline cost analysis over Claude Code transcripts.
#
# There is deliberately NO hook behind this. The transcripts under
# ~/.claude/projects/<encoded-cwd>/*.jsonl already contain every usage record,
# so a per-turn logging hook would add runtime cost to re-record data that is
# already on disk (CLAUDE.md Proportionality / YAGNI).
#
# WHY IT EXISTS: to verify — prospectively and with real numbers — the claim
# that shorter sessions are cheaper. Run it before and after adopting a
# session-length habit and compare cost per unit of work (PRs merged, commits
# landed), NOT cost per session, which trivially falls when sessions shrink.
#
# Usage:
#   session-cost-report.sh                 # per-session totals, most recent 10
#   session-cost-report.sh --curve         # cost per turn vs position in session
#   session-cost-report.sh --rebuilds      # full-prefix cache rebuilds, attributed
#   session-cost-report.sh --limit 20      # widen the window
#
# Prices are Opus API list rates and are an ASSUMPTION — on a subscription the
# dollar columns are notional. The token columns and the RATIOS are the durable
# findings; the ratios hold regardless of plan.
set -uo pipefail

MODE="summary"
LIMIT=10
while [ $# -gt 0 ]; do
    case "$1" in
        --curve)    MODE="curve" ;;
        --rebuilds) MODE="rebuilds" ;;
        --limit)    shift; LIMIT="${1:-10}" ;;
        -h|--help)  sed -n '1,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

PROJ_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# Claude Code encodes the cwd by replacing '/' with '-'.
ENCODED=$(printf '%s' "$PROJ_DIR" | sed 's|/|-|g')
TRANSCRIPT_DIR="$HOME/.claude/projects/$ENCODED"

if [ ! -d "$TRANSCRIPT_DIR" ]; then
    echo "no transcript dir: $TRANSCRIPT_DIR" >&2
    exit 1
fi

MODE="$MODE" LIMIT="$LIMIT" TRANSCRIPT_DIR="$TRANSCRIPT_DIR" python3 - <<'PYEOF'
import json, os, glob, sys
from collections import Counter

MODE = os.environ["MODE"]
LIMIT = int(os.environ["LIMIT"])
D = os.environ["TRANSCRIPT_DIR"]

# Opus list rates, $/M tokens. cache_write uses the 1-HOUR TTL rate (2x input).
# Measured: 0 of 2,896 turns ever hit a >60min gap, so the 1h TTL never expires
# on us; the expensive event is prefix INVALIDATION, not elapsed time.
P_OUT, P_CR, P_CW, P_IN = 75.0, 1.50, 30.0, 15.0

files = sorted(glob.glob(os.path.join(D, "*.jsonl")),
               key=os.path.getmtime, reverse=True)[:LIMIT]

def records(path):
    """Yield parsed records, DEDUPED by uuid.

    Assistant messages can appear more than once in a transcript (streaming /
    retry records). Counting them raw double-counts usage — that is exactly
    what inflated an earlier rebuild count from 22 to 44."""
    seen = set()
    for line in open(path, errors="ignore"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        k = d.get("uuid") or (d.get("message") or {}).get("id")
        if k is not None:
            if k in seen:
                continue
            seen.add(k)
        yield d

def usage_turns(path):
    for d in records(path):
        m = d.get("message")
        if not isinstance(m, dict):
            continue
        u = m.get("usage")
        if u:
            yield d, u

def money(out, cr, cw, inp):
    return out*P_OUT/1e6 + cr*P_CR/1e6 + cw*P_CW/1e6 + inp*P_IN/1e6

if MODE == "summary":
    print(f"{'session':14} {'turns':>6} {'output':>10} {'cache_read':>13} {'cache_wr':>11} {'peak_ctx':>10} {'$est':>9}")
    G = Counter()
    for f in files:
        s = Counter(); peak = 0
        for _, u in usage_turns(f):
            s["n"] += 1
            s["out"] += u.get("output_tokens", 0) or 0
            s["cr"]  += u.get("cache_read_input_tokens", 0) or 0
            s["cw"]  += u.get("cache_creation_input_tokens", 0) or 0
            s["in"]  += u.get("input_tokens", 0) or 0
            peak = max(peak, (u.get("cache_read_input_tokens", 0) or 0)
                             + (u.get("cache_creation_input_tokens", 0) or 0))
        if not s["n"]:
            continue
        G.update(s)
        c = money(s["out"], s["cr"], s["cw"], s["in"])
        print(f"{os.path.basename(f)[:12]:14} {s['n']:6d} {s['out']:10,} {s['cr']:13,} {s['cw']:11,} {peak:10,} {c:9,.2f}")
    print("-"*80)
    tc = money(G["out"], G["cr"], G["cw"], G["in"])
    print(f"{'TOTAL':14} {G['n']:6d} {G['out']:10,} {G['cr']:13,} {G['cw']:11,} {'':10} {tc:9,.2f}")
    if G["n"]:
        tot = G["cr"]*P_CR/1e6 + G["cw"]*P_CW/1e6 + G["out"]*P_OUT/1e6
        print(f"\nshare: cache_read {G['cr']*P_CR/1e6/tot:5.1%} | "
              f"cache_write {G['cw']*P_CW/1e6/tot:5.1%} | output {G['out']*P_OUT/1e6/tot:5.1%}")
        print(f"mean $/turn: {tc/G['n']:.3f}")

elif MODE == "curve":
    buckets = {}
    for f in files:
        for i, (_, u) in enumerate(usage_turns(f)):
            ctx = (u.get("cache_read_input_tokens", 0) or 0) + \
                  (u.get("cache_creation_input_tokens", 0) or 0)
            buckets.setdefault(i//100*100, []).append(ctx)
    print("COST OF A TURN vs ITS POSITION IN THE SESSION")
    print(f"{'turns':>12} {'n':>6} {'mean context':>14} {'% of 1M':>9} {'vs turns 0-99':>14} {'$/turn':>8}")
    base = None
    for b in sorted(buckets):
        v = buckets[b]
        m = sum(v)/len(v)
        if base is None:
            base = m
        print(f"{b:>5}-{b+99:<6} {len(v):6d} {m:14,.0f} {m/1e6:8.1%} {m/base:13.2f}x {m*P_CR/1e6:8.3f}")

elif MODE == "rebuilds":
    trig, cost = Counter(), Counter()
    n = 0
    for f in files:
        recs = list(records(f))
        for i, d in enumerate(recs):
            m = d.get("message")
            if not isinstance(m, dict):
                continue
            u = m.get("usage")
            if not u:
                continue
            cw = u.get("cache_creation_input_tokens", 0) or 0
            if cw <= 100_000:
                continue
            n += 1
            label = "other/unclassified"
            for j in range(i-1, max(-1, i-8), -1):
                p = recs[j]
                t = p.get("type", "")
                pm = p.get("message")
                txt = ""
                # A TOOL RESULT is carried on a record whose type is "user" —
                # it is not something the human typed. json.dumps() of its
                # content array starts with "[", which passes the
                # not-startswith("<") test below, so without this flag every
                # tool result was labelled "user typed message" AND broke the
                # scan early, masking the real trigger behind it. Measured on
                # 20 sessions: 6 of 6 such labels were tool results (100% false
                # positive). Reported by a review bot on a prior PR.
                is_tool_result = False
                if isinstance(pm, dict):
                    c = pm.get("content")
                    if isinstance(c, str):
                        txt = c
                    else:
                        txt = json.dumps(c)[:3000]
                        if isinstance(c, list):
                            is_tool_result = any(
                                isinstance(b, dict) and b.get("type") == "tool_result"
                                for b in c
                            )
                if "teammate-message" in txt:      label = "teammate ping"; break
                if "task-notification" in txt:     label = "background task notification"; break
                if t == "user" and "<bash-input>" in txt: label = "user ! bash-input"; break
                if t == "user" and is_tool_result:  label = "large tool result"; break
                if t == "user" and txt.strip() and not txt.strip().startswith("<"):
                    label = "user typed message"; break
                if t == "attachment":              label = "attachment injection"; break
                if t == "file-history-snapshot":   label = "file-history-snapshot"; break
            trig[label] += 1
            cost[label] += cw
    print(f"FULL-PREFIX CACHE REBUILDS (cache_write >100K), deduped by uuid: {n}")
    print(f"{'trigger':34} {'events':>7} {'tokens rewritten':>18} {'$ @2x write':>12}")
    for k, v in trig.most_common():
        print(f"  {k:32} {v:7d} {cost[k]:18,} {cost[k]*P_CW/1e6:11,.2f}")
    tot = sum(cost.values())
    print(f"  {'TOTAL':32} {n:7d} {tot:18,} {tot*P_CW/1e6:11,.2f}")
PYEOF
