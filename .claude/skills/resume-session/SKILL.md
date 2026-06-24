---
name: resume-session
description: |
  Use when the user wants to continue from a previous Claude Code session by
  session ID — typical phrasing: "continuing from session id <UUID>", "find the
  jsonl", "where did we leave off in session <UUID>", or any prompt that opens
  with "You are tech lead and orchestrator continuing from session id ...".
  Locates the raw session JSONL at
  ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl, summarizes the last
  exchange in tech-lead voice, and reports wrap-up items (uncommitted changes,
  open PRs, dangling todos). Distinct from /context-restore, which reads
  /context-save checkpoints — this skill reads raw JSONL.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
---

# Resume Session Skill

Reconstruct and summarize the state of a previous Claude Code session from its
raw JSONL file, then surface any wrap-up work. **Stop after the report — do not
auto-execute anything.**

This is the **entry point** of the workflow pipeline:
`resume-session` → `/orchestrate-investigation` → `/sdd` → `/tdd` → `/vdd` →
verify (`/qa` loop, gstack) → `/orchestrate-review-deploy` → `/wrap-up`.

---

## When to use / when NOT to use

**Use this skill** when the user's prompt contains:
- A UUID and words like "continuing from session id", "find the jsonl", "where
  did we leave off", "pick up where we left off"
- "You are tech lead and orchestrator continuing from session id ..."

**Do NOT use this skill** (and do not invoke `/context-restore`) when:
- The user explicitly says `/context-restore` — that skill reads checkpoints
  written by `/context-save`, which is a separate workflow.
- There is no session UUID in the prompt.

---

## Step 1 — Extract session ID

Parse the UUID from the user's message using pattern:
`[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`

If no UUID is found, ask the user for it before proceeding.

---

## Step 2 — Locate the JSONL

```bash
SESSION_ID="<extracted-uuid>"
# When work happens inside a `.worktrees/<branch>` checkout, Claude often
# writes a near-empty stub JSONL to the worktree-pathed project dir while the
# substantive transcript continues in the original repo's project dir. The
# same UUID can therefore appear in TWO files. Pick the largest by line count
# — a 1-line stub will lose to an 800-line transcript.
MATCHES=$(find ~/.claude/projects -maxdepth 2 -name "${SESSION_ID}.jsonl" -type f 2>/dev/null)
if [ -z "$MATCHES" ]; then
  echo "NOT_FOUND: no JSONL for session $SESSION_ID under ~/.claude/projects/"
  exit 1
fi
JSONL=$(echo "$MATCHES" | while IFS= read -r f; do
  printf '%d\t%s\n' "$(wc -l < "$f")" "$f"
done | sort -rn | head -1 | cut -f2-)
echo "FOUND: $JSONL"
echo "SIZE: $(wc -l < "$JSONL") lines, $(du -h "$JSONL" | cut -f1)"
# If there were other matches, surface them so the user knows they exist
OTHERS=$(echo "$MATCHES" | grep -vF "$JSONL" || true)
if [ -n "$OTHERS" ]; then
  echo "OTHER MATCHES (not used — smaller):"
  echo "$OTHERS" | sed 's/^/  /'
fi
# Decode the encoded CWD from the path component
ENCODED=$(echo "$JSONL" | sed 's|.*/projects/\([^/]*\)/.*|\1|')
CWD=$(echo "$ENCODED" | sed 's|^-|/|; s|-|/|g')
echo "CWD:  $CWD"
```

If `NOT_FOUND`, report the error clearly and stop — do not attempt to continue
with a missing file.

---

## Step 3 — Parse the JSONL tail

Use `jq` if available, otherwise fall back to Python 3. The goal is to extract:

- **First `user` message** — the original objective
- **Last 5 `user` messages** — recent direction shifts
- **Last 3 `assistant` text turns** — what we claimed to accomplish
- **Tool-use names from last 50 lines** — what actually executed
- **`gitBranch` from the last record** — branch state at session end
- **Sub-agent dispatches** (`isSidechain: true`) — in-flight delegations that
  may not have completion events

