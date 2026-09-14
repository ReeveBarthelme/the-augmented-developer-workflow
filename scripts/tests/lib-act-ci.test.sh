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

# The lock file the library derives from ACT_MUTEX_DIR.
_lockfile_for() { echo "${1%/}.lock"; }

# Try to take the flock from OUTSIDE the library, on a fresh open of the same path.
# Prints HELD when someone else owns it, FREE when it could be taken.
_probe_lock() {
    python3 - "$1" <<'PY'
import fcntl, sys
f = open(sys.argv[1], "a")
try:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("FREE")
except BlockingIOError:
    print("HELD")
PY
}

test_flock_holder_keeps_lock_and_second_acquire_times_out() {
    local name="a live holder keeps the lock; a second acquire times out and leaves the file"
    local base="$SANDBOX/f1" lf
    lf=$(_lockfile_for "$base")
    # Holder forks nothing that could inherit fd 9 and outlive it.
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$base"
        acquire_act_mutex || exit 1
        # `9>&-` closes fd 9 for this child only, so the sleep does NOT inherit the
        # lock descriptor. Without that the lock would outlive the subshell.
        sleep 2 9>&-
        exit 0
    ) >/dev/null 2>&1 &
    local holder=$!
    sleep 0.5
    local probe rc
    probe=$(_probe_lock "$lf")
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$base"
        ACT_MUTEX_WAIT_SECS=0
        ACT_MUTEX_POLL_SECS=1
        acquire_act_mutex
    ) >/dev/null 2>&1
    rc=$?
    wait "$holder" 2>/dev/null
    if [ "$probe" = "HELD" ] && [ "$rc" -ne 0 ] && [ -f "$lf" ]; then
        pass "$name"
    else
        fail "$name" "probe=$probe second-acquire rc=$rc (want nonzero) lockfile-present=$([ -f "$lf" ] && echo yes || echo no)"
    fi
    rm -f "$lf"
}

test_flock_released_when_holder_is_killed() {
    local name="kill -9 on the holder frees the lock, with no reaper involved"
    local base="$SANDBOX/f2" lf
    lf=$(_lockfile_for "$base")
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$base"
        acquire_act_mutex || exit 1
        # `9>&-` keeps fd 9 out of the child, so kill -9 on this subshell really is
        # the last holder going away.
        while :; do sleep 1 9>&-; done
    ) >/dev/null 2>&1 &
    local holder=$!
    sleep 0.5
    local before after
    before=$(_probe_lock "$lf")
    kill -9 "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    sleep 0.3
    after=$(_probe_lock "$lf")
    if [ "$before" = "HELD" ] && [ "$after" = "FREE" ]; then
        pass "$name"
    else
        fail "$name" "before=$before (want HELD) after=$after (want FREE)"
    fi
    rm -f "$lf"
}

test_flock_survives_the_python_child_that_took_it() {
    local name="lock survives the python child that took it"
    # The whole design rests on flock binding to the open file description rather
    # than to the process that called it. Assert it rather than assuming it.
    local base="$SANDBOX/f3" lf
    lf=$(_lockfile_for "$base")
    local probe
    probe=$(
        (
            REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
            . "$LIB"
            ACT_MUTEX_DIR="$base"
            acquire_act_mutex >/dev/null 2>&1 || { echo ACQUIRE_FAILED; exit 1; }
            # python3 has exited by now; a separate process must still be blocked.
            python3 - "$ACT_MUTEX_LOCKFILE" <<'PY'
import fcntl, sys
f = open(sys.argv[1], "a")
try:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("FREE")
except BlockingIOError:
    print("HELD")
PY
        )
    )
    check "$name" "$probe" "HELD"
    rm -f "$lf"
}

test_flock_release_allows_reacquire() {
    local name="release closes the descriptor and a second acquire succeeds"
    local base="$SANDBOX/f4" lf
    lf=$(_lockfile_for "$base")
    local first second
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$base"
        acquire_act_mutex >/dev/null 2>&1 || exit 1
        release_act_mutex
        exit 0
    ) >/dev/null 2>&1
    first=$?
    second=$(_probe_lock "$lf")
    if [ "$first" -eq 0 ] && [ "$second" = "FREE" ]; then
        pass "$name"
    else
        fail "$name" "first-cycle rc=$first probe-after-release=$second (want FREE)"
    fi
    rm -f "$lf"
}

test_release_without_ownership_is_a_noop() {
    local name="control: release without ownership is a no-op"
    local base="$SANDBOX/f5" lf
    lf=$(_lockfile_for "$base")
    : >> "$lf"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$base"
        release_act_mutex             # _ACT_MUTEX_OWNED deliberately unset
    ) >/dev/null 2>&1
    # The lock file must survive, and must still be takeable.
    if [ -f "$lf" ] && [ "$(_probe_lock "$lf")" = "FREE" ]; then
        pass "$name"
    else
        fail "$name" "lockfile-present=$([ -f "$lf" ] && echo yes || echo no) probe=$(_probe_lock "$lf")"
    fi
    rm -f "$lf"
}

