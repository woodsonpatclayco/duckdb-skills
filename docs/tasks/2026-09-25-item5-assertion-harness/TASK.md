Plan: PLAN-4.md (item 5). Splits PLAN-4 §5 in two: this spec is the harness; direction-aware
row-count tolerance moves to a follow-on item (see "Split out of this spec").
Serves: "if a sheet quietly stops giving me all the rows, or a column quietly goes blank, I want to
be told — not to find out from a number that looks plausible and is wrong."

# TASK — Assertion harness over multiple contracts (item 5)

PLAN-4 §5 defined this item's purpose as a **silent-nulling detector**. That purpose is void: both of
its mutation tests depend on behaviour that no longer reproduces. This spec replaces the justification
and, on review, **narrows the item** — direction-aware row tolerance is split out, because it is the
one deliverable whose correct behaviour cannot yet be stated.

It also corrects a latent defect in item 4's shipped contract that item 4's own checks cannot detect.

---

## What this item is actually for

Being precise about this, because the first draft got it wrong. Blank-row truncation (measured below)
is real, but **deliverable 3 eliminates it** with a one-line read-option change per contract. A
detector for a hazard that the same spec removes cannot be the harness's reason to exist.

The reasons, in order:

1. **Nothing runs more than one contract.** `check-contract.ps1` takes a single file. With a second
   contract landing here, "run every contract and tell me what broke" has no implementation.
2. **The per-column floors are the actual silent-failure guard.** A column that quietly stops being
   populated raises no error, changes no type, and every aggregate still computes. Floors are the only
   thing that notices, and they must be measured per column — `Job #` is 219 of 219 where `End Date`
   is 145 of 219.
3. **The truncation check is a regression guard on deliverable 3's read rule**, not a live-data
   detector. It exists so that removing `stop_at_empty = false` in some future edit fails loudly
   against a fixture instead of silently on Phil's numbers. That is a real job, stated honestly at
   its real size.

## Split out of this spec

**Direction-aware row-count tolerance.** PLAN-4 §5 asks for it, and it needs its own item: the
tolerance values are not measurable from two data points, and the sheets move in opposite directions
(GL grows, `All_Sales_Data` shrank 227 → 226 → 219, while its `Start Date` values run to 2027 and will
grow again). A rule keyed to a "declared direction" would make legitimate growth in the sales sheet a
failure — the exact cry-wolf outcome the plan asked direction-awareness to prevent.

This spec uses **conservative absolute floors** instead, stated here so no implementer invents them:

| contract | floor | why it cannot cry wolf |
|---|---|---|
| `Clayco_Job_Costs_from_GL` | **≥ 50,000** rows | lowest ever observed is 57,801 (2026-08-11) |
| `All_Sales_Data` | **≥ 200** rows | observed 227 → 226 → 219; never near 200 |

A floor catches a collapse and ignores ordinary movement in either direction. Replacing floors with
real tolerance is the follow-on item's job.

---

## Conventions that are not optional

Carried from items 3+4, all still apply.

- **SQL lives in `.sql` files invoked with `duckdb -f`**, never inline `duckdb -c`.
- **Write every file with `[IO.File]::WriteAllText` plus `New-Object Text.UTF8Encoding($false)`.**
  Never `Set-Content -Encoding UTF8` — BOM breaks DuckDB.
- PowerShell 5.1: `;` never `&&`, absolute paths.
- **Gate on `$LASTEXITCODE`, never on stderr being empty.** PowerShell throws a terminating
  `NativeCommandError` on *any* `duckdb` stderr output under `$ErrorActionPreference = 'Stop'`, even
  with stderr redirected. `tools\check-contract.ps1` scopes `'Continue'` around its DuckDB calls —
  copy that.
- **`LOAD excel;` is required before `COPY ... TO (FORMAT xlsx)`.** Measured: without it,
  `Catalog Error: Copy Function with name xlsx does not exist!`. `read_xlsx` autoloads; the COPY
  function does not.
