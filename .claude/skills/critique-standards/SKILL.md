---
name: critique-standards
description: Severity classification standards for code critique. Use when evaluating code quality or architecture issues to ensure consistent severity ratings across all review agents.
---

# Critique Severity Standards

When rating issues found during code review or architecture critique, use these severity levels consistently. All review agents (architecture-critic, code-quality-enforcer, orchestrate-review-deploy reviewers) MUST reference these definitions.

## Critical

Issues that **must** be fixed before merge. The code is broken or dangerous.

- **Bugs**: Code that will fail at runtime, incorrect logic, race conditions
- **Security**: Injection vulnerabilities, credential exposure, auth bypasses, OWASP Top 10
- **Data integrity**: Potential data loss, corruption, or inconsistency
- **Breaking changes**: Unintentional API breaks, removed functionality without migration

## Major

Issues that **should** be fixed. The code works but has significant problems that will cause pain.

- **Design flaws**: Tight coupling, wrong abstraction level, boundary violations
- **Error handling**: Missing error handling for likely failure cases, generic catches
- **Performance**: O(n^2) when O(n) is straightforward, N+1 queries, unnecessary blocking
- **Maintainability**: Complex logic without justification, magic numbers in business logic
- **Pattern violations**: Inconsistent with established codebase patterns without good reason

## Minor

Issues worth noting but **acceptable to defer**. The code is fine, could be better.

- **Style**: Naming that's not ideal but not confusing, minor formatting
- **Documentation**: Missing docstring on a complex function, outdated comment
- **Small improvements**: Could extract a helper, slightly verbose code
- **Test coverage**: Edge case not covered but happy path is solid

## Suggestion

**Optional** improvements. Opinions, preferences, nice-to-haves.

- **Alternatives**: Different approach that might be cleaner but current is fine
- **Future-proofing**: Could add extensibility not needed yet
- **Polish**: Micro-optimizations, stylistic preferences

## Rating Guidelines

1. **When in doubt, go lower**: If unsure between major and minor, pick minor
2. **Context matters**: A bug in logging is minor; the same pattern in payment/auth processing is critical
3. **One issue, one rating**: Don't inflate by counting the same issue multiple times
4. **Be specific**: Always include file:line and concrete description, not vague concerns
5. **Severity gates progression**: Only Critical and Major block merge/deployment. Minor and Suggestion are logged but do not block.

## Cross-Agent Consistency

All agents performing code review MUST use these severity definitions:
- **architecture-critic**: Architectural fit, coupling, breaking changes
- **code-quality-enforcer**: Code quality, test coverage, linting
- **orchestrate-review-deploy reviewers**: Final pre-merge review gate

The **spec-critic** agent uses its own severity calibration (documented in its agent file) because spec defects have different costs than code defects. However, the severity labels (Critical/Major/Minor/Suggestion) remain the same for consistent communication.
