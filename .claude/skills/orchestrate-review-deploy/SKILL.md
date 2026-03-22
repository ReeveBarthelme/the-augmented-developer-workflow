---
name: orchestrate-review-deploy
description: Multi-agent review with Gemini, Codex, and Claude to poke holes and vote on changes before commit and deploy. Use after implementation is complete.
allowed-tools:
  - Task
  - Bash
  - Read
  - Grep
  - Glob
---

# Multi-Agent Review & Deploy Orchestration

## Session Type Declaration

**This skill operates in Review/Deploy mode.** Do NOT implement new features or fix unrelated bugs. Focus exclusively on reviewing completed work, committing, and deploying.

## Phase 0: Pre-Review Verification

Before spawning review agents, verify the environment:

```bash
# 1. Confirm branch
BRANCH=$(git branch --show-current)
echo "Review branch: $BRANCH"
[ "$BRANCH" = "main" ] && echo "ERROR: Cannot review on main. Create a feature branch." && exit 1

# 2. Confirm there are changes to review
CHANGES=$(git diff --stat HEAD)
STAGED=$(git diff --cached --stat)
if [ -z "$CHANGES" ] && [ -z "$STAGED" ]; then
  echo "ERROR: No changes to review. Nothing in working directory or staging area."
  echo "Aborting review — commit your changes or check the branch."
  exit 1
fi
echo "$CHANGES"
echo "$STAGED"

# 3. Verify tests pass before review
echo "Running targeted tests for changed files..."
```

Run targeted tests for changed modules BEFORE spawning review agents. If tests fail, fix first — don't waste agent time reviewing broken code.

**IMPORTANT — git diff scope**: Use `git diff HEAD` (not `git diff main...HEAD`) to review working directory changes against the last commit. Use `git diff main...HEAD` only when reviewing all commits on a feature branch. For uncommitted work, `main...HEAD` returns an empty diff.

## Phase 1: Spawn Review Agents (Parallel)

**CRITICAL — Use the correct tool for each agent:**
- **Agent 1 (Claude)**: Use the **Task** tool to spawn a Claude subagent
- **Agent 2 (Gemini)**: Use the **Bash** tool to run the `gemini` CLI via the `/gemini-cli` skill
- **Agent 3 (Codex)**: Use the **Bash** tool to run `codex exec` via the `/codex` skill

Do NOT spawn all 3 via Task — that creates 3 Claude agents instead of using Gemini and Codex. The whole point of multi-model review is diverse perspectives from different model families.

### Agent 1: Claude Architecture Reviewer

Spawn with the **Task** tool, `subagent_type: "general-purpose"`. This reviewer uses the **architecture-critic** agent's focus areas.

```
You are performing a final pre-merge architecture review. Reference the critique-standards skill for severity definitions.

Review the following changes on branch: {BRANCH}

Run: git diff HEAD --name-only (for uncommitted changes) OR git diff main...HEAD --name-only (for feature branch commits)
Then read each changed file.

FOCUS AREAS (architecture-critic perspective):

1. **Pattern Consistency**: Do these changes follow patterns established elsewhere?
   - Route/controller → service → repository layering
   - Frontend component patterns (hooks, contexts, state management)
   - Naming conventions matching existing code
   EVIDENCE: Find 2+ existing examples of the same pattern and compare.

2. **Coupling and Dependencies**:
   - Does new code reach into internals of other modules?
   - Are dependencies flowing in the right direction?
   - Would this change force changes elsewhere?

3. **Breaking Changes**:
   - Modified function signatures, return types, or behaviors?
   - Existing callers that would break?
   - Migration path for consumers?

4. **Module Boundaries**:
   - Is responsibility in the right module?
   - Does code belong where it's placed?
   - Circular dependency violations?

5. **File Size Check**: Flag any file exceeding 500 lines.

6. **DRY Check**: Identify any logic duplicated across modules that should be shared.

OUTPUT FORMAT:
Vote: APPROVE / REQUEST_CHANGES / ABSTAIN

Issues (if any):
- [CRITICAL/MAJOR/MINOR/SUGGESTION] file:line — description
  Evidence: cite existing patterns from codebase

If APPROVE with no issues: "APPROVE. Code integrates well with existing architecture."
```

### Agent 2: Gemini Security & OWASP Review (fail-closed — no Flash fallback)

Run this via the **Bash** tool (NOT the Task tool). Uses **strict mode** — only tries pro-tier models. If all pro models are quota-exhausted, Gemini is skipped and a Claude security subagent is spawned instead (see fallback below).