- **Resolve repo paths from `$PSScriptRoot`**, never hardcoded absolutes — `.gitignore:3` excludes
  `.duckdb-skills/`, so no macro state file exists in a verifier's fresh worktree.
- **The workbook is read-only.** 34 dependents, 18 latent orphaned Power Query connections.
- **Do not touch `docs\tasks\2026-09-24-items34-sheet-discovery-contract\`.** Those files record what
  round 1 built and proved. Deliverable 3 edits live `contracts\*.sql` only; the archive's figures
  stay as shipped even where this item supersedes them.
- The repo root has an untracked 12 KB file named **`Revenue`** — a stray DuckDB database from a
  mis-parsed command line, unrelated to this work. Leave it untracked and do not `git add -A`. The
  cleanliness gate is "no tracked file modified outside this item's scope".

---

## Why PLAN-4 §5's stated purpose is void

| PLAN-4 §5 mutation | expected | measured 2026-09-24 |
|---|---|---|
| 1. drop `all_varchar`, add `ignore_errors=true` → `VENDOR_NAME` 51,571 → **0** | silent nulling detected | **51,928** — no collapse, identical to `all_varchar`, exit 0 |
| 2. drop `all_varchar` → `'City of DeKalb'` parse error | loud failure | **exit 0**, 62,110 rows |

Neither reproduces. Do not write either as an acceptance check.

`SHIPPED.md` told item 5 to rebuild its mutations on **type fidelity**. This spec uses truncation and
floors instead: type fidelity is already discharged by item 4's AC9/AC12 and `checks\gl-facts.sql`, so
rebuilding on it would re-test shipped work rather than cover new ground.

---

## Measured facts — all measured this session

### Which failures are already loud, and therefore need no harness

| failure | behaviour | measured |
|---|---|---|
| column renamed or removed | **LOUD** | `Binder Error: Referenced column "NO_SUCH_COLUMN" not found in FROM clause!`, exit 1 |
| uncastable value under a hard `::` cast | **LOUD** | `Conversion Error: Could not convert string "N/A" to DECIMAL(18,2)`, exit 1 |
| the same value under `TRY_CAST` | **SILENT** | NULL, exit 0 |

The binder already polices schema drift at bind time, before a row is read, so the harness need not.
The third row is why a contract must never use `TRY_CAST` — that rule is load-bearing, not stylistic.

### One blank row discards the rest of the sheet

`read_xlsx` stops at the first empty row by default. **Fixture A** — one definition, all figures
measured, not derived from prose:

```
VALUES ('NM','AMT'),('r1','10'),('r2','20'),(NULL,NULL),('r4','40'),('r5','50'),('r6',NULL)
        header       data ----------------  BLANK        ------------------------  partial
