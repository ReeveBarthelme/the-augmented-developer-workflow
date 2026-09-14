#!/usr/bin/env bash
# delegation-scorecard.sh — Report-only view of the delegation metrics
# collected by .claude/hooks/delegation-track.sh + agent-spawn-capture.sh.
#
# Usage: delegation-scorecard.sh [SESSION_ID] [--month YYYY-MM]
#   SESSION_ID defaults to the session_id of the last event line in the
#   target month's file. --month defaults to the current UTC month.
#
# This is a report, not a gate: every success path (including "no data
# found") exits 0. All JSONL parsing is defensive (`jq -R 'fromjson? //
# empty'`) so a torn line never crashes the script.
set -u

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

LIB="${CLAUDE_PROJECT_DIR:-}/.claude/scripts/delegation-lib.sh"
[ -f "$LIB" ] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/delegation-lib.sh"
if [ -f "$LIB" ]; then
    # shellcheck disable=SC1090
    source "$LIB" 2>/dev/null
fi
command -v dlg_metrics_dir >/dev/null 2>&1 || { echo "delegation-lib.sh not found or failed to source" >&2; exit 1; }

# --- args ---
SESSION_ID=""
MONTH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --month)
            shift
            if [ $# -gt 0 ]; then
                MONTH="$1"
                shift
            fi
            ;;
        --month=*)
            MONTH="${1#--month=}"
            shift
            ;;
        *)
            [ -n "$SESSION_ID" ] || SESSION_ID="$1"
            shift
            ;;
    esac
done
[ -n "$MONTH" ] || MONTH="$(date -u +%Y-%m)"

METRICS_DIR="$(dlg_metrics_dir)"
MONTH_FILE="$METRICS_DIR/delegation-$MONTH.jsonl"

SKIP_SESSION_REPORT=""

if [ ! -s "$MONTH_FILE" ]; then
    echo "No delegation events recorded for $MONTH."
    SKIP_SESSION_REPORT=1
fi

if [ -z "${SKIP_SESSION_REPORT:-}" ]; then
    EVENTS_JSON=$(jq -R 'fromjson? // empty' "$MONTH_FILE" 2>/dev/null | jq -s '[.[] | select(type == "object")]' 2>/dev/null)
    [ -n "$EVENTS_JSON" ] || EVENTS_JSON="[]"
    if [ "$(printf '%s' "$EVENTS_JSON" | jq 'length' 2>/dev/null || echo 0)" = "0" ]; then
        echo "No delegation events recorded for $MONTH."
        SKIP_SESSION_REPORT=1
    fi
fi

if [ -z "${SKIP_SESSION_REPORT:-}" ]; then
    if [ -z "$SESSION_ID" ]; then
        SESSION_ID=$(printf '%s' "$EVENTS_JSON" | jq -r '.[-1].session_id // empty' 2>/dev/null)
    fi
    if [ -z "$SESSION_ID" ]; then
        echo "No delegation events recorded for $MONTH."
        SKIP_SESSION_REPORT=1
    fi
fi

if [ -z "${SKIP_SESSION_REPORT:-}" ]; then
    SESSION_EVENTS=$(printf '%s' "$EVENTS_JSON" | jq --arg s "$SESSION_ID" '[.[] | select(.session_id == $s)]' 2>/dev/null)
    [ -n "$SESSION_EVENTS" ] || SESSION_EVENTS="[]"
    SESSION_EVENT_COUNT=$(printf '%s' "$SESSION_EVENTS" | jq 'length' 2>/dev/null || echo 0)

    if [ "$SESSION_EVENT_COUNT" = "0" ]; then
        echo "No delegation events recorded for session ${SESSION_ID} in $MONTH."
        SKIP_SESSION_REPORT=1
    fi
fi

