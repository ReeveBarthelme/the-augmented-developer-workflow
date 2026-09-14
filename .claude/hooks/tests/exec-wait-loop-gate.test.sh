#!/usr/bin/env bash
# shellcheck disable=SC2016
# Runs the gate against literal command shapes. Exit 1 on any mismatch.
# Sets EXEC_WAIT_LOOP_WRAPPERS itself, so this test passes regardless of how
# (or whether) the adopting project configures the gate.
set -u
export EXEC_WAIT_LOOP_WRAPPERS='wrap'
HOOK="$(cd "$(dirname "$0")/.." && pwd)/exec-wait-loop-gate.sh"
fail=0
# Protocol-shaped assertions (README "PreToolUse decision protocol"): a deny is
# only honored NESTED with hookEventName; an allow must stay TOP-LEVEL (a
# nested allow would skip the permission prompt). A top-level deny is a dark
# gate and must FAIL this test.
check() { # $1 expected deny|allow, $2 command
    out=$(jq -nc --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK")
    got=$(printf '%s' "$out" | jq -r 'if (.hookSpecificOutput.permissionDecision=="deny" and .hookSpecificOutput.hookEventName=="PreToolUse" and (.permissionDecision==null)) then "deny" elif (.permissionDecision=="allow" and (.hookSpecificOutput==null)) then "allow" else "MALFORMED:"+tostring end')
    if [ "$got" = "$1" ]; then echo "ok    $1  :: ${2:0:70}"; else echo "FAIL  want $1 got $got :: $2"; fail=1; fi
}
# the incident shape this gate exists for, verbatim
check deny  'cd frontend && until [ -s /tmp/x.txt ] && ! ps aux | wrap grep -q "[t]sc -b"; do sleep 5; done; echo DONE'
check deny  'until ! ps aux | wrap grep -q "[t]sc -b"; do sleep 3; done; echo TSC_DONE'
check deny  'while wrap grep -q pending /tmp/s.txt; do sleep 10; done'
check deny  $'until [ -s f ] && ! ps aux | wrap grep -q x\ndo sleep 5; done'
# must pass: no wrapper in the condition, bounded for-poll, wrapper outside loops, plain words
check allow 'until [ -s /tmp/x.txt ]; do sleep 5; done'
check allow 'for i in $(seq 1 40); do p=$(wrap gh pr view 1 --json x -q .x); [ "$p" = "0" ] && break; sleep 60; done'
check allow 'wrap gh pr view 1295 --json mergeable'
check allow 'echo "while we wait, wrap up"'
check allow 'while read -r line; do echo "$line"; done < file.txt; wrap status'
# wrapper, tab/newline after keyword, statement boundaries
check deny  'bash -c "while wrap grep -q x f; do sleep 1; done"'
check deny  $'while\twrap grep -q x f; do sleep 1; done'
check deny  $'while\nwrap grep -q x f; do sleep 1; done'
check deny  $'while wrap grep -q x f\ndo sleep 1\ndone'
check allow $'while read -r line\ndo\n  echo "$line"\ndone < f\nwrap status\nfor i in 1 2\ndo\n  echo "$i"\ndone'
check allow $'until [ -s f ]; do sleep 1; done\nwrap gh pr view 1 --json x\nwhile true; do break; done'
# Unconfigured gate is a no-op: the incident shape must be ALLOWED.
out=$(EXEC_WAIT_LOOP_WRAPPERS='' jq -nc '{tool_name:"Bash",tool_input:{command:"while wrap grep -q x f; do sleep 1; done"}}' | EXEC_WAIT_LOOP_WRAPPERS='' bash "$HOOK")
if [ "$(printf '%s' "$out" | jq -r '.permissionDecision')" = "allow" ]; then
    echo "ok    allow  :: unconfigured gate is a no-op"
else
    echo "FAIL  want allow got $out :: unconfigured gate is a no-op"; fail=1
fi
exit $fail