```

5 data rows; `AMT` populated on 4 of them; **true sum 120.00** — both facts read off the `VALUES` list,
not off any `read_xlsx` call.

| read | rows | sum | exit |
|---|---|---|---|
| default | **2** | **30.00** | **0** |
| `stop_at_empty = false`, raw | 6 | — | 0 |
| `stop_at_empty = false` + all-null filter | **5** | **120.00** | 0 |

**Three data rows silently lost and the sum wrong by 75 %, with exit 0** and no warning. On a
62,110-row sheet a single stray blank row reduces the answer to whatever preceded it.

Both sheets are ListObjects fed by Power Query (`xl/tables/table*.xml`, contiguous `ref=`). An
all-empty ListObject row is permitted and arises from an all-NULL source row or from a user clearing a
row's *contents* rather than deleting the row. It has **not** occurred here — do not claim a partial
refresh causes it, as annotation #28 records a full 65-connection refresh completing cleanly.

### Item 4's checks cannot detect it, by construction

Item 4's AC5 compares the view's count against a direct `read_xlsx` count **in the same run**. Both
truncate identically, so they agree while both are wrong. The internal-consistency gate that makes
item 4 robust to drift is exactly what blinds it here.

### The partially-null trap in the obvious shorthand

`NOT (COLUMNS(*) IS NULL)` reads as "no column is null" and therefore **drops partially-populated
rows**. Measured on fixture A: the generated predicate keeps **5** rows, the shorthand keeps **4** —
it discards `r6`. On `All_Sales_Data`, where `Revenue Total` is 201 of 219 and `End Date` 145 of 219,
the shorthand would silently drop dozens of real rows. **The predicate must be generated explicitly**
as `NOT (c1 IS NULL AND c2 IS NULL AND ...)`; fixture A's `r6` exists to make that failure visible.

### The all-null predicate must cover every sheet column, not the contract's projection

If the predicate covers only the columns the contract projects, a row populated **solely** in an
unprojected column is dropped, and nothing notices. Measured on a 3-column fixture whose last row is
populated only in column `C`:

| measure | value |
|---|---|
| default read | 3 |
| with-data over **all 3** sheet columns | **3** — agrees, nothing lost |
| with-data over the **2 projected** columns | **2** — the row is dropped |
| anchor non-null among survivors | 2 — **assertion still passes** |

This is live for this workbook: annotations #14 and #42 record that new columns are deliberately
appended last, so the first time `All_Sales_Data` gains a 17th column, a row populated only in it would
vanish. The predicate covers **every column `read_xlsx` returns**.

### The anchor-column assertion does not license the filter — this does

Asserting an anchor column is 100 % non-null proves nothing about dropped rows: assertions evaluate
against `contract_view`, which is already filtered, and dropping all-null rows can only *raise* the
anchor's non-null rate. The counterexample above passes it.

**The non-circular check is: the view's row count equals the with-data count over all sheet columns, in
the same run.** That is item 4's AC5 gate, retained and relabelled — and it is what actually catches
the orphan-column case. The anchor assertion is kept as a useful floor, not as a licence.

### Both real sheets are clean today, so deliverable 3 is provably neutral

| sheet | default | with-data, all columns | verdict |
|---|---|---|---|
| `Clayco_Job_Costs_from_GL` | 62,110 | **62,110** | no truncation |
| `All_Sales_Data` | 219 | **219** | no truncation |

The GL correction changes no shipped figure: 62,110 rows, `SUM(JOB_COSTS)` 22,454,928,166.83, floors
62,110 / 51,928 / 18,764 all hold under the new read. Prove it again rather than assuming.

### Item 4 shipped a row-count assertion that will fail on ordinary growth

`contracts\Clayco_Job_Costs_from_GL.sql:53` asserts `row_count ... = 62110` as **hard equality**, while
item 4's own policy is that a moved count is "drift to report, not a defect". The sheet moved three
times in six weeks. Left alone, the harness exits non-zero the moment it grows by one row.

Deliverable 3 replaces it with the two forms that are actually correct: the **floor** (≥ 50,000) and
the **internal-consistency** equality (view rows = with-data rows). The absolute count becomes reported
context, not a gate.

### `COPY TO xlsx` writes no header row

Verified. The first data row is otherwise consumed as the header, shifting every count by one. Write
the header explicitly as the first row.

### The second contract: `All_Sales_Data`

219 rows, 16 columns. Chosen because it stresses what the GL sheet cannot: **headers with spaces and
punctuation** — `Sales Year`, `Folder Path`, `Job #`, `Start Date`, `Revenue Total`, and
`match project` (lowercase, spaced, the most hostile of them). The GL sheet's 13 names are clean
identifiers, so Decision 2's quote-exactly rule has never been exercised against a hostile header.

All 16, in order:

```
Sales Year | Filename | Folder Path | Business Unit | Job # | Status | Status_Description | Market
| Client | Start Date | End Date | State | Project Name | Revenue Total | Earnings Total | match project
```

