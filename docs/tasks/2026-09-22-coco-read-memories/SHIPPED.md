# SHIPPED — `read-memories` ported to Cortex Code session logs

Date: 2026-09-22 · Branch: `coco-read-memories` · Implementation commit: `c91cc89`
Verified at: `9c0a606`, in a disposable worktree. Verdict: **SHIP**.

## The point of it

**Before:** asking about past work returned nothing useful. The skill read
`~/.claude/projects/` with Claude Code's column names (`timestamp`, `message.role`,
`message.content`), none of which exist in Cortex Code logs — so the query failed at the
binder, and on the occasions it returned anything, all 5 hits were injected
`<system-reminder>` context rather than conversation.

**After:** it searches 398 Cortex Code log files across both glob levels under
`~/.snowflake/cortex/conversations/` and returns dated, readable, attributed hits. A
verifier search for `dangling blob` returned one clean hit with session id, timestamp,
role, and title.

## What shipped

- `skills/read-memories/SKILL.md` — rewritten; frontmatter is exactly `name` +
  `description`, naming Cortex Code.
- `skills/read-memories/search.sql` — driven by `DSK_KEYWORD`, `DSK_MODE`, `DSK_CWD`,
  with three modes: `search`, `sqlresults`, `coverage`.
- `content` is read as `JSON`, never as a struct (spec finding 4). No struct-key or
  missing-column errors in any of the 12 checks.
- SQL result recovery matches both `sql_execute` and `snowflake_sql_execute`: 1,179
  blocks, 1,033 with `row(s) returned` — against the 56/50 the legacy name alone yields.
- `--here` scopes by sidecar `working_directory`, compared case-insensitively and
  separator-normalised.

## What deliberately did NOT change

- **The other 8 skills.** Untouched, so the fork keeps merging cleanly from
  `upstream/main`. That property was the one thing not allowed to break.
- **Claude Code logs.** Not searched. 63 files exist at `~/.claude/projects/`; out of
  scope on purpose.
- **`README.md`.** Lines ~70-75 and ~125 are now stale (they describe the old
  `read-memories` and claim it uses `duckdb-docs`). Left stale deliberately — a
  non-requirement forbade touching it. **This is the one known loose end.**
- **`state.sql`.** `read-memories` stays outside the shared state convention: fixed
  absolute path, no attached database.
- **`.claude-plugin/` and `.cortex-plugin/`.** Untouched.
- **The `sqldata` mystery** (`tool_result.sqldata` appears 47 times in raw text but
  extracts 0 rows corpus-wide). Not diagnosed; the CSV-text path is used instead.
- **No remote, no push.** There is no fork remote on this machine — `upstream` is
  read-only upstream. The work exists on this branch only.

## Known cosmetic issue (disclosed, accepted)

`search.sql` implements the three modes as guarded statements, so every run prints a
`guard` header and two empty mode-headers ahead of the real result block. The verifier
judged this untidy but not disqualifying: the answer section is always present and
locatable by its own header row. An automated consumer must find the right section
rather than assume the first block.

## Spec defect found by verification

Acceptance check A7 cmd1 fails as literally written, because `REVIEW-task-1.md` — the
review artifact the convention itself requires — was not in the `:(exclude)` list. The
verifier re-ran it with that file also excluded and got empty output, confirming no real
blast radius. **The fix belongs in the check convention, not in this task**: any A7-style
diff against upstream must exclude the whole artifact set (`PLAN*`, `TASK`, `REVIEW*`,
`RESULT*`, `VERIFY*`), not an enumerated subset that goes stale the moment a round is
added.
