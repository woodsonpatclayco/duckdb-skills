---
name: read-memories
description: >
  Search past Cortex Code session logs (~/.snowflake/cortex/conversations/) to recall prior
  decisions, patterns, or unresolved work. Use when the user says "do you remember", "what
  did we do", references past conversations, or you need context from prior Cortex Code
  sessions.
---

Search past session logs silently — do NOT narrate the process. Absorb the results into your
answer and continue; never dump raw logs or CSV to the user.

## User invocation

```
/duckdb-skills:read-memories <keyword> [--here]
```

`<keyword>` is a substring to search for. `--here` scopes the search to sessions whose working
directory matches the current one; omit it to search every Cortex Code session.

## Agent invocation

The user never sets `DSK_KEYWORD` or `DSK_CWD` directly — the agent sets them before running
`search.sql`. Set `DSK_CWD` to the empty string when `--here` was not given; the query then
applies no directory filter.

```powershell
$env:DSK_KEYWORD = '<keyword>'; $env:DSK_CWD = $PWD.Path
duckdb -csv -f "<abs path>\skills\read-memories\search.sql"
```

Omit the last line of `$env:DSK_CWD = ...` (leave it `''`) when `--here` was not passed.

Each `.sql` file is run with `-f`, not `-c`, because a `.sql` file has no way to learn the
working directory on its own — DuckDB exposes no cwd function and `$PWD` is not an environment
variable — and because PowerShell expands `$` inside double-quoted `-c` strings, which
silently breaks any inline JSON path like `'$.type'`.

### Other files

Beyond `search.sql`, this skill has three more single-purpose files:

| File | Use for |
|---|---|
| `search.sql` | keyword search over conversation text (the default for the invocation above) |
| `sqlresults.sql` | recovering a past Snowflake SQL result set by keyword (`DSK_KEYWORD` required) |
| `sqlresults-summary.sql` | a `total`/`with_rows_returned` coverage count of recoverable SQL history (ignores `DSK_KEYWORD`) |
| `coverage.sql` | a single `distinct_files` sanity count of the corpus this skill reads (ignores `DSK_KEYWORD`) |

Use `sqlresults.sql` when the user asks for a table or number they recall querying before, not
for ordinary "what did we discuss" recall.

## What the query does

- Reads the log corpus at **both** glob depths under
  `~/.snowflake/cortex/conversations/` — `*.history.jsonl` (top-level sessions) and
  `*/*.history.jsonl` (sessions in hashed subfolders). A single-level glob misses roughly a
  tenth of all sessions, including every one holding a recoverable SQL result.
- Reads each message's `content` field as `JSON`, never as an auto-detected struct. Cortex
  Code's schema varies session to session — some blocks (`tool_use`, `internalonly`,
  `is_user_prompt`, ...) don't appear in every file — and a struct type inferred from a
  sampled subset of the glob silently drops whichever keys weren't in the sample, then errors
  with `Could not find key "..." in struct` the first time a query touches one. Reading as
  JSON and pulling fields with `json_extract_string` sidesteps this entirely.
- `search.sql` searches only blocks whose `$.type` is `text`. `tool_use`, `tool_result`,
  `thinking`, and `image` blocks are excluded from keyword search — including tool blocks
  floods results with CSV dumps and quoted `<system-reminder>` text. Past SQL results are
  recovered separately, through `sqlresults.sql` and `sqlresults-summary.sql`, which filter
  `$.type = 'tool_result'` instead.
- `search.sql` excludes any `text` block containing `<system-reminder>` — injected context
  (memory files, connection banners, tool-usage reminders), not conversation.
- `search.sql` derives a display timestamp as `coalesce(user_sent_time, assistant_sent_time,
  sidecar created_at, sidecar creationDate)`, because roughly half of all message rows carry
  neither `user_sent_time` nor `assistant_sent_time`, and the two sidecar shapes (top-level vs.
  hashed-subfolder sessions) use different timestamp fields.
- `search.sql` joins each hit to its session's metadata sidecar (`<session-id>.json`) for
  `title`, and for `--here` scoping against `working_directory`. That comparison is
  case-insensitive and separator-normalized, because sidecars store a lowercase drive letter
  (`c:\Users\...`) while PowerShell's `$PWD.Path` renders an uppercase one.
- `search.sql` and `sqlresults.sql` require `DSK_KEYWORD` and fail loudly (non-zero exit) if
  it is empty, rather than silently matching everything.

## Step — internalize

From the results, extract decisions, patterns, unresolved TODOs, and user corrections. Use
this to inform your current response — do not repeat raw logs or CSV output to the user.
