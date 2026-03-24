#!/usr/bin/env bash
# Stop hook: remind about /wrap-up if uncommitted changes exist.
# Blocks once to prompt wrap-up; allows stop on second attempt
# to prevent infinite loops (uses stop_hook_active guard).
set -uo pipefail

INPUT=$(cat)

# Parse stop_hook_active from JSON input
STOP_HOOK_ACTIVE="false"
if command -v jq &>/dev/null; then
  STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
fi

# If we already blocked once, let the user go
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  exit 0
fi

# Check for uncommitted changes (staged or unstaged)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
if git -C "$REPO_ROOT" status --porcelain 2>/dev/null | grep -q '^'; then
  echo '{"decision":"block","reason":"You have uncommitted changes. Consider running /wrap-up to commit, save learnings, and clean up before ending the session. Say \"skip wrap-up\" to end without it."}'
fi

exit 0
