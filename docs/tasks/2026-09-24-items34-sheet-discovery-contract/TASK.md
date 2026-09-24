Plan: PLAN-4.md (items 3 and 4)
Serves: "show me which sheets exist in that workbook, and prove we can read one of them correctly
without corrupting it" — the first sheet DuckDB can read with money, IDs, and dates all intact.
After this, item 5 makes the assertions run across every contract.

# TASK — Sheet discovery and the first workbook contract (items 3 + 4)

Two items, one spec, because item 3 is the tool that tells you a sheet exists and item 4 is the
first proof that a sheet can be read correctly. Shipping 3 alone would deliver a lister with
nothing to list against.

Scope: `tools\list-sheets.ps1`, one contract file for `Clayco_Job_Costs_from_GL`, a committed checks
file, the assertion grammar both this item and item 5 depend on, and a single-contract runner that
proves the grammar executes.

**No acceptance check in this spec needs Snowflake.** Verified: every check below was run this
session with no connection. So unlike item 2b, the verifier can certify the whole thing and the main
session re-runs nothing.

---

## Conventions that are not optional

- **SQL lives in `.sql` files invoked with `duckdb -f`, never inline `duckdb -c`.** PowerShell
  expands `$` inside double-quoted strings, and — measured — a quoted identifier containing a
  literal newline is truncated at the newline when passed through `-c`, giving
  `Parser Error: syntax error at end of input`. It survives only via `-f`. This does not bite the 13
  clean names in this contract but will bite the first `Project_Profit` contract.
- **Write every file with `[IO.File]::WriteAllText` plus `New-Object Text.UTF8Encoding($false)`.**
  Never `Set-Content -Encoding UTF8` — it emits a BOM that DuckDB chokes on.
  `tools\ensure-duckdb-compat.ps1:91` already does this correctly; copy it.
- PowerShell 5.1: `;` never `&&`, absolute paths.
- **Gate success on `$LASTEXITCODE`, never on stderr being empty.** `duckdb -init` writes a
  `-- Loading resources from ...` banner to **stderr** while exiting 0, and PowerShell surfaces that
  as an error record.
- `duckdb -init` takes exactly one file; a second silently replaces the first.

---

## The workbook, pinned

```
C:\Users\woodsonp\Clayco, Inc\Profit Plans - General\Analytics\Excel Exports Data Warehousing\Domo\Data Extracts.xlsm
```

67,980,942 bytes, modified 2026-09-24 09:38:56. **Pin this path.** There are 31 files named
`Data Extracts*.xlsm` on this machine — `Data Extracts.PP.xlsm`, `Data Extracts.STEP23b.xlsm`,
`Data Extracts.prebid_rollback.xlsm`, `Data Extracts.NEW.xlsm`, and more. One other name is within
5 % of the live file's size. Every number below is meaningless without the path.

The path contains **a comma and spaces**. Verified working forms:

- PowerShell: double-quoted, backslashes — `"C:\Users\woodsonp\Clayco, Inc\...\Data Extracts.xlsm"`
- DuckDB: single-quoted, **forward** slashes — `'C:/Users/woodsonp/Clayco, Inc/.../Data Extracts.xlsm'`

### Read-only is load-bearing, not a preference

The dependency graph puts **34 dependents** on this file, and it carries **18 orphaned Power Query
connections** — including `Clayco_Job_Costs_from_GL_Query_String`, the one this contract replaces
the read for. Those orphans are latent, not active: the file opens clean today. But a connection
whose `Location=` names a missing query is precisely the condition that triggers Excel's repair
prompt, and repair resolves it by **deleting the table and the connection together**.

So: never open this workbook in Excel, never write a byte to it, never hand it to openpyxl.
`read_xlsx` and zip reads are safe — DuckDB reads sheet values only and never touches
`vbaProject.bin` or the DataMashup blob.

**On any lock or IO error, fail loudly with the full path. Never fall back to another file.** With
31 similarly-named workbooks in play, a silent fallback means reporting confident numbers measured
against the wrong file.

---

## Measured facts — all re-measured 2026-09-24 on this machine

### PLAN-4's pinned figures for this sheet are stale, and its justification does not reproduce

