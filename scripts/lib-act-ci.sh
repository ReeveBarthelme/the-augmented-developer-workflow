#!/usr/bin/env bash
# lib-act-ci.sh — shared library for running GitHub Actions locally via nektos/act.
#
# Sourced by scripts/act-local-ci.sh. Do not execute directly.
# Contains: logging, dependency checks, the cross-session mutex, act flags,
# the single-job runner with log retention, parallel dispatch, and the native
# security / shell / workflow-lint checks.
#
# Design: functions return exit codes and never call `exit`. The entry point
# script decides when to exit; `set -euo pipefail` lives there.
#
# WHAT YOU MUST CUSTOMIZE (search for CUSTOMIZE):
#   ACT_JOBS            in the Makefile — which workflow jobs run locally
#   SECURITY_REQ_FILES  Python requirements files for pip-audit
#   SECURITY_SRC_DIRS   source dirs for bandit
#   SHELL_CHECK_DIRS    directories whose *.sh get shellcheck'd
#   BATS_DIRS           directories holding *.bats suites

# Guard against direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: lib-act-ci.sh must be sourced, not executed directly." >&2
    exit 1
fi

# Set by the entry script before sourcing. Declared here so shellcheck sees it
# and so a mis-wired caller fails loudly instead of operating on "/".
: "${REPO_ROOT:?REPO_ROOT must be set by the entry script before sourcing}"

# ── Colors + logging ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[act]${NC} $*"; }
ok()   { echo -e "${GREEN}[act]${NC} $*"; }
warn() { echo -e "${YELLOW}[act]${NC} $*"; }
err()  { echo -e "${RED}[act]${NC} $*" >&2; }

# ── CUSTOMIZE: project paths the native checks scan ───────────────────────
# Space-separated, repo-relative. An entry that does not exist is skipped with
# a note; a TOOL that is not installed is a hard failure (see run_security).
SECURITY_REQ_FILES="${SECURITY_REQ_FILES:-requirements.txt}"
SECURITY_SRC_DIRS="${SECURITY_SRC_DIRS:-src}"
SHELL_CHECK_DIRS="${SHELL_CHECK_DIRS:-scripts .claude/hooks .githooks}"
BATS_DIRS="${BATS_DIRS:-tests}"

# ── Dependency checks ─────────────────────────────────────────────────────
check_deps() {
    local missing=0
    if ! command -v act &>/dev/null; then
        err "act not found. Install: brew install act"
        missing=1
    fi
    if ! command -v docker &>/dev/null; then
        err "docker not found. Install Docker Desktop."
        missing=1
    elif ! docker info &>/dev/null 2>&1; then
        err "Docker daemon not running. Start Docker Desktop."
        missing=1
    fi
    return $missing
}

# ── Secrets + act flags ───────────────────────────────────────────────────
ACT_FLAGS=()
VERBOSE="${VERBOSE:-false}"
FORCE_AMD64="${FORCE_AMD64:-false}"
REUSE="${REUSE:-false}"
PARALLEL="${PARALLEL:-true}"
MERGED_SECRETS_FILE=""

