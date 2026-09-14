---
name: orchestrate-review-deploy
description: Multi-agent review with two independent Claude subagents (architecture + security) and Codex to poke holes and vote on changes before commit and deploy. Use after implementation is complete.
allowed-tools:
  - Task
  - Bash
  - Read
  - Grep
  - Glob
  - AskUserQuestion
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

# 2. Confirm there are changes to review — check uncommitted (working tree +
#    staged) AND committed-on-branch diffs. Checking only the first two blocked
#    reviewing a branch that's already committed with a clean working tree
#    (e.g. this very workflow: implement -> commit -> THEN review).
CHANGES=$(git diff --stat HEAD)
STAGED=$(git diff --cached --stat)
BRANCH_DIFF=$(git diff --stat main...HEAD)
if [ -z "$CHANGES" ] && [ -z "$STAGED" ] && [ -z "$BRANCH_DIFF" ]; then
  echo "ERROR: No changes to review. Nothing in working directory, staging area, or committed on this branch vs main."
  echo "Aborting review — commit your changes or check the branch."
  exit 1
fi
if [ -n "$CHANGES" ] || [ -n "$STAGED" ]; then
  echo "Diff scope: uncommitted changes — review with 'git diff HEAD' / 'git diff --cached'"
  echo "$CHANGES"
  echo "$STAGED"
  if [ -n "$BRANCH_DIFF" ]; then
    echo ""
    echo "MIXED STATE: this branch ALSO has committed changes vs main — reviewers must cover BOTH scopes ('git diff HEAD' for uncommitted AND 'git diff main...HEAD' for committed), not just the uncommitted diff above."
    echo "$BRANCH_DIFF"
  fi
else
  echo "Diff scope: working tree is clean; reviewing committed changes on this branch — use 'git diff main...HEAD'"
  echo "$BRANCH_DIFF"
fi

# 3. Verify tests pass before review
echo "Running targeted tests for changed files..."
```

Run targeted tests for changed modules BEFORE spawning review agents. If tests fail, fix first — don't waste agent time reviewing broken code.

**Local Dev Verification gate (per CLAUDE.md — this is the layer that gets skipped):** for any change with a runtime surface, ALSO complete the API smoke (`curl` affected endpoints with a dev auth token) and a browser QA pass against local dev BEFORE spawning review agents. If local dev can't run, record that explicitly in the review artifact as a verification gap — never silently skip.

```bash
# 4. Fixture-masked-green gate — a passing suite is not enough; prove the
#    PRODUCTION change (not a test/fixture edit) caused the green. This is the
#    the fixture-masked-green failure mode (Fail-first rule).
case "${SKIP_FIXTURE_CHECK:-}" in
  1|true|TRUE|True|yes|YES|Yes)
    echo "Phase 0: SKIP_FIXTURE_CHECK set — skipping fixture-masked-green gate (reason required)" ;;
  *)
    echo "Phase 0: running fixture-masked-green gate via /classify-failures..." ;;
