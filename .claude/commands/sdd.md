Produce a formal specification through adversarial critique.

## Prerequisites

- A plan should be approved (via `/orchestrate-investigation` or manual planning) before formalizing into a spec. `/sdd` takes the approved plan's requirements and produces a formal 5-section specification.
- The user must describe a feature and its intent — either as an argument (`/sdd "feature description"`) or through conversation
- Optionally, an existing spec can be passed for revision: `/sdd --revise path/to/spec.md`. When `--revise` is provided, skip Step 1. In Step 2, spawn the spec-builder with the existing spec file and instruction to preserve structure while reformatting to the canonical format if needed. Then proceed to Step 3.

## Spec Output Format

The specification is saved as a markdown file following the canonical structure. TDD parses this format mechanically — do not deviate from the section numbering.

```markdown
# Specification: {Feature Name}

## 1. Behavioral Contract
### 1.1 Preconditions
### 1.2 Postconditions
### 1.3 Invariants

## 2. Interface Definition
### 2.1 Input Types
### 2.2 Output Types
### 2.3 Error Types

## 3. Edge Case Catalog

## 4. Non-Functional Requirements
### 4.1 Performance Bounds
### 4.2 Memory Constraints
### 4.3 Security Requirements

## 5. Verification Strategy
### 5.1 Provable Properties
### 5.2 Testable Properties
### 5.3 Verification Constraints
```

Save the spec file as `spec-{feature-name}.md` in the current working directory unless the user specifies a different location.

## State Tracking

Use TaskCreate/TaskUpdate to track progress:
- Create a task for "SDD: {feature name}"
- Update with iteration count as the critique loop progresses
- Mark completed when the spec is approved

## Structured Logging

```
=== SDD START: {feature name} ===
=== SDD ITERATION {n}: Building spec ===
=== SDD CRITIQUE {n}: Running spec-critic ===
=== HUMAN REVIEW REQUESTED ===
=== SDD COMPLETE ({n} iterations) ===
```

## Execution Flow

### Step 1: Gather Intent

Interview the user to understand what they want to build. Probe for:
- What does it do? Describe the core behavior.
- Who or what calls it? What is the entry point?
- What exists already that this interacts with?
- What are the known constraints (performance, security, compatibility)?
- What does failure look like? What should never happen?

If the user provided a description as an argument, use it as a starting point but still ask clarifying questions if insufficient.

**Sufficiency gate**: Before proceeding to Step 2, confirm you have enough detail to fill Sections 1-3 of the spec (behavioral contract, interface definition, edge cases). If after two rounds of clarifying questions you still lack enough detail, tell the user what is missing.

### Step 2: Draft Spec

Launch the **spec-builder** agent using the Task tool. Set max_turns to 15.

Prompt template:
```
Produce a complete specification for the following feature.

Requirements:
{summarized requirements from Step 1}

Write the spec to: {spec-{feature-name}.md path}

Use the canonical spec format (Sections 1-5). Be exhaustive on edge cases and precise on types.
```

The spec-builder writes the spec file to disk. After it completes, verify the file exists and follows the canonical format.

### Step 3: Critique Loop (max 3 iterations)

**Capped at 3 iterations**, not 5. Per Linus review: "5 rounds is bikeshedding."

Maintain a running list of REVISED log entries across all iterations.

Launch the **spec-critic** agent using the Task tool (fresh instance each time). Set max_turns to 12.

For iteration 1:
```
Review the following specification:
- {path/to/spec-file.md}

This is the initial review in an SDD critique loop.

Read the spec file. Evaluate it for:
- Ambiguous language interpretable multiple ways
- Missing edge cases given the behavioral contract and types
- Unstated assumptions
- Contradictions between spec sections
- Properties claimed "testable only" that should be provable
- Verification tool mismatches

Provide severity ratings (critical/major/minor/suggestion) with section references.
```

For iterations 2+:
```
Review the following specification:
- {path/to/spec-file.md}

This is iteration {n} of 3 in an SDD critique loop. The following sections have been revised:
{accumulated REVISED log entries}

Review the full spec, paying attention to revised sections and whether revisions introduced new issues. Do not re-flag issues in unrevised sections unless newly relevant.

Provide severity ratings (critical/major/minor/suggestion) with section references.
```

### Step 4: Human Review Gate

After each critique, present findings and request human review:

```
=== HUMAN REVIEW REQUESTED ===

Spec-critic found: {N critical, M major, P minor, Q suggestions}

{summarized critic findings, grouped by severity}

Please review:
- Approve to continue
- Request specific changes
- Override specific critic findings (explain why)
```

Wait for user input before proceeding.

### Step 5: Decision

**If the user requests changes:**
- Launch a fresh **spec-builder** agent to revise the spec (max_turns 20):
  ```
  Revise the following specification:
  - {path/to/spec-file.md}

  Critic findings to address:
  {unresolved critical and major findings}

  User feedback to incorporate:
  {user's requested changes}

  Prior revision history:
  {accumulated REVISED log entries}

  Read the spec, apply the feedback, write revised spec to the same file.
  Log every change as REVISED: {section} -- {description}.
  ```
- If iteration < 3, return to Step 3 with a fresh critic instance
- If iteration >= 3, ask the user how to proceed

**If the user approves AND unresolved critical/major issues remain:**
- Present unresolved issues and confirm the user wants to accept with known gaps

**If the user approves AND no critical/major issues remain:**
- Log: `SDD complete. Spec approved.`

## Completion

```
SDD complete.

Spec: {path/to/spec-file.md}
Iterations: {N}
Final status: Approved / Accepted with caveats

Deferred minor/suggestion feedback:
- [list any minor issues not addressed]

Next step: Run /tdd {spec-file.md} --test-only to generate tests from this spec.
```

## Important

- TWO agents per iteration: spec-builder (drafts/revises) then spec-critic (reviews). Sequential.
- Each iteration uses FRESH agent instances (do not resume)
- Human reviews every iteration — specs require human judgment
- The spec format is the contract with /tdd and /vdd — do not deviate
- 3 iterations max, not 5
- Do not guess at user intent. If ambiguous, ask before drafting.
