#!/usr/bin/env bash
# delegation-lib.sh — Shared helpers for the delegation-scorecard hooks
# (delegation-track.sh, agent-spawn-capture.sh) and, later, the scorecard
# report script itself. Sourced, never executed directly — defines
# functions only, no side effects at source time (mkdir happens when a
# function is actually called, not when this file is sourced).
#
# Every git call is guarded with `2>/dev/null` plus a non-git fallback
# (iCloud-hang guard, same precedent as .claude/hooks/pre-merge-gate.sh).
set -u

# Main repo root, regardless of which worktree the session is checked out
# in. `git rev-parse --git-common-dir` returns an absolute .../.git path
# from inside a linked worktree, or the literal ".git" from the main
# checkout itself (relative, since git-dir == git-common-dir there).
dlg_main_root() {
    local gcd
    gcd=$(git rev-parse --git-common-dir 2>/dev/null)
    if [ -z "$gcd" ] || [ "$gcd" = ".git" ]; then
        printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}"
        return 0
    fi
    printf '%s\n' "${gcd%/.git}"
}

# <main_root>/.claude/metrics, created if missing. Echoes the path.
# Honors DLG_METRICS_DIR if set, so tests (and any future consumer) can
# point every hook/script at a scratch dir without touching real metrics.
dlg_metrics_dir() {
    local dir
    dir="${DLG_METRICS_DIR:-$(dlg_main_root)/.claude/metrics}"
    mkdir -p "$dir" 2>/dev/null
    printf '%s\n' "$dir"
}

# <metrics_dir>/delegation-YYYY-MM.jsonl for the current UTC month.
dlg_month_file() {
    printf '%s/delegation-%s.jsonl\n' "$(dlg_metrics_dir)" "$(date -u +%Y-%m)"
}

# <metrics_dir>/delegation-YYYY-MM.jsonl for the PREVIOUS UTC calendar
# month. BSD `date -v-1m` first (this repo's stated runtime); GNU `date -d`
# fallback for Linux, same ordering convention as the stat -f/-c guard in
# delegation-nudge.sh. The GNU branch anchors on day 15 of the current
# month (not today's actual day) before subtracting, since GNU date's
# "-1 month" on day 29-31 can overflow into the wrong month (e.g. Mar 31
# minus 1 month lands back on Mar, not Feb) — day 15 always resolves
# cleanly in every month.
dlg_prev_month_file() {
    local ym
    ym=$(date -u -v-1m +%Y-%m 2>/dev/null) || ym=$(date -u -d "$(date -u +%Y-%m-15) -1 month" +%Y-%m 2>/dev/null)
    printf '%s/delegation-%s.jsonl\n' "$(dlg_metrics_dir)" "$ym"
}

