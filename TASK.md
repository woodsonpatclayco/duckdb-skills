Plan: PLAN-4.md
Serves: **Once a workbook sheet is in the lakehouse, you can keep asking it questions with the workbook
closed, moved, or mid-sync — and nothing in this project can quietly load the Snowflake extension that
once needed a reboot to kill.** Also: a session asked about `Data Extracts.xlsm` is told to answer from
the lake, not from a raw read that currently returns the wrong thing.

# Item 7 — Workbook proof, routing, and the extension non-goal

PLAN-4 §7 (lines 615-629). The last item on the workbook track; item 8 (the cross-source join) follows.

Four parts. **A** and **B** are new proof tools Phil can re-run. **C** is skill text. **D** is a bug in
`tools\materialize.ps1` found while measuring A. **D is not in PLAN-4 §7; Phil decided on 2026-09-29 to
keep it in item 7**, knowing it changes shipped item-6 behaviour (a missing or unreadable workbook no
longer aborts the remaining contracts, and `SUMMARY` gains `errored=`).

## Measured facts this spec rests on — all taken 2026-09-29 on this machine

**The `snowflake` extension is installed here, and autoload is on.** `duckdb_extensions()`:
`snowflake | loaded=false | installed=true | REPOSITORY | community | b61f5ad`, file
`C:\Users\woodsonp\.duckdb\extensions\v1.5.5\windows_amd64\snowflake.duckdb_extension` (22,533,654 bytes),
alongside `libadbc_driver_snowflake.so` (55,990,019). `autoload_known_extensions = true`,
`autoinstall_known_extensions = true`, `allow_community_extensions = true`. So "never loaded" is a live
risk, not a formality: an `ATTACH … (TYPE snowflake)` anywhere would load it. **Nothing in this task may
load it, including as a positive control** — `docs\duckdb-snowflake-findings.md` records it leaving an
unkillable process holding a driver lock that needed a reboot. `fts` (core) is also installed and
unloaded, which is why the positive control below uses it.

**PLAN-4 §7's check, as written, cannot prove the non-goal.** "`SELECT extension_name FROM
duckdb_extensions() WHERE loaded` returns no `snowflake` row" is only true of the process that runs it.
Every entrypoint here is its own short-lived `duckdb` process, so running that query in a fresh process
proves nothing about what any entrypoint loaded. The query must run **inside each entrypoint's own
process**. Measured that this is achievable without editing any tool:

| measurement | result |
|---|---|
| `duckdb -csv -f body.sql -c ".output <log>" -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded ORDER BY 1;"`, where `body.sql` is `LOAD ducklake; SELECT 7 AS body;` | exit 0, stdout `body \| 7` only, log = `autocomplete,core_functions,ducklake,icu,json,parquet,shell` — **the probe runs after the file, in the same process, and sees what the file loaded** |
| `-init <file> -f <file> -c <probe>` (reviewer) | init file runs first, `-f` second, probe last, with the file's loads visible |
| probe after a statement that errors | exit 1, **probe never runs** — `duckdb -f` stops at the first error |
| `duckdb -version -c "SELECT 42"` (reviewer) | prints `v1.5.5 (Variegata) d8cdaa33fd`, **ignores the `-c`**, exit 0 |
| probe after `SET enable_external_access=false; SET lock_configuration=true;` | **exit flips 0 → 1**: `Permission Error: Cannot access directory "…\.duckdb\extensions\v1.5.5\windows_amd64"` |
| a `duckdb.cmd` in a directory prepended to `$env:PATH` | `Get-Command duckdb` resolves to it; `& duckdb …` calls it; args pass through; exit 0 and 1 both propagate |

Every `duckdb` call in `tools\` is `& duckdb …` resolved through PATH — no absolute `duckdb.exe`, no
`Start-Process`, no `cmd /c` — so a PATH shim intercepts all of them, including calls from nested
`powershell -File` children (reviewer). Arguments are flags and file paths only; SQL, including the
`Clayco, Inc` path, always travels inside files. No `tools\*.ps1` uses the sandbox settings; only the bash
`query` skill does, and bash skills do not run on this machine.

**Querying the lake does not read the contract, so "point the contract at a nonexistent path" tests
nothing.** The test that proves the `Serves:` claim is to make the **workbook itself** absent. Measured
end to end, scratch copy and scratch lake:

```
materialize (scratch copy)          MATERIALIZE,All_Sales_Data,REFRESHED,219,reason=no_manifest   exit=0
rename workbook away                workbook present? False
query lake (READ_ONLY, fresh proc)  LAKE_ROWS,219   MANIFEST_ROWS,219                             exit=0  0.15s
materialize again, workbook absent  MATERIALIZE,All_Sales_Data,ERROR
                                    ERROR,All_Sales_Data,could not read workbook at …\DataExtracts.xlsm (see output above)   exit=1
