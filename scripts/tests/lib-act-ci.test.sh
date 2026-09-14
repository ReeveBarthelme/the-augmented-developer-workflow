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

# ── Finding C: signal between mkdir and the ownership flag ────────────────

test_contender_timeout_leaves_peer_lock_intact() {
    local name="a contender that times out must NOT delete a peer's unstamped lock"
    local lock="$SANDBOX/m3.lock"
    command mkdir -p "$lock"   # peer holds it, fresh, not yet PID-stamped
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        ACT_MUTEX_WAIT_SECS=0     # give up immediately, then run the EXIT trap
        ACT_MUTEX_POLL_SECS=1
        acquire_act_mutex
    ) >/dev/null 2>&1
    if [ -d "$lock" ]; then
        pass "$name"
        rm -rf "$lock"
    else
        fail "$name" "the failed contender deleted a peer session's lock dir"
    fi
}

test_release_leaves_lock_we_do_not_own() {
    local name="control: release_act_mutex never removes a lock it does not own"
    local lock="$SANDBOX/m5.lock"
    command mkdir -p "$lock"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        release_act_mutex             # _ACT_MUTEX_OWNED deliberately unset
    ) >/dev/null 2>&1
    if [ -d "$lock" ]; then
        pass "$name"
        rm -rf "$lock"
    else
        fail "$name" "release deleted a lock dir this shell never owned"
    fi
}

test_unstamped_lock_expires_by_staleness() {
    local name="an unstamped lock older than the 120s grace window is reaped by a waiter"
    local lock="$SANDBOX/m6.lock"
    command mkdir -p "$lock"
    # Backdate well past the -mmin +2 window. A fixed past timestamp keeps this
    # working on both BSD and GNU touch without date-arithmetic flags.
    touch -t 202001010000 "$lock"
    local rc
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        ACT_MUTEX_WAIT_SECS=0
        ACT_MUTEX_POLL_SECS=1
        acquire_act_mutex             # must reap the stale dir, then take it
    ) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$name"
    else
        fail "$name" "waiter did not reclaim a stale unstamped lock; acquire rc=$rc"
    fi
    rm -rf "$lock"
}

# Interleave a competing reaper against waiter A, mid-reap.
#
# Both tests shadow `warn`, which the reaper calls after deciding a dir is stale and
# before it removes anything. That is a hook point between decision and removal, and
# it needs no test-only code in the library. Inside the hook a peer "B" does what a
# real competitor would: reaps the stale dir, then installs its own live lock at the
# same path. Waiter A must not destroy that.
_reaper_race() {
    local lock="$1" bpid="$2"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        ACT_MUTEX_WAIT_SECS=0
        ACT_MUTEX_POLL_SECS=1
        warn() {
            case "$*" in
                *"Reaping stale act mutex"*)
                    warn() { :; }          # interleave once only
                    rm -rf "$lock"
                    command mkdir -p "$lock"
                    echo "$bpid" > "$lock/pid"
                    ;;
            esac
        }
        acquire_act_mutex
    ) >/dev/null 2>&1
}

test_reaper_race_dead_pid_branch() {
    local name="reaper race (dead-PID branch): a peer's re-acquired lock survives"
    local lock="$SANDBOX/r1.lock"
    rm -rf "$lock"; command mkdir -p "$lock"
    echo "999999" > "$lock/pid"        # a PID that is not alive
    _reaper_race "$lock" "4242"
    local got
    got=$(cat "$lock/pid" 2>/dev/null || echo MISSING)
    check "$name" "$got" "4242"
    rm -rf "$lock"
}

test_reaper_race_unstamped_branch() {
    local name="reaper race (old-unstamped branch): a peer's re-acquired lock survives"
    local lock="$SANDBOX/r2.lock"
    rm -rf "$lock"; command mkdir -p "$lock"
    touch -t 202001010000 "$lock"      # unstamped and past the grace window
    _reaper_race "$lock" "4343"
    local got
    got=$(cat "$lock/pid" 2>/dev/null || echo MISSING)
    check "$name" "$got" "4343"
    rm -rf "$lock"
}

test_two_waiters_race_one_reaps() {
    local name="two waiters on one stale dir: no error, and acquisition still works"
    local lock="$SANDBOX/r3.lock"
    rm -rf "$lock"; command mkdir -p "$lock"
    echo "999999" > "$lock/pid"
    local errlog="$SANDBOX/race.err"
    : > "$errlog"
    local i
    for i in 1 2; do
        (
            REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
            . "$LIB"
            ACT_MUTEX_DIR="$lock"
            ACT_MUTEX_WAIT_SECS=2
            ACT_MUTEX_POLL_SECS=1
            acquire_act_mutex
        ) >>"$errlog" 2>&1 &
    done
    wait
    # A later acquire must still succeed: nothing may be left wedged.
    local rc
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        ACT_MUTEX_WAIT_SECS=3
        ACT_MUTEX_POLL_SECS=1
        acquire_act_mutex
    ) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && ! grep -qiE '^rm:|^mv:|No such file' "$errlog"; then
        pass "$name"
    else
        fail "$name" "acquire rc=$rc; stderr: $(tr '\n' ' ' < "$errlog")"
    fi
    rm -rf "$lock"
}