# Resolve the PRIMARY repository's .git directory for a linked-worktree checkout.
#
# A `git worktree` checkout's .git is a FILE holding `gitdir: <primary>/.git/worktrees/<name>`,
# and that directory's `commondir` (typically "../..") points back at <primary>/.git, which
# holds the shared object DB and refs. Both hops must be resolvable for git to work.
#
# Echoes the absolute primary .git path and returns 0 on success; returns 1 (silently) when
# $1 is not a linked worktree or the chain cannot be resolved. Callers decide how to report.
resolve_primary_git_dir() {
    # Named worktree_root, not repo_root: a lowercase repo_root makes shellcheck
    # flag every $REPO_ROOT in this file as a possible misspelling (SC2153).
    local worktree_root="$1"
    [ -f "$worktree_root/.git" ] || return 1

    local worktree_gitdir
    worktree_gitdir=$(sed -n 's/^gitdir: //p' "$worktree_root/.git" | head -1)
    [ -n "$worktree_gitdir" ] || return 1

    # git >= 2.48 (`git worktree add --relative-paths`, or worktree.useRelativePaths=true)
    # writes a RELATIVE pointer, e.g. `gitdir: ../../.git/worktrees/<name>`. It is relative
    # to the directory holding the .git file, NOT to the caller's cwd. Resolving it against
    # $PWD silently finds nothing and skips the mount with only a warning.
    [[ "$worktree_gitdir" == /* ]] || worktree_gitdir="$worktree_root/$worktree_gitdir"
    [ -d "$worktree_gitdir" ] || return 1

    local commondir
    commondir=$(cat "$worktree_gitdir/commondir" 2>/dev/null) || return 1
    [ -n "$commondir" ] || return 1

    # commondir is relative to the worktree gitdir (typically "../.."), but git also
    # permits an absolute path — appending that to the gitdir would produce garbage.
    local commondir_path="$worktree_gitdir/$commondir"
    [[ "$commondir" == /* ]] && commondir_path="$commondir"

    local primary_git_dir
    primary_git_dir=$(cd "$commondir_path" 2>/dev/null && pwd) || return 1
    [ -d "$primary_git_dir" ] || return 1

    echo "$primary_git_dir"
}

# Reject primary-.git paths that would corrupt the parsers the mount flag lands in:
# docker's whitespace-separated option splitter, and a YAML plain scalar (where a
# leading or embedded ` #` starts a comment). Returns 0 when safe, 1 when not.
#
# `$`/`{`/`}` are rejected for a third parser: a path literally containing
# `${{secrets.X}}` passes every other check (no whitespace, no quotes) and would land in a
# YAML plain scalar as a GitHub expression. Rejecting the shape closes the class.
#
# Deliberately a DENY-list, not an allow-list (`*[!A-Za-z0-9._/@+-]*`). An allow-list also
# rejects any path containing a non-ASCII character, so a developer whose home directory
# carries an accent would silently lose the git mount. The exploit this trades against
# needs a directory literally named `${{secrets.X}}`, and anyone able to create it already
# controls `commondir`, hence `.git/hooks`, hence host code execution.
git_mount_path_is_safe() {
    case "$1" in
        *[[:space:]]*|*'#'*|*'"'*|*"'"*|*\\*|*:*|*'$'*|*'{'*|*'}'*) return 1 ;;
    esac
    return 0
}

build_act_flags() {
    # Auto-create required config files if missing (common in a fresh worktree).
    if [[ ! -f "$REPO_ROOT/.act-secrets" ]]; then
        warn ".act-secrets not found — creating an empty file."
        : > "$REPO_ROOT/.act-secrets"
        chmod 600 "$REPO_ROOT/.act-secrets"
    fi
    if [[ ! -f "$REPO_ROOT/.act-env" ]]; then
        warn ".act-env not found — creating with defaults."
        # Paths here must be HOST paths: .actrc sets --bind, which mounts the host
        # directory directly, so there is no /workdir inside the container.
        cat > "$REPO_ROOT/.act-env" <<ACTENV
CI=true
ACTENV
    fi

    # Register the cleanup trap BEFORE creating any sensitive file. cleanup_secrets()
    # is a no-op while MERGED_SECRETS_FILE is empty, so calling it early is safe and
    # closes the window where a secrets file exists with no trap to remove it.
    #
    # EXIT runs on every exit, signals included. The explicit `exit 130` on INT is
    # needed because `|| exit_code=$?` in run_act_job swallows the signal status and
    # the script would otherwise continue to the next job after Ctrl+C.
    trap 'cleanup_secrets; release_act_mutex' EXIT
    trap 'exit 130' INT TERM HUP

    # Merged secrets file, so secrets never appear in `ps` output.
    MERGED_SECRETS_FILE=$(mktemp "${TMPDIR:-/tmp}/act-secrets-XXXXXXXX")
    chmod 600 "$MERGED_SECRETS_FILE"
    cp "$REPO_ROOT/.act-secrets" "$MERGED_SECRETS_FILE"

    # SECURITY: do NOT auto-inject `gh auth token` as GITHUB_TOKEN. That token is the
    # user's personal credential with full account access, and it would be visible to
    # every workflow step including third-party actions. Create a fine-grained PAT with
    # only `contents:read` and add it to .act-secrets by hand.
    if ! grep -q '^GITHUB_TOKEN=' "$REPO_ROOT/.act-secrets" 2>/dev/null; then
        warn "No GITHUB_TOKEN in .act-secrets. Action downloads may fail."
        warn "Create a fine-grained PAT (contents:read) and add it to .act-secrets."
    fi

    # Pip/npm cache volumes persist across container recreations.
    # --bind is configured in .actrc (see .actrc.example): it bind-mounts the host repo
    # into the container instead of copying it, which is what makes the host-path
    # handling below correct.
    local container_opts="-v act-pip-cache:/root/.cache/pip -v act-npm-cache:/root/.npm"

    # Linked-worktree git context. In a `git worktree` checkout, $REPO_ROOT/.git is a
    # FILE pointing at <primary>/.git/worktrees/<name>, whose `commondir` points back at
    # <primary>/.git. --bind mounts ONLY $REPO_ROOT, so both hops dangle inside the
    # container and every git invocation dies with "fatal: not a git repository: (null)",
    # failing any git-dependent CI step. Mounting the primary .git at its IDENTICAL host
    # path fixes both hops, because --bind preserves absolute paths. Read-only is enough
    # and keeps a root container out of the object DB shared by every worktree.
    #
    # KNOWN GAP: act silently drops --container-options for any job that declares a
    # job-level `container:` block. Such a job in a linked worktree still loses the
    # mount. Add `options: -v <primary>/.git:<primary>/.git:ro` to that job's
    # container block by hand, or run pre-merge from the primary checkout.
    if [[ -f "$REPO_ROOT/.git" ]]; then
        local primary_git_dir
        if ! primary_git_dir=$(resolve_primary_git_dir "$REPO_ROOT"); then
            warn "Linked worktree detected but the primary git dir could not be resolved."
            warn "Git-dependent CI steps will fail inside the container."
        elif ! git_mount_path_is_safe "$primary_git_dir"; then
            warn "Primary git dir contains characters unsafe for docker options: $primary_git_dir"
            warn "Skipping the git mount — git-dependent CI steps will fail inside the container."
        else
            container_opts+=" -v ${primary_git_dir}:${primary_git_dir}:ro"
            log "Linked worktree detected — mounting primary git dir read-only: $primary_git_dir"
        fi
    fi

    ACT_FLAGS=(
        --secret-file "$MERGED_SECRETS_FILE"
        --env-file "$REPO_ROOT/.act-env"
        --detect-event
        --container-options "$container_opts"
    )

    if [[ "$REUSE" == "true" ]]; then
        ACT_FLAGS+=(--reuse)
        log "Container reuse enabled (skips pip/npm install on subsequent runs)"
    fi

    if [[ "$FORCE_AMD64" == "true" ]]; then
        ACT_FLAGS+=(--container-architecture linux/amd64)
    fi
}

cleanup_secrets() {
    if [[ -n "$MERGED_SECRETS_FILE" && -f "$MERGED_SECRETS_FILE" ]]; then
        rm -f "$MERGED_SECRETS_FILE"
    fi
}

# ── Run a single act job ──────────────────────────────────────────────────
# run_act_job <workflow-file> <job-id> [label]
#
# The workflow must be triggerable by `workflow_dispatch`, or --detect-event must
# find a matching trigger. A workflow with only `on: pull_request` will not run.
run_act_job() {
    local workflow="$1"
    local job="$2"
    local label="${3:-$workflow/$job}"

    log "${BOLD}Running: ${label}${NC}"
    local start_time
    start_time=$(date +%s)
    # Workflow AND job in the log name: several workflows commonly share a job id
    # (a "quality" job in each), and a shared name would overwrite the other's log.
    local logfile="${TMPDIR:-/tmp}/act-output-${workflow%%.*}-${job}-$$.log"

    # Per-group artifact server port. ACT_ARTIFACT_PORT is set by run_parallel before
    # forking, so each parallel group gets a unique free port; jobs inside a group are
    # serial and can share one. A serial call allocates dynamically but MUST stay inside
    # this session's window, or it could take a neighbouring session's reserved port.
    local job_port="${ACT_ARTIFACT_PORT:-}"
    if [[ -z "$job_port" ]]; then
        local sbase
        sbase=$(act_port_base)
        # find_free_port returns non-zero on exhaustion. Without this `if` the
        # assignment's failure would abort the entry script's `set -e` silently.
        if ! job_port=$(find_free_port "$sbase" "$(( sbase + ACT_PORT_WINDOW ))"); then
            err "${label} — no free artifact-server port in this session's window [$sbase, $(( sbase + ACT_PORT_WINDOW )))"
            return 1
        fi
    fi
    local job_artifact_dir
    job_artifact_dir=$(mktemp -d "${TMPDIR:-/tmp}/act-artifacts-XXXXXXXX")

    local act_cmd=(
        act workflow_dispatch
        -W "$REPO_ROOT/.github/workflows/$workflow"
        -j "$job"
        ${ACT_FLAGS[@]+"${ACT_FLAGS[@]}"}
        --artifact-server-port "$job_port"
        --artifact-server-path "$job_artifact_dir"
    )

    # `9>&-` closes the CI-lock descriptor for act and everything act spawns.
    # Without it a crashed run's orphaned act keeps the flock held, and every later
    # run waits out ACT_MUTEX_WAIT_SECS instead of reaching reclaim_orphaned_act_ports.
    # act never needs the lock itself; the shell that launched it holds it.
    local exit_code=0
    if [[ "$VERBOSE" == "true" ]]; then
        "${act_cmd[@]}" 9>&- || exit_code=$?
    else
        "${act_cmd[@]}" > "$logfile" 2>&1 9>&- || exit_code=$?
    fi

    local elapsed=$(( $(date +%s) - start_time ))

    # act returns non-zero for Docker CLEANUP failures (a volume delete timing out)
    # even when the job itself succeeded. This override exists for that one case only.
    #
    # act 0.2.84 returns exit 1 for BOTH a real job failure and a post-job Docker
    # cleanup error, so the exit code alone cannot tell them apart. The log has to.
    #
    # Every one of these must hold before a non-zero exit is forgiven:
    #   * the exit code is exactly 1 (so a signal death, always > 128, never qualifies)
    #   * at least one "🏁  Job succeeded" line is present
    #   * NO "🏁  Job failed" line appears anywhere in the log
    #   * NO "Job ... failed" line appears anywhere, which catches
    #     "Error: Job required failed" — act prints that without the emoji marker
    #
    # Reading only the LAST status marker was wrong: a run that failed one job and
    # then succeeded at another reported PASSED, erasing the real failure.
    #
    # A bare "Error: ..." line is deliberately NOT disqualifying. "Error: unable to
    # remove container" after a clean run is the exact cleanup case this override
    # exists for; treating every "Error:" as fatal would delete the whole feature.
    #
    # KNOWN RESIDUAL, accepted on purpose. A job whose own step prints
    # "🏁  Job succeeded" on stdout, in a run whose act error text never contains the
    # word "Job", is forgiven. The printed marker is byte-identical to act's real
    # status line, so no log-scraping predicate can separate them; closing this needs
    # act to emit a machine-readable result, which it does not.
    #
    # Why keep the override at all: act 0.2.84 exits 1 for a container cleanup error
    # just as it does for a job failure, so removing it brings back false reds on
    # every run where Docker is slow to release a volume. Why the residual is
    # tolerable: this is a self-hosted pre-merge gate, so a developer who prints that
    # marker to dodge it is only sabotaging their own branch, and CI still runs the
    # real workflows. The behavior is pinned by the test named
    # "RESIDUAL: forged marker + non-Job error is forgiven (documented)" so changing
    # it has to be a deliberate act.
    if [[ $exit_code -eq 1 && -f "$logfile" ]]; then
        if grep -qF '🏁  Job succeeded' "$logfile" \
           && ! grep -qF '🏁  Job failed' "$logfile" \
           && ! grep -qE 'Job .* failed' "$logfile"; then
            warn "${label} — act cleanup error after a clean run; treating as passed"
            exit_code=0
        fi
    fi

    if [[ $exit_code -eq 0 ]]; then
        ok "${label} — ${GREEN}PASSED${NC} (${elapsed}s)"
        rm -f "$logfile"
    else
        err "${label} — ${RED}FAILED${NC} (${elapsed}s)"
        if [[ "$VERBOSE" != "true" && -f "$logfile" ]]; then
            echo ""
            warn "Last 30 lines of output:"
            tail -30 "$logfile"
            echo ""
            warn "Full log retained at: $logfile"
        fi
    fi

    rm -rf "$job_artifact_dir"
    return $exit_code
}

# An ACT_JOBS entry: workflow.yml:job, with an optional :Label third field.
# Anchored and colon-free within each field, so a bare `ci.yml` cannot be read as both
# the workflow AND the job (`${spec#*:}` returns the whole string when there is no
# colon, which is how that silently happened), and a `:job` with no workflow is caught.
ACT_JOB_SPEC_RE='^[^:[:space:]]+\.ya?ml:[^:[:space:]]+(:[^:[:space:]]+)?$'

# parse_act_jobs "<raw ACT_JOBS value>" — split on ANY whitespace, validate, echo the
# accepted specs one per line. Returns 1 and names every bad token instead.
#
# The split must cover newlines. `read -r -a` stops at the first one, so a multi-line
# ACT_JOBS silently ran only its first entry and the gate shrank without saying so.
# Nothing is echoed when validation fails, so a caller cannot consume a partial list.
parse_act_jobs() {
    local raw="${1:-}"
    local -a tokens=() good=() bad=()
    local t
    # Split by rewriting every space and tab to a newline and reading line by line,
    # rather than by unquoted expansion. That avoids two traps at once: an unquoted
    # `$raw` globs a spec containing `*` against the cwd, and it depends on the shell
    # doing word splitting at all, which zsh does not.
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        tokens+=("$t")
    # The trailing newline is load-bearing: without it `read` hits EOF on the final
    # token, returns non-zero, and the loop discards that token. `printf '%s'` alone
    # silently dropped the LAST spec of every list.
    done < <(printf '%s\n' "$raw" | tr ' \t' '\n\n')
    for t in ${tokens[@]+"${tokens[@]}"}; do
        if [[ "$t" =~ $ACT_JOB_SPEC_RE ]]; then
            good+=("$t")
        else
            bad+=("$t")
        fi
    done
    if [[ ${#bad[@]} -gt 0 ]]; then
        err "Malformed ACT_JOBS entries (want workflow.yml:job, optionally :Label):"
        for t in "${bad[@]}"; do err "  bad token: '$t'"; done
        return 1
    fi
    for t in ${good[@]+"${good[@]}"}; do printf '%s\n' "$t"; done
    return 0
}

# run_act_jobs "<spec> [<spec> ...]" — each spec is workflow.yml:job[:Label]
# Runs them serially and returns 1 if any failed.
run_act_jobs() {
    local specs=("$@")
    local failed=0 spec wf job label
    if [[ ${#specs[@]} -eq 0 ]]; then
        err "No act jobs configured. Set ACT_JOBS in the Makefile, e.g."
        err '  ACT_JOBS = ci.yml:test:Unit-tests ci.yml:lint'
        return 1
    fi
    for spec in "${specs[@]}"; do
        # Re-validate here too: this function is reachable directly, not only through
        # parse_act_jobs, and an unvalidated spec is what produced the bare-token bug.
        if [[ ! "$spec" =~ $ACT_JOB_SPEC_RE ]]; then
            err "Malformed ACT_JOBS entry: '$spec' (want workflow.yml:job[:Label])"
            failed=1
            continue
        fi
        wf="${spec%%:*}"
        local rest="${spec#*:}"
        job="${rest%%:*}"
        label="${rest#*:}"
        [[ "$label" == "$rest" ]] && label="$wf/$job"
        if [[ ! -f "$REPO_ROOT/.github/workflows/$wf" ]]; then
            err "Workflow not found: .github/workflows/$wf (from ACT_JOBS entry '$spec')"
            failed=1
            continue
        fi
        run_act_job "$wf" "$job" "$label" || failed=1
    done
    return $failed
}

# ── Reclaim orphaned act processes ────────────────────────────────────────
# A killed run leaves its act process reparented to init, still holding its
# artifact-server port. Dynamic allocation means orphans no longer block new runs,
# but they leak processes and shrink the window — reap them.
#
# Kills ONLY orphaned act processes (parent dead). A live parent means an active
# concurrent run; never kill someone else's in-flight CI. Scoped to the act process,
# not Docker containers: act-* container names cannot be mapped back to the dead PID
# and a blanket `docker rm` would destroy a live run's containers.
reclaim_orphaned_act_ports() {
    # Without pgrep this function cannot see anything and would silently no-op,
    # reading as "no orphans found". Say so instead.
    if ! command -v pgrep &>/dev/null; then
        warn "pgrep not found — cannot detect orphaned act processes, so their ports stay reserved."
        warn "Install it (it ships with procps on Linux, and with macOS) to re-enable reaping."
        return 0
    fi
    local pid ppid killed=0
    # Exact process-name match: *act* would also match react, redact, compact.
    for pid in $(pgrep -x act 2>/dev/null); do
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ "$ppid" == "1" ]] || ! kill -0 "$ppid" 2>/dev/null; then
            warn "Reaping orphaned act process (pid $pid, parent dead)"
            kill "$pid" 2>/dev/null && killed=1
        fi
    done
    [[ "$killed" == "1" ]] && sleep 1 || true  # let the OS release freed ports
}

# ── Dynamic artifact-server port allocation ───────────────────────────────
# A FIXED base port makes concurrent local-CI sessions collide: the loser's act dies
# at bind time with every executed check passing, producing a confusing
# "all PASSED + Error 1" result. Ports must be session-unique.
#
# Each session gets a RESERVED, DISJOINT window of ACT_PORT_WINDOW ports keyed on its
# PID, and allocations are bounded to that window (see find_free_port's LIMIT arg), so
# two sessions in different windows can never share a port. The residual is two PIDs
# hashing to the same window, the pigeonhole floor.
#
# ACT_PORT_WINDOW must exceed the number of parallel groups, which is the number of
# DISTINCT workflow files named in ACT_JOBS. Raise it if you run more than four
# workflows locally; the spare ports absorb in-window contention.
ACT_PORT_FLOOR=34567
ACT_PORT_SESSIONS=128
ACT_PORT_WINDOW=4

# act_port_base [PID]: first port of this session's reserved window. PID defaults to
# $$; the argument makes the mapping unit-testable.
act_port_base() {
    local pid="${1:-$$}"
    echo $(( ACT_PORT_FLOOR + (pid % ACT_PORT_SESSIONS) * ACT_PORT_WINDOW ))
}

# find_free_port BASE [LIMIT [EXCLUDE...]]: first free port in [BASE, LIMIT) that is
# neither listening nor in EXCLUDE. LIMIT is an EXCLUSIVE upper bound; omit it for an
# unbounded scan. The bounded scan NEVER returns a port >= LIMIT, so a start at the
# boundary cannot leak into a neighbour's window.
#
# On exhaustion it prints NOTHING and returns 1. It used to return BASE, which handed
# two callers the same port and reproduced the "everything PASSED, exit 1" confusion
# the window exists to prevent. Callers must test the return value; an assignment like
# `p=$(find_free_port ...)` silently swallows it under `set -e`.
#
# Without lsof a port cannot be checked for a listener at all, so this fails closed and
# returns 2 rather than handing out an unverified port. ACT_ALLOW_UNVERIFIED_PORTS=1
# opts back in for an environment where installing lsof is not possible.
#
# EXCLUDE lets a caller reserve ports it has handed out but that are not bound yet:
# lsof cannot see a sibling act that has not started, so in-process exclusion is what
# keeps two groups in the SAME window off one port.
find_free_port() {
    local port=$1
    local limit=${2:-}
    local excluded=()
    [[ $# -gt 2 ]] && excluded=("${@:3}")

    # Diagnostics go to stderr: this function's stdout IS the port value, and a
    # warning printed there would be captured as part of it.
    local have_lsof=1
    command -v lsof &>/dev/null || have_lsof=0
    if [[ "$have_lsof" -eq 0 ]]; then
        if [[ "${ACT_ALLOW_UNVERIFIED_PORTS:-}" == "1" ]]; then
            warn "lsof not found — handing out ports UNVERIFIED (ACT_ALLOW_UNVERIFIED_PORTS=1)." >&2
        else
            err "lsof not found, so no port can be checked for an existing listener."
            err "Install it (brew install lsof), or set ACT_ALLOW_UNVERIFIED_PORTS=1 to accept the risk."
            return 2
        fi
    fi

    if [[ -n "$limit" ]]; then
        while [[ "$port" -lt "$limit" ]]; do
            local skip=0 ex
            for ex in ${excluded[@]+"${excluded[@]}"}; do
                [[ "$ex" == "$port" ]] && { skip=1; break; }
            done
            if [[ "$skip" -eq 0 ]]; then
                if [[ "$have_lsof" -eq 0 ]] || ! lsof -ti "tcp:$port" &>/dev/null; then
                    echo "$port"; return 0
                fi
            fi
            port=$(( port + 1 ))
        done
        return 1   # window exhausted — fail closed, never reuse the base port
    fi

    if [[ "$have_lsof" -eq 1 ]]; then
        while lsof -ti "tcp:$port" &>/dev/null; do
            port=$(( port + 1 ))
        done
    fi
    echo "$port"
}

# ── Run parallel groups ───────────────────────────────────────────────────
# run_parallel <fn> <arg-group> [<arg-group> ...]
# Calls `<fn> <group>` for each group concurrently, one artifact-server port each.
#
# `--artifact-server-port 0` is NOT an option: act passes the literal "0" into
# ACTIONS_RUNTIME_URL and containers get an unreachable http://addr:0/.
run_parallel() {
    local fn="$1"; shift
    local groups=("$@")
    local pids=()
    local failed=0

    # Fail closed BEFORE anything is forked. This session's window holds exactly
    # ACT_PORT_WINDOW ports, so a K-th group past that has no port of its own and
    # would have shared one with an earlier group, which is the bind collision the
    # window exists to prevent. Refusing is better than a half-launched run.
    if [[ ${#groups[@]} -gt $ACT_PORT_WINDOW ]]; then
        err "${#groups[@]} parallel groups requested but this session's port window holds only $ACT_PORT_WINDOW."
        err "Raise ACT_PORT_WINDOW in scripts/lib-act-ci.sh, or run with --serial."
        return 1
    fi

    reclaim_orphaned_act_ports

    # Bound every allocation to THIS session's window so a busy port cannot push a
    # group's scan into a neighbour's. Scan from the window base each time, EXCLUDING
    # ports already handed out: scanning from prev+1 could walk off the window's end,
    # and lsof cannot see a sibling act that has not bound yet.
    local base window_end used=()
    base=$(act_port_base)
    window_end=$(( base + ACT_PORT_WINDOW ))

    # Allocate EVERY port up front. Allocating inside the fork loop means an
    # exhaustion on group 3 leaves groups 1 and 2 already running with no way to
    # reach them; here nothing has started yet when we give up.
    #
    # LIMITATION: this is not an atomic cross-session reservation. It prevents
    # collisions WITHIN this run; across runs the only thing keeping two sessions off
    # one window is the global act mutex, which serializes them. A caller that
    # bypasses the mutex, or sets ACT_MUTEX_DIR to a different namespace, can still
    # race another session for these ports.
    local ports=() p ai
    for (( ai = 0; ai < ${#groups[@]}; ai++ )); do
        if ! p=$(find_free_port "$base" "$window_end" ${used[@]+"${used[@]}"}); then
            err "No free artifact-server port left in [$base, $window_end) for ${#groups[@]} parallel groups."
            err "Another session may hold ports in this window; retry, or run with --serial."
            return 1
        fi
        used+=("$p")
        ports+=("$p")
    done

    local prev_int_trap prev_term_trap
    prev_int_trap=$(trap -p INT)
    prev_term_trap=$(trap -p TERM)

    trap '__parallel_cleanup INT "${pids[@]}"' INT
    trap '__parallel_cleanup TERM "${pids[@]}"' TERM

    local gi
    for gi in "${!groups[@]}"; do
        # export is required: & forks a subshell, which only inherits exported vars.
        export ACT_ARTIFACT_PORT="${ports[$gi]}"
        # `9>&-`: the background group never needs the CI lock, and closing it here
        # means no descendant of this fork can keep the lock alive after the parent
        # dies. Belt and braces with the same close on the act call itself.
        # shellcheck disable=SC2086 # group is an intentionally word-split job spec list
        "$fn" ${groups[$gi]} 9>&- &
        pids+=($!)
    done
    unset ACT_ARTIFACT_PORT  # do not leak into later serial calls

    local i
    for i in "${!pids[@]}"; do
        if ! wait "${pids[$i]}"; then
            failed=1
        fi
    done

    # Restore exactly what was there before, not a hardcoded string. An empty result
    # from `trap -p` means no trap was set, so restore the default: `eval ""` is a no-op
    # and would leave the parallel cleanup trap in place.
    if [[ -n "$prev_int_trap" ]]; then eval "$prev_int_trap"; else trap - INT; fi
    if [[ -n "$prev_term_trap" ]]; then eval "$prev_term_trap"; else trap - TERM; fi

    return $failed
}

# Kill all parallel children on a signal, then re-raise it so the shell's default
# handler runs and the EXIT trap fires.
__parallel_cleanup() {
    local sig="$1"; shift
    local pids=("$@")
    local p
    for p in "${pids[@]}"; do
        kill "$p" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    trap - "$sig"
    kill "-$sig" "$$"
}

# ── Native security checks ────────────────────────────────────────────────
# Mirrors .github/workflows/security.yml so a bad dependency or a leaked secret is
# caught before the merge, not after. Runs natively; these tools do not need Docker.
#
# A tool that is NOT INSTALLED is a FAILURE, not a skip. A silent skip turns this gate
# into decoration: it reports green on a machine where nothing ran. Install the tools,
# or skip the whole gate explicitly with SKIP_SECURITY=true.
#
# A configured PATH that does not exist IS skipped with a note — that is a project
# using a subset of the scanners, not a broken environment.
run_security() {
    case "${SKIP_SECURITY:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss])
            warn "Security scans skipped (SKIP_SECURITY=${SKIP_SECURITY})"
            return 0
            ;;
    esac

    log "${BOLD}Running security scans (native)${NC}"
    local failed=0

    # pip-audit — known CVEs in Python dependencies.
    local req_args=() f
    for f in $SECURITY_REQ_FILES; do
        [[ -f "$REPO_ROOT/$f" ]] && req_args+=(-r "$REPO_ROOT/$f")
    done
    if [[ ${#req_args[@]} -eq 0 ]]; then
        log "pip-audit — no requirements files found (SECURITY_REQ_FILES='$SECURITY_REQ_FILES'), skipping"
    elif ! command -v pip-audit &>/dev/null; then
        err "pip-audit not installed (pip install pip-audit) — REQUIRED for pre-merge"
        failed=1
    else
        log "pip-audit..."
        if pip-audit "${req_args[@]}" 2>&1; then
            ok "pip-audit — ${GREEN}PASSED${NC}"
        else
            err "pip-audit — ${RED}FAILED${NC}"
            failed=1
        fi
    fi

    # bandit — Python static analysis, medium severity and above.
    local src_args=() d
    for d in $SECURITY_SRC_DIRS; do
        [[ -d "$REPO_ROOT/$d" ]] && src_args+=("$REPO_ROOT/$d")
    done
    if [[ ${#src_args[@]} -eq 0 ]]; then
        log "bandit — no source dirs found (SECURITY_SRC_DIRS='$SECURITY_SRC_DIRS'), skipping"
    elif ! command -v bandit &>/dev/null; then
        err "bandit not installed (pip install 'bandit[toml]') — REQUIRED for pre-merge"
        failed=1
    else
        log "bandit..."
        local bandit_args=(-r "${src_args[@]}" -ll -f txt)
        [[ -f "$REPO_ROOT/pyproject.toml" ]] && bandit_args+=(-c "$REPO_ROOT/pyproject.toml")
        if bandit "${bandit_args[@]}" 2>&1; then
            ok "bandit — ${GREEN}PASSED${NC}"
        else
            err "bandit — ${RED}FAILED${NC}"
            failed=1
        fi
    fi

    # npm audit — production dependencies only. Dev-dependency advisories are noisy
    # and rarely reachable at runtime; track those on a schedule instead.
    if [[ ! -f "$REPO_ROOT/package.json" ]]; then
        log "npm audit — no package.json, skipping"
    elif ! command -v npm &>/dev/null; then
        err "npm not installed — REQUIRED for pre-merge (package.json is present)"
        failed=1
    else
        log "npm audit..."
        if (cd "$REPO_ROOT" && npm audit --audit-level=high --omit=dev 2>&1); then
            ok "npm audit — ${GREEN}PASSED${NC}"
        else
            err "npm audit — ${RED}FAILED${NC}"
            failed=1
        fi
    fi

    # gitleaks — secrets committed to the repo.
    if ! command -v gitleaks &>/dev/null; then
        err "gitleaks not installed (brew install gitleaks) — REQUIRED for pre-merge"
        failed=1
    else
        log "gitleaks..."
        local gl_args=(detect --source "$REPO_ROOT" --no-banner)
        [[ -f "$REPO_ROOT/.gitleaks.toml" ]] && gl_args+=(--config "$REPO_ROOT/.gitleaks.toml")
        if gitleaks "${gl_args[@]}" 2>&1; then
            ok "gitleaks — ${GREEN}PASSED${NC}"
        else
            err "gitleaks — ${RED}FAILED${NC}"
            failed=1
        fi
    fi

    if [[ $failed -eq 0 ]]; then
        ok "${BOLD}All security scans passed${NC}"
    else
        err "${BOLD}Some security scans failed${NC}"
    fi
    return $failed
}

# ── Shell checks (native) ─────────────────────────────────────────────────
# Runs shellcheck over SHELL_CHECK_DIRS and bats over BATS_DIRS. Both skip with a
# note when the tool is absent, because unlike the security scanners these are lint,
# not a supply-chain guard — a missing linter does not let a vulnerability through.
run_shell_checks() {
    local failed=0
    local dirs=() d
    for d in $SHELL_CHECK_DIRS; do
        [[ -d "$REPO_ROOT/$d" ]] && dirs+=("$REPO_ROOT/$d")
    done

    if [[ ${#dirs[@]} -eq 0 ]]; then
        log "shellcheck — none of SHELL_CHECK_DIRS ('$SHELL_CHECK_DIRS') exist, skipping"
    elif ! command -v shellcheck &>/dev/null; then
        warn "shellcheck not installed (brew install shellcheck) — skipping"
    else
        log "${BOLD}Running: shellcheck (native)${NC}"
        # --severity=warning, because this template's own scripts are clean at that
        # level. Loosen to error if you are adopting it onto an existing script tree.
        if find "${dirs[@]}" -name '*.sh' -type f -print0 | \
            xargs -0 shellcheck --format=gcc --severity=warning; then
            ok "shellcheck — ${GREEN}PASSED${NC}"
        else
            err "shellcheck — ${RED}FAILED${NC}"
            failed=1
        fi
    fi

    # Plain-bash `*.test.sh` suites under the same dirs. These are NOT bats files and
    # nothing else would run them, so a suite could sit in the tree passing shellcheck
    # while never being executed. Each must exit 0 on success.
    local sh_tests=() t
    if [[ ${#dirs[@]} -gt 0 ]]; then
        while IFS= read -r t; do
            [[ -n "$t" ]] && sh_tests+=("$t")
        done < <(find "${dirs[@]}" -name '*.test.sh' -type f 2>/dev/null | sort)
    fi
    if [[ ${#sh_tests[@]} -eq 0 ]]; then
        log "shell tests — no *.test.sh files found, skipping"
    else
        log "${BOLD}Running: ${#sh_tests[@]} shell test suite(s)${NC}"
        for t in "${sh_tests[@]}"; do
            if bash "$t"; then
                ok "$(basename "$t") — ${GREEN}PASSED${NC}"
            else
                err "$(basename "$t") — ${RED}FAILED${NC}"
                failed=1
            fi
        done
    fi

    local bats_dirs=()
    for d in $BATS_DIRS; do
        [[ -d "$REPO_ROOT/$d" ]] && \
            [[ -n "$(find "$REPO_ROOT/$d" -name '*.bats' -type f -print -quit)" ]] && \
            bats_dirs+=("$REPO_ROOT/$d")
    done
    if [[ ${#bats_dirs[@]} -eq 0 ]]; then
        log "bats — no *.bats files under BATS_DIRS ('$BATS_DIRS'), skipping"
    elif ! command -v bats &>/dev/null; then
        warn "bats not installed (brew install bats-core) — skipping"
    else
        log "${BOLD}Running: bats (native)${NC}"
        if bats "${bats_dirs[@]}"; then
            ok "bats — ${GREEN}PASSED${NC}"
        else
            err "bats — ${RED}FAILED${NC}"
            failed=1
        fi
    fi

    return $failed
}

# ── Workflow lint (native) ────────────────────────────────────────────────
# actionlint catches unknown runner labels, expressions referencing outputs no step
# produces, and (through its shellcheck integration) shell errors inside `run:` blocks.
# Only error-severity shellcheck findings fail; info/style/warning noise is ignored.
# Declare custom self-hosted runner labels in .github/actionlint.yaml.
run_workflow_lint() {
    if [[ ! -d "$REPO_ROOT/.github/workflows" ]]; then
        log "actionlint — no .github/workflows, skipping"
        return 0
    fi
    if ! command -v actionlint &>/dev/null; then
        warn "actionlint not installed (brew install actionlint) — skipping workflow lint"
        return 0
    fi

    log "${BOLD}Running: actionlint (native)${NC}"
    local shellcheck_bin=""
    command -v shellcheck &>/dev/null && shellcheck_bin="$(command -v shellcheck)"

    if actionlint -shellcheck="$shellcheck_bin" -ignore 'SC[0-9]+:(info|style|warning):' \
        "$REPO_ROOT"/.github/workflows/*.yml; then
        ok "actionlint — ${GREEN}PASSED${NC}"
        return 0
    else
        err "actionlint — ${RED}FAILED${NC} (see findings above)"
        return 1
    fi
}

# ── Git hooks liveness ────────────────────────────────────────────────────
# Test the PROPERTY (does git resolve a hooks dir that IS this repo's .githooks?),
# not the spelling of the config value. An exact string compare against ".githooks"
# fails a perfectly live clone configured with the absolute path.
#
#   hooksPath unset        -> resolves to .git/hooks -> FAIL (hooks are dark)
#   hooksPath -> elsewhere                           -> FAIL
#   hooksPath=.githooks (relative)                   -> PASS
#   hooksPath=<abs>/.githooks                        -> PASS
check_git_hooks_path() {
    [[ -d "$REPO_ROOT/.githooks" ]] || return 0   # project has no .githooks — nothing to check
    local resolved expected
    resolved=$(cd "$(git -C "$REPO_ROOT" rev-parse --git-path hooks)" 2>/dev/null && pwd -P)
    expected=$(cd "$REPO_ROOT/.githooks" 2>/dev/null && pwd -P)
    if [[ -z "$resolved" || "$resolved" != "$expected" ]]; then
        err "git resolves hooks to '$resolved' (expected '$expected') — the .githooks gates are DARK in this clone."
        err "Fix:   git config core.hooksPath .githooks"
        return 1
    fi
    ok "git hooks — ${GREEN}LIVE${NC} ($expected)"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Cross-session act mutex, on a kernel flock.
#
# Concurrent Docker-based act runs share one Docker Desktop VM. The loser (often
# both) gets its install/test steps OOM-killed with daemon errors that look exactly
# like a red gate at the summary level. Serialize the runs.
#
# Why flock and not a lock directory: the kernel drops the lock when the holder
# dies, so there is no staleness model, no reaper, and no compare-and-delete to get
# wrong. Every race the directory version had came from deciding a lock was
# abandoned and then deleting it as a separate step. macOS ships no flock(1), so
# python3 takes the lock on a descriptor this shell already holds. The lock lives on
# one machine's kernel: it does NOT serialize across NFS or between containers.
#
# One inherited-descriptor caveat, measured rather than assumed. Children inherit
# fd 9, so an orphan that outlives this shell keeps the lock held until it too dies.
# For act that is the behaviour we want, since the lock should cover the whole run,
# but a wedged orphan holds it. reclaim_orphaned_act_ports already reaps orphaned act
# processes. A command that must not hold the lock can close it with `9>&-`.
# ─────────────────────────────────────────────────────────────────────────

# ACT_MUTEX_DIR keeps its name for the override path and its warning, but it now
# names the LOCK FILE's location rather than a directory that gets created.
ACT_MUTEX_DIR_OVERRIDDEN="${ACT_MUTEX_DIR:+1}"
ACT_MUTEX_DIR="${ACT_MUTEX_DIR:-${TMPDIR:-/tmp}/act-ci-global.lock}"
ACT_MUTEX_LOCKFILE="${ACT_MUTEX_DIR%/}.lock"

# Fixed descriptor 9, not bash 4.1's `exec {fd}>>`: macOS ships bash 3.2.57, which
# has no dynamic-fd form, and this template has to run there. Nothing else in these
# scripts uses fd 9.
ACT_MUTEX_FD=9

# Ownership flag. Not exported, so a forked child never releases its parent's lock.
_ACT_MUTEX_OWNED=""

# Take an exclusive lock on the descriptor this shell already holds, waiting up to
# $1 seconds and re-trying every $2. Exits 0 on success, 75 on timeout.
#
# flock binds to the open file DESCRIPTION, not to the process that called it, so the
# lock stays held in this shell after python exits. That is the whole trick, and it is
# asserted by the test named "lock survives the python child that took it".
_act_flock_acquire() {
    local wait_secs="$1" poll_secs="$2"
    python3 - "$ACT_MUTEX_FD" "$wait_secs" "$poll_secs" <<'PY'
import fcntl, sys, time

fd = int(sys.argv[1])
deadline = time.time() + float(sys.argv[2])
poll = max(float(sys.argv[3]), 0.1)
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except BlockingIOError:
        if time.time() >= deadline:
            sys.exit(75)
        time.sleep(poll)
PY
}

acquire_act_mutex() {
    # Nested invocation of an already-holding run (env inherited by children).
    if [[ -n "${ACT_MUTEX_HELD:-}" ]] && kill -0 "$ACT_MUTEX_HELD" 2>/dev/null; then
        return 0
    fi

    # Re-derive the lock path HERE, not only at source time: a caller that sets
    # ACT_MUTEX_DIR after sourcing the library (the entry script does, and so does
    # every test) would otherwise lock a stale path and silently share a lock with
    # everyone else.
    ACT_MUTEX_LOCKFILE="${ACT_MUTEX_DIR%/}.lock"

    # Arm cleanup before the lock exists. release_act_mutex is a no-op until
    # _ACT_MUTEX_OWNED is set, so arming early is safe on every path.
    # INT/TERM/HUP exit explicitly so the EXIT trap runs.
    trap 'cleanup_secrets; release_act_mutex' EXIT
    trap 'exit 130' INT TERM HUP

    # A caller-supplied ACT_MUTEX_DIR splits sessions into separate lock namespaces,
    # which also splits the port reservation this mutex is what protects.
    if [[ -n "${ACT_MUTEX_DIR_OVERRIDDEN:-}" ]]; then
        warn "ACT_MUTEX_DIR is overridden — runs using a different lock namespace are NOT serialized,"
        warn "so artifact-server port isolation between them is no longer guaranteed."
    fi

    if ! command -v python3 &>/dev/null; then
        err "python3 not found, and it is what takes the CI lock on this platform."
        err "Install python3; without it concurrent act runs would share one Docker VM and OOM-kill each other."
        return 1
    fi

    : >> "$ACT_MUTEX_LOCKFILE" 2>/dev/null || {
        err "Cannot create the CI lock file: $ACT_MUTEX_LOCKFILE"
        return 1
    }

    # shellcheck disable=SC2093 # not exec-replacing the shell; this only opens fd 9
    eval "exec ${ACT_MUTEX_FD}>>\"\$ACT_MUTEX_LOCKFILE\"" || {
        err "Cannot open fd $ACT_MUTEX_FD on $ACT_MUTEX_LOCKFILE"
        return 1
    }

    local wait_max="${ACT_MUTEX_WAIT_SECS:-7200}" poll="${ACT_MUTEX_POLL_SECS:-15}"
    local flock_err flock_rc=0
    flock_err=$(mktemp "${TMPDIR:-/tmp}/act-flock-err.XXXXXX")
    _act_flock_acquire "$wait_max" "$poll" 2>"$flock_err" || flock_rc=$?

    if [[ $flock_rc -eq 0 ]]; then
        rm -f "$flock_err"
        _ACT_MUTEX_OWNED=1
        export ACT_MUTEX_HELD="$$"
        return 0
    fi

    # 75 is the only code that means "someone else holds it". Every other exit is a
    # broken helper (no fcntl, a syntax error, a killed interpreter), and reporting
    # that as a timeout sends the reader hunting for a phantom concurrent run.
    if [[ $flock_rc -eq 75 ]]; then
        # Name the holder when that is cheap; never make this path expensive.
        local holder=""
        if command -v lsof &>/dev/null; then
            holder=$(lsof -t "$ACT_MUTEX_LOCKFILE" 2>/dev/null | tr '\n' ' ')
        fi
        if [[ -n "$holder" ]]; then
            err "Timed out after ${wait_max}s waiting for the act CI lock (held by pid(s): ${holder% })"
        else
            err "Timed out after ${wait_max}s waiting for the act CI lock ($ACT_MUTEX_LOCKFILE)"
        fi
    else
        err "Mutex acquisition failed (python exit ${flock_rc}) — the CI lock was NOT taken."
        local detail
        detail=$(tr '\n' ' ' < "$flock_err" 2>/dev/null)
        [[ -n "$detail" ]] && err "python stderr: ${detail}"
    fi

    rm -f "$flock_err"
    eval "exec ${ACT_MUTEX_FD}>&-" 2>/dev/null || true
    return 1
}

# Closing the descriptor drops the lock. There is nothing to delete: the lock file
# is a rendezvous point, not the lock, and leaving it in place is correct.
release_act_mutex() {
    if [[ "${_ACT_MUTEX_OWNED:-}" == "1" ]]; then
        eval "exec ${ACT_MUTEX_FD}>&-" 2>/dev/null || true
        _ACT_MUTEX_OWNED=""
        unset ACT_MUTEX_HELD
    fi
}
