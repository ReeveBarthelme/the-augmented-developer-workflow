#!/usr/bin/env bash
# agent-spawn-capture.sh — PreToolUse hook for Agent|Task (matcher name is
# a best guess at the real tool name; a wrong guess is harmless since this
# hook is output-free either way).
#
# Phase A of the delegation scorecard: captures the raw tool_input shape
# for every subagent spawn so a later task can analyze what fields real
# spawns actually carry, before building the scorecard/report on top of
# it. Any `prompt` field is truncated to its first 300 characters — this
# needs field names and shape, not full prompt text, and it keeps lines
# bounded.
#
# Protocol: stdin is Claude Code's PreToolUse JSON payload. Fail OPEN on
# any failure mode — this hook must NEVER block, NEVER print to
# stdout/stderr, and ALWAYS exit 0.
set -u

LIB="${CLAUDE_PROJECT_DIR:-}/.claude/scripts/delegation-lib.sh"
if [ ! -f "$LIB" ]; then
    LIB="$(dirname "${BASH_SOURCE[0]}")/../scripts/delegation-lib.sh"
fi
[ -f "$LIB" ] || exit 0
# shellcheck disable=SC1090
source "$LIB" 2>/dev/null || exit 0

dlg_hook_stdin

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

LINE=$(printf '%s' "$INPUT" | jq -c --arg ts "$TS" '
    {
        ts: $ts,
        session_id: (.session_id // null),
        tool_name: (.tool_name // null),
        tool_input: (
            (.tool_input // {}) as $ti
            | if ($ti.prompt? != null)
              then ($ti | .prompt = ($ti.prompt[0:300]))
              else $ti
              end
        )
    }' 2>/dev/null) || exit 0
[ -n "$LINE" ] || exit 0

dlg_append_event "$(dlg_metrics_dir)/agent-spawn-capture.jsonl" "$LINE"
exit 0
