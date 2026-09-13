# Claude Code adapter

Read `.workflow/vendor/WORKFLOW.md` and the project's contributor guide through the `CLAUDE.md` entrypoint. The project may expose a skill under `.claude/skills`; read that skill before following its workflow.

Use Claude Code's available file, shell and subagent tools. Ask a separate reviewer agent to inspect the diff and executed checks. When subagents are unavailable, use another review session or human review. Keep review pending until that happens. No particular model name or second vendor account is required by the shared workflow.

Project command hooks come from `.claude/settings.json`. Preserve the existing hook chain and permissions. Hook execution depends on the installed client and its trust/settings choices; a tracked hook file alone does not prove activation. Git hooks require separate clone-local activation. Never import another user's home settings or copy a broad permission allowlist as a setup shortcut.