if [ -z "${SKIP_SESSION_REPORT:-}" ]; then
    # --- header ---
    SHORT_SID="${SESSION_ID:0:8}"
    SESSION_DATE=$(printf '%s' "$SESSION_EVENTS" | jq -r '.[0].ts // empty' 2>/dev/null | cut -dT -f1)
    [ -n "$SESSION_DATE" ] || SESSION_DATE="unknown"
    SESSION_WORKTREE=$(printf '%s' "$SESSION_EVENTS" | jq -r '
        [.[] | .worktree // "unknown"] | group_by(.) | max_by(length) | .[0] // "unknown"
    ' 2>/dev/null)
    [ -n "$SESSION_WORKTREE" ] || SESSION_WORKTREE="unknown"

    HEADER="Delegation Scorecard — session ${SHORT_SID} (${SESSION_DATE}, worktree: ${SESSION_WORKTREE})"
    echo "$HEADER"
    printf '%*s\n' "${#HEADER}" '' | tr ' ' '='

    # --- main-loop source edits ---
    MAIN_SOURCE_COUNT=$(printf '%s' "$SESSION_EVENTS" | jq '[.[] | select(.origin=="main" and .source==true)] | length' 2>/dev/null || echo 0)
    [ -n "$MAIN_SOURCE_COUNT" ] || MAIN_SOURCE_COUNT=0

    MAIN_SOURCE_DETAIL=$(printf '%s' "$SESSION_EVENTS" | jq -r '
        [.[] | select(.origin=="main" and .source==true)] as $ev
        | if ($ev|length) == 0 then "none"
          else
            ( [$ev[].tool] | reduce .[] as $t ([]; if index($t) then . else . + [$t] end)
              | map(. as $t | "\($t) x\([$ev[] | select(.tool==$t)] | length)")
              | join(", ") ) as $tools
            | ( [$ev[].file] | reduce .[] as $f ([]; if index($f) then . else . + [$f] end) ) as $files
            | ( $files[0:5] | join(", ") ) as $shown
            | ( if ($files|length) > 5 then " +\(($files|length) - 5) more" else "" end ) as $more
            | "\($tools): \($shown)\($more)"
          end
    ' 2>/dev/null)
    [ -n "$MAIN_SOURCE_DETAIL" ] || MAIN_SOURCE_DETAIL="none"
    printf 'Main-loop source edits : %-4s (%s)\n' "$MAIN_SOURCE_COUNT" "$MAIN_SOURCE_DETAIL"

    # --- main-loop exempt edits ---
    MAIN_EXEMPT_COUNT=$(printf '%s' "$SESSION_EVENTS" | jq '[.[] | select(.origin=="main" and .source==false)] | length' 2>/dev/null || echo 0)
    [ -n "$MAIN_EXEMPT_COUNT" ] || MAIN_EXEMPT_COUNT=0
    printf 'Main-loop exempt edits : %-4s (docs/memory/.claude)\n' "$MAIN_EXEMPT_COUNT"

    # --- delegated source edits ---
    DELEGATED_COUNT=$(printf '%s' "$SESSION_EVENTS" | jq '[.[] | select(.origin=="subagent" and .source==true)] | length' 2>/dev/null || echo 0)
    [ -n "$DELEGATED_COUNT" ] || DELEGATED_COUNT=0
    AGENT_COUNT=$(printf '%s' "$SESSION_EVENTS" | jq '[.[] | select(.origin=="subagent" and .source==true) | .agent_id] | unique | length' 2>/dev/null || echo 0)
    [ -n "$AGENT_COUNT" ] || AGENT_COUNT=0
    printf 'Delegated source edits : %-4s across %s subagents\n' "$DELEGATED_COUNT" "$AGENT_COUNT"

    # Per-agent rows, in order of first appearance among delegated-source events.
    AGENT_ROWS=$(printf '%s' "$SESSION_EVENTS" | jq -r '
        [.[] | select(.origin=="subagent" and .source==true)] as $ev
        | ( [$ev[].agent_id] | reduce .[] as $a ([]; if index($a) then . else . + [$a] end) ) as $ids
        | $ids[] as $id
        | ( [$ev[] | select(.agent_id==$id)] ) as $sub
        | [$id, ($sub[0].agent_type // "?"), (($sub|length)|tostring)] | @tsv
    ' 2>/dev/null)

    if [ -n "$AGENT_ROWS" ]; then
        while IFS=$'\t' read -r AID ATYPE ACOUNT; do
            [ -n "$AID" ] || continue
            MODEL=""
            {
                for MF in "$HOME"/.claude/projects/*/"$SESSION_ID"/subagents/"${AID}".meta.json; do
                    [ -f "$MF" ] || continue
                    MODEL_LOOKUP=$(jq -r '.model // empty' "$MF" 2>/dev/null)
                    if [ -n "$MODEL_LOOKUP" ]; then MODEL="$MODEL_LOOKUP"; break; fi
                done
            } 2>/dev/null
            [ -n "$MODEL" ] || MODEL="model unknown"
            FLAG=""
            if [ "$ATYPE" = "Explore" ] || [ "$ATYPE" = "Plan" ]; then
                FLAG="   <-- flag: ${ATYPE} edited"
            fi
            printf '  %-10s  %-16s %-13s: %3s%s\n' "${AID:0:12}" "$ATYPE" "$MODEL" "$ACOUNT" "$FLAG"
        done <<< "$AGENT_ROWS"
    fi

    # --- lead-never-edits ---
    if [ "$MAIN_SOURCE_COUNT" = "0" ]; then LNE="YES"; else LNE="NO"; fi
    printf 'Lead-never-edits       : %s\n' "$LNE"

    # --- delegation ratio ---
    DENOM=$((MAIN_SOURCE_COUNT + DELEGATED_COUNT))
    if [ "$DENOM" -eq 0 ]; then
        printf 'Delegation ratio       : n/a  (0 source edits)\n'
    else
        PCT=$(( (DELEGATED_COUNT * 100 + DENOM / 2) / DENOM ))
        printf 'Delegation ratio       : %s%%  (%s/%s source edits delegated)\n' "$PCT" "$DELEGATED_COUNT" "$DENOM"
    fi

    printf -- '%*s\n' "${#HEADER}" '' | tr ' ' '-'
fi

# --- trailing-10 block (ALL delegation-*.jsonl files, chronological) ---
FILES=$(find "$METRICS_DIR" -maxdepth 1 -name 'delegation-*.jsonl' 2>/dev/null | sort)
ALL_EVENTS="[]"
if [ -n "$FILES" ]; then
    ALL_LINES=""
    while IFS= read -r F; do
        [ -f "$F" ] || continue
        ALL_LINES="${ALL_LINES}$(cat "$F" 2>/dev/null)"$'\n'
    done <<< "$FILES"
    ALL_EVENTS=$(printf '%s' "$ALL_LINES" | jq -R 'fromjson? // empty' 2>/dev/null | jq -s '[.[] | select(type == "object")]' 2>/dev/null)
    [ -n "$ALL_EVENTS" ] || ALL_EVENTS="[]"
fi

TRAILING_SESSIONS_JSON=$(printf '%s' "$ALL_EVENTS" | jq '
    [.[] | .session_id] | reduce .[] as $s ([]; if index($s) then . else . + [$s] end) | .[-10:]
' 2>/dev/null)
[ -n "$TRAILING_SESSIONS_JSON" ] || TRAILING_SESSIONS_JSON="[]"
M=$(printf '%s' "$TRAILING_SESSIONS_JSON" | jq 'length' 2>/dev/null || echo 0)
[ -n "$M" ] || M=0

LEAD_NEVER_COUNT=0
VIOLATING_COUNT=0
SONNET_NATIVE_COUNT=0
APPLICABLE_COUNT=0
if [ "$M" -gt 0 ]; then
    while IFS= read -r S; do
        [ -n "$S" ] || continue
        C=$(printf '%s' "$ALL_EVENTS" | jq --arg s "$S" \
            '[.[] | select(.session_id==$s and .origin=="main" and .source==true)] | length' 2>/dev/null)
        case "$C" in ''|*[!0-9]*) C=0 ;; esac

        # A session whose main loop already IS Sonnet/Haiku has nothing to
        # delegate DOWN to — the tiering policy doesn't apply, so it's
        # excluded from both counts rather than misreported as a violation.
        MAIN_MODEL=$(dlg_session_main_model "$S" 2>/dev/null)
        if dlg_is_execution_tier_model "$MAIN_MODEL"; then
            SONNET_NATIVE_COUNT=$((SONNET_NATIVE_COUNT + 1))
            continue
        fi
        APPLICABLE_COUNT=$((APPLICABLE_COUNT + 1))
        [ "$C" -eq 0 ] && LEAD_NEVER_COUNT=$((LEAD_NEVER_COUNT + 1))
        [ "$C" -ge 3 ] && VIOLATING_COUNT=$((VIOLATING_COUNT + 1))
    done < <(printf '%s' "$TRAILING_SESSIONS_JSON" | jq -r '.[]')
fi

if [ "$APPLICABLE_COUNT" -gt 0 ]; then
    LNE_PCT=$(( (LEAD_NEVER_COUNT * 100 + APPLICABLE_COUNT / 2) / APPLICABLE_COUNT ))
else
    LNE_PCT=0
fi
if [ "$M" -eq 0 ]; then
    echo "Trailing 10 sessions   : no history recorded yet"
elif [ "$APPLICABLE_COUNT" -eq 0 ]; then
    printf 'Trailing 10 sessions   : all %s Sonnet/Haiku-native (tiering policy n/a)\n' "$SONNET_NATIVE_COUNT"
else
    printf 'Trailing 10 sessions   : lead-never-edits %s/%s (%s%%)   target >=81%%  [%s Sonnet/Haiku-native excluded]\n' \
        "$LEAD_NEVER_COUNT" "$APPLICABLE_COUNT" "$LNE_PCT" "$SONNET_NATIVE_COUNT"
    printf 'Violating sessions     : %s/%s (>=3 main-loop source edits, Fable/Opus-main-loop only)\n' \
        "$VIOLATING_COUNT" "$APPLICABLE_COUNT"
fi

# --- enforcement ---
if [ -f "$METRICS_DIR/tiering-enforce" ]; then
    echo "Enforcement            : ARMED  (.claude/metrics/tiering-enforce present — 3rd main-loop source edit blocks on a Fable/Mythos loop; Opus advisory, Sonnet/Haiku exempt)"
else
    echo "Enforcement            : ADVISORY (.claude/metrics/tiering-enforce absent)"
fi

exit 0
