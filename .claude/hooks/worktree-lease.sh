#!/usr/bin/env bash
# worktree-lease.sh — Stop a second session from silently clobbering another
# session's uncommitted work in the same .worktrees/<name> checkout.
#
# Modes:
#   acquire (SessionStart)            — claim/refresh the lease for this worktree.
#   check   (PreToolUse Edit|Write|NotebookEdit) — block a foreign live lease.
#
# Invoked via settings.json EXEC FORM ("command" + "args", no shell string).
# The path placeholder MUST be braced — ${CLAUDE_PROJECT_DIR} — because exec
# form does per-element placeholder substitution, not shell expansion; an
# unbraced $CLAUDE_PROJECT_DIR is passed literally and posix_spawn ENOENTs.
# Exec form is deliberate —
# shell form runs through `sh -c`, making $PPID a TRANSIENT per-hook shell
# rather than the persistent claude process (empirically confirmed: a
# shell-form probe showed $PPID pointing at a short-lived /bin/zsh, whose
# OWN parent was the real claude process). Exec form spawns this script
# directly, so $PPID is reliably the persistent claude process — but only
# under that invocation style, hence ownership is NOT pid-only:
#
#   OWNERSHIP primary: stdin .session_id equality (documented-reliable on
#   every hook event, both modes). Mine iff lease.session == my session_id,
#   AND both are non-empty/non-"unknown".
#   LIVENESS secondary: lease.pid (the claude pid, under exec form) + kill -0
#   decides stale vs live for a lease that isn't recognizably mine.
#   FALLBACK: if session id is unknown on either side (payload anomaly),
#   pid equality alone decides "mine" instead of failing closed on bad data.
#
# Lease file: <worktree>/.session-lease, one line: "session=<id> pid=<ppid> ts=<epoch>"
# Fail OPEN on any parse error — a broken hook must never block normal work.
set -u

_lease_path_for() {
    # $1 = any path; echoes the .session-lease path if under .worktrees/<name>/, else empty.
    case "$1" in
        */.worktrees/*) ;;
        *) return 0 ;;
    esac
    local prefix="${1%%/.worktrees/*}"
    local rest="${1#*/.worktrees/}"
    local name="${rest%%/*}"
    [ -n "$name" ] && printf '%s/.worktrees/%s/.session-lease\n' "$prefix" "$name"
}

_write_lease() {
    # $1 = lease file path, $2 = session id. Atomic: write to a temp file
    # then rename into place, so a concurrent reader never sees a truncated
    # lease.
    local tmp="$1.tmp.$$"
    printf 'session=%s pid=%s ts=%s\n' "${2:-unknown}" "$PPID" "$(date +%s)" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$1" 2>/dev/null
}

_pid_is_valid() {
    # $1 = candidate pid string. Must be numeric and > 1 — pid 0 signals the
    # whole process group, pid 1 (init) is never a session, both would turn a
    # corrupt/hostile lease into a permanent fail-CLOSED block.
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -gt 1 ]
}

# Reads OWNER_PID/OWNER_SESS (set by the caller) and $SESS/$PPID. Ownership:
# session-id equality when both sides have a real id; else pid equality.
_lease_is_mine() {
    if [ -n "$OWNER_SESS" ] && [ "$OWNER_SESS" != "unknown" ] \
        && [ -n "$SESS" ] && [ "$SESS" != "unknown" ]; then
        [ "$OWNER_SESS" = "$SESS" ]
    else
        [ "$OWNER_PID" = "$PPID" ]
    fi
}

# True iff the lease belongs to someone ELSE who is still alive — the one
# predicate both modes need ("back off" for acquire, "block" for check).
_lease_is_foreign_and_alive() {
    _lease_is_mine && return 1
    _pid_is_valid "$OWNER_PID" && kill -0 "$OWNER_PID" 2>/dev/null
}

MODE="${1:-}"
INPUT=$(cat)
SESS=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
SESS="${SESS:-${CLAUDE_SESSION_ID:-unknown}}"

case "$MODE" in
acquire)
    TARGET="${CLAUDE_PROJECT_DIR:-$PWD}"
    LEASE="$(_lease_path_for "$TARGET")"
    [ -n "$LEASE" ] || exit 0
    if [ -f "$LEASE" ]; then
        OWNER_PID=$(sed -n 's/.*pid=\([^ ]*\).*/\1/p' "$LEASE" 2>/dev/null)
        OWNER_SESS=$(sed -n 's/.*session=\([^ ]*\).*/\1/p' "$LEASE" 2>/dev/null)
        _lease_is_foreign_and_alive && exit 0
    fi
    _write_lease "$LEASE" "$SESS"
    exit 0
    ;;
check)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || exit 0
    [ -n "$FILE_PATH" ] || exit 0
    LEASE="$(_lease_path_for "$FILE_PATH")"
    [ -n "$LEASE" ] || exit 0
    [ -f "$LEASE" ] || exit 0

    OWNER_PID=$(sed -n 's/.*pid=\([^ ]*\).*/\1/p' "$LEASE" 2>/dev/null)
    OWNER_SESS=$(sed -n 's/.*session=\([^ ]*\).*/\1/p' "$LEASE" 2>/dev/null)
    [ -n "$OWNER_PID" ] || exit 0

    if ! _lease_is_foreign_and_alive; then
        # Mine (session or pid match) — pure read, no write, allow the edit.
        _lease_is_mine && exit 0
        # Otherwise stale (owner pid dead/malformed) — replace, allow the edit.
        _write_lease "$LEASE" "$SESS"
        exit 0
    fi

    REST="${LEASE#*/.worktrees/}"
    WT_NAME="${REST%%/*}"
    SESS_PREFIX="${OWNER_SESS:0:8}"
    echo "worktree ${WT_NAME} is leased by session ${SESS_PREFIX} (pid ${OWNER_PID}, alive) — coordinate ownership with the user or remove .session-lease to override" >&2
    exit 2
    ;;
*)
    exit 0
    ;;
esac
