Plan: PLAN-5.md
Serves: **Under Claude Code, the `query` and `read-memories` skills behave as the original
duckdb-skills project intended.** Phil decided on 2026-10-06 that the fork is Claude-Code-first,
so the Cortex Code adaptations go. The features the fork added stay: the lakehouse, contracts,
extracts, the Excel guidance in `read-file`, and `xl_date()`. This is item 3a. Items 1 and 2 have
shipped. After this come 3b (Snowflake through the Python connector) and 4 (install).

# Item 3a — Undo the Cortex Code adaptations

PLAN-5 §"Item 3a", plus fact 7.

## Measured facts this spec rests on — taken 2026-10-06 on `main` at `f780c63`

**The Snowflake-dialect layer.**
- **`skills\query\duckdb-compat.sql`** defines 17 macros: 16 Snowflake names (`IFF`, `NVL`,
  `NVL2`, `ZEROIFNULL`, `NULLIFZERO`, `DIV0`, `DIV0NULL`, `TO_VARCHAR`, `TO_NUMBER`,
  `TRY_TO_NUMBER`, `TRY_TO_DATE`, `EQUAL_NULL`, `REGEXP_SUBSTR`, `CHARINDEX`, `LEN`,
  `UUID_STRING`), plus `xl_date()` (lines 36–39).
- **What calls them:** only the contracts call anything in the file, with 3 calls to
  `xl_date()` (`contracts\All_Sales_Data.sql:66-67`, `contracts\Clayco_Job_Costs_from_GL.sql:63`).
  Nothing calls the 16.
- **Removing `LEN` is safe:** `skills\snowflake-extract\registry.sql:78-80` uses DuckDB's native
  `len()` on lists.
- **`skills\query\SKILL.md:164-201`** is the "Snowflake dialect compatibility" section,
  between two `---` rules. It covers the macros, polyglot, and a pointer to `duckdb-compat.md`.
- **Dialect-only material elsewhere:**
  - `skills\query\duckdb-compat.md` (355 lines, mostly the fixture tables);
  - `skills\query\duckdb-compat-tests.csv`;
  - `tools\run-compat-tests.ps1`;
  - `tools\prove-no-snowflake.ps1:347`, its `run-compat-tests` entrypoint. Its header comment
    at line 29 mentions it too.
- **The compat file's SHA-256 is one of `materialize`'s four freshness keys**
  (`materialize.ps1:385`, reason label `compat_sha256`).

**`read-memories`.**
- **The fork's version** is `SKILL.md` plus five `.sql` files (`search`, `message`,
  `coverage`, `sqlresults`, `sqlresults-summary`). They search **Cortex Code** logs.
- **What else uses them:**
  - `prove-no-snowflake.ps1:350` runs `search.sql` as entrypoint `read-memories:search`, with
    env setup at `:412-415` and `:420-423`;
  - `skills\snowflake-extract\SKILL.md:39` cites `skills/read-memories/SKILL.md:15-18` as a
    precedent.
- **Upstream's version** (`git show 7feda8e:skills/read-memories/SKILL.md`) is one `SKILL.md`.
  Its single query is
  `read_ndjson('<glob>', auto_detect=true, ignore_errors=true, filename=true)` over
  `$HOME/.claude/projects/*/*.jsonl`.
- **That read is complete on this machine.** It reads **22,987 rows, equal to the
  22,987 lines** in those files. An explicit `columns={message:'JSON'}` read gives the
  same 22,987 rows and the same 63 hits for `lakehouse`. Auto-detect drops nothing today.
