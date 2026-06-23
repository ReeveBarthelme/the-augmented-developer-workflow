# Security

This template ships an opt-in **secret-scanning layer** so that adopters get a
baseline defense against committing credentials. Nothing here runs until you
turn it on.

## Components

| File | Purpose |
|------|---------|
| `.gitleaks.toml` | Gitleaks config: sensible allowlists (env examples, deps, test fixtures, placeholder regexes, public-by-design Firebase web API keys). |
| `.githooks/pre-commit` | Opt-in hook that runs `gitleaks protect --staged` on every commit, plus an optional migration prefix-collision guard. |
| `.githooks/README.md` | How to enable, customize, and bypass the hook. |

## Wire it up

1. **Install gitleaks** (optional but recommended):

   ```bash
   brew install gitleaks      # macOS — or see the gitleaks README for other platforms
   ```

2. **Enable the pre-commit hook** (one-time per clone):

   ```bash
   git config core.hooksPath .githooks
   ```

   From now on, staged changes are scanned for secrets before each commit. If
   `gitleaks` is not installed, the scan is skipped silently — the hook stays
   safe to enable everywhere.

3. **Scan the whole history on demand**:

   ```bash
   gitleaks detect --config .gitleaks.toml --no-banner
   ```

4. **Tune the allowlist** in `.gitleaks.toml` when you hit a confirmed false
   positive. Never allowlist a real secret — rotate it instead.

## If a secret is ever committed

1. **Rotate the credential immediately** — assume anything pushed is compromised,
   even if force-removed later.
2. Remove it from the working tree and add an allowlist entry only if it was a
   false positive.
3. For published history, rewrite with `git filter-repo` (or BFG) and
   force-push, then rotate again.

## Reporting

If you find a security issue in this template, please open an issue on the
repository (omit any live secret values from the report).