| metric | value |
|---|---|
| rows / columns | **219** / **16** |
| `Job #` non-null | **219** of 219 — the anchor |
| `match project` non-null | **214** |
| `Revenue Total` / `Earnings Total` non-null | **201** / **201** |
| `Start Date` / `End Date` non-null | **150** / **145** |
| `Start Date` all-digit (of non-null) | **150** of 150 |
| `SUM("Revenue Total")` | **36,580,445,574.84** |
| `SUM("Earnings Total")` | **1,439,728,975.91** |
| `Start Date` via `xl_date` | **2023-07-15** to **2027-03-15** |
| `Sales Year` distinct | **4** |
| `MAX("Revenue Total")` lexicographic vs cast first | **99266455** vs **1,682,000,000.00** |

That last row discharges PLAN-4 §5's "casts applied before any range comparison" on the new contract —
a 17× error if the cast is skipped.

### Why a second contract is required rather than optional

With one contract, "runs **each** contract's assertions" ships with no passing evidence. That is the
gap item 2b left and has still not discharged: every `extract-decide.ps1` fixture is single-object, so
its multi-object rule remains unverified. Do not repeat it.

---

## The contract read rule

**Contracts read with `stop_at_empty = false` and exclude rows where every column `read_xlsx` returns
is NULL.** Measured against fixture A, this is the only one of the three candidates that is right:

| approach | fixture A rows | correct? |
|---|---|---|
| default | 2 | no — 3 data rows lost |
| `stop_at_empty = false` alone | 6 | no — phantom blank row included |
| `stop_at_empty = false` + all-null filter | **5** | **yes** |

---

## Deliverables

### 1. Additive contract directives — the harness's declared inputs

The harness needs per-contract metadata that exists nowhere today. **Adding directives is explicitly
not "changing item 4's grammar"** — item 4's `-- @assert` grammar and both guards are inherited
verbatim. These are new, parsed the same way (same comment form, same `<name>:` split, same
before-the-view timing):

```sql
-- @sheet: Clayco_Job_Costs_from_GL
-- @anchor: JOB_COSTS
-- @rows_floor: 50000
-- @fingerprint: PARENT_PROJECT_NUMBER|PROJECT_COMPANY|...|JOB_COSTS
```

`-- @sheet` is required (the harness needs the sheet name to perform the second read; regexing it out
of the `read_xlsx` call is not acceptable). `-- @anchor`, `-- @rows_floor`, `-- @fingerprint` are
required, exactly one of each, and a missing or duplicated one is an **error**, like a malformed
`-- @assert`. The workbook path is read from the contract's existing `read_xlsx` call — it is already
pinned there and must not be duplicated into a directive where the two could disagree.

### 2. `tools\run-assertions.ps1` — the harness

`tools\run-assertions.ps1 [-Contract <path>]`

No argument: discovers and runs every `.sql` in `contracts\`. With `-Contract`: runs one, and accepts a
path outside `contracts\` so fixtures can be checked without becoming discoverable contracts.

Per contract it emits **one labelled `check_id,value` line per result** — the pattern that made items
3+4 hold, so the verifier reads values rather than parsing prose:

```
CONTRACT,Clayco_Job_Costs_from_GL
ASSERT,row_count,PASS
TRUNCATION_DEFAULT_ROWS,62110
TRUNCATION_WITHDATA_ROWS,62110
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,62110
ANCHOR,JOB_COSTS,62110,PASS
ROWS_FLOOR,50000,62110,PASS
FINGERPRINT,MATCH
SUMMARY,contracts=2,assertions=N,failures=0
```

Exit non-zero if any assertion FAILs, any ERROR occurs, the truncation check finds rows lost, the
consistency check disagrees, the anchor is not 100 % non-null, or the floor is breached. A fingerprint
mismatch reports `FINGERPRINT,DRIFT` with both lists and does **not** fail, per items 3+4's drift
policy. A DuckDB error is reported as **ERROR** with the message verbatim and exits non-zero — it is
never downgraded to a FAIL line.

State in the header whether it calls `check-contract.ps1` or supersedes it. **Performance:**
`check-contract.ps1` re-reads the 68 MB workbook once per assertion — measured 5.9 s for 7 assertions.
A `stop_at_empty=false` read into a `TEMP TABLE` plus aggregate queries measured **1.4 s** total. Use
the TEMP TABLE, but evaluate the fingerprint and declared types against the **view**, since the view is
what carries them.

### 3. `contracts\All_Sales_Data.sql` — the second contract

All 16 columns cast explicitly, headers quoted exactly including spaces and `#`, the read rule above,
`Job #` as anchor, floor 200, money as `DECIMAL(18,2)`, `Start Date`/`End Date` via `xl_date`. Floors
measured per column — `Job #` at 219 and `End Date` at 145 are nothing alike. Include a cast-before-
compare assertion on `MAX("Revenue Total")`.

