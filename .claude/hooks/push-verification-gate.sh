#!/usr/bin/env bash
# push-verification-gate.sh — Forces a review checkpoint before `git push`
# GATES: git push
#   Read by .claude/scripts/check-gate-liveness.sh to test whether this
#   hook's 'ask' can actually surface. Keep it the literal command prefix.
# directly to `main` on non-trivial diffs. Claude Code PreToolUse hook on Bash.
#
# Why: pr-verification-gate.sh forces this same checkpoint before `gh pr
# create`, and merge-pr.sh's review-artifact gate forces it before a PR
# merges — but neither ever fires on a direct-to-main landing (commit +
# `git push origin main`, no PR at all), which this project's own workflow
# explicitly allows for trivial fixes / single-line hotfixes / self-contained
# tooling changes. 6th documented instance of "offered to push/merge without
# having run review, surfaced only when the user asked" (Jul 21 2026,
# delegation-nudge.sh model-tier fix) happened specifically because this
# path has no gate at all — see infra-deploy-ci.md's "Always run
# /orchestrate-review-deploy before merging" entry for the prior 5.
#
# Protocol: a BLOCKING decision must be NESTED under hookSpecificOutput:
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                          "permissionDecision":"ask",   # allow|deny|ask ONLY
#                          #  (NOT "defer" — print-mode only, ignored interactively)
#                          "permissionDecisionReason":"..."}}
# A top-level "permissionDecision" is NOT a recognized key for this event and is
# silently ignored — this hook was dark from the day it was written until
# 2026-08-10. (The deprecated top-level key is "decision" with "approve"/"block";
# do not use that either.) See .claude/hooks/README.md for the full protocol.
#
# The "allow" fast paths below deliberately KEEP the ignored top-level shape: an
# ignored allow falls through to the normal permission flow, whereas a nested
# allow explicitly SKIPS the confirmation prompt. Never nest them.
#
# (Both bullets that used to live here — "allow -> proceeds silently", "ask ->
# user sees a confirmation prompt" — described the TOP-LEVEL shape and were
# simply false; that wrong header is why this hook shipped dark.)
#
# Fail OPEN on any ambiguity (missing jq, no git repo, no diff detected,
# can't determine target branch) — this hook must never block, only surface
# the checkpoint when it's confident the push targets main directly.
set -uo pipefail

INPUT=$(cat)

# Fast path: only intercept `git push` — exit immediately for everything
# else. Matched against the raw JSON payload (before jq extraction), so a
# bare `git push` at the end of the command string is followed by a JSON
# quote character, not whitespace/EOL — `"` must be in the alternation
# (same fix pr-verification-gate.sh's own fast path already applies).
# `git` is reachable under wrappers and global options that a literal
# `git\s+push` match misses: `git -C dir push`, `/usr/bin/git push`,
# `env X=1 git push`, or a wrapper such as `time git push`. Allow an optional path prefix and a
# run of global option tokens before the subcommand.
# TWO patterns — see pr-verification-gate.sh for the full rationale. Short
# version: the PREFILTER sees the RAW JSON payload, where a newline is the two
# characters \ and n, so a leading boundary alternation misses on any
# multi-line command and the gate goes dark. Prefilter carries no anchor.
GIT_PUSH_PREFILTER_RE='([^;&|"[:space:]]*/)?git\s+([-][^[:space:]]*(\s+[^-][^[:space:]]*)?\s+)*push(\s|"|$)'
# The PRECISE pattern runs against the jq-decoded command (real newlines).
GIT_PUSH_RE='(^|[;&|"'"'"']|\s)'"$GIT_PUSH_PREFILTER_RE"
if ! printf '%s\n' "$INPUT" | grep -qE "$GIT_PUSH_PREFILTER_RE"; then
    echo '{"permissionDecision":"allow"}'
    exit 0
fi

if command -v jq &>/dev/null; then
    COMMAND=$(printf '%s\n' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
else
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Repo-scoped log (CWE-377: avoids symlink attacks on predictable /tmp paths).
# Logging the emitted VERDICT — not just the command — is the README convention:
# that post-mortem needed a full transcript dig purely because the log
# recorded no decision.
_GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || true)"
LOG="${_GIT_DIR:+${_GIT_DIR}/push-verification-gate.log}"
LOG="${LOG:-/dev/null}"
{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "COMMAND: ${COMMAND:-<empty>}"
  echo "CWD: $(pwd)"
} >> "$LOG" 2>/dev/null || true

