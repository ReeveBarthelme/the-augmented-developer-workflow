---
name: gemini-cli
description: Wield Google's Gemini CLI for web research and Google Search grounding (its current, non-demoted role). Use when a task needs current internet information, latest library/API versions, or other live web-grounded facts. Code generation, code review, security audits, test-generation, and codebase analysis of this repo's proprietary code were demoted 2026-07-16 to emergency-manual-only — use Claude or Codex for those instead. Also use when the user explicitly requests Gemini operations.
allowed-tools:
  - Bash
  - Read
  - Write
  - Grep
  - Glob
---

# Gemini CLI Integration Skill

This skill enables Claude Code to effectively orchestrate Gemini CLI for web research and Google Search grounding — its primary, current use case. Code-related uses (generation, review, analysis, test-gen) were demoted 2026-07-16 to emergency-manual-only; see the routing table immediately below.

## When to reach for Gemini vs Claude/Codex (READ FIRST — cost + data routing)

**Demoted 2026-07-16**: Gemini is now **web-search/grounding ONLY**. No code review, no design-vote, no diffs of proprietary code. Reviews (security and design-vote) run on Claude/Codex subscription seats instead — see `orchestrate-review-deploy` SKILL.md. Gemini's *unique* value remains **Google Search grounding** (current web info); it is a metered paid API, while Claude (this session) and Codex are subscription-covered and free at the margin. Route by task type:

| Task | Use | Why |
|------|-----|-----|
| **Web-grounded research** (current docs, "latest X", library API) | **Gemini** (`--yolo`, Google Search) | Only Gemini has live search grounding |
| **Independent security/review dissent** | Claude security subagent, then Codex `gpt-5.6-sol`/`gpt-5.6-terra` design-vote | Gemini no longer serves review seats (see demotion note above) |
| **Repo-aware code analysis / generation / refactor / test-gen** | **Claude or Codex, NOT Gemini** | No search benefit; free at margin; keeps proprietary code off a metered API |

**Do not send proprietary code to Gemini for plain analysis** — it has no search advantage there and it's the account that spends money. Routing, not model downgrades, is the biggest cost reduction available here. On one project it removed ~97% of a daily Gemini bill that was interactive code analysis with no search need.

## Model Selection

**Always pin an explicit model — never use `-m auto` or `-m latest`, and pin GA model IDs only.** ⚠️ "gemini-3-flash" (bare, no suffix) is NOT a real API model — the CLI silently serves its default `gemini-3.5-flash` instead (found 2026-07-10; it burned the free-tier bucket and voided an A/B). `-preview` models get retired ("gemini-3-pro-preview" died) and "gemini-3-flash-preview" failed the N=5 recall A/B 0/5 vs 3.5-flash's 3/5. Default to `gemini-3.1-flash-lite` for routine work; escalate to `gemini-3.5-flash` for hard reasoning and review seats.

| Seat / Use Case | Primary Model | Fallback |
|-----------------|---------------|---------|
| `security` gate (strict) — **demoted 2026-07-16, emergency manual use only** | `gemini-3.5-flash` | `gemini-3.1-flash-lite` → exit 75 |
| `design-vote` — **demoted 2026-07-16, emergency manual use only** | `gemini-3.5-flash` | `gemini-3.1-flash-lite` → exit 75 |
| `investigation` / advisory | `gemini-3.1-flash-lite` | `gemini-3.5-flash` → exit 75 |
| Direct CLI (ad-hoc) | `gemini-3.1-flash-lite` | escalate to `gemini-3.5-flash` explicitly only when needed |

The `security` and `design-vote` rows above are the pins still wired in `.claude/scripts/gemini-with-fallback.sh` for emergency manual invocation — the *default* review flow no longer calls them (security → Claude subagent, design-vote → Codex `gpt-5.6-terra`/`gpt-5.6-sol`; see `orchestrate-review-deploy` SKILL.md).

Select the seat via `REVIEWER_SEAT` env var. The wrapper reads this automatically.

**Exit-code contract** (wrapper scripts):

| Code | Meaning | Action |
|------|---------|--------|
| `0` | Success | — |
| `75` | Quota exhausted | Wait; will reset. Claude security-subagent fallback available. |
| `78` | **Billing failure** | Fix GCP billing at console.cloud.google.com/billing — do NOT retry |

**Spend log**: every wrapper invocation appends a JSON line to `~/.gemini/spend.jsonl` (override via `SPEND_LOG` env). View a summary:
```bash
bash .claude/scripts/gemini-with-fallback.sh summarize
bash .claude/scripts/gemini-with-fallback.sh summarize --days 7
```