```bash
SESSION_ID="<extracted-uuid>"
JSONL="<path-from-step-2>"

# Prefer jq for robustness
if command -v jq &>/dev/null; then
  echo "=== FIRST USER MESSAGE ==="
  jq -r 'select(.type=="user") | .message.content // .content | if type=="array" then .[].text // empty else . end' \
    "$JSONL" 2>/dev/null | head -20 | head -1

  echo "=== LAST 5 USER MESSAGES ==="
  jq -r 'select(.type=="user") | .message.content // .content | if type=="array" then .[].text // empty else . end' \
    "$JSONL" 2>/dev/null | tail -5

  echo "=== LAST 3 ASSISTANT TEXT TURNS ==="
  jq -r 'select(.type=="assistant") | .message.content // .content | if type=="array" then .[] | select(.type=="text") | .text else . end' \
    "$JSONL" 2>/dev/null | tail -60

  echo "=== TOOL CALLS (last 50 lines) ==="
  tail -50 "$JSONL" | jq -r 'select(.type=="assistant") | .message.content // .content | if type=="array" then .[] | select(.type=="tool_use") | .name else empty end' 2>/dev/null

  echo "=== GIT BRANCH (last record with gitBranch) ==="
  jq -r 'select(.gitBranch != null) | .gitBranch' "$JSONL" 2>/dev/null | tail -1

  echo "=== SUB-AGENT DISPATCHES ==="
  jq -r 'select(.isSidechain==true) | "\(.type) sid=\(.sessionId // "?")"' "$JSONL" 2>/dev/null | tail -10

else
  # Python 3 fallback
  python3 - "$JSONL" <<'PYEOF'
import json, sys
lines = open(sys.argv[1]).readlines()
records = []
for l in lines:
    try: records.append(json.loads(l))
    except: pass

def text_of(r):
    c = r.get("message", {}).get("content") or r.get("content", "")
    if isinstance(c, list):
        return " ".join(x.get("text","") for x in c if x.get("type")=="text")
    return str(c)

def tool_names(r):
    c = r.get("message", {}).get("content") or r.get("content", [])
    if isinstance(c, list):
        return [x.get("name","") for x in c if x.get("type")=="tool_use"]
    return []

user_msgs = [r for r in records if r.get("type")=="user"]
asst_msgs = [r for r in records if r.get("type")=="assistant"]
last50 = records[-50:]

print("=== FIRST USER MESSAGE ===")
print(text_of(user_msgs[0])[:300] if user_msgs else "(none)")

print("\n=== LAST 5 USER MESSAGES ===")
for r in user_msgs[-5:]:
    print(text_of(r)[:200])

print("\n=== LAST 3 ASSISTANT TEXT TURNS ===")
for r in asst_msgs[-3:]:
    print(text_of(r)[:400])

print("\n=== TOOL CALLS (last 50 lines) ===")
for r in last50:
    for n in tool_names(r):
        print(n)

print("\n=== GIT BRANCH ===")
branches = [r.get("gitBranch") for r in records if r.get("gitBranch")]
print(branches[-1] if branches else "(unknown)")

print("\n=== SUB-AGENT DISPATCHES ===")
for r in records:
    if r.get("isSidechain"):
        print(f"{r.get('type')} sid={r.get('sessionId','?')}")
PYEOF
fi
```

---

## Step 4 — Check current live state

Run these regardless of what the JSONL says — live state may differ.

```bash
echo "=== GIT STATUS ==="
git status --short

echo "=== CURRENT BRANCH ==="
git branch --show-current

echo "=== RECENT COMMITS ==="
git log -5 --oneline

echo "=== WORKTREES ==="
git worktree list

echo "=== OPEN PRS (yours) ==="
if command -v gh &>/dev/null; then
  gh pr list --author @me --state open --json number,title,headRefName,statusCheckRollup \
    --template '{{range .}}#{{.number}} {{.headRefName}} — {{.title}}{{"\n"}}{{end}}' 2>/dev/null \
    || echo "(gh not authenticated or no open PRs)"
else
  echo "(gh not available)"
fi
```

---

## Step 5 — Synthesize the report

Produce a single block in this exact format:

```
── SESSION RESUME ──────────────────────────────────
Session:   <uuid>  (<start datetime> → <end datetime from last record>)
JSONL:     <path> (<N> lines, <size>)
CWD:       <decoded working directory>

Objective: <inferred from first user message — one sentence>
Last did:  <one-liner from last assistant turn>
Branch:    <current branch> (was <branch-at-session-end> at session end)

Wrap-up:
  • Uncommitted: <N files — list them, or "clean">
  • Open PRs:    <list with #num, branch, title — or "none">
  • Sub-agents:  <dispatched-but-no-completion events — or "none detected">
  • Todos:       <"todo"/"TODO"/"wrap-up" mentions in last 20 lines — or "none">

── PROPOSED NEXT STEP ──────────────────────────────
<One concrete, specific suggestion based on the wrap-up state above.
 Examples: "Commit the 3 staged files and push to <branch>."
           "Merge PR #42 — it passed CI and has no open review threads."
           "Address the P1 from the review bot before merging.">
────────────────────────────────────────────────────
```

---

## Step 6 — Stop

Do **NOT** auto-execute any wrap-up items. Surface the report and wait for the
user to direct next steps.

If the user's original message said "Is there anything else here to wrap up?" —
answer that directly in the "Wrap-up" section and the proposed next step. Do not
run deploys, merges, or commits without explicit instruction.
