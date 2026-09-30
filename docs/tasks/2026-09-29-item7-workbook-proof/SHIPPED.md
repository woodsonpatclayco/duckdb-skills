# SHIPPED — Workbook proof, routing, and the extension non-goal (item 7)

Shipped 2026-09-29. PLAN-4 §7, the last item on the workbook track. Verified SHIP on round 1 in a
disposable worktree at `b6d81a5`, merged as `cfcaeec`. Only item 8 (the cross-source join) remains.

## The point, as a before/after Phil can observe

**Before:** nothing showed that a materialized sheet survives its workbook going away, and nothing
could tell whether any tool had loaded the Snowflake extension — which is installed on this machine with
autoload on. A session asked about `Data Extracts.xlsm` got **1 row containing a binary blob**.

**After:**

```
powershell -NoProfile -File tools\prove-requery.ps1
REQUERY,All_Sales_Data,source_rows=219,lake_rows=219,manifest_rows=219,workbook_present=false,PASS
REQUERY,Clayco_Job_Costs_from_GL,source_rows=62377,lake_rows=62377,manifest_rows=62377,workbook_present=false,PASS
REQUERY_SUM,Clayco_Job_Costs_from_GL,source=22498718519.96,lake=22498718519.96,PASS
LIVE_WORKBOOK,unchanged

powershell -NoProfile -File tools\prove-no-snowflake.ps1
EXT,<label>,…,PASS          × 14
SUMMARY,entrypoints=14,pass=14,fail=0,no_evidence=0,hung=0,forbidden=snowflake
```

Counts are computed per run, never pinned — the workbook moves (62,377 GL rows on 2026-09-29; PLAN-4
pinned 61,741).

## What shipped

- **`tools\prove-requery.ps1`** — copies the live workbook, rewrites both contracts to the copy,
  materializes into a scratch lake, **removes the copy**, then reads the lake in a fresh read-only
  process and compares row counts and the exact GL `JOB_COSTS` sum against figures taken from the source
  before removal.
- **`tools\prove-no-snowflake.ps1`** — puts a temporary `duckdb.cmd` first on PATH (process-local,
  never persisted). Every `duckdb` call gets a probe appended that writes
  `duckdb_extensions() WHERE loaded` to a side file **from inside that same process**. Runs 14 entrypoints
  (~250 calls), reports what each actually loaded, and kills any entrypoint past a 120 s budget as `HUNG`.
  `-Only`, `-Forbid`, `-BudgetSeconds` run the three controls (`control_load_fts`, `control_error`,
  `control_hang`).
- **`skills\read-file\SKILL.md`** — `.xlsm` now routes to `read_xlsx`, and a new "Excel workbooks"
  section tells a session to answer from the lake when a contract covers the sheet, and otherwise read
  with `sheet=`, `all_varchar`, `stop_at_empty = false`, cast money to `DECIMAL`, and say the types are
  unverified.
- **`skills\lakehouse\SKILL.md`** — one sentence: once materialized, the lake is where to answer
  questions about that sheet, and it does not need the workbook present.
- **`tools\materialize.ps1`** — a missing or locked workbook no longer aborts the remaining contracts.
  `SUMMARY` gains `,errored=<n>`, with `contracts = refreshed + skipped + refused + errored`.

## Why PLAN-4's wording was replaced, not followed

**Its extension check would have been fake.** "`duckdb_extensions()` shows no loaded `snowflake`" is
only true of the process that runs the query; every entrypoint is its own process. Mutation 2 proves
it: moving the probe into a separate process made an extension the call really loaded (`fts`)
invisible, and the positive control wrongly passed. **Detection is proven with `fts`, never
`snowflake`** — that extension has left an unkillable process needing a reboot
(`docs\duckdb-snowflake-findings.md`).

**"Point the contract at a nonexistent path" tests nothing.** Querying the lake never evaluates the
contract. The test removes the workbook itself.

**"Within budget" became a hang detector, not a speed gate.** The failure this non-goal exists for is a
process that never exits. Elapsed time is printed; nothing fails for being slow.

## What deliberately did NOT change

- **The `snowflake` extension is still installed** under `C:\Users\woodsonp\.duckdb\`, and autoload is
  still on. Outside this repo; removing it is Phil's call. Its files were confirmed byte- and
  timestamp-identical before and after.
- **`read_any` still reads the first sheet** of a workbook (`MetaData`, 2 rows, for `Data Extracts.xlsm`).
  Deliberate: the new section is what routes a session past it. Do not "fix" it by adding `sheet=`.
- **No new skill.** PLAN-4 §8's two-skill budget was already spent; routing extends `read-file`.
  `lakehouse`'s description is byte-identical.
- **The whole-lake `exit 1` paths in `materialize.ps1`** — catalog lock, lake-write failures — still end
  the run without a `SUMMARY`. Only the per-contract workbook paths continue.
- **Archived `SUMMARY` literals** under `docs\tasks\` were not edited. Re-running them now shows
  `,errored=0` appended — expected drift, not a regression. Nothing parses that line.
- **The bash `query` skill's sandbox is not probed** (bash skills do not run here, and the probe itself
  fails under `lock_configuration`).
- **The routing rule is guidance, not enforcement.** Nothing can compel a session to check
  `contracts\` first; the skill says so.
- `PLAN-4.md` (frozen) still carries two stale facts: 61,741 rows, and `VENDOR_NAME` inferring to 0.

## Corrections worth keeping

- **Inferred workbook types are data-dependent.** On 2026-09-23 `VENDOR_NAME` inferred DOUBLE and
  silently nulled to 0 of 61,741. On 2026-09-29 it inferred VARCHAR correctly (52,165) — but `JOB_COSTS`
  still sums as DOUBLE, `22498718519.95991` against the contract's exact `22498718519.96`. Which columns
  go wrong changes with whatever rows sit at the top of the sheet.
- **DuckDB strips backslashes from an unquoted dot-command path.** `.output C:\…\probe.txt` silently
  wrote nothing; the forward-slash form works. The first shim produced `probe_missing` on every call.
- **`Start-Process -PassThru` with redirected output does not reliably return `.ExitCode`** in
  PowerShell 5.1. The tool uses `System.Diagnostics.Process` directly.
- **`%RANDOM%` collides under load.** Mutation 6 (no existence retry) reproduced on the first run:
  202 calls, **32** distinct probe paths, 25 `probe_missing`. The shim retries `if exist`.
- **Spec defects, both mine:** `control_hang`'s SQL lacked its column alias (`range(2000000000) t(i)`),
  so it failed to bind instead of hanging; and AC10 asked for a count the pinned `EXT` line had no field
  for — exposed on the `-Verbose` stream.
- **AC9 for `run-compat-tests` was closed by the main session**, not the verifier, whose harness hit
  `Access denied`: shimmed and unshimmed output byte-identical across 63 lines and 100 `-init` calls
  (addendum in `VERIFY-1.md`).

## Known residuals

- A `duckdb` call that **fails** stops before its probe, so it is counted `unprobed`, not clean. An
  entrypoint passes only with at least one probed call. `run-compat-tests` has 50 designed failures.
- The hyphenated-contract-filename bug in `materialize.ps1` (unquoted SQL identifier) is still open.
- `-- @ assert` (space after `@`) is still silently ignored (item 5b residual).
