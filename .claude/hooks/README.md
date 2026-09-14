# Claude Code Hooks

Every hook in this directory reads its JSON payload from **stdin**, never from
environment variables, and fails **open**: a missing dependency, malformed
payload, or internal error exits 0 and lets the tool call proceed. A broken
hook must never break the session.

Wire them in `.claude/settings.json`. Paths there use `$CLAUDE_PROJECT_DIR` so
they resolve from a worktree or a subdirectory, not only from the repo root.

---

## Quality Gate Hooks

### PreToolUse decision protocol — READ THIS BEFORE WRITING A GATE

A **blocking** decision must be NESTED. `permissionDecision` is not a recognized
TOP-LEVEL key for this event, so a top-level one is silently **ignored** — the
hook exits 0, the transcript records `hook_success`, and the tool runs anyway.

> Do not generalize this to "top-level decisions are ignored." There IS a
> top-level `decision` key — the 2.1.221 binary documents it as `"block"` for
> PostToolUse/Stop/UserPromptSubmit, and **deprecated for PreToolUse, use
> `hookSpecificOutput.permissionDecision` instead**. Its exact PreToolUse
> handling is not something we verified. Do not use either top-level form.

Three gates in this directory shipped with the top-level shape and were dark
from the day they were written. `pr-verification-gate.sh` and
`push-verification-gate.sh` were fixed 2026-08-10; **`pre-merge-gate.sh` is
still dark** — see its section below.

