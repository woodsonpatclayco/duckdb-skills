# SHIPPED — Materialize contracts into the lakehouse (item 6)

Shipped 2026-09-25. Plan: `PLAN-4.md` item 6, plus one addition Phil asked for — the lakehouse records
check **results**, not just provenance. Verified SHIP on **round 1**: 22 of 22 acceptance checks and 7 of
7 mutation proofs independently reproduced from a throwaway worktree.

Commit: `58996cd`.

## What shipped

| artifact | what it does |
|---|---|
| `tools\materialize.ps1` | Reads each contract into a DuckLake table, but only when something actually changed. Refuses to materialize data that fails its checks. |
| `tools\lake-status.ps1` | What is in the lake, when it landed, whether it was sound. `-History` for a check over time, `-AsOf` for the dated question. |
| `skills/lakehouse/SKILL.md` | How to query it, how freshness is decided, and the traps. Second and final new skill under PLAN-4 §8's budget. |
| `lake.manifest` | One row per materialization: twelve columns of provenance. |
| `lake.check_history` | One row per check per materialization, with `outcome`. |
| `Resolve-LakeRoot` in `tools\dsk-paths.ps1` | Additive; the four item-2 extract tools were re-run and still behave. |

Working state:

```
MATERIALIZE,All_Sales_Data,SKIPPED
MATERIALIZE,Clayco_Job_Costs_from_GL,SKIPPED
SUMMARY,contracts=2,refreshed=0,skipped=2,refused=0,forced=0
```

## The four-way freshness key, and why each part is there

A refresh happens when **any** of these moves, plus a fifth condition:

| input | the silent failure it prevents |
|---|---|
| workbook `LastWriteTime` | the ordinary case |
| workbook SHA-256 | content changed at an unchanged mtime |
| contract SHA-256 | a contract fix ignored because the workbook did not move |
| **`duckdb-compat.sql` SHA-256** | **`xl_date()` changed, so every date decodes differently while all three other fingerprints stay identical** |
| target table missing or empty | a manifest row outliving the table it describes, reporting SKIPPED forever |

The compat hash is the one worth remembering. It was found in review, not by me, and it is the third time
this project has come close to shipping a silently wrong date decoder — after item 1 (three macros wrong
while 17/17 checks passed) and items 3+4 (a decoder wrong for 6,654 of 18,764 dates passing an
aggregate-only check).

A manifest row with `checks_passed = false` also never satisfies the freshness test, so data forced
through with `-Force` is re-examined on the next run rather than persisting unexamined.

## What deliberately did NOT change

- **The workbook.** Not one byte, across the implementer's full run and the verifier's independent one.
  Hash and mtime captured before and after each. Every experiment needing a changed workbook used a
  scratch copy.
- **`tools\run-assertions.ps1`, `tools\check-contract.ps1`, `skills\query\duckdb-compat.sql`.** Verified
  byte-identical to their pre-item-6 state. The compat file especially: its hash is now part of item 6's
  freshness key, so a stray edit there would be doubly serious.
- **Item 5's output contract.** The harness emits `ASSERT,<name>,PASS` with no value, so
  `check_history.observed` is NULL for assert rows. The tempting fix — teach the harness to emit ratios —
  would have been reaching back into shipped work, and the tempting cheat — divide two snapshots to
  synthesise the ratio and print a convincing trend — was predicted in review and specifically checked
  for. The verifier confirmed no synthesised value appears anywhere. `lake-status.ps1 -History` states the
  limitation in its own output instead.
- **No hand-rolled serialization lock.** The first draft built one. DuckLake already enforces a single
  writer; see below.
- **`docs\tasks\`.** Untouched.
- **No Snowflake.** Third item running where the verifier certified everything without a connection.

## The correction this item is really about

The first draft's headline finding was that DuckLake lets two processes materialize at once, both report
success, and one silently loses its data — and it built a lock file to compensate.

**That was wrong, and the way it was wrong is the lesson.** The delay used to make the two processes
overlap was `count(*) FROM range(900000000)`, which DuckDB constant-folds — measured **0.105 s**, not the
ten assumed. The processes never overlapped, so neither hit a lock, and the later writer naturally won.
Both "reproduced twice" runs used the same broken delay.

With non-foldable work, DuckLake locks loudly: the second writer fails at `ATTACH`, exits 1, names the
holding PID, and **writes no snapshot**. PLAN-4 §6 was right; a whole deliverable left the spec.

Two sibling claims failed identically — all three characterised production behaviour with one- and
two-row fixtures:

| draft claim | measured against a real contract |
|---|---|
| no single-writer lock | the lock is real and loud |
| `DATA_PATH` stays empty because data inlines | inlining limit is **10 rows**; a real write is a **954 KB Parquet file** |
| catalog is 4.2 MB | **3,852 KB** |

A full GL materialization costs **0.93 s**. There was no excuse. The rule now sits in the spec: measure
production behaviour against a real contract, never a toy fixture.

## What the review and verification caught beyond that

- **AC9 could not be satisfied honestly** — it asked the history to show a floor's observed ratio, which
  the harness never emits. Rewritten to pin the values that exist and disclose the gap.
- **`kind` had no machine-readable basis.** The invariant/floor/snapshot taxonomy lives in prose comments,
  and an invariant and a floor are byte-identical in the output. Now assigned by line shape, with the
  `_floor` suffix load-bearing and documented as such.
- **AC2 asserted the opposite of what the spec mandated** — "no workbook read" while also requiring a
  workbook SHA-256, which *is* a read. Hashing costs 0.118 s; the real saving from SKIP is the **6.23 s**
  assertion harness.
- **`check_history` could not distinguish a run that landed from one that was refused.** Fixed with
  `run_id` as the real join key and `outcome`, which is what makes a FAIL row interpretable at all.
- **Snapshot ids are per-lake** and the manifest writes consume them, so a hardcoded `AT (VERSION => 1)`
  errors. Read from the manifest instead.

## Debt carried forward

- **Direction-aware row tolerance** — split out of item 5, still unbuilt. Conservative floors are the
  interim answer.
- **Floors have no stored observed value**, only pass/fail, because item 5's harness does not emit one.
  The counts are stored, so ratios are derivable. Changing that is an item-5 change.
- **`Earnings Total` and `Start Date` have no ratio floors**, only snapshots. Observed 91.8 % and 68.5 %.
- **Item 2b's multi-object extract path is still unverified** — every `extract-decide.ps1` fixture is
  single-object. Untouched by this item, still outstanding, and now the oldest open item in the project.
- One environment quirk, not a code defect: during rapid mutate-then-run sequences the shell
  intermittently displayed stale output. Both the implementer and the verifier confirmed every such case
  by querying the database directly rather than trusting printed text. Worth knowing before reading the
  raw logs.
