# Codex adapter

Read `.workflow/vendor/WORKFLOW.md` and the project's contributor guide. Use the repository's `AGENTS.md` entrypoint and `.agents/skills` discovery. Open referenced instructions with the available file-reading tool; do not assume an `@import` loads them.

Use the tools exposed by the current Codex session. Native subagents can provide independent review when the session exposes them and project instructions authorize delegation. If they are unavailable, use a separate review session or human review and mark the PR draft until review completes. Claude tool names such as `Task` or `AskUserQuestion` are not Codex APIs.

Run project commands through the available terminal tool. Codex Desktop does not require a separate Codex CLI installation for this workflow. Claude's `.claude/settings.json` hooks do not execute in Codex. Git hooks and project verification commands provide the shared checks; CI supplies the remote evidence. Do not claim hook parity with Claude.
