#!/usr/bin/env bash
# delegation-track.sh — PostToolUse hook for Edit|Write|NotebookEdit.
# Phase A of the delegation scorecard: silent measurement only. Logs one
# JSONL event per file-touching tool call (main-loop vs subagent, source
# vs exempt file, line-count delta for Edit) to the MAIN repo's
# .claude/metrics/delegation-YYYY-MM.jsonl, regardless of which worktree
# the session is running in. NEVER logs edit content itself.
#
# Protocol: stdin is Claude Code's PostToolUse JSON payload. Fail OPEN on
# any failure mode (missing jq, missing lib, malformed/empty stdin, empty
# file path) — this hook must NEVER block, NEVER print to stdout/stderr,
# and ALWAYS exit 0. A broken metrics hook must not break editing.
set -u

# Resolve delegation-lib.sh: prefer $CLAUDE_PROJECT_DIR, else a path
# relative to this script's own location (works even if
# CLAUDE_PROJECT_DIR is unset or points somewhere unexpected).
LIB="${CLAUDE_PROJECT_DIR:-}/.claude/scripts/delegation-lib.sh"
if [ ! -f "$LIB" ]; then
    LIB="$(dirname "${BASH_SOURCE[0]}")/../scripts/delegation-lib.sh"
fi
[ -f "$LIB" ] || exit 0
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

dlg_hook_stdin

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
SESSION_ID="${SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
[ -n "$SESSION_ID" ] || exit 0
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || exit 0
[ -n "$FILE_PATH" ] || exit 0

AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)

ORIGIN="main"
[ -n "$AGENT_ID" ] && ORIGIN="subagent"

# Line counts (newline-split, NOT the content itself) — Edit tool only.
LINES_OLD="null"
LINES_NEW="null"
if [ "$TOOL_NAME" = "Edit" ]; then
    LO=$(printf '%s' "$INPUT" | jq -c '(.tool_input.old_string // null) as $s | if $s == null then null else ($s | split("\n") | length) end' 2>/dev/null)
    LN=$(printf '%s' "$INPUT" | jq -c '(.tool_input.new_string // null) as $s | if $s == null then null else ($s | split("\n") | length) end' 2>/dev/null)
    [ -n "$LO" ] && LINES_OLD="$LO"
    [ -n "$LN" ] && LINES_NEW="$LN"
fi

REL_PATH="$(dlg_rel_path "$FILE_PATH")"
if dlg_is_source_file "$REL_PATH"; then SOURCE_JSON="true"; else SOURCE_JSON="false"; fi
WORKTREE="$(dlg_worktree_name)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

LINE=$(jq -nc \
    --arg ts "$TS" \
    --arg session_id "$SESSION_ID" \
    --arg origin "$ORIGIN" \
    --arg agent_id "$AGENT_ID" \
    --arg agent_type "$AGENT_TYPE" \
    --arg tool "$TOOL_NAME" \
    --arg file "$REL_PATH" \
    --argjson source "$SOURCE_JSON" \
    --argjson lines_old "$LINES_OLD" \
    --argjson lines_new "$LINES_NEW" \
    --arg worktree "$WORKTREE" \
    '{
        ts: $ts,
        session_id: $session_id,
        origin: $origin,
        agent_id: (if $agent_id == "" then null else $agent_id end),
        agent_type: (if $agent_type == "" then null else $agent_type end),
        tool: $tool,
        file: $file,
        source: $source,
        lines_old: $lines_old,
        lines_new: $lines_new,
        worktree: $worktree
    }' 2>/dev/null) || exit 0

dlg_append_event "$(dlg_month_file)" "$LINE"
exit 0
