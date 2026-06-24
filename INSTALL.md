# Installation Guide

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and configured

## Full Suite Installation

The fastest way to get everything:

```bash
# Clone this repo
git clone https://github.com/ReeveBarthelme/the-augmented-developer-workflow.git
cd the-augmented-developer-workflow

# Copy everything to your project
cp -r .claude/ /path/to/your-project/.claude/
cp -r scripts/ /path/to/your-project/scripts/
cp -r .github/ /path/to/your-project/.github/

# Security layer (optional)
cp .gitleaks.toml /path/to/your-project/
cp -r .githooks/ /path/to/your-project/.githooks/

# Supply-chain hardening (optional but recommended)
cp .npmrc /path/to/your-project/                 # blocks malicious npm install scripts
# .github/workflows/security.yml is included in the .github/ copy above

# Make scripts executable
chmod +x /path/to/your-project/.claude/hooks/*.sh
chmod +x /path/to/your-project/.claude/scripts/*.sh
chmod +x /path/to/your-project/scripts/*.sh
chmod +x /path/to/your-project/.githooks/pre-commit

# Enable the secret-scanning pre-commit hook (optional, one-time per clone)
git -C /path/to/your-project config core.hooksPath .githooks
```

### Merging with Existing `.claude/` Directory

If your project already has a `.claude/` directory:

```bash
# Copy skills, commands, agents individually (won't overwrite existing)
cp -rn .claude/skills/ /path/to/your-project/.claude/skills/
cp -rn .claude/commands/ /path/to/your-project/.claude/commands/
cp -rn .claude/agents/ /path/to/your-project/.claude/agents/
cp -rn .claude/hooks/ /path/to/your-project/.claude/hooks/
cp -rn .claude/scripts/ /path/to/your-project/.claude/scripts/

# Security layer (optional)
cp -n .gitleaks.toml /path/to/your-project/
cp -rn .githooks/ /path/to/your-project/.githooks/

# Manually merge settings.json (don't overwrite!)
# Compare .claude/settings.json with your existing one and merge the hooks +
# permissions entries
```

## A La Carte Installation

### The `/vdd` Pipeline (Verified-Driven Development)

Implements code phase-by-phase with two critic agents reviewing each phase.

**Files needed:**
```
.claude/commands/vdd.md
.claude/agents/code-quality-enforcer.md
.claude/agents/architecture-critic.md
.claude/skills/critique-standards/SKILL.md
```

**Usage:** `/vdd plan.md` where `plan.md` is your implementation plan.

### The `/sdd` Pipeline (Spec-Driven Development)

Generates bulletproof specifications through adversarial critique.

**Files needed:**
```
.claude/commands/sdd.md
.claude/agents/spec-builder.md
.claude/agents/spec-critic.md
```

**Usage:** `/sdd` — describe what you want to build, get a reviewed spec.

### The `/tdd` Pipeline (Test-Driven Development)

Generates tests from a spec with Red Gate enforcement.

**Files needed:**
```
.claude/commands/tdd.md
.claude/skills/testing-strategy/SKILL.md
```

**Usage:** `/tdd spec.md` — generates tests that must fail first.

### Multi-Agent Investigation

Launches 3 AI models to investigate a problem in parallel.

**Files needed:**
```
.claude/skills/orchestrate-investigation/SKILL.md
.claude/skills/gemini-cli/           (entire directory)
.claude/skills/codex/                (entire directory)
```

**Additional requirements:** Gemini CLI and/or Codex CLI installed.

**Usage:** Invoke the `orchestrate-investigation` skill and describe the problem.

### Multi-Agent Review & Deploy

3-model code review with auto-fix loop.

**Files needed:**
```
.claude/skills/orchestrate-review-deploy/SKILL.md
.claude/skills/critique-standards/SKILL.md
.claude/skills/gemini-cli/           (entire directory)
.claude/skills/codex/                (entire directory)
```

**Additional requirements:** Gemini CLI and/or Codex CLI installed.

**Usage:** Invoke the `orchestrate-review-deploy` skill after implementation is complete.

### Automated PR Review Bot

Automatically reviews PRs using multiple AI models.

**Files needed:**
```
scripts/pr-review-bot.sh
.github/workflows/pr-review-bot.yml
.claude/skills/pr-bot/SKILL.md
.claude/skills/pr-review/SKILL.md
```

**Additional requirements:** `gh` CLI, Gemini CLI (optional), Codex CLI (optional).

