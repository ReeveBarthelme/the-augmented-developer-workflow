#!/usr/bin/env bash
# Hook: PostToolUse on Edit|Write
# Auto-lints Python and JS/TS files after edits.
# Reads tool_input.file_path from the JSON Claude Code pipes on stdin.
#
# CAVEAT: this rewrites the file (--fix) right after the assistant wrote it, so
# the assistant's in-memory copy can drift from disk. Harmless for formatting
# fixes; if it bothers you (or your linter does risky autofixes), drop the
# --fix flags to lint-only, or unwire this hook from settings.json.

set -euo pipefail

FILE_PATH=$(jq -r '.tool_input.file_path // .tool_input.filePath // empty' 2>/dev/null || true)

if [ -z "$FILE_PATH" ] || [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

case "$FILE_PATH" in
  *.py)
    if command -v ruff &>/dev/null; then
      ruff check --fix --quiet -- "$FILE_PATH" 2>/dev/null || true
    fi
    ;;
  *.ts|*.tsx|*.js|*.jsx)
    # Find the nearest node_modules with eslint
    DIR=$(dirname "$FILE_PATH")
    while [ "$DIR" != "/" ]; do
      if [ -x "$DIR/node_modules/.bin/eslint" ]; then
        "$DIR/node_modules/.bin/eslint" --fix --quiet -- "$FILE_PATH" 2>/dev/null || true
        break
      fi
      DIR=$(dirname "$DIR")
    done
    ;;
esac

exit 0
