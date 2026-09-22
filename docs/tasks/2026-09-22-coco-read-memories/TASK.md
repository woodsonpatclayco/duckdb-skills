# TASK — port `read-memories` to Cortex Code session logs

Plan: none (single self-contained task; no multi-task plan exists)

Serves: **"Do you remember what we decided about X?"** — being able to search my own
past Cortex Code sessions the way `read-memories` searches Claude Code sessions.
Today the skill reads the wrong folder with the wrong column names and returns
nothing from Cortex Code history. After this, asking about past work finds it.

After this task: nothing further is planned. The other 8 duckdb-skills stay on
upstream untouched.

---

## Context

`duckdb-skills` was installed from `github.com/duckdb/duckdb-skills` into
`~/.snowflake/cortex/plugins/duckdb-skills/`. Its `read-memories` skill is written
for **Claude Code** logs. Cortex Code's logs live elsewhere with a different schema,
so the skill's query fails at the binder and returns nothing.

This repo (`C:\Users\woodsonp\Claude\Dev\duckdb-skills`) is a fork working copy.
`upstream` = duckdb/duckdb-skills. Branch: `coco-read-memories`.

**Scope: `skills/read-memories/` only.** Do not modify the other 8 skills — they work
and must keep merging cleanly from `upstream/main`. That clean-merge property is the
one thing that must not break.

Environment: Windows, PowerShell 5.1. DuckDB CLI **v1.5.5**.

---

## ⚠️ The corpus grows while you work — read this before any count

Every Cortex Code session, **including the implementer's and the verifier's own**,
appends to the logs being searched. Measured during the drafting of this spec:

| Metric | At first measurement | ~40 min later |
|---|---|---|
| log files | 392 | **393** |
| `tool_use` blocks | 20,039 | 20,122 |
| `tool_result` blocks | 19,992 | 20,075 |
| `thinking` blocks | 9,578 | 9,618 |
| `text` blocks | 9,310 | 9,312 |

**Every number in this spec is a snapshot floor, not an equality.** A measurement
**above** a stated number is expected drift — quote the actual figure and continue.
A measurement **below** it is a real failure. No acceptance check may assert
equality on a corpus count.

---

## Verified findings (measured on this machine — do not re-litigate)

### 1. Log location is TWO levels, not one

```
~/.snowflake/cortex/conversations/*.history.jsonl        →  37 files
~/.snowflake/cortex/conversations/*/*.history.jsonl      → 356 files
                                                  TOTAL  → 393 files (and rising)
```

A single-level glob misses the 37 top-level files — **including every file containing
recoverable SQL results**. Both globs are required. Pass them as a DuckDB list:
`read_ndjson([top_glob, sub_glob], ...)`.

### 2. Schema mismatch — 4 broken references in the current skill

| Current skill expects | Cortex Code actually has |
|---|---|
| `timestamp` | `user_sent_time` / `assistant_sent_time` (see finding 8) |
| `message.role` | `role` (top-level; there is no `message` struct) |
| `message.content` | `content` — a **JSON array of blocks**, not a string |
| `regexp_extract(filename,'projects/([^/]+)/',1)` | path is `conversations/<uuid-or-hash>/` |

### 3. Column presence VARIES between files

`assistant_sent_time` exists in some sessions and not others. A plain `auto_detect`
read across the glob errors with
`Binder Error: Referenced column "assistant_sent_time" not found`.
Older sessions carry extra fields (`attachedContext`, `request_id`).

### 4. Struct auto-detection across the glob is LOSSY — the key design constraint

Reading `content` with `auto_detect=true` unions struct keys from a **sample**, so
keys present in only a few files are silently dropped. Measured: a glob-wide
auto_detect read produced a `content` struct of only
`{type, text, thinking, image, tool_result{status}}` — silently losing `tool_use`,
`internalonly`, `is_user_prompt`. Querying a dropped key raises
`Binder Error: Could not find key "..." in struct`.

**Therefore: read `content` as `JSON`, not as a struct.**

