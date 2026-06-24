#!/usr/bin/env bash
# pre-merge-gate.sh — Blocks gh pr merge until `make pre-merge` passes.
# Claude Code PreToolUse hook on the Bash tool.
#
# Protocol: PreToolUse hooks output JSON with "permissionDecision".
# - "allow" → tool proceeds
# - "block" → tool is prevented from running
# Optional "systemMessage" is shown to Claude as context.

set -uo pipefail

# Read tool input from stdin (Claude Code passes JSON via stdin, NOT env vars)
INPUT=$(cat)

# Fast path: only intercept "gh pr merge" — exit immediately for everything else.
# Cheap raw-grep gate avoids running git/jq (which can hang under iCloud sync)
# on the vast majority of Bash calls that are not a merge.
if ! printf '%s\n' "$INPUT" | grep -qE 'gh\s+pr\s+merge(\s|"|$)'; then
    echo '{"permissionDecision":"allow"}'
    exit 0
fi

# This IS (probably) a merge command. Extract it accurately with jq.
# Fail-closed: without jq we cannot reliably parse the command, so block.
if command -v jq &>/dev/null; then
    COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
else
    echo '{"permissionDecision": "block", "systemMessage": "jq not found — install jq to enable the pre-merge gate."}'
    exit 0
fi

# Fail CLOSED: the raw fast-path already matched a merge pattern, so this is
# very likely a merge. If jq could not extract a command (empty — malformed or
# unexpectedly-shaped JSON), block rather than wave it through ungated.
if [[ -z "$COMMAND" ]]; then
    echo '{"permissionDecision": "block", "systemMessage": "Detected a likely \"gh pr merge\" but could not parse the command to run the pre-merge gate. Blocking to fail closed — re-run, or run `make pre-merge` manually and merge once it passes."}'
    exit 0
fi

# Repo-scoped log avoids symlink attacks on predictable /tmp paths (CWE-377).
# Falls back to /dev/null outside a git repo.
_GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || true)"
LOG="${_GIT_DIR:+${_GIT_DIR}/pre-merge-gate.log}"
LOG="${LOG:-/dev/null}"

# Debug log — confirms the hook fired and captures context.
{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "COMMAND: ${COMMAND:-<empty>}"
  echo "CWD: $(pwd)"
  echo "GIT_TOPLEVEL: $(git rev-parse --show-toplevel 2>/dev/null || echo '<failed>')"
} >> "$LOG" 2>/dev/null || true

# Re-check the parsed command — word boundary prevents matching "gh pr merge-queue".
if ! printf '%s\n' "$COMMAND" | grep -qE 'gh\s+pr\s+merge(\s|$)'; then
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/Makefile" ]]; then
    echo '{"permissionDecision": "allow", "systemMessage": "No Makefile found — skipping pre-merge gate."}'
    exit 0
fi

# Check that the Makefile actually has a pre-merge target (dry-run). If not,
# allow the merge but nudge toward Makefile.example.
if ! (cd "$REPO_ROOT" && make -n pre-merge >/dev/null 2>&1); then
    echo '{"permissionDecision": "allow", "systemMessage": "Makefile found but no pre-merge target. Add a pre-merge target or see Makefile.example."}'
    exit 0
fi

# Run pre-merge checks synchronously — must pass before the merge is allowed.
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
