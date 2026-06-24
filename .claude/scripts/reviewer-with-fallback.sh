#!/usr/bin/env bash
# =============================================================================
# reviewer-with-fallback.sh — Multi-provider reviewer for ADVISORY/investigation
# seats. Provider chain: groq → cerebras → ollama → gemini-3-flash (via gemini wrapper).
#
# EXIT CODE CONTRACT (matches gemini-with-fallback.sh):
#   0  = success
#   64 = EX_USAGE — seat forbidden (security*, design-vote) on this script
#   75 = all providers exhausted (quota/unavailable)
#   78 = terminal billing failure
#   other = real error passthrough
#
# FORBIDDEN SEATS (exit 64 — use gemini-with-fallback.sh instead):
#   Any seat matching *security* (case-insensitive, trimmed), or "design-vote".
#   Security reviews MUST use gemini_with_fallback_strict (pro-only chain).
#   Design-vote seat also requires pro-tier; use gemini-with-fallback.sh.
#
# PROVIDER CHAIN (investigation/default seats), each skipped if key/binary absent:
#   1. groq     — openai/gpt-oss-120b, OpenAI-compatible API (GROQ_API_KEY).
#   2. cerebras — SAME gpt-oss-120b on Cerebras' free tier (CEREBRAS_API_KEY); N+1
#                redundancy for the validated seat. ⚠️ Free tier ~8,192-token
#                context cap, so it sits AFTER groq; its errors DEGRADE (no abort).
#   3. ollama   — local qwen3-coder (skipped if `ollama` not on PATH).
#   4. gemini   — gemini-3-flash via gemini-with-fallback.sh.
#
# Each degradation prints a DEGRADED banner. Billing failure at groq or gemini
# exits 78 (terminal — fix billing); cerebras billing/quota degrades instead.
# Provider-attempt functions live in reviewer-providers.sh (sourced below).
#
# SPEND LOG:
#   Appends to SPEND_LOG (default: ~/.gemini/spend.jsonl) — same schema as
#   gemini-with-fallback.sh, with an added "provider" field.
#   Override via env: export SPEND_LOG=/tmp/test-spend.jsonl
#
# USAGE:
#   reviewer-with-fallback.sh "Your prompt here" [-o text]
#
# ENV VARS:
#   REVIEWER_SEAT    — seat tier (investigation/unknown; security/design-vote → forbidden)
#   REVIEWER_RUN_ID  — run identifier (defaults to date-based)
#   GROQ_API_KEY     — Groq API key (NEVER hardcode). If unset, the key line
#                      is extracted (never sourced/executed) from repo-root
#                      .env — the main checkout's when run from a worktree.
#   CEREBRAS_API_KEY — Cerebras API key (free at cloud.cerebras.ai). Same .env
#                      extraction as GROQ_API_KEY. Skipped if absent.
#   GEMINI_API_KEY   — Gemini API key for final fallback
#   SPEND_LOG        — override spend log path (for tests)
#   GROQ_API_URL     — override Groq API endpoint (for tests)
#   CEREBRAS_API_URL — override Cerebras API endpoint (for tests)
#   CEREBRAS_MODEL   — override Cerebras model (default: gpt-oss-120b)
#   OLLAMA_MODEL     — override ollama model (default: qwen3-coder)
#   RWF_ENV_FILE     — override .env path for the autoload (for tests)
#
# NOTE ON THE BUNDLED GEMINI WRAPPER:
#   This template ships a minimal gemini-with-fallback.sh that defines
#   gemini_with_fallback / gemini_with_fallback_strict but has NO seat-tier
#   model pinning, no REVIEWER_SEAT handling, no spend logging, and does not
#   emit the 75/78 exit codes. The Gemini fallback and the forbidden-seat
#   guidance still work, but the seat-tier and exit-code-parity comments below
#   describe a richer wrapper you may drop in. With the bundled wrapper, the
#   Gemini hop runs at its default model and the 75/78 gemini branches in
#   main() are inert (a non-zero gemini exit degrades via the generic path).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Exit code constants
# ---------------------------------------------------------------------------
readonly _RWF_EXIT_OK=0
readonly _RWF_EXIT_USAGE=64
readonly _RWF_EXIT_QUOTA=75
readonly _RWF_EXIT_BILLING=78

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
_GROQ_API_URL="${GROQ_API_URL:-https://api.groq.com/openai/v1/chat/completions}"
_GROQ_MODEL="openai/gpt-oss-120b"
# Cerebras: free-tier failover serving the SAME gpt-oss-120b over an
# OpenAI-compatible API. ⚠️ Free tier caps context at ~8,192 tokens, so it is
# positioned AFTER Groq (larger window) — large prompts may truncate here.
_CEREBRAS_API_URL="${CEREBRAS_API_URL:-https://api.cerebras.ai/v1/chat/completions}"
_CEREBRAS_MODEL="${CEREBRAS_MODEL:-gpt-oss-120b}"
_OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3-coder}"
_GEMINI_WRAPPER="${BASH_SOURCE[0]%/*}/gemini-with-fallback.sh"

