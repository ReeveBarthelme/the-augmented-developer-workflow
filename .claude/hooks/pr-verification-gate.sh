#!/usr/bin/env bash
# pr-verification-gate.sh — Forces a verification checkpoint before `gh pr create`
# GATES: gh pr create
#   Read by .claude/scripts/check-gate-liveness.sh to test whether this
#   hook's 'ask' can actually surface. Keep it the literal command prefix.
# on non-trivial diffs. Claude Code PreToolUse hook on Bash tool.
#
# Why: 5 documented instances of a PR opening
# before the CLAUDE.md "Local Dev Verification (MANDATORY)" layer actually ran,
# surfaced only when the user asked "did you /qa?" after the fact. Documentation
# alone (a memory entry, then a bold CLAUDE.md section) failed to prevent
# recurrence across all 4 prior instances. This hook can't detect whether
# verification happened — PreToolUse only sees the current tool call, not
# session history — so instead of trying to auto-detect evidence, it
# guarantees the checkpoint surfaces at the moment `gh pr create` fires,
# rather than relying on the agent to remember to raise it.
#
# Protocol: a BLOCKING PreToolUse decision must be NESTED under
# hookSpecificOutput — a top-level "permissionDecision" key is silently IGNORED
# by the harness. This file shipped with the top-level shape and was therefore
# DARK from the day it was written: it once fired on a real PR, emitted
# "ask", and the PR was created 3.9s later with no prompt (confirmed in the session
# transcript). Only the top-level
# "systemMessage" reached the model, and only AFTER the tool had already run.
#
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                          "permissionDecision":"ask|deny|allow",
#                          #  those three ONLY — "defer" is print-mode only
#                          #  and is IGNORED in interactive sessions
#                          "permissionDecisionReason":"..."}}
#
# DELIBERATE: the "allow" fast paths below keep the top-level (ignored) shape.
# An ignored allow falls through to the NORMAL permission flow; a correctly
# nested allow is an explicit bypass of it. Do not "fix" them — nesting them
# would auto-approve these commands outright. Only blocking decisions are nested.

set -uo pipefail
# Read tool input from stdin (Claude Code passes JSON via stdin, NOT env vars)
INPUT=$(cat)

# Fast path: only intercept "gh pr create" — exit immediately for everything else.
# `gh` accepts global options BETWEEN the binary and the subcommand
# (`gh --repo o/r pr create`, `gh -R o/r pr create`), so a literal `gh\s+pr`
# match misses valid invocations. Allow an optional run of option/value tokens
# in that gap. Kept deliberately loose: this is the cheap prefilter, and a false
# positive here only costs the word-boundary re-check below.
# TWO patterns, because the two checks see DIFFERENT text.
#
# The PREFILTER runs against the RAW JSON payload, where a newline is the two
# characters \ and n — so in `make build\ngh pr create` the character before
# `gh` is the LETTER n. Any leading boundary alternation therefore MISSES and
# the gate goes dark. (Every JSON escape ends in a letter, so \t has the same
# problem.) The prefilter must carry NO leading anchor: it is the cheap, loose
# check, and a false positive here costs only the precise re-check below.
# The option-run group appears TWICE: `gh` accepts global options both before
# the subcommand (`gh --repo o/r pr create`) and between it and the verb
# (`gh pr -R o/r create`). Both are documented, ordinary forms; allowing only
# the first left the second dark.
GH_OPTS='([-][^[:space:]]*(\s+[^-][^[:space:]]*)?\s+)*'
# `create|new`: `gh pr create --help` lists `gh pr new` under ALIASES. It is an
# ordinary documented invocation, not evasion, so it belongs inside this gate's
# scope. Anchored by the preceding `pr\s+` + option run, so a bare word "new"
# elsewhere (`git checkout -b new-branch`) cannot match.
GH_PR_CREATE_PREFILTER_RE='([^;&|"[:space:]]*/)?gh\s+'"$GH_OPTS"'pr\s+'"$GH_OPTS"'(create|new)(\s|"|$)'
# The PRECISE pattern runs against the jq-DECODED command, which has real
# newlines, so grep's per-line `^` anchors work as intended.
GH_PR_CREATE_RE='(^|[;&|"'"'"']|\s)'"$GH_PR_CREATE_PREFILTER_RE"
if ! printf '%s\n' "$INPUT" | grep -qE "$GH_PR_CREATE_PREFILTER_RE"; then
    echo '{"permissionDecision":"allow"}'
    exit 0