query lake again                    LAKE_ROWS,219   MANIFEST_ROWS,219                             exit=0
```

**Both shipped contracts read the same workbook**, and each contains its path **exactly once, in
forward-slash form** (`C:/Users/woodsonp/Clayco, Inc/Profit Plans - General/Analytics/Excel Exports Data
Warehousing/Domo/Data Extracts.xlsm`), zero times with backslashes (reviewer, both files).

**The workbook refreshed today.** GL is now **62,377** rows (PLAN-4 pinned 61,741; item 6 recorded
62,230). No check may pin a row count.

**`read-file` gives the wrong answer on this workbook, without warning.** Its `read_any` CASE
(`skills\read-file\SKILL.md:58`) lists `.xlsx` and `.xls` but not `.xlsm`, so `Data Extracts.xlsm` routes
to `blob_case`: **1 row, one `BLOB`**. With `.xlsm` routed, a bare `read_xlsx('<path>')` reads the first
sheet, `MetaData`: **2 rows, 2 columns**.

**Inferred types are data-dependent, and money is still wrong.** Bare
`read_xlsx(<path>, sheet='Clayco_Job_Costs_from_GL')` today, against the contract view:

| | inferred read | contract view |
|---|---|---|
| `VENDOR_NAME` | VARCHAR, 52,165 non-null | VARCHAR, 52,165 |
| `GL_PERIOD` | DATE, min 2026-07-01 | DATE, min 2026-07-01 |
| `JOB_COSTS` | **DOUBLE**, sum `22498718519.95991` | **DECIMAL(18,2)**, sum `22498718519.96` |

PLAN-4 measured `VENDOR_NAME` inferring DOUBLE and silently nulling **0 of 61,741** on 2026-09-23. Today
it infers correctly. So inference flips with whichever rows sit at the top of the sheet.

**Measured run time of every entrypoint** (exit 0 each):

| entrypoint | seconds |
|---|---|
| `check-contract.ps1` GL / All_Sales_Data | 3.71 / 4.42 |
| `run-assertions.ps1` | 12.27 |
| `materialize.ps1` first / second (SKIP) | 16.23 / 1.59 |
| `lake-status.ps1` / `-History Clayco_Job_Costs_from_GL` | 0.62 / 0.34 |
| `list-extracts.ps1` / `extract-status.ps1 -Name parent_projects` (real root) | 0.82 / 0.64 |
| `run-compat-tests.ps1` | **24.15** (slowest; ~202 sequential `duckdb` calls) |
| `make-truncation-fixtures.ps1` | 0.60 |
| `duckdb -f checks\gl-facts.sql` | 12.19 |
| `duckdb -csv -f skills\read-memories\search.sql` (`DSK_KEYWORD=lakehouse`) | 1.63 |

`extract-decide.ps1` is not yet timed; measure it. It **does** launch `duckdb`
(`extract-decide.ps1:216`, `& duckdb -csv -f $registrySql`, whenever the sidecar exists).

**Nothing parses `materialize.ps1`'s `SUMMARY` line** (reviewer, `git grep "SUMMARY,"`):
`materialize.ps1:525` produces it; copies exist only as literal text in archived docs (item 6
`SHIPPED.md:25`, `VERIFY-1.md:64`, `RESULT-1.md:46,70,95,238,257`; item 5b `RESULT-1.md:372,382,417`).

## Decisions

**D1 — The budget is a hang detector, not a performance gate.** The failure this non-goal exists for is
a process that never exits. Each entrypoint gets a timeout — default **120 s**, about 5× the slowest
measured — and exceeding it is `HUNG`: the process tree is killed and the run fails. Elapsed time is
printed for every entrypoint so drift is visible, but nothing fails for being merely slow.

**D2 — Routing extends `read-file`; no new skill.** PLAN-4 §8 caps this plan at two new skills, and
`lakehouse` and `snowflake-extract` already spent both. `read-file` is also where the trigger lands.
`lakehouse`'s description stays exactly as it is.

**D3 — The routing rule is unenforceable, and the skill says so.** Nothing can compel a future session to
check `contracts\` first. Same precedent as the registry-first rule (`skills\read-memories\SKILL.md:15-18`,
PLAN-4:451-455). What *is* checkable is that the paths the rule sends a session down give the right
answer, and that the path it replaces gave the wrong one.

**D4 — A failed call is "no evidence", never "clean".** A `duckdb` call that exits non-zero stops before
the probe runs. Some entrypoints fail calls by design and still exit 0 (`run-compat-tests.ps1` runs rows
expected to hit a `Catalog Error`). Such calls are `unprobed`. An entrypoint passes only if **at least
one** call was probed and **no** probed call loaded a forbidden extension.

**D5 — No entrypoint relies on a default root.** `Resolve-ExtractRoot` and `Resolve-LakeRoot` key their
defaults on `git rev-parse --show-toplevel`, which in the verifier's worktree is a different, **empty**
project directory — and resolving it creates that directory as a side effect. So every extract and lake
entrypoint gets an explicit scratch root.

## A — `tools\prove-requery.ps1` (new)

Proves the `Serves:` claim for both shipped contracts, re-runnably, without touching the live workbook or
the real lake.

1. Record the live workbook's SHA-256 and `LastWriteTime` (live path:
   `C:\Users\woodsonp\Clayco, Inc\Profit Plans - General\Analytics\Excel Exports Data Warehousing\Domo\Data Extracts.xlsm`).
   **Read only.** `Copy-Item` it to `$scratchWb` inside a fresh scratch directory `$scratch` under
   `$env:TEMP`. **Hold `$scratchWb` in a variable; it is the only file this script may ever remove.**
2. Write scratch copies of **both** shipped contracts, same filenames (the filename is the lake table
   name), each with its `read_xlsx` path rewritten from the **forward-slash** live path to `$scratchWb` in
   forward-slash form. **Stop the run unless exactly one occurrence was replaced per contract** — a contract
   still pointing at the live workbook would let the rest of the test pass by reading the source it claims
   is absent.
3. **Before removal, read each contract's view directly from `$scratchWb`**: `count(*)` per contract, and
   `SUM(JOB_COSTS)` as VARCHAR for GL. This is the source-side figure the lake must match.
4. Materialize both into a fresh scratch `-LakeRoot` (`-Contract <scratch copy>`, once per contract).
   Require `REFRESHED` for both and exit 0.
5. **Remove `$scratchWb`** — first asserting it is under `$scratch`. **Never derive a path to remove,
   rename or lock from a contract's `read_xlsx` text:** under AC2's second mutation that text is the live
   workbook.
6. Measure `workbook_present` with `Test-Path $scratchWb` — never a literal. Then, in a **fresh** `duckdb`
   process, `ATTACH` the scratch lake `READ_ONLY` and read each table's `count(*)`, the GL
   `SUM(JOB_COSTS)` as VARCHAR, and each contract's manifest `row_count`.
7. Print, one line per contract:
   `REQUERY,<contract>,source_rows=<n>,lake_rows=<n>,manifest_rows=<n>,workbook_present=<bool>,<PASS|FAIL>`,
   plus `REQUERY_SUM,Clayco_Job_Costs_from_GL,source=<s>,lake=<s>,<PASS|FAIL>`. A `REQUERY` line is PASS
   iff the three counts are equal **and** `workbook_present=false`.
8. Re-read the live workbook's hash and mtime, and print one of:
   - `LIVE_WORKBOOK,unchanged` — both equal;
   - `LIVE_WORKBOOK,SYNCED,<old mtime>-><new mtime>` — mtime later: a SharePoint sync, drift, quoted, does
     **not** fail the run (item 6 AC20's rule, `docs\tasks\2026-09-25-item6-lakehouse-materialize\TASK.md:406-410`);
   - `LIVE_WORKBOOK,CHANGED` — hash differs at the **same** mtime: a write by this run. Fails.
9. Remove `$scratch`. Exit 0 iff every line is PASS and the live workbook is not `CHANGED`.

Never passes, or resolves to, the real lake.

## B — `tools\prove-no-snowflake.ps1` (new)

Runs every entrypoint with an in-process probe injected through a temporary PATH shim, and reports what
each actually loaded.

### The shim

A `duckdb.cmd` (ASCII) written to a fresh scratch directory, prepended to `$env:PATH` **in this script's
process only** — child `powershell` processes inherit it, nothing is persisted. The real `duckdb.exe` is
resolved by absolute path **before** the shim is prepended. For each call the shim:

1. chooses a probe path that does not exist yet — **retry while `if exist`**, and create it empty before
   invoking `duckdb.exe`. Every tool here calls `duckdb` sequentially, so check-then-create suffices. **Do
   not rely on `%RANDOM%` alone**: `cmd.exe` seeds it from the clock, and `run-compat-tests.ps1` makes
   several calls per second;
2. invokes the real `duckdb.exe` with the original arguments **followed by**
   `-c ".output <probe>" -c ".mode list" -c ".headers off" -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded ORDER BY 1;" -c ".output"`
   — the `.mode`/`.headers` lines make every probe file one extension name per line, whatever output mode
   the tool used (tools leave csv-no-header, csv-with-header, or JSON behind);
