# The Augmented Developer Workflow

A battle-tested collection of Claude Code skills, commands, agents, and hooks that power a multi-agent AI-augmented development pipeline.

This isn't a framework — it's a **complete workflow** extracted from real production use. Every piece has been refined through hundreds of development cycles. Drop the `.claude/` directory into any project and get a structured, disciplined development flow with built-in quality gates.

## The Pipeline

```
┌────────────────────────────┬──────────────────────────────────────────────────────────────┬───────────────┐
│          You type          │                         What happens                         │ Code written? │
├────────────────────────────┼──────────────────────────────────────────────────────────────┼───────────────┤
│ /orchestrate-investigation │ 3 agents investigate, Linus review, $100 bet, plan produced  │ No            │
├────────────────────────────┼──────────────────────────────────────────────────────────────┼───────────────┤
│ /sdd                       │ Formal spec via adversarial critique (spec-builder + critic) │ No (spec)     │
├────────────────────────────┼──────────────────────────────────────────────────────────────┼───────────────┤
│ /tdd spec.md               │ Generate tests from spec, Red Gate, optional implementation  │ Tests only    │
├────────────────────────────┼──────────────────────────────────────────────────────────────┼───────────────┤
│ /vdd plan.md               │ Phase-by-phase implementation with 2 critic agents per phase │ Yes           │
├────────────────────────────┼──────────────────────────────────────────────────────────────┼───────────────┤
│ "verify it works"          │ Tests + /qa (auto-fix) or /qa-only (report), /browse         │ Fixes only    │
├────────────────────────────┼──────────────────────────────────────────────────────────────┼───────────────┤
│ /orchestrate-review-deploy │ 3-model review, auto-fix loop, commit, deploy staging        │ Fixes only    │
└────────────────────────────┴──────────────────────────────────────────────────────────────┴───────────────┘
```

Each stage is **independently useful** — you can use `/vdd` without `/sdd`, or run `/orchestrate-review-deploy` on code you wrote manually.

## What's Included

**44 assets** across 8 categories:

### Skills (12) — `.claude/skills/`

| Skill | What It Does |
|-------|-------------|
| **orchestrate-investigation** | Launches 3 parallel agents (Claude, Gemini, Codex) to investigate a problem, synthesizes findings, produces a plan with Linus-style review and $100 bet |
| **orchestrate-review-deploy** | 3-model code review → auto-fix loop → commit → deploy, with quality gates at each stage |
| **root-cause-investigation** | Systematic 4-phase root cause analysis: evidence gathering, hypothesis formation, verification, fix |
| **pr-review** | Structured PR review methodology with severity-based findings and actionable feedback |
| **pr-bot** | Automated PR review bot configuration for CI/CD integration |
| **post-deploy-verification** | Post-deployment verification with $100 bet pattern — would you bet $100 it works? |
| **critique-standards** | Severity classification standards for code review findings (Critical/Major/Minor/Suggestion) |
| **gemini-cli** | Complete Gemini CLI reference — patterns, tools, templates for multi-model workflows |
| **codex** | OpenAI Codex CLI reference for multi-model orchestration |
| **modular-architecture** | Modular architecture patterns — dependency boundaries, interface contracts, module isolation |
| **testing-strategy** | Test strategy framework — unit/integration/e2e pyramid, coverage gates, test patterns |
| **docs-architect** | Documentation architecture — ADRs, API docs, runbooks, structured documentation |

### Commands (4) — `.claude/commands/`

| Command | What It Does |
|---------|-------------|
| **`/vdd`** | **Verified-Driven Development** — Phase-by-phase implementation with 2 critic agents (code-quality-enforcer + architecture-critic) reviewing each phase. Iterates until both critics pass. |
| **`/sdd`** | **Spec-Driven Development** — Generates a formal specification using adversarial critique between spec-builder and spec-critic agents. Iterates until the spec is bulletproof. |
| **`/tdd`** | **Test-Driven Development** — Generates tests from a spec, enforces the Red Gate (tests must fail first), then optionally implements to make them pass. |
| **`/wrap-up`** | **Session Wrap-Up** — 5-phase end-of-session workflow: commit changes, prune memory, save learnings, self-improve, report. Triggered automatically by Stop hook when uncommitted changes exist. |

