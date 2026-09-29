Plan: PLAN-4.md — a correction to shipped items 4 and 5, which Phil asked for directly. It adds no
capability; it removes a requirement that should never have existed. It corresponds to no PLAN-4 step, and
the spec count becomes ten.
Serves: "most of my queries won't have quality definitions — adding them should be something I ask for,
not something the tool forces me to guess at."

# TASK — Make quality definitions optional in contracts (item 5b)

## The principle

A contract directive either needs **no opinion about the data** or it encodes one. The two are treated
differently:

- **Needs no opinion** — which sheet; the contract's own column list. Mechanical to write. **Required.**
- **Encodes an opinion** — "this column is always populated", "never fewer than N rows", "vendor names at
  least 80 % filled". Phil has to have a view. **Optional**, added only when he asks.

Today every opinion is mandatory. A contract with correct types and no opinions is **illegal**, which forces
invented thresholds — and invented thresholds get ignored, which is the cry-wolf failure arriving by a
different door.

## The classification

| directive | today | after | why |
|---|---|---|---|
| `-- @sheet` | required | **required** | no opinion — the harness cannot read the sheet without it |
| `-- @fingerprint` | required | **required** | no opinion — see the note below |
| `-- @anchor` | required | **optional** | opinion: "this column is always populated" |
| `-- @rows_floor` | required | **optional** | opinion: a threshold Phil has to choose |
| `-- @assert` | ≥ 1 required | **zero or more** | opinion |
| `-- @snapshot` / `_committed` | zero or more | unchanged | already optional |
| truncation + consistency | always run | **always run** | invariants needing no input |

**What `@fingerprint` actually does — corrected from the first draft.** The first draft justified keeping
it required because it "detects a rename". **It does not.** Measured: when a source column is renamed
upstream, the contract's `SELECT` references a column that no longer exists and DuckDB's binder fails
first — `Binder Error: Referenced column "Market_RENAMED" not found in FROM clause!` — so the harness
reports `ERROR` and the fingerprint is never evaluated. The binder catches renames, not the fingerprint.

What `@fingerprint` detects is narrower: it restates the view's own output column list, so it catches an
edit to the contract's `SELECT` that the author forgot to re-declare. That needs no opinion about the data,
so it stays on the required side — but the reason is "it is cheap and needs no judgment", not "it guards
against upstream change". The first draft's second reason, that `materialize.ps1:268` depends on it, was
also wrong: `Get-ContractDirectiveLiteral` returns `$null` on absence and the row is simply not written.

It must **not** be auto-derived. A bind-only `duckdb_columns()` query over `contract_view` reproduces it
exactly, but a self-derived fingerprint always matches, which destroys the one thing it catches.

---

## Conventions that are not optional

