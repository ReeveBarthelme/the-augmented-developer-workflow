#!/usr/bin/env bash
# pre-merge-gate.sh — Blocks gh pr merge until make pre-merge passes.
# Claude Code PreToolUse hook on Bash tool.
#
# Protocol: PreToolUse hooks must output JSON with "permissionDecision".
# - "allow" → tool proceeds
# - "block" → tool is prevented from running
# Optional "systemMessage" is shown to Claude as context.

set -uo pipefail

# Read tool input from stdin (Claude Code passes JSON via stdin, NOT env vars)
INPUT=$(cat)

LOG="/tmp/pre-merge-gate.log"

# Extract command — jq check MUST come before any jq usage to prevent fail-open.
# Without jq, raw grep detects "gh pr merge" in the JSON input for blocking;
# non-merge commands are allowed through since they don't need the gate.
if command -v jq &>/dev/null; then
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
else
    COMMAND=""
    # Fail-closed: if raw input contains "gh pr merge", block without jq
    if echo "$INPUT" | grep -qE 'gh\s+pr\s+merge(\s|"|$)'; then
        echo '{"permissionDecision": "block", "systemMessage": "jq not found — install jq to enable pre-merge gate."}'
        exit 0
    fi
    # Non-merge commands: allow through (jq not needed for those)
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Debug log — confirms hook fired and captures context
{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "COMMAND: ${COMMAND:-<empty>}"
  echo "CWD: $(pwd)"
  echo "GIT_TOPLEVEL: $(git rev-parse --show-toplevel 2>/dev/null || echo '<failed>')"
} >> "$LOG" 2>/dev/null || true

# Only intercept "gh pr merge" — word boundary prevents matching "gh pr merge-queue"
if ! echo "$COMMAND" | grep -qE 'gh\s+pr\s+merge(\s|$)'; then
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/Makefile" ]]; then
    echo '{"permissionDecision": "allow", "systemMessage": "No Makefile found — skipping pre-merge gate."}'
    exit 0
fi

# Check that the Makefile has a pre-merge target (dry-run)
if ! (cd "$REPO_ROOT" && make -n pre-merge >/dev/null 2>&1); then
    echo '{"permissionDecision": "allow", "systemMessage": "Makefile found but no pre-merge target. Add a pre-merge target or see Makefile.example."}'
    exit 0
fi

# Run pre-merge checks synchronously — must pass before merge is allowed
# Capture both output and exit code in one invocation
set +e
OUTPUT=$(cd "$REPO_ROOT" && make pre-merge 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    MSG="Pre-merge checks PASSED. Proceeding with merge."
    echo "{\"permissionDecision\": \"allow\", \"systemMessage\": $(printf '%s' "$MSG" | jq -Rs .)}"
else
    TAIL=$(printf '%s' "$OUTPUT" | tail -50)
    MSG="Pre-merge checks FAILED (exit $EXIT_CODE). Fix these issues before merging."
    FULL_MSG=$(printf '%s\n\n%s' "$MSG" "$TAIL")
    echo "{\"permissionDecision\": \"block\", \"systemMessage\": $(printf '%s' "$FULL_MSG" | jq -Rs .)}"
fi
