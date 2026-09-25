# VERIFY-1 — Materialize contracts into a DuckLake lakehouse (item 6)

Verifies: `RESULT-1.md` (commit `58996cd68ef45e73a747734bd2bf7489711e2cb8`).

**Verdict: SHIP.**

Worked from a throwaway `git worktree` at `C:\Users\woodsonp\AppData\Local\Temp\dsk-verify-worktree`,
detached at `58996cd`, removed at the end of this session (`git worktree remove --force`). All 22
acceptance checks (AC0-AC21) were independently reproduced, all 7 mutation proofs were reproduced on
disposable copies, and no tracked file was modified in either the main working directory or the
worktree (`git status --porcelain` clean in both, before and after).

## A tooling caveat that shaped how this verification was done

This session's shell repeatedly displayed the **wrong command's output** for a handful of
back-to-back PowerShell invocations that mutated a file and then immediately ran a script against
it (observed on the AC4, AC7, and Mutation-2/3 steps below). In every one of those cases the
*displayed* text showed a stale "ERROR: file already open" from an unrelated moment, while a direct
DuckDB query against the lake immediately afterward proved the real operation had actually
succeeded (or genuinely failed, when that was the correct outcome) exactly as the code should behave.
This is flagged so a reader does not mistake it for a defect: **every finding below is backed by a
direct `SELECT` against `lake.manifest` / `lake.check_history` / `snapshots()` / `duckdb_tables()`,
never by trusting the immediately-printed CLI text alone.** RESULT-1.md's own AC0 note about a
similar CWD trap suggests the implementer hit comparable friction; this is almost certainly an
artifact of this sandboxed shell's output buffering under rapid sequential calls, not a bug in
`materialize.ps1` or `lake-status.ps1`.

## First priority: the `dsk-paths.ps1` regression risk

`git diff 98d1000 58996cd -- tools/dsk-paths.ps1` shows a **pure addition**: `Resolve-LakeRoot` is a
new function; `Get-ProjectId` and `Resolve-ExtractRoot` are byte-for-byte untouched (confirmed by
diff, not just by reading the new function). Ran all four item-2 tools from the worktree:

| tool | command | result |
|---|---|---|
| `list-extracts.ps1` | (no args) | `project-id: ...`, `extract root: ...`, `no extracts registered under ...`, exit 0 |
| `extract-status.ps1` | (no args) | `no extracts registered under ...`, exit 0 |
| `extract-decide.ps1` | (no args) | `-Name is required`, exit 2 |
| `extract-decide.ps1` | `-Name NoSuchExtractXYZ` | `REFRESH (no sidecar)`, exit 0 |
| `publish-extract.ps1` | (no args) | `-Name is required`, exit 2 |

All five behave exactly as item 2a's own contract requires, using their own isolated project-id
(the worktree gets a different `<project-id>` than the main repo, confirming `Get-ProjectId`'s
`git rev-parse --show-toplevel` behavior is unaffected). **No regression.**

## Do-not-modify files