3. captures `%ERRORLEVEL%` into a variable **on the line immediately after** the `duckdb.exe` line;
4. **after** `duckdb.exe` returns, appends one line to the per-run call log:
   `<entrypoint label>|<exit code>|<probe path>|<args>`, the label taken from an environment variable the
   script sets per entrypoint;
5. exits with the captured code.

The probe's output **must never reach the tool's stdout** — `materialize.ps1`, `run-assertions.ps1`,
`run-compat-tests.ps1` and `check-contract.ps1` (via `ConvertFrom-Json`) all parse their `duckdb` output.

### Classifying calls

| condition | classification |
|---|---|
| args contain `-version` | `not_a_session` — decided **by argument**, never by outcome |
| probe file non-empty | `probed` |
| probe file empty, exit ≠ 0 | `unprobed` |
| probe file empty, exit = 0 | `probe_missing` — **fails the entrypoint** (a real probe failure) |

### Entrypoints

Every entrypoint runs with its working directory set to the repo root (`checks\gl-facts.sql` resolves
`.read` lines against it; `run-compat-tests.ps1` resolves its fixture, compat file and scratch dir against
it). Each entrypoint's stdout and stderr go to a scratch file, not to this script's output. Setup first:
`tools\make-extract-fixtures.ps1 -Root <scratch>\xfx` (absolute; setup only, never launches `duckdb`),
which lands its ages tree in `<scratch>\xfx\ages` including `parent_projects` with a sidecar
(`make-extract-fixtures.ps1:148`).