**Setup:**
1. Copy files to your project
2. Add required secrets to your GitHub repo settings:
   - `ANTHROPIC_API_KEY` — for Claude review
   - `GEMINI_API_KEY` — for Gemini review (optional)
   - `OPENAI_API_KEY` — for Codex review (optional)
3. The workflow triggers automatically on PR creation/update

### Hooks

**Files needed:**
```
.claude/hooks/pre-merge-gate.sh
.claude/hooks/post-create-check.sh
.claude/hooks/post-merge-cleanup.sh
.claude/hooks/post-edit-lint.sh
.claude/hooks/post-tool-use-tracker.sh
.claude/hooks/session-start-status.sh
.claude/hooks/stop-wrap-up-reminder.sh
scripts/cleanup-worktrees.sh          (required by post-merge-cleanup.sh)
.claude/settings.json
```

**Setup:**
1. Copy hook scripts and make executable: `chmod +x .claude/hooks/*.sh scripts/cleanup-worktrees.sh`
2. Merge the hooks configuration from `settings.json` into your existing `.claude/settings.json`
3. Customize file patterns in `post-tool-use-tracker.sh` for your project
4. Ensure your project has a `make pre-merge` target (or customize `pre-merge-gate.sh`)
5. `post-merge-cleanup.sh` auto-removes merged worktrees under `.worktrees/` after `gh pr merge`. Test it first with `scripts/cleanup-worktrees.sh --dry-run`.
6. `post-edit-lint.sh` (PostToolUse `Edit|Write`) auto-fixes lint on save via `ruff`/`eslint` — it no-ops if neither is installed, so it's safe to leave wired. Note it rewrites the file with `--fix`; drop the flag to lint-only if you'd rather it not touch files. `session-start-status.sh` (SessionStart) prints branch + uncommitted status; both are zero-config.

### Standalone Agents

General-purpose agents you can invoke directly (not tied to `/vdd` or `/sdd`):

**Files needed (pick any):**
```
.claude/agents/clean-code-engineer.md   (sonnet) — write/refactor clean code
.claude/agents/code-review-expert.md     (sonnet) — review recent code
.claude/agents/strategy-researcher.md    (opus)   — research optimal approaches
.claude/agents/tech-lead-architect.md    (opus)   — architecture & tech decisions
.claude/agents/test-coverage-expert.md   (sonnet) — comprehensive test design
```

**Usage:** Reference the agent by name when delegating a task, e.g. "use the tech-lead-architect agent to design this."

### Multi-Provider Reviewer Plumbing

Makes the orchestrate-* review seats runnable through a cheap-to-free provider
chain (Groq → Cerebras → Ollama → Gemini) before paying for pro models.

**Files needed:**
```
.claude/scripts/reviewer-with-fallback.sh
.claude/scripts/reviewer-providers.sh
.claude/scripts/gemini-with-fallback.sh   (final fallback — required)
```

**Setup:**
1. Copy and make executable: `chmod +x .claude/scripts/*.sh`
2. Provide API keys via environment (or a repo-root `.env` — keys are extracted, never sourced):
   - `GROQ_API_KEY` — console.groq.com (primary, large context)
   - `CEREBRAS_API_KEY` — cloud.cerebras.ai (free-tier failover)
   - `GEMINI_API_KEY` — final fallback
   - `OLLAMA_MODEL` — optional local model (default `qwen3-coder`, used only if `ollama` is on PATH)
3. Security and design-vote seats are **forbidden** here (exit 64) and must use the pro-only `gemini-with-fallback.sh` chain.

**Usage:** `REVIEWER_SEAT=investigation .claude/scripts/reviewer-with-fallback.sh "your prompt" -o text`

### Security Layer (Secret Scanning)

**Files needed:**
```
.gitleaks.toml
.githooks/pre-commit
.githooks/README.md
SECURITY.md
```

**Setup:**
1. Install gitleaks (optional but recommended): `brew install gitleaks`
2. Make the hook executable: `chmod +x .githooks/pre-commit`
3. Enable it (one-time per clone): `git config core.hooksPath .githooks`
4. (Optional) Enable the migration prefix-collision guard by setting `MIGRATIONS_DIR` in `.githooks/pre-commit`.

Bypass with `SKIP_SECRET_SCAN=1`, `SKIP_MIGRATION_CHECK=1`, or `SKIP_HOOKS=1`.
See `.githooks/README.md` and `SECURITY.md`.

### Supply-Chain Hardening (Bad-Package Defense)

Stops malicious or vulnerable npm/Python packages from running code or shipping.

