#!/usr/bin/env bash
# post-create-check.sh — After gh pr create, run make pre-merge in background
# and post results as a PR comment. Non-blocking.
# Claude Code PostToolUse hook on Bash tool.
#
# Protocol: PostToolUse hooks are informational — no JSON output required.
# This hook exits immediately; the background process posts a PR comment when done.

set -u

# Read tool input from stdin (Claude Code passes JSON via stdin, NOT env vars)
INPUT=$(cat)

# Fast path: skip jq for the vast majority of Bash calls that are not pr-create.
if ! printf '%s\n' "$INPUT" | grep -qE 'gh\s+pr\s+create(\s|"|$)'; then
    exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

# Only trigger after "gh pr create" — word boundary prevents matching hypothetical subcommands
if ! echo "$COMMAND" | grep -qE 'gh\s+pr\s+create(\s|$)'; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/Makefile" ]]; then
    exit 0
fi

# Guard: detached HEAD → can't determine branch → bail out
BRANCH=$(cd "$REPO_ROOT" && git branch --show-current)
if [[ -z "$BRANCH" ]]; then
    exit 0
fi

# Run pre-merge in background, post results as PR comment when done.
# Fully detach: redirect all FDs so the hook runner doesn't wait on child streams.
# Move gh pr list inside the background process to avoid 10s timeout on network calls.
(
    cd "$REPO_ROOT" || exit 0

    # Brief pause for GitHub API eventual consistency after PR creation
    sleep 3

    # Find the just-created PR number from current branch
    PR_NUM=$(gh pr list --head "$BRANCH" --json number --jq '.[0].number' 2>/dev/null)
    # Numeric, not merely non-empty: $PR_NUM is interpolated into a filesystem path
    # below, so constrain it at the source rather than trusting gh's output shape.
    if [[ ! "$PR_NUM" =~ ^[0-9]+$ ]]; then
        exit 0
    fi


    # Stamp the start so we can tell OUR per-job act logs from a peer's. The glob
    # /tmp/act-output-*.log is shared across sessions; the filename carries the act
    # script's PID, not ours, so mtime is the only handle we have.
    #
    # A MARKER FILE, not `find -newermt @<epoch>`. macOS ships BSD find, which cannot
    # parse the @epoch form at all — it exits with "Can't parse date/time: @1786562162"
    # and prints nothing, so the copy loop silently produced an empty list and every
    # comment would have said "(none)". Verified on /usr/bin/find; `-newer <file>` is
    # the portable predicate and is verified working.
    RUN_START=$(date +%s)
    RUN_MARKER=$(mktemp -t premerge-marker) || RUN_MARKER=""

    OUTPUT=$(make pre-merge 2>&1)
    EXIT_CODE=$?

    if [[ $EXIT_CODE -eq 0 ]]; then
        BODY="## Pre-merge Checks: PASSED

All local CI checks passed."
    else

        # Retain the evidence durably. TWO distinct things, and the wrapper alone is
        # NOT enough: run_act_job redirects a job's real output to
        # /tmp/act-output-<wf>-<job>-<pid>.log and echoes only a summary plus the last
        # 30 lines. So $OUTPUT is a digest, and the only
        # complete copy is the same reapable /tmp file this change exists to replace.
        # Copy both.
        LOG_DIR="$REPO_ROOT/.claude/ci-logs"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        # 077: these logs can carry gitleaks findings, act env dumps, database URLs and
        # cloud credentials, and they now live in the worktree rather than
        # reboot-cleared /tmp. act --bind mounts .worktrees/* into
        # containers, so a world-readable copy here is mounted into every later run.
        # Subshell so the umask does not leak to the rest of the hook.
        (
            umask 077
            LOG_PATH="${LOG_DIR}/pr-${PR_NUM}-${RUN_START}.log"
            printf '%s\n' "$OUTPUT" > "$LOG_PATH" 2>/dev/null
        )
        LOG_PATH="${LOG_DIR}/pr-${PR_NUM}-${RUN_START}.log"
        [[ -f "$LOG_PATH" ]] || LOG_PATH="(could not write)"

        # Per-job logs survive only for FAILED jobs (a passing job rm -f's its own,
        # a passing job removes its own log), so whatever is left newer than the marker is the failing
        # set from this window.
        #
        # RESIDUAL, accepted and stated rather than papered over: the marker excludes a
        # peer's PRE-EXISTING logs, but NOT a peer session running act concurrently —
        # its job log is also newer than our marker and matches the same glob. The
        # filename carries the act script's PID, which this hook has no way to
        # correlate to its own child. Observed in testing: a peer's live run was copied.
        # Harm is bounded (an extra log listed in our comment, no data loss, and act's
        # cross-session mutex makes a truly concurrent run uncommon), so this is not
        # worth a PID-tracking mechanism. An earlier comment here claimed the filter
        # DID exclude peers; that was wrong. (Architecture review seat.)
        JOB_LOGS=""
        if [[ -n "$RUN_MARKER" && -e "$RUN_MARKER" ]]; then
            # RESOLVE /tmp, do not pass `find -L`. Two traps compose here:
            #   * bare `find /tmp` matches NOTHING on macOS — /tmp is a symlink to
            #     private/tmp and BSD find will not descend it.
            #   * `find -L` fixes that but makes `-type f` useless as a symlink guard:
            #     under -L a symlink to a regular file IS -type f, so a planted
            #     /tmp/act-output-x.log -> ~/.ssh/id_rsa passes the filter and `cp`
            #     dereferences it into the worktree. Verified: cp printed the target's
            #     contents. (Security review seat, MAJOR.)
            # Resolving the path once and dropping -L makes -type f a real guard.
            TMPD=$(cd -P /tmp 2>/dev/null && pwd) || TMPD=/private/tmp
            # -print0/read -d '' so a filename with spaces or newlines cannot split
            # into two bogus paths. -user restricts to files this uid owns.
            while IFS= read -r -d '' jl; do
                [[ -f "$jl" && ! -L "$jl" ]] || continue
                dest="${LOG_DIR}/pr-${PR_NUM}-${RUN_START}-$(basename "$jl")"
                ( umask 077; cp "$jl" "$dest" 2>/dev/null ) && JOB_LOGS="${JOB_LOGS}
  ${dest}"
            done < <(find "$TMPD" -maxdepth 1 -type f -user "$(id -u)" \
                          -name 'act-output-*.log' -newer "$RUN_MARKER" -print0 2>/dev/null)
        fi
        [[ -z "$JOB_LOGS" ]] && JOB_LOGS="
  (none — failure was outside an act job, or the job logs were already removed)"

        # Retention: one full CI log per failed PR accumulates forever otherwise.
        # Keep the newest 40 files; ls -t then tail is enough at this scale.
        ( cd "$LOG_DIR" 2>/dev/null && ls -t 2>/dev/null | tail -n +41 | while IFS= read -r old; do rm -f -- "$old"; done ) || true

        # NEVER post the tail. run_pre_merge keeps a sticky failed=1 and runs the
        # security scans LAST, so the tail of a FAILED run is always a wall of green
        # and names nothing. A reader then has no way back to the real target, and
        # a merge gate blocks on this comment — costing a full ~20min re-run to
        # re-derive what the run already knew.
        #
        # Delegate the parse to scripts/classify-act-log.sh rather than re-implementing
        # it here. Earlier drafts of this hook hand-rolled an ANSI strip plus an
        # UNANCHORED `grep ' — FAILED'` plus a -A/-B context window, and every part of
        # that was wrong in a way the existing tool already has right:
        #   * it anchors on all THREE emitter shapes (duration, bare, free-text-reason),
        #     so a job's tail -30 of test stdout cannot forge a row;
        #   * it splits the log into per-target BLOCKS, so there is no context-window
        #     direction to get backwards — a real bug in two prior commits here, and
        #     one that survived a hand-written fixture because the fixture shared the
        #     bug's assumption. err() writes to stderr while the tail -30 goes to
        #     stdout, so byte order in a 2>&1 capture is not even guaranteed;
        #   * it strips ANSI with the portable $'...' form;
        #   * it triages ENVIRONMENTAL vs REAL, which is the single most useful thing
        #     for the merge-gate consumer;
        #   * it lists EVERY target with its result, so "which targets actually RAN"
        #     is answerable — a passing-looking run that skipped targets is a known
        #     trap here;
        #   * and it is covered by its own tests, where this hook's parser was
        #     covered by nothing.
        # (Architecture review seat, MAJOR. DRY, and prefer the architecturally
        # sound option.)
        SUMMARY=""
        CLASSIFY_RC=0
        if [[ -f "$LOG_PATH" && -x "$REPO_ROOT/scripts/classify-act-log.sh" ]]; then
            SUMMARY=$("$REPO_ROOT/scripts/classify-act-log.sh" "$LOG_PATH" 2>&1)
            CLASSIFY_RC=$?
            SUMMARY=$(printf '%s\n' "$SUMMARY" | sed 's/```/` ` `/g')
        else
            CLASSIFY_RC=99
        fi
        # Fallback chain. classify refuses verbose-format logs (exit 3) and reports
        # UNKNOWN when it parses zero target lines (exit 4) — and several real failure
        # paths emit no target line at all: PR-template missing aborts the run before
        # any target, as do a missing seam-guard file and an uninstalled
        # pip-audit/bandit/gitleaks/shellcheck/bats or an act mutex timeout. Those are
        # the CHEAPEST and most likely early failures, so they must not produce an
        # empty comment. Fall back to the tail, which is uninformative but never blank.
        # (Architecture review seat, MAJOR.)
        #
        # Test EMPTINESS *and* the exit code. classify's UNKNOWN (rc 4) and refusal
        # (rc 3) both print a short NON-empty line — "(no [act] target result lines
        # found)" is 115 chars — so an emptiness-only test silently accepts them and
        # posts a comment that names nothing. Caught by running the real thing against
        # a real unparseable log rather than by reading the code: rc 4, non-empty,
        # fallback never fired. That is precisely the PR-template-missing /
        # uninstalled-scanner class, i.e. the cheapest and most likely failures.
        if [[ -z "$SUMMARY" || "$CLASSIFY_RC" -eq 3 || "$CLASSIFY_RC" -eq 4 || "$CLASSIFY_RC" -eq 99 ]]; then
            SUMMARY="${SUMMARY:-(classify-act-log.sh unavailable)}

classify-act-log.sh could not identify a failing target (exit ${CLASSIFY_RC}), so the
last 60 lines follow. They are NOT reliable evidence of what failed — security scans
run last and the tail of a failed run is always green. Read \`${LOG_PATH}\`.

$(printf '%s\n' "$OUTPUT" | tail -60 | sed 's/```/` ` `/g')"
        fi

        BODY="## Pre-merge Checks: FAILED

\`\`\`
$SUMMARY
\`\`\`

Wrapper output: \`${LOG_PATH}\`
Failing act job logs (complete, not the 30-line digest):${JOB_LOGS}

Triage above is from \`scripts/classify-act-log.sh\`. Do not read the tail of the log to
decide what failed: \`run_pre_merge\` keeps a sticky \`failed=1\` and runs security scans
last, so a failed run's tail is always green."
    fi

    [[ -n "$RUN_MARKER" ]] && rm -f "$RUN_MARKER"

    # Capture the rc. a merge gate blocks on the PRESENCE of a
    # "## Pre-merge Checks: FAILED" comment, so a silently-failed post (auth, rate
    # limit, oversized body) means the gate sees no failure and lets a red run merge
    # clean — fail-open in the exact gate chain this change exists to harden. On
    # failure, retry with a minimal body that cannot be too large, and record the
    # outcome in the retained log so it is not lost.
    # (Both review seats, MAJOR.)
    # --body-file, not --body: the body travels through execve as an argv entry
    # otherwise, and a long one can exceed ARG_MAX and fail the post outright. A file
    # has no such limit. (Review seat, MAJOR.)
    BODY_FILE=$(mktemp -t premerge-body) || BODY_FILE=""
    if [[ -n "$BODY_FILE" ]]; then
        printf '%s\n' "$BODY" > "$BODY_FILE"
        POST_ARGS=(--body-file "$BODY_FILE")
    else
        POST_ARGS=(--body "$BODY")
    fi

    if ! gh pr comment "$PR_NUM" "${POST_ARGS[@]}" 2>>"${LOG_PATH:-/dev/null}"; then
        # Deliberately reuses the SAME "## Pre-merge Checks: <status>" prefix the full
        # body uses, because a merge gate keys on that exact prefix — a stub with a
        # different heading would not block.
        STATUS_LINE=$(printf '%s\n' "$BODY" | head -1)
        MINIMAL="${STATUS_LINE}

The full comment could not be posted (\`gh pr comment\` failed — see \`${LOG_PATH}\`).
This stub exists so the merge gate still blocks. Read the retained log."
        gh pr comment "$PR_NUM" --body "$MINIMAL" 2>>"${LOG_PATH:-/dev/null}" || \
            printf 'FATAL: could not post any PR comment for #%s\n' "$PR_NUM" >> "${LOG_PATH:-/dev/null}"
    fi
    [[ -n "$BODY_FILE" ]] && rm -f "$BODY_FILE"
) </dev/null >/dev/null 2>&1 &

# Return immediately — non-blocking
exit 0
