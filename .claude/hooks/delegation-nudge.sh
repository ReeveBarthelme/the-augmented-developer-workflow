#!/usr/bin/env bash
# delegation-nudge.sh — PreToolUse hook for Edit|Write|NotebookEdit.
# Phase C of the delegation scorecard: when the MAIN LOOP (not a subagent)
# is about to edit a SOURCE file, remind it of the tiering policy on the
# 1st and 5th such edit this session (advisory, non-blocking). Separately
# ships an enforcement path that is INERT until an operator drops a flag
# file (<metrics_dir>/tiering-enforce) AND the main loop is Fable-tier
# (claude-fable*/claude-mythos*): then the 3rd main-loop source edit of a
# session onward blocks (exit 2). An Opus main loop stays advisory — the
# Opus->Sonnet cold-cache-write cost makes small delegated edits more
# expensive, not less (see CLAUDE.md 'Model tiering'). Bypass with a live
# <metrics_dir>/tiering-override (1h TTL) or rm the enforce file — this hook
# gates Edit|Write|NotebookEdit only, NOT Bash, so both work mid-session.
# SKIP_TIERING_CHECK=1 is the one escape that does NOT: it must be exported in
# the Claude Code process env at LAUNCH. A MISSING or UNREADABLE transcript
# fails OPEN (no block); a READABLE transcript with no model in the 200-line
# window fails TOWARD policy (blocks), so a long Fable session cannot silently
# slip the gate.
#
# Protocol: stdin is Claude Code's PreToolUse JSON payload. Fail OPEN on
# any failure mode (missing jq, missing lib, malformed/empty stdin, empty
# file path, non-numeric count) — this hook must NEVER block on bad data,
# only on the one deliberate armed+threshold condition below. Subagent
# edits (.agent_id present) are never touched — always exit 0 silently.
#
# Model tiering only makes sense when the main loop is a HIGHER-cost model
# (Fable/Opus) delegating file edits DOWN to a cheaper Sonnet executor. When
# the main loop already IS Sonnet (or Haiku), "delegate to a Sonnet executor"
# is nonsensical overhead, so the nudge/enforcement is skipped entirely for
# those. The PreToolUse payload itself carries no model field and there is
# no env var for it (confirmed against Claude Code docs, 2026-07-21) — the
# only source of truth is the session's own transcript_path, whose assistant
# records carry `.message.model`. If that can't be read, fail OPEN to the
# pre-existing behavior (still nudge) rather than silently going quiet.
set -u

LIB="${CLAUDE_PROJECT_DIR:-}/.claude/scripts/delegation-lib.sh"
if [ ! -f "$LIB" ]; then
    LIB="$(dirname "${BASH_SOURCE[0]}")/../scripts/delegation-lib.sh"
fi
[ -f "$LIB" ] || exit 0
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

dlg_hook_stdin

AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
[ -n "$AGENT_ID" ] && exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || exit 0
[ -n "$FILE_PATH" ] || exit 0

REL_PATH="$(dlg_rel_path "$FILE_PATH")"
dlg_is_source_file "$REL_PATH" || exit 0

# Model-tier check comes AFTER the cheap file-path/source-file gate above
# (not before it) — an exempt-file edit (docs/memory/.claude) should never
# pay for a transcript read just to be told it was exempt anyway.
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
MAIN_MODEL=""
# READABLE distinguishes "no transcript to consult" from "consulted it and found
# no model". They must fail in OPPOSITE directions — see HARD_TIER below.
READABLE=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    READABLE=1
    MAIN_MODEL=$(dlg_last_real_assistant_model "$TRANSCRIPT_PATH")
    dlg_is_execution_tier_model "$MAIN_MODEL" && exit 0
fi

SESS=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
SESS="${SESS:-${CLAUDE_SESSION_ID:-}}"
[ -n "$SESS" ] || exit 0

COUNT=$(dlg_session_mainloop_count "$SESS" 2>/dev/null)
case "$COUNT" in
    ''|*[!0-9]*) exit 0 ;;
esac

METRICS_DIR="$(dlg_metrics_dir)"
ENFORCE_FILE="$METRICS_DIR/tiering-enforce"
OVERRIDE_FILE="$METRICS_DIR/tiering-override"

