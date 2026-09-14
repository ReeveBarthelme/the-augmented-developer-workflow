#!/usr/bin/env bash
# lib-act-ci.test.sh — discriminating tests for scripts/lib-act-ci.sh and
# scripts/act-local-ci.sh. Each test targets one reviewed defect and is written to
# FAIL on the unfixed code, so a green run is evidence the fix works rather than
# evidence the test is inert.
#
# Run:  bash scripts/tests/lib-act-ci.test.sh
# Exit: 0 when every test passes, 1 otherwise.
#
# Deliberately NOT `set -e`: the first failing assertion must not abort the run.
#
# File-level shellcheck exemptions, all inherent to testing a sourced library:
#   SC1090  the library path is computed at run time, so it cannot be followed.
#   SC2034  vars like ACT_PORT_WINDOW and VERBOSE look unused here; the sourced
#           library reads them. That is the point of setting them.
#   SC2123  PATH=/nonexistent inside a subshell is how tool absence is simulated.
# shellcheck disable=SC1090,SC2034,SC2123

TESTS_RUN=0
TESTS_FAILED=0

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
LIB="$LIB_ROOT/scripts/lib-act-ci.sh"
ENTRY="$LIB_ROOT/scripts/act-local-ci.sh"

# Every test runs against throwaway dirs, never the real mutex or the real repo
# config. Without this the ACT_JOBS tests would block on a peer session's lock.
SANDBOX="$(mktemp -d)"
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"
export ACT_MUTEX_DIR="$SANDBOX/mutex.lock"
trap 'rm -rf "$SANDBOX"' EXIT

pass() { TESTS_RUN=$((TESTS_RUN + 1)); echo "  PASS  $1"; }
fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  FAIL  $1"
    [ -n "${2:-}" ] && echo "        $2"
    return 0
}
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$3] got [$2]"; fi; }

# ── Finding 1: port-window exhaustion ─────────────────────────────────────

test_find_free_port_exhaustion() {
    local name="find_free_port returns nonzero when the window is exhausted"
    local out rc
    # Exclude every port in [100,104) so the window has nothing left to hand out.
    out=$( ( REPO_ROOT="$LIB_ROOT"; . "$LIB"; find_free_port 100 104 100 101 102 103 ) 2>/dev/null ); rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
        pass "$name"
    else
        fail "$name" "expected rc!=0 and empty stdout; got rc=$rc out=[$out]"
    fi
}

test_run_parallel_refuses_more_groups_than_window() {
    local name="run_parallel fails closed when groups exceed ACT_PORT_WINDOW"
    local portlog="$SANDBOX/ports.txt"
    : > "$portlog"
    local rc
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_PORT_WINDOW=4
        reclaim_orphaned_act_ports() { :; }          # never touch real processes
        probe() { echo "$ACT_ARTIFACT_PORT" >> "$portlog"; }
        run_parallel probe g1 g2 g3 g4 g5
    ) >/dev/null 2>&1
    rc=$?
    local lines
    lines=$(wc -l < "$portlog" | tr -d ' ')
    if [ "$rc" -ne 0 ] && [ "$lines" -eq 0 ]; then
        pass "$name"
    else
        local dupes
        dupes=$(sort "$portlog" | uniq -d | tr '\n' ' ')
        fail "$name" "expected rc!=0 with 0 forks; got rc=$rc forks=$lines duplicate-ports=[$dupes]"
    fi
}

# ── Finding 2: mutex acquisition window ───────────────────────────────────

test_mutex_trap_installed_before_mkdir() {
    local name="acquire_act_mutex installs the EXIT trap BEFORE mkdir"
    local probe="$SANDBOX/trapprobe.txt"
    : > "$probe"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$SANDBOX/m1.lock"
        # Capture what the EXIT trap looks like at the moment mkdir is called.
        mkdir() { trap -p EXIT > "$probe"; command mkdir "$@"; }
        acquire_act_mutex
    ) >/dev/null 2>&1
    if grep -q 'release_act_mutex' "$probe" 2>/dev/null; then
        pass "$name"
    else
        fail "$name" "no release_act_mutex trap was armed when mkdir ran (lock leaks on SIGINT)"
    fi
}

test_mutex_failed_pid_write_is_acquisition_failure() {
    local name="acquire_act_mutex fails and removes the dir when the PID write fails"
    local lock="$SANDBOX/m2.lock"
    local rc
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        # mode 000 dir: mkdir succeeds, the pid write inside it cannot.
        umask 0777
        acquire_act_mutex
    ) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && [ ! -d "$lock" ]; then
        pass "$name"
    else
        fail "$name" "expected rc!=0 and no leftover lock dir; got rc=$rc dir-exists=$([ -d "$lock" ] && echo yes || echo no)"
    fi
    rmdir "$lock" 2>/dev/null
}

# ── Finding 3: act exit-code override ─────────────────────────────────────

# Build a fake `act` that prints $FAKE_ACT_OUTPUT and exits $FAKE_ACT_RC.
_fake_act_dir() {
    local d="$SANDBOX/fakebin-$1"
    mkdir -p "$d"
    cat > "$d/act" <<'FAKEACT'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_ACT_OUTPUT"
exit "$FAKE_ACT_RC"
FAKEACT
    chmod +x "$d/act"
    echo "$d"
}

_run_act_job_with_fake() {
    local out="$1" rc="$2" bindir
    bindir=$(_fake_act_dir "$3")
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        PATH="$bindir:$PATH"
        export FAKE_ACT_OUTPUT="$out" FAKE_ACT_RC="$rc"
        ACT_ARTIFACT_PORT=34567
        VERBOSE=false
        run_act_job "x.yml" "job" "L"
    ) >/dev/null 2>&1
    echo $?
}

