# RESULT-1 -- item 3b: Snowflake extracts through the Python connector

Branch `item3b-python-connector`. Scratch extract root `$X` = `%TEMP%\sf3b\X`; `$W` = this worktree.
All sf.py calls run via `Start-Process py -3.12 ...` with separate stdout/stderr files, 180 s cap;
`.sql` files written with `[IO.File]::WriteAllText`. No sign-in prompt appeared (no `Initiating login request`).

## Files changed
- `tools/sf.py` (new): `query` (read-only guard, CSV, UTC `Z` datetimes, utf-8-sig read, stdout UTF-8/LF,
  connect inside `redirect_stdout(sys.stderr)`) and `unload` (COPY INTO @~ / GET / QUERY_HISTORY_BY_SESSION
  lookup with 5x1 s retry / REMOVE in `finally` with `removed=<n>` on stderr / JSON report).
- `skills/snowflake-extract/SKILL.md`: `allowed-tools: Bash`; new "Running Snowflake SQL" section;
  Materialize steps 5-7 and 9 collapsed into one `sf.py unload` step (step 8 text unchanged; `--project-id`
  comes from `list-extracts`' `project-id:` line); steps 2 and 4 and the Read-section probe say to run through
  `sf.py query`; step 1 no longer pre-creates `<name>.new` (unload does).
- `RESULT-1.md`.

## Acceptance checks
**AC1 PASS.** `--connection NO_SUCH_CONNECTION query` on `COPY INTO @~/x FROM (SELECT 1)` and on
`-- comment\nDELETE FROM t`: both exit=2, stderr
`ERROR: sf.py query only runs SELECT/WITH/SHOW/DESCRIBE; use the unload mode for COPY/GET/REMOVE`, stdout empty
(no connection attempted).

**AC2 PASS.**
- SHOW TABLES: 2 lines; header contains `rows`,`bytes`; line 2 rows=42257 (bytes 7463936).
- LAST_ALTERED: header `LA`, value `2026-10-06T21:44:26.222000Z` (matches regex).
- COLUMNS: 108 lines; 2 `TIMESTAMP_LTZ` (`START_DATE`, `FINISH_DATE`).

**AC3 PASS.** Name `ac3_dt_projects`, `--project-id verify-3b`, query projected from AC2's 107 columns
(2 LTZ -> `CONVERT_TIMEZONE('UTC', "<col>")::TIMESTAMP_NTZ AS "<col>"`).
- unload exit 0; JSON: `row_count` 42259, `output_bytes` 5122492, `runtime_seconds` 0.472,
  `files` = 7 local names (`data_0_0_0.snappy.parquet` ...); local dir held 7 parquet totalling 5122492 bytes.
- stderr `removed=7` == len(files).
- publish-extract: `published C:\Users\woodsonp\AppData\Local\Temp\sf3b\X\ac3_dt_projects`.
- sidecar: role `CLYCO_PWRUSR_COST_MGMT_GROUP`, warehouse `WH_POWER_USERS_XS`, database `DB_CONTROL_TOWER`,
  connection `DATAHUB`, runtime_seconds 0.472, source_rows [42257], source_last_altered [`2026-10-06T21:44:26.222000Z`].
  (source_rows/last_altered were taken from AC2's probes; the dynamic table had gained 2 rows by the unload, so
  `row_count` 42259 differs from `source_rows` 42257 -- expected, the spec says not to pin it.)
- read-back: DuckDB `count(*)` = 42259 = sidecar `row_count`.
- list-extracts: `name=ac3_dt_projects age_minutes=0 row_count=42259 size_bytes=5126781 bytes_check=AGREES`.

**AC4 PASS.** `describe` of new extract vs real `dt_projects` extract (read only): both 107 columns; type lists
byte-identical (SHA-256 of the two `column_name,column_type` listings equal `1D709FDC...43B0`); START_DATE and
FINISH_DATE are `TIMESTAMP` in both.

**AC5 PASS.** unload of `SELECT "START_DATE" FROM ...DT_PROJECTS LIMIT 1`: exit=1; stdout empty; stderr
`removed=0` then `100171 (22000): Error encountered when unloading to PARQUET: TIMESTAMP_TZ and LTZ types are not supported for unloading to Parquet. value get: TIMESTAMP_LTZ`; `--dest` not created (no parquet).

**M1 PASS (mutation fails, revert passes).** In `$W`, a second `connect()` for the history lookup:
exit 0, JSON without `runtime_seconds`, stderr `WARNING: no QUERY_HISTORY_BY_SESSION row for query id
01c78e9e-... after 5 tries; runtime_seconds omitted` and `removed=8`. After `git checkout -- tools/sf.py`
(worktree clean): re-run gives `runtime_seconds` 0.312, `removed=8`.

## Deviations
- First AC3 unload run (before commit 4c948bd) returned `files` as stage-relative paths
  (`verify-3b/ac3_dt_projects__.../data_0_0_0.snappy.parquet`), not local file names as the spec says. Fixed
  with `os.path.basename` and AC3 re-run from scratch; the results above are from the re-run. The first run's
  stage was also cleaned (`removed=7`).
- The sidecar JSON for AC3 was assembled by hand in PowerShell (the spec leaves its construction to the model).
- Final AC "Phil" command not run (it is Phil's).

## Not done
Nothing in the spec.

## Concerns
- Windows git warns LF->CRLF for `tools/sf.py` (autocrlf); harmless for Python.
- `source_rows` was probed before the unload; on a dynamic table the two can differ, which would make the
  first freshness probe look changed. Not a bug in this item.
- Mutation did leave 2 extra connector sessions open until process exit; irrelevant outside M1.