# HARD enforcement is priced for a FABLE main loop only. Break-even for
# delegating an edit is "subagent output > context / N" (N higher = easier to
# justify), from verified list pricing: subagent pays a 1.25x COLD cache write
# on context the main loop already reads at 0.1x.
#   fable -> sonnet   N=26.7  (50k ctx => ~1.9k output tokens to break even)
#   opus  -> sonnet   N=7.5   (50k ctx => ~6.7k; N=3.1 after Sonnet intro
#                              pricing ends 2026-08-31 => ~16k)
# So on Opus most single edits are CHEAPER done inline, and blocking them
# forces the expensive path. Opus stays advisory; Fable hard-blocks.
# Deliberately keyed on the model, not on removing the enforce file, so the
# flag survives for the next Fable session.
HARD_TIER=0
# Anchor on the vendor-prefixed model id (claude-fable-5, claude-mythos-5) rather than a
# bare substring, so an unrelated id that merely CONTAINS "fable" cannot hard-block.
case "$MAIN_MODEL" in claude-fable*|claude-mythos*) HARD_TIER=1 ;; esac

# READABLE transcript but no model resolved => fail TOWARD policy (block), matching
# dlg_is_execution_tier_model's contract. dlg_last_real_assistant_model only tails 200
# lines, so a long Fable session with >200 trailing tool records resolves "" from a
# perfectly healthy transcript. Treating that as "not Fable" silently disarmed the gate
# on exactly the long, expensive sessions it exists for. Only a MISSING or UNREADABLE
# transcript fails open — there is genuinely nothing to consult in that case.
if [ "$READABLE" -eq 1 ] && [ -z "$MAIN_MODEL" ]; then HARD_TIER=1; fi

if [ "$HARD_TIER" -eq 1 ] && [ -f "$ENFORCE_FILE" ] && [ -z "${SKIP_TIERING_CHECK:-}" ] && [ "$COUNT" -ge 2 ]; then
    OVERRIDE_LIVE=0
    if [ -f "$OVERRIDE_FILE" ]; then
        MTIME=$(stat -f %m "$OVERRIDE_FILE" 2>/dev/null)
        STAT_RC=$?
        case "$MTIME" in ''|*[!0-9]*) MTIME="" ;; esac
        if [ "$STAT_RC" -ne 0 ] || [ -z "$MTIME" ]; then
            MTIME=$(stat -c %Y "$OVERRIDE_FILE" 2>/dev/null)
            case "$MTIME" in ''|*[!0-9]*) MTIME="" ;; esac
        fi
        if [ -z "$MTIME" ]; then
            # stat failed both ways — fail open, never block on bad data.
            OVERRIDE_LIVE=1
        else
            NOW=$(date +%s)
            if [ $((NOW - MTIME)) -lt 3600 ]; then
                OVERRIDE_LIVE=1
            else
                rm -f "$OVERRIDE_FILE" 2>/dev/null
            fi
        fi
    fi

    if [ "$OVERRIDE_LIVE" -eq 0 ]; then
        N=$((COUNT + 1))
        echo "model-tiering: main-loop source edit #${N} this session on a Fable-tier main loop (policy: Fable orchestrates, Sonnet executes) — delegate this edit, or bypass: SKIP_TIERING_CHECK=1, or touch ${OVERRIDE_FILE} (1h), or disarm: rm ${ENFORCE_FILE}" >&2
        exit 2
    fi
fi

if [ "$COUNT" -eq 0 ] || [ "$COUNT" -eq 4 ]; then
    N=$((COUNT + 1))
    # Advisory text must match the tier. On an Opus main loop, CLAUDE.md says
    # investigate/verify DIRECTLY and delegate only bulk work (a subagent pays a
    # cold cache write, so small edits are cheaper inline) — telling it to follow
    # Fable policy would contradict the repo's own guidance.
    # Three-way, not two: HARD_TIER=0 covers BOTH "known Opus-tier" and
    # "model unknown" (empty MAIN_MODEL from a missing/unreadable transcript).
    # Collapsing those into one branch made the nudge assert "On an Opus main
    # loop" for a model it never identified — a false claim about the session.
    if [ "$HARD_TIER" -eq 1 ]; then
        CTX="Model-tiering: main-loop source edit #${N} this session on a Fable-tier main loop. Repo policy: Fable orchestrates + verifies only — delegate source edits to a Sonnet executor unless this is a single-line hotfix. (Advisory; subagent edits exempt. Scorecard: .claude/scripts/delegation-scorecard.sh)"
    elif [ -n "$MAIN_MODEL" ]; then
        CTX="Model-tiering: main-loop source edit #${N} this session on an Opus-tier main loop. Direct edits are expected — delegate only BULK/mechanical work (a subagent pays a cold prompt-cache write, so single edits are usually cheaper inline). (Advisory; subagent edits exempt. Scorecard: .claude/scripts/delegation-scorecard.sh)"
    else
        CTX="Model-tiering: main-loop source edit #${N} this session. The main-loop model could not be read from the transcript, so the tier is UNKNOWN and hard enforcement is inactive. If this is a Fable-tier loop, delegate source edits to a Sonnet executor. (Advisory; subagent edits exempt. Scorecard: .claude/scripts/delegation-scorecard.sh)"
    fi
    jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
fi

exit 0
