#!/usr/bin/env bash
# pipe-mask-warn.sh — advisory PreToolUse(Bash) hook: a STATE-CHANGING command
# piped into tail/head/grep masks its exit code (a pipe reports the LAST
# stage's RC), so a blocked commit/push/deploy prints as success.
#
# Why: 3 incidents in ONE session (Jul 29 2026) — a C3-gate-blocked
# `deploy.sh … | tail` printed RC=0; a mypy-gate-blocked
# `git commit … | tail` printed COMMIT_RC=0; a format-gate-blocked push hid
# its hook output the same way. The CLAUDE.md Evidence rule already forbids
# concluding pass/fail from a piped state-changer; this hook makes the rule
# fire at call time instead of relying on recall under flow.
#
# Advisory ONLY: always allows; on a match it attaches additionalContext so
# the agent reads the piped output with the right suspicion. Deliberately
# NOT a block — reading piped output is sometimes fine (the failure mode is
# trusting the exit code, which a warning corrects at zero friction).
#
# Known tradeoff: the segment matcher uses [^|;]* (not [^|;&]*) so the real
# Both matchers accept `|&` as well as `|`: bash's `cmd |& tail` is shorthand
# for `cmd 2>&1 | tail`, so it masks the exit code identically, and it is a
# common shape for lint/test output. Verified it evaded before this
# (found by a reviewer on a prior PR) — including for the state-changing matcher.
#
# incident shape `git push 2>&1 | tail` matches; the cost is a rare false
# positive across `&&` boundaries (`git commit -m x && ls | tail`). Advisory,
# so a spurious warning is cheap; a missed real one is not.
set -uo pipefail

INPUT=$(cat)

# Fast path: bail unless a state-changing OR verification token appears.
# (Both classes must be listed here — a token missing from this fast path can
#  never reach its PATTERN below. That gap is what let the Aug 5 2026 ruff
#  instance through: the hook existed, fired correctly on `git push | tail` in
#  the same session, and silently ignored `ruff check … | tail -1`.)
if ! printf '%s' "$INPUT" | grep -qE 'git (commit|push|merge)|gh pr merge|deploy|migrate\.sh|release\.sh|ruff|pytest|mypy|actionlint'; then
    echo '{"permissionDecision":"allow"}'
    exit 0
fi

if ! command -v jq &>/dev/null; then
    echo '{"permissionDecision":"allow"}'
    exit 0
fi

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

# State-changing segment followed (same segment, no ; or | between) by a pipe
# into tail/head/grep.
PATTERN='(git[[:space:]]+(commit|push|merge)|gh[[:space:]]+pr[[:space:]]+merge|(\./|/[^[:space:]]*/)?deploy[[:alnum:]_-]*\.sh|(\./|/[^[:space:]]*/)?migrate\.sh|(\./|/[^[:space:]]*/)?release\.sh)[^|;]*\|&?[[:space:]]*(tail|head|grep)'

# Verification/gate commands piped the same way. Different consequence, so a
# different message: a masked lint/test failure does not print as "success",
# it prints as a plausible LAST LINE that reads like a clean verdict.
# Matches the tool name anywhere in the segment so `python3 -m ruff` and
# bare `pytest` both hit. Same [^|;]* segment convention as above.
VERIFY_PATTERN='(ruff|pytest|mypy|actionlint)[^|;]*\|&?[[:space:]]*(tail|head|grep)'

if printf '%s' "$COMMAND" | grep -qE "$PATTERN"; then
    MSG='PIPE-MASK WARNING: a state-changing command in this call is piped into tail/head/grep. The pipe reports the LAST stage exit code — a blocked commit/push/deploy will print as success (3 real incidents, Jul 29 2026). Do not conclude pass/fail from this output: verify the state directly afterward (git log -1 / ls-remote vs local HEAD / a deployed-revision check), or rerun bare / redirected to a file.'
    jq -nc --arg ctx "$MSG" '{permissionDecision:"allow", hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$ctx}}'
    exit 0
fi

if printf '%s' "$COMMAND" | grep -qE "$VERIFY_PATTERN"; then
    MSG='PIPE-MASK WARNING: a lint/test/type command is piped into tail/head/grep, so the exit code you see belongs to the PIPE, not the check. The failure mode here is subtler than for a blocked deploy: the tail of a FAILING run often reads like a pass. Real instance (Aug 5 2026): ruff check --no-fix piped into tail -1 printed "No fixes available (2 hidden fixes ...)" and was reported as CLEAN — the bare command exited 1 with two real errors. Re-run bare, or redirect to a file with 2>&1, and read the EXIT CODE plus a nonzero passed/collected count before claiming green.'
    jq -nc --arg ctx "$MSG" '{permissionDecision:"allow", hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$ctx}}'
    exit 0
fi

echo '{"permissionDecision":"allow"}'