- **Write files with `[IO.File]::WriteAllText` plus `New-Object Text.UTF8Encoding($false)`.**
- PowerShell 5.1: `;` never `&&`, absolute paths. SQL in `.sql` files via `duckdb -f`.
- **Gate on `$LASTEXITCODE`, never on stderr.**
- **The workbook is READ-ONLY.** Throwaway contract copies live in `$env:TEMP`, never in `contracts\`.
- **Materialize only into a scratch absolute `-LakeRoot`**, never the real project lake.
- Do not touch `docs\tasks\`. Items 4 and 5's archives record what shipped then, including the grammar
  this item changes.
- No Snowflake. Entirely local.
- Branch `item5b-optional-quality`.

---

## Measured facts

All measured against `main` at `9bbf700`, and each independently reproduced in review.

### A contract with no quality definitions is rejected today

A two-column contract declaring only `-- @sheet`:

```
CONTRACT,minimal
ERROR,minimal,missing required directive: -- @anchor
ERROR,minimal,missing required directive: -- @rows_floor
ERROR,minimal,missing required directive: -- @fingerprint
SUMMARY,contracts=1,assertions=0,failures=3        exit 1
```

Enforced at `run-assertions.ps1:213-225`. The harness also delegates `@assert` evaluation to
`check-contract.ps1` (`:284`), whose **Guard 1** (`check-contract.ps1:111`) rejects zero assertions — so a
quality-free contract currently fails twice over.

With every directive and one trivial assertion, the same projection is clean. Full output:

```
CONTRACT,full
ASSERT,trivial,PASS
TRUNCATION_DEFAULT_ROWS,219
TRUNCATION_WITHDATA_ROWS,219
TRUNCATION_ROWS_LOST,0
CONSISTENCY_VIEW_ROWS,219
ANCHOR,Job #,219,PASS
ROWS_FLOOR,200,219,PASS
FINGERPRINT,MATCH
SUMMARY,contracts=1,assertions=1,failures=0        exit 0
```

Truncation and consistency run whatever is declared, so a quality-free contract keeps the protection that
needs no judgment.

### Guard 1 does not protect against what it was built for — and a typo hole is live

Guard 1 exists because a comment is invisible to DuckDB's binder, so a malformed assertion would be
silently ignored. Measured against `check-contract.ps1`:

| contract content | result | exit |
|---|---|---|
| **A** — one valid `-- @assert` plus a misspelled `-- @asert` that would fail | `PASS ok`, `assertion_count=1` — **typo silently dropped** | **0** |
| **B** — only the misspelled `-- @asert` | `GUARD 1 FAILED` | 1 |
| **C** — no directives at all | `GUARD 1 FAILED` | 1 |

**Case A is a live hole in shipped code.** A misspelled keyword is not a directive, so Guard 2 never sees
it, and Guard 1 fires only when the typo is the *only* assertion. Guard 1 catches the case that matters
least and misses the one that matters most.

The fix is an **unknown-directive guard**. It must be the *maximal-word* form — the natural regex
alternation is wrong, measured against the seven keywords:

| line | maximal-word extraction | alternation, no `\b` |
|---|---|---|
| `-- @asert x: 1` | flags | flags |
| `-- @snapshotX foo: 1` | flags | **accepts** |
| `-- @sheets: X` | flags | **accepts** |
| `-- @assertion a: 1` | flags | **accepts** |
| `-- @snapshot_committedX y: 1` | flags | **accepts** |
| `-- @snapshot_committed y: 1` | accepts | accepts |
| `--@assert ok: 1` | accepts | accepts |

The alternation form catches `@asert` and so passes a naive check, while letting four whole families of
typo through — reintroducing the exact hole the guard exists to close.

On the shipped contracts, the maximal-word guard has **zero false positives**: every start-anchored
directive word is one of the seven (`All_Sales_Data.sql`: sheet 1, anchor 1, rows_floor 1, fingerprint 1,
assert 7, snapshot 11, snapshot_committed 11; `Clayco_Job_Costs_from_GL.sql`: 1, 1, 1, 1, 4, 7, 7), and the
**14** prose lines mentioning `@word` mid-line are correctly excluded. The narrowest is
`Clayco_Job_Costs_from_GL.sql:90: -- -- see the @snapshot rows below.`, which is what makes a non-anchored
guard trip.

**Known residual, not closed by this item:** a line with whitespace between `@` and the keyword
(`-- @ assert x: 1`), or with the `@` missing entirely, is not directive-shaped under either the guard or
item 4's grammar and remains silently ignored. `RESULT-1.md` must say so rather than claim every
misspelling is now caught.

### Downstream: item 6 needs no change, but the harness has two traps

`materialize.ps1:389-424` parses emitted lines with an `if`/`elseif` chain, so an absent `ANCHOR` or
`ROWS_FLOOR` line simply adds no `check_history` row. No schema change; the `status` enum is untouched.

`lake-status.ps1:140`'s `$syntheticIds` is a **NOTE-suppression list**, not an expectation that those rows
exist — `-History` iterates only the rows present, so absence produces no line, no error, and no blank. It
already tolerates this; the first draft's claim that it needed fixing was a misread.

**Two traps in `run-assertions.ps1` that a one-line change would miss:**

- `:404-405` unconditionally generates `SELECT 'ANCHOR_TOTAL'` and `'ANCHOR_NONNULL'`, and `:437` and
  `:444` both `continue` if either key is missing — which would skip **every remaining line for that
  contract, including `TRUNCATION_*`, `CONSISTENCY_*` and `FINGERPRINT`.**
- `$rowsFloorInt` initialises to `0` at `:227`. A missing floor falling through to it emits
  `ROWS_FLOOR,0,<n>,PASS` — `count >= 0` is always true — which is exactly the invented threshold this item
  removes.

---

## Deliverables

### 1. `tools\run-assertions.ps1`

- `-- @sheet` and `-- @fingerprint`: **required exactly once**, unchanged.
- `-- @anchor` and `-- @rows_floor`: **zero or one**. More than one is still a duplicate error; a present
  but malformed value is still an error.
- **When `@anchor` is absent**: do not generate the `ANCHOR_TOTAL`/`ANCHOR_NONNULL` `SELECT`s at `:404-405`,
  **and** remove both keys from the required-key checks at `:437` and `:444`. Emit no `ANCHOR` line.
- **When `@rows_floor` is absent**: emit no `ROWS_FLOOR` line. Never fall back to `$rowsFloorInt`'s initial
  `0`.
- Do not emit a placeholder such as `ANCHOR,NONE` — that would need a status outside item 6's enum.
- **Add the unknown-directive guard.** For each line, match `^\s*--\s*@([A-Za-z0-9_]+)` and take the
  **maximal** captured word. If it is not **exactly** one of `sheet`, `fingerprint`, `anchor`,
  `rows_floor`, `assert`, `snapshot`, `snapshot_committed`, emit
  `ERROR,<contract>,unknown directive: -- @<word>` before any workbook read. **Do not implement it as a
  regex alternation of the seven keywords** — see the table above. Membership is **case-sensitive**:
  `-- @ASSERT` and `-- @Sheet` are unknown directives (both are already errors today via other paths; this
  only changes which message appears, and the guard should name the typo itself).
- Truncation and consistency run for every contract, unconditionally.
- Update the header (lines 26–35, 77–78): which directives are required and which optional, and why.

### 2. `tools\check-contract.ps1`

- **Remove Guard 1.** Zero `@assert` directives is valid: `assertion_count=0`, exit 0.
- **Add the same unknown-directive guard**, with the same seven-keyword set and the same maximal-word form.
  Removing Guard 1 alone would regress case B for anyone running this tool standalone — a contract whose
  every assertion is misspelled would go from a loud error to silence. `check-contract.ps1` is a command
  Phil can run, so it must not be the one entry point that silently drops typos. The keyword vocabulary is
  already duplicated across `materialize.ps1:404-419` and `lake-status.ps1:140`, so this is consistent with
  how the project is built.
- **Keep Guard 2** unchanged.
- Update the header (line 30): Guard 1 removed; replaced by the unknown-directive guard, which catches
  case A that Guard 1 never could, and case B that Guard 1 did.

### 3. `skills\lakehouse\SKILL.md`

One or two sentences: quality directives are opt-in; a contract without them is valid and still gets the
truncation, consistency and fingerprint protection. Within its 4-line description budget.

`tools\lake-status.ps1` needs **no change** — see "Downstream" above.

---

## Out of scope

- **Generating assertion-free contracts from `list-sheets.ps1`.** This makes it possible; building it is a
  separate request.
- **Deriving `@fingerprint` automatically.** Deliberately rejected — a self-derived fingerprint always
  matches, destroying the one thing it catches. If writing it by hand becomes a burden, the answer is a
  generator that emits the directive text for a human to paste, not a check that computes its own
  expected value.
- **A "not declared" message in `lake-status.ps1`.** `check_history` cannot distinguish "never declared"
  from "absent", and `lake-status.ps1` receives a contract *name* not a path, so it cannot consult the file.
  If wanted, it needs a mechanism this item does not build.
- Direction-aware row tolerance — Phil has decided to leave it.
- Adding or removing any quality definition on the two shipped contracts.
- Items 7 and 8. Any edit under `docs\tasks\`.

---

## Acceptance checks

Every check names a command. None needs Snowflake.

**AC1** *A contract with no quality definitions is valid.* A two-column `All_Sales_Data` projection
declaring only `-- @sheet` and `-- @fingerprint`. Its inner `WHERE NOT (… IS NULL AND …)` must cover **all
sixteen** raw columns, exactly as `contracts\All_Sales_Data.sql:81-88` does, because
`CONSISTENCY_VIEW_ROWS` is compared against the independent 16-column with-data count.
`run-assertions.ps1 -Contract <it>` exits **0**, emits `TRUNCATION_ROWS_LOST,0`,
`CONSISTENCY_VIEW_ROWS,219`, `FINGERPRINT,MATCH`, **no** `ANCHOR` or `ROWS_FLOOR` line, and `failures=0`.
Quote the pre-change run of the same file: three `missing required directive` errors, exit 1.

**AC2** *The no-opinion directives stay required.* Omit `-- @sheet` → `missing required directive: -- @sheet`,
exit 1. Omit `-- @fingerprint` → the same, exit 1.

**AC3** *Misspelled directive keywords are caught.* Case A — one valid `-- @assert` plus `-- @asert` — exits
**1** with `unknown directive: -- @asert`, via **both** `run-assertions.ps1` and standalone
`check-contract.ps1`. Quote the pre-change result: exit 0, typo dropped.

**AC3b** *Keyword-prefix typos are caught.* A throwaway contract containing `-- @snapshotX foo: 1`,
`-- @sheets: X`, `-- @assertion a: 1` and `-- @snapshot_committedX y: 1` produces **four**
`unknown directive` errors naming `snapshotX`, `sheets`, `assertion`, `snapshot_committedX`. All four are
silently ignored by every parser at `9bbf700`.

**AC3c** *Case B no longer regresses standalone.* A contract whose **only** assertion is misspelled exits 1
from standalone `check-contract.ps1` with `unknown directive`, where before it exited 1 with
`GUARD 1 FAILED`.

**AC4** *No false positives on shipped contracts.* `run-assertions.ps1` with no argument: **the pass
condition is that no line matching `unknown directive` appears.** Report `failures` as an observation; if
non-zero, quote the failing lines — a drifted `@assert` ratio is workbook drift, not a defect in this change.

**AC5** *Optional directives still bite when declared.* On a throwaway copy of the GL contract, point
`@anchor` at `VENDOR_NAME` → `ANCHOR,VENDOR_NAME,…,FAIL`, exit 1. Set `@rows_floor` above the row count →
`ROWS_FLOOR,…,FAIL`, exit 1. (VENDOR_NAME is 52,037 of 62,230 per the contract's committed snapshots; the
FAIL verdict is what is asserted, not the count.)

**AC6** *Duplicates and malformed values are still errors.* Two `@anchor` lines → duplicate error; a
non-integer `@rows_floor` → the existing not-an-integer error. Both exit 1.

**AC7** *Zero assertions is valid standalone.* `check-contract.ps1 <file with zero @assert>` →
`assertion_count=0`, exit **0**. A malformed `-- @assert` line (Guard 2) still exits 1.

**AC8** *Shipped behaviour unchanged.* **Capture the baseline first, from unmodified code:** check out
`9bbf700` into a throwaway `git worktree`, run `run-assertions.ps1` there with no argument, and save stdout
to a file outside both trees. Then run the modified harness and `Compare-Object` the two; quote the command
and result. If they differ **only** in `SNAPSHOT,<name>,<observed>` values, the workbook refreshed between
runs — say so, quote the differing lines, and confirm every other line is identical; that is a pass. Any
difference on a `CONTRACT`/`ASSERT`/`TRUNCATION_*`/`CONSISTENCY_*`/`ANCHOR`/`ROWS_FLOOR`/`FINGERPRINT`/`SUMMARY`
line is a failure. Separately, `duckdb -f checks\gl-facts.sql` still passes.

**AC9** *Item 6 unaffected for existing contracts.* Into a scratch absolute `-LakeRoot`: materialize both
shipped contracts, then **drop both target tables** so the second pass is a legitimate `target_missing`
REFRESH, then materialize again. (An unchanged second run SKIPs by design — `materialize.ps1:343-366` — and
writes no `check_history` rows; `-Force` does not override the decision.) `SELECT count(*) FROM
lake.check_history` returns **78** — GL 16 per run, `All_Sales_Data` 23 per run. Quote the
`GROUP BY contract_name, kind` table. If the workbook refreshed and a contract's snapshot count changed,
quote the new arithmetic and say so — the rule is fixed, the totals follow.

**AC10** *Item 6 handles a quality-free contract.* Materialize AC1's contract into a scratch lake: it
REFRESHes, `checks_passed` true, and `check_history` holds its rows with **no** `ANCHOR` or `ROWS_FLOOR`
row. Quote the count and its decomposition by `kind`.

**AC11** *`lake-status.ps1` tolerates absence, unchanged.* Against AC10's lake:
`lake-status.ps1 -LakeRoot <scratch>` exits 0 with a `STATUS,<name>,…` line; `-History <name>` exits 0 with
no `ANCHOR` and no `ROWS_FLOOR` row; `-AsOf <today> -Contract <name>` exits 0 with an `ASOF` line. Quote
all three.

**AC12** *The guard is start-anchored.* A prose comment containing `see @anchor above` mid-line produces no
error; `  --  @bogus: x` (leading whitespace, extra space) does.

**AC13** *No BOM.* For each of `tools\run-assertions.ps1`, `tools\check-contract.ps1`,
`skills\lakehouse\SKILL.md` and `RESULT-1.md`, `[IO.File]::ReadAllBytes($p)[0..2] -join ','` is not
`239,187,191`. Quote all four.

### Mutation proof required

Each failing, then passing after revert.

- **remove the unknown-directive guard** → AC3 fails: case A exits 0.
- **rewrite the guard as a keyword alternation with no `\b` and no whole-word test** → **AC3b fails**, all
  four prefix typos pass silently, while AC3 still passes — which is why AC3b exists.
- **restore `@anchor` as required** → AC1 fails.
- **restore Guard 1** → AC1 and AC7 fail.
- **leave `ANCHOR_TOTAL`/`ANCHOR_NONNULL` in the required-key checks** → AC1 fails: its `TRUNCATION_*`,
  `CONSISTENCY_*` and `FINGERPRINT` lines vanish.
- **let an absent `@rows_floor` fall through to `0`** → AC1 fails with a spurious `ROWS_FLOOR,0,219,PASS`.
- **match `@word` anywhere in a line** → AC4 fails on `Clayco_Job_Costs_from_GL.sql:90`.

---

## Commit and handoff

Branch `item5b-optional-quality`. Commit before writing `RESULT-1.md`; push separately with an explicit
timeout.

`RESULT-1.md` must record: exact commands and output for AC1–AC13 including AC3b/AC3c; mutation evidence
both directions; before/after for AC1 and AC3 from actual pre-change runs; the known residual gap
(`-- @ assert`); and anything not verified, named plainly.

**It must also state that item 4's Decision 1 is superseded** in two respects — Guard 1 is removed, and an
unknown-directive guard is added — and that the live grammar now lives in the headers of
`run-assertions.ps1` and `check-contract.ps1`, not in item 4's archive. This must carry into `SHIPPED.md`.
