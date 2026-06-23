# Token Optimization (RTK) — optional

> **Optional add-on.** This template does **not** bundle RTK and does not depend
> on it. This doc explains a pattern that has saved ~70% of the tokens spent on
> routine dev shell operations in real use, so you can wire it up if you want it.

## What it is

Agentic coding burns a surprising share of its token budget on the *output* of
routine shell commands — `git status`, `git diff`, `ls -R`, `grep`, file reads —
whose verbose, decorated output the model has to read back in full.

**RTK ("Rust Token Killer")** is a small CLI proxy that sits in front of those
commands and returns the same information in a far more token-dense form
(trimmed decoration, collapsed whitespace, de-duplicated noise), typically
saving **60–90%** of the tokens on the operations it covers.

It is a **separate tool**, not part of this template. Install and run it on its
own; this repo only documents how to slot it into the pipeline.

## How it plugs in

There are two layers, both optional and independent.

### 1. Transparent hook rewrite (recommended)

A Claude Code hook can transparently rewrite covered commands before they run —
e.g. `git status` → `rtk git status` — so you get the savings with **zero
changes to how you or the agent type commands**. The rewrite is invisible to the
model and adds no token overhead itself.

This is configured globally (in your user-level Claude Code config), not in this
repo, so it applies across every project without per-repo wiring.

### 2. Per-project permission allowlist (optional)

If you run Claude Code with permission prompts on, add the proxied forms to your
project `.claude/settings.local.json` so they don't prompt:

```jsonc
{
  "permissions": {
    "allow": [
      "Bash(rtk grep:*)",
      "Bash(rtk read:*)",
      "Bash(rtk git status:*)",
      "Bash(rtk git diff:*)"
    ]
  }
}
```

`settings.local.json` is gitignored, so these stay machine-local.

## Meta commands

RTK exposes a few of its own commands for visibility (exact surface depends on
your RTK version):

```bash
rtk gain        # show token savings analytics
rtk discover    # analyze history for missed optimization opportunities
rtk proxy <cmd> # run a raw command without filtering (debugging)
```

## Is it worth it?

If most of your sessions are implementation/iteration loops with lots of
`git`/`grep`/`read` traffic, the savings compound quickly. If your sessions are
dominated by model reasoning rather than tool output, the win is smaller. Start
with the hook rewrite, run `rtk gain` after a few sessions, and decide.

## Credit

RTK is a third-party tool — credit to its author. This template references it as
an optional optimization only; it bundles nothing and works fine without it.
