# Portable workflow bundle

New consumer installations use the versioned `bundle/` payload. The older `.claude` templates remain for existing installations; do not copy them over a customized project. They are not the source for this bundle and have not been certified for Codex.

The shared bundle defines investigation, testing, verification, independent review and PR outcomes. Claude Code and Codex each have an adapter. Projects retain their own setup commands, tests, architecture, hooks and access policy. Extra vendor CLIs, OMX and gstack may support advanced work, but the bundle does not install them or require personal configuration.

## Maintainer installation

Use Python 3.10 or newer and Git on a filesystem that preserves executable bits. For WSL2, clone inside the Linux filesystem. Bundle paths use portable ASCII names; file contents may contain Unicode. Clone this repository separately for maintenance, then choose a reviewed full commit ID:

```sh
python3 scripts/sync-workflow.py --source "$PWD" --ref <full-40-character-commit> --target /path/to/consumer
python3 /path/to/consumer/.workflow/vendor/sync.py --check --target /path/to/consumer
```

The sync reads committed files only. Review and commit `.workflow/vendor/` and `.workflow/lock.json` in the consumer PR. Contributors then clone only the consumer. Record this repository's URL in project documentation; the lock records exact commit and file hashes without personal absolute paths.

Add a project-owned `.workflow/project.json` declaring executable names and files:

```json
{
  "schema": 1,
  "required_tools": ["git", "python3"],
  "optional_tools": ["gh"],
  "required_files": ["AGENTS.md", "CLAUDE.md"]
}
```

Run `python3 .workflow/vendor/doctor.py --project .` to inspect this contract. It does not install tools, access credentials or run tests. Add project entrypoints that explicitly read the canonical workflow and appropriate adapter. Project commands must implement the verification steps. Integrate `bash .workflow/vendor/hooks/check-integrity.sh` into the existing Git hook chain if desired, and run the same check in CI. Do not replace an existing `core.hooksPath` automatically.

## Updating and recovering

Fix shared behavior here and add regression tests. Commit it, sync that exact commit into a consumer, then review the lock and payload diff. Source verification is available with `--check --source /path/to/upstream --target /path/to/consumer`. Dirty, missing or extra managed files block updates. Preserve local edits outside the managed directory and restore managed files from the consumer's committed revision before retrying. Never erase unknown files automatically.

Keep project-specific instructions outside `.workflow/vendor`. The installer does not own `.claude/settings.json`, `.githooks`, root agent documents or project scripts. Moving customized copies into the bundle requires a separate review of their behavior and dependencies.

## Acceptance and limits

Run `python3 -m unittest discover -s tests -v` for installer and capability checks. Consumer CI must verify the lock and its application behavior. Checksums detect drift; they are not a signature or a substitute for reviewing the pinned source. The installer accepts local commits for testing and does not prove remote reachability. Before publishing a consumer PR, push the upstream commit and record its repository and PR in project documentation.

A complete onboarding pilot still needs a fresh account on each supported host, real client sign-in, a failing test followed by a fix, passing project checks, browser evidence, independent review and a draft PR. Linux CI does not establish Windows or macOS client behavior. Production access is a separate project decision.
