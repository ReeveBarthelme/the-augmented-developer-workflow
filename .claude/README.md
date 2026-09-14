# `.claude/` layout

What lives where, and which files you must edit before a hook or script does
anything useful in your project.

```
.claude/
├── settings.json      # hook wiring + permission allow-list (checked in)
├── settings.local.json.example   # per-developer overrides (copy, never commit)
├── agents/            # subagent definitions used by /sdd, /vdd and the review skills
├── commands/          # slash commands: /sdd /tdd /vdd /wrap-up
├── hooks/             # stdin-driven gates and trackers — see hooks/README.md
├── scripts/           # helpers the skills and hooks call
└── skills/            # skill definitions loaded by name
```

## Hooks

Read `hooks/README.md` before editing or adding one. It carries the PreToolUse
decision protocol, which is the part that silently breaks: a blocking decision
nested under the wrong key exits 0, records success, and lets the tool run.

| Hook | Event | What it does |
|------|-------|--------------|
| `pre-merge-gate.sh` | PreToolUse Bash | Blocks `gh pr merge` until `make pre-merge` passes. |
| `pr-verification-gate.sh` | PreToolUse Bash | Asks for confirmation before `gh pr create` on a non-trivial diff. |
| `push-verification-gate.sh` | PreToolUse Bash | Same checkpoint for a push straight to the default branch. |
| `pipe-mask-warn.sh` | PreToolUse Bash | Warns when a state-changing or verification command is piped into `tail`/`head`/`grep`, which masks its exit code. |
| `exec-wait-loop-gate.sh` | PreToolUse Bash | Denies an unbounded wait loop whose condition runs a wrapper that swallows exit status. Off until you set `EXEC_WAIT_LOOP_WRAPPERS`. |
| `worktree-lease.sh` | SessionStart, PreToolUse Edit/Write | Stops a second session from clobbering uncommitted work in the same worktree. |
| `delegation-nudge.sh` | PreToolUse Edit/Write | Nudges an expensive main loop to delegate file edits. Advisory unless you arm it. |
| `post-create-check.sh` | PostToolUse Bash | After `gh pr create`, runs the local CI target in the background and posts the result as a PR comment. |
| `post-merge-cleanup.sh` | PostToolUse Bash | After `gh pr merge`, removes the merged branch's worktree. |
| `post-tool-use-tracker.sh` | PostToolUse Bash | Tracks which files a session changed, for context management. |
| `delegation-track.sh` | PostToolUse Edit/Write | Logs one metrics event per file-touching call. |
| `agent-spawn-capture.sh` | PreToolUse Agent/Task | Logs subagent spawns for the delegation scorecard. |
| `context-cost-nudge.sh` | UserPromptSubmit | Warns at most three times per session when resident context makes each turn materially more expensive. |

Every hook fails open. A missing `jq`, an empty payload, or an internal error
exits 0 and the tool call proceeds.

Hook tests live in `hooks/tests/`. Run one directly:

```bash
bash .claude/hooks/tests/exec-wait-loop-gate.test.sh
```

## Scripts

| Script | Purpose |
|--------|---------|
| `delegation-lib.sh` | Shared helpers for the delegation hooks. Sourced, never executed. |
| `delegation-scorecard.sh` | Prints the trailing-10-session delegation report `/wrap-up` reads. |
| `session-cost-report.sh` | Per-session token and cost breakdown from the transcripts. |
| `output-tokens-baseline.py` | Baseline output-token counts to compare a session against. |
| `memory-compact.sh` | Report-only planner for trimming the auto-memory index. Never edits. |
| `check-gate-liveness.sh` | Reports which gates are actually armed. A disabled workflow or an unreachable hook is a gate that protects nothing. |
| `gate-liveness-accepted.conf` | Gates knowingly left dark, with a reason each. |
| `gemini-with-fallback.sh` | Gemini CLI wrapper: model fallback, quota (exit 75) and billing (exit 78) separation, spend log. |
| `reviewer-with-fallback.sh`, `reviewer-providers.sh` | Provider chain for the advisory review seat. |

## Things you must edit for your project

| File | What to change |
|------|----------------|
| `settings.json` | The permission allow-list. The shipped entries are read-only git and file commands. |
| `hooks/exec-wait-loop-gate.sh` | Set `EXEC_WAIT_LOOP_WRAPPERS`, or the gate stays a no-op. |
| `hooks/pipe-mask-warn.sh` | The `PATTERN` list names `deploy*.sh`, `migrate.sh` and `release.sh`. Replace with your own state-changing scripts. |
| `hooks/pre-merge-gate.sh`, `hooks/post-create-check.sh` | Both call `make pre-merge`. Point them at your local CI target. |
| `skills/orchestrate-review-deploy/SKILL.md` | The project-specific security checklist and the deploy commands. |
| `scripts/gate-liveness-accepted.conf` | Your own accepted-dark list. |

## Skills

`skills/*/SKILL.md` are loaded by name. `orchestrate-investigation` is the entry
point for non-trivial work; `orchestrate-review-deploy` is the review pass
before a merge. `unslop` cuts machine-written tells from prose artifacts and is
the one to run on a PR body or a commit message.
