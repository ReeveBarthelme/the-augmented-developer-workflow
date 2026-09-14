#!/usr/bin/env bash
# lib-act-ci.test.sh — discriminating tests for scripts/lib-act-ci.sh and
# scripts/act-local-ci.sh. Each test targets one reviewed defect and is written to
# FAIL on the unfixed code, so a green run is evidence the fix works rather than
# evidence the test is inert.
#
# Run:  bash scripts/tests/lib-act-ci.test.sh
#
# Run it the way `make pre-merge` does, with a mutex already held by the parent:
#       ACT_MUTEX_HELD=$$ bash scripts/tests/lib-act-ci.test.sh
# That inherited variable short-circuits acquire_act_mutex, so before the harness
# scrubbed it the two mutex tests passed without executing any acquisition at all.
# Both invocations must be green.
#
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

# Scrub every variable the library or the Makefile exports into a child process.
# A test that inherits one of these is testing the caller's environment, not the
# code: ACT_MUTEX_HELD in particular makes acquire_act_mutex return 0 immediately,
# so under `make pre-merge` both mutex tests passed while executing nothing.
# Keep this list in sync with the exports in lib-act-ci.sh, act-local-ci.sh and
# Makefile.example.
unset ACT_MUTEX_HELD ACT_ARTIFACT_PORT ACT_ALLOW_UNVERIFIED_PORTS \
      ACT_MUTEX_WAIT_SECS ACT_MUTEX_POLL_SECS ACT_PORT_WINDOW ACT_JOBS ACT_FLAGS \
      VERBOSE REUSE PARALLEL FORCE_AMD64 SKIP_SECURITY \
      SECURITY_REQ_FILES SECURITY_SRC_DIRS SHELL_CHECK_DIRS BATS_DIRS

# Assert the scrub worked before running anything that depends on it.
if [ -n "${ACT_MUTEX_HELD:-}" ]; then
    echo "FATAL: ACT_MUTEX_HELD is still set after the scrub; mutex tests would be inert." >&2
    exit 1
fi

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

test_override_rejects_failure_before_success() {
    local name="an earlier real job failure is NOT erased by a later success marker"
    local got
    got=$(_run_act_job_with_fake '[x/a] 🏁  Job failed
[x/b] 🏁  Job succeeded
Error: Job required failed' 1 e)
    check "$name" "$got" "1"
}

test_override_forgives_trailing_cleanup_error() {
    local name="positive control: success markers + a trailing cleanup Error: is forgiven"
    local got
    got=$(_run_act_job_with_fake '[x/a] 🏁  Job succeeded
[x/b] 🏁  Job succeeded
Error: unable to remove container' 1 f)
    check "$name" "$got" "0"
}

test_override_rejects_job_required_failed_phrase() {
    local name="a 'Job ... failed' line with no emoji marker still blocks the override"
    local got
    got=$(_run_act_job_with_fake '[x/a] 🏁  Job succeeded
Error: Job required failed' 1 g)
    check "$name" "$got" "1"
}

# ── Harness integrity: the mutex tests must not be inert ──────────────────

test_harness_scrubs_act_mutex_held() {
    local name="harness runs green with ACT_MUTEX_HELD inherited (tests are not bypassed)"
    # Re-run THIS file with the variable the parent pre-merge run exports. Guard
    # against infinite recursion with a marker variable.
    if [ -n "${_LIB_ACT_CI_TEST_NESTED:-}" ]; then
        pass "$name (nested run, skipped)"
        return 0
    fi
    local rc
    _LIB_ACT_CI_TEST_NESTED=1 ACT_MUTEX_HELD=$$ \
        bash "${BASH_SOURCE[0]}" > "$SANDBOX/nested.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$name"
    else
        fail "$name" "nested run failed: $(grep -c FAIL "$SANDBOX/nested.log") failure(s); see $SANDBOX/nested.log"
    fi
}

# ── Finding C: signal between mkdir and the ownership flag ────────────────

test_mutex_no_leak_on_signal_right_after_mkdir() {
    local name="an interrupt between mkdir and the ownership flag leaves no lock dir"
    local lock="$SANDBOX/m3.lock"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        # Reproduce the window deterministically. `trap 'exit 130' TERM` is what the
        # library installs, so running `exit 130` the instant the real mkdir returns
        # IS the signal path, without depending on when bash chooses to deliver a
        # signal (it defers delivery until the enclosing `while` compound finishes,
        # which is why sending a real SIGTERM here cannot hit the window at all).
        mkdir() {
            command mkdir "$@" || return $?
            exit 130
        }
        acquire_act_mutex
    ) >/dev/null 2>&1
    if [ ! -d "$lock" ]; then
        pass "$name"
    else
        fail "$name" "lock dir survived the interrupt: $lock"
        rm -rf "$lock"
    fi
}

test_release_removes_unstamped_lock_after_attempt() {
    local name="release_act_mutex reclaims an unstamped lock dir our own acquire left"
    local lock="$SANDBOX/m4.lock"
    command mkdir -p "$lock"          # a lock dir with NO pid file, as mid-acquire
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        _ACT_MUTEX_ATTEMPTED=1        # this shell was inside acquire_act_mutex
        release_act_mutex
    ) >/dev/null 2>&1
    if [ ! -d "$lock" ]; then
        pass "$name"
    else
        fail "$name" "unstamped lock dir survived release: $lock"
        rm -rf "$lock"
    fi
}

test_release_leaves_unstamped_lock_we_never_attempted() {
    local name="control: release does NOT touch an unstamped lock when we never tried to acquire"
    local lock="$SANDBOX/m5.lock"
    command mkdir -p "$lock"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        release_act_mutex             # _ACT_MUTEX_ATTEMPTED deliberately unset
    ) >/dev/null 2>&1
    if [ -d "$lock" ]; then
        pass "$name"
        rm -rf "$lock"
    else
        fail "$name" "release deleted a peer session's in-flight lock dir"
    fi
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
test_mutex_no_leak_on_signal_right_after_mkdir
test_release_removes_unstamped_lock_after_attempt
test_release_leaves_unstamped_lock_we_never_attempted
echo "--- finding 3: exit-code override ---"
test_override_rejects_forged_marker_on_exit42
test_override_rejects_signal_exit
test_override_rejects_marker_followed_by_failure
test_override_accepts_genuine_cleanup_error
test_override_rejects_failure_before_success
test_override_forgives_trailing_cleanup_error
test_override_rejects_job_required_failed_phrase
echo "--- harness integrity ---"
test_harness_scrubs_act_mutex_held
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