test_orphaned_act_does_not_hold_the_lock() {
    local name="an orphaned act does not inherit the lock and block later runs"
    local base="$SANDBOX/f7" lf bindir
    lf=$(_lockfile_for "$base")
    bindir="$SANDBOX/fakebin-orphan"
    mkdir -p "$bindir"
    # An `act` that leaves a long-lived background process behind, which is exactly
    # what a crashed run does. If fd 9 reaches it, that orphan holds the CI lock.
    cat > "$bindir/act" <<'FAKEACT'
#!/usr/bin/env bash
sleep 30 &
echo "[x/job] 🏁  Job succeeded"
exit 0
FAKEACT
    chmod +x "$bindir/act"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$base"
        PATH="$bindir:$PATH"
        ACT_ARTIFACT_PORT=34567
        VERBOSE=false
        acquire_act_mutex >/dev/null 2>&1 || exit 1
        run_act_job "x.yml" "job" "L" >/dev/null 2>&1
        # Die hard, leaving the stub's background child orphaned.
        kill -9 $BASHPID
    ) >/dev/null 2>&1
    sleep 0.5
    local probe
    probe=$(_probe_lock "$lf")
    if [ "$probe" = "FREE" ]; then
        pass "$name"
    else
        fail "$name" "orphaned act descendant still holds the CI lock (probe=$probe)"
    fi
    pkill -f 'sleep 30' 2>/dev/null
    rm -f "$lf"
}

test_non_timeout_python_failure_is_reported_distinctly() {
    local name="a non-75 python exit is reported with its code, not as a timeout"
    local base="$SANDBOX/f8" bindir out rc
    bindir="$SANDBOX/fakebin-py"
    mkdir -p "$bindir"
    cat > "$bindir/python3" <<'FAKEPY'
#!/usr/bin/env bash
echo "ImportError: no module named fcntl" >&2
exit 3
FAKEPY
    chmod +x "$bindir/python3"
    out=$(
        (
            REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
            . "$LIB"
            ACT_MUTEX_DIR="$base"
            PATH="$bindir:$PATH"
            acquire_act_mutex
        ) 2>&1
    )
    rc=$?
    if [ "$rc" -ne 0 ] \
       && printf '%s' "$out" | grep -q 'python exit 3' \
       && printf '%s' "$out" | grep -qi 'no module named fcntl' \
       && ! printf '%s' "$out" | grep -qi 'timed out'; then
        pass "$name"
    else
        fail "$name" "expected 'python exit 3' + stderr and no timeout wording; got rc=$rc out=[$(printf '%s' "$out" | tr '\n' ' ')]"
    fi
    rm -f "$(_lockfile_for "$base")"
}

test_acquire_fails_closed_without_python3() {
    local name="acquire fails closed when python3 is unavailable"
    local base="$SANDBOX/f6"
    local out rc
    out=$(
        (
            REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
            . "$LIB"
            ACT_MUTEX_DIR="$base"
            PATH=/nonexistent
            acquire_act_mutex
        ) 2>&1
    )
    rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'python3'; then
        pass "$name"
    else
        fail "$name" "expected rc!=0 naming python3; got rc=$rc out=[$out]"
    fi
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

test_residual_forged_marker_with_non_job_error_is_forgiven() {
    local name="RESIDUAL: forged marker + non-Job error is forgiven (documented)"
    # This PINS a known, accepted gap. A step that prints the success marker on its
    # own stdout is indistinguishable from act's real status line, and an act error
    # that never says "Job" clears the other guard. See the residual note in
    # run_act_job. If this test ever flips, the change was deliberate.
    local got
    got=$(_run_act_job_with_fake 'my-step: echoing 🏁  Job succeeded for fun
Error: unable to remove container' 1 h)
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
echo "--- finding 2: mutex (kernel flock) ---"
test_flock_holder_keeps_lock_and_second_acquire_times_out
test_flock_released_when_holder_is_killed
test_flock_survives_the_python_child_that_took_it
test_flock_release_allows_reacquire
test_release_without_ownership_is_a_noop
test_orphaned_act_does_not_hold_the_lock
test_non_timeout_python_failure_is_reported_distinctly
test_acquire_fails_closed_without_python3
echo "--- finding 3: exit-code override ---"
test_override_rejects_forged_marker_on_exit42
test_override_rejects_signal_exit
test_override_rejects_marker_followed_by_failure
test_override_accepts_genuine_cleanup_error
test_override_rejects_failure_before_success
test_override_forgives_trailing_cleanup_error
test_override_rejects_job_required_failed_phrase
test_residual_forged_marker_with_non_job_error_is_forgiven
echo "--- finding 4: ACT_JOBS parsing ---"
test_parse_rejects_colon_prefixed_token
test_parse_rejects_bare_token
test_parse_reads_multiline_value
test_parse_allows_optional_label
echo "--- finding 5: pgrep / lsof ---"
test_find_free_port_fails_closed_without_lsof
test_find_free_port_override_without_lsof
test_reclaim_warns_without_pgrep
echo "--- harness integrity ---"
test_harness_scrubs_act_mutex_held

echo ""
echo "ran $TESTS_RUN, failed $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
echo "ENTRY under test: $ENTRY"
exit 0