Two separate problems. Both shape this spec.

**Stale figures.** The sheet has grown. Graph annotation #28 independently recorded it moving
57,801 → 58,403 rows on 2026-08-11, so PLAN-4's numbers were already behind when written:

| metric | PLAN-4 says | measured now | status |
|---|---|---|---|
| rows | 61,741 | **62,110** | drifted |
| `COUNT(VENDOR_NAME)` | 51,571 | **51,928** | drifted |
| `GL_PERIOD` non-null | 18,395 | **18,764** | drifted |
| `SUM(JOB_COSTS)` | 22,390,953,840.93 | **22,454,928,166.83** | drifted |
| `MAX(JOB_COSTS)` cast first | 256,178,387.75 | **256,178,387.75** | holds exactly |
| `MAX(JOB_COSTS)` lexicographic | `'99999.72'` | **`'99999.72'`** | holds exactly |
| `GL_PERIOD` min / max | 2026-07-01 / 2026-10-01 | **2026-07-01 / 2026-10-01** | holds |
| `typeof(xl_date(...))` | `DATE` | **`DATE`** | holds |
| `TRY_CAST(serial AS DATE)` | NULL | **NULL** | holds |
| column count | not stated | **13** | new |

**The justification does not reproduce.** PLAN-4 lines 175–178 claim `VENDOR_NAME` infers DOUBLE,
that `ignore_errors=true` silently yields `COUNT(VENDOR_NAME)` = 0 of 61,741, and that a bare read
fails loudly with `Could not convert string 'City of DeKalb' to DOUBLE`. **None of the three is
true today:**

| PLAN-4 claim | measured now |
|---|---|
| `VENDOR_NAME` infers DOUBLE | infers **VARCHAR** |
| `ignore_errors=true` → `COUNT(VENDOR_NAME)` = 0 | **51,928** — identical to `all_varchar` |
| bare read fails on `'City of DeKalb'` | **exit 0, 62,110 rows, no error** |

Do not write an acceptance check asserting any of them; it will fail. Whether the cause is changed
data or improved `read_xlsx` inference is not worth chasing — what matters is that the contract
discipline needs a justification that is actually reproducible. It has one.

### The real reason for `all_varchar = true`: type fidelity, not parse errors

Bare inference does not error — it silently picks types that lose data:

| column | bare infer | consequence |
|---|---|---|
| `JOB_COSTS` | `DOUBLE` | money in binary floating point |
| `VENDOR_NUMBER` | `DOUBLE` | renders **`17054.0`** |
| `ACCRUAL_FLAG` | `DOUBLE` | a flag as float |
| `GL_PERIOD` | `DATE` | **correct** — see below |

Measured, on the same 62,110 rows:

```
DOUBLE  sum (bare infer)   22454928166.829914
DECIMAL sum (all_varchar)  22454928166.83
```

A fraction of a cent on $22.45 B — small, real, and not reproducible across a different row order.
`VENDOR_NUMBER` is worse and has no rounding excuse: `17054.0` will not join to a Snowflake
`VENDOR_NUMBER` of `17054`, and the join fails as *no matching rows*, which reads like a business
finding rather than a type bug. That is the argument for the contract, and it is demonstrable.

**The difference is −8.7738037109375e-05.** The rounded rendering `-0.000088` appears nowhere as an
assertion, and **must never be asserted by equality**: subtracting the two *printed* decimals above
gives `-0.000086`, not `-0.000088`, and reconciling those two renderings is a wasted round. AC9's
gate is that the view's value has no floating-point tail and that the two paths differ — never the
size of the difference.

### `all_varchar` is a trade, not a free win — which is why `xl_date` exists

Bare inference gets `GL_PERIOD` **right**: `DATE`, 2026-07-01 to 2026-10-01, 18,764 non-null.
`all_varchar = true` throws that away, returning raw Excel serials as VARCHAR, and
`TRY_CAST('46204' AS DATE)` → **NULL**, silently. So the contract buys money and ID fidelity at the
cost of date decoding, then rebuilds dates with item 1's shipped `xl_date()` macro.

