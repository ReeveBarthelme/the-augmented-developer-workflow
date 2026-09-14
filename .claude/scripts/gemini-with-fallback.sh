#!/usr/bin/env bash
# =============================================================================
# gemini-with-fallback.sh — Hardened Gemini CLI wrapper with seat-tiered model
# pinning, billing-error detection (exit 78), quota detection (exit 75), and
# spend logging.
#
# SEAT ROUTING: if your project routes the `security` and `design-vote` seats
# to Claude and Codex instead of Gemini (see
# `.claude/skills/orchestrate-review-deploy/SKILL.md`), this wrapper and its
# `gemini_with_fallback_strict` pro-tier chain stay available for manual use.
#
# EXIT CODE CONTRACT (this IS the API):
#   0  = success
#   75 = quota exhausted (EX_TEMPFAIL) — wait-it-out
#   78 = billing/account failure — FAIL FAST, do NOT retry
#   other = real bug passthrough
#
# SPEND LOG:
#   Appends one JSON line per invocation to SPEND_LOG (default: ~/.gemini/spend.jsonl)
#   Override via env: export SPEND_LOG=/tmp/test-spend.jsonl
#
# SUBCOMMAND:
#   gemini-with-fallback.sh summarize [--days N]
#     Reads spend.jsonl and prints per-model + per-seat call counts and char totals.
#
# SEAT-TIERED MODEL PINS (env REVIEWER_SEAT selects tier) — GA models ONLY:
#   security     → gemini-3.5-flash (primary)      → gemini-3.1-flash-lite → exit 75
#   design-vote  → gemini-3.5-flash (primary)      → gemini-3.1-flash-lite → exit 75
#   investigation → gemini-3.1-flash-lite (primary) → gemini-3.5-flash     → exit 75
#   (default)    → gemini-3.5-flash (primary)      → gemini-3.1-flash-lite → exit 75
#   Three rules these pins encode, each learned the hard way:
#    1. Pin a REAL API model ID. A plausible-looking name the API does not serve
#       makes the CLI silently fall back to its own default, which burns a shared
#       free-tier bucket and turns any A/B into self-versus-self.
#    2. No -preview pins. Preview models get retired without notice, and one
#       measurably lost a fixed N=5 recall A/B against the GA flash model.
#    3. A retired model degrades to the next model in the chain with a loud
#       warning, never a hard seat failure. See _gemini_is_model_gone_error.
#   Verify every default pin against ListModels before changing it.)
#
# USAGE (source mode — two shell functions exported):
#   source .claude/scripts/gemini-with-fallback.sh
#   gemini_with_fallback "Your prompt here" -o text
#   gemini_with_fallback_strict "Security review prompt" -o text
#
# USAGE (subcommand mode):
#   bash .claude/scripts/gemini-with-fallback.sh summarize [--days N]
#
# Backward-compatible env var overrides (all seats unless overridden by seat logic):
#   GEMINI_PRIMARY_MODEL, GEMINI_FALLBACK_MODEL, GEMINI_LAST_RESORT_MODEL
# =============================================================================

# ---------------------------------------------------------------------------
# Exit code constants — guarded so sourcing twice under set -e is safe (m4)
# ---------------------------------------------------------------------------
if [ -z "${_GFB_EXIT_OK:-}" ]; then
    readonly _GFB_EXIT_OK=0
    readonly _GFB_EXIT_QUOTA=75
    readonly _GFB_EXIT_BILLING=78
fi

# ---------------------------------------------------------------------------
# Seat-tiered model selection — returns models one per line
# Never returns "auto" or "latest" as a model name.
# ---------------------------------------------------------------------------
_gemini_models_for_seat() {
    local seat="${1:-${REVIEWER_SEAT:-}}"
    case "$seat" in
        investigation)
            echo "${GEMINI_INVESTIGATION_PRIMARY:-gemini-3.1-flash-lite}"
            echo "${GEMINI_INVESTIGATION_FALLBACK:-gemini-3.5-flash}"
            ;;
        security|design-vote|*)
            echo "${GEMINI_PRIMARY_MODEL:-gemini-3.5-flash}"
            echo "${GEMINI_FALLBACK_MODEL:-gemini-3.1-flash-lite}"
            ;;
    esac
}

# Last-resort model (only used in non-strict full chain)
_gemini_last_resort_for_seat() {
    echo "${GEMINI_LAST_RESORT_MODEL:-gemini-3.5-flash}"
}

