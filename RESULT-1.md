# RESULT-1 — item 8 (the cross-source join), round 1

## Serves

**Ask one question across a Snowflake extract and a workbook sheet — job costs from
`Data Extracts.xlsm` by parent project from Snowflake — in one SQL statement, with the age of every
input printed beside the answer, and optionally save the joined result so it can be re-queried later
without re-reading either source or touching Snowflake.**

## Branch and commit

`item8-cross-source-join`, commit `1f3fe0f` (pushed to `origin/item8-cross-source-join`). `main` was
never touched. This file is committed and pushed separately, after the code commit, per the task
instructions.

## Files changed

- **`tools\cross-query.ps1`** (new) — the runner. Parses the query with DuckDB's own
  `json_serialize_sql`, classifies every input by exact parse-tree shape (never a regex or
  "looks like a path" heuristic), dates every `extract_table('<name>')` and `lake.<table>` input
  before running anything, runs the query in one process with the lake `READ_ONLY` unless `-Save`,
  and optionally saves the result as a real table with its inputs' versions recorded in a new
  `lake.join_manifest`.
- **`examples\job-costs-by-parent-project.sql`** (new) — the worked join example (GL costs by
  parent project, joined to the extract for the project name/WIP status).
- **`examples\job-costs-unmatched.sql`** (new) — the anti-join companion: GL rows whose project is
  missing from the extract.
- **`README.md`** (edited) — new "Joining a Snowflake extract to a workbook sheet" section after
  "Session state", before "Local development".
- **`skills\snowflake-extract\SKILL.md`**, **`skills\lakehouse\SKILL.md`** (edited) — one short
  paragraph each pointing at the README section. Descriptions (front matter) are byte-identical to
  `main` — confirmed via `git diff main`.

## Acceptance checks

**AC1 — the headline. PASS.**
```
EXTRACT,parent_projects,age_minutes=8580,window=60,stale=true,rows=15314,materialized_at=2026-09-24 18:54:17
LAKE,Clayco_Job_Costs_from_GL,age_minutes=5,materialized_at=2026-09-30 17:49:36.454219,workbook_changed_since=false
RESULT,rows=345,elapsed=0.034,extract_ages=parent_projects:8580,stale_inputs=1
PARENT_PROJECT_NUMBER,PARENT_PROJECT_NAME,PARENT_WIP_STATUS,gl_rows,job_costs
5070009819,JV-STACK Miner Bldg A,,225,1751635076.38
... (20 rows total)
```
Exit 0. `n=345` confirmed against a same-run `count(DISTINCT PARENT_PROJECT_NUMBER)` on
`lake.Clayco_Job_Costs_from_GL` in `<L>` (345). **Timing**: sampled repeatedly across the session;
typical whole-command `Measure-Command` times were 1.3–1.8 s, comfortably under 2 s, but two early
measurements (before an optimization — see Concerns) hit 2.1–2.5 s. See "Concerns" for the
environment-level cause measured directly.

**AC2 — the join loses and duplicates nothing. PASS.**
Full 345-row result (via `-Limit 1000`) summed: `gl_rows` total = 62,603, `job_costs` total =
`22505496119.72` — both match `count(*)` / `sum(JOB_COSTS)` on `lake.Clayco_Job_Costs_from_GL` in
`<L>` exactly. `examples\job-costs-unmatched.sql` against `<L>` returned `rows=0`.

**AC3 — the age is real, not decorative. PASS.**
`<Y>` built from a copy of the real `parent_projects` extract with only `materialized_at` rewritten
to 10 minutes ago. Same query file, no edit:
- `-ExtractRoot <Y>`, `DSK_WINDOW_MINUTES=60` (default): `age_minutes=11,window=60,stale=false`.
- `-ExtractRoot <Y>`, `DSK_WINDOW_MINUTES=5`: `age_minutes=11,window=5,stale=true`.