# ---------------------------------------------------------------------------
# Extract ONE named key from an env file and export it (if not already set).
# Never sources: wholesale `source` clobbers sibling keys (e.g. GEMINI_API_KEY)
# and dies under set -e on malformed lines. Existing value
# always wins. $1 = var name, $2 = env file.
# ---------------------------------------------------------------------------
_rwf_extract_key() {
    local var_name="$1" env_file="$2"
    [ -n "${!var_name:-}" ] && return 0
    local key
    key=$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${var_name}=" "$env_file" 2>/dev/null) || return 0
    key="${key#*=}"
    key="${key%$'\r'}"
    key="${key%\"}"; key="${key#\"}"; key="${key%\'}"; key="${key#\'}"
    [ -n "$key" ] && export "${var_name}=${key}"
    return 0
}

# ---------------------------------------------------------------------------
# Load GROQ_API_KEY and CEREBRAS_API_KEY from .env when not already set. Path:
# repo root anchored to this script; worktrees have no .env, so fall back to the
# main checkout via git-common-dir. RWF_ENV_FILE overrides (tests). Both keys
# share the single resolved env_file; each existing key always wins.
# NOTE: if only ONE key is pre-set in the shell, the other is still looked up in
# .env on every run (a git-common-dir resolve in worktrees) — inherent to
# supporting .env-provided keys. In normal orchestration both come from .env, so
# the read happens regardless; the cost only appears when a key is shell-exported.
# ---------------------------------------------------------------------------
_rwf_load_env() {
    # Short-circuit only when BOTH keys are already present in the environment.
    [ -n "${GROQ_API_KEY:-}" ] && [ -n "${CEREBRAS_API_KEY:-}" ] && return 0
    local env_file="${RWF_ENV_FILE:-}"
    if [ -z "$env_file" ]; then
        local script_dir="${BASH_SOURCE[0]%/*}"
        env_file="${script_dir}/../../.env"
        if [ ! -f "$env_file" ]; then
            local common_dir
            common_dir=$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
            env_file="${common_dir%/.git}/.env"
        fi
    fi
    [ -f "$env_file" ] || return 0
    _rwf_extract_key GROQ_API_KEY "$env_file"
    _rwf_extract_key CEREBRAS_API_KEY "$env_file"
    return 0
}

# ---------------------------------------------------------------------------
# Spend-log field sanitizer — strips characters that break JSON string values.
# Keeps spend-log fields JSON-safe and consistent across providers.
# ---------------------------------------------------------------------------
_rwf_sanitize_field() {
    printf '%s' "$1" | tr -cd '[:alnum:]._/:+-'
}