# ---------------------------------------------------------------------------
# Spend-log field sanitizer — strips characters that break JSON string values.
# Allows: alphanumeric, dot, hyphen, underscore, colon, slash (for model IDs).
# Applied to seat and run_id before printf interpolation (M4/m4).
# ---------------------------------------------------------------------------
_gemini_sanitize_field() {
    printf '%s' "$1" | tr -cd '[:alnum:]._/:+-'
}

# ---------------------------------------------------------------------------
# Error classification helpers — ONLY called on FAILED invocations (M1/m5).
# Never pass successful output to these functions.
# ---------------------------------------------------------------------------
_gemini_is_billing_error() {
    local output="$1"
    local exit_code="$2"
    [ "$exit_code" -ne 0 ] || return 1
    # Billing-specific markers only — does NOT match bare PERMISSION_DENIED
    # so that IAM model-level denials are not misclassified as billing (m8).
    # `payment.*required` added to match _rwf_is_billing_error in
    # reviewer-with-fallback.sh (regex-parity drift found in review; the two
    # classifiers must stay semantically identical — see m9 test below).
    echo "$output" | grep -qiE \
        'billing.*(disabled|suspended|blocked|invalid|not_enabled|not enabled)|PERMISSION_DENIED.*billing|billing.*PERMISSION_DENIED|consumer.*has been suspended|project.*billing.*disabled|billing_not_enabled|payment.*required'
}

_gemini_is_quota_error() {
    local output="$1"
    local exit_code="$2"
    [ "$exit_code" -ne 0 ] || return 1
    echo "$output" | grep -qiE \
        'quota|rate.limit|resource.exhausted|429|RESOURCE_EXHAUSTED|daily.limit|RPD|TPD'
}

# Model retired/nonexistent (2026-07-10): gemini-3-pro-preview died with "no
# longer available" and a hard error stopped the whole chain — a phase-out must
# DEGRADE to the next pinned model (with a loud warning), not kill the seat.
_gemini_is_model_gone_error() {
    local output="$1"
    local exit_code="$2"
    [ "$exit_code" -ne 0 ] || return 1
    echo "$output" | grep -qiE \
        'is not found for API version|no longer available|ModelNotFoundError'
}

# ---------------------------------------------------------------------------
# Billing failure banner — loud, multi-line, to stderr
# ---------------------------------------------------------------------------
_gemini_billing_banner() {
    cat >&2 <<'BANNER'

================================================================================
🚨 BILLING FAILURE — GCP billing account is broken; ALL Gemini seats are down.

  This is NOT a quota wait-it-out error. You must fix billing before retrying.

  Fix at: console.cloud.google.com/billing
  Check:  gcloud beta billing projects describe $(gcloud config get project)

  Until billing is restored, ALL Gemini reviewer seats will fail with exit 78.
================================================================================

BANNER
}

