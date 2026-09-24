# SHIPPED — Sheet discovery and the first workbook contract (items 3 + 4)

Shipped 2026-09-24. Plan: `PLAN-4.md` items 3 and 4. Verified SHIP on **round 1** — no corrections
round was needed, the first item in this project to clear in one pass.

Commits: `ed88781` (deliverables), `4fafb77` (RESULT-1).

## What shipped

| artifact | what it does |
|---|---|
| `tools\list-sheets.ps1` | Lists a workbook's sheets by reading `xl/workbook.xml` from the zip. Never opens Excel. Suggests `contracts\<sheet>.sql` per sheet, and **refuses** to suggest a filename for a name that would not round-trip. |
| `contracts\Clayco_Job_Costs_from_GL.sql` | The first contract: `contract_view` over one sheet, `all_varchar = true`, all 13 columns explicitly cast, 7 embedded `-- @assert` directives. |
| `tools\check-contract.ps1` | Runs a contract's assertions, PASS/FAIL by name, both Decision 1 guards before the 68 MB read. Resolves the compat macros via `$PSScriptRoot`. |
| `checks\gl-facts.sql` | The AC5–AC12 measurements as committed SQL, one labelled line per check, so verifier and implementer run the same thing. |
| `tools\make-ac16-fixture.ps1` | Builds the hostile-sheet-name zip AC16 needs. Beyond the spec's four named deliverables; judged sound by the verifier because AC16 is otherwise not reproducible from a fresh worktree. |

## The two format decisions, now settled for every future contract

**Assertions** are `-- @assert <name>: <expr>` comment directives, evaluated verbatim as
`SELECT <expr>;` with no `FROM` appended, so each carries its own scalar subquery. The view is always
named **`contract_view`**. Zero assertions is an error; a malformed directive is an error, not a skip;
both guards run before the view is created. Item 5 inherits this grammar rather than inventing one.

**Column names** are quoted exactly as the workbook spells them — `normalize_names` absent, positional
selection rejected. This is a **third option PLAN-4 §4 did not offer**; it was chosen because it is
the only one that keeps the header fingerprint byte-traceable to the workbook, so an upstream rename
is detected rather than absorbed.

## What deliberately did NOT change

- **The workbook.** Not one byte. SHA-256 and `LastWriteTime` identical before and after both the
  implementer's and the verifier's full runs, independently captured. Never opened in Excel, never
  touched by openpyxl. This was not incidental caution: the file has 34 dependents and 18 latent
  orphaned Power Query connections, and Excel's repair prompt resolves such a connection by deleting
  the table and the connection together.
- **The 18 orphaned connections.** Left exactly as found. Annotation #28 is explicit that
  hand-deleting them from `xl/connections.xml` is unsafe.
- **`skills/query/duckdb-compat.sql`.** Item 1's shipped macros were not edited, not even temporarily.
  AC7's mutation was deliberately redirected to the contract (`GL_PERIOD::TIMESTAMP`) rather than
  dropping `xl_date`'s trailing `::DATE`, precisely so a mutation proof could not disturb shipped
  work. Item 1's own test suite was re-run and reports no regression.
- **`PLAN-4.md`.** Frozen, and left frozen. The three claims in it that this item disproved were
  corrected *in the spec*, not by editing the plan — the plan chain is the record of what was believed
  when.
- **`Project_Profit`.** Measured only to settle Decision 2. Its 123 columns, newline headers, and
  duplicate-suffixed names remain undecoded; that belongs to the workbook track and
  `xlsx-power-query`.
- **No Snowflake.** The spec claimed no check needed a connection and that held: the verifier, which
  has no `snowflake_sql_execute`, certified all 17 checks. First item where the main session re-ran
  nothing.

## Corrections this item forced on the plan's beliefs

Three of PLAN-4's recorded facts for this sheet did not reproduce and are now known wrong:

| PLAN-4 said | measured 2026-09-24 |
|---|---|
| `VENDOR_NAME` infers DOUBLE | infers **VARCHAR** |
| `ignore_errors=true` → `COUNT(VENDOR_NAME)` = 0 of 61,741 | **51,928** — no collapse at all |
| bare read fails on `'City of DeKalb'` | **exit 0**, 62,110 rows |

The contract discipline survived, but on a different and better justification: bare inference does not
error, it silently picks lossy types. `JOB_COSTS` becomes DOUBLE, making the $22.45 B total
`22,454,928,166.829914` instead of `...166.83`; `VENDOR_NUMBER` becomes DOUBLE and renders `17054.0`,
which will not join to Snowflake's `17054` and fails as *no matching rows* — reading like a business
finding rather than a type bug.

Four figures also drifted (rows 61,741 → **62,110**; `VENDOR_NAME` 51,571 → **51,928**; `GL_PERIOD`
18,395 → **18,764**; sum → **22,454,928,166.83**) while four held byte-exact, including
`MAX(JOB_COSTS)` = 256,178,387.75.

## Debt this hands to item 5

**PLAN-4 §5's entire acceptance section is built on the two dead claims above** — mutation 1 expects
the `51,571 → 0` collapse, mutation 2 expects the parse error. Neither reproduces. Item 5 needs a new
stated reason to exist before it is specced, and its mutations must be rebuilt on type fidelity rather
than silent nulling.

## What made round 1 hold

The review caught that the spec's one independent check was worthless as written: comparing the two
date decoders on min, max, and count passed a decoder that was **wrong for 6,654 of 18,764 dates**,
because the wrong dates landed on other dates already in range. Made row-wise before implementation.
The verifier then re-ran that same sabotage against the shipped contract and confirmed it is caught
(both diffs 6,654, not 0).

The second catch was subtler: the check meant to prove `VENDOR_NUMBER` is not a float **passed before
any contract existed**, and would have crashed under the obvious honest cast. Both defects were the
item 1 failure shape — green checks over wrong code — caught at spec time rather than two items later.

## Carried forward, still unverified

**Multi-object extracts remain unverified** from item 2b: every `extract-decide.ps1` fixture is
single-object, so the multi-object stage-1/stage-2 rule and the `@(… | ConvertFrom-Json)`
double-nesting fix still have no passing evidence. Unrelated to this item, but not yet discharged.