This gives the spec its one genuinely **independent** check — two unrelated decoders, DuckDB's own
C++ serial decoder and our pure-arithmetic macro. Because it is the only check here with an external
oracle, it is formulated row-wise in AC8; see the warning there.

### Why the casts cannot throw — record this, it is the contract's safety condition

Measured on the non-null rows:

- `GL_PERIOD` is all-digits in **18,764 of 18,764** → `::BIGINT` cannot fail
- `JOB_COSTS` is castable in **62,110 of 62,110** → `::DECIMAL(18,2)` cannot fail

State this in the contract as a comment. Without it, a future sheet carrying one stray text cell
turns the whole contract into a hard conversion error and nobody will know the safety condition was
ever checked. (`xl_date` is null-safe and accepts a VARCHAR serial directly — `xl_date('46204')`
returns `2026-07-01`/`DATE`, `xl_date(NULL)` returns NULL — so the explicit `::BIGINT` is
belt-and-braces, not load-bearing.)

### The lexicographic trap, unchanged

On `all_varchar` columns `MAX(JOB_COSTS)` is `'99999.72'` — string ordering. Cast first and it is
**256,178,387.75**. Both figures are byte-identical to PLAN-4's, so this demo is stable.

### Null rates are per-column and must never be templated

| column | non-null | of 62,110 |
|---|---|---|
| `JOB_COSTS` | 62,110 | 100.0 % |
| `VENDOR_NAME` | 51,928 | 83.6 % |
| `GL_PERIOD` | 18,764 | **30.2 %** |

`GL_PERIOD` is ~70 % NULL by design. A floor copied from `JOB_COSTS` would fail it; a floor copied
from `GL_PERIOD` would leave `JOB_COSTS` unguarded.

### The 13 columns, in order

```
PARENT_PROJECT_NUMBER | PROJECT_COMPANY | COST_TYPE_CODE | PHASE_DIVISION | PHASE | DIVISION
| ACCRUAL_FLAG | VENDOR_NUMBER | VENDOR_NAME | GL_PERIOD | MONTH_OFFSET | MONTH_OFFSET_LABEL
| JOB_COSTS
```

All 13 are already clean identifiers — no newlines, no duplicate suffixes.

### The workbook: 26 sheets, `MetaData` first

Read from `xl/workbook.xml` in the zip. First sheet is `MetaData` (2 rows, **not data** — matters
for anything iterating all sheets). `Clayco_Job_Costs_from_GL` is #13, `Project_Profit` is #22.
Two names are truncated at exactly 31 characters by Excel's limit:
`Subcontract_Totals_and_Invoicin`, `Actual_Substantial_Completion_D`. All 26 names match
`^[A-Za-z0-9_]+$`. There is no sheet-listing function in DuckDB — hence item 3.

### Read cost, and why it compounds

One count is 0.78–0.86 s. But the view **re-reads the 68 MB workbook on every query**: a view plus
six aggregates measured **4.29 s**. With ~8 assertions, the checks file, and four mutation cycles
run twice each, the full acceptance run is minutes, not seconds. Budget for it.

The runner **may** materialize the sheet into a `TEMP TABLE` once per session to avoid this — but if
it does, **AC6 and AC7 must still be evaluated against the view**, since the view is what carries
the declared types.

---

## The two format decisions, settled

PLAN-4 item 4 requires both settled here rather than left open.

### Decision 1 — assertions live in `-- @assert` comment directives

**The contract creates exactly one view, named `contract_view`** — a fixed name, so the runner, the
assertions, the checks file, and item 5 all agree without inspecting the file.

Grammar, one assertion per line, anywhere in the contract file:

```sql
-- @assert <name>: <sql-boolean-expression>
```

- A **directive** is a line whose first non-whitespace characters are `--` followed by optional
  whitespace and `@assert`. Leading whitespace is permitted. `--@assert` with no space **is** a
  directive and must parse.
- `<name>` ends at the first `:`, matches `^[A-Za-z0-9_]+$`, and must be unique within the file.
- Everything after the first `:`, trimmed, is the expression. It must not contain `;`.
- Each expression is evaluated **verbatim as `SELECT <expr>;` with no `FROM` appended.** An
  assertion needing rows therefore carries its own scalar subquery:

```sql
-- @assert row_count: (SELECT count(*) FROM contract_view) = 62110
-- @assert glperiod_is_date: (SELECT any_value(typeof(GL_PERIOD)) FROM contract_view) = 'DATE'
```

- The result must be exactly one row, one column, BOOLEAN, value `true`. **A NULL result is a FAIL,
  not an error.** More than one row or column, a non-boolean type, or a DuckDB error is an **error**
  and exits non-zero.

Chosen over a companion `<name>__assert` view because the directive sits adjacent to the column it
constrains, needs no second 68 MB read, and lets item 5 enumerate assertions without executing
anything.

**The directive's real weakness, and the two guards that fix it.** A comment is invisible to
DuckDB's binder, so a malformed assertion is silently ignored — the exact failure mode that let
item 1's fixture grade itself. Therefore, mandatory in the runner:

1. A contract file with **zero** parsed assertions is an **error**, not a pass.
2. Any line that is a directive but does not match the grammar is an **error**, not skipped.

Both guards run **before the view is created**, so a malformed file fails without paying the 68 MB
read. Without both guards this decision is unsafe and must not ship.

### Decision 2 — `normalize_names` left false, headers quoted exactly

**This is a third option PLAN-4 did not offer.** Plan §4 framed the choice as
`normalize_names = true` *versus* positional selection. Neither is chosen. Both were measured and
both work:

- **Exact quoting reaches hostile headers.** On `Project_Profit`,
  `count("Current Revenue JDE⏎(JVs 100%)")` = **230**. A literal newline inside double quotes is
  fine — via `-f` only, per the conventions above.
- **`normalize_names = true` does not collide.** 123 columns → **123 distinct** snake_case names
  (`financial_status`, `cost_engineer`, `ops_exec`).

Exact quoting is adopted because it is the only one of the three that keeps the header list
**byte-traceable to the workbook**, so the committed fingerprint detects any upstream rename.
`normalize_names = true` would absorb some renames silently — two headers can normalize to one name,
and the mapping is a DuckDB-version-dependent transformation we would be trusting blind. Positional
selection is unreadable and no more robust to column insertion.

This also matches the workbook's own change discipline: graph annotations #14 and #42 record that
new columns are deliberately **appended last so existing column positions stay byte-stable for the
downstream consumers**.

Set nothing rather than restating the default — `normalize_names` is absent from the contract.

---

## Deliverables

### 1. `tools\list-sheets.ps1` — item 3

`tools\list-sheets.ps1 <absolute-workbook-path>`

Reads `xl/workbook.xml` from the zip via `System.IO.Compression`. Read-only; never launches Excel;
never writes. Emits, per sheet, the 1-based position and the name, plus a total count.

Also emits a **suggested contract filename** per sheet, derived from the **sheet** name not the
workbook, so the convention survives a workbook path with spaces and multiple dots:
`contracts\<sheet-name>.sql`.

Sheet names are used verbatim only when they match `^[A-Za-z0-9_]+$`. Any other name — spaces,
punctuation, anything filesystem-hostile — makes the tool **report the sheet and refuse to suggest a
filename**, rather than silently mangling it into a name that will not round-trip. All 26 sheets in
this workbook pass, so on this workbook the rule is defensive; AC16 exercises it against a
purpose-built zip.

Missing file, or a zip with no `xl/workbook.xml`, exits non-zero with the path in the message.

### 2. `contracts\Clayco_Job_Costs_from_GL.sql` — item 4

`CREATE OR REPLACE VIEW contract_view` over `read_xlsx` with:

- the pinned absolute path, forward slashes, single-quoted
- `sheet = 'Clayco_Job_Costs_from_GL'`, `all_varchar = true`
- `normalize_names` **absent**; `ignore_errors` **never**
- an explicit cast per column, all 13, named exactly as the workbook spells them
- `GL_PERIOD` → `xl_date(GL_PERIOD::BIGINT)`, never `TRY_CAST(... AS DATE)`
- `JOB_COSTS` → `DECIMAL(18,2)`
- `VENDOR_NUMBER` → **`BIGINT`**. It is an integer identifier that must join to a Snowflake
  `VENDOR_NUMBER`; `BIGINT` is what makes that join work and what AC12 checks for.