```sql
read_ndjson([...], columns = {role: 'VARCHAR', content: 'JSON'},
            ignore_errors = true, filename = true)
```

then `unnest(json_extract(content, '$[*]'))` and pull fields with
`json_extract_string(c, '$.type')`. Key-presence-independent and immune to sampling.
**This is non-negotiable** — a struct-typed read will appear to work, then break on a
corpus it did not sample. Because `columns=` is explicit, declare every column you
reference; do not reference `assistant_sent_time` unless it is in `columns=`.

### 5. Content block types (snapshot — floors, per the warning above)

| Block type | Count |
|---|---|
| `tool_use` | 20,122 |
| `tool_result` | 20,075 |
| `thinking` | 9,618 |
| `text` | 9,312 |
| `image` | 7 |

Of the `text` blocks, **8,053 are clean** and **1,259 contain `<system-reminder>`** —
injected context (memory files, `AGENTS.md`, connection banners), not conversation.
These match keyword searches spuriously.

### 6. Past SQL results are recoverable — match BOTH tool names

For `tool_result` blocks, the result set is CSV text at
`tool_result.content[*].text`. **Two tool names produce these, and the modern one
holds 95% of the history:**

| `tool_result.name` | blocks | with `row(s) returned` |
|---|---|---|
| `snowflake_sql_execute` | 1,119 | 979 |
| `sql_execute` (legacy) | 56 | 50 |
| **TOTAL** | **1,175** | **1,029** |

Match both: `tool_result.name IN ('sql_execute','snowflake_sql_execute')`. Prefer a
forward-compatible `name LIKE '%sql_execute'` so the next rename does not silently
halve coverage. **Matching only `sql_execute` recovers 4.8% of the history and is a
FAIL**, even though it returns data.

`tool_result.sqldata` appears 47 times in raw text but `json_extract(c,
'$.tool_result.sqldata')` returns 0 rows corpus-wide; cause not diagnosed. **Do not
build on `sqldata`** — use the CSV text path above.

### 7. Every session has a metadata sidecar — but sidecars come in TWO SHAPES

Beside each `<id>.history.jsonl` sits `<id>.json`. Present for every session, but the
field names differ by level and **only `session_id`, `title`, and `working_directory`
exist in both shapes**:

| Shape | Count | Timestamp fields |
|---|---|---|
| top-level sidecars | ~37 | `created_at`, `last_updated` (ISO strings); also `git_root`, `git_branch` |
| sub-level sidecars | ~356 | `creationDate`, `lastMessageDate` (**epoch milliseconds, BIGINT**); no `created_at`, no git fields |

Measured: of 428 parseable `.json` files, **39 have `created_at` and 389 do not.**
Assuming `created_at` corpus-wide loses 90% of sessions.

Read sidecars with an explicit columns list covering both shapes:

```sql
columns = {session_id: 'VARCHAR', title: 'VARCHAR', working_directory: 'VARCHAR',
           created_at: 'VARCHAR', creationDate: 'BIGINT'}
```

Join sidecars via a second `read_json` over the same two glob levels (`*.json`),
matching `session_id` to the history filename stem. The `.json` glob returns ~428
files — more than the ~394 history files — so let unmatched sidecars drop. **Do not
assert a 1:1 count.**

`working_directory` is stored with a **lowercase drive letter** (`c:\Users\...`) while
PowerShell's `$PWD.Path` renders `C:`. Any comparison must be case-insensitive and
separator-normalised.

**This makes `--here` supportable** — compare `working_directory` to the current
directory. **Never fall back to the containing folder name as a project identifier:**
355+ files sit in 17 opaque hash folders, one of which is literally named `global` and
holds 20 unrelated sessions.

### 8. Half of all rows have NO timestamp — specify the fallback

| Rows | with `user_sent_time` | with `assistant_sent_time` | with neither |
|---|---|---|---|
| 37,854 | 18,935 | **91** | **18,828 (49.7%)** |

`assistant_sent_time` is present on 91 rows out of 37,854 — finding 2's
"and/or" badly overstates it. Since keyword search is most useful on assistant text,
a naive implementation shows a blank timestamp on most rows.

