---
name: pr-bot
description: Trigger multi-agent PR review (Claude + Gemini + Codex)
user_invocable: true
---

# Multi-Agent PR Review Bot

Run the multi-agent review pipeline against a pull request. The same script
powers the automatic GitHub Action (`pr-review-bot.yml`) and this manual trigger.

## Usage

```bash
scripts/pr-review-bot.sh <PR_NUMBER>
```

If no PR number is provided by the user, detect it from the current branch:

```bash
PR_NUM=$(gh pr list --head "$(git branch --show-current)" --json number -q '.[0].number')
scripts/pr-review-bot.sh "$PR_NUM"
```

## What It Does

1. Fetches the PR diff and changed files
2. Runs three review agents in parallel:
   - **Claude** — architecture (patterns, coupling, boundaries, DRY, file size)
   - **Gemini** — security (OWASP Top 10, auth, secrets, injection)
   - **Codex** — edge cases (null handling, string gotchas, performance, tests)
3. Parses structured output from each agent
4. Posts a GitHub review with:
   - Summary table (agent votes + severity counts)
   - Inline comments on diff lines
   - `REQUEST_CHANGES` if any Critical or Major issues found

## After Running

Display the script output to the user. If the review was posted, provide the PR URL
so they can see the inline comments on GitHub.
