---
name: gemini-cli
description: Wield Google's Gemini CLI as a powerful auxiliary tool for code generation, review, analysis, and web research. Use when tasks benefit from a second AI perspective, current web information via Google Search, codebase architecture analysis, or parallel code generation. Also use when user explicitly requests Gemini operations.
allowed-tools:
  - Bash
  - Read
  - Write
  - Grep
  - Glob
---

# Gemini CLI Integration Skill

This skill enables Claude Code to effectively orchestrate Gemini CLI with Gemini 3.1 Pro for code generation, review, analysis, and specialized tasks.

## Model Selection

| Model ID | Use Case | Notes |
|----------|----------|-------|
| `auto` | **Default** - Auto-routes to best available model (currently 3.1 Pro) | Recommended for most tasks |
| `gemini-3.1-pro-preview` | Explicit 3.1 Pro - Complex analysis, code review, documentation | Latest model (Feb 2026), extended thinking |
| `gemini-2.5-flash` | Simple tasks, high-volume operations | Faster, lower cost |

**Recommended**: Use `-m auto` for most tasks (routes to Gemini 3.1 Pro). Use `gemini-3.1-pro-preview` explicitly when you need to pin the model.

## When to Use This Skill

### Ideal Use Cases

1. **Second Opinion / Cross-Validation**
   - Code review after writing code (different AI perspective)
   - Security audit with alternative analysis
   - Finding bugs Claude might have missed

2. **Google Search Grounding**
   - Questions requiring current internet information
   - Latest library versions, API changes, documentation updates
   - Current events or recent releases

3. **Codebase Architecture Analysis**
   - Use Gemini's `codebase_investigator` tool
   - Understanding unfamiliar codebases
   - Mapping cross-file dependencies

4. **Parallel Processing**
   - Offload tasks while continuing other work
   - Run multiple code generations simultaneously
   - Background documentation generation

5. **Specialized Generation**
   - Test suite generation
   - JSDoc/documentation generation
   - Code translation between languages

### When NOT to Use

- Simple, quick tasks (overhead not worth it)
- Tasks requiring immediate response (rate limits cause delays)
- When context is already loaded and understood
- Interactive refinement requiring conversation

## Core Instructions

### 1. Verify Installation & Authentication

```bash
# Check installation
command -v gemini || which gemini

# CRITICAL: Source .env to load GEMINI_API_KEY
if [ -f .env ]; then set -a; source .env; set +a; fi

# Verify API key is available
[ -n "$GEMINI_API_KEY" ] && echo "✅ GEMINI_API_KEY loaded" || echo "❌ GEMINI_API_KEY missing"
```

**IMPORTANT**: The Gemini CLI requires `GEMINI_API_KEY` environment variable. This project stores it in `.env`. Always source `.env` before running Gemini commands.

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

**⚠️ CRITICAL**: Always prefix Gemini commands with `.env` sourcing to load `GEMINI_API_KEY`:

```bash
# Standard prefix for ALL gemini commands
if [ -f .env ]; then set -a; source .env; set +a; fi && gemini [...]
```

### Code Generation
```bash
if [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Create [description] with [features]. Output complete file content." -m auto --yolo -o text
```

### Code Review
```bash
if [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Review [file] for: 1) features, 2) bugs/security issues, 3) improvements" -m auto -o text
```

### Bug Fixing
```bash
if [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Fix these bugs in [file]: [list]. Apply fixes now." -m auto --yolo -o text
```

### Test Generation
```bash
if [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Generate [Jest/pytest] tests for [file]. Focus on [areas]." -m auto --yolo -o text
```

### Documentation
```bash
if [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Generate JSDoc for all functions in [file]. Output as markdown." -m auto --yolo -o text
```

### Architecture Analysis
```bash
if [ -f .env ]; then set -a; source .env; set +a; fi && gemini "Use codebase_investigator to analyze this project" -m auto -o text
```

### Web Research
```bash
if [ -f .env ]; then set -a; source .env; set +a; fi && gemini "What are the latest [topic]? Use Google Search." -m auto -o text
```

### Faster Model (Simple Tasks)
```bash
if [ -f .env ]; then set -a; source .env; set +a; fi && gemini "[prompt]" -m gemini-2.5-flash -o text
```

## Error Handling

### Rate Limit / Daily Quota Exceeded
- CLI auto-retries with backoff for per-minute rate limits
- For **daily quota exhaustion**, use the fallback wrapper:
  ```bash
  source .claude/scripts/gemini-with-fallback.sh
  gemini_with_fallback "Your prompt" -o text
  ```
  Fallback chain: `auto` (3.1 Pro) → `gemini-3-pro-preview` → `gemini-2.5-flash`
  Override via env vars: `GEMINI_PRIMARY_MODEL`, `GEMINI_FALLBACK_MODEL`, `GEMINI_LAST_RESORT_MODEL`
- Use `-m gemini-2.5-flash` directly for lower priority tasks (avoids burning Pro quota)
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

1. **google_web_search** - Real-time internet search via Google
2. **codebase_investigator** - Deep architectural analysis
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
