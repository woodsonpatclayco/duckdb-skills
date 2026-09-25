# SHIPPED — Assertion harness over multiple contracts (item 5)

Shipped 2026-09-25. Plan: `PLAN-4.md` item 5, **narrowed** — direction-aware row tolerance was split
out to a follow-on item. Verified SHIP after **two rounds**.

Commits: `d590a82` (round 1), `17cc7bf` (RESULT-1), `d88a312` (round 2), `2e33d4d` (RESULT-2),
`66a437e` (post-verification coverage fix).

## What shipped

| artifact | what it does |
|---|---|
| `tools\run-assertions.ps1` | Runs every contract in `contracts\`, or one via `-Contract`. Emits labelled `check_id,value` lines and exits non-zero on any real failure. |
| `contracts\All_Sales_Data.sql` | Second contract — 219 rows, 16 columns, headers with spaces and `#`. |
| `contracts\Clayco_Job_Costs_from_GL.sql` | Corrected: new read rule, four directives, reclassified assertions. |
| `tools\make-truncation-fixtures.ps1` | Builds fixtures A, B, C with known-by-construction contents. |
| Additive directives | `-- @sheet`, `-- @anchor`, `-- @rows_floor`, `-- @fingerprint`, `-- @snapshot`, `-- @snapshot_committed` — added alongside item 4's `-- @assert`, never altering it. |

Current state: `SUMMARY,contracts=2,assertions=11,failures=0`.

## The idea this item actually contributed

**Every assertion belongs to one of three kinds, and the kind determines the form.** Round 1 shipped
without this and immediately proved why it was needed: the workbook refreshed overnight, five checks
failed, and none of them had found a defect.

| kind | form | gates? | example |
|---|---|---|---|
| **Invariant** | a relationship, never a literal | yes | `count(JOB_COSTS) = count(*)` |
| **Floor** | a measured ratio with justified headroom | yes | `VENDOR_NAME` ratio ≥ 0.80 |
| **Snapshot** | reported with committed value alongside | **no** | `SUM(JOB_COSTS)` = 22,478,661,033.93 |

The measurement that settled it: across the refresh that moved **every** absolute count, the ratios
held. `JOB_COSTS` at exactly 1.00000 both times; `VENDOR_NAME` 0.83607 → 0.83620; `GL_PERIOD`
0.30211 → 0.30345. So a ratio is refresh-proof where a count is not.

Phil still sees every absolute number — they are printed as snapshots with committed and observed side
by side. They simply no longer gate the exit code, so the harness does not cry wolf on ordinary growth.
A monitor that always fails is worse than none, because it trains you to ignore it.

## What deliberately did NOT change

- **The workbook.** Not one byte, across four agent runs and two verification passes. Hash and
  `LastWriteTime` independently captured before and after each. It did refresh once on its own
  (SharePoint sync, 2026-09-24 09:38 → 2026-09-25 08:48), which AC15's re-baseline rule handled
  exactly as written.
- **Item 4's `-- @assert` grammar and its two guards.** Inherited verbatim. Six new directives were
  **added**; none altered. The guards were re-proven under the harness.
- **`skills/query/duckdb-compat.sql`.** Item 1's macros untouched in both rounds.
- **`checks\gl-facts.sql`'s behaviour.** Still passes; re-run after every change including the final
  fix. Its AC5 comparison now doubles as the orphan-column detector and is relabelled, not weakened.
- **`docs\tasks\`.** The items 3+4 archive keeps its round-1 figures even where this item supersedes
  them. It records what was proven then.
- **`PLAN-4.md`.** Frozen and left frozen; its void §5 justification was corrected in the spec.
- **Direction-aware tolerance.** Deliberately not built. Split to its own item because two data points
  cannot set a tolerance and the two sheets move in opposite directions.
- **The 18 orphaned connections.** Untouched.
- **No Snowflake.** Verifier certified all 19 checks without a connection, for the second item running.

## Defects this item found in shipped work

**Item 4's contract asserted five absolute snapshots by equality**, including `row_count = 62110`. The
sheet had already moved three times in six weeks; it moved again mid-item. All five are reclassified.

**The obvious blank-row shorthand silently drops partly-filled rows.** `NOT (COLUMNS(*) IS NULL)` means
"no column is null" — measured 4 rows where 5 is correct. On `All_Sales_Data`, where `Revenue Total` is
filled on 201 of 219 rows, it would discard dozens of real rows.

**A row populated only in an unprojected column vanishes silently** if the all-null predicate covers
only the contract's projection — and the anchor assertion cannot catch it, because assertions run
against the already-filtered view. Fixture C exists to hold this case down.

**`read_xlsx` stops at the first blank row by default**: 2 of 5 data rows, sum 30.00 against a true
120.00, exit 0. Contracts now read `stop_at_empty = false` with the all-null filter, which is correct
on both the interior-blank and trailing-blank cases where neither default nor bare `stop_at_empty=false`
is.

## What the two review passes and the verifier caught

Round 1's draft rested the whole item on truncation detection — but the same spec **fixes** truncation,
so a detector for it could not be the reason to build a harness. Reframed before implementation: the
real reasons are that nothing ran more than one contract, and that the per-column floors are the actual
silent-failure guard.

The reviewer also found the anchor-column safety condition was **circular** and built the counterexample
that proved it.

The verifier then rejected round 2's deletion of `glperiod_range`, on grounds worth keeping: **two
decoders agreeing proves the decode is consistent, not that the range is sane.** A corrupted date window
would have passed both remaining checks. It also noted the deletion left the contract inconsistent with
its sister, which kept the identically-shaped check as a snapshot. Restored as a snapshot in `66a437e`
and confirmed non-gating.

## Debt carried forward

- **Direction-aware row tolerance** — the split-out item. Floors are the interim answer.
- **`Earnings Total` and `Start Date` have no ratio floors**, only snapshots, because the corrections
  table did not specify thresholds for them. The implementer correctly declined to invent them. Observed
  ratios are 0.918 and 0.685 if a later item wants to set them.
- **Item 2b's multi-object extract path is still unverified.** Every `extract-decide.ps1` fixture is
  single-object. Untouched by this item and still outstanding.
- **`Revenue`** — a stray 12 KB DuckDB database at the repo root from a mis-parsed command line. Left
  untracked deliberately; safe to delete.