### 4. Correction to `contracts\Clayco_Job_Costs_from_GL.sql`

Add the read rule, the four directives, and replace the hard `row_count = 62110` with the floor plus
the consistency equality. **Every committed figure must be unchanged**; prove it.

Note this changes what item 4's AC5 compares — `contract_view` becomes a filtered
`stop_at_empty=false` read while `checks\gl-facts.sql`'s `direct_varchar` is still a default read. Both
are 62,110 today (measured). Keep that comparison and relabel it: it is now the orphan-column detector,
and it is in scope to update `checks\gl-facts.sql`'s comments to say so.

### 5. `tools\make-truncation-fixtures.ps1`

Builds fixture A (above) and fixture B (trailing blanks only: header, r1/10, r2/20, r3/30, then two
all-null rows). Committed, so the verifier reproduces them from a clean worktree. `LOAD excel;` first.

---

## Out of scope

- Direction-aware row tolerance — split to its own item.
- Lakehouse materialization and workbook freshness — item 6; cross-source join — item 8.
- A third contract beyond the two named. Fixture contracts are not contracts.
- `Project_Profit`.
- Changing item 4's `-- @assert` grammar or its two guards. Inherit them; deliverable 1 adds, never
  alters.
- Any write to the source workbook; any edit under `docs\tasks\`.
- Item 2b's unverified multi-object extract path. Still outstanding, still not this item.

---

## Acceptance checks

Every check is a literal command with a literal expected line. All run without Snowflake.

**AC0** In a throwaway worktree at the implementer's commit, `tools\run-assertions.ps1` exits 0 on
first invocation with no setup. Quote the `SUMMARY` line. (`.duckdb-skills\` will not exist there;
note that `LOAD excel` resolves from `~\.duckdb\extensions`, outside the repo, so this holds on a
machine that has already used the extension.)

**AC1** `tools\run-assertions.ps1` (no argument) emits `CONTRACT,Clayco_Job_Costs_from_GL` and
`CONTRACT,All_Sales_Data`, and `SUMMARY,contracts=2,...,failures=0`. Exit 0.

**AC2** `tools\make-truncation-fixtures.ps1` builds both fixtures. Running the harness against fixture
A with the contract read rule gives `5` rows and sum `120.00` — the values read off fixture A's
`VALUES` list, not back out of the file.

**AC3** *The detector fires.* On fixture A the harness emits `TRUNCATION_DEFAULT_ROWS,2`,
`TRUNCATION_WITHDATA_ROWS,5`, `TRUNCATION_ROWS_LOST,3` and exits **non-zero**.

**AC4** *No false alarm.* On fixture B: `TRUNCATION_ROWS_LOST,0`, exit 0 — default 3, with-data 3,
despite the raw `stop_at_empty=false` count being 5.

**AC5** *The partially-null trap.* On fixture A the with-data count is **5**, not 4. A `COLUMNS(*)`
shorthand gives 4; the generated predicate is what makes this 5.

**AC6** *Control.* On both real sheets `TRUNCATION_ROWS_LOST,0` — GL 62,110/62,110 and
`All_Sales_Data` 219/219. Labelled a control: it passes today and AC3 is the only evidence the detector
works.

**AC7** *The GL correction moves nothing.* `CONSISTENCY_VIEW_ROWS,62110`, `SUM(JOB_COSTS)`
**22,454,928,166.83**, floors **62,110 / 51,928 / 18,764**, `FINGERPRINT,MATCH`. Report committed vs
observed side by side; live-sheet drift is drift to report, but the correction itself must move nothing.

**AC8** `duckdb -f checks\gl-facts.sql` still emits `AC5_VIEW_ROWS,62110` and `AC5_DIRECT_ROWS,62110`
with every other line unchanged — item 4's shipped verification is not regressed.

**AC9** `All_Sales_Data` figures: rows **219**, columns **16**, `Job #` **219**, `match project`
**214**, `Revenue Total` **201**, `Earnings Total` **201**, `Start Date` **150**, `End Date` **145**,
`SUM("Revenue Total")` **36,580,445,574.84**, `SUM("Earnings Total")` **1,439,728,975.91**, `xl_date`
range **2023-07-15**–**2027-03-15**.

