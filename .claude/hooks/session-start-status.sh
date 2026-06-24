#!/usr/bin/env bash
# Hook: SessionStart
# Shows current branch and uncommitted changes at session start.

set -euo pipefail

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
DIRTY_ALL=$(git status --porcelain 2>/dev/null)

if [ -n "$DIRTY_ALL" ]; then
  COUNT=$(echo "$DIRTY_ALL" | wc -l | tr -d ' ')
  DISPLAY=$(echo "$DIRTY_ALL" | head -20)
  echo "Branch: $BRANCH | $COUNT uncommitted change(s)"
  echo "$DISPLAY"
  if [ "$COUNT" -gt 20 ] 2>/dev/null; then
    echo "... and $((COUNT - 20)) more"
  fi
else
  echo "Branch: $BRANCH | Working tree clean"
fi

exit 0