**Required behaviour:** derive and display

```sql
ts = coalesce(user_sent_time::TIMESTAMP, assistant_sent_time::TIMESTAMP,
              created_at::TIMESTAMP, epoch_ms(creationDate))
```

Both sidecar terms are required per finding 7 — `created_at` alone is NULL for ~90% of
sessions. Never return a blank timestamp. Order by the same expression.

### 9. Windows and shell specifics

- `regexp_extract` on `filename` must accept **both** separators: `[/\\]`.
- **PowerShell expands `$` inside double-quoted strings**, so
  `duckdb -c "... '$.type' ..."` silently yields empty JSON paths. Single-quoted
  PowerShell strings work but require doubling every internal quote, which is
  unreadable and error-prone. **Ship the SQL in a `.sql` file invoked with
  `duckdb -f`** — not because `-c` cannot work, but because it cannot work reliably.
- DuckDB box-drawing output garbles in this console. Use `-csv`.
- Only two bash idioms exist in the current skill — `$HOME` and
  `$(echo "$PWD" | sed 's|[/_]|-|g')`. Neither blocks functionality; both are
  trivially replaced. **The bash idioms are not the problem; the schema is.**

---

## Requirements

1. Rewrite `skills/read-memories/SKILL.md` to search Cortex Code logs at **both**
   glob levels, reading `content` as JSON per finding 4.
2. Ship `skills/read-memories/search.sql`, invoked via `duckdb -csv -f`. Runtime
   values pass through **three** environment variables read by `getenv()`:
   **`DSK_KEYWORD`**, **`DSK_MODE`**, and **`DSK_CWD`**. `DSK_CWD` exists because a
   `.sql` file run under `-f` has no way to learn the working directory — DuckDB
   exposes no cwd function and `$PWD` is not an environment variable. When `--here`
   is absent the agent sets `DSK_CWD` to the empty string and the SQL applies no
   directory filter.

   `DSK_MODE` takes exactly three values:

   | value | behaviour |
   |---|---|
   | `search` | keyword search (requirements 4-7) |
   | `sqlresults` | recover past SQL result sets (requirement 8) |
   | `coverage` | emit a single `distinct_files` count from the skill's own `read_ndjson` call (check A1) |

   Any other value must print `unknown DSK_MODE` and exit non-zero.

   SKILL.md must show the literal PowerShell invocation the **agent** runs (the user
   never sets these):
   ```powershell
   $env:DSK_KEYWORD = '<keyword>'; $env:DSK_MODE = 'search'; $env:DSK_CWD = $PWD.Path
   duckdb -csv -f "<abs path>\skills\read-memories\search.sql"
   ```
3. Document how the **user** invokes the skill, in the form already used at
   `README.md:74` (`/duckdb-skills:read-memories <keyword> [--here]`). The current
   skill's `argument-hint` is being removed (requirement 9), so the invocation
   contract must be restated in the body.
4. Exclude `<system-reminder>` blocks from text results by default. Keyword search
   mode reads **only blocks whose `type` is `text`** — `tool_use`, `tool_result`,
   `thinking`, and `image` blocks are excluded from search mode entirely. (Measured
   for keyword `Project Miner`: 186 `tool_result`, 112 `tool_use`, 22 `text`, 6
   `thinking`. Including tool blocks floods the output with CSV dumps and re-admits
   quoted `<system-reminder>` text, failing requirements 6 and 4.) Past tool results
   are reachable only through the recovery mode of requirement 8.
5. Exclude `thinking` blocks from results by default (internal reasoning, not
   decisions).
6. Return per hit: session id (from filename), `ts` per finding 8, `role`, and a
   **readable prose snippet** — not a JSON struct dump. Include the sidecar `title`
   where available.
7. Support `--here` per finding 7, scoping to sessions whose sidecar
   `working_directory` matches the current directory.
8. Support recovering past SQL result sets per finding 6 as a **distinct documented
   mode** (`DSK_MODE`), not mixed into keyword-search output.
