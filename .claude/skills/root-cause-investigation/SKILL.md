---
name: root-cause-investigation
description: Enforce structured root cause analysis before fixing bugs. Use when debugging errors, investigating failures, or diagnosing issues with unclear causes.
allowed-tools:
  - Task
  - Read
  - Grep
  - Glob
  - Bash
---

# Root Cause Investigation Protocol

## The $100 Bet Rule

**You cannot implement a fix until you can answer YES to:**
"Would you bet $100 that this is the actual root cause?"

## The 5-Whys + Reproduce Protocol

### Step 1: Capture Symptom (Required)
Document EXACT symptom:
- Error message verbatim
- User action that triggered it
- When it started (commit/deploy/time)

### Step 2: Reproduce First (Required)
BEFORE looking at code:
- Write minimal reproduction case
- Confirm you can trigger at will
- Document reproduction steps

**STOP if cannot reproduce. Do not guess at fixes.**

### Step 3: 5-Whys Chain (Required)

```
Symptom: [Exact error/behavior]
Why 1: [Proximate cause] →
Why 2: [Contributing cause] →
Why 3: [Root cause] →
Why 4: [Systemic issue] (optional) →
Why 5: [Process gap] (optional)
```

**Example:**
```
Symptom: API returns invalid JSON
Why 1: Response is truncated mid-field
Why 2: Stream interrupted before completion
Why 3: No handling of truncated streams
Why 4: Parser assumes complete JSON
ROOT: Missing stack-based JSON repair
```

### Step 4: Validate Hypothesis (Required)
Before fixing:
- Add logging at suspected location
- Trigger the issue
- Confirm logs match hypothesis
- If mismatch → return to Step 3

### Step 5: Document Before Fixing

```markdown
## Investigation: [Description]
**Symptom**: [Exact error]
**Reproduced**: Yes + steps
**5-Whys Chain**: [Documented]
**Root Cause Confirmed By**: [Evidence]
**$100 Bet**: Yes, would bet
**Proposed Fix**: [Brief description]
```

## Anti-Patterns (Auto-Reject)

| Pattern | Response |
|---------|----------|
| Fixing without reproducing | BLOCK |
| Single-level analysis | BLOCK: Ask "why" 3+ times |
| Schema fix without tracing data flow | WARN: Verify actual source |
| Suppressing errors with try/except | REJECT: Never hide symptoms |