esac
```

Unless `SKIP_FIXTURE_CHECK` is set, invoke the **`/classify-failures`** skill on
this branch's diff. If it reports `verdict: blocked` (any `fixture_masked`
test), **STOP the review** — the green is unearned. Fix by exercising the fix's
own branch with a test that is RED before the fix, or split the PR; do not spawn
review agents on a fixture-masked green.

**IMPORTANT — git diff scope**: Use `git diff HEAD` (not `git diff main...HEAD`) to review working directory changes against the last commit. Use `git diff main...HEAD` only when reviewing all commits on a feature branch. For uncommitted work, `main...HEAD` returns an empty diff.

## Phase 1: Spawn Review Agents (Parallel)

**CRITICAL — Use the correct tool for each agent:**
- **Agent 1 (Claude)**: Use the **Task** tool to spawn a Claude subagent
- **Agent 2 (Claude, security seat)**: Use the **Task** tool to spawn a second Claude subagent (demoted from Gemini 2026-07-16 — see Agent 2 below)
- **Agent 3 (Codex)**: Use the **Bash** tool to run `codex exec` via the `/codex` skill

**⚠️ EVERY seat prompt MUST state the DELIVERY MECHANISM, not just the output format.** A backgrounded Claude subagent's plain text does NOT reach the lead — it surfaces only as a contentless `idle_notification`, which reads exactly like a stalled or silent seat. Append this verbatim to each Task-spawned seat prompt:

> Deliver your verdict by calling the **SendMessage** tool with `to: "main"`, with the entire verdict in the message body. Your plain text output does NOT reach the lead. If you did no real analysis, send `"ABSTAIN — no analysis performed"` — that is a valid answer; silence is not.

Without that line, empty pings are the EXPECTED outcome, not a malfunction, and the lead burns 2-3 round-trips chasing verdicts that were never deliverable. Seen across 5 separate sessions, each costing 3 ping rounds before the mechanism was stated; both seats then reported in full within ~2 min. The standing "idle pings ≠ done" and "0-byte seat = ABSENT" memories describe the SYMPTOM; this is the cause. Codex seats have the analogous failure via argv-vs-stdin — always `cat prompt.txt | codex exec`.

Do NOT spawn Agent 1 and Agent 2 as the same call — they run independent focus areas (architecture vs. security) and both must produce their own PROOF/vote. The whole point of multi-model review is diverse perspectives; with Gemini demoted to web-search-only, that diversity now comes from Claude vs. Codex rather than a third model family. Note: the security seat is now single-vendor on the OWASP axis (Claude reviewing Claude-adjacent code, not a genuinely independent model family) — the compensating controls are the mandatory PROOF-quote requirement, the hollow-approve guard, the manual `/security-review` escape hatch, and the N=5 oracle validation (recall 1.0/1.0) that justified the swap.

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

### Agent 2: Claude Security & OWASP Review (primary security seat)

**Why Claude and not Gemini here**: Gemini is a metered API; Claude and Codex seats are subscription-covered. This Claude subagent, previously the quota-exhausted fallback, is the primary and default security seat. The swap was validated before it shipped: N=5 Claude (Opus) runs against a fixed oracle fixture with two planted bugs scored recall 1.0 on both.

Spawn with the **Task** tool, `subagent_type: "general-purpose"`, `model: opus` — pin explicitly, since the N=5 recall-1.0 validation evidence was measured against Opus specifically and a cheaper model swap here would be unvalidated.

```
You are performing a security-focused pre-merge review. Reference critique-standards for severity definitions.

Run: git diff HEAD --name-only (for uncommitted changes) OR git diff main...HEAD --name-only (for feature branch commits)
Then read each changed file.

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
PROOF: quote the exact changed hunk you read (verbatim from the diff, with file path). A vote with no file path/symbol/hunk quoted here is void — treat it as an empty seat, not an approval.
Vote: APPROVE / REQUEST_CHANGES

Issues (if any):
- [CRITICAL/MAJOR/MINOR/SUGGESTION] file:line — description
  OWASP category: A01-A10
  Mitigation: specific fix recommendation