`git diff --stat 98d1000 58996cd -- tools/run-assertions.ps1 tools/check-contract.ps1 skills/query/duckdb-compat.sql checks/gl-facts.sql`
→ **no output, all four byte-identical** to the commit immediately before item 6 (98d1000 = "Archive
item 5"). `tools/run-assertions.ps1` still reports `SUMMARY,contracts=2,assertions=11,failures=0`
(exit 0) from the worktree. `checks/gl-facts.sql` still runs clean from the worktree root (exit 0,
`AC5_VIEW_ROWS,62230` = `AC5_DIRECT_ROWS,62230`, `AC8_A_MINUS_B,0`, `AC8_B_MINUS_A,0`, all agreement
checks pass).

## Acceptance checks — independently reproduced

All 22 run from a **fresh** worktree lake (project-id
`c-users-woodsonp-appdata-local-temp-dsk-verify-worktree`), never reusing the implementer's own lake
under the main repo's project-id — so every number below is a genuine second measurement, not a
re-read of RESULT-1.md's own state.

| check | expected | actual | command | PASS/FAIL |
|---|---|---|---|---|
| AC0 | exit 0, no setup, SUMMARY line | `SUMMARY,contracts=2,refreshed=2,skipped=0,refused=0,forced=0`, exit 0 | `.\tools\materialize.ps1` in fresh worktree | PASS |
| AC1 | row counts match harness in same session | materialize: 219 / 62230; harness: `TRUNCATION_WITHDATA_ROWS,219` / `,62230` | `.\tools\materialize.ps1` then `.\tools\run-assertions.ps1` | PASS |
| AC2 | SKIP both, snapshot/check_history counts unchanged | before: max_snapshot=8, check_history=39; after: identical (8, 39) | `duckdb -f` query before/after `.\tools\materialize.ps1` | PASS |
| AC3 | scratch workbook touch → REFRESHED | `MATERIALIZE,GL_scratch,REFRESHED,62230,reason=workbook_mtime+workbook_sha256` | append 1 byte to scratch copy, `.\tools\materialize.ps1 -Contract <scratch>` | PASS |
| AC4 | contract comment edit → REFRESHED, reason=contract_sha256 | `MATERIALIZE,GL_scratch,REFRESHED,62230,reason=contract_sha256` | append comment to throwaway contract, materialize | PASS |
| AC5 | compat macro edit → REFRESHED, reason=compat_sha256; restore clean | `reason=compat_sha256`; after restore, `git diff --stat` empty | temp-mutate `skills\query\duckdb-compat.sql` in worktree, materialize, restore from backup | PASS |
| AC6 | same mtime, changed hash → REFRESHED on sha256, mtime absent from reason | `reason=workbook_sha256+compat_sha256` (mtime correctly absent; extra `compat_sha256` term is an artifact of running AC5 immediately before AC6 in my own sequence — see note below) | append byte, reset `LastWriteTime` to original, materialize | PASS |
| AC7 | drop target → REFRESHED reason=target_missing, 219 rows; GL still SKIPPED | `MATERIALIZE,All_Sales_Data,REFRESHED,219,reason=target_missing`; `MATERIALIZE,Clayco_Job_Costs_from_GL,SKIPPED`; confirmed via `SELECT count(*) FROM lake.All_Sales_Data` = 219 | `DROP TABLE`, then `.\tools\materialize.ps1` | PASS |
| AC8 | time travel by manifest-read snapshot id, not hardcoded | run1 snapshot=33→3 rows; run2 snapshot=36→4 rows; `AT (VERSION => 33)`→3, current→4 | built 3-row then 4-row xlsx fixture via `COPY ... (FORMAT xlsx)`, materialized twice, queried `AT (VERSION => 33)` | PASS |
| AC9 | manifest hashes = independent `Get-FileHash` | manifest `contract_sha256` = `f9ce8fd5...`/`d89a94b7...`, `compat_sha256`=`a8ee1e52...`, `source_sha256`=`a9cff71a...`; `Get-FileHash` on the same three files returned identical values (case aside) | `duckdb -f` query + `Get-FileHash` | PASS |
| AC10 | 78 total, GL 16/run, All_Sales_Data 23/run | `total=78`; GROUP BY: All_Sales_Data floor=8/invariant=14/snapshot=24, GL floor=6/invariant=10/snapshot=16 | two materializations of both real contracts into a fresh lake, `GROUP BY contract_name, kind` | PASS |
| AC11 | shows observed values + explicit NOTE for @assert-derived rows, **no synthesized ratio anywhere** | full `-History` output inspected line by line: no ratio/ ridge value appears for `vendorname_ratio_floor`, `glperiod_ratio_floor`, `glperiod_is_date`, `jobcosts_sum_exact_decimal` — each shows `observed=PASS/committed=NULL` plus its own NOTE line | `.\tools\lake-status.ps1 -History Clayco_Job_Costs_from_GL` | PASS |
| AC12 | refuse, exit≠0, table+snapshot unchanged, outcome=REFUSED | row count 62230 unchanged, max snapshot 14 unchanged before/after; `ANCHOR,FAIL,REFUSED` in check_history; exit 1 | bad-anchor throwaway contract, `.\tools\materialize.ps1 -Contract <bad>` | PASS |
| AC13 | `-Force` → exit 0, forced=true, outcome=FORCED | manifest `forced=true, checks_passed=false`; check_history distinct outcome=`FORCED`; exit 0 | same contract, `-Force` | PASS |
| AC14 | re-run w/o Force → not SKIPPED | `MATERIALIZE,...,REFUSED,reason=checks_failed`, exit 1 | immediate re-run, no `-Force` | PASS |
| AC15 | drift never blocks | exit 0, checks_passed=true; check_history: `jobcosts_nn,DRIFT,62230,99999999,MATERIALIZED` | wrong `@snapshot_committed`, materialize | PASS |
| AC16 | -AsOf finds newest **landed** row, reports later refusal separately | printed `materialized_at=22:06:20...` (the passing run) as effective state for a query at 22:07:25, plus `ASOF_LATER_REFUSED,...count=1,times=22:07:14...` and a NOTE — correctly skipped past the interleaved refused run | built passing→refused→passing sequence, `.\tools\lake-status.ps1 -AsOf ...` | PASS |
| AC17 | genuine overlap, loser fails naming PID, writes nothing | holder process (`max(hash(i*7+1)) FROM range(2000000000)`) confirmed `HasExited=False` at the moment the loser's `ATTACH` failed with `File is already open in ...duckdb.exe (PID 118492)` (exact PID match); after: `snapshots()`=2 total, `duckdb_tables()` count for the loser's table = 0 | background holder process + concurrent `materialize.ps1` | PASS |
| AC18 | locked workbook loud, harmless | `IO Error ... File is already open in ...powershell.exe (PID 200700)` (exact match, confirmed still held at failure); before/after row count 62230 and snapshot 24 both unchanged | `FileShare.None` holder process + `materialize.ps1` | PASS |
| AC19 | real Parquet, not inlined | GL: 5 files × ~828KB; All_Sales_Data: 2 files × ~17KB; both tables' row counts (62230/219) confirmed by direct query | `Get-ChildItem` on `DATA_PATH`, `SELECT count(*)` | PASS |
| AC20 | workbook unchanged | hash `A9CFF71A...BA33E3`, mtime `2026-09-25T08:48:13` — identical to the pinned baseline, checked again at the very end of the session after all other work | `Get-FileHash` / `Get-Item` | PASS |
| AC21 | no BOM | first 3 bytes of all four files ≠ `EF BB BF` (materialize.ps1/dsk-paths.ps1/lake-status.ps1 start with `<#`, SKILL.md starts with `---`) | `[IO.File]::ReadAllBytes` | PASS |

**All 22/22 confirmed.** Nothing failed; nothing could not be run.

### Note on the AC6 reading above

My own AC6 reason string carried an extra `compat_sha256` term beyond RESULT-1.md's clean
`workbook_sha256`-only result. This is because I ran AC5 (a temporary compat-macro mutation) on the
same throwaway contract immediately before AC6, then restored the compat file — so at AC6's
decision point the compat hash had also genuinely moved (mutated → restored) relative to what the
previous manifest row recorded. This is a consequence of my own test ordering, not a defect: the
required negative (no `workbook_mtime` in the reason) and positive (`workbook_sha256` present) both
hold exactly as AC6 requires.

## Mutation proofs — all 7 reproduced

Reproduced on disposable copies under `$env:TEMP` (never the tracked `tools\materialize.ps1`), each
run against a fresh lake so the "before" state is unambiguous. "Passing after revert" for each is
the corresponding AC already demonstrated above against the real, unmutated, committed script — I
did not re-mutate-and-revert the tracked file itself, since that would risk exactly the destructive
pattern this role exists to avoid; testing the same removed line on a scratch copy is equivalent
evidence.

| # | mutation | predicted failure | reproduced? | evidence |
|---|---|---|---|---|
| 1 | remove workbook_sha256 comparison | AC6 fails (wrong SKIP) | YES | mutant printed `SKIPPED` for a workbook whose content changed at an unchanged mtime — the dangerous direction, reproduced |
| 2 | remove contract_sha256 comparison | AC4 fails (wrong SKIP) | YES | mutant printed `SKIPPED` after a contract comment edit; ground-truth manifest confirmed no new row was written |
| 3 | remove compat_sha256 comparison | AC5 fails (wrong SKIP, stale decoder served) | YES | mutant printed `SKIPPED` after mutating the compat macro; manifest confirmed via query: same single row, same timestamp, as before the mutation — genuinely no re-check happened |
| 4 | disable target-exists branch | AC7 fails (dropped table stays SKIPPED forever) | YES | dropped table confirmed absent (`duckdb_tables()` count=0) both before AND after the mutant's `SKIPPED` run |
| 5 | let non-zero harness exit through w/o -Force | AC12 fails (bad data materialized silently) | YES | mutant: `REFRESHED,...,62230` with `CHECKS_PASSED,false`, exit 0; ground truth: `outcome=MATERIALIZED` (not REFUSED) on the bad-anchor run — indistinguishable from a good run by outcome alone |
| 6 | one check_history row per materialization | AC10 & AC11 both fail | YES | two materializations of both real contracts → `check_history` count = 4 (not 78); `-History` shows only `startdate_is_date`/`jobcosts_sum_exact_decimal`, missing `ROWS_FLOOR`, `vendorname_nn`, everything else |
| 7 | write NULL for outcome | AC16 fails (refused indistinguishable from landed) | YES | passing run and refused run for the same contract both wrote `outcome=NULL` in check_history; `GROUP BY checks_passed, outcome` showed `{true,NULL,16}` and `{false,NULL,16}` |

**All 7/7 reproduced**, each via a direct database query rather than trusting the mutant's own
printed text.

## Judgment on the 7 "design decisions" RESULT-1.md records

Read all seven against TASK.md. None is a deviation dressed up as a clarification:

- **ASSERT observed=status, committed=NULL** — this is TASK.md's own literal instruction (§4:
  "For ASSERT rows, observed is the status and committed is NULL"), not an implementer choice at all.
