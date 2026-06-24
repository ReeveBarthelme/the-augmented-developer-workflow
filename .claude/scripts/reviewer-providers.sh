#!/usr/bin/env bash
# =============================================================================
# reviewer-providers.sh — provider-attempt functions for reviewer-with-fallback.sh
#
# LIBRARY ONLY — sourced by reviewer-with-fallback.sh; defines no top-level
# state and runs no main(). Functions here resolve their shared helpers
# (_rwf_is_billing_error, _rwf_is_invalid_key_error, _rwf_log_spend), config
# vars (_GROQ_*, _CEREBRAS_*, _OLLAMA_MODEL, _GEMINI_WRAPPER), exit-code
# constants (_RWF_EXIT_BILLING) and _RWF_OUTPUT at CALL time from the parent
# script, so the source order in the parent does not matter.
# =============================================================================

# ---------------------------------------------------------------------------
# Shared OpenAI-compatible provider (Groq + Cerebras both serve gpt-oss-120b).
# Args: provider key model url keyvar prompt. Thin wrappers below bind each seat.
#
# Response handling:
#   SUCCESS = HTTP 200 AND choices[0].message.content is a non-empty trimmed string.
#   Successful content is NEVER keyword-scanned.
#   Error classification runs ONLY on the error path (non-200, curl failure,
#   missing/empty choices, malformed JSON).
#
# Uses jq for both building the request payload and parsing the response (jq is
# the only JSON dependency — avoids prompt-injection risk from shell-built JSON).
#
# HTTP error classification:
#   401/invalid-key → loud banner + fall through to next provider (config bug)
#   429/quota/rate-limit → transient, degrade
#   billing patterns → terminal (exit 78)
#   5xx/timeout/network → transient, degrade
#   empty/malformed choices → provider failure, degrade
#
# Returns: 0 (success), 78 (billing terminal), other (degrade)
# Sets _RWF_OUTPUT to content on success, error message on failure.
# ---------------------------------------------------------------------------
_rwf_try_openai_compatible() {
    local provider="$1" key="$2" model="$3" url="$4" keyvar="$5" prompt="$6"
    local chars_in=${#prompt}

    if [ -z "$key" ]; then
        _RWF_OUTPUT="${keyvar} not set"
        return 1
    fi

    # Build JSON payload safely using jq (avoids prompt-injection risk)
    local payload
    if ! payload=$(jq -n --arg model "$model" --arg content "$prompt" \
        '{"model":$model,"messages":[{"role":"user","content":$content}]}' 2>/dev/null); then
        # jq failed — fail this provider, degrade to next
        _RWF_OUTPUT="jq payload construction failed"
        return 1
    fi

    # Capture HTTP status code separately from body using -w / -o.
    # mktemp: unpredictable names + 0600 perms (review finding: a literal
    # "${SPEND_LOG%/*}" with SPEND_LOG unset resolved to the unwritable root dir).
    local body_file stderr_file
    body_file=$(mktemp "${TMPDIR:-/tmp}/${provider}_body.XXXXXX") || return 1
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/${provider}_stderr.XXXXXX") || { rm -f "$body_file"; return 1; }
    local http_status
    local curl_rc=0
    http_status=$(curl -sS --max-time 60 \
        -X POST "$url" \
        -H "Authorization: Bearer ${key}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -o "$body_file" \
        -w '%{http_code}' \
        2>"$stderr_file") || curl_rc=$?

    local body=""
    local curl_stderr=""
    [ -f "$body_file" ] && body=$(cat "$body_file")
    [ -f "$stderr_file" ] && curl_stderr=$(cat "$stderr_file")
    rm -f "$body_file" "$stderr_file" 2>/dev/null || true

    # Network/timeout failure (curl non-zero, no HTTP status)
    if [ $curl_rc -ne 0 ]; then
        local err_output="${curl_stderr}${body}"
        _RWF_OUTPUT="curl failed (rc=${curl_rc}): ${err_output}"
        if _rwf_is_billing_error "$err_output" 1; then
            return $_RWF_EXIT_BILLING
        fi
        return $curl_rc
    fi

    # HTTP error path — classify by status + body (only on error path)
    if [ "$http_status" != "200" ]; then
        local err_combined="${curl_stderr}${body}"
        _RWF_OUTPUT="HTTP ${http_status}: ${body}"

        if _rwf_is_billing_error "$err_combined" 1; then
            return $_RWF_EXIT_BILLING
        fi

        if _rwf_is_invalid_key_error "$err_combined" 1 || [ "$http_status" = "401" ]; then
            # 401 = config bug — loud banner but FALL THROUGH (not terminal billing)
            printf '\n⚠️  INVALID API KEY — %s is set but rejected (HTTP 401).\n   This is a configuration error. Check your %s value.\n   Falling through to next provider.\n\n' "$keyvar" "$keyvar" >&2
            return 1
        fi

        # 429, 5xx, other → transient, degrade
        return 1
    fi

    # HTTP 200 — parse choices from response body with jq (SUCCESS PATH, no keyword scan).
    # jq is the only JSON dependency (same tool used to build the payload above).
    local content=""
    content=$(printf '%s' "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || content=""
    # Empty/missing choices, malformed JSON, or whitespace-only content → degrade, not success.
    if [ -z "$content" ] || [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]; then
        _RWF_OUTPUT="${provider} HTTP 200 but no valid content: ${body}"
        return 1
    fi

    # Genuine success — return content without scanning it
    _RWF_OUTPUT="$content"
    _rwf_log_spend "$provider" "$model" "$chars_in" "${#content}" 0
    return 0
}

# Thin wrapper: Groq seat (terminal billing — see main()).
_rwf_try_groq() {
    _rwf_try_openai_compatible groq "${GROQ_API_KEY:-}" "$_GROQ_MODEL" "$_GROQ_API_URL" GROQ_API_KEY "$1"
}

# Thin wrapper: Cerebras seat — SAME gpt-oss-120b, free-tier N+1 redundancy for
# Groq. ⚠️ Free tier caps context at ~8,192 tokens (large prompts truncate),
# hence it sits AFTER Groq. Its failures (incl. billing/quota) DEGRADE rather
# than abort — a free supplementary seat must never kill the run (see main()).
_rwf_try_cerebras() {
    _rwf_try_openai_compatible cerebras "${CEREBRAS_API_KEY:-}" "$_CEREBRAS_MODEL" "$_CEREBRAS_API_URL" CEREBRAS_API_KEY "$1"
}

# ---------------------------------------------------------------------------
# Provider 3: Ollama (local, qwen3-coder)
# Returns: 0 (success), other (failure/unavailable)
# Sets _RWF_OUTPUT to captured output.
# ---------------------------------------------------------------------------
_rwf_try_ollama() {
    local prompt="$1"
    local chars_in=${#prompt}

    if ! command -v ollama >/dev/null 2>&1; then
        _RWF_OUTPUT="ollama not found in PATH"
        return 1
    fi

    if ! ollama list 2>/dev/null | grep -q "$_OLLAMA_MODEL"; then
        _RWF_OUTPUT="ollama model ${_OLLAMA_MODEL} not available"
        return 1
    fi

    local output
    local rc=0
    output=$(ollama run "$_OLLAMA_MODEL" "$prompt" 2>&1) || rc=$?
    _RWF_OUTPUT="$output"

    if [ $rc -eq 0 ]; then
        _rwf_log_spend "ollama" "$_OLLAMA_MODEL" "$chars_in" "${#output}" 0
        return 0
    fi

    return $rc
}

# ---------------------------------------------------------------------------
# Provider 4: Gemini via gemini-with-fallback.sh (investigation seat tier)
# Does NOT pass -m: the wrapper supplies its own seat-tiered -m, so an extra
# -m here produced a duplicate flag. Instead, REVIEWER_SEAT is
# forced to "investigation" in the child env so the wrapper's seat-tier logic
# picks gemini-3-flash itself and logs the correct model/seat in spend.jsonl.
# GEMINI_INVESTIGATION_PRIMARY still overrides the pin (test injection).
# Returns: 0 (success), 75 (quota), 78 (billing), other (error)
# Sets _RWF_OUTPUT to captured output.
# ---------------------------------------------------------------------------
_rwf_try_gemini() {
    local prompt="$1"
    shift
    local extra_args=("$@")

    if [ ! -f "$_GEMINI_WRAPPER" ]; then
        _RWF_OUTPUT="gemini-with-fallback.sh not found at ${_GEMINI_WRAPPER}"
        return 1
    fi

    local output
    local rc=0
    output=$(
        SPEND_LOG="${SPEND_LOG:-${HOME}/.gemini/spend.jsonl}" \
        REVIEWER_SEAT="investigation" \
        bash -c "source \"\$1\"; gemini_with_fallback \"\$2\" \"\${@:3}\"" \
            -- "$_GEMINI_WRAPPER" "$prompt" \
            "${extra_args[@]+"${extra_args[@]}"}"
    ) || rc=$?
    _RWF_OUTPUT="$output"

    return $rc
}