### Agents (9) — `.claude/agents/`

| Agent | Role |
|-------|------|
| **code-quality-enforcer** | Reviews code for bugs, security issues, test coverage, and code quality. Used by `/vdd`. |
| **architecture-critic** | Reviews architectural decisions, module boundaries, dependency flow. Used by `/vdd`. |
| **spec-builder** | Generates detailed specifications from requirements. Used by `/sdd`. |
| **spec-critic** | Adversarially reviews specs for gaps, ambiguities, and missing edge cases. Used by `/sdd`. |
| **clean-code-engineer** | Writes and refactors code with a focus on clean-code principles, SOLID, DRY/KISS. General-purpose implementation agent. |
| **code-review-expert** | Reviews recently-written code for DRY violations, best practices, and maintainability with severity-ranked findings. |
| **strategy-researcher** | Researches and compares modern approaches/technologies for a problem, weighing trade-offs (opus). |
| **tech-lead-architect** | Strategic technical leadership — system design, technology evaluation, standards, architecture reviews (opus). |
| **test-coverage-expert** | Designs comprehensive automated tests (unit/integration/e2e) to maximize meaningful coverage. |

### Hooks (7) — `.claude/hooks/`

| Hook | Trigger | What It Does |
|------|---------|-------------|
| **pre-merge-gate.sh** | Before `gh pr merge` | Runs `make pre-merge` and blocks the merge if it fails. Fast-path exit for non-merge commands; repo-scoped log under `.git/` (CWE-377 safe); jq-based command parsing. |
| **post-create-check.sh** | After `gh pr create` | Runs `make pre-merge` in a detached background process and posts the result as a PR comment. Non-blocking. |
| **post-merge-cleanup.sh** | After `gh pr merge` | Auto-removes the merged worktree via `scripts/cleanup-worktrees.sh`. Non-blocking. |
| **post-edit-lint.sh** | After Edit/Write | Auto-runs `ruff --fix` (Python) or the nearest `eslint --fix` (JS/TS) on the edited file. No-ops if the linter isn't installed. |
| **post-tool-use-tracker.sh** | After tool use | Tracks which files are being modified for audit |
| **session-start-status.sh** | Session start | Prints current branch + a summary of uncommitted changes for instant orientation. |
| **stop-wrap-up-reminder.sh** | Session stop | Reminds about `/wrap-up` when uncommitted changes exist. Blocks once, allows stop on second attempt. |

### Scripts (6)

| Script | Location | What It Does |
|--------|----------|-------------|
| **pr-review-bot.sh** | `scripts/` | Multi-agent PR review — sends PR to Claude, Gemini, and Codex for independent review, synthesizes findings. Includes hunk-aware diff truncation, non-code PR skipping, delta-aware re-review gating, and `@review` comment trigger. |
| **lib-pr-review-utils.sh** | `scripts/` | Shared library for pr-review-bot.sh — diff truncation, line mapping, output parsing, review posting |
| **cleanup-worktrees.sh** | `scripts/` | Removes `.worktrees/` worktrees whose PRs have merged (verified via GitHub API). `--dry-run` supported. Driven by the post-merge-cleanup hook. |
| **gemini-with-fallback.sh** | `.claude/scripts/` | Runs Gemini CLI with automatic seat-tiered fallback if a model/quota is unavailable |
| **reviewer-with-fallback.sh** | `.claude/scripts/` | Multi-provider reviewer for advisory/investigation seats. Provider chain: Groq → Cerebras → Ollama → Gemini. Exit-code contract (0/64/75/78); forbids `*security*`/`design-vote` seats from degrading to the free tier. |
| **reviewer-providers.sh** | `.claude/scripts/` | Provider-attempt library sourced by `reviewer-with-fallback.sh` (Groq/Cerebras/Ollama/Gemini), with spend logging. |