- the safety condition recorded as a comment (18,764/18,764 all-digits; 62,110/62,110 castable)
- `-- @assert` lines per Decision 1, covering the row count, the three per-column non-null floors,
  the `GL_PERIOD` type and range, and the money sum. Floors are measured, not templated.

### 3. `tools\check-contract.ps1` — the grammar, proven

`tools\check-contract.ps1 <contract.sql>`

Parses and validates all directives, **then** creates the view, runs each assertion, reports
`PASS`/`FAIL` per assertion by name, prints the assertion count, and exits non-zero if any fails or
either guard trips.

**It must make `xl_date` available without depending on any gitignored state.** `.gitignore:3`
excludes `.duckdb-skills/`, so the `state.sql` that `tools\ensure-duckdb-compat.ps1` writes **does
not exist in a fresh worktree** — and without the macros every assertion fails as a `Catalog Error`
for reasons unrelated to the work. Resolve `skills\query\duckdb-compat.sql` **relative to
`$PSScriptRoot`**, never as a hardcoded absolute path, so the tool is correct inside a
`git worktree add` checkout at a different path. Say which mechanism you used in the script header.

**Boundary with item 5:** this is a single-contract runner whose job is to prove the grammar
executes. Item 5 owns the multi-contract harness, aggregate reporting, and floor derivation. This
exists so item 4 does not ship assertions that have never run — unexercised assertions are the
self-grading failure in a new costume. **`check-contract.ps1` corresponds to no PLAN-4 step; it is
deliberate expansion beyond §3/§4**, recorded here so a later session knows where it came from.

### 4. `checks\gl-facts.sql` — so the verifier runs what the implementer ran

A committed `.sql` file, invoked `duckdb -f`, emitting **one labelled line per check** as
`check_id,value` — `AC5_VIEW_ROWS`, `AC5_DIRECT_ROWS`, `AC6_FINGERPRINT`, `AC8_A_MINUS_B`,
`AC8_B_MINUS_A`, `AC8_VIEW_MIN`, `AC8_VIEW_MAX`, `AC8_VIEW_NN`, `AC8_BARE_MIN`, `AC8_BARE_MAX`,
`AC8_BARE_NN`, `AC9_DECIMAL_SUM`, `AC9_DOUBLE_SUM`, `AC10_MAX_CAST`, `AC10_MAX_LEX`,
`AC11_JOBCOSTS_NN`, `AC11_VENDORNAME_NN`, `AC11_GLPERIOD_NN`, `AC12_VENDORNUMBER_TYPE`,
`AC12_DOT_ZERO_ROWS`.

Without this, AC5–AC12 are facts with no command, the verifier authors its own SQL, and its numbers
are not comparable to the implementer's — which defeats the point of having a separate verifier.

---

## How pinned figures are to be treated

These figures are **snapshots of a live, SharePoint-synced workbook that refreshes from Snowflake**.
It grew 57,801 → 58,403 → 62,110 rows over six weeks. It will move again, possibly between the
implementer's run and the verifier's.

**A difference from these numbers is drift to be reported, not a failure to be fixed.** Do not
adjust a figure to make a check pass, and do not "correct" the contract because a count moved.

The gate is therefore **internal consistency**, not equality with my numbers:

- the view's row count equals a direct `read_xlsx` count of the same sheet in the same run
- the two independent date decoders agree row for row
- the DECIMAL sum has no floating-point tail and differs from the DOUBLE sum
- the header fingerprint matches the committed one

All four hold regardless of how much the sheet grows. If an absolute figure has moved, record both
the committed value and the observed one in `RESULT-1.md` and say so explicitly.

**A fingerprint mismatch (AC6) is also drift, not a failure.** Report both lists side by side; do
not "fix" the contract to match. Note that append-only is a convention, not an invariant —
annotation #42 records two columns being *removed* from a sheet in this same workbook.

---

## Out of scope

- The `Project_Profit` contract. Its suffixed and newline headers, and the M-code decoding behind
  them, belong to the workbook track and `xlsx-power-query`. Measured here only to settle Decision 2.