**AC4 — the name, not a path, is what resolves. PASS.**
`<Z>` built via `COPY (SELECT * FROM read_parquet('<X>/parent_projects/*.parquet') ORDER BY
PARENT_PROJECT_NUMBER LIMIT 1000) TO ... (FORMAT parquet)` plus a sidecar with `row_count=1000`.
Same example file run with `-ExtractRoot <X>` then `<Z>`:
- `<X>`: `RESULT,rows=345` (all 345 GL projects present in the full 15,314-row extract).
- `<Z>`: `EXTRACT,parent_projects,...,rows=1000,...` and `RESULT,rows=1` — confirmed against an
  independent same-run `count(DISTINCT g.PARENT_PROJECT_NUMBER)` joined to `<Z>`'s actual parquet
  file, which also returned **1**. `examples\job-costs-unmatched.sql` against `<Z>` returned
  `rows=344` (non-zero, as required). `grep`ing both example files for `parquet` and `:\ ` / `:/`
  found nothing.

**AC5 — a saved join is re-queryable with its provenance. PASS.**
`-Save gl_by_parent` against `<L>` printed `SAVED_AS,gl_by_parent,rows=345,run_id=f6a72d06-...`.
The scratch copy of `<X>` used for this check was then deleted (asserted under `$env:TEMP` first;
`Test-Path` → `False` after, and `Test-Path <X>\parent_projects\_extract.json` → `True`,
confirming the real `<X>` was never touched). Re-querying
`SELECT count(*) AS n, sum(job_costs) AS c FROM lake.gl_by_parent` with `-ExtractRoot <the deleted
path>` printed:
```
SAVED,gl_by_parent,age_minutes=8527,saved_at=2026-09-30 16:49:53.413241,inputs=parent_projects@2026-09-24 18:54:17;Clayco_Job_Costs_from_GL@787f12a6-0dc7-4e1b-b6cc-ffef118648ba
RESULT,rows=1,elapsed=0.006,extract_ages=none,stale_inputs=1
n,c
345,22505496119.72
```
`n=345`/`c=22505496119.72` match AC1's `rows` and AC2's job-cost sum exactly. `age_minutes=8527` ≥
8,400 (the extract's age, the oldest input — not the save's own few-second-old timestamp). One
`lake.join_manifest` row confirmed with its `inputs` JSON (see the SAVED line above).