### Security (4)

| Asset | What It Does |
|-------|-------------|
| **.gitleaks.toml** | Gitleaks config with sensible allowlists (env examples, deps, test fixtures, placeholder regexes, public-by-design Firebase web API keys). |
| **.githooks/pre-commit** | Opt-in pre-commit hook: `gitleaks protect --staged` secret scan + optional migration prefix-collision guard. Bypass via `SKIP_*` env vars. |
| **.githooks/README.md** | How to enable (`git config core.hooksPath .githooks`), customize, and bypass the hook. |
| **SECURITY.md** | Documents the secret-scanning layer and how to wire it up. |

See [SECURITY.md](SECURITY.md) to enable secret scanning.

### Token Optimization (1)

| Asset | What It Does |
|-------|-------------|
| **docs/token-optimization.md** | Optional reference for wiring up RTK ("Rust Token Killer"), a CLI proxy that cut ~70% of tokens on routine shell ops in real use. Reference only — nothing bundled. |

### GitHub Actions (1)

| Workflow | What It Does |
|----------|-------------|
| **pr-review-bot.yml** | Triggers `pr-review-bot.sh` on PR creation/update, `@review` comments, and label changes. Supports `skip-ai-review` label. |

## Quick Start

### Full Installation (recommended)

```bash
# Clone this repo
git clone https://github.com/ReeveBarthelme/the-augmented-developer-workflow.git

# Copy the .claude directory into your project
cp -r the-augmented-developer-workflow/.claude/ your-project/.claude/

# Copy scripts
cp -r the-augmented-developer-workflow/scripts/ your-project/scripts/

# Copy GitHub Actions (optional)
cp -r the-augmented-developer-workflow/.github/ your-project/.github/

# Copy the security layer (optional)
cp the-augmented-developer-workflow/.gitleaks.toml your-project/
cp -r the-augmented-developer-workflow/.githooks/ your-project/.githooks/

# Make hooks and scripts executable
chmod +x your-project/.claude/hooks/*.sh
chmod +x your-project/.claude/scripts/*.sh
chmod +x your-project/scripts/*.sh
chmod +x your-project/.githooks/pre-commit

# Enable the secret-scanning pre-commit hook (optional)
git -C your-project config core.hooksPath .githooks
```

### A La Carte

Pick individual pieces:

```bash
# Just the /vdd command + its critic agents
cp the-augmented-developer-workflow/.claude/commands/vdd.md your-project/.claude/commands/
cp the-augmented-developer-workflow/.claude/agents/code-quality-enforcer.md your-project/.claude/agents/
cp the-augmented-developer-workflow/.claude/agents/architecture-critic.md your-project/.claude/agents/
cp the-augmented-developer-workflow/.claude/skills/critique-standards/SKILL.md your-project/.claude/skills/critique-standards/

# Just the /sdd command + its agents
cp the-augmented-developer-workflow/.claude/commands/sdd.md your-project/.claude/commands/
cp the-augmented-developer-workflow/.claude/agents/spec-builder.md your-project/.claude/agents/
cp the-augmented-developer-workflow/.claude/agents/spec-critic.md your-project/.claude/agents/

# Just the multi-agent investigation
cp -r the-augmented-developer-workflow/.claude/skills/orchestrate-investigation/ your-project/.claude/skills/

# Just the PR review bot
cp the-augmented-developer-workflow/scripts/pr-review-bot.sh your-project/scripts/
cp the-augmented-developer-workflow/scripts/lib-pr-review-utils.sh your-project/scripts/
cp -r the-augmented-developer-workflow/.github/ your-project/.github/

# Just the session wrap-up command + stop hook
cp the-augmented-developer-workflow/.claude/commands/wrap-up.md your-project/.claude/commands/
cp the-augmented-developer-workflow/.claude/hooks/stop-wrap-up-reminder.sh your-project/.claude/hooks/
chmod +x your-project/.claude/hooks/stop-wrap-up-reminder.sh
# Then add the Stop hook to your .claude/settings.json (see settings.json for format)
```

