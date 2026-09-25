# REVIEW — TASK.md (item 5: assertion harness), round 1

Reviewer: `task-reviewer`. Round 1, on the spec only — no implementer had run.
Verdict at the time: **NOT READY**, seven blocking items.

Recorded here because the reviewer reports inline and does not write the file. `PLAN-4.md` was
confirmed frozen and unedited (its last commit predates both item 2b's and items 3+4's specs).

## What the reviewer independently re-measured

Thirteen of fourteen claim groups were re-measured and came back **exact**: both real sheets' default
and `stop_at_empty=false` counts, all `All_Sales_Data` figures, the loud/silent taxonomy, the voiding
of PLAN-4 §5's mutation 1 (`COUNT(VENDOR_NAME)` = 51,928 not 0), `COPY TO xlsx` writing no header,
fixture B's 3/5/3, and the GL correction's neutrality under the new read rule. The fourteenth was a
genuine contradiction — B1 below.

The reviewer also confirmed the spec's claim that **no check needs Snowflake**: everything ran with no
connection.

## Blocking defects, and the fixes applied

**B1 — "Fixture A" was two different fixtures with contradictory numbers.** The prose described header
plus 6 data rows and `stop_at_empty=false` returning 6, while the detector table and AC2/AC3 described
5 raw / 4 with-data / 2 lost. Both were built and shown to be different files, and AC2's "4 rows
summing to 180.00" was unsatisfiable under either. The narrative line "four of six rows vanished" also
counted the blank row itself as lost data — the phantom-row error the spec rejects three paragraphs
later. Fixed: **one** fixture definition, with every figure re-measured rather than derived from prose
(default 2 / sum 30.00; with-data 5 / sum 120.00; 3 rows lost), and a deliberately partially-null row
added so the fixture also exercises the `COLUMNS(*)` trap.

**B2 — the harness needed four kinds of per-contract metadata that existed nowhere, and "Out of scope"
appeared to forbid creating them.** Sheet name, anchor column, fingerprint, and tolerance were all
either free prose in a comment or embedded in the `read_xlsx` call, and the spec said not to change
item 4's grammar — which a careful implementer would read as "invent no directives", falling back to
regexing the SQL. The verifier could then not know what format was chosen. Fixed: an explicit additive
directive family (`-- @sheet`, `-- @anchor`, `-- @rows_floor`, `-- @fingerprint`), with a statement
that **adding** directives is not **altering** item 4's grammar, and each one required exactly once.
The reviewer identified this as the root defect causing B4, B5, B6 and most of B7.

**B3 — the anchor-column safety condition was circular, with a measured counterexample.** Assertions
evaluate against `contract_view`, which is already filtered, and dropping all-null rows can only raise
the anchor's non-null rate — so the assertion can never observe a dropped row. The reviewer built a
three-column fixture whose last row is populated only in the unprojected third column: the detector
stays silent (3 = 3), the row is dropped (2), and the anchor assertion passes. Reproduced directly in
the main session. Fixed: the all-null predicate now covers **every column `read_xlsx` returns**, not
the contract's projection, and the non-circular licence is stated as the view-rows = with-data-rows
equality — item 4's AC5 gate, retained and relabelled as the orphan-column detector. The anchor is
kept as a floor, explicitly not as a licence.

**B4 — AC12 (direction-aware tolerance) had no tolerance value, no simulation mechanism, a rule that
would fail on legitimate growth, and a collision with item 4's shipped hard `row_count = 62110`.** The
implementer would have chosen the tolerance and then graded boundary behaviour against its own choice
— prior failure (a) exactly. Fixed by **splitting direction-aware tolerance into its own item** and
using conservative, spec-stated absolute floors instead (GL ≥ 50,000, `All_Sales_Data` ≥ 200), which
catch a collapse and cannot cry wolf.

**B5 — the first mutation proof was unachievable as written.** It asked for `stop_at_empty = false` to
be removed from the GL contract and for AC3 on fixture A to fail — but AC3 is computed from fixture A
and cannot be affected by editing the GL contract. Fixed: the mutation targets the fixture-A check
path, with an explicit note that this is *why* the fixture exists and why the real sheet cannot prove
it.