**AC10** *Hostile headers reached, provably.* `count(DISTINCT "Sales Year")` = **4** and
`count("match project")` = **214** — values reachable only through the exactly-quoted names, so this
cannot pass merely because the read succeeded.

**AC11** *Cast before compare, on the new contract.* `MAX("Revenue Total")` cast first is
**1,682,000,000.00**; lexicographic on the raw varchar is **99266455**.

**AC12** *The floors bite.* Both contracts carry `ROWS_FLOOR` (50,000 and 200) and both PASS. Lower a
throwaway copy's floor above its actual count and the harness **fails** naming the contract.

**AC13** *Grammar and guards inherited.* On throwaway copies in `$env:TEMP`, deleted after: zero
`-- @assert` lines exits non-zero; a malformed directive exits non-zero rather than being skipped; a
missing `-- @sheet`, `-- @anchor`, `-- @rows_floor` or `-- @fingerprint` exits non-zero; a duplicated
one exits non-zero.

**AC14** *Errors stay errors.* Renaming a column in a throwaway contract copy to one that does not
exist produces `ERROR` with the `Binder Error` text verbatim and a non-zero exit — not a FAIL line.

**AC15** *Control.* Workbook SHA-256 and `LastWriteTime` identical before and after. Baseline
`CD6342D03B4F9AC177859778A3625E56DB506F649512E081230BD9A86A7B968F`, `2026-09-24T09:38:56`. A changed
hash with a later mtime is a SharePoint sync — report and re-baseline; a changed hash at the same mtime
is a write by this run and a hard failure.

**AC16** No file created or modified by this item contains a UTF-8 BOM. Give the one-liner; expect
empty output.

### Mutation proof required

