#!/usr/bin/env bash
# check-gate-liveness.sh — is each ask-emitting PreToolUse hook capable of
# surfacing a prompt at all?
#
# WHY THIS EXISTS (6th instance of the skipped-workflow
# pattern logged in memory/infra-deploy-ci.md):
# pr-verification-gate.sh fired on `gh pr create`, matched the non-trivial
# diff, and logged `VERDICT: ask` — with the correct nested
# hookSpecificOutput shape. No prompt appeared and the PR was created. The
# hook was working perfectly and was inert anyway, because a PreToolUse
# "ask" is only a gate when something is left to do the asking.
#
# Two independent things swallow an "ask", and this repo had both:
#   1. permissions.defaultMode = "auto" — auto-approves every Bash call,
#      including ones with no allow rule at all (proven: `git commit` is in
#      no allow list and ran unprompted for three commits that session).
#   2. an allow rule covering the gated command (`Bash(gh:*)` covers
#      `gh pr create`; `Bash(git push:*)` covers the push gate).
#
# Neither end emits a signal. The hook logs "ask" and believes it worked;
# the harness approves and never learns a gate wanted to speak. That is the
# dark-gate shape this repo has now hit six times, so this script asserts
# the property directly instead of trusting that a hook exists.
#
# SCOPE: liveness of ask-emitting hooks ONLY. Workflow liveness (triggers,
# freshness, hollow runs) is scripts/dark_gate_detector.py's job — this is
# deliberately NOT bolted onto that file's 770 lines; different subject,
# different failure shape.
#
# ACCEPTED INERT GATES: .claude/gate-liveness-accepted.txt lists gates whose
# darkness is a recorded decision, not an accident. Those are reported and do
# NOT fail the run. Without that list this check would exit 1 forever the
# moment anyone chose to keep a gate open, and a check that always fails gets
# muted -- the same disease it exists to catch.
#
# Usage: .claude/scripts/check-gate-liveness.sh [--quiet]
# Exit:  0 every ask-emitting gate can surface, or its darkness is accepted
#        1 at least one is inert and UNACCEPTED  (the finding, not an error)
#        2 could not evaluate (missing jq, no hooks dir)

set -uo pipefail

QUIET=""
[[ "${1:-}" == "--quiet" ]] && QUIET=1

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "check-gate-liveness: not in a git repo" >&2; exit 2; }
cd "$REPO_ROOT" || exit 2

command -v jq >/dev/null 2>&1 || { echo "check-gate-liveness: jq required" >&2; exit 2; }

HOOK_DIR=".claude/hooks"
[[ -d "$HOOK_DIR" ]] || { echo "check-gate-liveness: no $HOOK_DIR" >&2; exit 2; }

SETTINGS_FILES=(
  ".claude/settings.json"
  ".claude/settings.local.json"
  "$HOME/.claude/settings.json"
)

say() { [[ -n "$QUIET" ]] || printf '%s\n' "$*"; }

# --- 1. Resolve the effective permission mode ---------------------------
# Any file setting defaultMode=auto (or bypassPermissions/acceptEdits) makes
# an "ask" inert. Read them all rather than guessing precedence: if ANY says
# auto, report it — a false INERT costs one investigation, a false LIVE is
# the bug this file exists to catch.
MODE=""
MODE_SRC=""
for f in "${SETTINGS_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  m=$(jq -r '.permissions.defaultMode // empty' "$f" 2>/dev/null || true)
  if [[ -n "$m" && "$m" != "default" && "$m" != "plan" ]]; then
    MODE="$m"; MODE_SRC="$f"; break
  fi
done

# --- 2. Collect allow rules across all settings files -------------------
ALLOW_RULES=""
for f in "${SETTINGS_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  rules=$(jq -r '.permissions.allow[]? // empty' "$f" 2>/dev/null || true)
  [[ -n "$rules" ]] && ALLOW_RULES+="$rules"$'\n'
done

