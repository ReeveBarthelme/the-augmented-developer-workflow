#!/usr/bin/env bash
# act-local-ci.sh — run this repo's GitHub Actions jobs locally via nektos/act.
#
# Usage:
#   ./scripts/act-local-ci.sh <target> [options]
#
# Targets:
#   jobs            Run the workflow jobs named in $ACT_JOBS (Docker, via act)
#   security        pip-audit + bandit + npm audit + gitleaks (native)
#   shell           shellcheck + bats (native)
#   workflow-lint   actionlint over .github/workflows (native)
#   hooks           Verify git core.hooksPath points at .githooks
#   pre-merge       hooks + jobs + shell + workflow-lint + security
#   list            Show these targets
#
# Options:
#   --verbose, -v   Stream act output instead of summarizing
#   --force-amd64   Force x86_64 via emulation (if arm64 fails)
#   --reuse         Reuse containers between runs (skips install steps)
#   --serial        Run job groups serially (default: parallel)
#   --help, -h      Show this help
#
# ACT_JOBS is a space-separated list of `workflow.yml:job[:Label]` entries,
# normally exported by the Makefile. Example:
#   ACT_JOBS="ci.yml:lint ci.yml:test:Unit-tests"
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
export REPO_ROOT

# shellcheck source=lib-act-ci.sh
source "$(dirname "$0")/lib-act-ci.sh"

# Split ACT_JOBS into an array. Word splitting is the intended parse here.
read -r -a ACT_JOB_SPECS <<< "${ACT_JOBS:-}"

run_target() {
    local target="$1"
    local failed=0

    case "$target" in
        jobs)
            check_deps || return 1
            build_act_flags
            # Group the specs by workflow FILE, then run one act process per group
            # with the group's jobs serial inside it. Running every job concurrently
            # instead would exhaust ACT_PORT_WINDOW past 4 entries (two acts then bind
            # one port) and put N containers on one Docker VM, which is the
            # out-of-memory case the cross-session mutex exists to prevent.
            local groups=() seen=" " spec wf g
            for spec in ${ACT_JOB_SPECS[@]+"${ACT_JOB_SPECS[@]}"}; do
                wf="${spec%%:*}"
                case "$seen" in
                    *" $wf "*)
                        for i in "${!groups[@]}"; do
                            [[ "${groups[$i]%%:*}" == "$wf" ]] && groups[i]="${groups[$i]} $spec" && break
                        done
                        ;;
                    *) seen="$seen$wf "; groups+=("$spec") ;;
                esac
            done
            if [[ "$PARALLEL" == "true" && "$VERBOSE" != "true" && ${#groups[@]} -gt 1 ]]; then
                log "${BOLD}Running ${#groups[@]} workflow groups in parallel${NC}"
                run_parallel run_act_jobs "${groups[@]}" || failed=1
            else
                if [[ ${#groups[@]} -eq 0 ]]; then
                    # No specs at all: let run_act_jobs print the configuration error.
                    run_act_jobs || failed=1
                else
                    for g in "${groups[@]}"; do
                        # shellcheck disable=SC2086 # g is an intentionally word-split spec list
                        run_act_jobs $g || failed=1
                    done
                fi
            fi
            ;;
        security)      run_security || failed=1 ;;
        shell)         run_shell_checks || failed=1 ;;
        workflow-lint) run_workflow_lint || failed=1 ;;
        hooks)         check_git_hooks_path || failed=1 ;;
        pre-merge)
            # Hooks first: a dark .githooks means the commit-time gates never ran,
            # and that is cheaper to learn now than after a 10-minute act run.
            check_git_hooks_path || failed=1
            run_target jobs || failed=1
            echo ""
            run_shell_checks || failed=1
            echo ""
            run_workflow_lint || failed=1
            echo ""
            # project-specific gates go here
            run_security || failed=1
            ;;
        list)
            sed -n '6,14p' "$0" | sed 's/^# \{0,1\}//'
            return 0
            ;;
        *)
            err "Unknown target: $target"
            echo "Run with 'list' to see available targets."
            return 1
            ;;
    esac

    return $failed
}

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

# shellcheck disable=SC2034 # FORCE_AMD64/REUSE are read by build_act_flags in the lib
main() {
    local target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v)  VERBOSE=true; shift ;;
            --force-amd64) FORCE_AMD64=true; shift ;;
            --reuse)       REUSE=true; shift ;;
            --serial)      PARALLEL=false; shift ;;
            --parallel)    PARALLEL=true; shift ;;
            --help|-h)     usage; exit 0 ;;
            -*)            err "Unknown option: $1"; usage; exit 1 ;;
            *)             target="$1"; shift ;;
        esac
    done

    if [[ -z "$target" ]]; then
        err "No target specified."
        usage
        exit 1
    fi

    # Serialize Docker-based act runs across sessions: concurrent runs share one
    # Docker VM and OOM-kill each other. Native-only targets skip the mutex.
    case "$target" in
        security|shell|workflow-lint|hooks|list) ;;
        *) acquire_act_mutex || exit 1 ;;
    esac

    local start_time
    start_time=$(date +%s)

    local exit_code=0
    run_target "$target" || exit_code=$?

    local total_elapsed=$(( $(date +%s) - start_time ))
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        ok "${BOLD}All checks in '$target' passed${NC} (${total_elapsed}s total)"
    else
        err "${BOLD}Some checks in '$target' failed${NC} (${total_elapsed}s total)"
    fi

    return $exit_code
}

main "$@"