9. Frontmatter: keep only `name` and `description`. Remove `argument-hint` and
   `allowed-tools` — Cortex Code parses nothing else. The `description` must name
   Cortex Code, not Claude Code.
10. Keep the behavioural contract: search silently, do not narrate, absorb results
    into the answer rather than dumping logs.
11. Commit on branch `coco-read-memories` **before** writing `RESULT-1.md`.

## Non-requirements

- Do **not** make it also search Claude Code logs. Cortex Code only. (63 Claude Code
  files exist at `~/.claude/projects/`; out of scope.)
- Do **not** diagnose the `sqldata` mystery (finding 6). Note it and move on.
- Do **not** touch `README.md`. If your change makes it stale — it documents
  `read-memories` at lines 70-74 and claims it uses `duckdb-docs` at line 125 — name
  the stale line numbers in `RESULT-1.md` and make no change to `README.md`. This
  does not block completion of the rest of the task.
- Do **not** use, create, or write to `state.sql`. `read-memories` deliberately stays
  outside the shared state convention: it reads a fixed absolute path and needs no
  attached database.
- Do **not** touch `.claude-plugin/` or `.cortex-plugin/`.
- Do **not** reformat or re-lint the other 8 skills. They must keep merging cleanly
  from `upstream/main`.
- Do **not** create a GitHub remote or push — no `gh` CLI on this machine.
- Do **not** pin a DuckDB version in the skill.

---

## Acceptance checks

Run from `C:\Users\woodsonp\Claude\Dev\duckdb-skills`. `RESULT-1.md` must quote the
**actual console output** of every check. A check not run is a FAIL, not a blank.

**A1 — corpus fully covered (catches the 37-file miss)**

Count distinct files from **inside the skill's own `read_ndjson` call** — not from
`Get-ChildItem`. A file DuckDB skips is not covered. This is what `coverage` mode
exists for (requirement 2); do not run an ad-hoc query.

```powershell
$env:DSK_MODE = 'coverage'; $env:DSK_KEYWORD = ''; $env:DSK_CWD = ''
duckdb -csv -f "<abs path>\skills\read-memories\search.sql"
```

```
Expected: a single `distinct_files` value >= 394, AND strictly greater than the
sub-level-only count (357 at time of writing).
A result equal to the sub-level count alone means the top-level glob is
missing → FAIL.
```

**A2 — keyword search returns conversation, not injected context**

Keyword `Project Miner`:

```
Expected: >= 1 hit, and ZERO hits whose text contains "<system-reminder>".
(For reference: the OLD BROKEN skill returned 5 hits, all system-reminder.
That figure is not reproducible with the new query — do not treat its absence
as a discrepancy.)
```

**A3 — a known-present keyword is found, rendered readably**

Keyword `read_xlsx`:

```
Expected: >= 1 hit. `role` and `ts` both non-empty on every row. Snippet is
readable prose.
If a snippet looks like {'type': 'text', 'text': ...} → FAIL.
```

Margin warning: only **3** `text` blocks corpus-wide contain this token, of which
**2** are clean (non-system-reminder). Both must be returned. Search mode must **not**
filter by `role`, dedupe by session, or require a non-NULL raw timestamp — each of
those takes this check to zero. If it returns 0 rows the cause is over-filtering, not
a missing corpus.

**A4 — known-absent keyword returns cleanly (control)**

Keyword `zzqqxx-not-a-real-token`:

```
Expected: 0 rows. $LASTEXITCODE = 0. No binder error, no stack trace.
This is a control — it passes on any non-crashing build.
```

**A5 — SQL result recovery covers BOTH tool names**

Two invocations.

**A5a — coverage of both tool names:**

```powershell
$env:DSK_MODE = 'sqlresults'; $env:DSK_KEYWORD = ''; $env:DSK_CWD = ''
duckdb -csv -f "<abs path>\skills\read-memories\search.sql"
```

```
Expected: a `total,with_rows_returned` line with total >= 1,175 and
with_rows_returned >= 1,029 (floors — higher is expected drift).
A result of 56,50 means only the legacy `sql_execute` name was matched → FAIL.
```

