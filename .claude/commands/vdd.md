Execute an approved plan in phases with iterative critique loops.

## Prerequisites

- An approved artifact is required — either a **plan** (from `/plan` or investigation) or a **spec** (from `/sdd`)
- The artifact path can be passed as an argument: `/vdd path/to/plan-or-spec.md`
- If no argument provided, ask the user for the artifact location
- VDD accepts both plans (with phase markers) and specs (with section markers). Phase Detection below handles both formats.

## Phase Detection

Parse the input file for explicitly marked phases or sections. Look for:

**Plan-style markers:**
- `## Phase 1`, `## Phase 2`, etc.
- `### Phase 1: Description`
- Requirements labeled `R1`, `R2`, etc.

**Spec-style markers** (from `/sdd` output):
- `## 1. Behavioral Contract`, `## 2. Interface Definition`, etc.
- Each top-level section becomes an implementation phase

If phases/sections are not clearly marked, ask the user to clarify boundaries before proceeding.

## State Tracking

Use TaskCreate/TaskUpdate to track phase execution:
- Create a task for each phase (e.g., "Phase 1: Database schema")
- Mark the current phase as `in_progress`
- Update with iteration count (e.g., "Phase 1: Database schema (iteration 2)")
- Mark phases as `completed` when they pass quality gates

## Structured Logging

**Phase boundaries:**
```
=== PHASE 1 START: {description} ===
=== PHASE 1 COMPLETE ({N} iterations) ===
```

**File tracking** (after each file is modified):
```
MODIFIED: src/models/user.py
CREATED: src/migrations/001_add_users.py
```

**Deferred issues:**
```
DEFERRED [minor]: src/models/user.py:45 - variable naming could be clearer
DEFERRED [suggestion]: src/api/endpoints.py:12 - consider adding caching
```

## Execution Flow

For each phase in order:

### Step 1: Execute Phase

Implement the work described in the current phase. Write the code, make the changes.

### Step 2: Critique Loop (max 3 iterations)

Launch TWO parallel agents using the Task tool (fresh instances each time):

**Agent 1: code-quality-enforcer**

Spawn using the Task tool with `subagent_type: "code-quality-enforcer"` if available, otherwise `subagent_type: "general-purpose"` with the prompt below. The agent file at `.claude/agents/code-quality-enforcer.md` is the source of truth for this agent's behavior.

```
You are the code-quality-enforcer performing a VDD critique. Reference the critique-standards skill for severity definitions.

Review the following files modified in Phase {current} of {total}:
- path/to/file1.py
- path/to/file2.py

Phase description: {phase_description}

YOUR TASKS:
1. Detect language and run appropriate linters on modified files:
   - Python: ruff check {files} && ruff format --check {files}
   - TypeScript: npx eslint {files} && npx tsc --noEmit
   (Skip if tooling unavailable)

2. Run targeted unit tests for modified code:
   - Python: python3 -m pytest {relevant_test_files} -v
   - TypeScript: npm test -- --run {relevant_test_files}

3. Analyze code for:
   - Bugs, logic errors, race conditions
   - Anti-patterns, placeholder TODOs without tracking refs
   - Error handling gaps (bare except, swallowed errors)
   - Type safety issues (Any types, missing annotations)
   - Inefficient patterns (N+1 queries, O(n^2))
   - Test quality: do assertions check meaningful behavior?

4. Run broader checks if module boundaries are crossed:
   - If modified files import from other modules, run type checks on those modules too
   - Check for broken imports/contracts in files that depend on modified code

Tests deferred for phases {current+1} through {total} are acceptable.
Tests deferred for phases 1 through {current} should now pass.

Provide severity ratings (critical/major/minor/suggestion) with file:line references.
```

**Agent 2: architecture-critic**

Spawn using the Task tool with `subagent_type: "architecture-critic"` if available, otherwise `subagent_type: "general-purpose"` with the prompt below. The agent file at `.claude/agents/architecture-critic.md` is the source of truth for this agent's behavior.

```
You are the architecture-critic performing a VDD critique. Reference the critique-standards skill for severity definitions.

Review the following files modified in Phase {current} of {total}:
- path/to/file1.py
- path/to/file2.py

Phase description: {phase_description}

YOUR TASKS:
1. Explore the broader codebase to understand existing patterns and conventions.
   Use Glob and Grep to find related code. Read existing implementations.

2. Evaluate how these changes fit architecturally:
   - Pattern consistency: Does this follow patterns elsewhere in the repo?
   - Coupling: Does code reach into internals of other modules?
   - Breaking changes: Do modified interfaces break callers?
   - Module boundaries: Is responsibility in the right place?
   - File size: Any file exceeding 500 lines?

3. Cite evidence from elsewhere in the codebase for every issue.
   "This pattern exists at X:42. This implementation diverges."

Provide severity ratings (critical/major/minor/suggestion) with file:line references.
```

### Step 3: Evaluate Feedback

Collect and consolidate issues from both agents, grouped by severity.

### Step 4: Decision

**If critical or major issues exist AND iteration < 3:**
- Log: `Phase X, iteration Y: Found N critical, M major issues. Addressing...`
- Fix the identified critical and major issues (minor/suggestions deferred)
- Return to Step 2 for re-critique with fresh agent instances

**If critical or major issues exist AND iteration >= 3:**
- Log: `Phase X: Still finding issues after 3 iterations. Stopping for human review.`
- Present all unresolved critical/major issues
- Ask the user: fix specific issues, skip them, or abort
- Wait for user input

**If NO critical or major issues:**
- Log: `Phase X complete. No critical/major issues found.`
- Proceed to next phase automatically

## Completion

```
VDD complete.

Phases: {X}
Total critique iterations: {Y}
Final status: All phases passed quality gates

Modified files:
- [list all created/modified files]

Summary of deferred minor/suggestion feedback:
- [list any minor issues noted but not addressed]

Next step: Run /orchestrate-review-deploy to perform final multi-agent review and deploy.
```

## Important

- Run critic agents in PARALLEL for efficiency
- Each critique loop uses FRESH agent instances (do not resume previous instances)
- Only address critical/major feedback during the loop; minor issues deferred
- Severity-gated: only Critical and Major block phase progression
- Escalation after 3 failed iterations -> human decides
- Track iteration count per phase to enforce the limit
- Be direct about problems found — no softening