**Env vars**:
- `REVIEWER_SEAT` — seat tier (`security` / `design-vote` / `investigation` / unset)
- `REVIEWER_RUN_ID` — run identifier for spend log (defaults to date-based string)

## When to Use This Skill

### Ideal Use Cases (current — web-search/grounding only)

1. **Google Search Grounding**
   - Questions requiring current internet information
   - Latest library versions, API changes, documentation updates
   - Current events or recent releases

### When NOT to Use

- Simple, quick tasks (overhead not worth it)
- Tasks requiring immediate response (rate limits cause delays)
- When context is already loaded and understood
- Interactive refinement requiring conversation
- Code review, security audits, code generation/refactor/test-gen, or architecture analysis of THIS repo's (proprietary) code — see "Demoted" below; use Claude or Codex instead

### Demoted 2026-07-16 (emergency manual use only)

These were formerly listed as "ideal use cases" for Gemini. They are demoted — proprietary code must not go to a metered external API by default. Only reach for these with explicit direction for emergency/manual fallback (see `.claude/scripts/gemini-with-fallback.sh` header, `orchestrate-review-deploy` SKILL.md):

1. **Second Opinion / Cross-Validation** — code review after writing code, security audit, finding bugs. Now: Claude security subagent is the primary security seat; `/security-review` is the manual escape hatch.
2. **Codebase Architecture Analysis** — Gemini's `codebase_investigator` tool on this repo's code. Now: Claude/Codex repo-aware analysis (via Task/Explore or `codex review`).
3. **Parallel Processing / code generation** — running multiple code generations simultaneously. Now: Claude/Codex.
4. **Specialized Generation** — test suite generation, JSDoc/documentation generation, code translation. Now: Claude/Codex.

## Core Instructions

### 1. Verify Installation & Authentication

```bash
# Check installation
command -v gemini || which gemini

# Load GEMINI_API_KEY from .env ONLY if not already set in the shell —
# a personal/local key exported in ~/.zshrc must win over the project's
# .env key (the billed app key your application code uses).
# Do NOT change this to an unconditional source — plain `source .env` overwrites
# an already-exported var and silently reverts the CLI to the GCP-billed key.
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi

# Verify API key is available
[ -n "$GEMINI_API_KEY" ] && echo "✅ GEMINI_API_KEY loaded" || echo "❌ GEMINI_API_KEY missing"
```

**IMPORTANT**: The Gemini CLI requires `GEMINI_API_KEY` environment variable. If not already exported in your shell, this project falls back to the value in `.env`. Never source `.env` unconditionally — see the guard above.

### 2. Basic Command Pattern

```bash
gemini "[prompt]" --yolo -o text 2>&1
```

Key flags:
- `--yolo` or `-y`: Auto-approve all tool calls
- `-o text`: Human-readable output
- `-o json`: Structured output with stats
- `-m gemini-2.5-flash`: Use faster model for simple tasks

### 3. Critical Behavioral Notes

**YOLO Mode Behavior**: Auto-approves tool calls but does NOT prevent planning prompts. Gemini may still present plans and ask "Does this plan look good?" Use forceful language:
- "Apply now"
- "Start immediately"
- "Do this without asking for confirmation"

**Rate Limits**: Free tier has 60 requests/min, 1000/day. CLI auto-retries with backoff. Expect messages like "quota will reset after Xs".

### 4. Output Processing

For JSON output (`-o json`), parse:
```json
{
  "response": "actual content",
  "stats": {
    "models": { "tokens": {...} },
    "tools": { "byName": {...} }
  }
}
```

## Quick Reference Commands

**⚠️ CRITICAL**: Prefix Gemini commands with the guarded `.env` fallback below (loads `GEMINI_API_KEY` only if the shell doesn't already have one — an ambient key, e.g. from `~/.zshrc`, must win over the project's GCP-billed `.env` key):

```bash
# Standard prefix for ALL gemini commands
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi && gemini [...]
```

### Web Research (primary use case)
```bash
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi && gemini "What are the latest [topic]? Use Google Search." -m gemini-3.1-flash-lite -o text
```

### Lighter Model (High-volume / simple tasks)
```bash
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi && gemini "[prompt]" -m gemini-3.1-flash-lite -o text
```

### Demoted 2026-07-16 (emergency manual use only — do not use these against this repo's proprietary code by default)