```jsonc
// ✅ blocking — honored
{"hookSpecificOutput":{"hookEventName":"PreToolUse",
                       "permissionDecision":"ask",   // allow | deny | ask  (see note on defer)
                       "permissionDecisionReason":"..."},
 "systemMessage":"..."}                              // top-level, also honored

// ❌ ignored — no effect whatsoever
{"permissionDecision":"ask","systemMessage":"..."}
// ❌ "block" is not a valid permissionDecision at all
//    (valid: allow | deny | ask). "block" is a legacy value of the
//    deprecated top-level "decision" key — a different field entirely.
//
// ⚠️ "defer" is NOT usable here. The 2.1.221 binary's own schema string lists
//    the enum as exactly "allow", "deny", or "ask" (PreToolUse only), and it
//    logs: `returned permissionDecision=defer in interactive mode; ignoring
//    (defer is print-mode only)`. A gate using defer is dark in exactly the
//    way this whole document exists to prevent.
```

Conventions used here:
- **Only blocking decisions are nested.** The `allow` fast paths in these
  scripts deliberately keep the ignored top-level shape: an ignored `allow`
  falls through to the normal permission flow, whereas a nested `allow` *skips
  the confirmation prompt* (deny/ask permission RULES still apply, but the
  prompt does not). Never "fix" an `allow` line into the nested form. On a
  catch-all fast path this is catastrophic: `pipe-mask-warn.sh` emits an inert
  top-level `allow` for every unmatched Bash command, so nesting it would
  auto-approve every Bash call in every session.
- **Log the emitted verdict**, not just the command. That post-mortem
  needed a transcript dig purely because the log recorded no decision.
- `exit 2` (used by `delegation-nudge.sh` / `worktree-lease.sh`) is a separate,
  working blocking mechanism — unrelated to this JSON protocol.

**Scope boundary — these gates are not shell parsers.** They match the common
spellings of the commands they guard (plain, path-prefixed, `env`-prefixed,
wrapper-prefixed, and global options in the positions the CLI documents).
They do **not** tokenize shell, and they do not resist deliberate evasion:
`"gh" pr create`, `\gh pr create`, `gh 2>/dev/null pr create`, line
continuations, and `$VAR`-indirected binaries all slip through. That is an
accepted design limit, not an open bug — these gates are a self-honesty
checkpoint for a cooperating agent, not a security boundary against an
adversary who is trying to get around them. Sizing them to the incident is the
CLAUDE.md Proportionality rule; chasing the evasion tail is not. Two known,
non-adversarial gaps ARE worth closing if they ever bite: `git -C other-repo
push` (and `--git-dir`/`--work-tree`) matches but then evaluates the *hook's*
repo rather than the target one, and unusual option arity can over-match
(`gh --version pr create` prompts). Both fail toward "extra prompt" or
"unchanged existing behavior", never toward a new bypass.

**How this was found**: a PR opened without a review pass, the 6th such instance. `pr-verification-gate.sh`
*did* fire 3.9s earlier and emitted `ask`; the decision was discarded because of
the shape above, and only its `systemMessage` reached the model, after the tool
had already run.

### `pre-merge-gate.sh` (PreToolUse → Bash)

> ⚠️ **CURRENTLY DARK — does not block anything.** It emits `"block"`, which is
> not a valid `permissionDecision`, at the top level, which is ignored anyway.
> It still *runs* `make pre-merge` synchronously (up to 15 min) on every
> `gh pr merge` and then discards the verdict. See the PreToolUse decision
> protocol above. Arming it is deliberately deferred: it needs a verified-green
> `make pre-merge` first, since it would become a real blocker across every
> worktree at once. Consider an early exit while it stays dark, so it stops
> burning 15 min per merge attempt for no effect.

Intended (not current) behavior: block `gh pr merge` until `make pre-merge` passes. Synchronous hard gate.
- Timeout: 900s (15 min)
- Requires: `jq` (degrades to allow-with-warning if missing)
- Regex: `gh\s+pr\s+merge(\s|$)` (avoids `merge-queue` false positive)

### `post-create-check.sh` (PostToolUse → Bash)
After `gh pr create`, runs `make pre-merge` in background and posts results as PR comment.
- Timeout: 10s (hook exits instantly; background process is fully detached)
- Guards: detached HEAD, missing Makefile, API race (3s sleep)
- Sanitizes triple backticks in output to prevent markdown breakage

### `post-tool-use-tracker.sh` (PostToolUse → *)
Context tracker that reminds about TDD, deployment gates, and file sizes based on modified files.

### `pr-verification-gate.sh` (PreToolUse → Bash)
Forces an "ask" confirmation before `gh pr create` on any PR touching non-doc/non-test files, reciting the local verification checklist in the prompt. Added after the 5th documented instance of a PR opening before verification actually ran, surfaced only when the user asked after the fact. Documentation-only fixes, first a memory entry and then a bold section in the project instructions, had already failed to prevent recurrence 4 times.
- Timeout: 15s
- Requires: `jq` (fails open — allows — if missing)
- Regex: `$GH_PR_CREATE_RE` — tolerates global options in both documented
  positions (`gh --repo o/r pr create`, `gh pr -R o/r create`), path/env
  prefixes (`/usr/local/bin/gh pr create`), and the official `gh pr new` alias
  (`gh pr create --help` lists it under ALIASES). A bare `gh\s+pr\s+create`
  match missed every one of those valid forms.
- Carve-out: skips the ask if every file in `git diff --name-only origin/<default-branch>...HEAD` matches `*.md` / `docs/` / `tests?/` / `test_*.py` / `*_test.py` / `*.example` / `*.template`
- Fails open (allows silently) on: missing `jq`, no `REPO_ROOT`, or HEAD having no diff versus the resolved base (fork PR, already-merged base, or a detached HEAD sitting *on* that base — a detached HEAD with changes still asks). Never hard-blocks; "ask" at worst
- Log: `<git-dir>/pr-verification-gate.log`, including the emitted VERDICT
- Tests: `tests/deployment/unit/test_pr_verification_gate.bats`

---

## Session Cost Hooks

### `context-cost-nudge.sh` (UserPromptSubmit)

Advisory only. Warns when resident context has grown expensive enough that
continuing the session costs materially more than restarting it.

**Why**: `cache_read` is 57-65% of session spend and is billed as
*turns x resident context*. Measured across 20 sessions / 5,800+ turns
(`.claude/scripts/session-cost-report.sh --curve`), the same unit of work costs
**6.60x** more at turn ~950 than at turn ~50:

| turns | mean context | % of 1M window | vs turns 0-99 |
|---|---|---|---|
| 0-99 | 118,927 | 11.9% | 1.00x |
| 300-399 | 321,676 | 32.2% | 2.70x |
| 600-699 | 544,816 | 54.5% | 4.58x |
| 900-999 | 784,891 | 78.5% | **6.60x** |

Note this is **not** a context-window problem — turn 250 sits near 30% of a 1M
window. It is purely price, so the message says "the objective changed, start
fresh", never "you are running out of room".

**Sized to the incident** (CLAUDE.md Proportionality): session `cfc07473` ran
995 turns. The user typed *"merge, cleanup and /wrap-up"* at turn 796 and
`/wrap-up` ran at turn 808 — then 187 more turns executed on an unrelated PR at
~712K context (~$200 vs ~$42 in a fresh session).

- **It cannot end a session.** No Claude Code hook can. Detector, not enforcer.
- **Silent below 350K** — it runs on EVERY prompt, so a chatty version would
  itself become the resident-context problem it flags. Verified: prints nothing
  and exits 0 below the band.
- Bands 350K / 500K / 650K, firing **at most once each per session** (~50 tokens
  per fire, 3x maximum). State: `.claude/metrics/context-nudge/<session>.band`.
- Fails open (silent, exit 0) on: missing `jq`, missing/unreadable transcript,
  no usage record in the tail, unparseable context value.
- Reads only `tail -c 1000000` of the transcript — 74ms measured against a
  762KB live transcript.
- No enforcement mode and no arming file. Unlike `delegation-nudge.sh` this
  never blocks, because the correct response ("start a new session") is not
  something a hook can perform on the user's behalf.

### `.claude/scripts/session-cost-report.sh` (not a hook)

Offline analyzer over `~/.claude/projects/<encoded-cwd>/*.jsonl`. Deliberately
**not** backed by a logging hook: transcripts already contain every usage
record, so a per-turn logger would add runtime cost to re-record existing data.

- `--curve` cost per turn vs position; `--rebuilds` full-prefix cache rebuilds
  attributed to trigger; default = per-session totals. `--limit N` widens.
- Dedupes records by `uuid` — assistant messages recur in transcripts, and
  counting them raw double-counts usage (this inflated one rebuild count 22 -> 44).
- Dollar columns assume Opus API list rates and are notional on a subscription.
  **The ratios are the durable finding, not the dollars.**
- Use it to verify session-length claims prospectively: compare cost per *unit
  of work* (PRs merged, commits landed), never cost per session, which
  trivially falls when sessions get shorter.
- It derives the transcript dir from `CLAUDE_PROJECT_DIR`, so **run from a
  worktree it reads that worktree's transcripts, not the main repo's** — each
  worktree gets its own `~/.claude/projects/<encoded-cwd>/` (24 such dirs exist
  today). Arguably correct, but it surprises anyone comparing sessions across
  worktrees; `cd` to the main checkout for a whole-project view.

---

## Model-Tiering Delegation Scorecard Hooks

Silently measure the "main loop orchestrates, Sonnet executes" policy (see root `CLAUDE.md`) so it's auditable instead of anecdotal. Logs counts only, never edit content. Report: `.claude/scripts/delegation-scorecard.sh` (also surfaced by `/wrap-up` Phase 5).

### `delegation-track.sh` (PostToolUse → Edit|Write|NotebookEdit)
Logs one JSONL event per file-touching call — main-loop vs subagent origin, source vs exempt file (docs/memory/`.claude/` are exempt), line-count delta — to the MAIN repo's `.claude/metrics/delegation-YYYY-MM.jsonl` regardless of which worktree the session runs in.
- Fails open on any error (missing jq/lib, malformed stdin, empty file path) — never blocks editing.

### `delegation-nudge.sh` (PreToolUse → Edit|Write|NotebookEdit)
On the 1st and 5th main-loop source edit in a session, surfaces an advisory `additionalContext` reminder to delegate. Subagent edits (`.agent_id` present) always pass through silently.
- Enforcement is INERT by default: a human must `touch .claude/metrics/tiering-enforce` (from the main repo checkout) to arm blocking on the 3rd+ main-loop source edit. Bypass: `SKIP_TIERING_CHECK=1` or a 1h self-expiring `.claude/metrics/tiering-override`.
- Fails open on bad/missing data; only blocks on the one deliberate armed+threshold condition.

### `agent-spawn-capture.sh` (PreToolUse → Agent|Task)
Captures the shape of every subagent spawn (tool name, truncated 300-char prompt prefix, session id) to `.claude/metrics/agent-spawn-capture.jsonl`, feeding future scorecard refinements.
- Fails open; never blocks a spawn.

---

**Note**: Skills auto-activate based on semantic matching of their descriptions in SKILL.md frontmatter. Claude decides when to use them based on your request and the skill's description. This hook provides additional prompt-based suggestions for better UX.

### `exec-wait-loop-gate.sh` (PreToolUse → Bash) — BLOCKING (deny)

**Off until you configure it.** Set `EXEC_WAIT_LOOP_WRAPPERS` to an ERE alternation of the command wrappers your project uses, e.g. `export EXEC_WAIT_LOOP_WRAPPERS='myproxy|mywrapper'`. Empty or unset means the gate allows everything, because a template cannot guess your wrapper's name and a gate that guessed one would deny nothing while looking armed.

Once configured it denies an `until`/`while` loop whose condition runs a listed wrapper, e.g. `until ! ps aux | myproxy grep -q "[t]sc -b"; do sleep 5; done`. A wrapper that returns its own exit status instead of the wrapped command's makes the condition never flip, so the loop spins forever and a subagent idles "waiting for the monitor". Deny, not ask, because a subagent has nobody to answer a prompt. The reason text carries the rewrite: a foreground run redirected to a file, or a bounded `for` poll with a plain test. Nested `permissionDecision` per the protocol above. Regex: keyword, then a condition span containing a wrapper token, then `;`/newline + `do`. Test: `bash .claude/hooks/tests/exec-wait-loop-gate.test.sh`, 16 literal shapes including the unconfigured no-op case; the test sets the variable itself. Known limit: a semicolon-separated condition list (`while a; myproxy grep -q x; do`) is not matched, because newlines map to `;` as statement boundaries and the gate is a regex tripwire, not a parser.
