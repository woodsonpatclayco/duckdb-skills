# VERIFY-1 — independent verification of item 3b (commit 81ceeff)

**Who and where.**
- **Verifier:** the `verifier` agent.
- **Worktree:** a throwaway one, `$W`, at `…\scratchpad\verify-item3b`, detached at `81ceeff`.
- **Scratch extract root:** `%TEMP%\v3b\X`.
- **Who wrote this file:** the verifier has no write tool, so the main session saved its
  report here.

**How it ran:**
- **Capture and timeout:** every `sf.py` call ran through `Start-Process` with separate
  stdout and stderr files and a 180 s timeout.
- **Sign-in:** no `Initiating login request` appeared in any stderr.

**Tree gate:**
- `git -C $W status --short` was empty, after the M1 revert and after the last run.
- Nothing ran in the main checkout, and nothing was written under the real
  `~\.duckdb-skills\…\extracts\`. The real `dt_projects` was read only.

| Check | Actual (quoted) | Verdict |
|---|---|---|
| AC1 | `sf.py --connection NO_SUCH_CONNECTION query` on `COPY INTO @~/x FROM (SELECT 1)` and on `-- comment` / `DELETE FROM t`: exit 2, stderr `ERROR: sf.py query only runs SELECT/WITH/SHOW/DESCRIBE; use the unload mode for COPY/GET/REMOVE`. Control `SELECT 1` with the same bad connection: exit 1, `Invalid connection_name 'NO_SUCH_CONNECTION'`, so the guard fires before `connect` | PASS |
| AC2 | SHOW TABLES: 2 lines, header has `rows,bytes`, rows `42259`. LAST_ALTERED: `LA` / `2026-10-06T21:49:20.833000Z`. Columns: 108 lines, `START_DATE,TIMESTAMP_LTZ` and `FINISH_DATE,TIMESTAMP_LTZ`; 0 CR bytes (LF only) | PASS |
| AC3 | Followed the new SKILL.md literally; projected query from AC2's 107 columns. `sf.py unload --name ac3_dt_projects --project-id verify-3b --database DB_CONTROL_TOWER …`: exit 0, `{"stage_path": "@~/duckdb-skills/verify-3b/ac3_dt_projects__8a911c1e/", "row_count": 42259, "output_bytes": 5229002, "runtime_seconds": 0.322, "files": [8 names]}`, stderr `removed=8`. `published …\v3b\X\ac3_dt_projects`. Sidecar: role `CLYCO_PWRUSR_COST_MGMT_GROUP`, warehouse `WH_POWER_USERS_XS`, database `DB_CONTROL_TOWER`, connection `DATAHUB`, runtime 0.322, `source_rows [42259]`, `source_last_altered ["2026-10-06T21:49:20.833000Z"]`. DuckDB count 42259 = sidecar. `list-extracts`: `bytes_check=AGREES` | PASS |
| AC4 | `DESCRIBE` of the new extract and the real 2026-09-24 `dt_projects`: both 107 columns, `cmp` IDENTICAL; `START_DATE`/`FINISH_DATE` are `TIMESTAMP` in both | PASS |
| AC5 | Unprojected `START_DATE` unload: exit 1, stdout empty, stderr `removed=0` then `100171 (22000): Error encountered when unloading to PARQUET: TIMESTAMP_TZ and LTZ types are not supported for unloading to Parquet. value get: TIMESTAMP_LTZ`; dest not created | PASS |
| M1 — second connection for history | exit 0, JSON without `runtime_seconds`, stderr `WARNING: no QUERY_HISTORY_BY_SESSION row for query id … after 5 tries; runtime_seconds omitted`, `removed=7`. After revert: `"runtime_seconds": 0.361` | PASS (fails, then passes) |

**`sf.py` implements decisions 1–3 as written:**
- **Reading SQL:** `utf-8-sig`.
- **Output:** stdout reconfigured to UTF-8/LF, and `lineterminator='\n'`.
- **Sign-in:** `redirect_stdout(sys.stderr)` around `connect`.
- **One statement per call:** `cursor.execute` only.
- **COPY:** strips a trailing `;` and wraps the query in newlines.
- **History lookup:** by query id, database-qualified, `SUCCESS`-only, 5 retries.
- **Cleanup:** `REMOVE` in `finally`, which prints `removed=<n>`.

**Scope:** the diff from `40665e9` is only `RESULT-1.md`, `skills/snowflake-extract/SKILL.md`
and `tools/sf.py`. **Claims against RESULT-1:** all reproduced. The numbers differ only because
`DT_PROJECTS` is a dynamic table that moved.

**Concerns, none blocking:**
1. **`publish-extract.ps1` accepted a malformed sidecar.** `source_last_altered` held objects
   instead of strings, built by the verifier's own harness mistake, and the tool exited 0.
   The validator is lax on array element types. This is outside 3b. The AC3 numbers above
   come from a second, clean run.
2. **SKILL.md step numbering jumps from 5 to 8** after steps were merged. Cosmetic.
3. **`source_rows` can differ from `row_count`** on a dynamic table, because it is probed
   before the unload. The spec already leaves it unpinned.

**Overall verdict: SHIP.**
