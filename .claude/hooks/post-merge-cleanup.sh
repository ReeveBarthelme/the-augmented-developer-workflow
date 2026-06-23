#!/usr/bin/env bash
# post-merge-cleanup.sh — After gh pr merge, clean up the merged worktree.
# Claude Code PostToolUse hook on Bash. Non-blocking.

set -u

INPUT=$(cat)

# Fast path: skip jq + git for the vast majority of Bash calls that aren't merges.
if ! printf '%s\n' "$INPUT" | grep -qE 'gh\s+pr\s+merge(\s|"|$)'; then
    exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

# Re-check the parsed command (word boundary avoids matching gh pr merge-queue).
if ! echo "$COMMAND" | grep -qE 'gh\s+pr\s+merge(\s|$)'; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/scripts/cleanup-worktrees.sh" ]]; then
    exit 0
fi

LOG_FILE="$REPO_ROOT/.claude/logs/worktree-cleanup.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Brief pause for GitHub API consistency, then clean up in background
(
    sleep 3
    "$REPO_ROOT/scripts/cleanup-worktrees.sh"
) >> "$LOG_FILE" 2>&1 &

exit 0