Each failing, then passing after revert. Mutate only this item's files — never
`skills\query\duckdb-compat.sql`, never the workbook, never `docs\tasks\`.

- **remove `stop_at_empty = false` from the fixture-A check path** → AC3 fails to report rows lost.
  (Note: mutating the *GL contract* cannot affect AC3, which is computed from fixture A — that is why
  the fixture exists, and why the real sheet cannot prove this.)
- **remove the all-null filter** → fixture B gains a phantom NULL row; AC4 fails.
- **narrow the all-null predicate to the contract's projected columns** → the orphan-column case is
  dropped silently; the consistency check in AC7 fails.
- **swap the generated predicate for `NOT (COLUMNS(*) IS NULL)`** → AC5 gives 4 instead of 5.
- **point an anchor at `VENDOR_NAME`** (51,928 of 62,110) → the anchor check fails naming it.

`git status` must show no tracked file modified outside scope before `RESULT-1.md` is written; the
untracked `Revenue` file is expected and must not be added.

---

## Commit and handoff

Commit before writing `RESULT-1.md`; the verifier works from a throwaway worktree at that commit. Do
not chain `git push` onto the commit — push separately, with an explicit timeout.

`RESULT-1.md` must record: exact commands and output for AC0–AC16; mutation evidence both directions
for all five mutations; committed vs observed for every figure with any live drift named; the workbook
hash and mtime before and after; and anything not verified, named plainly rather than omitted.

---

# CORRECTIONS — round 2

Round 1 shipped the harness and both contracts, and 12 of 17 checks passed clean. The other five did
not fail because the harness is wrong — they failed because **the workbook refreshed overnight** and
item 4's contract asserts absolute snapshots by equality.

Confirmed independently, live file now `2026-09-25 08:48:13` (was `2026-09-24 09:38:56`):

| figure | committed | observed 2026-09-25 |
|---|---|---|
| GL rows | 62,110 | **62,230** |
| `JOB_COSTS` non-null | 62,110 | **62,230** |
| `VENDOR_NAME` non-null | 51,928 | **52,037** |
| `GL_PERIOD` non-null | 18,764 | **18,884** |
| `SUM(JOB_COSTS)` | 22,454,928,166.83 | **22,478,661,033.93** |
| `All_Sales_Data` rows | 219 | 219 — unchanged |

The implementer correctly refused to edit those figures to make checks pass, and said so. That was the
right call and it exposed a defect in this spec, not in the work.

## C1 — I corrected an instance; the defect is a class

This spec's deliverable 4 named **only** `row_count` as the hard-equality assertion to replace. But
`jobcosts_nn`, `vendorname_nn`, `glperiod_nn` and `jobcosts_sum` have exactly the same defect, and the
same reasoning condemns all five. Leaving four in place means the harness reports `failures=4` on every
refresh forever — a monitor that always cries wolf is worse than none, because it trains you to ignore
it.

**The ratios are stable where the counts are not.** Measured across the refresh that moved every count:

| column | ratio 09-24 | ratio 09-25 |
|---|---|---|
| `JOB_COSTS` | **1.00000** | **1.00000** |
| `VENDOR_NAME` | 0.83607 | 0.83620 |
| `GL_PERIOD` | 0.30211 | 0.30345 |

So every assertion in every contract must be reclassified into one of three kinds, and the kind
determines the form:

**Invariants — assert as a relationship, never a literal. Refresh-proof.**

- anchor completeness: `count(<anchor>) = count(*)` — measured to hold exactly across the refresh where
  `= 62110` did not. This replaces `jobcosts_nn`.
- `(SELECT any_value(typeof(GL_PERIOD)) FROM contract_view) = 'DATE'`
- consistency: view rows = with-data rows over all sheet columns
- the money sum has **no floating-point tail** — the AC9 property from items 3+4, which is a property of
  the cast and cannot drift

**Floors — measured ratios with justified headroom. Survive growth and ordinary shrink.**

| contract | assertion | floor | headroom |
|---|---|---|---|
| GL | rows | ≥ **50,000** | lowest ever observed 57,801 |
| GL | `VENDOR_NAME` non-null ratio | ≥ **0.80** | observed 0.836 twice |
| GL | `GL_PERIOD` non-null ratio | ≥ **0.25** | observed 0.302, 0.303 |
| `All_Sales_Data` | rows | ≥ **200** | observed 227, 226, 219 |
| `All_Sales_Data` | `Job #` | `count = count(*)` — anchor invariant | 219 of 219 |
| `All_Sales_Data` | `Revenue Total` ratio | ≥ **0.85** | observed 0.918 |
| `All_Sales_Data` | `End Date` ratio | ≥ **0.55** | observed 0.662 |
| `All_Sales_Data` | `match project` ratio | ≥ **0.90** | observed 0.977 |

**Snapshots — reported, never asserted.** Absolute row counts, absolute non-null counts, and the money
sum itself. Emit them as `check_id,value` context lines so Phil can tie the sum to a report, and so
drift is visible. A snapshot must never gate the exit code.