# Does any allow rule cover COMMAND? This repo writes allow rules in BOTH
# shapes and they must both be handled:
#   Bash(gh:*)                     colon-wildcard
#   Bash(some tool read *)       space-wildcard  (.claude/settings.json)
# Stripping only `:*` leaves `some tool read *` with a LITERAL asterisk,
# which then prefix-matches nothing, and the gate is reported LIVE when an
# allow rule does in fact cover it. That is a false LIVE -- the one direction
# this script must never fail in -- so normalize every trailing wildcard form.
# Deliberately loose in the other direction: over-reporting a covered command
# costs a line of output, under-reporting hides a dark gate.
allow_covers() {
  local cmd="$1" rule bare
  while IFS= read -r rule; do
    [[ "$rule" == Bash\(*\) ]] || continue
    bare="${rule#Bash(}"; bare="${bare%)}"
    bare="${bare%:\*}"           # Bash(gh:*)                -> gh
    bare="${bare%\*}"            # Bash(some tool ... *)     -> "some tool ... "
    bare="${bare%"${bare##*[! ]}"}"  # trim the trailing space it leaves
    [[ -n "$bare" ]] || continue
    if [[ "$cmd" == "$bare"* ]]; then printf '%s' "$rule"; return 0; fi
  done <<< "$ALLOW_RULES"
  return 1
}

# --- 3. Which hooks emit ask, and what command does each gate? ----------
# The gated command is declared by the hook itself in a GATES: line so this
# script never has to parse a regex out of shell source. A hook that emits
# ask without declaring GATES: is reported as UNDECLARED, not skipped.
# MUST live under .claude/scripts/ and MUST NOT end in .txt: .gitignore
# blanket-ignores `.claude/*` (un-ignoring only settings.json, hooks/,
# skills/, agents/, commands/, scripts/) AND `*.txt` later in the file, which
# wins by last-match. An untracked acceptance file is absent in a fresh clone,
# so the checker would exit 1 there for gates that ARE accepted -- a check that
# cries wolf, the exact disease this whole mechanism exists to avoid. Verify
# with `git check-ignore` after ever moving it.
ACCEPT_FILE=".claude/scripts/gate-liveness-accepted.conf"

# Reason a hook's darkness was accepted, or empty.
# Keyed on hook filename AND the command it declares, `<hook> :: <cmd> :: why`,
# never the filename alone: an acceptance records a decision about a specific
# command. Repointing an accepted hook's `# GATES:` line (say
# pr-verification-gate.sh from `gh pr create` to `gh pr merge`) must invalidate
# the acceptance and fail, because nobody agreed to that. Comment lines ignored.
accepted_reason() {
  [[ -f "$ACCEPT_FILE" ]] || return 1
  local key="$1 :: $2" line
  line=$(grep -v '^[[:space:]]*#' "$ACCEPT_FILE" | grep -m1 -F "$key :: " || true)
  [[ -n "$line" ]] || return 1
  printf '%s' "${line#*"$key :: "}"
}

INERT=0
ACCEPTED=0
FOUND=0

say "Gate liveness — ask-emitting PreToolUse hooks"
say "============================================="
if [[ -n "$MODE" ]]; then
  say "Permission mode : $MODE   (from $MODE_SRC)"
else
  say "Permission mode : default"
fi
say ""

for hook in "$HOOK_DIR"/*.sh; do
  [[ -f "$hook" ]] || continue
  grep -qE 'permissionDecision" *: *"ask|permissionDecision":"ask' "$hook" || continue
  FOUND=$((FOUND + 1))
  name="$(basename "$hook")"

  gated=$(grep -m1 -E '^# *GATES: ' "$hook" | sed -E 's/^# *GATES: *//' || true)

  reasons=()
  if [[ -n "$MODE" ]]; then
    reasons+=("permission mode '$MODE' auto-approves without prompting")
  fi
  if [[ -n "$gated" ]]; then
    if rule=$(allow_covers "$gated"); then
      reasons+=("allow rule $rule covers '$gated'")
    fi
  else
    reasons+=("hook emits ask but declares no '# GATES: <command>' line")
  fi

  if [[ ${#reasons[@]} -eq 0 ]]; then
    say "  LIVE   $name  (gates: ${gated:-?})"
  elif why=$(accepted_reason "$name" "${gated:-?}"); then
    ACCEPTED=$((ACCEPTED + 1))
    say "  INERT  $name  (gates: ${gated:-?})   [accepted]"
    for r in "${reasons[@]}"; do say "         └─ $r"; done
    say "         └─ ACCEPTED: $why"
  else
    INERT=$((INERT + 1))
    say "  INERT  $name  (gates: ${gated:-?})"
    for r in "${reasons[@]}"; do say "         └─ $r"; done
  fi
done

say ""
if [[ $FOUND -eq 0 ]]; then
  say "No ask-emitting hooks found. Nothing to check."
  exit 0
fi

if [[ $INERT -gt 0 ]]; then
  say "$INERT of $FOUND ask-emitting gate(s) are dark and NOT accepted."
  say ""
  say "An inert gate is worse than no gate: it logs a verdict, so a reader"
  say "checking 'is the hook there?' sees it working. Fix by one of:"
  say "  - have the hook emit permissionDecision 'deny' with a documented"
  say "    bypass env var such as SKIP_<GATE>, which"
  say "    no permission mode overrides; or"
  say "  - narrow the covering allow rule, if mode is the only other cause; or"
  say "  - accept it deliberately and say so in memory, so the next reader"
  say "    does not cite this gate as protection."
  exit 1
fi

if [[ $ACCEPTED -gt 0 ]]; then
  say "$ACCEPTED of $FOUND gate(s) are dark by recorded decision; none unaccepted."
  say "Those gates are NOT protection — do not cite them as such."
else
  say "All $FOUND ask-emitting gate(s) can surface."
fi
exit 0