```bash
# Source fallback wrapper: strict mode = auto (Pro) → fallback-pro → FAIL (no flash)
source .claude/scripts/gemini-with-fallback.sh

gemini_with_fallback_strict "You are performing a security-focused pre-merge review. Reference critique-standards for severity definitions.

Review the changes on the current branch. Read changed files directly using file paths from git status.

FOCUS AREAS (security-first perspective):

1. **OWASP Top 10 Compliance**:
   - A01 Broken Access Control: Are endpoints properly authenticated? Authorization checks?
   - A02 Cryptographic Failures: Secrets in code, weak hashing, exposed credentials?
   - A03 Injection: SQL injection, command injection, XSS in templates?
   - A04 Insecure Design: IDOR vulnerabilities? Missing rate limiting?
   - A05 Security Misconfiguration: Debug enabled, default credentials, verbose errors?
   - A06 Vulnerable Components: Known CVEs in dependencies?
   - A07 Auth Failures: Token handling, session management, auth bypass?
   - A08 Data Integrity: CSRF, unsigned data, integrity check failures?
   - A09 Logging Failures: Missing audit trail, secrets in logs?
   - A10 SSRF: User-controlled URLs, internal endpoint exposure?

2. **Data Validation**:
   - Input sanitization at API boundaries
   - Output encoding to prevent XSS
   - File upload validation (type, size, content)
   - SQL parameterization (no string formatting)

3. **Secrets and Configuration**:
   - No secrets in code or logs
   - Environment variables used for configuration
   - .env files not committed

OUTPUT FORMAT:
Vote: APPROVE / REQUEST_CHANGES

Issues (if any):
- [CRITICAL/MAJOR/MINOR/SUGGESTION] file:line — description
  OWASP category: A01-A10
  Mitigation: specific fix recommendation

If APPROVE: 'APPROVE. No security issues found. OWASP compliance verified.'" \
-o text
```

#### Gemini Unavailable Fallback: Claude Security Subagent

**If `gemini_with_fallback_strict` returns exit code 75** (all pro models quota-exhausted), skip Gemini and spawn a Claude security reviewer via the **Task** tool instead.

### Agent 3: Codex Edge Case & Performance Review

Run this via the **Bash** tool (NOT the Task tool). This calls the actual Codex CLI. Use heredoc to avoid bash injection:

```bash
cat <<'CODEX_PROMPT' | codex exec 2>&1
You are performing an edge case and performance pre-merge review. Reference critique-standards for severity definitions.

Review the changes on the current branch. Read changed files directly using file paths from git status.

FOCUS AREAS (code-quality-enforcer perspective):

1. **Edge Cases**:
   - Null/undefined/empty inputs at every function boundary
   - String comparison gotchas (endswith('') always True, case sensitivity)
   - Integer overflow, division by zero, off-by-one errors
   - Unicode handling in user-facing strings
   - Concurrent access to shared state

2. **Error Handling**:
   - Are all error paths handled? No bare except:
   - Do errors propagate correctly? No swallowed exceptions
   - Are error messages helpful for debugging?
   - Retry logic: are retries idempotent?

3. **Performance**:
   - N+1 database queries
   - Unbounded loops or recursion
   - Missing pagination on list endpoints
   - Large payload serialization
   - Missing indexes for new query patterns

4. **Test Coverage**:
   - Are new code paths tested?
   - Do tests cover error paths, not just happy path?
   - Are mocks realistic? (e.g., mock always returns success = useless)
   - Property-based tests for invariants?

5. **Backwards Compatibility**:
   - API response shape changes that break clients
   - Database schema changes without migration
   - Environment variable additions without documentation

OUTPUT FORMAT:
Vote: APPROVE / REQUEST_CHANGES

Issues (if any):
- [CRITICAL/MAJOR/MINOR/SUGGESTION] file:line — description
  Impact: what breaks if this is not fixed
  Fix: specific recommendation

If APPROVE: 'APPROVE. No edge case, performance, or compatibility issues found.'
CODEX_PROMPT
```

## Phase 2: Collect Votes & Autonomous Fix Loop

### Vote Collection

| Agent | Vote | Critical | Major | Minor |
|-------|------|----------|-------|-------|
| Claude (Architecture) | ? | ? | ? | ? |
| Gemini (Security) | ? | ? | ? | ? |
| Codex (Edge Cases) | ? | ? | ? | ? |

### Autonomous Fix Loop (Max 3 Iterations)

**If ANY agent votes REQUEST_CHANGES with Critical or Major issues:**

1. **Implement fixes** for all Critical and Major issues identified
2. **Run targeted tests** for the affected code to verify fixes don't break anything
3. **Re-spawn ALL 3 agents** — fixes can introduce new issues in domains other agents cover
4. **Collect new votes**

Repeat up to 3 iterations.

**If still REQUEST_CHANGES after 3 iterations**, escalate to user for human review.

**Minor and Suggestion issues** are logged but do NOT block.

## Phase 3: Decision Gate

### If ALL APPROVE (Unanimous):

```bash
# 1. Stage specific files (NEVER git add -A)
git add [specific changed files]

# 2. Commit with review attribution
git commit -m "$(cat <<'EOF'
[type]: [description]

- [change 1]
- [change 2]

Reviewed-by: Claude (architecture), [Gemini Pro or Claude fallback] (security), Codex (edge cases)
Review: unanimous approval, [N] iterations
EOF
)"
```

### Deploy (Optional)

**Default target is STAGING** unless the user explicitly says "production" or "prod."

```bash
# Customize: your staging deploy command here
# ./deploy_staging.sh

# PRODUCTION (only with explicit user instruction)
# Customize: your production deploy command here
```

**NEVER deploy to production without explicit user confirmation.** This is non-negotiable.

## Phase 4: Post-Deploy Verification

After deploy completes:
1. Wait for propagation (60s typical for containerized services)
2. Execute EXACT reproduction steps from the original task
3. Verify original symptom is resolved
4. Check for regressions
5. Monitor logs for errors

## Confidence Gate

**Would you bet $100 the deployment is successful?**

Only mark complete after verification passes. If verification fails, rollback or fix — do not leave broken staging.
