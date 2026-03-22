Generate a test suite from an approved specification, then optionally implement.

## Prerequisites

- An approved spec file is required — either from `/sdd` or manually written following the canonical spec format (Sections 1-5)
- Spec path passed as argument: `/tdd path/to/spec.md`
- If no argument provided, ask the user for the spec file location
- Optional flag: `--test-only` — generate tests and verify the Red Gate, then stop. Do not implement.
- Requires an approved spec from `/sdd` or manually written

## Mode Detection

- **Full mode** (default, standalone): Test generation -> Red Gate -> Minimal implementation -> Refactor -> Human checkpoint
- **Test-only mode** (`--test-only`): Test generation -> Red Gate -> Stop

## State Tracking

Use TaskCreate/TaskUpdate to track progress:
- Create a task for each step: "TDD: Validate spec", "TDD: Generate tests", "TDD: Red Gate", etc.
- Mark each as in_progress when starting, completed when done

## Structured Logging

```
=== TDD START: {spec name} ===
=== TDD STEP 1: Validating spec ===
=== TDD STEP 2: Generating test suite ===
=== TDD STEP 3: Red Gate ===
=== TDD RED GATE: PASS ({N} tests, all failing) ===
=== TDD RED GATE: FAIL ===
=== TDD STEP 4: Implementing ({N} tests remaining) ===
=== TDD GREEN: {test_name} now passing ({M}/{N} total) ===
=== TDD STEP 5: Refactoring ===
=== TDD STEP 6: Human checkpoint ===
=== TDD COMPLETE ===
```

## Execution Flow

### Step 1: Validate Spec

Read the spec file. Verify it follows the canonical format:
- Section 1: Behavioral Contract (1.1 Preconditions, 1.2 Postconditions, 1.3 Invariants)
- Section 2: Interface Definition (2.1 Input Types, 2.2 Output Types, 2.3 Error Types)
- Section 3: Edge Case Catalog (numbered entries)
- Section 4: Non-Functional Requirements
- Section 5: Verification Strategy

If the spec does not follow this format, ask the user whether to proceed anyway or abort.

### Step 2: Test Suite Generation

Parse the spec and generate tests mechanically. Every testable statement becomes a test.

**Mapping rules:**

| Spec Section | Test Type | Naming Convention |
|-------------|-----------|-------------------|
| 1.2 Postconditions | Unit tests | `test_postcondition_{description}` |
| 1.1 Precondition violations | Error-expecting tests | `test_precondition_violation_{error_type}` |
| 1.3 Invariants | Property-based tests | `test_invariant_{property}` |
| 3 Edge Cases | Dedicated edge case tests | `test_edge_case_{catalog_number}_{description}` |
| 2 Interface Definition | Integration tests | `test_integration_{interface}` |
| 4.1 Performance Bounds | Performance tests | `test_perf_{bound}` |
| 4.3 Security Requirements | Security tests | `test_security_{requirement}` |
| 5.2 Testable Properties | Property-based tests | `test_property_{name}` |

**Sections that do NOT produce tests:**
- Section 5.1 (Provable Properties) — enforced by types/static analysis
- Section 5.3 (Verification Constraints) — meta-requirements about tooling

Reference the **testing-strategy** skill for project conventions (testing pyramid, coverage requirements, fixture patterns).

**Exploratory bypass**: For UI/visual components where behavioral specs are impractical (e.g., "the button should look right"), mark as `@pytest.mark.skip(reason="Visual component - manual verification")` or equivalent. Document what needs manual inspection.

**Stub generation:**
- Create module/class/function files with correct names and signatures from Section 2
- Every function body raises `NotImplementedError` (Python) or `throw new Error("Not implemented")` (TS)
- Stubs must raise an error type NOT among Section 2.3 error types to prevent false passes
- Log: `STUB: {path} -- minimal stub for test compilation`

**Test file organization:**
- Follow existing project conventions
- Include spec reference comment: `# Generated from: {spec-file-path}`
- Group by spec section in dedicated test files

### Step 3: Red Gate

Run the full test suite. **ALL tests must fail.**

**If all tests fail:**
```
=== TDD RED GATE: PASS ({N} tests, all failing) ===
```
In test-only mode, skip to Completion. In full mode, proceed to Step 4.

**If any test passes:**
```
=== TDD RED GATE: FAIL ===
The following tests pass without implementation:
- {test_name} ({file}:{line})
```

Possible causes:
1. Tautological assertion — test passes regardless of implementation
2. Spec describes behavior that already exists
3. Test setup provides the expected result (mock always returns success)

Wait for user input. The user may fix the test, acknowledge existing behavior, or adjust the spec.

**Partial implementation handling:** If user confirms some tests pass because behavior exists, mark as "pre-green." In full mode, implement only remaining failing tests. In test-only mode, log the pre-green tests and proceed to completion:

```
=== TDD RED GATE: PARTIAL PASS ({N} total, {M} pre-green, {K} failing) ===
Pre-green tests (existing behavior): [list]
Failing tests (new behavior): [list]
```

### Step 4: Minimal Implementation (full mode only)

Classic TDD — one test at a time. Process in this order:

1. Postconditions (Section 1.2)
2. Precondition violations (Section 1.1)
3. Invariants (Section 1.3)
4. Edge cases (Section 3)
5. Integration (Section 2)
6. Performance (Section 4.1) — after all functional tests pass
7. Security (Section 4.3)
8. Testable properties (Section 5.2)

For each failing test:
1. Run the full test suite. Identify the next failing test in order.
2. Write the **minimum** code to make that one test pass. No extra abstractions, no future-proofing.
3. Run the full test suite again. Target test should pass. No regressions.
4. Log: `=== TDD GREEN: {test_name} now passing ({M}/{N} total) ===`
5. Repeat.

### Step 5: Refactor (full mode only)

All tests pass. Now refactor:
- Extract duplicated code
- Improve variable and function names
- Optimize for performance bounds in Section 4.1
- Ensure code follows existing project patterns

**After each refactoring change**, run the full test suite. If any test fails, revert.

Run coverage if tooling is available:
```bash
# Python
python3 -m pytest --cov=module_name -v

# TypeScript
npm test -- --run --coverage
```

### Step 6: Human Checkpoint (full mode only)

```
=== TDD STEP 6: Human checkpoint ===

Test suite: {path/to/tests}
Implementation: {list of created/modified files}
Tests: {N} passing, 0 failing
Coverage: {X}%

Spec: {path/to/spec}

Please review for alignment with the spirit of the spec.
AI can miss intent even when it nails the letter of the contract.
```

Wait for user input.

## Completion

**Full mode:**
```
TDD complete.

Spec: {path/to/spec}
Test suite: {path/to/tests}
Implementation: {list of files}
Tests: {N} passing
Coverage: {X}%

Next step: Run /orchestrate-review-deploy to review and deploy (implementation already done in full mode).
```

**Test-only mode:**
```
TDD test-only complete.

Spec: {path/to/spec}
Test suite: {path/to/tests}
Tests: {N} total, {K} failing, {M} pre-green (Red Gate passed)

Ready for implementation. Run /vdd {spec-or-plan-file} to implement with adversarial critique.
```

## Important

- Parse the spec mechanically — every postcondition, edge case, invariant becomes a test
- Empty/absent spec sections are skipped — no placeholder tests
- Red Gate is mandatory. No implementation begins until all tests fail.
- In test-only mode, stop after Red Gate
- In full mode, implement ONE test at a time (strict red-green-refactor)
- The test suite is the source of truth during implementation
- Do not guess at test behavior when spec is ambiguous — flag for human review