- The multi-contract assertion harness — item 5. **One warning for whoever writes that spec:
  PLAN-4 §5's acceptance section is built entirely on the two claims this spec disproves** — its
  mutation 1 expects a `51,571 → 0` collapse under `ignore_errors=true` (measured: **51,928**, no
  collapse) and its mutation 2 expects the `'City of DeKalb'` parse error (measured: **exit 0**).
  Item 5's stated reason to exist does not reproduce and it needs a new one before it is specced.
- Lakehouse materialization and workbook freshness — item 6.
- Any join to a Snowflake extract — item 8.
- Any write, refresh, or repair of the workbook. Reading only, always.
- Removing the 18 orphaned connections. Annotation #28 is explicit that hand-deleting them from
  `xl/connections.xml` is unsafe.

---

## Acceptance checks

All are commands. Every one was run this session with no Snowflake connection. AC5–AC12 read a
labelled line from `checks\gl-facts.sql`; AC1–AC4, AC13–AC16 name their own command.

**AC0** In a throwaway worktree created by `git worktree add` at the implementer's commit,
`tools\check-contract.ps1 contracts\Clayco_Job_Costs_from_GL.sql` exits **0 on the first invocation
with no prior setup of any kind.** This is the check that proves the verifier can run anything at
all — `.duckdb-skills\` will not exist there.

**AC1** `tools\list-sheets.ps1 <pinned path>` prints **26** sheets; position 1 is `MetaData`;
`Clayco_Job_Costs_from_GL` and `Project_Profit` both appear. Exit 0.

**AC2** The same run shows `Subcontract_Totals_and_Invoicin` and `Actual_Substantial_Completion_D`
intact at 31 characters, neither truncated further nor padded.

**AC3** `tools\list-sheets.ps1` against a path that does not exist exits **non-zero** and the
message contains the path it was given.

**AC4** `tools\check-contract.ps1 contracts\Clayco_Job_Costs_from_GL.sql` exits **0** with every
assertion `PASS`, and prints an assertion count equal to the number of `-- @assert` lines in the
file. State both numbers.

**AC5** `AC5_VIEW_ROWS` equals `AC5_DIRECT_ROWS` — the view and a direct
`read_xlsx(..., all_varchar=true)` count of the same sheet, in the same run. Committed snapshot
**62,110**. If it has moved, the two still agree and the drift is reported.

**AC6** `AC6_FINGERPRINT` matches the committed 13-name ordered list exactly, including order.

**AC7** `(SELECT any_value(typeof(GL_PERIOD)) FROM contract_view)` is `DATE`, not `TIMESTAMP`. Run
via `check-contract.ps1` as the `glperiod_is_date` assertion. Note the `any_value` — an
un-aggregated `typeof()` returns 62,110 rows and would trip Decision 1's one-row rule.

**AC8** *The independent date check.* Two unrelated decoders must agree **row for row**, not merely
on aggregates. `AC8_A_MINUS_B` and `AC8_B_MINUS_A` must both be **0**:

```sql
SELECT count(*) FROM ((SELECT GL_PERIOD AS d FROM contract_view)
                      EXCEPT ALL (SELECT GL_PERIOD AS d FROM bare));
SELECT count(*) FROM ((SELECT GL_PERIOD AS d FROM bare)
                      EXCEPT ALL (SELECT GL_PERIOD AS d FROM contract_view));