The recipes below predate the demotion. Reach for Claude/Codex instead (see routing table above); keep these only for a deliberate, explicitly-directed manual fallback.

#### Code Generation
```bash
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Create [description] with [features]. Output complete file content." -m gemini-3.1-flash-lite --yolo -o text
```

#### Code Review
```bash
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Review [file] for: 1) features, 2) bugs/security issues, 3) improvements" -m gemini-3.1-flash-lite -o text
```

#### Bug Fixing
```bash
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Fix these bugs in [file]: [list]. Apply fixes now." -m gemini-3.1-flash-lite --yolo -o text
```

#### Test Generation
```bash
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Generate [Jest/pytest] tests for [file]. Focus on [areas]." -m gemini-3.1-flash-lite --yolo -o text
```

#### Documentation
```bash
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Generate JSDoc for all functions in [file]. Output as markdown." -m gemini-3.1-flash-lite --yolo -o text
```

#### Architecture Analysis (codebase_investigator on proprietary code)
```bash
if [ -z "${GEMINI_API_KEY:-}" ] && [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Use codebase_investigator to analyze this project" -m gemini-3.1-flash-lite -o text
```

## Error Handling

### Rate Limit / Daily Quota Exceeded
- CLI auto-retries with backoff for per-minute rate limits
- For **daily quota exhaustion**, use the fallback wrapper:
  ```bash
  source .claude/scripts/gemini-with-fallback.sh
  gemini_with_fallback "Your prompt" -o text
  ```
  Seat-tiered chains (set `REVIEWER_SEAT` before sourcing):
  - `security` / `design-vote`: `gemini-3.5-flash` → `gemini-3.1-flash-lite` → exit 75 — **demoted 2026-07-16, emergency manual use only; the default review flow calls Claude (security) / Codex (design-vote) instead, see `orchestrate-review-deploy` SKILL.md**
  - `investigation`: `gemini-3.1-flash-lite` → `gemini-3.5-flash` → exit 75
  Override individual models: `GEMINI_PRIMARY_MODEL`, `GEMINI_FALLBACK_MODEL`, `GEMINI_LAST_RESORT_MODEL`
- For **advisory/investigation** seats, prefer `reviewer-with-fallback.sh` — adds groq + ollama before Gemini:
  ```bash
  REVIEWER_SEAT=investigation .claude/scripts/reviewer-with-fallback.sh "Your prompt" -o text
  ```
- Use `-m gemini-3.1-flash-lite` directly for lower priority tasks (avoids burning Pro quota)
- Run in background for long operations

### Command Failures
- Check JSON output for detailed error stats
- Verify Gemini is authenticated: `gemini --version`
- Check `~/.gemini/settings.json` for config issues

### Validation After Generation
Always verify Gemini's output:
- Check for security vulnerabilities (XSS, injection)
- Test functionality matches requirements
- Review code style consistency
- Verify dependencies are appropriate

## Integration Workflow

### Standard Generate-Review-Fix Cycle

**Demoted 2026-07-16 (emergency manual use only)** — this cycle is a code-generation/self-review workflow, exactly the category routed to Claude/Codex now. Keep only for deliberate manual fallback.

```bash
# 1. Generate
gemini "Create [code]" --yolo -o text

# 2. Review (Gemini reviews its own work)
gemini "Review [file] for bugs and security issues" -o text

# 3. Fix identified issues
gemini "Fix [issues] in [file]. Apply now." --yolo -o text
```

### Background Execution

For long tasks, run in background and monitor:
```bash
gemini "[long task]" --yolo -o text 2>&1 &
# Monitor with BashOutput tool
```

## Gemini's Unique Capabilities

These tools are available only through Gemini:

1. **google_web_search** - Real-time internet search via Google (the current, non-demoted use case)
2. **codebase_investigator** - Deep architectural analysis — **demoted 2026-07-16**: do not point this at this repo's proprietary code by default; use Claude/Codex repo-aware analysis instead
3. **save_memory** - Cross-session persistent memory

## Configuration

### Project Context (Optional)

Create `.gemini/GEMINI.md` in project root for persistent context that Gemini will automatically read.

### Session Management

List sessions: `gemini --list-sessions`
Resume session: `echo "follow-up" | gemini -r [index] -o text`

## See Also

- `reference.md` - Complete command and flag reference
- `templates.md` - Prompt templates for common operations
- `patterns.md` - Advanced integration patterns
- `tools.md` - Gemini's built-in tools documentation
