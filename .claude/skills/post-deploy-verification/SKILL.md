---
name: post-deploy-verification
description: Verify original symptoms are resolved after deployment. Use after deploying fixes or completing bug fixes.
allowed-tools:
  - Bash
  - Read
  - WebFetch
---

# Post-Deploy Verification Protocol

## The Rule

**Passing deployment gates does NOT mean the bug is fixed.**
You must verify the ORIGINAL SYMPTOM is gone.

## Pre-Deploy: Document Expected Outcome

Before deploying:
1. **Original Symptom**: What was broken?
2. **Reproduction Steps**: How to trigger?
3. **Expected Post-Fix Behavior**: What should happen?
4. **Verification Method**: How to confirm?

## Post-Deploy: Execute Verification

After deploy completes:
1. Wait for propagation (60s typical for containerized services)
2. Run EXACT reproduction steps from investigation
3. Confirm symptom is gone (positive test)
4. Check for regressions
5. Monitor logs for 5 minutes

## Verification Checklist

```markdown
## Verification: [Fix Description]
- [ ] Deployment completed: [revision]
- [ ] Waited for propagation
- [ ] Reproduction steps executed
- [ ] Symptom no longer occurs: [evidence]
- [ ] Expected behavior confirmed: [evidence]
- [ ] No regressions observed
- [ ] Logs clean for 5 minutes
- [ ] User confirmed (if applicable)
```

## Verification by Issue Type

### API/Backend
```bash
# 1. Call failing endpoint
curl -X POST https://[service]/api/[endpoint]

# 2. Check logs for errors
# Customize: your log query command here

# 3. Verify response data
```

### Frontend
1. Open page where issue occurred
2. Perform triggering action
3. Verify correct behavior
4. Check browser console

### Data/Schema
```sql
SELECT [columns] FROM [table] WHERE [condition];
-- Verify data format correct
```

## The $100 Bet

**Would you bet $100 this bug is actually fixed?**

Only mark complete after verification passes AND you'd bet $100.
