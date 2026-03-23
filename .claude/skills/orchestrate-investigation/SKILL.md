---
name: orchestrate-investigation
description: "Multi-agent investigation — the entry point for all non-trivial tasks. Spawns Gemini + Codex + Claude in parallel, performs Linus Torvalds review, requires $100 confidence bet. Use for ALL feature requests, bug fixes, refactors, or investigations."
allowed-tools:
  - Task
  - Bash
  - Read
  - Grep
  - Glob
  - AskUserQuestion
---

# Multi-Agent Investigation Orchestration

## Session Type Declaration

**This skill operates in Investigation mode.** Do NOT attempt code changes or deploys. Output is a plan document with findings, not implementation.

**This skill is the entry point for all non-trivial tasks.** It provides read-only exploration, plan output, and a user approval gate — plus the full multi-agent investigation pipeline. Do NOT use Claude Code's built-in plan mode (`/plan`) for tasks that need multi-agent investigation, as plan mode blocks the Bash and Task tools needed to spawn Gemini and Codex agents.

## Phase 0: Environment Verification (MANDATORY)

Before ANY investigation, verify the working environment.

```bash
# 1. Check current branch
BRANCH=$(git branch --show-current)
echo "Branch: $BRANCH"

# 2. Verify working directory
echo "Working directory: $(pwd)"

# 3. Verify NOT on main (investigations should be on feature branches or in plan mode)
if [ "$BRANCH" = "main" ]; then
  echo "WARNING: On main branch. Consider creating a feature branch or worktree before implementation."
fi

# 4. Confirm session type
echo "Session type: INVESTIGATION (read-only, no code changes)"
```

Report environment status before proceeding.

## Phase 1: Requirements Articulation

**Re-articulate the requirements in your own words.** Prove you understand the task — do not parrot back what the user said. For each requirement:

1. **Concrete requirements**: What specifically needs to happen? State each in your own words.
2. **Actions for each**: What must be done for each requirement?
3. **Implementation steps**: Sequential order with dependencies — re-organize into logical implementation order.
4. **Parallel vs Serial**: What can run in parallel? What must be serial? Be specific about which agents/tasks.
5. **Agent assignments**: Who does what based on strengths? (Claude Explore = architecture/patterns, Gemini via `/gemini-cli` skill = risks/security/web research, Codex via `/codex` skill = deep code analysis/edge cases)
6. **How you will complete this**: A short plain-text description of your approach — not just bullets, but a paragraph explaining your plan.
7. **TDD approach**: Test-first for each component
8. **DRY compliance**: Identify reusable patterns — 3+ identical blocks → extract
9. **Security requirements**: Production-grade, no workarounds, no hacky code
10. **Modularity**: <500 lines per file target, modular for continuous AI iterative development

### Contextual Epistemology

Before proceeding, explicitly state:
- **What you KNOW** (verified from code/docs)
- **What you ASSUME** (reasonable but unverified — flag for investigation)
- **What you DON'T KNOW** (gaps that agents must fill)

Do NOT proceed with assumptions as facts. If something is uncertain, assign an agent to verify it.

## Phase 2: Parallel Investigation (Spawn 3 Agents)

**CRITICAL — Use the correct tool for each agent:**
- **Agent 1 (Claude)**: Use the **Task** tool to spawn a Claude Explore subagent
- **Agent 2 (Gemini)**: Use the **Bash** tool to run the `gemini` CLI via the `/gemini-cli` skill
- **Agent 3 (Codex)**: Use the **Bash** tool to run `codex exec` via the `/codex` skill

Do NOT spawn all 3 via Task — that creates 3 Claude agents. The whole point is diverse perspectives from different model families.

### Agent 1: Claude Explore (Architecture & Patterns)

Spawn using the **Task** tool with `subagent_type: "Explore"`:

```
Investigate the following task: {TASK_DESCRIPTION}

Your focus is ARCHITECTURE and EXISTING PATTERNS:

1. **Existing implementations**: Find code that already solves similar problems.
   Search for related functions, services, and utilities. Cite specific file:line.

2. **Architectural patterns**: How does the existing codebase solve this class of problem?
   - Route/controller → service → repository patterns
   - Frontend component patterns (hooks, contexts, state management)
   - Shared utilities for cross-module concerns

3. **Integration points**: Where would new code connect to existing systems?
   - Which routes/endpoints are affected?
   - Which services need modification?
   - Which database tables are involved?

4. **Test patterns**: What testing approaches exist for similar features?
   - Find existing test files for the affected modules
   - Note fixtures, mocks, and test utilities available

5. **Schema verification** (if 3+ tables involved): Read actual migration files
   for every table the task will query. Report exact column names and types.

OUTPUT FORMAT:
- For each finding, cite specific file:line evidence
- Group findings by: Reusable Code | Patterns to Follow | Integration Points | Test Infrastructure
- Flag any concerns as: RISK (potential problem) or QUESTION (needs clarification)
- Rate overall complexity: Simple | Medium | Complex | Requires Decomposition
```

### Agent 2: Gemini (Analysis & Web Research)

Run this via the **Bash** tool (NOT the Task tool). This calls the actual Gemini CLI with automatic model fallback:

```bash
# Source fallback wrapper
source .claude/scripts/gemini-with-fallback.sh

# SECURITY: Write prompt to temp file to prevent bash expansion of task description
cat <<'GEMINI_PROMPT' > /tmp/gemini-investigation-prompt.txt
Investigate the following task: {TASK_DESCRIPTION}

Your focus is RISK ANALYSIS and CURRENT BEST PRACTICES:

1. **Risk assessment**: What could go wrong with this implementation?
   - Security risks (OWASP Top 10, injection, auth bypass, IDOR)
   - Data integrity risks (race conditions, partial updates)
   - Performance risks (N+1 queries, unbounded loops, large payloads)
   - Deployment risks (migration safety, env var changes, breaking changes)

2. **Best practices**: What do current best practices recommend?
   - Use Google Search for latest approaches in the relevant technology
   - Compare against established patterns in similar frameworks

3. **Security deep-dive**:
   - Authentication/authorization requirements
   - Input validation and sanitization needs
   - Data exposure risks in API responses
   # Customize: add your platform-specific security considerations here

4. **Edge cases**: What edge cases should tests cover?
   - Boundary conditions for all input types
   - Concurrent access scenarios
   - Network failure / timeout handling
   - Malformed input handling

OUTPUT FORMAT:
- Group findings by: Security | Performance | Edge Cases | Best Practices
- Rate each risk: Critical / Major / Minor (use critique-standards definitions)
- Provide specific mitigation for each identified risk
- Cite sources for best practice recommendations
GEMINI_PROMPT

gemini_with_fallback "$(cat /tmp/gemini-investigation-prompt.txt)" -o text
```

**SECURITY NOTE**: The prompt is written to a temp file using a single-quoted heredoc to prevent bash expansion of `{TASK_DESCRIPTION}`. When constructing the actual prompt, replace `{TASK_DESCRIPTION}` in the temp file before passing to gemini. For untrusted descriptions, always use this file-based approach rather than inline string substitution.

### Agent 3: Codex (Deep Code Analysis)

Run this via the **Bash** tool (NOT the Task tool). This calls the actual Codex CLI:

```bash
# Use codex skill — runs the REAL Codex/GPT model, not a Claude subagent
# SECURITY: Use heredoc with single-quoted delimiter to prevent bash expansion
cat <<'CODEX_PROMPT' | codex exec 2>/dev/null
Investigate the following task: {TASK_DESCRIPTION}

Your focus is DEEP CODE ANALYSIS and IMPLEMENTATION APPROACH:

1. **Code path analysis**: Trace the execution path for the affected features.
   - Entry points (routes, event handlers, CLI commands)
   - Data flow through the system
   - State mutations and side effects

2. **Bug and edge case identification**:
   - Identify potential bugs in existing code that could affect this task
   - Find edge cases not covered by existing tests
   - Check for type mismatches, null handling gaps, string comparison gotchas

3. **Performance implications**:
   - Database query efficiency (explain plans if needed)
   - Memory usage for large datasets
   - API response payload sizes
   - Caching opportunities

4. **Implementation approach**:
   - Propose a specific implementation approach with rationale
   - Identify files that need modification (with line ranges)
   - Estimate number of lines changed per file
   - Flag any files approaching the 500-line limit

OUTPUT FORMAT:
- For each finding, cite specific file:line evidence
- Group by: Code Paths | Potential Bugs | Performance | Implementation Plan
- Rate confidence: High / Medium / Low for each recommendation
- Explicitly flag any assumptions that need verification
CODEX_PROMPT
```

## Phase 3: Synthesis & Voting

After all agents complete:

1. **Collect all findings** into a single structured report:
   | Category | Claude | Gemini | Codex | Consensus? |
   |----------|--------|--------|-------|------------|
   | Risk 1 | ... | ... | ... | Yes/No |
   | Approach | ... | ... | ... | Yes/No |

2. **Identify agreements** (consensus points — all 3 agree)
3. **Document disagreements** (dissenting opinions with evidence)
4. **Vote on approach**: Each agent's recommendation
5. **Resolve conflicts**: Present tradeoffs, do NOT paper over disagreements

## Phase 4: Linus Torvalds Review

Review combined findings as Linus would:
- **No workarounds**: Reject hacky solutions. "If it needs a workaround, the design is wrong."
- **Simplicity**: Is this the simplest approach that works? Over-engineering is a bug.
- **Performance**: Will this scale? N+1 queries, unbounded loops, O(n^2) — all rejected.
- **Security**: Production-ready or amateur hour? IDOR, injection, auth bypass — all deal-breakers.
- **Maintainability**: Will future devs understand this without a PhD in the codebase?
- **Address complaints**: Fix issues Linus would reject. Be specific about what to change.

## Phase 5: Task List & Plan

Generate complete task list:
1. Logical & sequential order
2. Dependencies marked (which tasks block which)
3. TDD tasks (test before implementation)
4. Security review tasks
5. Verification tasks
6. File-level impact list (which files change, estimated line counts)

## VDD Pipeline Cross-Reference

After plan approval, consider the appropriate workflow based on task size:

| Task Size | Recommended Workflow |
|-----------|---------------------|
| **Significant feature** | `/sdd` (formal spec) -> `/tdd --test-only` (tests) -> `/vdd` (implement) -> `/orchestrate-review-deploy` |
| **Medium feature** | `/vdd` (implement with critics) -> `/orchestrate-review-deploy` |
| **Small fix** | Implement directly -> `/orchestrate-review-deploy` |

Include a workflow recommendation in the plan output.

## Confidence Gate

**Answer: Would you bet $100 on this approach?**

If not at 100% confidence:
- Continue pre-research
- Spawn additional investigation agents
- Ask user clarifying questions

Do NOT proceed until confidence is 100%.

## Wait for Confirmation

Present the plan and task list, then WAIT for user confirmation before any implementation.
