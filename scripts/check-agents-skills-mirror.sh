#!/usr/bin/env bash
# check-agents-skills-mirror.sh — .agents/skills must be a byte copy of .claude/skills.
# Claude Code reads .claude/skills; Codex reads .agents/skills. They are copies, not
# symlinks, so they drift silently. Run this in pre-merge; fix drift by re-copying.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
[ -d .claude/skills ] || { echo "no .claude/skills — nothing to mirror"; exit 0; }
rc=0
seen=" "
for d in .claude/skills/*/ .agents/skills/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    case "$seen" in *" $n "*) continue ;; esac
    seen="$seen$n "
    diff -r ".claude/skills/$n" ".agents/skills/$n" >/dev/null 2>&1 || {
        echo "DRIFT: .claude/skills/$n vs .agents/skills/$n"; rc=1
    }
done
[ "$rc" -eq 0 ] && echo "agents-skills mirror: in sync" || echo "Fix: rm -rf .agents/skills && mkdir -p .agents/skills && cp -R .claude/skills/. .agents/skills/"
exit "$rc"