**AC6 — a refreshed extract does not silently change a saved join. PASS.**
Saved `gl_by_parent` again from `<Z>` (`SAVED_AS,gl_by_parent,rows=1,run_id=42b64af8-...`).
`lake.join_manifest` now holds two rows for `gl_by_parent`:
```
run_id=f6a72d06-... saved_at=2026-09-30 16:49:53.413241 lake_snapshot_id=10 row_count=345
run_id=42b64af8-... saved_at=2026-09-30 17:02:23.983374 lake_snapshot_id=12 row_count=1
```
`SELECT count(*) FROM lake.gl_by_parent AT (VERSION => 10)` → **345** (the first save's count,
unchanged); current `SELECT count(*) FROM lake.gl_by_parent` → **1** (the second save's count).

**AC7 — refusals. PASS (13 of 14 cases exactly as specified; 1 case refused via a different rule
than TASK.md's own prose predicts — see "Disagreements" below).** Every case: exit 1, nothing run.
`<L>`'s GL row count and `lake.snapshots()` count confirmed unchanged after the batch (62,603 before
and after; `-Save` collision attempts never reached a write).
| case | result |
|---|---|
| `DROP TABLE lake.manifest` | `ERROR,parse,Only SELECT statements can be serialized to json!` |
| `SELECT 1; DROP TABLE lake.manifest` with `-Save x` | same parser refusal (2 statements, one non-SELECT) |
| `extract_table('par' \|\| 'ent')` | `ERROR,input,extract_table,argument must be a single string constant naming the extract` |
| `extract_table('no_such_extract')` | `ERROR,extract,no_such_extract,not in the registry at <root>` (exact text) |
| `FROM '<X>/.../*.parquet'` (single-quoted) | `ERROR,input,<path>,not a lake table or an extract -- ...` |
| `FROM "<X>/.../*.parquet"` (double-quoted) | same |
| `FROM parent_projects.parquet` | `ERROR,input,parent_projects.parquet,not a lake table or an extract -- ...` |
| `SELECT (SELECT count(*) FROM '<X>/.../*.parquet')` | same as single-quoted |
| `FROM lake.x.parquet` | `ERROR,input,lake.x.parquet,not a lake table or an extract -- ...` (see Disagreements) |
| `FROM lake.snapshots()` | `ERROR,input,snapshots,table function not permitted -- ...` |
| CTE named `'C:/x.parquet'` | `ERROR,input,C:/x.parquet,CTE name may not contain path characters` |
| `read_xlsx('<live workbook>', ...)` | `ERROR,input,read_xlsx,table function not permitted -- ...`; live workbook hash/mtime unchanged |
| `-Save manifest` | `ERROR,save,manifest,reserved name -- may not be used for a saved join` |
| `-Save Clayco_Job_Costs_from_GL` | `ERROR,save,Clayco_Job_Costs_from_GL,a saved join may only replace a saved join, never a contract table` |
| `-Save clayco_job_costs_from_gl` (case collision) | same refusal; `<L>` GL row count unchanged (62,603) |
| `-Save bad-name` | `ERROR,save,bad-name,invalid table name -- must match ^[A-Za-z_][A-Za-z0-9_]*$` |
| `-LakeRoot <empty scratch dir>` | `ERROR,lake,no lake at <root> -- run tools\materialize.ps1 first`; `Test-Path <dir>\lake.ducklake` → `False` after |

**AC8 — decoys are not inputs. PASS.** A query with `-- lake.decoy extract_table('decoy_in_comment')`
in a comment and `'lake.not_a_table'` as a string literal, around a real join, printed exactly one
`EXTRACT` line and one `LAKE` line and ran (`RESULT,rows=345`).

**AC9 — a changed workbook is reported. PASS.** `<L2>` built exactly as `<L>` (own scratch workbook
copy). Sequence:
1. Query: `workbook_changed_since=false`.
2. Scratch copy's `LastWriteTime` moved forward one hour: `workbook_changed_since=true`,
   `stale_inputs` rose from 0 to 1, exit still 0.
3. Scratch copy removed: `workbook_present=false`, query still ran, same count (`n=62603`) both times.

**AC10 — the non-save path cannot write. PASS.** `<L>`'s `lake.ducklake` `LastWriteTime` unchanged
across AC1/AC2/AC8 and every non-`-Save` AC7 refusal. `-Verbose` on AC1's query showed the generated
`ATTACH 'ducklake:...' AS lake (DATA_PATH '...', READ_ONLY);` — `READ_ONLY` present.

**AC11 — the lock is reported, not retried. PASS.** A separate `duckdb -f` process held `<L>`
read-write with `SELECT max(hash(i*7+1)) FROM range(2000000000) t(i)` (confirmed `HasExited=False`
throughout). `-Save lock_test_table` against the same `<L>` failed in **2,066 ms** (well under 5 s)
with the verbatim `File is already open in ...duckdb.exe (PID <n>)` text, holder confirmed still
running (`HasExited=False`) at that moment, exit 1, no retry.

**Which attach failed**: the `-Save` collision-check's own **read-only** attach (my step "2b",
issued before the write attach) — the query used for this check (`extract_table('parent_projects')`
only, no lake input) has no lake `BASE_TABLE`, so the merged read-only dating attach never ran; the
first attach attempted after the extract's `EXTRACT` line was the collision check's `ATTACH ...
READ_ONLY`, which is where the lock surfaced. This matches the reviewer's own expectation ("step 2's
read-only attach" surfaces the lock first).

