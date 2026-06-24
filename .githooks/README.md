# Git Hooks (opt-in)

This directory holds a generic, opt-in `pre-commit` hook for the template. It is
**not active until you enable it** — git only runs hooks from `.git/hooks` unless
you point `core.hooksPath` here.

## Enable

```bash
git config core.hooksPath .githooks
```

Run this once per clone. To disable, run `git config --unset core.hooksPath`.

## What the hook does

The `pre-commit` hook runs two independent guards, each individually bypassable:

1. **Secret scan** — runs `gitleaks protect --staged` against the staged diff,
   using `.gitleaks.toml` if present. If `gitleaks` is not installed the scan is
   silently skipped, so the hook is safe to enable on machines without it.

2. **Migration prefix-collision guard** — blocks committing a new numbered
   migration file (e.g. `012_add_index.sql`) whose numeric prefix already exists
   on `origin/main`. This catches the classic "two branches both wrote migration
   012" conflict before it lands. **Off by default.**

## Customize

Open `.githooks/pre-commit` and set the migration directory near the top:

```bash
# Leave empty to disable the migration-collision guard entirely.
MIGRATIONS_DIR="db/migrations"   # e.g. your project's migrations folder
```

Adjust the filename pattern in the guard if your migrations are not named
`<number>_<name>` or `<number>-<name>`.

## Bypass

Use sparingly, and only with a reason:

```bash
SKIP_SECRET_SCAN=1     git commit ...   # skip the secret scan only
SKIP_MIGRATION_CHECK=1 git commit ...   # skip the migration guard only
SKIP_HOOKS=1           git commit ...   # skip the whole hook
```

## Install gitleaks

```bash
brew install gitleaks      # macOS
# or see https://github.com/gitleaks/gitleaks#installing
```