**Fourteen labelled runs, in this order** (order is load-bearing for the lake rows):

| label | command |
|---|---|
| `check-contract:GL` | `tools\check-contract.ps1 -Contract contracts\Clayco_Job_Costs_from_GL.sql` |
| `check-contract:All_Sales_Data` | `tools\check-contract.ps1 -Contract contracts\All_Sales_Data.sql` |
| `run-assertions` | `tools\run-assertions.ps1` |
| `materialize:1` | `tools\materialize.ps1 -LakeRoot <scratch>\lake` (REFRESH) |
| `materialize:2` | same (SKIP) |
| `lake-status` | `tools\lake-status.ps1 -LakeRoot <scratch>\lake` |
| `lake-status:history` | `tools\lake-status.ps1 -History Clayco_Job_Costs_from_GL -LakeRoot <scratch>\lake` |
| `list-extracts` | `tools\list-extracts.ps1 -ExtractRoot <scratch>\xfx\ages` |
| `extract-status` | `tools\extract-status.ps1 -Name parent_projects -ExtractRoot <scratch>\xfx\ages` |
| `extract-decide` | `tools\extract-decide.ps1 -Name parent_projects -ExtractRoot <scratch>\xfx\ages` |
| `run-compat-tests` | `tools\run-compat-tests.ps1` |
| `make-truncation-fixtures` | `tools\make-truncation-fixtures.ps1 -Path <scratch>\trunc` |
| `gl-facts` | `duckdb -f checks\gl-facts.sql` |
| `read-memories:search` | `duckdb -csv -f skills\read-memories\search.sql` with `DSK_KEYWORD=lakehouse`, `DSK_CWD=''` set in this script's process only |

**Not all scratch:** `check-contract`, `run-assertions` and `materialize` read the **live** workbook,
read-only, through the shipped contracts. That is intended — it is the real path.

If `extract-decide`'s verdict in the fixture tree needs arguments beyond those shown to make a probed call,
measure and use them, and say so in `RESULT-1.md`. `-Only <label>` runs one entrypoint; for a
`lake-status*` label it first builds the lake with an **unshimmed** `materialize.ps1`, and for an
extract label it first builds the fixture tree.

**Excluded, with the reason printed in the script's header:**
- the bash upstream skills (`read-file`, `query`, `attach-db`, `convert-file`, `s3-explore`, `spatial`,
  `duckdb-docs`, `install-duckdb`) — **excluded from probing** because they do not run on Windows (README).
  Sessions still *read* `read-file`'s text on Windows; that is part C, not a probe;
- `list-sheets.ps1`, `publish-extract.ps1`, `dsk-paths.ps1`, `ensure-duckdb-compat.ps1`,
  `make-extract-fixtures.ps1`, `make-decide-fixtures.ps1`, `make-ac16-fixture.ps1` — never launch
  `duckdb`. **Confirm by searching every `tools\*.ps1` for a `duckdb` invocation.** If any tool is missing
  from both lists, add it and say so.