# $1 = absolute path. Echoes it relative to the session checkout's
# toplevel, or unchanged if it isn't under that toplevel (outside the repo).
dlg_rel_path() {
    local abs="$1" top
    top=$(git rev-parse --show-toplevel 2>/dev/null)
    [ -n "$top" ] || top="${CLAUDE_PROJECT_DIR:-$PWD}"
    case "$abs" in
        "$top"/*)
            printf '%s\n' "${abs#"$top"/}"
            ;;
        *)
            printf '%s\n' "$abs"
            ;;
    esac
}

# $1 = the output of dlg_rel_path. Returns 0 (true) for source files, 1
# (exempt) for: paths outside the repo (still absolute — starts with "/"),
# any *.md* extension, or anything under memory/, docs/, or .claude/.
dlg_is_source_file() {
    local path="$1"
    case "$path" in
        /*) return 1 ;;
    esac
    case "$path" in
        *.md*) return 1 ;;
        memory/*|docs/*|.claude/*) return 1 ;;
    esac
    return 0
}

# "main" if the session checkout toplevel is the main repo root, else the
# worktree directory's basename.
dlg_worktree_name() {
    local top main
    top=$(git rev-parse --show-toplevel 2>/dev/null)
    [ -n "$top" ] || top="${CLAUDE_PROJECT_DIR:-$PWD}"
    main="$(dlg_main_root)"
    if [ "$top" = "$main" ]; then
        printf '%s\n' "main"
    else
        printf '%s\n' "$(basename "$top")"
    fi
}

# Reads stdin into the global $INPUT, exiting the CALLING SCRIPT (not just
# this function) with 0 if jq is missing or stdin is empty — the fail-open
# contract every hook depends on. Must be called as a plain statement
# (`dlg_hook_stdin`), NEVER via command substitution (`x=$(dlg_hook_stdin)`)
# — command substitution forks a subshell, and `exit` inside a subshell only
# terminates the subshell, silently defeating the fail-open guarantee and
# leaving $INPUT unset in the parent shell. This is the one thing to get
# exactly right in this refactor.
dlg_hook_stdin() {
    command -v jq >/dev/null 2>&1 || exit 0
    INPUT=$(cat)
    [ -n "$INPUT" ] || exit 0
}

# True (0) if $1 (a resolved model string, e.g. "claude-sonnet-5") is an
# execution-tier model (Sonnet/Haiku) that the Fable/Opus-orchestrates-
# Sonnet-executes tiering policy does not apply to as a MAIN LOOP — there is
# nothing cheaper to delegate down to. False (1) for Fable/Opus, and for
# empty/unknown input: an undetectable model fails toward "policy still
# applies" (the pre-existing behavior), never toward silently exempting it.
#
# NOTE (2026-07-27) — delegation-nudge.sh honours this contract for a READABLE
# transcript: consulted it, found no model => still enforce. That matters because
# dlg_last_real_assistant_model only tails 200 lines, so a long Fable session with
# many trailing tool records resolves "" from a healthy transcript; treating that
# as "not Fable" would silently disarm the gate on the sessions it exists for.
# Only a MISSING or UNREADABLE transcript fails open — nothing to consult at all.
# Covered by tests/deployment/unit/test_delegation_nudge.bats.
# Match style differs deliberately from delegation-nudge.sh's HARD_TIER case, which is
# anchored (claude-fable*). This one stays a BARE substring because the two failure
# directions are opposite: a missed match here means a Sonnet/Haiku loop gets a
# pointless nudge (harmless), whereas a missed match there means a Fable loop slips a
# cost gate. Widen-by-default is right for an exemption, narrow-by-default for a block.
dlg_is_execution_tier_model() {
    case "${1:-}" in
        *sonnet*|*haiku*) return 0 ;;
        *) return 1 ;;
    esac
}

# <projects_dir> to search for session transcript JSONLs. Honors
# DLG_CLAUDE_PROJECTS_DIR (tests only), same override pattern as
# DLG_METRICS_DIR in dlg_metrics_dir().
dlg_claude_projects_dir() {
    printf '%s\n' "${DLG_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
}

# $1 = a transcript JSONL file. Echoes the most recent REAL model driving
# that transcript's assistant turns, scanning its last 200 lines. Two
# things a naive "last assistant record's .message.model" read gets wrong,
# both confirmed against real production transcripts (2026-07-21):
#   1. `type=="object"` is checked before `.type=="assistant"` — jq's `and`
#      short-circuits, so a torn line that survives `fromjson? // empty`
#      as a bare scalar (not an object) is skipped instead of crashing
#      `.type` field access, which would otherwise abort the whole scan.
#   2. Claude Code inserts a synthetic `{"type":"assistant",
#      "message":{"model":"<synthetic>"}}` placeholder after a transient
#      API error (e.g. 529 Overloaded) — confirmed present as the literal
#      LAST assistant record in many real session transcripts (any session
#      that ends on a retry/error). Blindly taking "the last one" would
#      report "<synthetic>" instead of the model that was actually driving
#      the session. Filtered out here so the real model underneath it wins.
#   3. The 200-line tail is a speed optimisation, not a correctness bound. A
#      long session can have >200 trailing non-assistant records (ordinary heavy
#      tool use), in which case the tail contains NO assistant record and the
#      model resolves empty from a perfectly healthy transcript. That produced
#      two opposite live defects on 2026-07-27 — a Fable loop silently slipping
#      the tiering gate, and a Sonnet loop wrongly BLOCKED and told it was
#      Fable-tier. Both are lookup failures,
#      not policy failures, so the fix belongs here: fall back to scanning the
#      whole file when the tail yields nothing. The tail still handles the
#      overwhelmingly common case without reading a large transcript.
# Echoes empty on no match/no file/no jq — never errors.
_dlg_scan_model() {
    jq -R 'fromjson? // empty' 2>/dev/null \
        | jq -rs '[.[] | select(type=="object" and .type=="assistant")
                   | .message.model // empty | select(. != "" and . != "<synthetic>")] | last // empty' 2>/dev/null
}

dlg_last_real_assistant_model() {
    local file="$1" model
    [ -n "$file" ] && [ -f "$file" ] || return 0
    model=$(tail -n 200 "$file" 2>/dev/null | _dlg_scan_model)
    # Fall back to the whole file only when the cheap tail found nothing.
    [ -n "$model" ] || model=$(_dlg_scan_model < "$file")
    printf '%s\n' "$model"
}

# $1 = session id. Best-effort resolution of which model was driving that
# session's MAIN LOOP: glob every encoded-cwd project dir for
# <session_id>.jsonl (a session run from a worktree logs under a DIFFERENT
# encoded path than the main checkout — same multi-match idiom the
# resume-session skill uses), pick the largest by line count if more than
# one matches, then delegate to dlg_last_real_assistant_model. Echoes
# empty on any failure — no match, no jq, no assistant records — never
# errors.
dlg_session_main_model() {
    local sess="$1" f best="" best_lines=-1 lines
    for f in "$(dlg_claude_projects_dir)"/*/"${sess}.jsonl"; do
        [ -f "$f" ] || continue
        lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
        if [ "$lines" -gt "$best_lines" ]; then
            best="$f"
            best_lines="$lines"
        fi
    done
    [ -n "$best" ] || return 0
    dlg_last_real_assistant_model "$best"
}

