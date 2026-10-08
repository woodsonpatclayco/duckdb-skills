# Excel tables / named ranges by name, and formula checks — plan archive

Archived 2026-10-08, after item 4 shipped. Plugin version 0.4.0.

**The plan:** one version, `PLAN-6.md`, reviewed in `REVIEW-plan-6.md` and revised in place before
any work started.

**How it was built:** the first plan under this project's new workflow (Phil, 2026-10-08). The
main session built each item directly, with no `TASK.md`, implementer, verifier or review gates,
and after each item handed Phil one proof command to run himself. So there are no
`docs\tasks\` folders for this plan; the proof scripts below are the record.

**Serves:** Phil can point a query or a contract at an Excel **table or named range by its
name** and get exactly its rows. And a contract can **check a workbook's formulas**: one
consistent formula per table column with nothing typed over it, no growth in error cells, and
key formulas unchanged since they were committed.

## What shipped

| item | what it delivered | commit | proof Phil runs |
|---|---|---|---|
| 1 | `tools\xlsx_meta.py`: `tables` / `names` discovery; generated `read_xlsx_table(path, table)` / `read_xlsx_name(path, name)`; refuses ambiguous, broken, formula-defined names | `ed1d8b5` | `tests\prove-xlsx-tables.ps1` |
| 2 | Contracts take `-- @table:` / `-- @name:` instead of `@sheet`; one shared directive list (`tools\contract-xlsx.ps1`); `contracts\Job_Rate_Tiers.sql` | `ac77e4d` | `tests\prove-contract-tables.ps1` |
| 3 | `xlsx_meta.py formulas` and `macros --formulas`: the `xlsx_formulas` view (A1 + R1C1, error cells, gaps in formula columns); R1C1 converter `tools\xlsx_r1c1.py` with a trap fixture | `e569b11` | `tests\prove-xlsx-formulas.ps1` |
| 4 | `@formula_consistent`, `@formula_errors_max`, `@formula_fingerprint`, evaluated by `run-assertions.ps1` and filed in `check_history` as invariants | `cf77289` | `tests\prove-formula-checks.ps1` |
| 5 | Docs rode with each item; version bump to 0.4.0 | (bump commit) | — |

## Where the measured facts moved from the plan

- **`Executive_Reviews.xlsx`.** The plan's "122 rows for `Exec_Review_Details`" belonged to a
  second table, `Exec_Review_Details8` (`A2:AN124`). `Exec_Review_Details` itself is `A2:AO125`,
  123 rows. The proof shows both.
- **The SDI Calculator was saved on 2026-10-08 at 09:32**, after the plan measured it. That
  copy has 7,200 formula cells (the plan had 7,142) and 748 error cells (the plan had 691),
  124 of them in formulas and 624 plain values. It has 38 tables, not 62; its 61
  `calculatedColumnFormula` entries match. The item 3 proof re-measures every run against an
  independent recount, so it does not depend on these numbers.
- **The R1C1 converter was checked once against Excel's own `Formula2R1C1`** (a dedicated
  hidden Excel, fixture copy only). Every reference was identical. The only differences were
  display forms Excel uses for non-reference text: `[@Col]`, `@` for `_xlfn.SINGLE`, `1000`
  for `1E3`, and an unquoted `Q1!`.

## Found and fixed along the way

- **`run-assertions.ps1` CSV quoting.** It took DuckDB's CSV output literally, so a column name
  or value containing an apostrophe or comma kept its surrounding quotes. The first case was
  `SDI On This Month's Costs`. It would have broken any sheet contract with such a column.
- **Table XML parsing in item 1.** It read the table part with a streaming parser stopped
  early, which could miss the column list of a very wide table. It now parses the whole small
  part.

## What deliberately did not change

- **The existing contracts.** `All_Sales_Data` and `Clayco_Job_Costs_from_GL` behave
  byte-for-byte as before. Their freshness key is unchanged, so an existing lake does not
  refresh because of this plan.
- **Sheet-only contracts never run Python or the generator.** The formula view is built only
  for contracts that use it.
- **The generated SQL is never cached or committed.** It is regenerated every run, so it
  cannot go stale (Decision 1).
- **No C++ extension, no external-link checks, no formula evaluation, no `.xlsb`.**
  Formula-defined named ranges are refused, not resolved. `tools\list-sheets.ps1` is
  untouched.
- **`tools\prove-requery.ps1` still covers only the two original sheet contracts.** It lists
  them by name and was not extended to `Job_Rate_Tiers`.
- **`calculatedColumnFormula` is never trusted.** The checks read the cells, because the
  table's own formula is often stale.
- **`.cortex-plugin\plugin.json` stays at 0.2.4.** Cortex Code is not a target of this fork.

## Known and left alone

- **`Clayco_Job_Costs_from_GL`'s `glperiod_null_iff_older` assertion fails on today's
  workbook.** It already failed before this plan, because the data moved, and it is why that
  contract is `REFUSED` in item 2's proof.
- **Three SDI table columns mix formulas with typed values or blanks.** They are
  `Final_Pay_App_Adjs[Adjustment to Included Cost of Work]`, `Not_to_Exceed_SDI[Not to
  Exceed]`, and `Insurance_Basis[Project Cost of Performance Bonds …]`. They are real
  `@formula_consistent` failures, if anyone wants to check them.