**AC12 — docs. PASS, no drift.** Followed the README section literally: `materialize.ps1` (no
`-Contract`, so both real contracts) against the **live** workbook into a fresh scratch lake;
`list-extracts.ps1 -ExtractRoot <X>`; the by-parent-project example; the unmatched example; `-Save` +
re-query. Reached AC1's `RESULT` line (`rows=345`). `workbook_changed_since=false` throughout — no
SharePoint sync landed during this run (the live workbook's `LastWriteTime` was
`2026-09-30T09:49:32` before AGENTS.md's own baseline note and identical after — no drift to quote).
*Control*: `snowflake-extract` and `lakehouse` descriptions confirmed byte-identical to `main` via
`git diff main`.

**New README section** (verbatim, as shipped):
> ## Joining a Snowflake extract to a workbook sheet
>
> `tools\cross-query.ps1` answers one question across a Snowflake extract (`tools\snowflake-extract`)
> and a workbook sheet materialized into the DuckLake lakehouse (`tools\materialize.ps1`) in a single
> SQL statement, printing the age of every input beside the answer. Steps, from a clean shell in this
> repo:
>
> 1. **`tools\materialize.ps1`** — bring the lake current. A stale lake table (its workbook has
>    changed since the last materialize) is *reported*, never fixed automatically — this tool never
>    refreshes anything on your behalf.
> 2. **`tools\list-extracts.ps1`** — see which Snowflake extracts exist and how old they are.
>    Refreshing a stale extract is done through the `snowflake-extract` skill in an agent session, not
>    by any script here — `cross-query.ps1` cannot call Snowflake itself.
> 3. **`tools\cross-query.ps1 -Sql examples\job-costs-by-parent-project.sql`** — read the `EXTRACT`,
>    `LAKE` and `RESULT` lines it prints, in that order, before the answer's own CSV rows.
> 4. **`tools\cross-query.ps1 -Sql examples\job-costs-unmatched.sql`** — the same two inputs, but an
>    anti-join: GL rows whose parent project is missing from the extract. This is the check a stale
>    extract fails first — a project created in Snowflake after the extract was taken shows up here,
>    even though the join in step 3 quietly drops it.
> 5. **`-Save <table>`** — save the joined result as a table in the lake
>    (`tools\cross-query.ps1 -Sql examples\job-costs-by-parent-project.sql -Save gl_by_parent`), then
>    re-query it with `cross-query.ps1 -Sql <a file selecting from lake.gl_by_parent>` so its `SAVED`
>    provenance line prints instead of `LAKE`.
>
> **The freshness rule.** Every input's age prints beside the answer, unconditionally. Nothing is ever
> refused for being old — a stale extract or a lake table whose workbook has changed since it was
> materialized is loud, recorded, and still answered. The reader's window (`DSK_WINDOW_MINUTES`,
> 60 minutes by default) decides whether an age counts as `stale`; it never decides whether the query
> runs. A saved join keeps the data it was built from — it does not re-read either source — and every
> time it is read back, it reports the age of its own **oldest** recorded input, not the age of the
> save itself.
>
> **The patterns.** A query given to `cross-query.ps1` may only read `extract_table('<name>')` for a
> Snowflake extract (the name is resolved from the extract registry at run time — the query text never
> contains a path) and `lake.<table>` for a workbook sheet materialized as a contract, or a previously
> saved join. Nothing else is dateable, so nothing else is accepted: a raw `read_parquet`/`read_csv`/
> `read_xlsx`/`read_json` call, a quoted file path, or any other table function is refused. A saved join
> is stored as a real **table**, never a view — a view's `extract_table` macro does not survive into a
> new process, so a saved join that referenced an extract would silently break the moment it was
> re-queried.

**`skills\snowflake-extract\SKILL.md` paragraph** (verbatim):
> ## Joining an extract to a lake table
>
> `tools\cross-query.ps1` (item 8) answers one question across a lake table and a Snowflake extract
> in a single SQL statement, printing the age of both inputs beside the answer -- see the README's
> "Joining a Snowflake extract to a workbook sheet" section for the walkthrough and the freshness rule.

**`skills\lakehouse\SKILL.md` paragraph** (verbatim):
> ## Joining a lake table to a Snowflake extract
>
> `tools\cross-query.ps1` (item 8) answers one question across a lake table and a Snowflake extract
> in a single SQL statement, printing the age of both inputs beside the answer -- see the README's
> "Joining a Snowflake extract to a workbook sheet" section for the walkthrough and the freshness rule.