# ---------------------------------------------------------------------------
# Spend log helper — appends one JSON line; never logs secrets.
# seat and run_id are sanitized before interpolation (M4).
# ---------------------------------------------------------------------------
_gemini_log_spend() {
    local model
    model=$(_gemini_sanitize_field "$1")   # env-overridable model names must not break JSON
    local chars_in="$2"
    local chars_out="$3"
    local exit_code="$4"
    local provider="${5:-gemini}"
    local seat_override="${6:-}"   # optional: override REVIEWER_SEAT (used by strict)

    local raw_seat="${seat_override:-${REVIEWER_SEAT:-unknown}}"
    local raw_run_id="${REVIEWER_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
    local seat
    seat=$(_gemini_sanitize_field "$raw_seat")
    local run_id
    run_id=$(_gemini_sanitize_field "$raw_run_id")
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

    local log_file="${SPEND_LOG:-${HOME}/.gemini/spend.jsonl}"
    local log_dir
    log_dir=$(dirname "$log_file")
    mkdir -p "$log_dir" 2>/dev/null || true
    chmod 700 "$log_dir" 2>/dev/null || true

    # No secrets: model, seat, run_id, timing, char counts, exit code, provider,
    # key-tier provenance (paid|ambient) only — never key material.
    printf '{"ts":"%s","model":"%s","seat":"%s","run_id":"%s","chars_in":%d,"chars_out":%d,"exit_code":%d,"provider":"%s","key":"%s"}\n' \
        "$ts" "$model" "$seat" "$run_id" \
        "$chars_in" "$chars_out" "$exit_code" "$provider" \
        "$(_gemini_sanitize_field "${_GFB_KEY_SOURCE:-ambient}")" \
        >> "$log_file" 2>/dev/null || true
    chmod 600 "$log_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# @-token shield — the Gemini CLI's @path include feature rewrites the literal
# token `@-` (curl's read-body-from-stdin idiom) into a resolved repo file
# path BEFORE the model sees the prompt (proven in a prior incident: `-d @-`
# arrived as `-d @scripts/staging-chat.sh` in a prompt that never mentioned
# that file, producing identical phantom findings from two different models).
# When a prompt contains `@-`, substitute the placeholder [AT-DASH] and
# prepend a preamble telling the model how to read it. Prompts without `@-`
# pass through untouched (intentional @file includes keep working).
# Disable entirely with GEMINI_NO_AT_SHIELD=1.
# ---------------------------------------------------------------------------
_gemini_shield_at_tokens() {
    local prompt="$1"
    if [ -n "${GEMINI_NO_AT_SHIELD:-}" ] || [[ "$prompt" != *"@-"* ]]; then
        printf '%s' "$prompt"
        return 0
    fi
    # The sentinel must not pre-exist in the prompt (user text would be misread
    # as the token) — uniquify on collision (Codex review, this PR).
    local sentinel="[AT-DASH]"
    while [[ "$prompt" == *"$sentinel"* ]]; do
        sentinel="[AT-DASH-${RANDOM}]"
    done
    # The preamble must NOT itself contain the raw token — it would be rewritten
    # by the same CLI preprocessor the shield defends against (Codex review).
    local preamble
    preamble="NOTE ON ENCODING: the placeholder ${sentinel} below stands for a \
literal at-sign character followed immediately by a hyphen (curl's \
read-body-from-stdin form). It was substituted because the CLI harness \
rewrites that token into a file path. Read every ${sentinel} as those two \
verbatim characters."
    printf '%s\n\n%s' "$preamble" "${prompt//@-/${sentinel}}"
}

# ---------------------------------------------------------------------------
# Core single-model invocation with error classification.
# Sets global _GFB_OUTPUT to captured output.
# Returns: 0 (success), 75 (quota), 78 (billing), other (real error)
#
# IMPORTANT: error classifiers are ONLY called on failed (rc!=0) invocations.
# Successful output is never scanned for error keywords (M1/m5 dead-code fix).
# ---------------------------------------------------------------------------
_gemini_invoke_model() {
    local model="$1"
    local prompt="$2"
    shift 2
    local extra_args=("$@")

    prompt=$(_gemini_shield_at_tokens "$prompt")

    local output
    output=$(gemini "$prompt" -m "$model" "${extra_args[@]}" 2>&1)
    local rc=$?
    _GFB_OUTPUT="$output"

    # Success path: rc=0 → return immediately, NEVER scan output for errors (M1)
    if [ $rc -eq 0 ]; then
        return 0
    fi

    # Billing errors take priority over quota errors (billing is a 403 subcategory).
    # Non-billing 403s (IAM model-level permission denied) must NOT match here (m8).
    if _gemini_is_billing_error "$output" "$rc"; then
        return "$_GFB_EXIT_BILLING"
    fi

    # Retired/nonexistent model → degrade to the next chain model (returns the
    # quota code so both callers' loops continue), with a loud pin-rot warning.
    if _gemini_is_model_gone_error "$output" "$rc"; then
        echo "⚠ model '$model' not found/retired on this API — likely deprecated; update the pins in .claude/scripts/gemini-with-fallback.sh" >&2
        return "$_GFB_EXIT_QUOTA"
    fi

    if _gemini_is_quota_error "$output" "$rc"; then
        return "$_GFB_EXIT_QUOTA"
    fi

    # Real error — pass through original exit code (m3)
    return $rc
}

# ---------------------------------------------------------------------------
# Extract ONE named key from an env file without executing it (mirrors
# _rwf_extract_key in reviewer-with-fallback.sh — m9 schema consistency).
# Never sources: a repo/worktree-controlled .env is not trusted as shell
# input. $1 = var name, $2 = env file.
# ---------------------------------------------------------------------------
_gemini_extract_key() {
    local var_name="$1" env_file="$2"
    local key
    key=$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${var_name}=" "$env_file" 2>/dev/null) || return 0
    key="${key#*=}"
    key="${key%$'\r'}"
    # Quoted values: take exactly the content between the opening quote and
    # its matching closing quote, so a trailing `# comment` after the quote
    # is dropped rather than absorbed into the key. Unquoted values: cut at
    # the first whitespace for the same reason.
    if [[ "$key" == \"*\"* ]]; then
        key="${key#\"}"; key="${key%%\"*}"
    elif [[ "$key" == \'*\'* ]]; then
        key="${key#\'}"; key="${key%%\'*}"
    else
        key="${key%%[[:space:]]*}"
    fi
    printf '%s' "$key"
}

# ---------------------------------------------------------------------------
# Load .env if API key not set (backward compat)
#
# Key routing (2026-07-10): wrapper calls carry proprietary code diffs, and
# Google's FREE Gemini API tier may use prompts for model training (paid tier
# does not). If GEMINI_API_KEY_PAID is set (a key from a second, billing-enabled
# GCP project), the wrapper prefers it — reviews run on the no-training paid
# tier (~$0.02/review at gemini-3-flash rates) while the plain free key stays
# the default for ad-hoc `gemini` web research. Inert until the paid key exists.
# ---------------------------------------------------------------------------
_gemini_load_env() {
    # Non-executing parse only — Codex round-2 iter-2 [MAJOR]: the legacy
    # `set -a; source .env; set +a` here ran every command in a
    # repo/worktree-controlled .env whenever GEMINI_API_KEY was unset (e.g.
    # a model-canary script's scored runs, which deliberately strip keys
    # before calling this function) — the exact class of hole already fixed
    # one call site down for GEMINI_API_KEY_PAID. The wrapper now reads ONLY
    # these two keys from .env; no other var is ambiently loaded any more —
    # that's intentional.
    if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then
        local dotenv_key
        dotenv_key=$(_gemini_extract_key GEMINI_API_KEY .env)
        [ -n "$dotenv_key" ] && export GEMINI_API_KEY="$dotenv_key"
    fi
    # An exported ambient GEMINI_API_KEY skips the .env load above, which
    # made a paid key living only in .env invisible — reviews silently ran
    # on the trainable ambient tier. Pull just GEMINI_API_KEY_PAID from .env
    # via the same non-executing parse.
    if [ -z "${GEMINI_API_KEY_PAID:-}" ] && [ -f .env ]; then
        GEMINI_API_KEY_PAID=$(_gemini_extract_key GEMINI_API_KEY_PAID .env)
    fi
    # Key-tier provenance: recorded in every spend line ("key":"paid"|"ambient")
    # so "reviews never run on a trainable tier" is auditable, not asserted.
    # Exported so child shells (e.g. a model-canary script's scored runs)
    # can re-derive paid provenance instead of defaulting to ambient (Codex
    # round-2 iter-2 [MINOR]).
    if [ -n "${GEMINI_API_KEY_PAID:-}" ]; then
        export GEMINI_API_KEY="$GEMINI_API_KEY_PAID"
        export GEMINI_API_KEY_PAID
        _GFB_KEY_SOURCE="paid"
    else
        _GFB_KEY_SOURCE="ambient"
    fi
}

# ---------------------------------------------------------------------------
# gemini_with_fallback — full fallback chain
# Tries seat-tiered models in order, then last-resort flash as final step.
# ---------------------------------------------------------------------------
gemini_with_fallback() {
    local prompt="$1"
    shift
    local extra_args=("$@")
    local chars_in=${#prompt}

    _gemini_load_env

    # Collect seat-tiered model chain
    local seat_models=()
    while IFS= read -r m; do
        seat_models+=("$m")
    done < <(_gemini_models_for_seat)

    local last_resort
    last_resort=$(_gemini_last_resort_for_seat)

    # Build full chain: seat models + last resort, deduped against EVERY seat
    # model — comparing only the last one re-queued the exhausted primary
    # (default seats: 3.5-flash → 3.1-flash-lite → 3.5-flash again).
    local full_chain=("${seat_models[@]}")
    if [ -n "$last_resort" ]; then
        local already_in_chain=false
        local m
        for m in "${seat_models[@]}"; do
            if [ "$m" = "$last_resort" ]; then already_in_chain=true; break; fi
        done
        if [ "$already_in_chain" = false ]; then
            full_chain+=("$last_resort")
        fi
    fi

    local attempt_rc
    local last_tried_model="unknown"
    for model in "${full_chain[@]}"; do
        echo "▸ Trying Gemini model: $model (seat: ${REVIEWER_SEAT:-unknown})" >&2
        last_tried_model="$model"
        _gemini_invoke_model "$model" "$prompt" "${extra_args[@]}"
        attempt_rc=$?

        if [ $attempt_rc -eq "$_GFB_EXIT_BILLING" ]; then
            _gemini_billing_banner
            echo "$_GFB_OUTPUT"
            _gemini_log_spend "$model" "$chars_in" 0 "$_GFB_EXIT_BILLING"
            return "$_GFB_EXIT_BILLING"
        fi

        if [ $attempt_rc -eq 0 ]; then
            echo "$_GFB_OUTPUT"
            _gemini_log_spend "$model" "$chars_in" "${#_GFB_OUTPUT}" 0
            return 0
        fi

        if [ $attempt_rc -ne "$_GFB_EXIT_QUOTA" ]; then
            # Real error passthrough (m3: do NOT collapse to 75)
            echo "$_GFB_OUTPUT"
            _gemini_log_spend "$model" "$chars_in" 0 "$attempt_rc"
            return $attempt_rc
        fi

        echo "⚠ $model quota exhausted — trying next model" >&2
    done

    # All models exhausted
    _gemini_log_spend "$last_tried_model" "$chars_in" 0 "$_GFB_EXIT_QUOTA"
    return "$_GFB_EXIT_QUOTA"
}

# ---------------------------------------------------------------------------
# gemini_with_fallback_strict — pro-only chain; ALWAYS uses security-tier models
# regardless of REVIEWER_SEAT env (M2). Logs seat="security" in spend.jsonl.
# Fails closed (no last-resort). Returns 75 (quota) or 78 (billing).
# ---------------------------------------------------------------------------
gemini_with_fallback_strict() {
    local prompt="$1"
    shift
    local extra_args=("$@")
    local chars_in=${#prompt}

    _gemini_load_env

    # ALWAYS use security tier, ignoring ambient REVIEWER_SEAT (M2)
    local seat_models=()
    while IFS= read -r m; do
        seat_models+=("$m")
    done < <(_gemini_models_for_seat "security")

    local attempt_rc
    local last_tried_strict="unknown"
    for model in "${seat_models[@]}"; do
        echo "▸ [strict] Trying Gemini model: $model (seat: security)" >&2
        last_tried_strict="$model"
        _gemini_invoke_model "$model" "$prompt" "${extra_args[@]}"
        attempt_rc=$?

        if [ $attempt_rc -eq "$_GFB_EXIT_BILLING" ]; then
            _gemini_billing_banner
            echo "$_GFB_OUTPUT"
            _gemini_log_spend "$model" "$chars_in" 0 "$_GFB_EXIT_BILLING" "gemini" "security"
            return "$_GFB_EXIT_BILLING"
        fi

        if [ $attempt_rc -eq 0 ]; then
            echo "$_GFB_OUTPUT"
            _gemini_log_spend "$model" "$chars_in" "${#_GFB_OUTPUT}" 0 "gemini" "security"
            return 0
        fi

        if [ $attempt_rc -ne "$_GFB_EXIT_QUOTA" ]; then
            echo "$_GFB_OUTPUT"
            _gemini_log_spend "$model" "$chars_in" 0 "$attempt_rc" "gemini" "security"
            return $attempt_rc
        fi

        echo "⚠ [strict] $model quota exhausted — trying next model" >&2
    done

    # Fail closed: no last-resort for strict mode
    echo "✗ [strict] All pro-tier Gemini models exhausted. Failing closed." >&2
    _gemini_log_spend "$last_tried_strict" "$chars_in" 0 "$_GFB_EXIT_QUOTA" "gemini" "security"
    return "$_GFB_EXIT_QUOTA"
}

# ---------------------------------------------------------------------------
# summarize subcommand — print spend report to stdout
# Skips lines with corrupt numeric fields rather than crashing (M5).
# ---------------------------------------------------------------------------
_gemini_summarize() {
    local days="${1:-}"
    local log_file="${SPEND_LOG:-${HOME}/.gemini/spend.jsonl}"

    if [ ! -f "$log_file" ]; then
        echo "No spend data found (${log_file} does not exist)"
        return 0
    fi

    python3 - "$log_file" "$days" <<'PYEOF'
import sys, json, collections

log_file = sys.argv[1]
days_str = sys.argv[2] if len(sys.argv) > 2 else ""

cutoff = ""
if days_str:
    try:
        import datetime
        days_int = int(days_str)
        cutoff = (datetime.datetime.utcnow() - datetime.timedelta(days=days_int)).strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        pass

by_model = collections.defaultdict(lambda: {"calls": 0, "chars_in": 0, "chars_out": 0})
by_seat  = collections.defaultdict(lambda: {"calls": 0, "chars_in": 0, "chars_out": 0})
fallback = {}
total = 0
skipped = 0
corrupt = 0

try:
    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                corrupt += 1
                continue

            ts = entry.get("ts", "")
            if cutoff and ts < cutoff:
                skipped += 1
                continue

            model = entry.get("model", "unknown")
            seat  = entry.get("seat", "unknown")
            # M5: per-field try/except — corrupt numeric fields skip the row
            try:
                ci = int(entry.get("chars_in", 0))
                co = int(entry.get("chars_out", 0))
            except (ValueError, TypeError):
                corrupt += 1
                continue

            by_model[model]["calls"]     += 1
            by_model[model]["chars_in"]  += ci
            by_model[model]["chars_out"] += co

            by_seat[seat]["calls"]     += 1
            by_seat[seat]["chars_in"]  += ci
            by_seat[seat]["chars_out"] += co

            # Fallback-rate tracking: exit 75 = seat lost to quota (T5, Jul 10)
            try:
                ec = int(entry.get("exit_code", 0))
            except (ValueError, TypeError):
                ec = 0
            seat_totals = fallback.setdefault(seat, {"calls": 0, "exit75": 0, "paid": 0})
            seat_totals["calls"] += 1
            if ec == 75:
                seat_totals["exit75"] += 1
            if entry.get("key") == "paid":
                seat_totals["paid"] += 1

            total += 1
except FileNotFoundError:
    print("No spend data found")
    sys.exit(0)

if total == 0:
    msg = "0 entries in spend log"
    if skipped:
        msg += f" (after cutoff; {skipped} older entries skipped)"
    if corrupt:
        msg += f" ({corrupt} corrupt lines skipped)"
    print(msg)
    sys.exit(0)

extras = []
if skipped:
    extras.append(f"{skipped} older entries skipped")
if corrupt:
    extras.append(f"{corrupt} corrupt lines skipped")
label = (", " + ", ".join(extras)) if extras else ""
print(f"\n=== Gemini Spend Summary ({total} entries{label}) ===\n")

print("By Model:")
print(f"  {'Model':<35} {'Calls':>6} {'Chars-In':>12} {'Chars-Out':>12}")
print(f"  {'-'*35} {'-'*6} {'-'*12} {'-'*12}")
for m, d in sorted(by_model.items()):
    print(f"  {m:<35} {d['calls']:>6} {d['chars_in']:>12,} {d['chars_out']:>12,}")

print("\nBy Seat:")
print(f"  {'Seat':<20} {'Calls':>6} {'Chars-In':>12} {'Chars-Out':>12}")
print(f"  {'-'*20} {'-'*6} {'-'*12} {'-'*12}")
for s, d in sorted(by_seat.items()):
    print(f"  {s:<20} {d['calls']:>6} {d['chars_in']:>12,} {d['chars_out']:>12,}")

print("\nSeat Health (exit-75 = seat lost to quota/fallback; paid = no-training key):")
print(f"  {'Seat':<20} {'Calls':>6} {'Exit-75':>8} {'Fallback%':>10} {'Paid-key%':>10}")
print(f"  {'-'*20} {'-'*6} {'-'*8} {'-'*10} {'-'*10}")
for s, d in sorted(fallback.items()):
    fb_pct = 100.0 * d["exit75"] / d["calls"] if d["calls"] else 0.0
    paid_pct = 100.0 * d["paid"] / d["calls"] if d["calls"] else 0.0
    print(f"  {s:<20} {d['calls']:>6} {d['exit75']:>8} {fb_pct:>9.0f}% {paid_pct:>9.0f}%")

print()
PYEOF
}

# ---------------------------------------------------------------------------
# Subcommand dispatch when the script is executed directly (not sourced)
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        summarize)
            shift
            _days=""
            if [[ "${1:-}" == "--days" && -n "${2:-}" ]]; then
                _days="$2"
            fi
            _gemini_summarize "$_days"
            ;;
        *)
            echo "Usage: $(basename "$0") summarize [--days N]" >&2
            exit 1
            ;;
    esac
fi
