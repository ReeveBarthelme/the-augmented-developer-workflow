#!/usr/bin/env bash
# exec-wait-loop-gate.sh — blocking PreToolUse(Bash) hook: deny an
# `until`/`while` loop whose CONDITION runs through a command wrapper that
# does not propagate the wrapped command's exit status.
#
# Why: a CLI proxy or shim that runs your command and reformats its output
# often returns its OWN exit status, not the wrapped command's. Put one in a
# loop condition and the condition never flips:
#
#   until [ -s out.txt ] && ! ps aux | WRAPPER grep -q "[t]sc -b"; do sleep 5; done
#
# The loop spins forever and a subagent idles "waiting for the monitor" while
# the lead waits on it. A subagent cannot answer a permission prompt, so this
# is a deny with a rewrite hint, not an ask. Main-loop calls hit the same rule;
# the rewrite is the same and costs nothing.
#
# CONFIGURE BEFORE THIS GATE DOES ANYTHING. Set EXEC_WAIT_LOOP_WRAPPERS to an
# ERE alternation of the wrapper commands your project actually uses, e.g.
#
#   export EXEC_WAIT_LOOP_WRAPPERS='myproxy|mywrapper'
#
# Unset or empty means every command is allowed and this hook is a no-op. That
# default is deliberate: a template cannot know your wrapper's name, and a gate
# that guesses one would deny nothing while looking armed. Confirm it is live
# with `bash .claude/hooks/tests/exec-wait-loop-gate.test.sh`, which sets the
# variable itself.
#
# Scope is deliberately narrow: only loops whose CONDITION contains a listed
# wrapper. Bounded `for` polls and loops without a wrapper pass.
set -uo pipefail

INPUT=$(cat)

WRAPPERS="${EXEC_WAIT_LOOP_WRAPPERS:-}"

# Unconfigured, or no loop keyword, or no wrapper token → allow. The top-level
# (ignored) allow shape is deliberate: it falls through to the normal
# permission flow, where a nested allow would bypass it. See README protocol.
if [ -z "$WRAPPERS" ] \
    || ! printf '%s' "$INPUT" | grep -qE 'until|while' \
    || ! printf '%s' "$INPUT" | grep -qE "$WRAPPERS"; then
    echo '{"permissionDecision":"allow"}'
    exit 0
fi

if ! command -v jq &>/dev/null; then
    echo '{"permissionDecision":"allow"}'
    exit 0
fi

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

# Newlines are statement boundaries in bash, so map them to `;` (NOT to a
# space: flattening lets `[^;]*` span a finished loop, an unrelated wrapper
# call and a later `do`, a false deny). Keyword boundary includes quotes so
# `bash -c "while WRAPPER ..."` is caught. Loop condition = text between the
# keyword and its `do`; match a wrapper token inside it.
PATTERN="(^|[;&|[:space:](\"'])(until|while)[[:space:];]+([^;]*[[:space:]])?(${WRAPPERS})[[:space:]][^;]*(;|[[:space:]])[[:space:]]*do([[:space:]\";]|$)"

if printf '%s' "$COMMAND" | tr '\n\t' ';  ' | grep -qE "$PATTERN"; then
    # shellcheck disable=SC2016
    REASON='EXEC-WAIT-LOOP GATE: this until/while loop runs a wrapper command inside its condition. The wrapper does not propagate the wrapped command exit status, so the loop never terminates. Rewrite without a wait loop: run the work in the foreground redirected to a file, e.g. `cmd > /tmp/out.txt 2>&1; echo RC=$?`, then read the file. If you must poll, use a bounded `for i in $(seq 1 N)` with a plain (unwrapped) test and a break.'
    jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}, systemMessage:$r}'
    exit 0
fi

echo '{"permissionDecision":"allow"}'