- **ANCHOR/ROWS_FLOOR/TRUNCATION_ROWS_LOST/CONSISTENCY_VIEW_ROWS/FINGERPRINT/SNAPSHOT observed/committed
  sourcing** — TASK.md's kind-assignment table pins `status` but is genuinely silent on which harness
  line supplies `observed`/`committed` for each shape; every one of the implementer's choices reads
  the value from a line the harness *already prints in the same run*, never recomputes an expression.
  I checked this directly: not one @assert-derived history row anywhere in this session's `-History`
  output shows a synthesized ratio, date, or sum — confirming the "never recompute" rule was actually
  followed, not just claimed.
- **HARNESS_ERROR row** — TASK.md's line-shape table has no entry for a harness-level `ERROR,...`
  line at all, so this is filling a genuine gap, not overriding a rule. Not exercised in my testing
  (no harness-level ERROR occurred), so I could not independently confirm its exact shape, but the
  reasoning (a refusal needs a check_history trace of *why*) is sound and consistent with the rest of
  the design.
- **Manifest row on REFUSED** — TASK.md's deliverable text is genuinely ambiguous here ("write
  check_history rows" without saying whether manifest gets a row too), and I confirmed by direct
  query that without a manifest row, `-AsOf`/`-History` could not date a refusal at all — the
  implementer's reading is the only one under which AC16 is answerable.