### Output and verdicts

The script prints only these lines (plus, for any entrypoint not `PASS`, that entrypoint's last 20 output
lines):

`EXT,<label>,exit=<n>,elapsed=<s>,calls=<n>,probed=<n>,unprobed=<n>,not_a_session=<n>,probe_missing=<n>,loaded=<a|b|…>,<verdict>`

`loaded` is the union across that entrypoint's probed calls. Then
`SUMMARY,entrypoints=<n>,pass=<n>,fail=<n>,no_evidence=<n>,hung=<n>,forbidden=<list>`.

**Verdict**, first match wins: `HUNG` if it exceeded `-BudgetSeconds` (default 120; process tree killed);
`FAIL` if any probed call loaded a forbidden extension, or `probe_missing > 0`, or the entrypoint's own
exit code was non-zero; `NO_EVIDENCE` if `probed = 0`; else `PASS`. Script exits 0 iff every line is
`PASS`.

**Parameters:** `-Forbid <names>` (default `snowflake`; comma-split — `powershell -File` cannot bind a
`[string[]]` from multiple arguments), `-BudgetSeconds <n>`, `-Only <label>`.

### Controls — extra labels, run only when named with `-Only`

- `control_load_fts` — `duckdb -f <scratch>\fts.sql` containing `LOAD fts; SELECT 1;`. The positive
  control proving the probe detects a load. **It uses `fts`, a core extension installed here, so that
  proving detection never requires loading `snowflake`.**
- `control_error` — a scratch `.ps1` that runs `& duckdb -f <scratch>\error.sql` (containing
  `SELECT * FROM no_such_table;`) and **then `exit 0`**, modelled on `list-extracts.ps1`, which exits 0
  after a failed read. It must exit 0 itself, or the exit-code rule decides it `FAIL` and the `probed = 0`
  rule is never tested.
- `control_hang` — `duckdb -f <scratch>\hang.sql` containing
  `SELECT max(hash(i*7+1)) FROM range(2000000000);` (non-foldable, ~12 s measured in item 6; **not**
  `count(*) FROM range(n)`, which is constant-folded).

Remove the shim directory, probe files and scratch at the end, including on failure.

## C — Routing text (edit `skills\read-file\SKILL.md` and `skills\lakehouse\SKILL.md`)

**`read-file`:**

1. Add `OR file_name ILIKE '%.xlsm'` to the `excel_case` arm at line 58. **Do not add `sheet=` to
   `read_any`**: reading the first sheet by default is expected, and it is why the section below exists.
