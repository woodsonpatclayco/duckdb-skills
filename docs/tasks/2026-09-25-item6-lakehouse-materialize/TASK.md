Plan: PLAN-4.md (item 6), plus one addition Phil asked for — the lakehouse records check
results, not just provenance, so "was this sheet healthy when I built that report?" is answerable.
Serves: "put the sheets somewhere I can query without re-running the whole check suite every time,
only re-read when something actually changed, and keep a record of whether the data was sound each
time it landed."

# TASK — Materialize contracts into the lakehouse, with freshness and a check history (item 6)

## A correction to how this spec was first drafted

The first draft asserted that DuckLake permits two concurrent writers to both succeed while one
silently loses, and built a hand-rolled lock file to compensate. **That was wrong.** The "delay" used
to create overlap was `count(*) FROM range(900000000)`, which DuckDB **constant-folds** — measured at
**0.105 s**, so the two processes never overlapped at all. Re-run with a non-foldable delay
(`max(hash(i*7+1))` over `range(2000000000)`, ~12 s), the overlap is genuine and **DuckLake locks
loudly**. PLAN-4 §6 was right.

Two other first-draft claims came from the same class of mistake — fixtures of one or two rows that
generalize incorrectly to 62,230. **Every measured claim below was re-taken against a real contract.**
A full GL materialization costs 0.93 s, so there is no excuse for using a toy fixture to characterise
production behaviour. Carry that rule forward.

---

## Conventions that are not optional

- **SQL in `.sql` files invoked with `duckdb -f`**, never inline `duckdb -c`.
- **Write files with `[IO.File]::WriteAllText` plus `New-Object Text.UTF8Encoding($false)`.** Never
  `Set-Content -Encoding UTF8`.
- PowerShell 5.1: `;` never `&&`, absolute paths.
- **Gate on `$LASTEXITCODE`, never on stderr being empty.** PowerShell throws a terminating
  `NativeCommandError` on any `duckdb` stderr output under `$ErrorActionPreference = 'Stop'`;
  `tools\check-contract.ps1` scopes `'Continue'` around its DuckDB calls — copy that.
- **Resolve repo paths from `$PSScriptRoot`**, never hardcoded absolutes.
- **`LOAD ducklake;` is required.** `duckdb_settings()` does not even list the DuckLake settings until
  the extension is loaded.
- **The workbook is READ-ONLY.** 34 dependents, 18 latent orphaned Power Query connections; writing it
  also triggers a full SharePoint re-upload. Use **scratch copies** for every experiment.
