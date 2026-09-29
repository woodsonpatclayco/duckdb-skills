Verifies: RESULT-1.md (item 5b -- make quality definitions optional in contracts)

# VERIFY-1 -- item 5b, round 1

Verified in a disposable `git worktree add` at commit `304e6d9` (branch
`item5b-optional-quality`), path `C:\Users\woodsonp\AppData\Local\Temp\verify5b-304e6d9`,
removed after this report was written. A second disposable worktree at `9bbf700`
(`main`), path `C:\Users\woodsonp\AppData\Local\Temp\verify5b-9bbf700`, was used
for AC8's independent baseline and for the hyphenated-filename pre-existing-behaviour
check. The main working directory (`C:\Users\woodsonp\Claude\Dev\duckdb-skills`,
itself checked out on `item5b-optional-quality`) was never used to run code and is
confirmed unchanged (`git status` before and after this session: only the two
pre-existing untracked files `TASK.md` and `REVIEW-task-1.md`, nothing else).

## Verdict: SHIP

All 13 acceptance checks (AC1-AC13, including AC3b/AC3c) reproduce exactly as
RESULT-1.md claims. All seven mutation proofs reproduce, including a corrected
version of mutation 7, which RESULT-1.md itself said did not bite -- and Phil's
own diagnosis (an unanchored guard tested with an *unknown* mid-line word, not the
prose's own known keyword) is independently confirmed to bite correctly. No check
lost teeth. The hyphenated-filename SQL-identifier bug is pre-existing at `9bbf700`,
not introduced by this item.

## Acceptance checks

| check | expected | actual | verdict |
|---|---|---|---|
| AC1 | quality-free contract: exit 0, TRUNCATION_ROWS_LOST=0, CONSISTENCY_VIEW_ROWS=219, FINGERPRINT,MATCH, no ANCHOR/ROWS_FLOOR, failures=0; pre-change: exit 1, 2 missing-directive errors | Reproduced exactly both ways (after: `SUMMARY,contracts=1,assertions=0,failures=0` EXIT=0, no ANCHOR/ROWS_FLOOR line; before at 9bbf700: `ERROR,...missing required directive: -- @anchor` / `-- @rows_floor`, EXIT=1); standalone check-contract.ps1: `assertion_count=0` EXIT=0 | PASS |
| AC2 | omit @sheet / @fingerprint each -> exit 1, named missing directive | `ERROR,...,missing required directive: -- @sheet` EXIT=1; `ERROR,...,missing required directive: -- @fingerprint` EXIT=1 | PASS |
| AC3 | case A (valid assert + `@asert` typo): exit 1, "unknown directive: -- @asert", both entry points; pre-change: exit 0, typo dropped | `check-contract.ps1`: `UNKNOWN DIRECTIVE GUARD FAILED: line 7: unknown directive: -- @asert` EXIT=1; `run-assertions.ps1`: `ERROR,...,unknown directive: -- @asert` EXIT=1 | PASS |
| AC3b | 4 prefix typos (`snapshotX`,`sheets`,`assertion`,`snapshot_committedX`) each named, exit 1, both entry points | All four named exactly via both `run-assertions.ps1` and `check-contract.ps1`; also independently probed `-- @ASSERT` and `-- @Sheet` -> both flagged unknown (case-sensitive membership confirmed) | PASS |
| AC3c | only assertion is `@asert` -> standalone check-contract.ps1 exits 1 with "unknown directive", not "GUARD 1 FAILED" | `UNKNOWN DIRECTIVE GUARD FAILED: line 4: unknown directive: -- @asert` EXIT=1 | PASS |
| AC4 | no arg run: no "unknown directive" line; failures reported as observation | Output byte-identical to RESULT-1.md's quoted output: `SUMMARY,contracts=2,assertions=11,failures=0` EXIT=0, zero unknown-directive lines, several SNAPSHOT_DRIFT lines (workbook drift, not a defect) | PASS |
| AC5 | @anchor pointed at VENDOR_NAME -> ANCHOR,...,FAIL exit 1; @rows_floor above row count -> ROWS_FLOOR,...,FAIL exit 1 | `ANCHOR,VENDOR_NAME,52165,FAIL` EXIT=1; `ROWS_FLOOR,999999999,62377,FAIL` EXIT=1 | PASS |
| AC6 | dup @anchor -> duplicate error; non-integer @rows_floor -> not-an-integer error, both exit 1 | `ERROR,...,duplicate directive: -- @anchor (found 2 times)` EXIT=1; `ERROR,...,'@rows_floor' value is not an integer: notanumber` EXIT=1 | PASS |
| AC7 | zero @assert standalone -> assertion_count=0 exit 0 | Covered under AC1: `assertion_count=0` EXIT=0 | PASS |
| AC8 | shipped behaviour unchanged vs 9bbf700; gl-facts.sql still passes | **Independently captured own 9bbf700 baseline** (not reused from RESULT-1.md) and diffed against the 304e6d9 no-arg run: `Compare-Object` produced **zero differences**, both 54 lines. `duckdb -f checks\gl-facts.sql`: 21 lines, `EXIT=0`, matches RESULT-1.md's quoted output exactly | PASS |
| AC9 | materialize both, drop both tables, materialize again -> check_history=78, GL 16/run, All_Sales_Data 23/run | `SELECT count(*) FROM lake.check_history` = 78; breakdown: All_Sales_Data floor=8/invariant=14/snapshot=24 (46/2=23 per run), Clayco floor=6/invariant=10/snapshot=16 (32/2=16 per run) | PASS |
| AC10 | quality-free contract materializes: REFRESHED, checks_passed=true, 3 check_history rows (invariant=2, snapshot=1), no ANCHOR/ROWS_FLOOR row | `MATERIALIZE,ac1minimal,REFRESHED,219,reason=no_manifest`, `CHECKS_PASSED,true`; check_history: `CONSISTENCY_VIEW_ROWS,invariant,PASS` / `FINGERPRINT,snapshot,PASS` / `TRUNCATION_ROWS_LOST,invariant,PASS` -- exactly 3 rows, no ANCHOR/ROWS_FLOOR | PASS |
| AC11 | lake-status.ps1 -LakeRoot / -History / -AsOf all exit 0, no ANCHOR/ROWS_FLOOR row | All three exit 0 with the exact STATUS/HISTORY/ASOF+ASOF_CHECK lines expected, no ANCHOR/ROWS_FLOOR anywhere; `lake-status.ps1` confirmed byte-identical (SHA-256) to 9bbf700 | PASS |
| AC12 | prose "see @anchor above" mid-line -> no error; leading-whitespace `@bogus` -> error | `ERROR,...,unknown directive: -- @bogus` EXIT=1, and no error for the prose line | PASS |
| AC13 | none of the 4 named files begins with EF BB BF | run-assertions.ps1: `60,35,13`; check-contract.ps1: `60,35,13`; SKILL.md: `45,45,45`; RESULT-1.md: `80,108,97` -- none is `239,187,191` | PASS |

## Mutation proofs (all 7, reproduced independently)

| # | mutation | expected failure | reproduced |
|---|---|---|---|
| 1 | remove guard call, both tools | AC3 case A: exit 0, typo dropped | `PASS trivial` / `assertion_count=1` EXIT=0 -- confirmed |
| 2 | alternation, no `\b`, no whole-word test | AC3b fails (4 typos pass silently); AC3 still passes | `assertion_count=0` EXIT=0 on the 4-typo fixture; AC3 case A still `UNKNOWN DIRECTIVE GUARD FAILED: ...@asert` EXIT=1 -- confirmed, exactly the differential AC3b exists to expose |
| 3 | restore @anchor as required | AC1 fails | `ERROR,...,missing required directive: -- @anchor` (+ @rows_floor) EXIT=1 -- confirmed |
| 4 | restore Guard 1 | AC1 and AC7 fail | via run-assertions: `ERROR,...,check-contract.ps1 exited 1 with no parsed assertions` EXIT=1; standalone: `GUARD 1 FAILED: zero @assert directives...` EXIT=1 -- confirmed |
| 5 | leave ANCHOR_TOTAL/ANCHOR_NONNULL unconditional | AC1 fails, TRUNCATION_*/CONSISTENCY_*/FINGERPRINT vanish | `ERROR,...,expected value 'ANCHOR_TOTAL' missing...` + same for ANCHOR_NONNULL, EXIT=1, no other lines emitted -- confirmed |
| 6 | let @rows_floor fall through to 0 | AC1 fails with spurious ROWS_FLOOR,0,219,PASS | `ROWS_FLOOR,0,219,PASS` present, EXIT=0 (no failure counted, but the trap line is the defect) -- confirmed |
| 7 (corrected) | match `@word` anywhere, unanchored | RESULT-1.md: does not bite via the spec's own prose example (known keyword). **Independently confirmed it DOES bite with an unknown word.** | Unmutated: `-- note: ask @phil about...` -> `failures=0` EXIT=0 (no error). Mutated (both tools, `^\s*--\s*` dropped): same fixture -> `ERROR,...,unknown directive: -- @phil` EXIT=1 (run-assertions) and `UNKNOWN DIRECTIVE GUARD FAILED: ...unknown directive: -- @phil` EXIT=1 (check-contract), reverted after -- confirmed |

## Additional confirmations

- **Both shipped contracts byte-identical to 9bbf700** (SHA-256 match on `All_Sales_Data.sql` and `Clayco_Job_Costs_from_GL.sql`); no throwaway contract left in `contracts\` (`Get-ChildItem contracts\*.sql` lists exactly the two).
- **`git diff --stat 9bbf700 304e6d9`**: exactly `RESULT-1.md`, `skills/lakehouse/SKILL.md`, `tools/check-contract.ps1`, `tools/run-assertions.ps1` -- 4 files, matching RESULT-1.md's claim. `tools\lake-status.ps1` is not in the list and is confirmed byte-identical (SHA-256) to 9bbf700.
- **Known residual honestly recorded and independently reproduced**: a throwaway contract with `-- @ assert broken: 1 = 2` (space after `@`) produces no error at all -- `failures=0` EXIT=0 -- confirming the gap is real and not silently fixed, matching RESULT-1.md's own statement.
- **Hyphenated-filename bug is pre-existing, not introduced by this item.** Built a fixture (`item5b-hyphentest-full2.sql`) valid under **both** the old (9bbf700) and new (304e6d9) directive-requirement grammars (declares @anchor/@rows_floor/one trivial @assert, so it passes every guard at both commits) and ran `materialize.ps1 -Contract` against it at both commits. Both fail identically: `Parser Error: syntax error at or near "-"` / `LINE 1: CREATE OR REPLACE TABLE lake.item5b-hyphentest-full2 AS SELECT * FROM contract_view;`, EXIT=1. Confirmed pre-existing at 9bbf700, unaffected by item 5b.
- **Case-sensitivity of the unknown-directive guard** independently probed beyond AC3b: a fixture with `-- @ASSERT` and `-- @Sheet` produces `unknown directive: -- @ASSERT` and `unknown directive: -- @Sheet` (both via `-cnotcontains`, confirmed by reading the guard code in both scripts: `if ($knownDirectiveKeywords -cnotcontains $word)`).
- **Status enum discipline**: `SELECT DISTINCT status FROM lake.check_history` returns only `PASS`/`DRIFT` in this session's data (no FAIL/ERROR occurred); no row's `check_id` or `observed` contains the literal `NONE`.
- **`skills\lakehouse\SKILL.md`** description field is 4 content lines (within budget), confirmed by reading the file.
- **`TASK.md` and `REVIEW-task-1.md`** remain untracked in the main working directory, confirmed by `git status` both before and after this verification session -- identical output, no drift.
- Read the actual guard implementation in both `tools\run-assertions.ps1` and `tools\check-contract.ps1`: both use `^\s*--\s*@([A-Za-z0-9_]+)` maximal-word capture (never an alternation) and `$knownDirectiveKeywords -cnotcontains $word` (case-sensitive exact membership against the seven keywords), matching RESULT-1.md's description exactly.

## Nothing found that contradicts RESULT-1.md's claims

No discrepancy between what RESULT-1.md claimed and what this independent run reproduced, on any of the 13 acceptance checks or 7 mutation proofs (including the corrected mutation 7, where RESULT-1.md's own "did not reproduce" statement and Phil's diagnosis of *why* were both independently confirmed).