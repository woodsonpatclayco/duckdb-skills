# VERIFY — item 2c, round 1

Verifier: `verifier` subagent, working in a throwaway `git worktree` at `ff445c0` (detached HEAD),
removed afterwards. Main working directory confirmed untouched before and after.

Verdict: **SHIP.**

Recorded here by the main session because the verifier reported inline and did not write the file — the
same omission caught in item 2b round 1. Content is its findings, not a re-run.

## Provenance caveat this verification had to carry

Item 2c had **two implementers**. The first did substantial work on `tools\extract-decide.ps1` and
`tools\make-decide-fixtures.ps1` and halted without committing; the second reviewed those diffs, finished
the remaining deliverables, and committed. No single agent wrote all of it, and the inherited portion was
never checked while it was being written, so the verifier was instructed to treat the whole diff as
unreviewed.

## Acceptance checks — 14 of 14 independently confirmed

| check | result |
|---|---|
| AC1 before / after | pre-fix `expected 2 values for 2 source objects, got 1` exit 2; post-fix `SKIPPED (source unchanged)` exit 0 |
| AC2 | all 10 matrix rows identical to `RESULT-1.md` |
| AC3 | array form identical to the `-File` form |
| AC4 | post-fix **0 bytes** stderr both single- and two-object; pre-fix **non-zero** |
| AC4 anti-suppression | `2>$null` = 1, `SilentlyContinue` = 0, `ErrorActionPreference` = 0 |
| AC5 | `minus1500` → `REFRESH (no evidence past ceiling)`; `minus90` → `SKIPPED (no evidence) age=97` (drift, within ±3 of nominal after elapsed session time) |
| AC6 (control) | `SKIPPED (source unchanged)` — unchanged stays unbounded |
| AC7 | both directions: ceiling 1440 → skip, ceiling 60 → refresh |
| AC8 | three usage errors, all exit 2, including `"100,"` on the empty-element rule |
| AC9 | `abc` → invalid exit 2; `null,NULL` → accepted exit 0 |
| AC10 | comma-joined `-CurrentLastAltered` → `SKIPPED (ambiguous: …)` |
| AC11 | **all 14 baseline rows match exactly**; `g` and `m` correctly stay on `SKIPPED (source unchanged)` |
| AC12 | `extract-status`, `list-extracts`, `publish-extract` all run |
| AC13 | all 13 verdicts reproduced, including the `damaged` tree's two |
| AC14 | no BOM in any of the four touched files |

## Mutation proofs — 5 of 5, on scratch copies, never the tracked file

| # | mutation | failing | passing |
|---|---|---|---|
| 1 | drop comma-splitting | `got 1`, exit 2 | `SKIPPED (source unchanged)` |
| 2 | both-abstain → `SKIPPED (source unchanged)` | wrong skip on both fixtures | correct no-evidence verdicts |
| 3 | drop the ceiling check | `minus1500` wrongly skipped at age 1515 | `REFRESH (no evidence past ceiling)` |
| 4 | retype the placeholder instead of wrapping | **stderr 333 bytes**, bug reproduced verbatim | 0 bytes |
| 5 | add a second `2>$null` instead of guarding | stderr 0 bytes — *falsely looks clean* — but count = 2 | count = 1 |

Mutation 4 is the one that matters: it confirms the fix addresses the real array-unrolling mechanism
rather than the misdiagnosed placeholder-type one. Mutation 5 confirms the anti-suppression assertion is
what catches a cosmetic "fix".

## The D2 fix mechanism, read directly

`extract-decide.ps1:310`:

```powershell
$currentLastAltered = @(if ($PSBoundParameters.ContainsKey('CurrentLastAltered')) { $CurrentLastAltered } else { [object[]]::new($sourceObjectsList.Count) })
```

The `@(...)` wraps the **entire `if`-statement output**, forcing array semantics on the pipeline
enumeration. It does **not** retype the placeholder. Correct.

## Adversarial probe: could a wrong SKIP be constructed?

Three attempts, all designed to trick the tool into `SKIPPED (source unchanged)` with no real evidence:
single object with null rows and no `-CurrentLastAltered`; two objects with `[null,null]` rows and
unparseable `last_altered` strings; and `two_object_w6` with both rows null and no `last_altered`.

**All three correctly returned `SKIPPED (no evidence) age=<n>`.** No wrong SKIP could be constructed — the
D1 fix held under adversarial testing.

## Regression sweep

| target | result |
|---|---|
| `tools\run-assertions.ps1` | `SUMMARY,contracts=2,assertions=11,failures=0`, exit 0 |
| `duckdb -f checks\gl-facts.sql` | all rows clean including `AC8_A_MINUS_B,0` / `AC8_B_MINUS_A,0` |
| `tools\materialize.ps1` | both contracts REFRESHED, `CHECKS_PASSED,true`, exit 0 |
| five `dsk-paths.ps1` dependents | all run correctly |
| `tools\make-extract-fixtures.ps1` | byte-identical across the whole range — item 2a's AC10 holds |
| diff scope | exactly four files: `RESULT-1.md`, `SKILL.md`, `extract-decide.ps1`, `make-decide-fixtures.ps1` |
| `SKILL.md` description block | still exactly 4 lines — item 2b's AC16 pin holds |
| header | 13 verdicts named; parallel-array guard documented as load-bearing at lines 74–83, judged adequate |

## Two write-up inaccuracies in `RESULT-1.md`

Neither blocks shipping; both recorded because an unremarked inaccuracy erodes trust in the log.

1. **Stderr byte counts do not reproduce verbatim.** `RESULT-1.md` claims 1,424 / 1,380; the verifier
   measured **1,408** via native `2>` redirection and **333–357** via `Start-Process`. A capture-method
   artifact — every method agrees on non-zero → zero, which is the fact under test.
2. **The `2>$null` line citation predates the header commit.** `RESULT-1.md` cites line 205; on the
   shipped tree it is line **216**, and `4d41739` added exactly 11 lines to the header. So that citation
   was captured *before* the header fix, which contradicts the same file's claim that every check was
   re-run afterwards. The fact checked — count = 1 — is correct on the shipped tree.

## Main-session confirmation

Independently re-ran the headline deliverable on `main` after merge: `two_object` with
`-CurrentRows 100,200` through `powershell -File` returns `SKIPPED (source unchanged)`, and the `2>$null`
occurrence count is 1.