- **Do not touch anything under `docs\tasks\`.** Throwaway contract copies live in `$env:TEMP`, never in
  `contracts\`, so they cannot become a discoverable third contract.
- Reuse `tools\dsk-paths.ps1`'s `Get-ProjectId` for `<project-id>`. Do not re-derive it — item 2 already
  fixed a bug where a drive colon leaked into the path. `-LakeRoot`, if given, **must be absolute**,
  matching `Resolve-ExtractRoot`'s rule, which exists because a relative path bit a verifier mid-run.
- `skills/lakehouse/SKILL.md` is the **second and final** new skill permitted by PLAN-4 §8's standing
  context budget: **≤ 4 description lines.**

---

## Measured facts

### 1. DuckLake enforces a single writer, loudly — as PLAN-4 §6 expected

With a genuine overlap (A begins a transaction at 15:33:03.685 and holds it to 15:33:15.735; B starts at
15:33:07.704, inside that window), B fails at **`ATTACH`**:

```
IO Error: Failed to attach DuckLake MetaData "__ducklake_metadata_lake" at path
"...\lake.ducklake": Cannot open file "...\lake.ducklake": The process cannot access
the file because it is being used by another process.
File is already open in ...\duckdb.exe (PID <n>)
```

**B exits 1 and writes nothing.** A's data survives as current. The error names the holding PID — the
same shape as the locked-workbook error in §3.

So **no tool-level lock is needed.** DuckLake's catalog file lock is the serializer. Its supported
tuning knobs, which exist and should be named rather than reinvented:

```
ducklake_max_retry_count   10
ducklake_retry_backoff     1.5
ducklake_retry_wait_ms     100
```

A hand-rolled lock would be strictly worse: it adds a stale-lock reclaim path whose only purpose is
recovering from a failure mode the lock itself invents.

### 2. `DATA_PATH` holds real Parquet — both contracts are far above the inlining threshold

`ducklake_default_data_inlining_row_limit` is **10** rows. Measured, materializing the real GL contract:

```
snapshot 1  {tables_created=[main.gl], tables_inserted_into=[1]}     <- NOT inlined_insert
DATA_PATH\main\gl\ducklake-01a0da46-....parquet    954.4 KB
catalog                                            3,852 KB
```

Both contracts (62,230 and 219 rows) are above 10, so **both write Parquet**. PLAN-4 §6's claim that no
directory is created, and the first draft's claim that the directory stays empty, are both wrong.

Decide whether a materialization happened from `snapshots()` and the manifest, **never from the
filesystem** — but do not expect `DATA_PATH` to be empty.

### 3. A locked workbook fails loudly

Against a **copy** under `FileShare.None`:

```
IO Error: Cannot open file "...lockme.xlsm": The process cannot access the file
because it is being used by another process.
File is already open in ...powershell.exe (PID 233508)
```

Exit 1, naming the holder. Releasing the lock and re-reading returned 219 rows. Excel's own lock is less
strict than `FileShare.None`, which is why every read in this project has succeeded with the workbook
open; the exclusive case is a mid-sync or another-tool situation.

### 4. What the harness emits — and what it does not

This shapes the whole schema, so it is measured verbatim. `tools\run-assertions.ps1` on the GL contract:

```
ASSERT,jobcosts_sum_exact_decimal,PASS
ASSERT,vendorname_ratio_floor,PASS
ASSERT,glperiod_ratio_floor,PASS
ASSERT,glperiod_is_date,PASS
TRUNCATION_DEFAULT_ROWS,62230
TRUNCATION_WITHDATA_ROWS,62230
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,62230
ANCHOR,JOB_COSTS,62230,PASS
ROWS_FLOOR,50000,62230,PASS
FINGERPRINT,MATCH
SUMMARY,contracts=1,assertions=4,failures=0
```

**`ASSERT` lines carry no value.** `vendorname_ratio_floor`'s observed ratio (0.8362) and its threshold
(0.80) appear nowhere — `check-contract.ps1` evaluates each `@assert` as `SELECT <boolean>;` and keeps
only the verdict. That is structural.

Consequence, and it must be stated so nobody quietly works around it: **`check_history.observed` is
populated only for the line kinds that carry a value** — `SNAPSHOT`, `ANCHOR`, `ROWS_FLOOR`,
`TRUNCATION_*`, `CONSISTENCY_VIEW_ROWS`. For `ASSERT` rows, `observed` is the status and `committed` is
NULL.

**Do not modify `run-assertions.ps1`, and do not recompute an assertion's expression inside
`materialize.ps1`.** A second evaluation is a second source of truth. If the real ratios should be
stored, that is a change to item 5's output contract and belongs in its own spec.

### 5. Timings — so no acceptance check rests on a false premise

| operation | measured |
|---|---|
| SHA-256 of the 64.82 MB workbook | **0.118 s** |
| one raw `read_xlsx` of the GL sheet | 0.65 s |
| full harness run on the GL contract | **6.23 s** |
| full GL materialization into the lake | 0.93 s |

**Hashing the workbook is a full read of it.** So the SKIP path reads the workbook's bytes by
construction — that is required, not a defect. The saving from SKIP is the **6.23 s harness**, not the
read. The `Serves:` line is worded accordingly.

### 6. What else reproduces

`ATTACH 'ducklake:<path>' AS lake (DATA_PATH ...)`, `CREATE OR REPLACE TABLE lake.<n> AS SELECT ...`,
`snapshots()` recording `schemas_created`/`tables_created`/`tables_dropped`/`tables_inserted_into`, and
`AT (VERSION => n)` time travel all work. `snapshots()` records *that* a table was replaced and never
from which file, at which mtime, under which contract — so a manifest is justified, exactly as the plan
says.

UTC pinning also holds: `timezone('UTC', now())::TIMESTAMP` agreed with PowerShell's UTC clock to within
10 ms. Same discipline as item 2's sidecar, where the naive form measured **−297** minutes wrong and a
`TIMESTAMPTZ` pin **+390**.

---

## The addition Phil asked for: a check history

Check **definitions** stay in the contract files — versioned, diffable, readable. Check **results** get
written to the lake at materialization time.

**`lake.manifest`** — one row per materialization attempt that reached a decision:

| column | meaning |
|---|---|
| `run_id` | GUID — the real join key. `(materialized_at, contract_name)` is not guaranteed unique. |
| `materialized_at` | TIMESTAMP, `timezone('UTC', now())` pinned |
| `contract_name` | e.g. `Clayco_Job_Costs_from_GL` |
| `source_path` | absolute workbook path, read from the contract's own `read_xlsx(...)` call |
| `source_mtime` | workbook `LastWriteTime` at read time |
| `source_sha256` | workbook hash — catches a content change at an unchanged mtime |
| `contract_sha256` | hash of the contract `.sql` |
| `compat_sha256` | hash of `skills\query\duckdb-compat.sql` — see below |
| `row_count` | rows landed |
| `lake_snapshot_id` | the DuckLake snapshot this write produced |
| `checks_passed` | BOOLEAN |
| `forced` | BOOLEAN — materialized despite failing checks |

**`compat_sha256` is in the key because the contracts depend on a fourth input.** Both call `xl_date()`,
defined in `skills\query\duckdb-compat.sql`. Change that macro's epoch, its `to_days` arithmetic, or its
trailing `::DATE`, and every `GL_PERIOD` and `Start Date` in the lake decodes differently while the
workbook mtime, workbook hash, and contract hash are all **unchanged** — so without this the tool SKIPs
and serves the old decode silently. This is the item-1 failure (three macros wrong, 17/17 passing) and
the items-3+4 decoder failure (6,654 of 18,764 dates wrong) waiting to happen a third time. The refresh
decision is therefore **four-way**.

**`lake.check_history`** — one row per check per materialization:

| column | meaning |
|---|---|
| `run_id` | joins to `manifest` |
| `contract_name`, `check_id` | which check |
| `kind` | `invariant` \| `floor` \| `snapshot` |
| `status` | `PASS` \| `FAIL` \| `DRIFT` \| `ERROR` |
| `observed`, `committed` | VARCHAR — holds a date, a ratio, and a 22-billion sum alike |
| `outcome` | `MATERIALIZED` \| `REFUSED` \| `FORCED`, identical on every row of one run |

**`outcome` is what makes a FAIL row interpretable.** A refused run writes check rows and materializes
nothing, so without it you cannot tell whether the checks describe data that actually landed — which is
the entire question this table exists to answer.

`observed` is VARCHAR, so a trend query must `TRY_CAST(observed AS DOUBLE)` for ordering and display the
raw text. Note the harness already compares snapshot values numerically when both parse as doubles, so
`1682000000.00` and `1682000000.0` are not drift; `materialize.ps1` must not implement a different
comparison.

**SKIPPED runs write no rows to either table.** Correct — the inputs did not change, so there is no new
verdict — but `SKILL.md` must say so outright or the gaps read as missing data.

### Assigning `kind` and `status` — by line shape, the only machine-readable signal

The taxonomy exists only in prose comments inside the contracts. From §4's output, an invariant
(`glperiod_is_date`) and a floor (`vendorname_ratio_floor`) are byte-identical in shape. So:

| emitted line | `kind` | `status` |
|---|---|---|
| `ASSERT,<n>,…` where `<n>` ends `_floor` | `floor` | as emitted |
| `ASSERT,<n>,…` otherwise | `invariant` | as emitted |
| `ROWS_FLOOR,<floor>,<obs>,<st>` | `floor` | as emitted |
| `ANCHOR,<n>,<obs>,<st>` | `invariant` | as emitted |
| `TRUNCATION_ROWS_LOST,<n>` | `invariant` | PASS iff 0 |
| `CONSISTENCY_VIEW_ROWS,<n>` | `invariant` | PASS iff = `TRUNCATION_WITHDATA_ROWS` |
| `SNAPSHOT,<n>,<v>` | `snapshot` | DRIFT iff a `SNAPSHOT_DRIFT` line follows for `<n>`, else PASS |
| `FINGERPRINT,MATCH\|DRIFT` | `snapshot` | PASS / DRIFT |

**The `_floor` suffix is load-bearing.** A future contract with an unsuffixed floor is filed as an
invariant; say so in `SKILL.md`.

Parse on the **first n commas with the remainder as detail** — never a naive `-split ','`. `ASSERT`
details contain commas (`duckdb exited 1: ...`) and `ANCHOR,Job #,219,PASS` carries a space and a `#` in
the check id.