- **Three Windows defects in upstream's version, measured:**
  1. **`--here` builds the wrong folder name.** `echo "$PWD" | sed 's|[/_]|-|g'` gives
     `-c-Users-woodsonp-Claude-Dev-duckdb-skills`, but the real folder is
     `C--Users-woodsonp-Claude-Dev-duckdb-skills`. Claude Code replaces every character that
     is not `[A-Za-z0-9]` with `-`, applied to the Windows path. `pwd -W | sed
     's/[^A-Za-z0-9]/-/g'` gives the right name from Git Bash.
  2. **Folder names differ in drive-letter case, but that does not matter.** `~\.claude\projects\`
     holds both `C--Users-woodsonp-OneDrive---Clayco--Inc-Documents` and
     `c--Users-woodsonp-OneDrive---Clayco--Inc-Documents-Snowflake-Workspace`. The reviewer
     measured that NTFS and DuckDB's glob are both case-insensitive: a wrong-case path still
     reads the folder. No case handling is needed.
  3. **The `project` column is always empty on Windows.** DuckDB returns `filename` with
     backslashes (`C:\Users\woodsonp\.claude\projects\C--Users-woodsonp\…`), so
     `regexp_extract(filename, 'projects/([^/]+)/', 1)` matches nothing.
- **`$HOME` and `$PWD` in Git Bash are `/c/Users/…`.** That is a form native `duckdb.exe` must
  not be handed. Use Windows-form paths (`C:/Users/…`, e.g. from `cygpath -m` or `pwd -W`).

**README.**
- **The fork note (lines 5–10)** belongs to item 4. Line 7 ("searches Cortex Code session logs")
  becomes false after this item, and item 4 rewrites it.
- **The `read-memories` section** runs from line 77 to line 85. Only line 78 is
  Cortex-specific.
- **Line 195** describes the fork's PowerShell/`.sql` design for `read-memories`.

**Other things found by review.**
- **A second precedent pointer:** `skills\snowflake-extract\registry.sql:5-6` cites
  `skills/read-memories/SKILL.md` for a rule the restored skill no longer follows.
- **An entrypoint count:** `prove-no-snowflake.ps1:334` says "the 14 main entrypoints".
- **`prove-no-snowflake.ps1` fails at the base commit today.** It runs in about 90 seconds.
  The run gives `SUMMARY,entrypoints=14,pass=13,fail=1`, exit 1.
  - **The failure:** the `gl-facts` entrypoint. `checks\gl-facts.sql`'s `bare` view reads the
    GL sheet with type inference on purpose, as a DATE oracle. It hits the same
    `'City of DeKalb'` cell as the earlier probe bug.
  - **Scope:** this is not this item's concern. It is dev scaffolding, and Phil decides
    separately.
- **After the dialect section goes, no skill text mentions `ensure-duckdb-compat` or
  `duckdb-compat.md`.** Nothing would tell a query session how to get `xl_date()`.

## Decisions

1. **The compat file keeps only `xl_date()`.**
   - **`duckdb-compat.sql`** keeps its `xl_date()` macro and the comment block directly above
     it (lines 36–39 now), under a new 2–3 line header saying what the file is for: decoding
     Excel serial dates in contracts. Everything else is deleted.
   - **The file name stays `duckdb-compat.sql`.** Renaming it would touch `materialize`,
     `run-assertions`, `ensure-duckdb-compat` and the item 2 skill text for no gain.
2. **The query skill loses the dialect section.**
   - **Deleted:** the "Snowflake dialect compatibility" section of `skills\query\SKILL.md`.
   - **Exact lines:** delete lines 164–200, the `---` at 164 through the blank line at 200.
     The `---` at 201 stays.
   - **What replaces it:** one short paragraph, so `xl_date()` stays discoverable:
     > **Excel serial dates.** Run `${CLAUDE_PLUGIN_ROOT}/tools/ensure-duckdb-compat.ps1` once
     > per project (see "Running the tools"). `xl_date(serial)` then returns a `DATE`. See
     > `${CLAUDE_PLUGIN_ROOT}/skills/query/duckdb-compat.md`.
   - **The "Running the tools" section from item 2 stays.**
3. **`duckdb-compat.md` shrinks** to a short page:
   - what `duckdb-compat.sql` holds (`xl_date()`) and why its trailing `::DATE` matters;
   - how it reaches a session (`ensure-duckdb-compat` writes one quoted `.read` line, per
     item 2);
   - that its hash is a `materialize` freshness key, so editing it re-materializes every
     contract;
   - one line saying the Snowflake macro layer was removed on 2026-10-06 and lives in git
     history before this commit.

   Target: under 40 lines.
4. **Delete** `skills\query\duckdb-compat-tests.csv` and `tools\run-compat-tests.ps1`. In
   `prove-no-snowflake.ps1`:
   - delete the `run-compat-tests` entrypoint (`:347`);
   - reword the header sentence at `:29` so it no longer names that script;
   - change `14` to `12` in the comment at `:334`.

   Make no other change to that file except decision 6's.
5. **`read-memories` is upstream's version, with the three Windows defects fixed and a new
   description.**
   - **Start from** `git show 7feda8e:skills/read-memories/SKILL.md`. Keep its structure, its
     query shape, its `LIMIT 40`, and its "do not narrate" instruction.
   - **Search paths:**
     - **All projects:** `<HOME>/.claude/projects/*/*.jsonl`, where `<HOME>` is the
       Windows-form home folder (`cygpath -m "$HOME"`).
     - **`--here`:** `<HOME>/.claude/projects/<dir>/*.jsonl`, where `<dir>` is
       `pwd -W | sed 's/[^A-Za-z0-9]/-/g'`.
     - **No drive-letter case handling.** Windows paths and DuckDB's glob are
       case-insensitive (measured).
   - **Windows only:** do not add a macOS/Linux branch.
   - **The `project` column** uses `regexp_extract(replace(filename, '\', '/'), 'projects/([^/]+)/', 1)`.
   - **The description** (frontmatter) and the first paragraph say, in substance:
     > Search the raw transcripts of past **Claude Code** sessions. For decisions, conventions,
     > or "what did we decide about X", **check shared memory first** (the `memory_*` tools),
     > which holds curated notes from both Claude Code and Cortex Code. Use this skill to find
     > the exact wording of a past conversation, or something shared memory does not hold.
     > It cannot see Cortex Code sessions.
   - **Trigger phrases** stay in the description, so the skill is still discoverable.
6. **Delete** the five fork `.sql` files in `skills\read-memories\`.
   - **`prove-no-snowflake.ps1`:** delete the `read-memories:search` entrypoint (`:350`) and
     its two env-setup blocks (`:412-415`, `:420-423`).
   - **`skills\snowflake-extract\SKILL.md:39`:** drop the parenthetical precedent pointer, which
     would cite a line that no longer exists. Keep the sentence it sits in.
   - **`skills\snowflake-extract\registry.sql:5-6`:** drop the parenthetical
     `(see skills/read-memories/SKILL.md for the same rule applied there)`. Keep the
     sentence.
7. **README.**
   - **Line 78 only:** replace it with a description of the restored skill: Claude Code
     transcripts, and shared memory first. Lines 77 and 79–85 stay.
   - **Line 195:** delete its paragraph about the fork's PowerShell `read-memories`, and add
     the sentence "`read-memories` is adapted for Windows paths in this fork."
   - **Leave alone:** lines 5–10 (the fork note, even though line 7 becomes false; item 4
     rewrites it) and every other README line.

## Deliverables

- `skills\query\duckdb-compat.sql`, `skills\query\duckdb-compat.md`, `skills\query\SKILL.md`.
- `skills\read-memories\SKILL.md`, with the five `.sql` files deleted.
- `skills\query\duckdb-compat-tests.csv` and `tools\run-compat-tests.ps1`, both deleted.
- `tools\prove-no-snowflake.ps1`, per decisions 4 and 6.
- `skills\snowflake-extract\SKILL.md:39` and `skills\snowflake-extract\registry.sql:5-6`.
- `README.md`.
- `RESULT-1.md` at repo root.

## Out of scope — do not do these

- **The contracts:** do not edit `contracts\*.sql`.
- **The compat file's name, location, and `xl_date()`'s body:** none change.
- **`ensure-duckdb-compat.ps1`, `materialize.ps1`, `run-assertions.ps1`, or any tool not named
  above:** do not edit them.
- **Snowflake access, `allowed-tools`, `snowflake_sql_execute`:** that is item 3b.
- **`docs\duckdb-snowflake-findings.md`:** it is a historical record. Leave it.
- **`.claude-plugin\`, `.cortex-plugin\`:** these are item 4's. Do not delete or edit them.
- **`checks\gl-facts.sql`:** do not edit it. Its failure today is known and outside this
  item.
- **`docs\tasks\`, `docs\plans\`:** archived history is never edited.
- **Shared memory itself:** no `memory_*` calls, and no hooks.
- **The real lake:** nothing writes to
  `~\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\`.

## Conventions

- **The verifier works in a throwaway worktree at the implementer's commit**, called `$W`.
  `$B` is a second throwaway worktree at the base commit, `git merge-base HEAD main`.
- **PowerShell tools** run as child processes via `Start-Process` with separate
  stdout/stderr files, as in items 1 and 2. Never use `2>`/`2>&1` on a `powershell` call.
- **Skill commands** (bash) run the item 2 way:
  - write them to an LF `.sh` file;
  - run that file with `Start-Process 'C:\Program Files\Git\bin\bash.exe'`;
  - never call `bash -c` from PowerShell.
- **`$L`:** a scratch lake folder under `%TEMP%`, outside any repo, used as `-LakeRoot` by both
  `$B` and `$W`.
- **The workbook is live and refreshes daily.** AC3 compares before and after within one
  verifier session. If `materialize` reports `workbook_mtime`/`workbook_sha256` among its
  reasons in the after-run, the workbook moved mid-check. Re-run AC3 from the start rather than
  calling it a failure.

## Acceptance checks

**AC1 — The macro layer is gone, and `xl_date()` still works.** In one DuckDB process:

```
duckdb -c ".read '<$W>/skills/query/duckdb-compat.sql'" -c "SELECT xl_date(45000) AS d, typeof(xl_date(45000)) AS t" -c "SELECT IFF(true,1,2)"
```

- **First query:** prints `2023-03-15` and `DATE`.
- **Second query:** fails with `Catalog Error` naming `iff`.
- **Control:** the same command at `$B` succeeds on the second query, returning `1`.
- **No macros left:** also run
  `duckdb -csv -c ".read '<$W>/skills/query/duckdb-compat.sql'" -c "SELECT string_agg(function_name, ',' ORDER BY function_name) FROM duckdb_functions() WHERE NOT internal"`.
  - **At `$W`:** it prints exactly `xl_date`.
  - **At `$B`:** it prints all 17 names.

**AC2 — Nothing still references the removed material.** Run this from `$W` in PowerShell:

```
git grep -n -F -e polyglot -e run-compat-tests -e duckdb-compat-tests -e search.sql -e message.sql -e coverage.sql -e sqlresults -e cortex/conversations -e 'cortex\conversations' -e 'IFF(' -e 'NVL(' -- . ':!docs/tasks' ':!docs/plans' ':!docs/duckdb-snowflake-findings.md' ':!TASK.md' ':!PLAN-5.md' ':!REVIEW-*.md' ':!RESULT-*.md'
```

- **Expect:** no output, and `$LASTEXITCODE` = 1. That is `git grep`'s "no match", **not** a
  failure.
- **Control:** the same command at `$B` prints hits (about 150 lines) and exits 0.
- **Case-sensitive on purpose:** `-F` is case-sensitive, so `date_diff(` in
  `SIDECAR.md`/`registry.sql` is not a hit.

**AC3 — The compat change re-materializes, and the data is identical.**
1. **Baseline:** from `$B`, run `materialize -LakeRoot $L`. Both contracts give
   `REFRESHED`, `reason=no_manifest`, and `CHECKS_PASSED,true`.
   - **If the baseline fails:** if either line is `REFUSED` or `CHECKS_PASSED,false`, AC3 is
     **NOT RUN**, because that contract fails on the live workbook, outside this item. Quote
     the output. Never use `-Force`.
   - **Reviewer's timing:** about 17 s.
2. **Snapshot:** export both lake tables to Parquet files outside `$L`:
   `ATTACH 'ducklake:$L/lake.ducklake' AS lake (DATA_PATH '$L/data', READ_ONLY)`, then
   `COPY lake.<table> TO '<file>'`.
3. **After:** from `$W`, run `materialize -LakeRoot $L`.
   - Both contracts give `REFRESHED`, with a reason that **includes `compat_sha256`** and does
     **not** include `contract_sha256`.
   - **This step must not SKIP.**
4. **Compare:** for each table, the after-table and its baseline Parquet give 0 rows in both
   directions of `EXCEPT ALL`. Equal row counts are also quoted (57,777 GL rows and 484 sales
   rows as of 2026-10-06; quote whatever the live workbook gives).

**AC4 — `read-memories` works on Windows.** Use the skill's own commands, as written in the new
`SKILL.md`, with `<KEYWORD>` = `lakehouse`.
- **From `C:\Users\woodsonp\Claude\Dev\duckdb-skills`, with `--here`:**
  - at least 1 row is returned;
  - every row's `project` is exactly `C--Users-woodsonp-Claude-Dev-duckdb-skills`, not empty;
  - no row comes from another project.
  - Running from the real repo folder only reads logs, which is safe.
- **Same keyword, no `--here`:** at least as many rows as with `--here`, and at least one row
  whose `project` is a different folder (or, if none exists, say so and quote the per-project
  counts from a `GROUP BY project` variant).
- **Description:** the frontmatter `description` contains the phrase `shared memory` and the
  words `Claude Code`.

**AC5 — `prove-no-snowflake.ps1` lost exactly its two entrypoints, and nothing else
changed.**
- **Run:** from `$B` and from `$W`, `prove-no-snowflake.ps1` with no arguments. It takes about
  90 s at `$B`.
- **Quote:** both `SUMMARY` lines, and every `EXT` line's label and verdict.
- **Expect:**
  - `entrypoints=14` at `$B` and `entrypoints=12` at `$W`;
  - the two missing labels are exactly `run-compat-tests` and `read-memories:search`;
  - each of the 12 shared labels has the same verdict at `$W` as at `$B`.
- **Exit code is not the criterion.** `gl-facts` fails at the base commit today because of the
  live workbook. Do not fix it.

## Mutation proof — must fail, then pass again after revert

- **M1:** in `$W`, re-add the line
  `CREATE OR REPLACE MACRO IFF(c, t, f) AS CASE WHEN c THEN t ELSE f END;` to
  `duckdb-compat.sql`. **AC1 must fail.** Revert by re-checking-out the committed file inside
  `$W`.

## Final check — Phil

```powershell
cd C:\Users\woodsonp\Claude\Dev\duckdb-skills; .\tools\materialize.ps1
```

**Expect, the first time after merge:**
- both contracts `REFRESHED`;
- `All_Sales_Data`'s reason includes `compat_sha256`;
- `Clayco_Job_Costs_from_GL` may show `reason=previous_checks_failed` instead. Its last real
  run failed checks, and that reason outranks the hash comparison.

Either is the one-time rebuild the plan predicted. A second run reports `SKIPPED` for both.
