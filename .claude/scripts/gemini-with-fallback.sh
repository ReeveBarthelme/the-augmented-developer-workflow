#!/usr/bin/env bash
# Gemini CLI wrapper with model fallback on rate limits / quota exhaustion.
#
# Two modes:
#   gemini_with_fallback        — full chain: auto → 3-pro → 2.5-flash (for research/investigation)
#   gemini_with_fallback_strict — pro-only chain: auto → 3-pro → FAIL (for security review)
#
# Usage:
#   source .claude/scripts/gemini-with-fallback.sh
#   gemini_with_fallback "Your prompt here" -o text
#   gemini_with_fallback_strict "Security review prompt" -o text  # fails closed if all pro models exhausted
#
# Fallback chain: auto (3.1 Pro) → gemini-3-pro-preview → gemini-2.5-flash
#
# Override the chain via env vars:
#   GEMINI_PRIMARY_MODEL=gemini-3.1-pro-preview
#   GEMINI_FALLBACK_MODEL=gemini-3-pro-preview
#   GEMINI_LAST_RESORT_MODEL=gemini-2.5-flash

GEMINI_PRIMARY_MODEL="${GEMINI_PRIMARY_MODEL:-auto}"
GEMINI_FALLBACK_MODEL="${GEMINI_FALLBACK_MODEL:-gemini-3-pro-preview}"
GEMINI_LAST_RESORT_MODEL="${GEMINI_LAST_RESORT_MODEL:-gemini-2.5-flash}"

_gemini_is_quota_error() {
  local output="$1"
  local exit_code="$2"
  # Non-zero exit with quota/rate-limit indicators
  if [ "$exit_code" -ne 0 ]; then
    if echo "$output" | grep -qiE 'quota|rate.limit|resource.exhausted|429|RESOURCE_EXHAUSTED|daily.limit|RPD|TPD'; then
      return 0
    fi
  fi
  return 1
}

gemini_with_fallback() {
  local prompt="$1"
  shift
  # Remaining args are flags like -o text, --yolo, etc.
  local extra_args=("$@")

  # Source .env for GEMINI_API_KEY if not already set
  if [ -z "$GEMINI_API_KEY" ] && [ -f .env ]; then
    set -a; source .env; set +a
  fi

  # --- Attempt 1: Primary model ---
  echo "▸ Trying Gemini model: $GEMINI_PRIMARY_MODEL" >&2
  local output
  output=$(gemini "$prompt" -m "$GEMINI_PRIMARY_MODEL" "${extra_args[@]}" 2>&1)
  local rc=$?

  if [ $rc -eq 0 ] && ! _gemini_is_quota_error "$output" "$rc"; then
    echo "$output"
    return 0
  fi

  # Check if it's actually a quota error vs some other failure
  if ! _gemini_is_quota_error "$output" "$rc"; then
    # Non-quota failure — don't retry with different model, just return error
    echo "$output"
    return $rc
  fi

  echo "⚠ $GEMINI_PRIMARY_MODEL quota exhausted — falling back to $GEMINI_FALLBACK_MODEL" >&2

  # --- Attempt 2: Fallback model ---
  output=$(gemini "$prompt" -m "$GEMINI_FALLBACK_MODEL" "${extra_args[@]}" 2>&1)
  rc=$?

  if [ $rc -eq 0 ] && ! _gemini_is_quota_error "$output" "$rc"; then
    echo "$output"
    return 0
  fi

  if ! _gemini_is_quota_error "$output" "$rc"; then
    echo "$output"
    return $rc
  fi

  echo "⚠ $GEMINI_FALLBACK_MODEL also exhausted — last resort: $GEMINI_LAST_RESORT_MODEL" >&2

  # --- Attempt 3: Last resort ---
  output=$(gemini "$prompt" -m "$GEMINI_LAST_RESORT_MODEL" "${extra_args[@]}" 2>&1)
  rc=$?
  echo "$output"
  return $rc
}

# Strict variant: only tries pro-tier models, fails closed if all exhausted.
# Use for security reviews where model quality matters.
# Returns exit code 75 (EX_TEMPFAIL) when all pro models are quota-exhausted.
gemini_with_fallback_strict() {
  local prompt="$1"
  shift
  local extra_args=("$@")

  if [ -z "$GEMINI_API_KEY" ] && [ -f .env ]; then
    set -a; source .env; set +a
  fi

  # --- Attempt 1: Primary model ---
  echo "▸ [strict] Trying Gemini model: $GEMINI_PRIMARY_MODEL" >&2
  local output
  output=$(gemini "$prompt" -m "$GEMINI_PRIMARY_MODEL" "${extra_args[@]}" 2>&1)
  local rc=$?

  if [ $rc -eq 0 ] && ! _gemini_is_quota_error "$output" "$rc"; then
    echo "$output"
    return 0
  fi

  if ! _gemini_is_quota_error "$output" "$rc"; then
    echo "$output"
    return $rc
  fi

  echo "⚠ [strict] $GEMINI_PRIMARY_MODEL quota exhausted — trying $GEMINI_FALLBACK_MODEL" >&2

  # --- Attempt 2: Fallback (still pro-tier) ---
  output=$(gemini "$prompt" -m "$GEMINI_FALLBACK_MODEL" "${extra_args[@]}" 2>&1)
  rc=$?

  if [ $rc -eq 0 ] && ! _gemini_is_quota_error "$output" "$rc"; then
    echo "$output"
    return 0
  fi

  if ! _gemini_is_quota_error "$output" "$rc"; then
    echo "$output"
    return $rc
  fi

  # --- Fail closed: no 2.5-flash fallback for strict mode ---
  echo "✗ [strict] All pro-tier Gemini models exhausted. Failing closed." >&2
  return 75
}
