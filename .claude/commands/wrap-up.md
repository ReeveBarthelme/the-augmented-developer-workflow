# Session Wrap-Up & Self-Improvement

Run the following phases in order. Be concise — focus on actionable findings, not summaries.

## Budgets (Hard Caps)

These limits are non-negotiable. Check BEFORE writing anything.

| Target | Hard Cap | At Cap |
|--------|----------|--------|
| `memory/MEMORY.md` | 180 lines | Extract sections to topic files first |
| `memory/*.md` topic files | 15 files max | Consolidate related topics |
| `CLAUDE.md` | Never write directly | All changes via Phase 3 + user approval |
| `.claude/commands/` | Never auto-create | Propose only, user creates |
| New memories per session | 3 max | Prioritize highest-value |
| New rules per session | 1 max | Only the most impactful |

## Phase 1: Ship It

1. Run `git status` at the repo root.
2. If uncommitted changes exist:
   - Analyze changes and draft a concise commit message.
   - **Wait for user confirmation** before committing. Never force-switch branches.
3. After commit, ask if the user wants to push.
4. Review any TODO items or tasks — mark completed ones done, flag orphans.

## Phase 2: Prune & Consolidate (BEFORE adding anything)

This phase runs BEFORE new content is added. The goal: make space, not add weight.

1. **Count lines**: `wc -l memory/MEMORY.md`. If over 180 lines:
   - Identify the 3 largest sections by line count
   - For sections >15 lines, extract to `memory/{topic}.md` and replace with a one-line index link
   - Remove entries older than 3 months that haven't been referenced in recent sessions
2. **Check topic file count**: `ls memory/*.md | wc -l`. If over 15:
   - Merge related topic files (e.g., multiple deploy-related files → one)
3. **Scan for staleness**: Flag any memory entry with a date >3 months old. Ask:
   - Is this still true? (code may have changed)
   - Is this already enforced by a hook/linter? (if so, the memory is redundant)
   - Has this been referenced in the last 5 sessions? (if not, candidate for archival)
4. **Check for contradictions**: Search existing memories and CLAUDE.md for rules that conflict with each other. Flag for user review.

**Report pruning actions**: "Pruned N lines from MEMORY.md, extracted M topic files, archived K stale entries."

If nothing to prune: "Memory is within budget. No pruning needed."

## Phase 3: Remember It

Review what was learned this session. **Do NOT duplicate what auto-memory already captured** — check existing entries first.

Route knowledge to the correct tier:

| Tier | When to Use | Location | Gate |
|------|------------|----------|------|
| **Auto Memory** | Debugging insights, project quirks | `memory/` (Write tool) | Max 3 new entries per session |
| **Handoff** | Session-spanning context, multi-step work | `.claude/handoff/YYYY-MM-DD-*.md` | For significant sessions only |

**CLAUDE.md and skills are OFF-LIMITS in this phase.** Those changes go through Phase 4's frequency gate.

Before writing:
1. Search `memory/MEMORY.md` and `memory/*.md` for existing entries on this topic
2. If found → UPDATE the existing entry (don't create a new one)
3. If MEMORY.md is over budget (180 lines) → you MUST complete Phase 2 pruning first
4. Include a date tag: `(Mar 2026)` on each new entry for staleness tracking

## Phase 4: Review & Apply (Self-Improvement Core)

Analyze the conversation for self-improvement signals. If the session was routine, say "Nothing to improve" and skip to Phase 5.

### 4a. Detect Friction

Scan the session for:
- **Corrections**: User said "no", "not that", "instead do..."
- **Retries**: Actions that failed and were re-attempted differently
- **Manual steps**: Things the user had to ask for that should have been automatic
- **Skill gaps**: Topics where you lacked knowledge or made wrong assumptions

### 4b. Check Frequency (3-Session Threshold)

For each friction point:
1. Search `memory/MEMORY.md`, `memory/*.md`, `CLAUDE.md`, and `.claude/handoff/*.md`
2. Has this exact pattern appeared in **3+ prior sessions** with evidence (dates)?
3. If NO → log as a memory entry only (counts toward 3-entry budget)
4. If YES → eligible for rule proposal in 4c

The delegation scorecard's trailing-10 trend is a pre-computed frequency signal: run `.claude/scripts/delegation-scorecard.sh` and check "Violating sessions." **>=3 violating sessions in the trailing 10** meets the threshold above and is eligible for a 4c rule proposal — propose arming tiering enforcement (`touch .claude/metrics/tiering-enforce`, run from the MAIN repo checkout, not a worktree — the path is relative to the main repo root, not your CWD; user approval required before touching it).

### 4c. Propose Rules (Gated)

**Only for patterns meeting the 3-session threshold AND with trend "stable" or "worsening".**
Patterns with trend "improving" are resolving naturally — do NOT enshrine them as rules.

Draft **conditional** rules (not global absolutes):

```
FRICTION: [what kept going wrong]
FREQUENCY: [N sessions, with dates/evidence]
TREND: [improving | worsening | stable]
CONTRADICTS: [any existing rule this conflicts with, or "none"]
PROPOSED RULE: [conditional rule text]
TARGET: [CLAUDE.md | memory/ | .claude/skills/]
```

**Max 1 rule proposal per session.** Pick the highest-impact one.
**Wait for user approval** before writing anything. Never auto-write to CLAUDE.md or skills.

### 4c-bis. Standing default: apply, don't ask

If your user has restated "do it if it makes sense and does not bloat" across
several sessions, that is a standing instruction, not a per-session decision.
Encode it this way:

| Target | Action |
|--------|--------|
| `memory/`, `.claude/handoff/` | **Apply without asking** if it passes the two tests below |
| `scripts/`, `.claude/hooks/`, `CLAUDE.md`, `.claude/skills/`, new rules | Still require explicit approval (unchanged) |

`scripts/` was in the auto-apply column in the first draft of this section and was
moved back: unattended writes to CI tooling are exactly the brittleness this repo
keeps getting bitten by, and the review that caught it was reviewing a PR fixing a CI
hook that had shipped two silent no-op bugs. Docs and memory are recoverable; a
quietly-edited gate is not. (Architecture review seat, a prior incident.)

Both tests must pass, or drop it silently rather than surfacing it:

1. **Net-token-saving** — name the specific waste it removes. A change justified only
   as "clearer" or "more complete" fails. Resident docs are read every turn of every
   future session, so added lines are a recurring cost, not a one-time one.
2. **In budget** — respect the Phase 2 caps. If it needs new lines, prune first.

Do not narrate skipped candidates. A dropped suggestion the user never sees is the
point; listing what you chose not to do reintroduces the cost you just avoided.

### 4d. Suggest Automation

Identify repetitive patterns that could become commands, hooks, or scripts.
Only suggest if the pattern occurred 3+ times this session or across sessions.
**Propose only — never auto-create.** User decides what to build.

## Phase 5: Report

| Action | Details |
|--------|---------|
| Commits | [branches, messages] |
| Pruned | [lines removed, files consolidated] |
| Memories | [new/updated, count vs budget] |
| Rules proposed | [count, targets, awaiting approval] |
| Automation suggested | [count, types] |
| Delegation | [run `.claude/scripts/delegation-scorecard.sh`, paste the scorecard summary] |
| Memory health | [MEMORY.md: N/180 lines, topic files: N/15] |
