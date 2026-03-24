#!/usr/bin/env bash
# scripts/pr-review-bot.sh — Multi-agent PR review bot
#
# Runs Claude, Gemini, and Codex in parallel to review a PR, then
# posts a GitHub review with inline comments on the correct diff lines.
#
# Non-code PRs (docs-only, license, changelog) are skipped automatically.
# All code PRs get the full 3-agent review at original model quality.
#
# Usage: scripts/pr-review-bot.sh <PR_NUMBER>
# Requires: gh, jq, and at least one of: claude, gemini, codex

set -euo pipefail

readonly PR_NUM="${1:?Usage: pr-review-bot.sh <PR_NUMBER>}"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
readonly REPO

WORK="$(mktemp -d)"
readonly WORK
readonly MAX_DIFF_CHARS=50000
readonly AGENT_TIMEOUT=180  # seconds per agent
readonly SMALL_DELTA_THRESHOLD=50  # lines changed since last review

trap 'rm -rf "$WORK"' EXIT

# Detect timeout command (macOS needs coreutils)
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi

# ─── Utilities ───────────────────────────────────

log() { printf '[pr-review-bot] %s\n' "$*" >&2; }

run_with_timeout() {
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$AGENT_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# Source shared library (expects WORK, log to be defined)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-pr-review-utils.sh"

check_prereqs() {
  local missing=()
  command -v gh  >/dev/null || missing+=(gh)
  command -v jq  >/dev/null || missing+=(jq)
  if (( ${#missing[@]} > 0 )); then
    log "ERROR: Missing required tools: ${missing[*]}"
    exit 1
  fi
  local has_agent=false
  command -v claude >/dev/null && has_agent=true
  command -v gemini >/dev/null && has_agent=true
  command -v codex  >/dev/null && has_agent=true
  if ! $has_agent; then
    log "ERROR: Need at least one agent CLI (claude, gemini, or codex)"
    exit 1
  fi
  if [[ -z "$TIMEOUT_CMD" ]]; then
    log "WARNING: timeout/gtimeout not found — agents run without time limit"
    log "  Install coreutils for timeout support: brew install coreutils"
  fi
}

# ─── Fetch PR Data ───────────────────────────────

fetch_pr_data() {
  log "Fetching PR #${PR_NUM} from ${REPO}..."
  gh pr diff "$PR_NUM" > "$WORK/diff.txt"
  gh pr view "$PR_NUM" --json title,body,headRefName,baseRefName,files \
    > "$WORK/pr_info.json"

  local diff_size
  diff_size=$(wc -c < "$WORK/diff.txt" | tr -d ' ')

  truncate_diff_by_hunks "$MAX_DIFF_CHARS" "$WORK/diff.txt" "$WORK/diff_review.txt"

  log "PR: $(jq -r .title "$WORK/pr_info.json")"
  log "Branch: $(jq -r .headRefName "$WORK/pr_info.json")"
  log "Files: $(jq '.files | length' "$WORK/pr_info.json"), Diff: ${diff_size} chars"
}

# ─── PR Classification (skip or review) ─────────
# Binary: does this PR contain code changes? If not, skip entirely.

has_code_changes() {
  local files_list
  files_list=$(jq -r '.files[].path' "$WORK/pr_info.json" 2>/dev/null || true)

  while IFS= read -r fpath; do
    [[ -z "$fpath" ]] && continue
    case "$fpath" in
      *.md|docs/*|.gitignore|.gcloudignore|LICENSE|CHANGELOG*)
        ;; # non-code — skip
      *)
        return 0  # found a code file
        ;;
    esac
  done <<< "$files_list"

  return 1  # no code files found
}

# ─── Agent Focus Areas ──────────────────────────
# Customize these for your project's specific patterns and concerns.

readonly CLAUDE_FOCUS='FOCUS AREAS (architecture):
1. Pattern consistency — are routes, services, and repositories properly layered?
2. Coupling — does new code reach into internals of other modules?
3. Breaking changes — modified function signatures, return types, or behaviors
4. Module boundaries — is code placed in the right module?
5. File size — flag any file exceeding 500 lines
6. DRY — duplicated logic that should be extracted to a shared module'

readonly GEMINI_FOCUS='FOCUS AREAS (security):
1. OWASP Top 10 — injection, broken access control, XSS, SSRF, IDOR
2. Secrets — credentials in code or logs, .env files committed
3. Input validation — sanitization at API boundaries
4. SQL parameterization — no string formatting in queries
5. Auth checks — authentication and authorization on all endpoints
6. Data isolation — tenant-level or user-level access controls'

readonly CODEX_FOCUS='FOCUS AREAS (edge cases and quality):
1. Null/empty/undefined inputs at every function boundary
2. String gotchas — endswith("") always True, case sensitivity
3. Error handling — no bare except, no swallowed exceptions
4. Performance — N+1 queries, unbounded loops, missing pagination
5. Test coverage — are new code paths and error paths tested?
6. Backwards compatibility — API response shape changes, missing migrations'

# ─── Agent Runners ───────────────────────────────

run_claude_review() {
  if ! command -v claude >/dev/null 2>&1; then
    log "  Skipping Claude (not installed)"
    return 0
  fi
  log "  Starting Claude (architecture) review..."

  # Build enhanced prompt: file list + truncated diff + tool access for full context
  local pr_title pr_branch file_list
  pr_title=$(jq -r .title "$WORK/pr_info.json")
  pr_branch=$(jq -r .headRefName "$WORK/pr_info.json")
  file_list=$(jq -r '.files[].path' "$WORK/pr_info.json" 2>/dev/null || true)

  local preamble postamble
  preamble=$(printf '<UNTRUSTED_PR_METADATA>\nPR: %s\nBranch: %s\n\nChanged files:\n%s\n</UNTRUSTED_PR_METADATA>' \
    "$pr_title" "$pr_branch" "$file_list")
  postamble='You have access to Read and Grep tools. If the diff is truncated or you need
more context about a file, use these tools to read the full source file.
Only read files that appear in the changed files list.'

  build_review_prompt "Claude (Architecture)" "$CLAUDE_FOCUS" "$preamble" "$postamble" \
    > "$WORK/prompt-claude.txt"

  # Unset CLAUDECODE to allow running inside a Claude Code session (local testing).
  # --allowedTools restricts to read-only tools. Default permission mode auto-approves
  # reads within the working directory; reads outside require explicit approval (safe
  # in CI where no user is present — denied tool calls degrade gracefully to diff-only).
  CLAUDECODE='' run_with_timeout claude -p "$(cat "$WORK/prompt-claude.txt")" \
    --allowedTools "Read,Grep" \
    --output-format text \
    > "$WORK/review-claude.txt" 2>/dev/null || {
    log "  Claude review failed or timed out (exit $?)"
    return 0
  }
  log "  Claude review complete ($(wc -l < "$WORK/review-claude.txt" | tr -d ' ') lines)"
}

run_gemini_review() {
  if ! command -v gemini >/dev/null 2>&1; then
    log "  Skipping Gemini (not installed)"
    return 0
  fi
  log "  Starting Gemini (security) review..."
  # Source .env for Google Cloud auth if available
  if [[ -f .env ]]; then set -a; source .env 2>/dev/null || true; set +a; fi

  # Use strict fallback: auto (Pro) → fallback-pro → FAIL
  # Security reviews must fail closed — no downgrade to weaker models
  local prompt
  prompt="$(build_review_prompt "Gemini (Security)" "$GEMINI_FOCUS")"

  if [[ -f .claude/scripts/gemini-with-fallback.sh ]]; then
    run_with_timeout bash -c "
      source .claude/scripts/gemini-with-fallback.sh
      gemini_with_fallback_strict \"\$1\" -o text
    " -- "$prompt" > "$WORK/review-gemini.txt" 2>/dev/null || {
      log "  Gemini review failed or timed out (exit $?)"
      return 0
    }
  else
    # Fallback: direct call without wrapper
    run_with_timeout gemini "$prompt" -o text \
      > "$WORK/review-gemini.txt" 2>/dev/null || {
      log "  Gemini review failed or timed out (exit $?)"
      return 0
    }
  fi
  log "  Gemini review complete ($(wc -l < "$WORK/review-gemini.txt" | tr -d ' ') lines)"
}

run_codex_review() {
  if ! command -v codex >/dev/null 2>&1; then
    log "  Skipping Codex (not installed)"
    return 0
  fi
  log "  Starting Codex (edge cases) review..."

  # Use `codex review --base` for native diff reading (~85% fewer input tokens
  # vs piping the full diff into codex exec). Pass output format in the prompt
  # so output is compatible with parse_agent_output().
  local base_ref
  base_ref=$(jq -r '.baseRefName // "main"' "$WORK/pr_info.json")
  run_with_timeout codex review --base "$base_ref" \
    "${CODEX_FOCUS}

${OUTPUT_FMT}" \
    > "$WORK/review-codex.txt" 2>/dev/null || {
    log "  Codex review failed or timed out (exit $?)"
    return 0
  }
  log "  Codex review complete ($(wc -l < "$WORK/review-codex.txt" | tr -d ' ') lines)"
}

# ─── Delta-Aware Re-Review Gate ─────────────────
# Detects prior bot reviews and skips/reduces re-reviews based on delta size.
# Returns 0 to proceed with review, 1 to skip.
# Side effect: on large deltas, overwrites $WORK/diff.txt with just the delta
# so that subsequent build_diff_line_map and agents review only new changes.

check_previous_review() {
  # Force review bypasses all delta checks (triggered by @review comment)
  if [[ "${FORCE_REVIEW:-}" == "true" ]]; then
    log "Force review requested — skipping delta check."
    return 0
  fi

  # 1. Query existing bot reviews
  local last_review_sha
  last_review_sha=$(gh api "repos/${REPO}/pulls/${PR_NUM}/reviews?per_page=100" \
    --jq '[.[] | select(.user.login == "github-actions[bot]")] | last | .commit_id' \
    2>/dev/null) || true

  if [[ -z "$last_review_sha" || "$last_review_sha" == "null" ]]; then
    log "No previous bot review found — full review."
    return 0
  fi

  # 2. Verify the commit still exists in history (handles force-pushes)
  if ! git cat-file -e "${last_review_sha}^{commit}" 2>/dev/null; then
    log "Previous review commit ${last_review_sha:0:8} not in history (force-pushed?) — full review."
    return 0
  fi

  # 3. Compute delta since last reviewed commit
  local delta_stat delta_lines
  delta_stat=$(git diff --shortstat "${last_review_sha}..HEAD" -- 2>/dev/null) || true

  if [[ -z "$delta_stat" ]]; then
    delta_lines=0
  else
    # Sum insertions + deletions using pure bash (no bc dependency)
    delta_lines=0
    local n
    while IFS= read -r n; do
      (( delta_lines += n )) || true
    done < <(echo "$delta_stat" | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+')
    # If parsing failed (unexpected format), default to full review
    [[ "$delta_lines" -eq 0 && -n "$delta_stat" ]] && delta_lines=999
  fi

  log "Previous review at ${last_review_sha:0:8}, delta: ${delta_lines} lines"

  if (( delta_lines == 0 )); then
    log "No changes since last review — skipping."
    return 1
  elif (( delta_lines <= SMALL_DELTA_THRESHOLD )); then
    log "Small follow-up (${delta_lines} lines) — skipping re-review."
    gh pr comment "$PR_NUM" --body \
      "**PR Review Bot**: Small follow-up (~${delta_lines} lines) since last review. Skipping re-review. Comment \`@review\` to force." \
      > /dev/null 2>&1 || true
    return 1
  else
    # Large delta — review only the new changes
    log "Significant changes (${delta_lines} lines) since last review — delta-only review."
    git diff "${last_review_sha}..HEAD" > "$WORK/diff.txt"
    truncate_diff_by_hunks "$MAX_DIFF_CHARS" "$WORK/diff.txt" "$WORK/diff_review.txt"
    return 0
  fi
}

# ─── Main ────────────────────────────────────────

main() {
  log "=== Multi-Agent PR Review for PR #${PR_NUM} ==="
  check_prereqs
  fetch_pr_data

  # Skip if no changes
  if [[ ! -s "$WORK/diff.txt" ]]; then
    log "No diff — nothing to review."
    exit 0
  fi

  # Skip non-code PRs (docs, CI config, formatting)
  if ! has_code_changes; then
    log "No code changes detected — skipping review."
    post_skip_comment
    log "=== Done (skipped) ==="
    exit 0
  fi

  # Delta-aware re-review: skip or reduce scope for follow-up pushes
  if ! check_previous_review; then
    log "=== Done (skipped — follow-up after review) ==="
    exit 0
  fi

  build_diff_line_map

  # Run all 3 agents in parallel
  log "Launching review agents..."
  run_claude_review &
  local pid_c=$!
  run_gemini_review &
  local pid_g=$!
  run_codex_review &
  local pid_x=$!
  wait "$pid_c" "$pid_g" "$pid_x" 2>/dev/null || true
  log "All agents finished."

  parse_all_outputs
  build_review_payload
  post_review

  log "=== Done ==="
}

main