# Re-check on the jq-extracted command. As in pr-verification-gate.sh, this does
# not parse shell — a command that merely mentions `git push` still MATCHES.
# That false positive is deliberate: an extra prompt is cheap, a dark gate is
# not. (Whether a match becomes a visible prompt also depends on the session's
# permission rules, which this hook does not control.)
if ! printf '%s\n' "$COMMAND" | grep -qE "$GIT_PUSH_RE"; then
    echo 'VERDICT: allow (no git push in extracted command)' >> "$LOG" 2>/dev/null || true
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    echo '{"permissionDecision": "allow"}'
    exit 0
fi
cd "$REPO_ROOT" || { echo '{"permissionDecision": "allow"}'; exit 0; }

# `git rev-parse --abbrev-ref origin/HEAD` can FAIL (nonzero exit) while
# still echoing the literal "origin/HEAD" to stdout when the remote's HEAD
# symref was never set (e.g. `git init --bare` + manual `remote add`,
# rather than `git clone`/`remote set-head`) — checking only for empty
# output misses this and silently resolves DEFAULT_BRANCH to "HEAD".
# Check the command's own exit status instead.
DEFAULT_BRANCH=""
if REF=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null) && [[ -n "$REF" ]]; then
    DEFAULT_BRANCH="${REF#origin/}"
fi
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

# Does this push target the default branch? Either the command names it
# explicitly (`git push origin main`), or it's a bare `git push`/`git push
# origin` while HEAD is already ON the default branch (upstream push). This
# errs toward "ask" on ambiguous cases (e.g. pushing an explicit refspec for
# some other branch while sitting on main) — the cost of an unnecessary
# confirmation is low, the cost of a silently-skipped one is the 6-instance
# pattern this hook exists to close.
TARGETS_DEFAULT=0
if printf '%s\n' "$COMMAND" | grep -qE "(^|[[:space:]/:])${DEFAULT_BRANCH}([[:space:]:]|$)"; then
    TARGETS_DEFAULT=1
elif [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
    TARGETS_DEFAULT=1
fi

[[ "$TARGETS_DEFAULT" -eq 1 ]] || { echo 'VERDICT: allow (push does not target default branch)' >> "$LOG" 2>/dev/null || true; echo '{"permissionDecision": "allow"}'; exit 0; }

CHANGED=$(git diff --name-only "origin/${DEFAULT_BRANCH}...HEAD" 2>/dev/null || true)
if [[ -z "$CHANGED" ]]; then
    # HEAD has no diff versus the resolved base (nothing new to push, the
    # remote branch is gone, or a detached HEAD sitting ON the base — a
    # detached HEAD WITH commits still produces a diff). Fail open.
    echo '{"permissionDecision": "allow"}'
    exit 0
fi

# Trivial-diff carve-out: docs, markdown, tests, fixtures — same as
# pr-verification-gate.sh's carve-out for the PR path.
NON_TRIVIAL=$(printf '%s\n' "$CHANGED" | grep -vE '\.md$|^docs/|(^|/)tests?/|_test\.py$|^test_|\.example$|\.template$' || true)
[[ -n "$NON_TRIVIAL" ]] || { echo 'VERDICT: allow (trivial diff — docs/tests/fixtures only)' >> "$LOG" 2>/dev/null || true; echo '{"permissionDecision": "allow"}'; exit 0; }

REASON="This pushes non-trivial changes directly to ${DEFAULT_BRANCH} (no PR). Before pushing, confirm /code-review or /orchestrate-review-deploy actually ran on this diff this session. If skipped for a trivial/tooling-only change, say so explicitly rather than pushing silently."

# A blocking decision MUST be nested under hookSpecificOutput — a top-level
# "permissionDecision" is silently ignored (this hook was dark until 2026-08-10;
# see pr-verification-gate.sh header for the transcript evidence).
# The "allow" fast paths above deliberately KEEP the top-level shape: ignored ==
# fall through to the normal permission flow, whereas a nested allow would be an
# explicit bypass of it. Only this blocking path is nested.
printf 'VERDICT: ask (non-trivial: %s)\n' "$(printf '%s' "$NON_TRIVIAL" | tr '\n' ' ')" >> "$LOG" 2>/dev/null || true
jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r},systemMessage:$r}'