# ---------------------------------------------------------------------------
# Spend log helper (mirrors gemini-with-fallback.sh schema + provider field).
# seat and run_id sanitized before printf interpolation.
# ---------------------------------------------------------------------------
_rwf_log_spend() {
    local provider="$1"
    local model
    model=$(_rwf_sanitize_field "$2")   # env-overridable model names must not break JSON
    local chars_in="$3"
    local chars_out="$4"
    local exit_code="$5"

    local raw_seat="${REVIEWER_SEAT:-unknown}"
    local raw_run_id="${REVIEWER_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
    local seat
    seat=$(_rwf_sanitize_field "$raw_seat")
    local run_id
    run_id=$(_rwf_sanitize_field "$raw_run_id")
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

    local log_file="${SPEND_LOG:-${HOME}/.gemini/spend.jsonl}"
    local log_dir
    log_dir=$(dirname "$log_file")
    mkdir -p "$log_dir" 2>/dev/null || true
    chmod 700 "$log_dir" 2>/dev/null || true

    # No secrets logged — same printf format as gemini-with-fallback.sh
    printf '{"ts":"%s","model":"%s","seat":"%s","run_id":"%s","chars_in":%d,"chars_out":%d,"exit_code":%d,"provider":"%s"}\n' \
        "$ts" "$model" "$seat" "$run_id" \
        "$chars_in" "$chars_out" "$exit_code" "$provider" \
        >> "$log_file" 2>/dev/null || true
    chmod 600 "$log_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Degradation banner
# ---------------------------------------------------------------------------
_rwf_degraded_banner() {
    local from_provider="$1"
    local to_provider="$2"
    local reason="$3"
    echo "" >&2
    echo "⚠️  DEGRADED SEAT: falling through provider ${from_provider} → ${to_provider} (reason: ${reason})" >&2
    echo "" >&2
}

# ---------------------------------------------------------------------------
# Error classification on the ERROR PATH ONLY — never called on success.
# Billing-specific markers only; does not match bare PERMISSION_DENIED.
# ---------------------------------------------------------------------------
_rwf_is_billing_error() {
    local output="$1"
    local exit_code="$2"
    [ "$exit_code" -ne 0 ] || return 1
    echo "$output" | grep -qiE \
        'billing.*(disabled|suspended|blocked|invalid|not_enabled|not enabled)|PERMISSION_DENIED.*billing|billing.*PERMISSION_DENIED|consumer.*has been suspended|project.*billing.*disabled|billing_not_enabled|payment.*required'
}

_rwf_is_invalid_key_error() {
    local output="$1"
    local exit_code="$2"
    [ "$exit_code" -ne 0 ] || return 1
    echo "$output" | grep -qiE \
        'invalid.*(api.?key|key|token)|api.?key.*invalid|authentication.*failed|unauthorized|invalid_api_key'
}

# ---------------------------------------------------------------------------
# Billing failure banner
# ---------------------------------------------------------------------------
_rwf_billing_banner() {
    local provider="$1"
    cat >&2 <<BANNER

================================================================================
🚨 BILLING FAILURE — ${provider} account/billing is broken; this reviewer seat is down.

  This is NOT a wait-it-out error. Fix billing/account access before retrying.

  For GCP/Gemini: console.cloud.google.com/billing
  For Groq: console.groq.com

  Exit code: 78 (terminal — billing/account failure)
================================================================================

BANNER
}

# ---------------------------------------------------------------------------
# Provider-attempt functions (groq / cerebras / ollama / gemini) live in a
# sibling library, sourced here to keep this orchestrator under the 500-line
# ceiling. The lib resolves the shared helpers, config vars, exit-code
# constants and _RWF_OUTPUT defined above at call time, so source order is safe.
# ---------------------------------------------------------------------------
# shellcheck source=.claude/scripts/reviewer-providers.sh
source "${BASH_SOURCE[0]%/*}/reviewer-providers.sh"

# ---------------------------------------------------------------------------
# Seat normalization and forbidden-seat check.
# Normalizes to lowercase and trims whitespace.
# Refuses: any seat matching *security* pattern, or "design-vote".
# ---------------------------------------------------------------------------
_rwf_normalize_seat() {
    # lowercase + strip leading/trailing whitespace
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

_rwf_is_forbidden_seat() {
    local normalized="$1"
    # Any seat containing "security" substring is forbidden
    [[ "$normalized" == *security* ]] && return 0
    # design-vote requires pro-tier; forbidden here
    [[ "$normalized" == "design-vote" ]] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
main() {
    local prompt="${1:-}"
    shift || true
    local extra_args=("$@")

    if [ -z "$prompt" ]; then
        echo "Usage: $(basename "$0") <prompt> [-o text]" >&2
        exit $_RWF_EXIT_USAGE
    fi

    local chars_in=${#prompt}

    # Normalize and validate seat
    local normalized_seat
    normalized_seat=$(_rwf_normalize_seat "${REVIEWER_SEAT:-}")

    if _rwf_is_forbidden_seat "$normalized_seat"; then
        cat >&2 <<'ERRMSG'
ERROR: This seat is forbidden on reviewer-with-fallback.sh.

  Seats containing "security" and "design-vote" require pro-tier models only.
  Use: source .claude/scripts/gemini-with-fallback.sh && gemini_with_fallback_strict "..." -o text

  Exit code: 64 (EX_USAGE)
ERRMSG
        exit $_RWF_EXIT_USAGE
    fi

    # ---------------------------------------------------------------------------
    # Provider chain: groq → cerebras → ollama → gemini
    # set -e is active; use || var=$? pattern to capture non-zero returns.
    # ---------------------------------------------------------------------------

    _rwf_load_env

    # Provider 1: Groq
    local groq_rc=0
    _rwf_try_groq "$prompt" || groq_rc=$?

    if [ $groq_rc -eq $_RWF_EXIT_BILLING ]; then
        _rwf_billing_banner "Groq"
        _rwf_log_spend "groq" "$_GROQ_MODEL" "$chars_in" 0 $_RWF_EXIT_BILLING
        exit $_RWF_EXIT_BILLING
    fi

    if [ $groq_rc -eq 0 ]; then
        echo "$_RWF_OUTPUT"
        exit $_RWF_EXIT_OK
    fi

    _rwf_degraded_banner "groq" "cerebras" "$_RWF_OUTPUT"
    _rwf_log_spend "groq" "$_GROQ_MODEL" "$chars_in" 0 "$groq_rc"

    # Provider 2: Cerebras (same gpt-oss-120b, free-tier failover for Groq).
    # ANY non-zero return degrades to ollama — incl. billing/quota: a free
    # supplementary seat must never abort the run (unlike Groq's terminal exit).
    local cerebras_rc=0
    _rwf_try_cerebras "$prompt" || cerebras_rc=$?

    if [ $cerebras_rc -eq 0 ]; then
        echo "$_RWF_OUTPUT"
        exit $_RWF_EXIT_OK
    fi

    _rwf_degraded_banner "cerebras" "ollama" "$_RWF_OUTPUT"
    _rwf_log_spend "cerebras" "$_CEREBRAS_MODEL" "$chars_in" 0 "$cerebras_rc"

    # Provider 3: Ollama
    local ollama_rc=0
    _rwf_try_ollama "$prompt" || ollama_rc=$?

    if [ $ollama_rc -eq 0 ]; then
        echo "$_RWF_OUTPUT"
        exit $_RWF_EXIT_OK
    fi

    _rwf_degraded_banner "ollama" "gemini" "$_RWF_OUTPUT"
    _rwf_log_spend "ollama" "$_OLLAMA_MODEL" "$chars_in" 0 "$ollama_rc"

    # Provider 4: Gemini (investigation seat tier, pinned model)
    local gemini_rc=0
    _rwf_try_gemini "$prompt" "${extra_args[@]+"${extra_args[@]}"}" || gemini_rc=$?

    if [ $gemini_rc -eq $_RWF_EXIT_BILLING ]; then
        _rwf_billing_banner "Gemini"
        exit $_RWF_EXIT_BILLING
    fi

    if [ $gemini_rc -eq 0 ]; then
        echo "$_RWF_OUTPUT"
        exit $_RWF_EXIT_OK
    fi

    if [ $gemini_rc -eq $_RWF_EXIT_QUOTA ]; then
        echo "✗ All providers exhausted (groq failed, cerebras failed/absent, ollama unavailable, gemini quota exhausted)." >&2
        exit $_RWF_EXIT_QUOTA
    fi

    # Real error from final provider — pass through, not 75
    echo "✗ All providers failed. Last error from gemini (rc=${gemini_rc}):" >&2
    echo "$_RWF_OUTPUT" >&2
    exit $gemini_rc
}

main "$@"