test_orphaned_tomb_is_swept_by_age() {
    local name="an orphaned reap tomb older than the window is swept, a fresh one is not"
    local lock="$SANDBOX/r4.lock"
    rm -rf "$lock" "$lock".reap.*
    local oldtomb="${lock}.reap.111.1" freshtomb="${lock}.reap.222.2"
    command mkdir -p "$oldtomb" "$freshtomb"
    touch -t 202001010000 "$oldtomb"
    command mkdir -p "$lock"          # something for the waiter to contend with
    echo "999999" > "$lock/pid"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        ACT_MUTEX_WAIT_SECS=0
        ACT_MUTEX_POLL_SECS=1
        acquire_act_mutex
    ) >/dev/null 2>&1
    if [ ! -d "$oldtomb" ] && [ -d "$freshtomb" ]; then
        pass "$name"
    else
        fail "$name" "old tomb exists=$([ -d "$oldtomb" ] && echo yes || echo no), fresh tomb exists=$([ -d "$freshtomb" ] && echo yes || echo no)"
    fi
    rm -rf "$lock" "$oldtomb" "$freshtomb"
}

_age_lock() {
    local lock="$1" secs="$2" stamp
    rm -rf "$lock"; command mkdir -p "$lock"
    stamp=$(date -v-"${secs}"S +%Y%m%d%H%M.%S 2>/dev/null) \
        || stamp=$(date -d "-${secs} seconds" +%Y%m%d%H%M.%S 2>/dev/null) \
        || return 1
    touch -t "$stamp" "$lock"
}

_try_acquire() {
    local lock="$1"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        ACT_MUTEX_WAIT_SECS=0
        ACT_MUTEX_POLL_SECS=1
        acquire_act_mutex
    ) >/dev/null 2>&1
}

test_stale_threshold_is_exact_at_120s() {
    local name="stale window is exactly 120s: 119s kept, 121s reaped"
    local lock="$SANDBOX/age.lock"
    local below above
    _age_lock "$lock" 119 || { fail "$name" "could not backdate (no BSD or GNU date)"; return 0; }
    _try_acquire "$lock"; below=$?          # must NOT reap -> acquire fails
    _age_lock "$lock" 121 || { fail "$name" "could not backdate"; return 0; }
    _try_acquire "$lock"; above=$?          # must reap -> acquire succeeds
    rm -rf "$lock"
    if [ "$below" -ne 0 ] && [ "$above" -eq 0 ]; then
        pass "$name"
    else
        fail "$name" "119s acquire rc=$below (want nonzero), 121s acquire rc=$above (want 0)"
    fi
}

test_mid_acquire_leak_is_bounded_by_stale_expiry() {
    local name="an interrupt right after mkdir leaks a lock, but staleness bounds it"
    local lock="$SANDBOX/m4.lock"
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        # `trap 'exit 130' TERM` is what the library installs, so running `exit 130`
        # the instant the real mkdir returns IS the signal path. A real SIGTERM
        # cannot reach this window: bash defers delivery until the enclosing `while`
        # compound finishes, by which point the ownership flag is already set.
        mkdir() {
            command mkdir "$@" || return $?
            exit 130
        }
        acquire_act_mutex
    ) >/dev/null 2>&1

    # The leak is EXPECTED and accepted: deleting it would mean deleting a dir we
    # cannot prove is ours, which is the bug this replaced.
    if [ ! -d "$lock" ]; then
        fail "$name" "expected the interrupted acquire to leak an unstamped dir"
        return 0
    fi
    # What must hold is that the leak self-heals: a later waiter reaps it once it
    # ages past the grace window.
    touch -t 202001010000 "$lock"
    local rc
    (
        REPO_ROOT="$LIB_ROOT"; export REPO_ROOT
        . "$LIB"
        ACT_MUTEX_DIR="$lock"
        ACT_MUTEX_WAIT_SECS=0
        ACT_MUTEX_POLL_SECS=1
        acquire_act_mutex
    ) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$name"
    else
        fail "$name" "leaked lock was not reclaimable by stale expiry; acquire rc=$rc"
    fi
    rm -rf "$lock"
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
test_contender_timeout_leaves_peer_lock_intact
test_release_leaves_lock_we_do_not_own
test_reaper_race_dead_pid_branch
test_reaper_race_unstamped_branch
test_two_waiters_race_one_reaps
test_orphaned_tomb_is_swept_by_age
test_stale_threshold_is_exact_at_120s
test_unstamped_lock_expires_by_staleness
test_mid_acquire_leak_is_bounded_by_stale_expiry
echo "--- finding 3: exit-code override ---"
test_override_rejects_forged_marker_on_exit42
test_override_rejects_signal_exit
test_override_rejects_marker_followed_by_failure
test_override_accepts_genuine_cleanup_error
test_override_rejects_failure_before_success
test_override_forgives_trailing_cleanup_error
test_override_rejects_job_required_failed_phrase
test_residual_forged_marker_with_non_job_error_is_forgiven
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