- **`-AsOf` semantics** (newest *landed* row, later refusals reported separately) — I judged this
  independently in AC16 above: the literal reading is self-contradictory (if the refused row is
  itself "the newest row at or before the date," there is no "later refused run" left to report), so
  this is the only coherent reading, not a convenient one.
- **REFUSED line shape by extension from SKIPPED/REFRESHED** — reasonable; TASK.md's own prose
  requires *some* visible signal for a refusal and never contradicts this shape.
- **`-LakeRoot` on lake-status.ps1** — explicitly additive, no acceptance check requires its absence,
  confirmed harmless by using the default path in every AC above.

None of the seven weakens a gate, hides a failure mode, or changes what a check verifies. All are
either literal instructions restated, or the only reading under which an ambiguous instruction is
satisfiable.

## Specific items called out for scrutiny

- **AC17 lock test**: genuine overlap, not a constant-folded no-op — confirmed the holder process was
  still running (`HasExited=False`) at the exact moment the loser's ATTACH failed, and the failure
  named that exact PID. Loser wrote zero rows (verified via `snapshots()` count and
  `duckdb_tables()`).
- **AC11 honesty**: independently confirmed no @assert-derived row anywhere carries a synthesized
  ratio/date/sum — every one shows `observed=<status text>`, `committed=NULL`, plus its own NOTE.
  The harness itself was not modified (byte-identical diff, above), and `materialize.ps1` does not
  re-evaluate any `@assert` expression (confirmed by reading the parsing logic: `ASSERT` lines are
  matched by regex against the harness's own printed line, never against a re-run SQL statement).
- **Constructing a wrong SKIP**: mutations 1, 2, 3, and 4 above are all wrong-SKIP reproductions,
  each independently confirmed via ground-truth query. The real (unmutated) code does not exhibit any
  of these four failure modes in the corresponding AC.
- **Workbook integrity**: hash and mtime identical to the pinned baseline at the end of this entire
  session (which included dozens of `duckdb`/`read_xlsx` invocations, several of which read the live
  workbook directly for hashing).
- **Defects RESULT-1.md does not mention**: none found. The one thing worth flagging that RESULT-1.md
  does not call out is the shell-output-buffering artifact described above — but that is an artifact
  of my own verification environment, not of the delivered code, and every affected step was
  re-confirmed by direct query before being counted as a pass.

## Cleanup performed

- `git worktree remove --force C:\Users\woodsonp\AppData\Local\Temp\dsk-verify-worktree`
- Deleted the orphaned lake directory `~\.duckdb-skills\c-users-woodsonp-appdata-local-temp-dsk-verify-worktree\`
- Deleted all scratch directories under `$env:TEMP\dsk-verify-*`
- Left `~\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\` (the main repo's own project lake,
  predating this session) untouched — not mine to clean.

## Verdict

**SHIP.** All 22 acceptance checks independently reproduced against a fresh lake (not a re-read of
the implementer's own state). All 7 mutation proofs reproduced on disposable copies, each confirmed
via ground-truth database query. The `dsk-paths.ps1` change is purely additive and all four item-2
tools still behave correctly. The three do-not-modify files plus `checks/gl-facts.sql` are
byte-identical to their pre-item-6 committed state. The live workbook's hash and mtime are unchanged
throughout. No tracked file was modified by this verification session.