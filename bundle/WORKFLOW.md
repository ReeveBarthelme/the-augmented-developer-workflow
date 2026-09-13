# Shared contributor workflow

Read the project's agent entrypoint and contributor guide first. This bundle defines common development outcomes. The project owns commands, architecture, access rules and deployment policy. Personal memories, global plugins and other vendors' accounts are not prerequisites.

1. Establish the requested outcome, current branch, changed files and acceptance criteria. Preserve unrelated work. Investigate the code before choosing an implementation. Write a short plan for a change involving several steps; clarify unresolved product decisions before implementing them.
2. For a behavior change, reproduce the problem or write an appropriate failing test. Capture the failure, implement the change, and rerun it. Documentation-only edits need content and link checks rather than artificial unit tests.
3. Use the project's verification commands for the affected code. Run lint, type checking and relevant tests where applicable. Verify user-visible changes in the running application. A build or HTTP health check does not prove an interaction works.
4. Ask an independent reviewer to inspect the same diff and test evidence. Use a separate native agent context when available, another session given the diff, or a human reviewer. A second model vendor is optional. Self-review does not satisfy this step. If no independent reviewer is available, mark review pending and keep the PR in draft.
5. Resolve review findings, rerun checks affected by the fixes, and record passed, failed, skipped and unverified checks separately. State the branch and revision; note uncommitted changes in evidence captured before committing.
6. Prepare the feature-branch PR with the problem, resulting behavior, test evidence and remaining gaps. Follow the project's merge and deployment policy. Access to local preview does not grant production authority.

## Capability gaps

Run the project's doctor before setup. An installed tool is only an available executable. Authentication, Docker health, browser behavior and independent review require separate evidence. Missing required tools block the affected step. Optional conveniences must not silently remove a required outcome.

Use the project command contract for setup, verification and browser checks. Avoid inventing host commands when the project provides a container runner. Do not copy credentials, home-directory settings or private memory into the repository. Project facts needed by collaborators belong in reviewed project documentation.

## Updating this bundle

Files under `.workflow/vendor` are managed snapshots. Do not edit them directly. Make a generic change upstream, test it, pin its exact commit with the upstream sync command, and review the resulting consumer diff. Project-specific changes belong outside the vendor directory. A consumer clone does not need an upstream checkout for everyday work or offline integrity checks.