**B6 — no defined way to point the harness at a fixture, and the obvious way was out of scope.** AC3
and AC4 need the harness run against fixtures, the interface was `-Contract` over `contracts\*.sql`,
and "a third or further contract" was forbidden. Fixed: `-Contract` accepts a path outside
`contracts\`, and fixture contracts are excluded from no-argument discovery so AC1's "both contracts"
still holds.

**B7 — 14 of 16 acceptance checks contained no command,** against a stated "All are commands". Worse
than items 3+4 round 1 (8 of 15), and with no equivalent of the `check_id,value` file that made that
round hold. Fixed: the harness now emits a pinned labelled output contract
(`CONTRACT,…` / `ASSERT,…` / `TRUNCATION_*` / `ANCHOR,…` / `ROWS_FLOOR,…` / `FINGERPRINT,…` /
`SUMMARY,…`), so every check became a literal command with a literal expected line.

## Non-blocking issues fixed in the same revision

- `COPY ... TO (FORMAT xlsx)` requires `LOAD excel;` — measured, `Catalog Error` without it.
  `read_xlsx` autoloads; the COPY function does not. Added to the conventions.
- The `NOT (COLUMNS(*) IS NULL)` shorthand means "no column is null" and drops partially-populated
  rows — measured 4 vs 5 on fixture A, and would drop dozens of real rows on `All_Sales_Data`. The
  original fixtures could not have caught it because every data row was fully populated. Fixture A now
  carries a partially-null row and AC5 pins the distinction.
- Truncation hard-failed while fingerprint drift only reported, unargued. Now stated.
- AC13/AC14 conflicted with the inherited grammar's **ERROR** classification. Now explicit: ERROR, not
  FAIL, with the `Binder Error` text verbatim.
- Deliverable 3 silently changed what item 4's AC5 compares. Now called out, kept, and relabelled.
- No performance budget, with the deciding design choice left open. Measured: `check-contract.ps1`
  re-reads the workbook per assertion, 5.9 s for 7 assertions, versus **1.4 s** for a TEMP TABLE plus
  aggregates. The TEMP TABLE is now required, with the fingerprint and declared types still evaluated
  against the view.
- `All_Sales_Data`'s hostile-header list omitted **`match project`** — lowercase, spaced, the most
  hostile of the 16. Added, along with the unpinned `End Date` 145 and `Earnings Total` 201.
- Deliverable 3 needed the archive fenced, or an implementer would helpfully update `SHIPPED.md`'s
  figures. Now forbidden explicitly.
- AC10's throwaway-copy discipline was missing where AC11/AC13 had it. Added.
- `git status` clean would fail today for an unrelated reason: the untracked 12 KB `Revenue` file at
  repo root is a stray DuckDB database (magic `DUCK`), not matched by `.gitignore`. The gate is now
  "no **tracked** file modified outside scope", with an explicit instruction not to `git add -A`.

## Plan omissions the reviewer caught

- PLAN-4 §5's **"casts applied before any range comparison"** was discharged for the GL sheet by item 4
  but had no check on the new contract. Added as AC11, measured: `MAX("Revenue Total")` lexicographic
  **99266455** vs cast-first **1,682,000,000.00**, a 17× error.
- PLAN-4 §5's "reporting pass/fail per column" is answered per-assertion instead, inheriting item 4's
  grammar. Inheriting is right; the divergence is now stated rather than silent.
- Deliverables 2–5 correspond to no PLAN-4 §5 step. Item 4 set the precedent of labelling expansion in
  as many words; this spec now does the same.

## The reframing the review forced

The reviewer's sharpest structural point was not a defect list item. The first draft rested the whole
item on silent blank-row truncation — but **deliverable 4 eliminates that hazard** with a one-line read
change, so a detector for it cannot be "the harness's reason to exist". The spec now states the real
reasons in order: nothing runs more than one contract; the per-column floors are the actual
silent-failure guard; and the truncation check is a **regression guard on the read rule**, sized
honestly.

Also recorded: `SHIPPED.md` instructed item 5 to rebuild its mutations on **type fidelity**. This spec
uses truncation and floors instead, because type fidelity is already discharged by item 4's AC9/AC12
and `checks\gl-facts.sql`. The divergence from the hand-off note is now stated in one sentence rather
than left for a reader to notice.

## Main-session verification of the review

Per the standing rule that agent reports are not taken at face value, the findings driving the redesign
were re-checked directly before revising:

| claim | result |
|---|---|
| `COLUMNS(*)` shorthand drops a partially-null row | confirmed — 2 vs 1 on a 3-row fixture |
| orphan-column row dropped, detector silent, anchor passes | confirmed — default 3, all-cols 3, projection-only 2, anchor 2 |
| fixture A's corrected arithmetic | confirmed by building it — 2 / 30.00, 5 / 120.00, 3 lost, trap 4 |
| `MAX("Revenue Total")` cast vs lexicographic | confirmed — 1,682,000,000.00 vs 99266455 |
| `All_Sales_Data` remaining floors | confirmed — `End Date` 145, `Earnings Total` 201, `match project` 214 |

All held. The revision was written against them.
