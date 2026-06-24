#!/usr/bin/env bash
# cleanup-worktrees.sh — Remove worktrees whose PRs have been merged.
# Safe: only removes worktrees confirmed merged via GitHub API.
# Usage: ./scripts/cleanup-worktrees.sh [--dry-run]

set -euo pipefail

# Prepend common tool locations (Homebrew on Apple Silicon/Intel) without
# discarding the caller's PATH — this runs from a background hook with a possibly
# minimal environment, but must still find git/gh wherever they live on Linux.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
WORKTREES_DIR="$REPO_ROOT/.worktrees"

echo "=== Worktree Cleanup — $(date) ==="
$DRY_RUN && echo "(dry-run: no changes will be made)"

cd "$REPO_ROOT"

# Step 1: prune stale worktree metadata
if $DRY_RUN; then
    echo "~ would run: git worktree prune"
else
    git worktree prune
    echo "✓ git worktree prune"
fi

[[ -d "$WORKTREES_DIR" ]] || { echo "No .worktrees/ directory."; exit 0; }

# Step 2: process each subdirectory
for dir in "$WORKTREES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    name=$(basename "$dir")

    branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "")

    if [[ -z "$branch" ]]; then
        echo "? $name: no branch detected (detached HEAD or orphaned dir) — skipping"
        continue
    fi

    merged=$(gh pr list --head "$branch" --state merged --json number --jq 'length' 2>/dev/null || echo "0")

    if [[ "$merged" -gt 0 ]]; then
        # Refuse to remove if the worktree is dirty in ANY way. `git status
        # --porcelain` covers staged, unstaged AND untracked files — a plain
        # `git diff` check would miss untracked work, which the remove-fallback
        # below could then destroy.
        if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
            echo "⚠ $name ($branch): merged but has uncommitted/untracked changes — skipping (clean manually)"
            continue
        fi

        echo "✓ $name ($branch): PR merged"
        if $DRY_RUN; then
            echo "  ~ would: git worktree remove + git branch -D $branch"
        else
            # Use git's own --force (worktree-aware) rather than `rm -rf`: it
            # refuses to touch anything that isn't a registered worktree, so a
            # bad $dir can't escalate into deleting an arbitrary directory.
            git worktree remove "$dir" 2>/dev/null || git worktree remove --force "$dir" 2>/dev/null || true
            git worktree prune 2>/dev/null || true
            git branch -D "$branch" 2>/dev/null && \
                echo "  ✓ removed worktree + deleted branch $branch" || \
                echo "  ✓ removed worktree (branch $branch already gone)"
        fi
    else
        echo "~ $name ($branch): not merged, keeping"
    fi
done

echo "=== Done ==="