2. Add a short **"Excel workbooks"** section before Step 1. It must say, in this order:
   - **If a contract covers the workbook and sheet, answer from the lake, not the workbook.** Contracts
     are `contracts\*.sql`; each names its workbook in `read_xlsx('<path>', sheet='<sheet>', …)`. Query
     `lake.<contract>` per the `lakehouse` skill, and check freshness with `tools\lake-status.ps1`.
   - **If none does:** list sheets with `tools\list-sheets.ps1 <absolute path>` (the first sheet may be
     metadata — `Data Extracts.xlsm`'s is a 2-row `MetaData`); read the named sheet with `sheet=`,
     `all_varchar = true` and `stop_at_empty = false`; cast money explicitly to `DECIMAL` before summing;
     and **tell Phil the types are unverified.** Never `ignore_errors = true`.
   - **Why**, in one or two sentences with today's figures: an inferred read sums GL `JOB_COSTS` as
     DOUBLE (`22498718519.95991`) where the contract returns `22498718519.96`, and which columns infer
     correctly changes as the sheet's contents change.
   - A contract is added **only when Phil asks** (item 5b's principle) — the section must not tell a
     session to write one.
   - That this is guidance a session is asked to follow, not a check anything enforces.
3. The frontmatter description stays **≤ 3 lines**. Rewording it is allowed; growing it is not.

**`lakehouse`:** add one sentence to "Querying the lake directly" saying that once a contract is
materialized, the lake is the place to answer questions about that sheet, and it does not need the
workbook present (cite `tools\prove-requery.ps1`). The description is not touched.

## D — `tools\materialize.ps1`: a missing workbook must not abort the other contracts

**In scope by Phil's decision** (see top). Found while measuring A. Today, when a contract's
workbook does not exist:

- the `read_blob` hash read fails first, so the explicit `Test-Path` branch at `materialize.ps1:287-290`
  ("workbook path does not exist") is **unreachable**;
- the message is `could not read workbook at <path> (see output above)`, with nothing above it;
- it calls **`exit 1`** (`materialize.ps1:283`), so **every contract after it is never processed**, and
  no `SUMMARY` line is printed.

Required:

1. Test existence **before** the hash read. A missing workbook prints `MATERIALIZE,<contract>,ERROR` then
   `ERROR,<contract>,workbook path does not exist: <path>`, writes **nothing** to `manifest` or
   `check_history`, leaves `lake.<contract>` untouched, and **continues to the next contract.**
2. A workbook that exists but cannot be read (locked, mid-sync) keeps today's message — DuckDB's verbatim
   error, including the holder's process name and PID (item 6 AC18) — but also **continues** instead of
   exiting.
3. `SUMMARY` gains a trailing `,errored=<n>`: the number of contracts that printed an
   `ERROR,<contract>,…` line and were counted in none of `refreshed`, `skipped`, `refused`. That includes
   the no-`read_xlsx` case at `materialize.ps1:260-264`. After D, every `SUMMARY` satisfies
   `contracts = refreshed + skipped + refused + errored` (`forced` is a subset of `refreshed`,
   `:521-522`). Any `errored > 0` makes the final exit non-zero.
4. The whole-lake `exit 1` paths are **unchanged** and still end the run without a `SUMMARY`: the catalog
   lock at `:322` (item 6 AC17), and the lake-write failures at `:463`, `:492`, `:514`.
5. Re-running an archived acceptance command will now show `,errored=0` appended to `SUMMARY`. That is
   expected drift, not a regression. **Do not edit `docs\tasks\`.**

Nothing else in `materialize.ps1` changes.

### Scratch tree for AC3, AC4 and mutations 5a/5b

`materialize.ps1` finds contracts only in `<its own repo root>\contracts\` (`:119-120,156-168`); with
`-Contract` it processes exactly one file; and both shipped contracts read the same workbook. So build
`<scratch>\tree\`:

- `tools\` — a copy of every `tools\*.ps1`, from this branch for "after" and from `main`
  (`git show main:tools/<f>`) for "before";
- `skills\query\duckdb-compat.sql` — a copy;
- `contracts\` — the two scratch contracts only, each pointing at its **own** workbook copy,
  `<scratch>\wb\All_Sales_Data.xlsm` and `<scratch>\wb\Clayco_Job_Costs_from_GL.xlsm`.

Run it as
`powershell -NoProfile -ExecutionPolicy Bypass -File <scratch>\tree\tools\materialize.ps1 -LakeRoot <scratch>\lake`.
Contracts are processed in `Sort-Object Name` order (`:161-163`), so the first-processed contract is
**`All_Sales_Data`**. Remove or lock only paths held in variables from the copy step, never a path read
back from a contract.

## Out of scope — do not do these

- **No edits to any shipped contract**, to `run-assertions.ps1`, `check-contract.ps1`, `lake-status.ps1`,
  or the `snowflake-extract` tools.
- **Do not uninstall or touch the `snowflake` extension** under `C:\Users\woodsonp\.duckdb\` — outside
  this repo. If it is worth removing, that is Phil's call.
- **Do not load `snowflake` for any reason**, and never write `ATTACH … (TYPE snowflake)`. Use `fts`.
- No new skill. No README change (item 8 owns README).
- Do not edit `PLAN-4.md` (frozen), though two of its measured facts are stale (61,741 rows;
  `VENDOR_NAME` inferring to 0).
- The hyphenated-filename bug in `materialize.ps1` stays out; D is limited to the missing/unreadable-
  workbook path.
- The bash `query` skill's sandbox is not probed. Do not add a sandbox run.

## Conventions

Windows / PowerShell 5.1; `;` never `&&`; absolute paths. SQL in `.sql` files run with `duckdb -f`.
**Gate on `$LASTEXITCODE`, never stderr** — scope `$ErrorActionPreference = 'Continue'` around DuckDB
calls, as `check-contract.ps1` does. Write files with `[IO.File]::WriteAllText` and
`New-Object Text.UTF8Encoding($false)`; the `.cmd` shim is ASCII. **The live workbook is read-only.** All
lakes and extract roots are scratch, under `$env:TEMP`. Throwaway contracts never go in `contracts\`.

## Acceptance checks

Figures marked *runtime* are computed in the same run, never pinned — the workbook moves.

**AC1 — re-query without the workbook.** `powershell -NoProfile -File tools\prove-requery.ps1` prints:

```
REQUERY,All_Sales_Data,source_rows=<n>,lake_rows=<n>,manifest_rows=<n>,workbook_present=false,PASS
REQUERY,Clayco_Job_Costs_from_GL,source_rows=<n>,lake_rows=<n>,manifest_rows=<n>,workbook_present=false,PASS
REQUERY_SUM,Clayco_Job_Costs_from_GL,source=<s>,lake=<s>,PASS
LIVE_WORKBOOK,unchanged
```

(or `LIVE_WORKBOOK,SYNCED,…`), all three counts equal on each line (*runtime*; today 219 and 62,377), and
exit 0.

**AC2 — AC1 has teeth.** Three mutations of a scratch copy of `prove-requery.ps1`, each exiting non-zero:
- skip step 5, so the workbook stays present → both `REQUERY` lines show `workbook_present=true,FAIL`;
- skip step 2's rewrite, so the scratch contracts still point at the live workbook → the
  "exactly one occurrence replaced" guard stops the run **before** materializing, and the live workbook
  is not `CHANGED` and still exists afterwards;
- in step 6, read counts from a lake **other** than the one step 4 wrote (e.g. a second, empty scratch
  lake) → `FAIL`, proving the lake figures are really read.

**AC3 — a missing workbook no longer aborts the batch.** In the scratch tree: materialize (REFRESHED ×2);
record both tables' `count(*)`, the `manifest` row count and the `check_history` row count; remove
`<scratch>\wb\All_Sales_Data.xlsm` only; materialize again. After the fix:

```
MATERIALIZE,All_Sales_Data,ERROR
ERROR,All_Sales_Data,workbook path does not exist: <scratch>\wb\All_Sales_Data.xlsm
MATERIALIZE,Clayco_Job_Costs_from_GL,SKIPPED
SUMMARY,contracts=2,refreshed=0,skipped=1,refused=0,forced=0,errored=1
```

exit 1; both table counts, the `manifest` count and the `check_history` count unchanged. Before the fix
(the same sequence with `main`'s `tools\`): output ends at
`ERROR,All_Sales_Data,could not read workbook at … (see output above)`, with no
`Clayco_Job_Costs_from_GL` line and no `SUMMARY` line, exit 1. Capture both.

**AC4 — a locked workbook still names its holder, and no longer aborts.** Item 6's lock recipe
(`docs\tasks\2026-09-25-item6-lakehouse-materialize\RESULT-1.md:343-362`): a separate `powershell`
process holds `<scratch>\wb\All_Sales_Data.xlsm` open with
`[IO.File]::Open(<path>, 'Open', 'Read', 'None')`; then run the scratch-tree `materialize.ps1`. Expected:
the verbatim `File is already open in …powershell.exe (PID <n>)`, `<n>` equal to the holder's PID; then a
`MATERIALIZE,Clayco_Job_Costs_from_GL,…` line; `errored=1`; exit non-zero. Release the lock afterwards.

**AC5 — nothing loads `snowflake`.** `powershell -NoProfile -File tools\prove-no-snowflake.ps1` with no
arguments prints 14 `EXT,…,PASS` lines (the labels in B's table), no `loaded=` containing `snowflake`,
`SUMMARY,entrypoints=14,pass=14,fail=0,no_evidence=0,hung=0,forbidden=snowflake`, exit 0. (The reviewer
counted 15; recounting B's table gives 14. If a tool is added under B's "confirm by searching" rule, the
count rises with it, and `RESULT-1.md` says why.)
`run-compat-tests` shows `unprobed > 0` and `not_a_session = 1`, and is still `PASS` because
`probed ≥ 1`. **Must pass identically in the verifier's worktree** — that is what D5 exists for.

**AC6 — the probe detects a load (positive control).** `-Only control_load_fts -Forbid fts` prints
`EXT,control_load_fts,…,loaded=…fts…,FAIL` and exits non-zero. `-Only control_load_fts` with the default
`-Forbid` prints `PASS`, proving the verdict comes from the forbid list, not from the control.

**AC7 — a failed call is not clean.** `-Only control_error` prints
`EXT,control_error,exit=0,…,calls=1,probed=0,unprobed=1,…,NO_EVIDENCE` — **exactly** `NO_EVIDENCE` — and
the script exits non-zero.

**AC8 — a hang is caught and killed.** `-Only control_hang -BudgetSeconds 3` prints `HUNG` with
`elapsed ≤ 15`, exits non-zero, and afterwards no `duckdb.exe` whose `Win32_Process.CommandLine` contains
the control's scratch `hang.sql` path is running. (Matching on command line, not on a PID snapshot:
Phil's other sessions may start `duckdb.exe` in the same window.)

**AC9 — the probe does not change what tools print.** For `run-compat-tests.ps1`, `check-contract.ps1` on
each shipped contract, `list-extracts.ps1 -ExtractRoot <fixture>`, and `lake-status.ps1` against a
scratch lake built by an **unshimmed** `materialize.ps1`: stdout through the shim is identical to stdout
without it, and so is the exit code. Before comparing `list-extracts`, replace each `age_minutes=<n>` with
`age_minutes=*` (it is `date_diff('minute', materialized_at, now())`, `registry.sql:74`). Show the diff,
which must be empty. `run-compat-tests` is in this set because it is the only tool that passes `-init` and
redirects stderr, and its exit code ignores row failures — a mangled argument would lower its pass counts
while it still exits 0.

**AC10 — call accounting.** For every `EXT` line in AC5, show `calls` (log lines), the number of
**distinct** probe paths (must equal `calls`), `probed`, `unprobed`, `not_a_session`, and
`probe_missing` (must be 0).

**AC11 — control: the shim leaves no trace.** After AC5–AC8: shim directory and probe files gone; a fresh
`powershell -NoProfile -Command "(Get-Command duckdb).Source"` resolves to the real `duckdb.exe`;
`snowflake.duckdb_extension` and `libadbc_driver_snowflake.so` under `C:\Users\woodsonp\.duckdb\` have the
same size and `LastWriteTime` as before; and no new `~\.duckdb-skills\<id>\` directory was created for the
worktree's project-id. (A control: it can fail only if PATH was persisted or a default root was
resolved.)

**AC12 — the route `read-file` sends a session down is now right.** Put the `read_any` block from
`skills\read-file\SKILL.md` into `<scratch>\readany.sql` verbatim, with `RESOLVED_PATH` replaced by a
scratch copy's path in forward slashes, and run `duckdb -csv -f <scratch>\readany.sql`:
- before (`main`'s SKILL.md): `DESCRIBE` shows `content` as `BLOB`, and `row_count` = 1;
- after: `DESCRIBE` shows the `MetaData` sheet's 2 columns, and `row_count` = 2.

Then run the section's no-contract recipe on `Clayco_Job_Costs_from_GL` and show
`SUM(JOB_COSTS::DECIMAL(18,2))` equals the contract view's `SUM(JOB_COSTS)` (*runtime*; today
`22498718519.96`), beside the inferred-DOUBLE sum (today `22498718519.95991`).

**AC13 — skill text.** `read-file`'s description is ≤ 3 lines; `lakehouse`'s description is
byte-identical to `main`. Quote the new "Excel workbooks" section and the new `lakehouse` sentence in
`RESULT-1.md`. The section contains no instruction to write a contract.

**AC14 — nothing real was touched.** The live workbook is `unchanged` or `SYNCED` by AC1's rule, never
`CHANGED`, across the whole implementation. The real lake's catalog file (`Resolve-LakeRoot`'s default in
the main checkout; it exists, 8,663,040 bytes) has an unchanged `LastWriteTime`. `contracts\` holds exactly
the two shipped contracts, byte-identical to `main`.

**AC15 — no BOM** on any new or changed `.ps1`, `.sql` or `.md`.

## Mutation proofs — each must fail, then pass again after revert

1. Shim writes the probe to stdout instead of the probe file → AC9 fails.
2. Probe runs in a **separate** `duckdb` process instead of appended to the call → AC6 fails (`fts` loaded
   by the call is invisible to it). This is the mutation that shows PLAN-4's literal check would have been
   a fake.
3. Treat `probed = 0` as `PASS` → AC7 fails.
4. Drop the timeout → AC8 fails. Run it under a hard outer timeout so the proof itself cannot hang.
5. a. In D's new missing-workbook branch, replace `continue` with `exit 1` → AC3 fails
   (`Clayco_Job_Costs_from_GL` and `SUMMARY` absent).
   b. In the unreadable-workbook branch (today's `materialize.ps1:283`), restore `exit 1` → AC4 fails.
6. Name probe files with `%RANDOM%` alone, no existence retry → AC10's distinct-path count falls below
   `calls` on `run-compat-tests`. If it does not reproduce in three runs, say so rather than force it.
7. Remove the `.xlsm` arm → AC12's first half fails.

## Deliverables

`tools\prove-requery.ps1`, `tools\prove-no-snowflake.ps1` (new); `tools\materialize.ps1`,
`skills\read-file\SKILL.md`, `skills\lakehouse\SKILL.md` (edited). Branch `item7-workbook-proof` from
`main`. Commit and push before writing `RESULT-1.md`.