---

## Deliverables

### 1. `tools\materialize.ps1`

`tools\materialize.ps1 [-Contract <path>] [-Force] [-LakeRoot <absolute path>]`

Default: every contract in `contracts\`. Lake at `~\.duckdb-skills\<project-id>\lake.ducklake`, with
`DATA_PATH` alongside.

Per contract:

1. **Decide.** Compare workbook mtime, workbook SHA-256, contract SHA-256, and compat SHA-256 against
   the newest `lake.manifest` row for that contract. **Also confirm the target still exists**: if
   `lake.<contract_name>` is absent from `duckdb_tables()` or has 0 rows, REFRESH regardless of hashes
   and report `reason=target_missing`. The lake lives under gitignored scratch and its Parquet files are
   separately deletable, so a manifest row can outlive the table it describes. A manifest row with
   `checks_passed = false` **never** satisfies the freshness test — always REFRESH, so forced bad data
   is re-checked rather than persisting unexamined.
2. **Run the checks** by invoking `tools\run-assertions.ps1`. Do not reimplement item 5's grammar.
3. **Gate on the harness's exit code.** Non-zero means a gating signal failed and materialization is
   refused. This is already exactly the right gate — the harness increments its failure count for
   non-PASS asserts, ERROR, directive errors, rows-lost, consistency mismatch, anchor FAIL and floor
   FAIL, and **never** for `SNAPSHOT_DRIFT` or `FINGERPRINT,DRIFT`. Do not re-derive it. On refusal:
   leave the previous lake table untouched, write `check_history` rows with `outcome = REFUSED`, exit
   non-zero. `-Force` materializes anyway with `outcome = FORCED` and `manifest.forced = true`.
4. **Materialize** `CREATE OR REPLACE TABLE lake.<contract_name> AS SELECT * FROM contract_view`.
5. **Write** the manifest and check-history rows, sharing one `run_id`.

Emit `MATERIALIZE,<name>,SKIPPED` or `,REFRESHED,<rows>[,reason=…]`, plus `MANIFEST_SNAPSHOT_ID`,
`CHECKS_PASSED`, and a `SUMMARY` line, in item 5's established format.

On a locked workbook: report the `IO Error` verbatim including the PID, leave the previous lake table
intact, exit non-zero, do not retry — the error is deterministic while the lock is held. On DuckLake's
catalog lock: report it the same way and name `ducklake_max_retry_count` as the tuning knob rather than
implementing a retry loop.

### 2. `tools\lake-status.ps1`

Read-only. `tools\lake-status.ps1` prints per contract: last materialized, source mtime, rows, checks
passed, forced, current snapshot id, and outcome. `-History <contract>` shows a check's observed values
across materializations. `-AsOf <date> -Contract <name>` prints the newest manifest row at or before that
date with its check rows, and states that any later `REFUSED` runs did not change the data — that is the
dated question this exists to answer.

Must work when no lake exists: report "no lake", exit 0.

### 3. `skills/lakehouse/SKILL.md`

≤ 4 description lines. Covers: how to query the lake; the four-way freshness key and why the compat hash
is in it; SKIPPED vs REFRESHED, and that SKIPPED writes no history; that `DATA_PATH` holds Parquet and an
empty one would be abnormal; DuckLake's single-writer lock and its retry settings; recovering a
superseded write with `AT (VERSION => n)`; and that the `_floor` suffix determines `kind`.

---

## Out of scope

- Direction-aware row tolerance — its own item. Workbook proof and routing — item 7. Cross-source join —
  item 8.
- Any change to item 5's output contract, including making the harness emit observed ratios.
- A hand-rolled serialization lock. DuckLake's own lock is the serializer; see §1.
- Compaction or `DATA_PATH` tuning.
- Materializing Snowflake extracts into the lake — items 2a/2b already land queryable Parquet; unifying
  is item 8's business.
- A third contract. Any write to the source workbook. Any edit under `docs\tasks\`.
- Item 2b's unverified multi-object extract path. Still outstanding, still not this item.

---

## Acceptance checks

Every check is a command with an expected value. None needs Snowflake.

**AC0** In a throwaway worktree at the implementer's commit, `tools\materialize.ps1` succeeds on first
invocation with no setup. Quote the `SUMMARY` line. Note `Get-ProjectId` derives from
`git rev-parse --show-toplevel`, so the worktree gets its **own** lake under a different
`<project-id>` — good isolation, and the verifier should delete that orphaned lake directory afterwards.

**AC1** First run materializes both contracts, exit 0. Row counts must equal what
`tools\run-assertions.ps1` reports for the same sheets **in the same session** — cross-checked against
an independent tool, not pinned to an absolute.

**AC2** *Freshness.* Run twice unchanged. The second reports `SKIPPED` for both. It **does** read the
workbook's bytes to hash it — required by the decision, not a defect — but must not parse a sheet and
must not write. Prove: max `snapshot_id` from `lake.snapshots()` identical before and after, and
`SELECT count(*) FROM lake.check_history` identical before and after. Quote all four numbers.

**AC3** *A changed workbook forces a refresh.* Against a **scratch copy** — never the live file — touch
it; next run reports REFRESHED with a row count.

**AC4** *A changed contract forces a refresh.* Edit a comment in a throwaway contract copy so only
`contract_sha256` moves → REFRESHED.

**AC5** *A changed macro forces a refresh.* Edit a comment in a throwaway copy of
`skills\query\duckdb-compat.sql` so only `compat_sha256` moves → REFRESHED. Without this, a changed date
decoder is served silently.

**AC6** *Same mtime, changed content is still caught.* Materialize a scratch copy, modify it, reset its
`LastWriteTime` to the original → still REFRESHED, on the SHA-256.

**AC7** *A missing target defeats the SKIP.* After a clean SKIP run, `DROP TABLE lake.All_Sales_Data`,
re-run → REFRESHED with `reason=target_missing` and 219 rows, not SKIPPED.

**AC8** *Time travel.* After two materializations of a changed scratch copy, `snapshots()` lists the
replace. Read `lake_snapshot_id` from the **first** manifest row for that contract and
`SELECT count(*) FROM lake.<contract> AT (VERSION => <that id>)` returns the first run's count, while the
current table returns the second's. **Do not hardcode a version literal** — snapshot ids are per-lake and
the manifest and check-history writes consume them, so `VERSION => 1` errors with
`Table with name … does not exist at version 1!`.

**AC9** *The manifest records provenance `snapshots()` cannot.* One row per materialization with every
column populated. Name the expected value of each for run 1: `row_count` equal to the harness's count,
`checks_passed` **true**, `forced` **false**, and the three hashes equal to independently computed
`Get-FileHash` output quoted beside them.

**AC10** *The check history is per check, per materialization.* After two materializations of both
contracts, `SELECT count(*) FROM lake.check_history` returns **78**, decomposing per the `kind` table as
GL **16** per run (4 ASSERT + 1 ANCHOR + 1 ROWS_FLOOR + 1 TRUNCATION + 1 CONSISTENCY + 7 SNAPSHOT + 1
FINGERPRINT) and `All_Sales_Data` **23** per run (7 + 1 + 1 + 1 + 1 + 11 + 1). Quote the
`GROUP BY contract_name, kind` table. If the live workbook refreshed and a contract's snapshot count
changed, quote the new arithmetic and say so — the rule is fixed, the totals follow.

**AC11** *The history answers the question it exists for.* `tools\lake-status.ps1 -History
Clayco_Job_Costs_from_GL` shows, across two materializations, the `SNAPSHOT` rows `vendorname_nn` and
`rows` with observed values, and the `ROWS_FLOOR` row with floor 50000 and its observed count. State
explicitly in the output that `vendorname_ratio_floor` has **no** observed value because the harness
emits none — §4.

**AC12** *Failing checks block materialization.* Point a **throwaway** contract copy's anchor at
`VENDOR_NAME` (52,037 of 62,230). Materialize refuses, exits non-zero, the previous lake table is
unchanged — prove with both its row count **and** the unchanged max `snapshot_id` — and
`check_history` records the failure with `outcome = REFUSED`.

**AC13** *`-Force` overrides and is recorded.* Same contract with `-Force`: exit 0,
`manifest.forced = true`, `outcome = FORCED`.

**AC14** *A forced bad run is re-checked, never skipped.* Immediately re-run without `-Force`: it must
**not** SKIP, because the newest manifest row has `checks_passed = false`.

**AC15** *Snapshot drift never blocks.* Set a `@snapshot_committed` to a wrong value in a **throwaway**
copy. Materialize succeeds, exit 0, `check_history` records `DRIFT`.

**AC16** *The dated question.* `tools\lake-status.ps1 -AsOf <date> -Contract <name>` across three runs —
one passing, one refused (AC12's setup), one passing — prints the newest manifest row at or before the
date and states that the refused run did not change the data.

**AC17** *DuckLake serializes writers by itself.* Start a materialization holding the catalog and a
second inside its window. The second exits non-zero with `File is already open in …duckdb.exe (PID <n>)`;
`snapshots()` before and after shows exactly **one** new snapshot, proving the loser wrote nothing. Use a
delay DuckDB **cannot** constant-fold — `count(*) FROM range(n)` is folded and produces no overlap.

**AC18** *A locked workbook is loud and harmless.* Hold an exclusive lock on a scratch copy; materialize
reports the `IO Error` with the PID, exits non-zero, and the previous lake table's row count **and**
snapshot id are unchanged.

**AC19** *Data lands as Parquet.* After materializing both contracts,
`DATA_PATH\main\Clayco_Job_Costs_from_GL\` contains at least one `*.parquet` file, `snapshots()` shows
`tables_inserted_into` (**not** `inlined_insert`), and `SELECT count(*)` over the lake table equals the
harness's count in the same session. Guards against a future session "fixing" an empty-directory
non-problem that does not exist at this scale.

**AC20** *Control.* The live workbook's SHA-256 and `LastWriteTime` unchanged before and after. Baseline
`A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3`,
`2026-09-25T08:48:13`. A mismatch with a **later** mtime is a SharePoint sync — quote both hashes and
both mtimes, re-quote any dependent snapshot figures, and continue; it is drift, not a failure. A
mismatch at the **same** mtime is a write by this run and a hard failure.

**AC21** No file created or modified by this item contains a UTF-8 BOM.

### Mutation proof required

Each failing, then passing after revert. Mutate only this item's files.

- **compare only mtime, dropping the workbook SHA-256** → AC6 fails.
- **drop `contract_sha256` from the decision** → AC4 fails; a contract fix is silently ignored.
- **drop `compat_sha256` from the decision** → AC5 fails; a changed date decoder is silently served.
- **drop the target-exists check** → AC7 fails; a dropped table stays SKIPPED forever.
- **let a non-zero harness exit through without `-Force`** → AC12 fails; the lake is replaced with
  known-bad data.
- **write one `check_history` row per materialization instead of per check** → AC10 and AC11 both fail.
- **omit `outcome`** → AC16 fails; a refused run is indistinguishable from one that landed.

---

## Commit and handoff

Commit before writing `RESULT-1.md`; the verifier works from a throwaway worktree at that commit. Do not
chain `git push` onto the commit — push separately with an explicit timeout.

`RESULT-1.md` must record: exact commands and output for AC0–AC21; mutation evidence both directions;
committed vs observed for any drifted figure; the live workbook's hash and mtime before and after; and
anything not verified, named plainly rather than omitted.