**Files needed:**
```
.npmrc                          (blocks npm install-script execution)
.github/workflows/security.yml  (pip-audit + npm audit + bandit + gitleaks + SBOM)
```

**Setup:**
1. Copy `.npmrc` to your project root (and into any subdir with its own
   `package.json`). It sets `ignore-scripts=true` — the single most effective
   defense against npm install-hook worms (shai-hulud / TanStack class) — plus
   `audit-level=high`. See the file's header for the native-build escape hatch.
2. Copy `.github/workflows/security.yml` and **customize the `# Customize:`
   markers** (requirements file paths, frontend dir, bandit source dirs). Remove
   any job your stack doesn't use (e.g. drop `npm-audit` for a pure-Python repo).
3. For local pre-merge mirroring, the `Makefile.example` `security:` target now
   runs `gitleaks` + `pip-audit` + `bandit` + `npm audit` when each is installed.

**Python note:** `pip` only runs code from *source* distributions, not wheels.
For stronger Python supply-chain safety, pin and verify hashes:
```bash
pip install --require-hashes -r requirements.txt   # needs hashes in the file
pip install --only-binary :all: <pkg>              # avoid sdist setup.py execution
```
`pip-audit` (in `security.yml`) covers the CVE side.

### Resume / Start Session (Pipeline Entry Point)

Reconstructs a previous Claude Code session from its raw JSONL and reports
wrap-up items — the entry point of the workflow pipeline.

**Files needed:**
```
.claude/skills/resume-session/SKILL.md
```

**Usage:** Start a message with "continuing from session id `<UUID>`" (or "where
did we leave off in session `<UUID>`"). It locates
`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, summarizes the last
exchange, and surfaces uncommitted changes / open PRs / dangling todos. It
**stops after the report** — it never auto-merges or deploys. Distinct from
`/context-restore` (which reads `/context-save` checkpoints).

**Pipeline:** `resume-session` → `/orchestrate-investigation` → `/sdd` → `/tdd`
→ `/vdd` → verify (`/qa` loop, gstack) → `/orchestrate-review-deploy` →
`/wrap-up`.

### Token Optimization (RTK)

**Files needed:**
```
docs/token-optimization.md
```

RTK is a **separate, optional** CLI proxy — nothing is bundled here. See
`docs/token-optimization.md` for how to wire the global hook rewrite and the
optional per-project allowlist.

## Optional: Multi-Model Setup

For the full multi-agent experience (orchestrate-investigation, orchestrate-review-deploy, pr-review-bot):

### Gemini CLI

```bash
npm i -g @google/gemini-cli
```

Set up authentication per [Gemini CLI docs](https://github.com/google-gemini/gemini-cli).

### Codex CLI

Follow [OpenAI Codex CLI](https://github.com/openai/codex) installation instructions.

### gstack (Browse/QA)

For browser-based QA verification:

```bash
git clone https://github.com/garrytan/gstack.git
# Follow gstack's README for setup
```

This enables `/browse`, `/qa`, and `/qa-only` commands for automated browser testing.

## Customization

After installation, search for `# Customize:` comments in the copied files to find project-specific settings you should adjust:

```bash
grep -r "# Customize:" .claude/ scripts/
```

Common customizations:
- **Deploy commands** — Update deploy scripts/URLs in orchestrate-review-deploy and post-deploy-verification
- **File patterns** — Update watched paths in post-tool-use-tracker.sh
- **Review focus** — Adjust review priorities in pr-review-bot.sh
- **Pre-merge gates** — Ensure `make pre-merge` exists or customize pre-merge-gate.sh
- **Migration guard** — Set `MIGRATIONS_DIR` in `.githooks/pre-commit` to enable the prefix-collision check
- **Test conventions** — Update testing-strategy skill for your language/framework

## Verification

After installation, verify everything is wired correctly:

```bash
# Check all scripts are executable
find .claude/hooks -name "*.sh" -exec test -x {} \; -print
find .claude/scripts -name "*.sh" -exec test -x {} \; -print
find scripts -name "*.sh" -exec test -x {} \; -print
test -x .githooks/pre-commit && echo ".githooks/pre-commit"

# Validate settings.json
jq . .claude/settings.json

# (Optional) Validate the gitleaks config and run a self-scan
gitleaks detect --config .gitleaks.toml --no-banner

# Validate GitHub Actions workflow
# (push to a branch and check the Actions tab)

# Test a command
# In Claude Code, type /vdd or /sdd to verify commands are available
```