See [INSTALL.md](INSTALL.md) for detailed setup instructions.

## Full Stack Setup (Recommended)

This pipeline works standalone with just Claude Code, but reaches full power with companion tools:

### 1. Superpowers Plugin (Recommended)

The [Superpowers plugin](https://github.com/anthropics/claude-code) provides 14 workflow skills that complement this pipeline:

| Superpowers Skill | Pairs With | What It Adds |
|-------------------|-----------|-------------|
| `brainstorming` | `/orchestrate-investigation` | Design discovery before investigation |
| `systematic-debugging` | `root-cause-investigation` | 4-phase root cause methodology |
| `test-driven-development` | `/tdd` | RED→GREEN→REFACTOR discipline |
| `verification-before-completion` | `post-deploy-verification` | Evidence before claims |
| `writing-plans` / `executing-plans` | `/vdd` | Plan lifecycle management |
| `dispatching-parallel-agents` | `orchestrate-*` skills | Multi-agent coordination |
| `requesting-code-review` | `/orchestrate-review-deploy` | Review workflow discipline |

Install via the Claude Code plugin system.

### 2. gstack — Browse/QA (Optional)

[gstack](https://github.com/garrytan/gstack) provides headless browser capabilities for QA testing:

```bash
# Install gstack
git clone https://github.com/garrytan/gstack.git
# Follow gstack's setup instructions for /browse, /qa, /qa-only commands
```

This enables the "verify it works" step in the pipeline:
- `/qa` — full QA: tests, finds bugs, fixes them, re-verifies in a loop
- `/qa-only` — report-only: finds bugs but doesn't fix (for review before changes)
- `/browse` — ad-hoc browser interaction, screenshots, element inspection

### 3. Multi-Model CLI Tools (Optional)

For the multi-agent investigation and review skills:

```bash
# Gemini CLI (used by orchestrate-investigation, orchestrate-review-deploy, pr-review-bot)
npm i -g @google/gemini-cli

# Codex CLI (used by orchestrate-investigation, orchestrate-review-deploy, pr-review-bot)
# Follow OpenAI's Codex CLI installation instructions
```

### 4. Reviewer Providers — Groq / Cerebras / Ollama (Optional)

`reviewer-with-fallback.sh` runs advisory/investigation review seats through a
cheap-to-free provider chain before falling back to Gemini:

```bash
export GROQ_API_KEY=...        # console.groq.com  (primary, large context)
export CEREBRAS_API_KEY=...    # cloud.cerebras.ai (free-tier failover)
export OLLAMA_MODEL=qwen3-coder  # optional local model (if `ollama` is installed)
export GEMINI_API_KEY=...      # final fallback (also used by gemini-with-fallback.sh)
```

Chain: **Groq → Cerebras → Ollama → Gemini**. Security and design-vote seats are
forbidden here and must use the pro-only `gemini-with-fallback.sh` chain (the
script enforces this with exit code 64).

### 5. Security Layer — gitleaks (Optional)

Enable opt-in secret scanning on every commit:

```bash
brew install gitleaks                      # or see gitleaks' README
git config core.hooksPath .githooks        # one-time, per clone
```

See [SECURITY.md](SECURITY.md) and [.githooks/README.md](.githooks/README.md).

### 6. Token Optimization — RTK (Optional)

Routine `git`/`grep`/`read` shell traffic can dominate token spend. **RTK
("Rust Token Killer")** is an optional, separate CLI proxy that returns the same
output in a far more token-dense form — ~70% savings on covered operations in
real use. It is **not bundled**; this template only documents how to slot it in.

See [docs/token-optimization.md](docs/token-optimization.md).

## How the Pieces Compose

```
                    ┌─────────────────────┐
                    │   Problem / Task    │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │ /orchestrate-       │  3 agents investigate
                    │  investigation      │  → synthesized plan
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │      /sdd           │  spec-builder + spec-critic
                    │                     │  → bulletproof spec
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │      /tdd           │  Tests from spec
                    │                     │  → Red Gate → failing tests
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │      /vdd           │  Phase-by-phase implementation
                    │                     │  → 2 critics per phase
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Verify (tests +    │  /qa or /qa-only
                    │  browser QA)        │  + /browse → iterate
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │ /orchestrate-       │  3-model review
                    │  review-deploy      │  → auto-fix → deploy
                    └──────────┴──────────┘
```

## Dependencies

| Tool | Required? | Used By |
|------|-----------|---------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | **Yes** | Everything |
| Superpowers plugin | Recommended | Brainstorming, debugging, TDD, verification discipline |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | Optional | orchestrate-investigation, orchestrate-review-deploy, pr-review-bot |
| [Codex CLI](https://github.com/openai/codex) | Optional | orchestrate-investigation, orchestrate-review-deploy, pr-review-bot |
| [gstack](https://github.com/garrytan/gstack) | Optional | Browse/QA verification step |
| [`gh`](https://cli.github.com/) | Optional | pr-bot, hooks, pr-review-bot script, worktree cleanup |
| `jq` | Optional | pre-merge-gate hook, pr-review-bot script, reviewer plumbing |
| `make` | Optional | pre-merge-gate hook (expects `make pre-merge` target) |
| [gitleaks](https://github.com/gitleaks/gitleaks) | Optional | Secret-scanning layer (`.githooks/pre-commit`, `.gitleaks.toml`) |
| [Groq](https://console.groq.com/) / [Cerebras](https://cloud.cerebras.ai/) / [Ollama](https://ollama.com/) | Optional | Fast/free reviewer providers for `reviewer-with-fallback.sh` |
| RTK | Optional | Token-optimization proxy — see [docs/token-optimization.md](docs/token-optimization.md) |

## Customization

Each asset is designed to be customized. Look for comments like:

```
# Customize: your deploy command here
# Customize: your project-specific patterns here
```

The most common customizations:
- **Deploy commands** in `orchestrate-review-deploy` and `post-deploy-verification`
- **File patterns** in `post-tool-use-tracker.sh`
- **Review focus areas** in `pr-review-bot.sh`
- **Pre-merge targets** in `pre-merge-gate.sh` (default: `make pre-merge`)

## Credits

This pipeline builds on work from several open-source projects:

- **`/vdd`, `/sdd`, `/tdd` commands + agents + critique-standards** — originally from [sherifattia/vdd](https://github.com/sherifattia/vdd) (Verification-Driven Development). Includes the `architecture-critic`, `code-quality-enforcer`, `spec-builder`, `spec-critic` agents and `critique-standards` skill.
- **gemini-cli** skill — originally from [forayconsulting/gemini_cli_skill](https://github.com/forayconsulting/gemini_cli_skill)
- **codex** skill — originally from [skills-directory/skill-codex](https://github.com/skills-directory/skill-codex)

Optional integrations referenced by this template (none bundled):

- **RTK ("Rust Token Killer")** — optional token-optimization CLI proxy; credit to its author. See [docs/token-optimization.md](docs/token-optimization.md).
- **[Groq](https://console.groq.com/), [Cerebras](https://cloud.cerebras.ai/), and [Ollama](https://ollama.com/)** — optional reviewer providers powering the fast/free tiers of `reviewer-with-fallback.sh`.
- **[gitleaks](https://github.com/gitleaks/gitleaks)** — powers the opt-in secret-scanning layer.

The orchestration skills (`orchestrate-investigation`, `orchestrate-review-deploy`), agents, hooks, reviewer plumbing, security layer, PR review bot, and the multi-agent pipeline that ties everything together were developed independently.

## License

MIT
