# VERIFY-2 — verification of RESULT-2.md (item 2b, round 2)

Two parts, because the verifier cannot reach Snowflake.

- **Part A — `verifier` agent**, disposable `git worktree` at
  `C:\Users\woodsonp\Claude\Dev\_verify-2b-r2`, commit `7a36599`. Tree clean before and after;
  worktree removed. Scope was set in advance to what it can actually run.
- **Part B — main session**, for the `[skill]` half.

## Verdict: SHIP

## Part A — the local half

The verifier confirmed its own limits first: it has `bash`, `read`, `grep`, `glob`, `read_tabular`,
`system_todo_write` and the context-graph MCP tools. **No `snowflake_sql_execute`, and
`Get-Command snow` returns nothing.** Exactly as round 1 found — so the scoping in the corrections was
correct rather than pessimistic.

| Check | Verdict | Observed |
|---|---|---|
| AC1 both halves | PASS | publish → `FRESH`, 0 subdirs, no `.old`/`.new`; bare `Move-Item` → `$?`=True, live still `STALE`, nested dir holds the fresh copy |
| AC2 | PASS | `publish failed, restored previous extract: … Access … is denied`, exit 1, row count 7 intact, no `.old` |
| AC3 (4 cases) | PASS | all four messages exact, exit 3, live row count still 3 |
| AC4 (14 rows) | PASS | every verdict token matched, including `STALE (probe required) age=90 window=60 objects=DB.SCH.A` and `REFRESH (clock skew) age=-45` |
| AC5 | PASS | both usage errors exit 2 with exact messages; window default 60 stated |
| AC6 | PASS | ages **1 / 91 / 1501** inside 2a's bands; deletion math exact (`1276957 − 381002 = 895955`); compat suite `REGRESSION: none`, exit 0 |
| AC16 | PASS | description exactly 4 content lines; `--diff-filter=A` → one new `SKILL.md` |
| AC17 | PASS | first line `0`, verdict `FRESH`, `-ceq True` |
| AC19 local half | PASS | sidecar `query` is **3,074 chars** and contains `CONVERT_TIMEZONE('UTC', "START_DATE")::TIMESTAMP_NTZ` **with the column double-quoted**, same for `FINISH_DATE`; `extract-status.ps1` first line **`24`** — numeric, not blank |
| AC20 local half | PASS | `parent_projects` query exactly `SELECT * FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS`, `-ceq True`, 72 chars, no casts |

### The no-change promise, proven by diff rather than asserted

```
git diff --name-only fb4eecb 7a36599
→ RESULT-2.md
  skills/snowflake-extract/SKILL.md
```

Two files. **None** of `dsk-paths.ps1`, `extract-decide.ps1`, `publish-extract.ps1`,
`make-decide-fixtures.ps1`, `list-extracts.ps1`, `extract-status.ps1`, `registry.sql` or `SIDECAR.md`
changed. `SKILL.md` is 41 insertions / 7 deletions, entirely inside the materialize block, frontmatter
untouched.

### Mutation attacks re-run, since publish is the dangerous code

| mutation | result |
|---|---|
| rename-aside collapsed to a bare `Move-Item` | live stayed `STALE`, 1 nested subdirectory, **exit 0** — AC1 fails as it should |
| delete-then-move, using the same `[IO.Directory]::Move` API | **extract completely gone**, no restore — AC2 fails as it should |

The verifier corrected its own process mid-run and said so: its first delete-then-move mutant used the
`Move-Item` **cmdlet**, which tolerated the open handle and succeeded, giving a misleading pass unrelated
to the question. Re-running with the same API the shipped script uses reproduced round 1's finding
cleanly. That is a real difference between two "delete-then-move" implementations, not a flaw in the
shipped code — and it is the kind of self-correction worth having on record.

### The round's actual deliverable — the `SKILL.md` text — assessed

Nothing else verifies prose, so the verifier read it against seven required points. **All seven
present:** generic by column type; `INFORMATION_SCHEMA` must be database-qualified; every projected
column double-quoted with the reason; projection re-derived every materialize, never replayed;
fail-loud rule; landed type is a naive `TIMESTAMP` holding UTC with the `timezone('UTC', now())`
discipline; scoped to single-object whole-table `SELECT *`.

And the anti-special-casing requirement holds: grepped for `DT_PROJECTS`, `START_DATE`, `FINISH_DATE`,
`107` and `113` — **zero matches** in the new section. A future session can apply the rule to a table
nobody has seen.

## Part B — main session, the Snowflake half

| check | result |
|---|---|
| Column completeness | `INFORMATION_SCHEMA.COLUMNS` = **107**, ordinals contiguous 1–107, 2 TZ columns; landed Parquet `ncols` = **107**. Nothing dropped. |
| TZ columns as landed | `START_DATE` and `FINISH_DATE` both **`TIMESTAMP`** — not VARCHAR, not `TIMESTAMP WITH TIME ZONE` |
| Row count | **42,167** in the Parquet |
| **Lossless, by an independent path** | Snowflake `DATE_PART(EPOCH_SECOND, START_DATE)` → `1567746000`, `1459746000`, `1739426400`; DuckDB `epoch(START_DATE)` on the landed Parquet → **identical for all three**. No multiple-of-3600 shift. |

The epoch comparison is the one that matters: it does **not** reuse `CONVERT_TIMEZONE`, so it can detect
a timezone-shifted projection, which the round-1 draft of this check could not.

## The 107-versus-113 discrepancy — resolved

The corrections said `DT_PROJECTS` has 113 columns. It has **107**. `RESULT-2.md` reported the mismatch
explicitly and used the live figure consistently rather than adjusting a check to match the spec — the
right call.

Cause: the 113 came from `snowflake_object_search`, whose index is **stale**.
`INFORMATION_SCHEMA.COLUMNS` is authoritative and was confirmed twice. Worth remembering — the object
search is fine for discovery, not for a figure a check depends on.

## Final state

Both extracts present and consistent, so the evidence for this round stays inspectable:

```
name=parent_projects age_minutes=22 row_count=15314 size_bytes=518925  bytes_check=AGREES
name=dt_projects     age_minutes=30 row_count=42167 size_bytes=5223915 bytes_check=AGREES
total_size_bytes=5742840
```

## Known gap, recorded rather than closed

Every `extract-decide.ps1` fixture is single-object, so the **multi-object stage-1/stage-2 rule** and
round 1's `@(… | ConvertFrom-Json)` nesting fix have no passing evidence. Deferred deliberately and
stated here so a later round does not assume it was covered.