fi

# Extract command via jq for accurate detection
if command -v jq &>/dev/null; then
    COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
else
    # Fail open — can't reliably extract the command without jq
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Repo-scoped log to avoid symlink attacks on predictable /tmp paths (CWE-377)
_GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || true)"
LOG="${_GIT_DIR:+${_GIT_DIR}/pr-verification-gate.log}"
LOG="${LOG:-/dev/null}"
{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "COMMAND: ${COMMAND:-<empty>}"
  echo "CWD: $(pwd)"
} >> "$LOG" 2>/dev/null || true

# Re-check on the jq-extracted command. NOTE: this does NOT parse shell, so a
# command that merely MENTIONS "gh pr create" (an echo, a quoted heredoc, a PR
# body) still MATCHES. That false positive is deliberate and safe-by-direction:
# the cost is at most one extra confirmation prompt, whereas a missed match is a
# silently dark gate — the exact failure this file exists to fix. Do not
# "tighten" this into a bypass. (Whether a match becomes a visible prompt also
# depends on the session's permission rules, which this hook does not control.)
if ! printf '%s\n' "$COMMAND" | grep -qE "$GH_PR_CREATE_RE"; then
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

cd "$REPO_ROOT" || { echo '{"permissionDecision": "allow"}'; exit 0; }

# Default branch to diff against — this repo's default is "main" (confirmed
# via git remote), fall back to origin/HEAD's symref if ever different.
# `git rev-parse --abbrev-ref origin/HEAD` can FAIL (nonzero exit) while still
# echoing the literal "origin/HEAD" when the remote's HEAD symref was never set
# (`git init --bare` + `remote add`, rather than `git clone`). Piping into sed
# discards that exit status and resolves DEFAULT_BRANCH to the literal "HEAD",
# so the diff below fails, CHANGED is empty, and the gate goes DARK on exactly
# the repos it should guard. push-verification-gate.sh already hardened this;
# this file kept the naive form. Check the command's own exit status.
DEFAULT_BRANCH=""
if REF=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null) && [[ -n "$REF" ]]; then
    DEFAULT_BRANCH="${REF#origin/}"
fi
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

CHANGED=$(git diff --name-only "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || true)

if [[ -z "$CHANGED" ]]; then
    # HEAD has no diff versus the resolved base (fork PR, already-merged base,
    # or a detached HEAD sitting ON that base — a detached HEAD WITH commits
    # still produces a diff and still asks). Fail open: nothing to gate on.
    echo 'VERDICT: allow (empty diff vs origin/'"$DEFAULT_BRANCH"')' >> "$LOG" 2>/dev/null || true
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Trivial-diff carve-out: docs, markdown, tests, fixtures. Mirrors this
# project's own VDD "Trivial fix" tier — don't gate a docs/test-only PR.
NON_TRIVIAL=$(printf '%s\n' "$CHANGED" | grep -vE '\.md$|^docs/|(^|/)tests?/|_test\.py$|^test_|\.example$|\.template$' || true)

if [[ -z "$NON_TRIVIAL" ]]; then
    echo 'VERDICT: allow (trivial diff — docs/tests/fixtures only)' >> "$LOG" 2>/dev/null || true
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

REASON='This PR touches non-trivial source files. Before opening it, state which of these actually ran THIS session, naming any that did not:
(A) Verification — CLAUDE.md "Local Dev Verification (MANDATORY)": (1) targeted tests, (2) API smoke curl against affected endpoints, (3) /qa or an equivalent live local-dev/staging check.
(B) Review — /orchestrate-review-deploy (the multi-agent review gate). An ad-hoc single-seat pass is NOT a substitute; the CLAUDE.md VDD table requires it at every task size, down to "Trivial fix".
Do not answer "done" for a layer you only intended to run. If any was skipped, say so explicitly rather than opening the PR silently.'

emit_ask() {
    jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r},systemMessage:$r}'
}

printf 'VERDICT: ask (non-trivial: %s)\n' "$(printf '%s' "$NON_TRIVIAL" | tr '\n' ' ')" >> "$LOG" 2>/dev/null || true
emit_ask "$REASON"
