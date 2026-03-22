#!/usr/bin/env bash
# post-create-check.sh — After gh pr create, run make pre-merge in background
# and post results as a PR comment. Non-blocking.
# Claude Code PostToolUse hook on Bash tool.
#
# Protocol: PostToolUse hooks are informational — no JSON output required.
# This hook exits immediately; the background process posts a PR comment when done.

set -u

# Read tool input from stdin (Claude Code passes JSON via stdin, NOT env vars)
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

# Only trigger after "gh pr create" — word boundary prevents matching hypothetical subcommands
if ! echo "$COMMAND" | grep -qE 'gh\s+pr\s+create(\s|$)'; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/Makefile" ]]; then
    exit 0
fi

# Guard: detached HEAD → can't determine branch → bail out
BRANCH=$(cd "$REPO_ROOT" && git branch --show-current)
if [[ -z "$BRANCH" ]]; then
    exit 0
fi

# Run pre-merge in background, post results as PR comment when done.
# Fully detach: redirect all FDs so the hook runner doesn't wait on child streams.
# Move gh pr list inside the background process to avoid 10s timeout on network calls.
(
    cd "$REPO_ROOT"

    # Brief pause for GitHub API eventual consistency after PR creation
    sleep 3

    # Find the just-created PR number from current branch
    PR_NUM=$(gh pr list --head "$BRANCH" --json number --jq '.[0].number' 2>/dev/null)
    if [[ -z "$PR_NUM" || "$PR_NUM" == "null" ]]; then
        exit 0
    fi

    OUTPUT=$(make pre-merge 2>&1)
    EXIT_CODE=$?

    if [[ $EXIT_CODE -eq 0 ]]; then
        BODY="## Pre-merge Checks: PASSED

All local CI checks passed."
    else
        # Sanitize: strip triple backticks from output to prevent markdown breakage
        TAIL=$(printf '%s' "$OUTPUT" | tail -80 | sed 's/```/` ` `/g')
        BODY="## Pre-merge Checks: FAILED

Fix these issues before merging:

\`\`\`
$TAIL
\`\`\`"
    fi

    gh pr comment "$PR_NUM" --body "$BODY" 2>/dev/null
) </dev/null >/dev/null 2>&1 &

# Return immediately — non-blocking
exit 0
