# REVIEW-plan-6 — PLAN-6.md (draft)

Reviewer: `plan-reviewer`, 2026-10-07. It has no write tools; the main session saved its report here
verbatim (headings condensed). Reviews the first draft (commit `dbb1d10` plus an uncommitted Item 1
wording tidy). PLAN-6 was unfrozen, so the fixes were made in place.

**Status:** draft. No `TASK.md` carries `Plan: PLAN-6.md`.

## Problem the plan solves
Today a workbook read can only target a whole sheet, which can silently stop early or run past the end
of an Excel table, and can never isolate one table when several share a sheet. Contracts also cannot
see formulas at all. The plan lets queries and contracts read a table or named range by name, and lets
contracts check formula consistency, error counts and formula fingerprints — via SQL macros generated
on every run, not a C++ extension.

## Blocking issues

1. **Item 3 / Item 4: the error check misses 83% of the errors the plan quotes.** Item 3 emits one
   row per formula cell (plus typed values inside table columns), but on the staged SDI copy **576 of
   the 691 error cells hold no formula** — plain `#N/A` values in query-output sheets
   (`Project_Phases` 297, `SDI_Costcodes` 234, `Journal Entry Helpers` 39, 6 more on
   `Potential Reserves` and `All_Projects_Face`). Only 115 are formula cells. *Plan should say:*
   `formulas` also emits every error-valued cell (`t="e"`), formula or not, with kind `none`, and
   `@formula_errors_max` counts all error cells in scope, reporting formula vs value errors
   separately — or count formula cells only and change the proof figure to 115. Pick one.

2. **Item 2: `@table <name>` / `@name <name>` don't match the one-value grammar.** One-value
   directives are `-- @sheet: X` with a colon (`run-assertions.ps1:198`,
   `^\s*--\s*@$Keyword\s*:(.*)$`); without it the line is malformed. *Plan should say:*
   `-- @table: <name>` / `-- @name: <name>`, plus the quoting rule for sheet-scoped names whose
   sheet has spaces, e.g. `-- @name: 'Journal Entry Helpers'!ExternalData_1`.

3. **Item 4: the three formula directives have no label.** Named directives are
   `-- @kw <name>: <value>` with `<name>` matching `[A-Za-z0-9_]+` (`run-assertions.ps1:220`,
   `check-contract.ps1:129`); that name is what is reported, de-duplicated, re-parsed
   (`^(PASS|FAIL|ERROR)\s+([A-Za-z0-9_]+)`), and keyed in `materialize.ps1`'s `check_history`
   (`ASSERT,<name>,…`). The drafted forms put a scope (`*`, a sheet with spaces, `Table[Col]`) where
   the name goes. *Plan should say:* named form with scope and threshold in the value, name the
   separator between scope and value (`:` is taken, and R1C1 text can contain `:`), say which script
   evaluates them (`check-contract.ps1` only evaluates `@assert`), and emit results as
   `ASSERT,<name>,PASS|FAIL,<detail>` from `run-assertions.ps1` so `materialize.ps1:421` records
   them as `invariant` with no new parsing.

4. **Item 2: a generator hash in the freshness key breaks every existing lake.** `lake.manifest` is
   `CREATE TABLE IF NOT EXISTS` with a fixed 12-column schema (`materialize.ps1:333`) and positional
   inserts (`:479`, `:530`); a 13th value fails on existing lakes. *Plan should say:* (a) fold the
   generator hash into the existing `compat_sha256` value, or (b) `ALTER TABLE … ADD COLUMN IF NOT
   EXISTS` first. Item 2's proof should include `materialize.ps1` on the existing contracts.

5. **Items 2/4: the formula loader runs on every contract, contradicting Risks.** "Loaded for every
   workbook contract" means every run of the existing contracts streams all of the 68 MB
   `Data Extracts.xlsm` and gains a Python failure path; Item 2 also runs the generator
   unconditionally. *Plan should say:* generator only when the contract uses `read_xlsx_table(` /
   `read_xlsx_name(` / `@table` / `@name`; formula view only when a formula directive is present or
   an `@assert` mentions `xlsx_formulas`; sheet-only contracts execute exactly as today. This is the
   most likely way Item 2 breaks the existing contracts.

6. **Item 2: query-skill session state contradicts "nothing can go stale".** Macros are generated
   for specific workbooks with literal CASE bodies; a permanent `.read` line in `state.sql` reads
   whatever was generated last. *Plan should say:* (a) the skill generates per invocation and
   `.read`s it per invocation, not from `state.sql`, or (b) the skill uses `xlsx_meta.py tables` and
   writes explicit `read_xlsx(…, sheet=…, range=…)`, keeping macros for runners only.

7. **Items 2/4: proof contracts have no stated home or source path.** Default runners glob
   `contracts\*.sql`; a committed contract pointing at a temp staged copy fails once the copy is
   gone. *Plan should say* for each proof contract whether it is committed and where; suggestion:
   outside `contracts/`, run with `-Contract`; only stable-path contracts join `contracts/`.

## Non-blocking notes

- **Item split and order are right.** Moving the keyword list into one shared file is justified
  (`check-contract.ps1:101` and `run-assertions.ps1:257` are identical copies).
- **R1C1 is the right basis** (it is what Excel uses to flag inconsistent formulas; shared
  dependents inheriting the master's R1C1 is correct). Close three gaps: fingerprint on a column
  with more than one form → fail and point to `@formula_consistent`; define what a blank data cell
  counts as; print the A1 form beside R1C1 on failure.
- **Converter trap fixture, add:** quoted sheet names incl. one that looks like a cell (`'Q1'!A1`),
  error literals in formula text (`#REF!`), `_xlfn.`/`_xlws.` prefixes, implicit-intersection `@`,
  scientific notation (`1E3` — zero in SDI, fixture-only), any identifier followed by `(` treated as
  a function (`LOG10`, `DAYS360`).
- **"Has formulas" must be decided from the cells**, not `calculatedColumnFormula`, or
  `SDI_Costcodes` A–H alone produce ~2,700 false typed-value rows. Say it in the item text.
- **Item 1 macro details:** escape `'` in paths inside the `query()` string; normalize slashes/case
  before matching the CASE key; pass `header=false` or refuse when `headerRowCount="0"`.
- `@formula_fingerprint` reads close to the existing header `@fingerprint`; no parsing collision
  (whole-word guard) but worth a docs sentence.
- **Proofs are proportionate**, not over-built. Nothing to cut.
- Measured facts checked: 35/105/110 and 122 follow from the refs; 691 with 604/65/22 matches the
  staged copy.

## Verdict
**REVISE.** The error check as written counts 115 of the 691 error cells the plan cites, and the new
directives don't fit the `-- @kw: value` / `-- @kw name: value` grammar the parsers enforce. Each is
a sentence to fix. The approach (macros generated every run, R1C1, item split and order) is sound.
