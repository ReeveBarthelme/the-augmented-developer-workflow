#!/usr/bin/env bash
# memory-compact.sh — Report-only planner for compacting the auto-memory index.
#
# The memory hook demands MEMORY.md stay under a byte budget. Getting there by
# hand is a guess-trim-measure loop (8 passes on Aug 12 2026, 13 compactions to
# date). This does the measuring so the trimming is one pass.
#
# It NEVER edits anything. It prints:
#   1. current bytes vs budget, and exactly how many bytes to cut
#   2. the longest index lines, ranked, with byte counts
#   3. per line: SAFE  = its distinctive tokens were found in a topic file
#                MOVE  = tokens found ONLY in the index -> move the detail out
#                        into a topic file BEFORE trimming, or the fact is lost
#
# Usage:
#   memory-compact.sh [--budget N] [--top N] [--memory-dir DIR]
#
# Defaults: budget 17100 bytes (the hook's compaction target), top 15 lines.
# Exit 0 if already under budget, 1 if a trim is needed, 2 on usage error.

set -uo pipefail

# Claude Code encodes a project's cwd by replacing every "/" with "-".
MEMORY_DIR="${CLAUDE_MEMORY_DIR:-$HOME/.claude/projects/$(pwd | tr '/' '-')/memory}"
BUDGET=17100
TOP=15

while [ $# -gt 0 ]; do
    case "$1" in
        --budget)     BUDGET="${2:-}"; shift 2 || exit 2 ;;
        --top)        TOP="${2:-}"; shift 2 || exit 2 ;;
        --memory-dir) MEMORY_DIR="${2:-}"; shift 2 || exit 2 ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *)            echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

INDEX="$MEMORY_DIR/MEMORY.md"
[ -f "$INDEX" ] || { echo "no index at $INDEX" >&2; exit 2; }

BYTES=$(wc -c < "$INDEX" | tr -d ' ')
LINES=$(wc -l < "$INDEX" | tr -d ' ')
OVER=$(( BYTES - BUDGET ))

echo "MEMORY.md — $BYTES bytes / $BUDGET budget, $LINES lines"
echo "============================================================"
if [ "$OVER" -le 0 ]; then
    echo "Under budget by $(( -OVER )) bytes. Nothing to do."
    exit 0
fi
echo "OVER BUDGET by $OVER bytes. Trim at least that much."
echo

# Distinctive tokens for the coverage check: backticked identifiers, issue
# numbers, commit shas, and *.md/*.sh/*.py filenames. Common words are useless
# here -- a token has to be rare enough that finding it in a topic file really
# means that file carries this fact.
extract_tokens() {
    printf '%s\n' "$1" \
        | grep -oE '`[^`]+`|#[0-9]{3,5}|\b[0-9a-f]{8}\b|[A-Za-z0-9_.-]+\.(md|sh|py|toml|yml|ts|tsx)\b' \
        | tr -d '`' \
        | grep -vE '^(md|sh|py)$' \
        | grep -vE '[[:space:]]' \
        | sort -u
        # Multi-word backticked phrases are dropped on purpose: they match by
        # exact string, so `exclude_commands=["ps"]` in the index misses the
        # topic file's `exclude_commands = ["ps"]` and reports a false MOVE.
        # Single tokens (identifiers, issue numbers, shas, filenames) are stable.
}

# A line's detail is SAFE to trim only if at least one distinctive token also
# appears in some topic file. Tokens that name the topic file itself (the link
# target) are skipped -- every index line contains one, so counting it would
# make everything look covered.
LINK_TARGETS=$(grep -oE '\]\([a-z0-9_.-]+\.md\)' "$INDEX" | tr -d '])(' | sort -u)

echo "Longest lines (trim these first):"
echo "------------------------------------------------------------"
printf '%-6s %-6s %s\n' "BYTES" "STATUS" "LINE"

# Split on the FIRST colon only -- index lines are full of colons (`$VAR:text`,
# `container:` job), and an awk -F: rejoin silently eats every one of them.
grep -n '^- \[' "$INDEX" \
  | while IFS= read -r row; do
        n="${row%%:*}"; t="${row#*:}"
        printf '%s\t%s\t%s\n' "${#t}" "$n" "$t"
    done \
  | sort -rn | head -"$TOP" \
  | while IFS=$'\t' read -r len lineno text; do
        status="SAFE"
        uncovered=""
        # `set -f` is load-bearing: index lines contain globs (`review-*.md`,
        # `/tmp/act-output-*.log`) and an unquoted token would expand to every
        # matching file on disk, firing MOVE for hundreds of phantom tokens.
        set -f
        while IFS= read -r tok; do
            [ -n "$tok" ] || continue
            case "$LINK_TARGETS" in *"$tok"*) continue ;; esac
            # Recurse over the DIRECTORY, not a glob of files: with an explicit
            # file list `--exclude` is ignored, MEMORY.md matches its own token,
            # and every line reports SAFE regardless of coverage.
            if ! grep -rqlF --exclude=MEMORY.md -- "$tok" "$MEMORY_DIR" 2>/dev/null; then
                uncovered="$uncovered $tok"
            fi
        done <<EOF
$(extract_tokens "$text")
EOF
        set +f
        [ -n "$uncovered" ] && status="MOVE"
        printf '%-6s %-6s L%s %s\n' "$len" "$status" "$lineno" "$(printf '%s' "$text" | cut -c1-90)"
        [ -n "$uncovered" ] && printf '%-13s   index-only:%s\n' "" "$uncovered"
    done

echo
echo "MOVE = that token appears in NO topic file. Move the detail out first,"
echo "       then trim. SAFE = the topic file already carries it."
exit 1