test_override_rejects_forged_marker_on_exit42() {
    local name="exit 42 with the success marker in step stdout stays FAILED"
    local got
    got=$(_run_act_job_with_fake 'step output: 🏁  Job succeeded' 42 a)
    check "$name" "$got" "42"
}

test_override_rejects_signal_exit() {
    local name="a signal exit (137) with the success marker stays FAILED"
    local got
    got=$(_run_act_job_with_fake '[x/job] 🏁  Job succeeded' 137 b)
    check "$name" "$got" "137"
}

test_override_rejects_marker_followed_by_failure() {
    local name="success marker followed by a failure marker stays FAILED"
    local got
    got=$(_run_act_job_with_fake '[x/job] 🏁  Job succeeded
[x/job2] 🏁  Job failed' 1 c)
    check "$name" "$got" "1"
}

test_override_accepts_genuine_cleanup_error() {
    local name="positive control: exit 1 with success as the LAST status line passes"
    local got
    got=$(_run_act_job_with_fake 'some noise
[x/job] 🏁  Job succeeded' 1 d)
    check "$name" "$got" "0"
}

# ── Finding 4: ACT_JOBS parsing ───────────────────────────────────────────

_parse() {
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        parse_act_jobs "$1"
    ) 2>&1
}

test_parse_rejects_colon_prefixed_token() {
    local name="parse_act_jobs rejects ':missing-job' and names it"
    local out rc
    out=$(_parse "$(printf 'ci.yml:lint\n:missing-job')"); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q ':missing-job'; then
        pass "$name"
    else
        fail "$name" "expected rc!=0 and the bad token named; got rc=$rc out=[$out]"
    fi
}

test_parse_rejects_bare_token() {
    local name="parse_act_jobs rejects a token with no colon"
    local out rc
    out=$(_parse "ci.yml"); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'malformed'; then
        pass "$name"
    else
        fail "$name" "expected rc!=0 and a malformed message; got rc=$rc out=[$out]"
    fi
}

test_parse_reads_multiline_value() {
    local name="parse_act_jobs keeps BOTH specs from a multi-line ACT_JOBS"
    local out rc
    out=$(_parse "$(printf 'ci.yml:lint\nci.yml:test')"); rc=$?
    local n
    n=$(printf '%s\n' "$out" | grep -c .)
    if [ "$rc" -eq 0 ] && [ "$n" -eq 2 ]; then
        pass "$name"
    else
        fail "$name" "expected rc=0 and 2 specs; got rc=$rc n=$n out=[$out]"
    fi
}

test_parse_allows_optional_label() {
    local name="parse_act_jobs still accepts the documented workflow:job:Label form"
    local out rc
    out=$(_parse "ci.yml:test:Unit-tests"); rc=$?
    check "$name" "$rc/$out" "0/ci.yml:test:Unit-tests"
}

# ── Finding 5: pgrep / lsof availability ──────────────────────────────────

test_find_free_port_fails_closed_without_lsof() {
    local name="find_free_port fails closed when lsof is unavailable"
    local out rc
    out=$( ( REPO_ROOT="$LIB_ROOT"; PATH=/nonexistent; . "$LIB"; find_free_port 34567 34571 ) 2>&1 ); rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'lsof'; then
        pass "$name"
    else
        fail "$name" "expected rc!=0 naming lsof; got rc=$rc out=[$out]"
    fi
}

test_find_free_port_override_without_lsof() {
    local name="ACT_ALLOW_UNVERIFIED_PORTS=1 lets find_free_port proceed unverified"
    local out rc
    out=$( ( REPO_ROOT="$LIB_ROOT"; PATH=/nonexistent; ACT_ALLOW_UNVERIFIED_PORTS=1; . "$LIB"; find_free_port 34567 34571 ) 2>/dev/null ); rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '34567'; then
        pass "$name"
    else
        fail "$name" "expected rc=0 and port 34567; got rc=$rc out=[$out]"
    fi
}

test_reclaim_warns_without_pgrep() {
    local name="reclaim_orphaned_act_ports warns when pgrep is unavailable"
    local out
    out=$( ( REPO_ROOT="$LIB_ROOT"; PATH=/nonexistent; . "$LIB"; reclaim_orphaned_act_ports ) 2>&1 )
    if printf '%s' "$out" | grep -qi 'pgrep'; then
        pass "$name"
    else
        fail "$name" "expected a warning naming pgrep; got [$out]"
    fi
}

# ── Runner ────────────────────────────────────────────────────────────────

echo "lib-act-ci tests"
echo "--- finding 1: port window ---"
test_find_free_port_exhaustion
test_run_parallel_refuses_more_groups_than_window
echo "--- finding 2: mutex ---"
test_mutex_trap_installed_before_mkdir
test_mutex_failed_pid_write_is_acquisition_failure
echo "--- finding 3: exit-code override ---"
test_override_rejects_forged_marker_on_exit42
test_override_rejects_signal_exit
test_override_rejects_marker_followed_by_failure
test_override_accepts_genuine_cleanup_error
echo "--- finding 4: ACT_JOBS parsing ---"
test_parse_rejects_colon_prefixed_token
test_parse_rejects_bare_token
test_parse_reads_multiline_value
test_parse_allows_optional_label
echo "--- finding 5: pgrep / lsof ---"
test_find_free_port_fails_closed_without_lsof
test_find_free_port_override_without_lsof
test_reclaim_warns_without_pgrep

echo ""
echo "ran $TESTS_RUN, failed $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
echo "ENTRY under test: $ENTRY"
exit 0