```

where `bare` reads the same sheet with no `all_varchar`, letting DuckDB's own decoder produce the
DATE. Report min, max, and non-null from both paths as context (committed 2026-07-01, 2026-10-01,
18,764), but **the gate is the two zeros.** Min/max/count agreement is explicitly **not**
sufficient: a decoder that remaps interior dates onto other dates already present leaves all three
aggregates identical — this was demonstrated on a sabotaged decoder that was wrong for **6,654 of
18,764** dates and still showed 2026-07-01 / 2026-10-01 / 18,764.

**AC9** `AC9_DECIMAL_SUM` has **no floating-point tail** — committed **22454928166.83** — and
differs from `AC9_DOUBLE_SUM`, committed **22454928166.829914**. Do not assert the size of the
difference; see the note above on `-0.000088`.

**AC10** `AC10_MAX_CAST` is **256178387.75** and `AC10_MAX_LEX` is **99999.72**. Cast before
compare.

**AC11** `AC11_JOBCOSTS_NN` / `AC11_VENDORNAME_NN` / `AC11_GLPERIOD_NN` are **62,110 / 51,928 /
18,764** — three visibly different floors, none templated.

**AC12** Two parts, both required. **(a)** `AC12_VENDORNUMBER_TYPE` is **`BIGINT`**. **(b)**
`AC12_DOT_ZERO_ROWS`, from
`SELECT count(*) FROM contract_view WHERE VENDOR_NUMBER::VARCHAR LIKE '%.0'`, is **0**. The explicit
`::VARCHAR` is required — measured, `regexp_matches(BIGINT, ...)` is a
`Binder Error: No function matches ... 'regexp_matches(BIGINT, STRING_LITERAL)'`. **Part (b) alone
is not sufficient**: under `all_varchar` the source already renders `0`, `1`, `10` — never `17054.0`
— so (b) returns 0 on an uncast VARCHAR column too. Part (a) is what proves the cast happened.

**AC13** *Guard 1.* A contract file with no `-- @assert` lines makes `check-contract.ps1` exit
**non-zero**. Use a copy in `$env:TEMP`, deleted afterwards — never modify the real contract, and
never leave a `contracts\broken.sql` behind to be committed by accident.

**AC14** *Guard 2.* A malformed directive — missing colon, or a duplicate name — makes
`check-contract.ps1` exit **non-zero** rather than skipping it. Same throwaway discipline.

**AC15** *Control.* The source workbook is unchanged by the whole run. Capture SHA-256 and
`LastWriteTime` before and after; show both. The hash costs 0.17 s. This is a control and cannot
fail unless something writes — but interpret it correctly: **a changed hash with a later
`LastWriteTime` is a SharePoint sync** — report it and re-baseline. **A changed hash at the same
`LastWriteTime` is a write by this run and a hard failure.**

**AC16** *The refusal rule, exercised.* Build a minimal zip in `$env:TEMP` whose `xl/workbook.xml`
declares one sheet named `Q1 Sales (draft)`. `list-sheets.ps1` lists the sheet and suggests **no**
filename for it, exit 0. Without this check the rule can be omitted entirely and still pass
everything else.

### Mutation proof required

For AC8, AC9, and AC12, show the check **failing** under a deliberate single-line break in the
**contract**, then passing again once reverted:

- replace `xl_date(GL_PERIOD::BIGINT)` with `TRY_CAST(GL_PERIOD AS DATE)` → AC8 fails (expect
  all-NULL, so `AC8_B_MINUS_A` = 18,764)
- cast `JOB_COSTS` to `DOUBLE` instead of `DECIMAL(18,2)` → AC9 fails
- cast `VENDOR_NUMBER` to `DOUBLE` → AC12 fails, on part (a) and part (b) both

For **AC7**, mutate the **contract** — `GL_PERIOD::TIMESTAMP` — **not** `duckdb-compat.sql`. That
file is shipped, verified, and out of scope; dropping `xl_date`'s trailing `::DATE` would prove the
same thing by editing item 1's work. If you do temporarily touch any shipped file, revert it and
show `git status` clean before writing `RESULT-1.md`.

A check that cannot be made to fail is not evidence. Item 1 passed 17 of 17 while three macros were
wrong, which is why this section exists.

---

## Commit and handoff

Commit before writing `RESULT-1.md`; the verifier works from a throwaway worktree at that commit.
Do not chain `git push` onto the commit — push separately, with an explicit timeout.

`RESULT-1.md` must record:

- the exact commands run and their output for AC0 through AC16
- the mutation evidence, both directions, for AC7, AC8, AC9, AC12
- any figure that drifted, with committed and observed values side by side
- the workbook SHA-256 and `LastWriteTime`, before and after
- `git status` clean, if any shipped file was temporarily touched
- anything you were unable to verify, named plainly rather than omitted