# $1 = target file, $2 = a single pre-built JSON line (caller must build it
# with jq -nc, never hand-assembled). Appends atomically via one printf;
# drops the event instead of writing a torn/oversized line past 4096 bytes.
# Always returns 0 — a metrics-append failure must never surface.
dlg_append_event() {
    local file="$1" line="$2" nbytes
    [ -n "$file" ] && [ -n "$line" ] || return 0
    nbytes=$(printf '%s' "$line" | wc -c | tr -d ' ')
    # The write below is `$line` PLUS a trailing newline, i.e. nbytes + 1
    # bytes actually hit disk. Bound nbytes at 4095 (not 4096) so the
    # worst case (4095 + 1) lands exactly on the documented 4096-byte cap
    # instead of one byte past it. Do not "simplify" this back to 4096.
    [ "$nbytes" -le 4095 ] || return 0
    printf '%s\n' "$line" >> "$file" 2>/dev/null
    return 0
}

# $1 = session id. Count of events with that session_id, origin=="main",
# source==true, across the current month's file AND the previous month's
# file (bounded 2-file scan, not unbounded history) — a session's
# main-loop edits can span a UTC month boundary, and the running count
# must not silently reset to 0 right after rollover mid-session. Missing/
# unparseable files -> 0 contribution from that file.
dlg_session_mainloop_count() {
    local sess="$1" file count total=0
    for file in "$(dlg_month_file)" "$(dlg_prev_month_file)"; do
        [ -f "$file" ] || continue
        count=$(jq -R 'fromjson? // empty' "$file" 2>/dev/null \
            | jq -s --arg s "$sess" \
                '[ .[] | select(type == "object") | select(.session_id == $s and .origin == "main" and .source == true) ] | length' \
                2>/dev/null)
        [ -n "$count" ] || count=0
        total=$((total + count))
    done
    printf '%s\n' "$total"
}