`SUM(JOB_COSTS)` is the clearest case: Phil ties it to a report, so its **value** must be printed
prominently, and its **assertion** is that the cast produced an exact decimal.

## C2 — the acceptance checks must stop gating on snapshots

AC7 and AC9 currently pin absolute counts and sums as gates, which is the same defect one level up.
Revised: they assert the invariants and floors, and **report** the snapshots side by side with the
committed values. AC0/AC1's `failures=0` becomes reachable again and stays reachable.

This also resolves the contradiction the reviewer flagged between deliverable 4's "every committed
figure must be unchanged" and the drift policy. The correct statement: **the correction must not change
what the contract computes.** Whether the underlying sheet moved is not the correction's business.

## C3 — re-baseline the workbook control

AC15's own rule says a changed hash with a later `LastWriteTime` is a SharePoint sync: report and
re-baseline. Doing that. New baseline:

```
A9CFF71AC5CBC83CB792676CB12AB317FEAE9BDFCB734BD11F208FFB29BA33E3
2026-09-25 08:48:13
```

The round-1 mismatch was a sync that predates the session, not a write by it. AC15 behaved correctly
and passes.

## C4 — the orphan-column fixture is blessed, and must be committed

Round 1 had to build a purpose-built 3-column fixture to demonstrate the projected-columns mutation,
because neither real contract has an orphan column today. That is correct and unavoidable — it is the
same reason fixture A exists. Promote it to **fixture C**, built by
`tools\make-truncation-fixtures.ps1` and committed, so the verifier reproduces it rather than
improvising. Its shape: three columns, last data row populated **only** in the third.

Expected, measured: default read 3, with-data over all three columns **3** (agrees — nothing lost),
with-data over the two projected columns **2** (the row is dropped), anchor non-null among survivors
**2** (assertion still passes). That triple is what proves the predicate must span every column.

## Revised acceptance checks

Unchanged: AC2, AC3, AC4, AC5, AC6, AC8, AC10, AC11, AC12, AC13, AC14, AC16.

**AC0′ / AC1′** As before, and `SUMMARY,...,failures=0` must now hold — on the live sheet, whatever it
has drifted to. Quote the summary line.

**AC7′** The GL correction changes nothing the contract *computes*: `FINGERPRINT,MATCH`; the consistency
equality holds; the anchor invariant `count(JOB_COSTS) = count(*)` holds; the sum has no floating-point
tail; all three floors pass. **Report** rows, the three non-null counts, and the sum as snapshots with
committed and observed side by side — no snapshot gates the exit code.

**AC9′** `All_Sales_Data`: 16 columns, the anchor invariant on `Job #`, all four ratio floors pass, and
`xl_date` range within **2023-07-15**–**2027-03-15** unless the sheet has genuinely extended, in which
case report it. Report the absolute counts and both sums as snapshots.

**AC17 (new)** *Refresh-proofing, demonstrated.* Show that the reclassified assertions survive a row
count change, by running the harness against a copy of a contract pointed at fixture A and again after
adding a data row to the fixture: the invariants and floors pass both times, and only the snapshot
values differ. This is the check that proves C1 actually solved the class and not just today's numbers.

**AC18 (new)** *No snapshot gates the exit.* Change a snapshot's committed value in a throwaway
contract copy to a deliberately wrong number. The harness reports the difference and still exits **0**.
Change a floor so it is breached, and it exits non-zero. This proves the two categories are wired
differently rather than merely labelled differently.

### Mutation proof, added

- **convert the anchor invariant back to `count(JOB_COSTS) = 62110`** → passes today only by accident of
  timing and must fail against fixture A with a row added (AC17). This is the regression guard on C1
  itself.

## Handoff

Round 2 commits on top of round 1; do not rewrite round 1's commits. `RESULT-2.md` must record the
reclassification per assertion per contract — which kind each became and why — plus AC17 and AC18
evidence, and the committed-vs-observed snapshot tables. `REVIEW-task-1.md` and the untracked `Revenue`
file stay untracked.
