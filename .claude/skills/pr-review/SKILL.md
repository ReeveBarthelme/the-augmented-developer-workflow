---
name: pr-review
description: Write accurate PR descriptions with multi-agent verification; use when creating or reviewing pull requests for merges
---

# PR Review with Verification

## Purpose

Create accurate, well-structured PR descriptions that tell the full story of changes. Prevents AI hallucinations by requiring code-level verification of all claims.

## When to Use

- Writing PR descriptions for large merges
- Reviewing PR descriptions for accuracy
- Multi-agent code review orchestration

## Critical Rules

### 1. VERIFY EVERY CLAIM

**Never make factual claims without citing code:**

```
BAD:  "Feature X is not implemented"
GOOD: "Feature X is implemented in src/config/auth.ts:68-75
       via signInWithProvider()"
```

For each claim, you MUST provide:
- File path
- Line numbers or function name
- Brief code snippet or description

### 2. CHECK THE FULL HISTORY

Large merges tell a story. Don't just look at recent commits:

```bash
# Check earliest commits (the beginning)
git log --oneline main..HEAD | tail -50

# Check timeline
git log --format="%as %s" main..HEAD | head -50

# Find feature commits across all time
git log --format="%as %s" main..HEAD | grep -iE "feat"
```

### 3. MULTI-AGENT VERIFICATION WORKFLOW

If using multiple agents:

**Phase 1: Gather (Agent 1)**
- Collect facts with file:line citations
- No claims without code evidence

**Phase 2: Verify (Agent 2)**
- Read cited files
- Confirm code matches claims
- Flag anything unverified

**Phase 3: Human Review**
- Present only verified claims
- Mark confidence levels
- Include "could not verify" disclaimers

### 4. NEVER TRUST CONSENSUS

Three agents agreeing does NOT mean they're correct. In practice:
- 3/3 agents can claim something is missing when it exists
- 3/3 agents can claim a technology is used when it isn't
- Human review catches what agents miss

## PR Description Structure

### For Large Merges (100+ commits)

```markdown
# [Title]: Brief Description

> **Stats**: X commits | Y files | Z lines | Timeline

## TL;DR (30 seconds)
- Bullet points of what this delivers
- Focus on outcomes, not implementation details

## The Journey (for long-lived branches)
### Phase 1: [Date Range]
- Key changes with context

### Phase 2: [Date Range]
- Evolution of the system

## Architecture
[ASCII diagram or description]

## Key Technical Achievements
- What's impressive (with evidence)

## Test Coverage
| Scope | Count | Status |
|-------|-------|--------|
| Backend | X files | Pass |
| Frontend | Y files | Pass |

## Deployment
- Commands
- Secrets configured
- Post-merge steps
```

### For Small PRs (<200 lines)

```markdown
## Summary
One paragraph explaining why and what.

## Changes
- Bullet list of specific changes

## Testing
How to verify this works.
```

## Common Mistakes to Avoid

| Mistake | Why It's Bad | Fix |
|---------|--------------|-----|
| Focusing only on recent commits | Misses the full story | Check `git log | tail` |
| Marketing language | Erodes trust | Facts only |
| Uncited claims | May be hallucinations | Always cite file:line |
| "Known Limitations" without verification | Often wrong | Verify each limitation exists |
| Trusting agent consensus | Agents amplify errors | Human must verify |

## Verification Commands

```bash
# Check if feature exists
grep -ri "searchterm" path/to/code

# Verify auth providers
grep -r "OAuth\|signIn" src/config/

# Check session storage
grep -r "session" services/ | grep -v test

# Count actual test files
find . -name "test_*.py" | wc -l
find . -name "*.test.ts" | wc -l

# Check commit timeline
git log --format="%as" main..HEAD | sort | uniq -c
```

## Sources

Best practices based on:
- [Microsoft Engineering Playbook](https://microsoft.github.io/code-with-engineering-playbook/code-reviews/pull-requests/)
- [arXiv: Multi-Agent Code Verification](https://arxiv.org/abs/2511.16708)

Research shows:
- RAG reduces hallucinations by 71%
- Multi-agent improves accuracy 39.7pp but doesn't guarantee correctness
- 76% of enterprises require human-in-the-loop
