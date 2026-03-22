# Installation Guide

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and configured

## Full Suite Installation

The fastest way to get everything:

```bash
# Clone this repo
git clone https://github.com/reeveb/the-augmented-developer-workflow.git
cd the-augmented-developer-workflow

# Copy everything to your project
cp -r .claude/ /path/to/your-project/.claude/
cp -r scripts/ /path/to/your-project/scripts/
cp -r .github/ /path/to/your-project/.github/

# Make scripts executable
chmod +x /path/to/your-project/.claude/hooks/*.sh
chmod +x /path/to/your-project/.claude/scripts/*.sh
chmod +x /path/to/your-project/scripts/*.sh
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

# Manually merge settings.json (don't overwrite!)
# Compare .claude/settings.json with your existing one and merge the hooks entries
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
.claude/hooks/post-tool-use-tracker.sh
.claude/settings.json
```

**Setup:**
1. Copy hook scripts and make executable: `chmod +x .claude/hooks/*.sh`
2. Merge the hooks configuration from `settings.json` into your existing `.claude/settings.json`
3. Customize file patterns in `post-tool-use-tracker.sh` for your project
4. Ensure your project has a `make pre-merge` target (or customize `pre-merge-gate.sh`)

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
- **Test conventions** — Update testing-strategy skill for your language/framework

## Verification

After installation, verify everything is wired correctly:

```bash
# Check all scripts are executable
find .claude/hooks -name "*.sh" -exec test -x {} \; -print
find .claude/scripts -name "*.sh" -exec test -x {} \; -print
find scripts -name "*.sh" -exec test -x {} \; -print

# Validate settings.json
jq . .claude/settings.json

# Validate GitHub Actions workflow
# (push to a branch and check the Actions tab)

# Test a command
# In Claude Code, type /vdd or /sdd to verify commands are available
```