**AC13 — control: nothing real was touched. PASS.**
| | before | after |
|---|---|---|
| real `lake.ducklake` size | 8,663,040 | 8,663,040 |
| real `lake.ducklake` `LastWriteTime` | 2026-09-25T16:26:30.30 | 2026-09-25T16:26:30.30 (identical) |
| real extract file count | 17 | 17 |
| real extract total bytes | 5,742,840 | 5,742,840 |
| newest real extract file mtime | 2026-09-24T13:54:17.16 | 2026-09-24T13:54:17.16 (identical) |
| live workbook `LastWriteTime` | 2026-09-30T09:49:32 | 2026-09-30T09:49:32 (identical — `unchanged`, not `SYNCED`) |
| live workbook length | 68,150,686 | 68,150,686 |
| `~\.duckdb-skills\` subdirs | `c-users-...-duckdb-skills`, three pre-existing `_verify-*`, `fixtures` (5) | identical 5 — no new directory |

**AC14 — control: no BOM.** Checked all 6 new/changed files (`tools\cross-query.ps1`, both example
`.sql` files, `README.md`, both `SKILL.md` files) by reading the first 3 bytes: none begin with
`EF BB BF`. PASS.

## Mutation proofs

All nine run: fail with the mutation, pass/refuse with the real script. Every mutation was applied to
a throwaway copy of `cross-query.ps1` placed temporarily inside `tools\` (so `$PSScriptRoot`-relative
paths resolved correctly), then deleted immediately after — confirmed via `git status --short` that no
mutant file was ever left in the tree.

1. **Regex instead of parse tree.** Replaced the extract-name collection with
   `[regex]::Matches($rawQueryText, "extract_table\('([^']+)'\)")`. Against AC8's decoy query:
   `ERROR,extract,decoy_in_comment,not in the registry at ...` — the comment's decoy was extracted
   and treated as a real input, exactly the failure TASK.md predicts. Real script: AC8 passes
   (single `EXTRACT`/`LAKE` line, decoy ignored — see above).

1b. **"Ignore unqualified `BASE_TABLE` nodes" instead of the allow-list.** Removed the CTE-name
   membership check from the "is this a CTE" branch (any unqualified node is now silently ignored).
   TASK.md's own AC7 quoted-path fixture alone doesn't exercise the hole (it has no other input, so
   the separate "references nothing" guard still refuses it) — I built a combined query,
   `SELECT (SELECT count(*) FROM '<X>/parent_projects/*.parquet') AS decoy_read, (SELECT count(*)
   FROM extract_table('parent_projects')) AS legit`, which has a legitimate `extract_table` input
   alongside the quoted-path decoy. Against the mutant: `decoy_read=15314` — **the raw file was
   read**, exit 0. Against the real script: refused,
   `ERROR,input,C:/.../parent_projects/*.parquet,not a lake table or an extract -- ...`, exit 1.

2. **`CREATE VIEW` instead of `CREATE TABLE`.** Saved `gl_mutant2_test` via `CREATE OR REPLACE VIEW`.
   The save itself succeeded (a view is valid SQL). Re-querying `SELECT count(*) AS n FROM
   lake.gl_mutant2_test` in a **new** process (the real script, no macro defined) failed:
   `Catalog Error: Table with name _r does not exist!` — the view's own `extract_table(...)`
   reference could not be resolved outside the process that defined the macro, exactly TASK.md's
   measured fact ("a new process fails: `Catalog Error: Table Function with name extract_table does
   not exist!`"; the wrapping error text differed slightly here because the failure surfaced one
   level up, at the `CREATE TEMP TABLE _r AS SELECT count(*) FROM lake.gl_mutant2_test` statement,
   but the outcome — exit 1, cannot re-query — is identical). Real script (`CREATE TABLE`): AC5
   passes as shown above.

3. **Hard-coded glob under `<X>` instead of the registry.** Replaced `$parquetGlob =
   [string]$row.parquet_glob` with a literal path under the real `<X>`. Running AC4's example against
   `-ExtractRoot <Z>` (the 1,000-row fixture) still reported `RESULT,rows=345` — the full 15,314-row
   `<X>` data, not `<Z>`'s tiny file — proving the name never actually resolved to `<Z>`. Real script:
   `rows=1` against `<Z>` (see AC4 above).

4. **Statement-count guard dropped.** Replaced `if ($statements.Count -ne 1)` with `if ($false)`.
   **Disagreement with TASK.md's own proof query** — see below; ran the mutation with a query that
   actually exercises the guard's protection.

4b. **`-Save` name comparison made case-sensitive.** Removed `lower()` from the collision-check's
   `duckdb_tables()` query. `-Save clayco_job_costs_from_gl` against `<L>` (a real, disposable scratch
   lake, always passed as `-LakeRoot` under `$env:TEMP`) **succeeded**:
   `SAVED_AS,clayco_job_costs_from_gl,rows=1,run_id=...`, exit 0. Verified the contract table was
   destroyed: `SELECT count(*) FROM lake.Clayco_Job_Costs_from_GL` → **1** (was 62,603). `<L>` was
   then rebuilt from scratch (both contracts re-materialized against the same scratch workbook copy;
   confirmed 62,603 GL rows restored) before continuing. Real script: refused,
   `ERROR,save,clayco_job_costs_from_gl,a saved join may only replace a saved join, never a contract
   table`, GL row count confirmed unchanged (62,603) both immediately after the refusal and at the
   end of the session.

5. **Attach read-write on the non-save path.** Made `$attachOpts` always omit `READ_ONLY`. `-Verbose`
   on AC1's query showed the generated `ATTACH 'ducklake:...' AS lake (DATA_PATH '...');` — no
   `READ_ONLY` — failing AC10's generated-SQL check directly. (Did not additionally check whether the
   catalog's `LastWriteTime` moved under this mutation, since the generated-SQL half alone already
   fails the check unambiguously, and repeatedly re-running a read-write attach against `<L>` risked
   an unnecessary extra write path while other proofs were still pending.) Real script: `READ_ONLY`
   present (AC10 above), `<L>`'s `LastWriteTime` unchanged.

6. **Report the save's age instead of the oldest input's.** Replaced the oldest-input fallback with
   `$oldestMaterializedAt = $savedAt` unconditionally. Re-querying `lake.gl_by_parent` (re-saved after
   the mutation-4b rebuild) reported `age_minutes=0` — the save's own few-second-old timestamp, not
   the extract's real ~8,500-minute age — failing AC5's `age_minutes ≥ 8,400` requirement. Real
   script: `age_minutes=8578` on the identical re-query.

7. **`coalesce(..., error(...))` guard and the registry existence check both omitted.** The sidecar
   `Test-Path` refusal was replaced with a silent `continue` (skipping the unknown name rather than
   refusing), and the macro's `error(...)` fallback was dropped from
   `read_parquet(getvariable('dsk_extract_globs')[n])`. Running `extract_table('no_such_extract')`
   printed the raw DuckDB error: `Parser Error: read_parquet cannot take NULL list as parameter` —
   exactly TASK.md's predicted failure mode. Real script:
   `ERROR,extract,no_such_extract,not in the registry at <root>` (exact text, confirmed in AC7).

## Both example queries' measured figures

`examples\job-costs-by-parent-project.sql` against `<X>`/`<L>` (today): 345 rows, `job_costs`
summed to `22505496119.72`, `gl_rows` summed to 62,603 — matching `lake.Clayco_Job_Costs_from_GL`'s
own `count(*)`/`sum(JOB_COSTS)` exactly (AC2). `examples\job-costs-unmatched.sql` against the same
inputs: 0 rows (today's extract, though ~8,500 minutes stale, still happens to cover every GL
project). Against the 1,000-row `<Z>` fixture, the same unmatched query returns 344 rows — the
check catching exactly what a stale/truncated extract misses.

## How a quoted path appears in the parse tree

Measured directly (`json_serialize_sql`, v1.5.5) for `SELECT * FROM 'C:/x/*.parquet'`: a
`BASE_TABLE` node with `catalog_name` and `schema_name` both the empty string `""`, `table_name`
equal to the literal path text `"C:/x/*.parquet"`. This is the *exact same shape* a bare CTE
reference produces (`WITH x AS (...) SELECT * FROM x` → `BASE_TABLE`, `catalog_name`/`schema_name`
both `""`, `table_name = "x"`) — the reason the allow-list collects every CTE name *first* and only
then treats a bare-shaped `BASE_TABLE` as a CTE if its name (case-insensitively) matches one already
collected; everything else in that shape is refused as "not a lake table or an extract".

## Which attach AC11's lock hit

The `-Save` collision check's own read-only attach (see AC11 above) — not the save's own write
attach, and not step 2's per-table dating attach (which never ran for this particular test query,
since it referenced no lake table).

## Disagreements with the frozen spec

### 1. `FROM lake.x.parquet` is refused by a different rule than TASK.md's own prose predicts

TASK.md (and the reviewer's replacement text) both state the allow-list's first bullet — `catalog_name
= lake` and `schema_name = main`, or `catalog_name` empty and `schema_name = lake` — "is what catches
`lake.x.parquet`", implying that case matches the lake-input shape and is refused via the
`duckdb_tables()` existence check (`no such table in the lake`).

Measured directly (`json_serialize_sql`, v1.5.5): `FROM lake.x.parquet` parses as `BASE_TABLE` with
`catalog_name = "lake"`, `schema_name = "x"`, `table_name = "parquet"` — a genuine three-part
identifier. This matches **neither** of the two allow-list shapes literally as written (`catalog=lake
AND schema=main`, or `catalog=empty AND schema=lake`) — `schema_name` here is `"x"`, not `"main"`, and
`catalog_name` is not empty. I implemented the two shapes exactly as the frozen spec states them,
rather than inventing a third rule to make the prose's claim true, since TASK.md's own allow-list text
is the part that is actually pinned and testable, and widening it (e.g., "any `catalog_name = lake`
regardless of schema") is exactly the kind of judgment call the spec asks me not to make unilaterally.

The practical effect is identical either way: `lake.x.parquet` is still refused, exit 1, nothing run —
it falls into the allow-list's third bullet ("anything else is refused") instead of the first, so the
printed message is `ERROR,input,lake.x.parquet,not a lake table or an extract -- use lake.<table> or
extract_table('<name>')` rather than the `no such table in the lake at <root>` text AC7 quotes for this
case. Both are refusals with the same safety property; only the exact wording differs from AC7's
literal expectation.

### 2. Mutation 4's own proof query does not actually exercise the statement-count guard

TASK.md's mutation 4 says: "Drop the statement-count guard → AC7's `SELECT 1; DROP TABLE
lake.manifest` with `-Save x` **drops `lake.manifest` in `<L>`**". Measured directly: this exact query
is refused at an *earlier*, unrelated guard regardless of whether the statement-count check is present
— `json_serialize_sql` itself returns `{"error":true,"error_message":"Only SELECT statements can be
serialized to json!"}` for **any** batch containing a non-SELECT statement, not just a single DROP
alone. I confirmed this by running the exact decoy against a version of `cross-query.ps1` with the
statement-count guard entirely removed (mutant 4, replaced with `if ($false)`): it is still refused,
verbatim `ERROR,parse,Only SELECT statements can be serialized to json!`, because my code checks
`$tree.error -eq $true` unconditionally, before ever consulting `$statements.Count`.

This means TASK.md's specific proof-of-mutation scenario for item 4 cannot actually demonstrate the
vulnerability the guard protects against — dropping the guard alone never lets this particular decoy
through, because a separate guard (the parser's own SELECT-only restriction, which mutation 4 does not
touch) already blocks it.

The underlying vulnerability the statement-count guard protects against is real, however, and I
demonstrated it with a query the spec did not name: two syntactically valid `SELECT` statements (so
`json_serialize_sql` succeeds and returns a 2-length `statements` array, and no other guard fires) —
`SELECT * FROM extract_table('parent_projects'); SELECT count(*) FROM '<X>/parent_projects/*.parquet'`.
My classification code only ever inspects `$statements[0]` (`Get-AllNodes -Obj $statements[0]`), so
with the guard removed, the *second* statement's raw file read is never scanned by the allow-list at
all — and since the whole `$queryText` is embedded verbatim into the run script, **both** statements
execute. Measured: `RESULT,rows=15314` (the raw parquet file's own row count), exit 0 — the file was
read, unscanned, unrefused. Against the real script (guard intact): `ERROR,parse,expected exactly 1
SELECT statement, found 2`, exit 1.

I did not run the literal `DROP TABLE lake.manifest` decoy against a real lake at all, in either
direction, since I confirmed *both* the real script and the guard-dropped mutant refuse it identically
(via the parse-error guard) before it could ever reach a `-Save` write — there was nothing destructive
left to prove or guard against for that specific query shape, and doing so would have meant an
unnecessary `DROP TABLE`/rebuild cycle against a scratch lake for a scenario that turned out to be
inert either way.

## Concerns

- **AC1's 2 s budget is tight in this environment, for reasons unrelated to the design.** Direct
  measurement: a bare `powershell -NoProfile -Command "exit 0"` costs ~650 ms of pure process-startup
  overhead here (well above the ~270 ms this machine class typically shows), and a single
  write-then-delete of a small `.sql` scratch file costs ~155 ms + ~82 ms ≈ 237 ms (measured directly,
  isolated from DuckDB) — almost certainly antivirus real-time scanning of newly created files, not
  DuckDB or PowerShell themselves (a bare `SELECT 1` DuckDB invocation measured 110–170 ms). The
  initial implementation issued 7 DuckDB subprocesses for AC1's query (parse, one per-extract registry
  call, a separate contract/saved/refused/now-UTC lookup, and the run) and measured 5–15 s per
  invocation in a tight loop — far over budget. I restructured the read-only path to merge per-table
  lake dating into the *same* DuckDB process as the run itself (justified as safe: dating there is
  read-only and race-free, so doing it inside the run's own process rather than a textually-earlier
  process changes nothing about correctness — see the header comment in `cross-query.ps1`), cutting
  AC1's query down to 3 DuckDB processes (parse, one registry call, the merged dating+run). Repeated
  sampling after this change showed 1.3–1.8 s consistently, with two earlier out-of-band measurements
  (before the final version of the merge, and once immediately after a `-Save`-heavy sequence) at
  2.1–2.5 s. I believe the current 3-process design is close to the practical minimum for this query
  shape without weakening D1 (ages must be computed and printed unconditionally) or D3 (every input
  must be classified before anything runs), but I cannot fully rule out this environment's per-process
  overhead pushing an occasional run over 2 s. A verifier re-running AC1 several times and reporting
  the spread, rather than a single sample, would give a truer picture than either of us relying on one
  number.
- **A real, unrelated bug found and fixed along the way**: `@(<pipeline> | ConvertFrom-Json)` — the
  array subexpression operator wrapped directly around a pipeline ending in `ConvertFrom-Json` —
  silently collapses a multi-element JSON array into a single object whose properties become
  parallel arrays, on this PowerShell 5.1 build (`5.1.26100.9444`), measured directly and reproduced
  in isolation. Assigning the `ConvertFrom-Json` result to a variable first, then wrapping *that*
  variable with `@()`, is unaffected. This bit the `SAVED` line's `inputs` parsing (AC5's re-query
  threw `Exception calling "Parse" with "2" argument(s): "String was not recognized as a valid
  DateTime."` before the fix, because `$oldestMaterializedAt` ended up holding both input records'
  `materialized_at` values space-joined into one unparseable string). Fixed by splitting the
  assignment (see the `NOTE:` comment at the fix site in `cross-query.ps1`). I did not find this
  pattern anywhere else in the script (checked every `@(...)` occurrence).
- **`lake.manifest`'s `source_path` and `lake.join_manifest`'s `inputs` can both contain literal
  commas** — this repo's own live workbook path contains `"...\Clayco, Inc\..."`, and a saved join's
  `inputs` JSON is comma-dense by construction. The materialize.ps1/lake-status.ps1 label/CSV
  convention (`.mode csv` + a naive `-split ','`) is unsafe for reading either field back, so
  `cross-query.ps1` uses `.mode json` (via `Invoke-DuckdbJsonBatch`) for every lake-dating read
  instead — real, comma/quote-safe JSON parsing throughout, never the naive split. I did not touch
  `materialize.ps1`/`lake-status.ps1` themselves (out of scope, and they never read these two fields
  back through that convention today, so they are not exposed to this).
- **`git status --short` after this round** shows exactly the six expected files (`README.md`,
  both `SKILL.md` files, both new `examples\*.sql` files, `tools\cross-query.ps1`) — no stray mutant
  or debug files were left behind; each was created inside `tools\` only for the duration of its own
  test and removed immediately after (verified after every single one).
