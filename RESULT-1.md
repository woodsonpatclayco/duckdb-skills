# RESULT-1 — Item 3a: undo the Cortex Code adaptations

Branch `item3a-undo-cortex`, code commit `1ca79bc` (from b54e9f7). `$W` = this worktree, `$B` = throwaway
worktree at b54e9f7, `$L` = scratch lake under %TEMP% (not the real lake).

## Files changed
- `skills/query/duckdb-compat.sql` — only `xl_date()` kept, 3-line header added.
- `skills/query/duckdb-compat.md` — rewritten, 24 lines (xl_date, delivery, hash key, history note).
- `skills/query/SKILL.md` — deleted lines 164-200 (dialect section); added the "Excel serial dates" paragraph.
- `skills/query/duckdb-compat-tests.csv`, `tools/run-compat-tests.ps1` — deleted.
- `tools/prove-no-snowflake.ps1` — removed `run-compat-tests` and `read-memories:search` entrypoints and the two env blocks; header sentence (line 29) reworded; `14` -> `12`.
- `skills/read-memories/SKILL.md` — upstream (7feda8e) version with the three Windows fixes and new description; five `.sql` files deleted.
- `skills/snowflake-extract/SKILL.md`, `skills/snowflake-extract/registry.sql` — dropped the two precedent pointers.
- `README.md` — line 78 replaced; line 195 replaced by "`read-memories` is adapted for Windows paths in this fork."

## Acceptance checks
**AC1 — PASS.** `$W`: `xl_date(45000)` -> `2023-03-15`, `DATE`; `SELECT IFF(true,1,2)` -> `Catalog Error: Scalar Function with name iff does not exist!` (exit 1). Function list at `$W`: `xl_date`. Control `$B`: IFF returned `1`, exit 0; function list: `CHARINDEX,DIV0,DIV0NULL,EQUAL_NULL,IFF,LEN,NULLIFZERO,NVL,NVL2,REGEXP_SUBSTR,TO_NUMBER,TO_VARCHAR,TRY_TO_DATE,TRY_TO_NUMBER,UUID_STRING,ZEROIFNULL,xl_date` (17).

**AC2 — PASS.** `$W`: no output, `$LASTEXITCODE` = 1. Control `$B`: 140 hit lines (spec said about 150), exit 0.

**AC3 — PASS.**
- Baseline `$B`: `All_Sales_Data,REFRESHED,484,reason=no_manifest`, `CHECKS_PASSED,true`; `Clayco_Job_Costs_from_GL,REFRESHED,57777,reason=no_manifest`, `CHECKS_PASSED,true`.
- After `$W`: both `REFRESHED`, `reason=compat_sha256` (no `contract_sha256`, no workbook_* reasons), `CHECKS_PASSED,true`; `SUMMARY,contracts=2,refreshed=2,skipped=0,refused=0,forced=0,errored=0`.
- `EXCEPT ALL` both directions: All_Sales_Data after 484 / base 484 / 0 / 0; Clayco_Job_Costs_from_GL after 57777 / base 57777 / 0 / 0.

**AC4 — PASS.** Ran the skill's query (as an LF .sh via Git Bash, `-csv`, cwd = the main repo folder, read-only).
- `--here`: SEARCH_PATH `C:/Users/woodsonp/.claude/projects/C--Users-woodsonp-Claude-Dev-duckdb-skills/*.jsonl`; 40 rows (LIMIT 40), all `project = C--Users-woodsonp-Claude-Dev-duckdb-skills`.
- No `--here`: 40 rows (LIMIT 40, so "at least as many" is 40 vs 40): 39 from `C--Users-woodsonp-Claude-Dev-duckdb-skills`, 1 from `C--Users-woodsonp`.
- Unlimited per-project counts (GROUP BY variant): `C--Users-woodsonp-Claude-Dev-duckdb-skills` 64, `C--Users-woodsonp` 1.
- Description contains `shared memory` and `Claude Code`.

**AC5 — PASS.**
- `$B`: `SUMMARY,entrypoints=14,pass=13,fail=1,...` exit 1. `$W`: `SUMMARY,entrypoints=12,pass=11,fail=1,...` exit 1.
- All 12 shared labels have the same verdict (check-contract:GL, check-contract:All_Sales_Data, run-assertions, materialize:1, materialize:2, lake-status, lake-status:history, list-extracts, extract-status, extract-decide, make-truncation-fixtures = PASS; gl-facts = FAIL in both).
- Only differences: `run-compat-tests` and `read-memories:search` (both PASS at `$B`, absent at `$W`).

**M1 — PASS (mutation caught, then reverted).** Appended the IFF macro line: `SELECT IFF(true,1,2)` returned `1`, function list `IFF,xl_date` — AC1 would fail. After `git checkout -- skills/query/duckdb-compat.sql` in `$W`: Catalog Error for `iff` again, function list `xl_date`; tree clean.

## Deviations
- AC4's "at least as many rows without `--here`" is satisfied only as 40 vs 40 because the skill's query has `LIMIT 40`; the unlimited counts above are the stronger evidence.
- AC2 control had 140 hits vs "about 150".

## Not done
Nothing.

## Concerns
- `gl-facts` fails at both commits (known, out of scope).
- README lines 5-10 (fork note) still says read-memories searches Cortex Code logs; left for item 4 as specified.
- `docs\duckdb-snowflake-findings.md` and `.cortex-plugin` untouched, as specified.