If APPROVE: 'APPROVE. No security issues found. OWASP compliance verified.'
```

**Hollow-approve guard**: a vote is only valid if the PROOF line above is present and quotes an actual changed hunk (verbatim, with file path). An APPROVE with an absent, generic, or unquoted PROOF line is void — treat it exactly like an empty seat, not an approving one (added after a hollow APPROVE reached a merge decision).

**Alternatively**, the user can run `/security-review` manually to get an independent security review at any time — this is a Claude Code built-in skill (not defined in this repo's `.claude/skills/`), so don't go looking for its source here.

### Design-Vote Seat: Codex (not part of the default 3-agent flow)

The `design-vote` `REVIEWER_SEAT` tier (contentious/split design calls) was previously routed to Gemini pro-tier via `gemini-with-fallback.sh`. As of 2026-07-16 it runs on Codex instead, subscription-covered. Same 2-minute-default-timeout risk as Agent 3 below applies here — pass an explicit `timeout` (480000-600000) or background it, don't issue this as a bare foreground call:

```bash
codex exec --sandbox read-only --skip-git-repo-check --config model_reasoning_effort="high" -m gpt-5.6-terra 2>&1 <<'DESIGN_VOTE_PROMPT'
[design-question prompt: pose the contentious design decision, ask for a vote + rationale]
DESIGN_VOTE_PROMPT
```

`gpt-5.6-terra` is chosen for single-shot judgment calls — higher precision and roughly 2x cheaper quota burn than `sol` on short calls (CodeRabbit benchmark, Jul 2026). This was **not** validated via the recall oracle above — that oracle tests bug-finding, the wrong instrument for a judgment/vote seat.

On a split or contentious vote, escalate to `gpt-5.6-sol` for a tie-breaking pass.

### Agent 3: Codex Edge Case & Performance Review

Run this via the **Bash** tool (NOT the Task tool). This calls the actual Codex CLI. Use heredoc to avoid bash injection.

**⚠️ Never issue this as a bare foreground Bash call.** A real edge-case review at high reasoning effort routinely takes 2-6 min; the Bash tool's default 120s timeout will SIGTERM it (exit 143, zero output — the review work is lost, not delayed) before it can print a verdict. This has hit every CLI reviewer used in this skill, three consecutive kills in one session before the fix was applied. On the FIRST attempt, either:
- Pass an explicit `timeout` of 480000-600000 (8-10 min) on the same foreground Bash call, or
- Launch with `&`, capture the PID, and poll (`while kill -0 $PID; do sleep 10; done`) or use `run_in_background: true`.

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
| Claude (Security) | ? | ? | ? | ? |
| Codex (Edge Cases) | ? | ? | ? | ? |

### Autonomous Fix Loop — Selective Re-Review (Max 3 Iterations)

**If ANY agent votes REQUEST_CHANGES with Critical or Major issues:**

1. **Track which agent(s)** voted REQUEST_CHANGES with Critical or Major issues
2. **Implement fixes** for all Critical and Major issues identified
3. **Run targeted tests** for the affected code to verify fixes don't break anything
4. **Selective re-review** (saves agent calls vs re-spawning all 3):
   - Re-run **only the flagging agent(s)** to verify the fix addresses their concerns
   - Run **Claude as cross-domain checker** on just the fix diff (one agent on a small diff catches side effects cheaply)
   - **Escalate to full 3-agent re-review** only if the fix diff touches multiple domains (e.g., both backend routes and frontend components)
5. **Collect new votes**

Example:
```
=== REVIEW ITERATION 1: 2 Critical, 1 Major from Claude (Security) ===
=== FIX: Addressed 2 Critical (IDOR in products.py, SQL injection in search) ===
=== REVIEW ITERATION 2: Re-running Claude (Security) (verify fix) + Claude (Architecture) (cross-domain check) ===
=== REVIEW ITERATION 2: Both approve → done (saved 1 Codex call) ===
```

Repeat up to 3 iterations. Track iteration count.

**If still REQUEST_CHANGES after 3 iterations:**
```
=== REVIEW ESCALATION: Still finding issues after 3 fix iterations ===
Unresolved issues:
- [list remaining Critical/Major issues]

Human review required. Options:
1. Fix specific issues manually
2. Accept with known limitations
3. Abort and redesign
```
Wait for user input.

**Minor and Suggestion issues** are logged but do NOT block. They are included in the commit message as "Known minor issues" if applicable.

## Phase 3: Decision Gate

### Write the review artifact (ALWAYS, before anything else in this phase)

`scripts/merge-pr.sh` refuses to merge without this file (review-skip shipped
4 times on documentation alone). Write it as soon as
votes are collected, whatever the verdict:

```bash
# If the PR already exists:  .claude/handoff/review-pr<N>-<YYYY-MM-DD>.md
# If the PR doesn't exist yet (normal flow — review runs before gh pr create):
#   .claude/handoff/review-<YYYY-MM-DD>-<branch-slug>.md
# The file MUST contain the exact head branch name on a line (the merge gate
# greps for it), e.g.:
#   Branch: fix/704-707-chat-quick-fixes
#   Verdict: unanimous approval after 2 iterations
#   Claude (architecture): APPROVE — <one-line summary>
#   Claude (security):     APPROVE — <one-line summary>
#   Codex (edge cases):    APPROVE — <one-line summary>
```

### If ALL APPROVE (Unanimous):

```bash
# 1. Stage specific files (NEVER git add -A)
git add [specific changed files]

# 2. Commit with review attribution
git commit -m "$(cat <<'EOF'
[type]: [description]

- [change 1]
- [change 2]

Reviewed-by: Claude (architecture), Claude (security), Codex (edge cases)
Review: unanimous approval, [N] iterations
EOF
)"
```

### Deploy (Optional)

**Default target is STAGING** unless the user explicitly says "production" or "prod."

```bash
# Customize: your staging deploy command here
# ./scripts/deploy-staging.sh

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
