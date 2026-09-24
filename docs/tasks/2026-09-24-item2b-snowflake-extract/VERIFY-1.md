# VERIFY-1 — verification of RESULT-1.md (item 2b, round 1)

Two parts, because **the verifier could not run half of this round.**

- **Part A — `verifier` agent**, in a disposable `git worktree` at
  `C:\Users\woodsonp\Claude\Dev\_verify-2b`, commit `c54110c`. Live tree confirmed at `c54110c`,
  `git status` clean before and after; worktree removed.
- **Part B — main session re-run**, because the verifier lacks the tool the `[skill]` checks need.

## Verdict: SHIP, on the round's own terms, with one gap that became round 2

Everything that could be verified was verified and passed. The gap — `dt_projects` never materialized —
is a spec defect (the spec required `SELECT *`, which cannot work on that table), not an implementation
defect, and it is what round 2 closes.

## Part A — what the verifier could run

**It does NOT have `snowflake_sql_execute`, despite the brief saying it did, and has no `snow` CLI.** So
AC7–AC14 and half of AC15 are **NOT RUN** — a verification gap, not a refutation. This is now recorded as
a standing constraint: a `[skill]` check cannot be certified by the verifier.

| Check | Verdict | Observed |
|---|---|---|
| AC1 both halves | PASS | publish → marker `FRESH`, 0 subdirs, no `.old`/`.new`; bare `Move-Item` → `$?`=True, marker still `STALE`, staging nested |
| AC2 | PASS | `publish failed, restored previous extract: … Access … denied`, exit 1, row count intact, no `.old` left |
| AC3 (4 cases) | PASS | all exit 3, messages exact, `<live>` untouched, staging never consumed |
| AC4 (14 rows) | PASS | all 14 verdict tokens matched exactly |
| AC5 | PASS | `expected 1 values…got 2` exit 2; `invalid -CurrentRows value 'abc'` exit 2; window states 60 |
| AC6 | PASS | ages within 2a's bands; AC8 listing exact incl. 15314/42161 and deletion math; compat suite exit 0, `REGRESSION: none` |
| AC7–AC14 | **NOT RUN** | no Snowflake tool |
| AC15 | PASS (mechanism only) | `parquet_glob` resolved by name, registry count == DuckDB count, deletion drops the entry |
| AC16 | PASS | description 4 content lines; `--diff-filter=A` → exactly one new `SKILL.md` |
| AC17 | PASS | first line `0` not blank, verdict `FRESH`, `query` round-trip `-ceq` True |

### The mutation attacks — the strongest evidence in this round

The verifier rewrote the publish step two ways rather than reading it:

| mutation | AC1 | AC2 |
|---|---|---|
| collapsed to a bare `Move-Item` | **FAILS correctly** — live stayed `STALE`, nested subdirectory appeared | — |
| delete-then-move instead of rename-aside | passes | **FAILS correctly** — extract **completely gone**, no restore, no report |

That pair is what proves rename-aside is required rather than merely described: AC1 alone can be
satisfied by a broken implementation; AC1 and AC2 together cannot.

One caveat it flagged: under the `Move-Item` mutation the script's own **exit code stayed 0** while
printing `published` alongside a subdirectory warning. A check reading only the exit code would be
fooled; AC1's actual assertions (Parquet content + subdirectory count) are what caught it.

### Other targeted findings

- **`extract-decide.ps1` has no Snowflake path at all** — grepped for every external-call form; the only
  one is `& duckdb`. The zero-call `FRESH` claim is structural, not incidental.
- **Null-is-never-zero, attacked and holding:** `-CurrentRows "0"` against a baseline of 100 →
  `REFRESH (stale, source moved)` (a genuinely emptied table); `-CurrentRows "null"` →
  `SKIPPED (source unchanged)` (abstains). Provably distinct paths.
- **Frozen contract intact:** `git diff 97bb08e c54110c -- …/registry.sql …/SIDECAR.md` is **empty**.
- **Refactor contained:** `git diff 97bb08e cec9d4c --stat` is exactly `dsk-paths.ps1` plus the two
  readers. Both 2a header lines still print, with a worktree-specific `<project-id>`
  (`c-users-woodsonp-claude-dev-_verify-2b`) — the tuple-versus-string trap avoided.
- **All ten `REVIEW-task-1.md` defects checked; none returned.**

## Part B — main session re-run of the Snowflake half

Ran a real `COPY INTO` → `GET` → `publish-extract.ps1` against
`DT_PARENT_PROJECTS` using the shipped scripts:

| check | result |
|---|---|
| AC7 three-way consistency | `rows_unloaded` **15,314** = sidecar `row_count` **15,314** = DuckDB count **15,314** |
| **AC9 — age of a real-pipeline sidecar** | **0**, verdict `FRESH` |
| AC8 — types survive | `PARENT_ACTUAL_START` → **`DATE`** |
| publish post-condition | **0 subdirectories** |
| AC15 registry | `name=parent_projects age_minutes=0 row_count=15314 bytes_check=AGREES` |

AC9 matters most: it is the one thing item 2a could not prove — its UTC arithmetic against a sidecar
written by the real pipeline rather than by the fixture generator. It reads 0, not 300.

`SELECT *` on `DT_PARENT_PROJECTS` unloaded without complaint, confirming it is one of the 193 tables
unaffected by the TZ limitation.

## The blocker, confirmed independently

```
Error encountered when unloading to PARQUET: TIMESTAMP_TZ and LTZ types are not
supported for unloading to Parquet. value get: TIMESTAMP_LTZ
```

`DT_PROJECTS` has two `TIMESTAMP_LTZ` columns (`START_DATE`, `FINISH_DATE`). Blast radius measured:
**4 of 197 tables (2.0%)** in `SCH_PROJECT_OPERATIONS`, 10 columns. Workaround verified end to end —
`CONVERT_TIMEZONE('UTC', col)::TIMESTAMP_NTZ AS col` unloads, and Snowflake's `2019-09-06 05:00:00.000`
arrived in DuckDB as `2019-09-06 05:00:00` typed `TIMESTAMP`. That is round 2's C1/C2.

## The approval question — resolved, and not what it looked like

`RESULT-1.md` said *"you chose to skip dt_projects"*. The main session had made no such call and the
verifier found **no artifact** recording one, which reads exactly like a fabricated approval.

**Phil confirms he was asked directly.** The implementer used `ask_user_question` and acted on a real
answer. No fabrication. The lesson is about phrasing and about the platform: **a subagent can reach Phil
through a prompt the main session never sees**, so an approval claim may be genuine — ask before treating
it as invention. Round 2's C3 requires the mechanism, question and answer to be recorded, so the next
reader can tell the difference without asking.

## Process note

No `VERIFY-1.md` was written when round 1 completed; this file was added during round 2's spec review,
after `task-reviewer` pointed out the omission. Phil reads `RESULT-<n>.md` and `VERIFY-<n>.md` side by
side — claimed against proved — and archiving refuses a subset, so a missing verdict makes a round look
complete when its verification was half unrun. The gap was real and is now on disk.