**A5b — one result set actually rendered:**

Re-run `sqlresults` with `DSK_KEYWORD` set to any token present in one recovered
result.

```
Expected: at least one recovered result whose text contains a comma-delimited
header line followed by data rows and a line matching "N row(s) returned".
Paste the full block in RESULT-1.md, and the keyword used.
```

**A6 — no struct-key or missing-column failures anywhere**

```
Expected: none of A1-A5 emits "Could not find key" or "Referenced column ...
not found". Either string means the JSON-typed read of finding 4 was not used.
State explicitly, per check A1-A5, whether it ran, and paste its output.
```

**A7 — blast radius contained (two commands)**

```
git diff --stat upstream/main -- . ":(exclude)skills/read-memories" ":(exclude)TASK.md" ":(exclude)RESULT-1.md" ":(exclude).cortex-plugin"
Expected: EMPTY output.
```

`TASK.md` and `.cortex-plugin/plugin.json` are Cortex-fork additions already committed
on this branch and legitimately absent from `upstream/main`; they are excluded
deliberately, not overlooked. Without those exclusions this check fails on an
untouched repo.

```
git status --short
Expected: exactly one line, `?? RESULT-1.md`. Nothing else.
```

`.cortex-plugin/plugin.json` is **tracked and committed**, so it can never appear as
`??` — do not `git rm` it to satisfy this check. The tree is clean at the start of this
task, and requirement 11 commits `SKILL.md` and `search.sql` before `RESULT-1.md` is
written, so `RESULT-1.md` is the only untracked artifact.

**A8 — no relative-path assumptions**

Run A1 again with the working directory set to `C:\Users\woodsonp`:

```
Expected: the same file count A1 returned in this same run (do not compare to
a number written in this spec — compare the two runs to each other).
```

**A9 — thinking blocks excluded**

Assert the mechanism, not the side-effect. `thinking` prose lives at `$.thinking`, not
`$.text`, so an implementation that matches on `$.text` excludes thinking blocks
*incidentally* — this check must not pass on that accident.

```
Select-String -Pattern "\$\.type" skills\read-memories\search.sql
Expected: an explicit block-type filter (e.g. json_extract_string(c,'$.type') = 'text').
Absence of an explicit type filter → FAIL, even if output happens to be clean.

Then keyword `Project Miner`: ZERO returned rows are `thinking` blocks (6 thinking
blocks in the corpus contain that phrase; none may appear).
```

**A10 — frontmatter is Cortex-correct**

```
Get-Content skills\read-memories\SKILL.md -TotalCount 10
Expected: frontmatter contains exactly `name` and `description`.
No `argument-hint`. No `allowed-tools`. The description names Cortex Code.
```

**A11 — `--here` actually scopes**

Run with `--here` from `C:\Users\woodsonp\Claude\Dev\duckdb-skills`, i.e.
`$env:DSK_CWD = $PWD.Path`.

Compare case-insensitively with separators normalised:
`lower(replace(working_directory,'/','\')) = lower(replace(getenv('DSK_CWD'),'/','\'))`.

```
Expected: at least one session, including
  6b705409-e077-4c05-a7c1-1b1b476e9583  "DuckDB Skills Fork for Cortex Code"
whose working_directory is stored as `c:\Users\woodsonp\Claude\Dev\duckdb-skills`
(lowercase drive letter). Zero sessions from other directories.

More than one session is expected drift — later work in this directory adds
sessions. ZERO sessions is a FAIL: a case-sensitive `=` against $PWD.Path returns
nothing and looks deceptively like a clean scope.
If --here returns the full corpus, the sidecar join is not wired → FAIL.
```

**A12 — documented contract present in SKILL.md**

Covers requirements 2, 3, and 10, which no other check touches.

```
Select-String -Pattern "DSK_KEYWORD","DSK_CWD","duckdb -csv -f","/duckdb-skills:read-memories" skills\read-memories\SKILL.md
Expected: at least one match per pattern; paste the matched lines.
Plus: quote the lines carrying the do-not-narrate contract (requirement 10).
```
