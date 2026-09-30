# SHIPPED — The cross-source join (item 8)

Shipped 2026-09-30. PLAN-4 §8, **the last item of PLAN-4**. Verified SHIP on round 1 in a disposable
worktree at `560ce47`, merged as `7d76778`. The plan archives with this item — see
`docs\plans\2026-09-30-local-sql-surface\INDEX.md`.

## The point, as a before/after Phil can observe

**Before:** a Snowflake extract and a workbook sheet could only meet in a hand-written query with a
hard-coded Parquet path. Nothing reported how old either input was, so a join could silently use a
six-day-old extract.

**After:**

```
powershell -NoProfile -File tools\cross-query.ps1 -Sql examples\job-costs-by-parent-project.sql
EXTRACT,parent_projects,age_minutes=8599,window=60,stale=true,rows=15314,materialized_at=2026-09-24 18:54:17
LAKE,Clayco_Job_Costs_from_GL,age_minutes=…,materialized_at=…,workbook_changed_since=false
RESULT,rows=345,elapsed=…,extract_ages=parent_projects:8599,stale_inputs=1
PARENT_PROJECT_NUMBER,PARENT_PROJECT_NAME,PARENT_WIP_STATUS,gl_rows,job_costs
…20 rows…
```

GL job costs by parent project: **345 projects, 62,603 GL rows, 0 unmatched**, `SUM(JOB_COSTS)` identical
on both sides (`22505496119.72` on 2026-09-30). Whole command **~1.1 s** (five verifier samples,
1.08–1.14 s), against PLAN-4's 2 s process budget.

## What shipped

- **`tools\cross-query.ps1`** — runs one SELECT across `lake.<table>` and `extract_table('<name>')`.
  Dates every input **before** running: the extract's age and `stale` flag from its sidecar via
  `registry.sql`; for a lake table, the effective `lake.manifest` row and whether the workbook's
  `LastWriteTime` has moved since. Prints `EXTRACT` / `LAKE` / `SAVED` lines, then `RESULT` with
  `stale_inputs`, then the first rows. **Stale is reported, never refused** (PLAN-4:489).
- **`-Save <table>`** — writes the result as a real DuckLake table and a row in a new
  **`lake.join_manifest`**: the query, its SHA-256, and every input's version — the extract's
  `materialized_at`, the contract's `lake.manifest` `run_id`, or a saved join's `run_id`. Re-querying a
  saved join prints its **oldest input's** age, not the save's, and works with the extract deleted.
- **`examples\job-costs-by-parent-project.sql`** and **`examples\job-costs-unmatched.sql`** — the worked
  example, and the `ANTI JOIN` check a stale extract fails first (a project created in Snowflake after the
  extract appears there).
- **`README.md`** — "Joining a Snowflake extract to a workbook sheet": a clean-shell walkthrough, the
  freshness rule in plain words, and the two patterns.
- One pointer paragraph each in **`skills\snowflake-extract\SKILL.md`** and **`skills\lakehouse\SKILL.md`**.

## The security boundary, and why it is an allow-list

The runner only accepts inputs it can date, so it must know every input. It reads them from DuckDB's own
parse tree (`json_serialize_sql`), which ignores names in comments and strings — a regex would not
(mutation 1). But **a quoted file path and a CTE name are the same node shape**, and
`parent_projects.parquet` is a *qualified* name that triggers a file read. So every `BASE_TABLE` must be
provably a lake table, or a CTE by name, or it is **refused**. The first draft of this spec said to ignore
unqualified nodes; the review measured that as a hole, and mutation 1b re-creates it (`decoy_read=15314`,
exit 0).

The verifier tried to get a file read past it with `LATERAL`, `UNION`, `EXISTS`, paths in join
subqueries, a CTE shadowing a lake table, `glob`/`read_blob`/`sniff_csv`, `read_csv` in a subquery,
`COPY`/`ATTACH`/`PRAGMA`/`SET`, `main.extract_table(...)`, a second statement after a comment, and 3- and
4-part `lake.main.…` names. Every one was refused, exit 1, no file content returned.

## What deliberately did NOT change

- **`lake.manifest`, `materialize.ps1` and its four-way freshness key.** Input versions for saved joins
  live in the new `lake.join_manifest` instead — Phil's decision, 2026-09-29. **PLAN-4:674-675 said item
  6's manifest already recorded an extract's `materialized_at`; it never did.** This item is where that
  claim became true, in a different table.
- **The runner cannot refresh an extract.** Refreshing needs `snowflake_sql_execute`, an agent tool; the
  README and skill text say to refresh through the `snowflake-extract` skill first when the work is
  staleness-sensitive.
- **Both extracts were left ~6 days old** on purpose: the checks depend on it. Snowflake had 15,322 parent
  projects on 2026-09-29 against the extract's 15,314.
- **Hand-written joins are still possible.** Routing them through the runner is guidance, not enforcement;
  the skill text says so.
- **No new skill.** Both skill descriptions are byte-identical to `main`; PLAN-4 §8's two-skill budget was
  already spent.
- **No retention or cleanup of saved joins** (PLAN-4:281).
- `PLAN-4.md` stays frozen, with its stale facts (61,741 GL rows; the `lake.manifest` claim).

## Corrections worth keeping

- **Quoted identifiers are case-insensitive in DuckDB.** `-Save clayco_job_costs_from_gl` would replace the
  contract table `Clayco_Job_Costs_from_GL`; every name comparison is `lower()` on both sides. Mutation 4b
  shows the contract table going from 62,603 rows to 15,314.
- **`lake.manifest.source_mtime` is local time**, second-truncated (`materialize.ps1:305`) — comparing it
  against `LastWriteTimeUtc` would flag every table as changed.
- **The real lake holds a REFUSED manifest row** with `row_count NULL`; the effective row filters
  `(checks_passed OR forced)`, as `lake-status.ps1 -AsOf` does and its default mode does not.
- **`registry.sql` exits 0 on a name mismatch** — its `reason` column is what refuses.
- **A trailing `--` comment swallows an appended `;`** — embedded query text always ends in a newline.
- **`lake_snapshot_id` must be captured after the save's `CREATE OR REPLACE`** — earlier, it names a
  version at which the table does not exist.
- **PowerShell 5.1 `@(… | ConvertFrom-Json)` collapses a multi-element JSON array.** Found by the
  implementer; the verifier confirmed every such parse in the runner uses the split-assignment form.
- **The live workbook path contains a comma** (`Clayco, Inc`), which broke comma-splitting of
  `source_path`; the lake-dating reads use JSON output.
- **Spec defects, mine:** `lake.x.parquet` is refused by the "anything else" rule, not the existence check
  the spec named (its node puts `lake` in `catalog_name` and `x` in `schema_name`); mutation 4's specified
  query was already blocked by the parser, so the implementer demonstrated the statement-count guard with a
  second SELECT that would otherwise have run unvalidated; mutation 7's leaked message is `registry.sql`'s
  `read_json` error, not the `read_parquet` one predicted.

## Known residuals

- `lake.main."<nonexistent name>"` prints raw JSON fragments instead of a clean error line when the run
  fails. Cosmetic; nothing is read. Found by the verifier.
- A lock during `-Save` surfaces at the collision check's read-only attach, not the save attach — reported
  verbatim either way, exit 1, no retry.
- The hyphenated-contract-filename bug in `materialize.ps1` is still open (items 5b, 7).
- `-- @ assert` with a space after `@` is still silently ignored (item 5b).
