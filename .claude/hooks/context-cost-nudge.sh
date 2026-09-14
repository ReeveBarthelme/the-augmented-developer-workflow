#!/usr/bin/env bash
# context-cost-nudge.sh — UserPromptSubmit hook.
#
# WHY: cache_read is ~57-65% of session spend, and it is charged as
# (turns x resident context). Measured over 8 sessions / 2,875 turns, the SAME
# unit of work costs 6.76x more at turn ~950 than at turn ~50, purely because
# the prompt being re-read is bigger:
#
#     turns   0-99  -> 108,779 tok/turn   (1.00x)
#     turns 200-299 -> 270,514 tok/turn   (2.49x)
#     turns 500-599 -> 440,449 tok/turn   (4.05x)
#     turns 900-999 -> 735,345 tok/turn   (6.76x)
#
# This is NOT a context-window problem — turn 250 sits at ~30% of a 1M window
# with 700K to spare. It is purely a price problem, so the fix is to start a
# fresh session when the OBJECTIVE changes, not to ration the window.
#
# The incident this is sized to (CLAUDE.md Proportionality): session cfc07473
# ran 995 turns. The user said "merge, cleanup and /wrap-up" at turn 796 and
# /wrap-up actually ran at turn 808 — then 187 more turns executed at ~712K
# context (~$200) on an unrelated PR. In a fresh session those same turns cost
# ~$42. One tail, ~$158.
#
# WHAT THIS DOES NOT DO: a hook cannot end or start a session — Claude Code has
# no such capability. This is a detector that warns, never an enforcer.
#
# CONTEXT-COST DISCIPLINE: this hook runs on EVERY user prompt, so below the
# first band it MUST print nothing at all. A hook that narrates on every prompt
# would itself become the resident-context problem it is meant to flag. It
# therefore fires at most ONCE PER BAND PER SESSION (3x maximum, ~50 tokens
# each).
#
# Protocol: stdin is Claude Code's UserPromptSubmit JSON payload. Fail OPEN on
# every failure mode — never block, never print on error, always exit 0.
set -u

LIB="${CLAUDE_PROJECT_DIR:-}/.claude/scripts/delegation-lib.sh"
if [ ! -f "$LIB" ]; then
    LIB="$(dirname "${BASH_SOURCE[0]}")/../scripts/delegation-lib.sh"
fi
[ -f "$LIB" ] || exit 0
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

dlg_hook_stdin   # sets INPUT; exits 0 if jq missing or stdin empty

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$TRANSCRIPT" ] && [ -n "$SID" ] || exit 0
[ -r "$TRANSCRIPT" ] || exit 0

# Resident context = the last assistant turn's cache_read + cache_creation.
# Read only the tail: transcripts reach 5MB+ and this runs on every prompt.
# `tail -n +2` drops the partial first line that a byte-offset tail can cut.
LAST=$(tail -c 1000000 "$TRANSCRIPT" 2>/dev/null \
        | tail -n +2 \
        | grep '"cache_read_input_tokens"' \
        | tail -1) || exit 0
[ -n "$LAST" ] || exit 0

CTX=$(printf '%s' "$LAST" | jq -r '
    (.message.usage // {}) as $u
    | (($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0))
' 2>/dev/null) || exit 0
case "$CTX" in ''|*[!0-9]*) exit 0 ;; esac

# Bands chosen from the measured curve above: ~350K is around turn 300 (2.7x),
# ~500K around turn 550 (4.4x), ~650K around turn 750 (6.0x).
if   [ "$CTX" -ge 650000 ]; then BAND=3
elif [ "$CTX" -ge 500000 ]; then BAND=2
elif [ "$CTX" -ge 350000 ]; then BAND=1
else exit 0                      # SILENT — the overwhelming majority of prompts
fi

STATE_DIR="$(dlg_metrics_dir)/context-nudge"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
# Session ids come from Claude Code as UUIDs; strip anything else defensively
# so a hostile/odd id can never escape the directory.
SAFE_SID=$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SAFE_SID" ] || exit 0
STATE_FILE="$STATE_DIR/${SAFE_SID}.band"

FIRED=0
if [ -r "$STATE_FILE" ]; then
    FIRED=$(cat "$STATE_FILE" 2>/dev/null)
    case "$FIRED" in ''|*[!0-9]*) FIRED=0 ;; esac
fi
[ "$BAND" -gt "$FIRED" ] || exit 0    # already warned at this level

printf '%s' "$BAND" > "$STATE_FILE" 2>/dev/null || true

# 108779 = measured mean resident context for turns 0-99 (the cheap baseline).
# 1.5 = $/M cache-read at Opus rates; the ratio is the durable part, not the $.
MULT=$(awk -v c="$CTX" 'BEGIN{printf "%.1f", c/108779}')
DOLLARS=$(awk -v c="$CTX" 'BEGIN{printf "%.2f", c*1.5/1000000}')
CTXK=$(awk -v c="$CTX" 'BEGIN{printf "%d", c/1000}')

CTX_MSG="Context ~${CTXK}K: each turn now costs ${MULT}x a turn at session start (~\$${DOLLARS}/turn re-read). Window is fine (~$(awk -v c="$CTX" 'BEGIN{printf "%d", (1000000-c)/1000}')K free) — this is price, not capacity. If the objective has changed since this session opened, /wrap-up and continue in a fresh session. Report: .claude/scripts/session-cost-report.sh"

jq -nc --arg ctx "$CTX_MSG" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'

exit 0
