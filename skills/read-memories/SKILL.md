---
name: read-memories
description: >
  Search the raw transcripts of past Claude Code sessions. For decisions, conventions, or "what
  did we decide about X", check shared memory first (the memory_* tools), which holds curated
  notes from both Claude Code and Cortex Code. Use this skill to find the exact wording of a
  past conversation, or something shared memory does not hold. It cannot see Cortex Code
  sessions. Use when the user says "do you remember", "what did we do", references past
  conversations, or you need context from prior sessions.
argument-hint: <keyword> [--here]
allowed-tools: Bash
---

Search the raw transcripts of past Claude Code sessions. For decisions, conventions, or "what
did we decide about X", **check shared memory first** (the `memory_*` tools), which holds
curated notes from both Claude Code and Cortex Code. Use this skill to find the exact wording
of a past conversation, or something shared memory does not hold. It cannot see Cortex Code
sessions.

Search past session logs silently — do NOT narrate the process. Absorb the results and continue with enriched context.

`$0` is the keyword. Pass `--here` as `$1` to scope to the current project only.

## Step 1 — Query

Run this in Git Bash. `HOME_W` is the Windows-form home folder (`C:/Users/...`); native
`duckdb.exe` cannot read the `/c/Users/...` form that `$HOME` has in Git Bash.

```bash
HOME_W=$(cygpath -m "$HOME")
# All projects:
SEARCH_PATH="$HOME_W/.claude/projects/*/*.jsonl"
# Current project only (--here): use this line instead
SEARCH_PATH="$HOME_W/.claude/projects/$(pwd -W | sed 's/[^A-Za-z0-9]/-/g')/*.jsonl"

duckdb :memory: -c "
SELECT
  regexp_extract(replace(filename, '\', '/'), 'projects/([^/]+)/', 1) AS project,
  strftime(timestamp::TIMESTAMPTZ, '%Y-%m-%d %H:%M') AS ts,
  message.role AS role,
  left(message.content::VARCHAR, 500) AS content
FROM read_ndjson('$SEARCH_PATH', auto_detect=true, ignore_errors=true, filename=true)
WHERE message::VARCHAR ILIKE '%<KEYWORD>%'
  AND message.role IS NOT NULL
ORDER BY timestamp
LIMIT 40;
"
```

Keep only the `SEARCH_PATH` line you need. Replace `<KEYWORD>` before running; double any
single quote in it.

Claude Code names each project folder by replacing every character that is not a letter or
digit in the Windows path with `-` (for example `C--Users-woodsonp-Claude-Dev-duckdb-skills`).
The folder's drive-letter case varies, but Windows paths and DuckDB's glob are
case-insensitive, so it does not matter.

## Step 2 — Internalize

From the results, extract decisions, patterns, unresolved TODOs, and user corrections. Use this to inform your current response — do not repeat raw logs to the user.
