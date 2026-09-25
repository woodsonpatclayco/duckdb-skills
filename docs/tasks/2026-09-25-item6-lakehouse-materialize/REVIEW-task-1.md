# REVIEW — TASK.md (item 6: materialize into the lakehouse), round 1

Reviewer: `task-reviewer`. Round 1, on the spec only — no implementer had run.
Verdict at the time: **NOT READY**, ten blocking items.

Recorded here because the reviewer reports inline and does not write the file. `PLAN-4.md` confirmed
frozen and unmodified against HEAD.

## The finding that mattered: my central claim was an artifact

The draft asserted that DuckLake permits two concurrent writers to both succeed while one silently
loses, and built a hand-rolled lock file as the remedy. The reviewer instrumented the experiment and
found **the delay did not delay**: `count(*) FROM range(900000000)` is **constant-folded** by DuckDB.

```
A start=15:22:33.397 end=15:22:33.694 exit=0     <- 297 ms, not ~10 s
B start=15:22:36.384 end=15:22:36.580 exit=0
```

A finished 2.7 s before B began. The two processes never overlapped, so neither could hit a lock, and
the later writer naturally won. Both of my "reproduced twice" runs used the same broken delay.

Rebuilt with a non-foldable delay (`max(hash(i*7+1))` over `range(2000000000)`), the overlap is genuine
and **DuckLake locks loudly**. Re-verified in the main session:

```
A start 15:33:03.685 ... holds to 15:33:15.735
B start 15:33:07.704  (inside A's window)   ->  exit 1
IO Error: Failed to attach DuckLake MetaData "__ducklake_metadata_lake" ...
Cannot open file "...lake.ducklake": The process cannot access the file ...
File is already open in ...duckdb.exe (PID <n>)
```

B wrote nothing; A's data survived. **PLAN-4 §6 was right** and the lock error it asked me to document is
real. Consequence: deliverable 2 (the hand-rolled lock) deleted entirely, along with two acceptance
checks and a mutation test. DuckLake's supported knobs named instead —
`ducklake_max_retry_count` 10, `ducklake_retry_backoff` 1.5, `ducklake_retry_wait_ms` 100.

## The pattern behind three of the blocking defects

All three of my "measured corrections to PLAN-4 §6" came from fixtures of one or two rows and
generalized incorrectly to 62,230 rows:

| draft claim | reality |
|---|---|
| no single-writer lock | the delay was folded; the lock is real and loud |
| `DATA_PATH` stays empty because data inlines | `ducklake_default_data_inlining_row_limit` is **10**; both contracts write Parquet — measured **954.4 KB** |
| catalog was 4.2 MB | that was the 1-row fixture; a real GL materialization gives **3,852 KB** |

A full GL materialization costs **0.93 s**, so there was no excuse for characterising production
behaviour with a toy fixture. The rule is now written into the spec for the next session.

## Blocking defects, and the fixes applied

**B1 — the concurrency finding was false.** Above. §1 rewritten, deliverable 2 deleted, AC13/AC14 and
the lock mutation deleted, replaced by AC17 asserting DuckLake's real behaviour including that the loser
writes no snapshot.

**B2 — AC16 could not pass.** It asserted zero files under `DATA_PATH`. Real contracts write Parquet.
Replaced by AC19, which asserts Parquet is **present** and that `snapshots()` shows
`tables_inserted_into` rather than `inlined_insert`.

**B3 — AC9 could not be satisfied honestly.** It required the history to show a floor's observed value,
but the harness emits only `ASSERT,vendorname_ratio_floor,PASS` — the ratio 0.8362 and the threshold
0.80 appear nowhere, because `check-contract.ps1` evaluates each `@assert` as `SELECT <boolean>;` and
keeps only the verdict. The reviewer predicted the cheap workaround exactly: divide two snapshots, print
a convincing trend, mark it passed, and leave `observed` NULL — failure mode (a) again. Fixed by stating
that `observed` is populated only for value-carrying line kinds, forbidding both a change to
`run-assertions.ps1` and any recomputation inside `materialize.ps1`, and rewriting the check (now AC11) to
pin the values that do exist and to **state the limitation in its own output**.

**B4 — `kind` and the gate rule had no machine-readable basis.** The taxonomy lives only in prose
comments; an invariant and a floor are byte-identical in the emitted output. Also `ERROR` was not covered
by the gate, `TRUNCATION_*`/`CONSISTENCY_*` carry no status, and `FINGERPRINT,MATCH` is outside the
declared enum. Fixed with an explicit line-shape mapping table, a note that the `_floor` suffix is
load-bearing, and — better — gating on the **harness's exit code**, which already counts exactly the
right signals and already excludes `SNAPSHOT_DRIFT` and `FINGERPRINT,DRIFT`.

**B5 — AC2 asserted the opposite of what the spec mandated.** It required "no workbook read" while
deliverable 1 required a workbook SHA-256, which *is* a full read. Measured: hash 0.118 s, sheet read
0.65 s, harness 6.23 s. Fixed: hashing is acknowledged as a read, the check now asserts no sheet parse
and no write, proved by snapshot id and `check_history` count rather than by timing. The `Serves:` line
was also reworded, since the real saving is the 6.23 s harness, not the read.

**B6 — AC8 had no expected number, so it self-graded.** "Show the row count" passes on any output, and
the grain was genuinely undefined (42–78 plausible). Fixed by defining the grain in the `kind` table and
pinning the literal total: GL 16 per run, `All_Sales_Data` 23 per run, two runs of both = **78** —
counts verified directly in the main session.

**B7 — AC6's `AT (VERSION => 1)` errors.** Snapshot ids are per-lake and the manifest and check-history
writes consume them, so `VERSION => 1` fails with `Table with name … does not exist at version 1!`
depending on creation order the spec never fixed. Fixed to read `lake_snapshot_id` from the first
manifest row.

**B8 — a real false SKIP the freshness key missed.** Both contracts call `xl_date()` from
`skills\query\duckdb-compat.sql`. Change that macro and every date in the lake decodes differently while
workbook mtime, workbook hash and contract hash are all unchanged — the tool SKIPs and serves the old
decode. This is the item-1 failure (three macros wrong, 17/17 passing) and the items-3+4 decoder failure
(6,654 of 18,764 dates wrong) queued up a third time. Fixed: `compat_sha256` added to the manifest and to
a now four-way decision, with AC5 and a mutation.

**B9 — a second false SKIP: the manifest can outlive its table.** The decision read only the newest
manifest row, never whether `lake.<contract>` still exists. The lake is gitignored scratch and its
Parquet files are separately deletable, so a dropped table would report SKIPPED forever. Fixed with a
target-exists check, `reason=target_missing`, AC7, and a mutation.

**B10 — `check_history` could not distinguish a run that landed from one that was refused.** A refused
run writes check rows and no manifest row, so `materialized_at` was a join key with no parent for exactly
the runs whose health matters most. Fixed with `run_id` as the real key (`(materialized_at,
contract_name)` is not unique) and `outcome` = `MATERIALIZED`/`REFUSED`/`FORCED`, plus AC16 for the dated
question Phil actually asked.

## Non-blocking issues fixed in the same revision

- `-Force` was sticky and invisible: a forced bad run wrote a manifest row, and the next ordinary run
  would SKIP on matching hashes, persisting known-bad data unexamined. Now a row with
  `checks_passed = false` never satisfies the freshness test, with AC14 to prove it.
- AC12/AC15 lacked the throwaway-copy qualifier that AC4 and AC12 had, risking an in-place edit to a
  shipped contract. Added, with copies confined to `$env:TEMP` so they cannot become a discoverable third
  contract.
- The workbook path source was unspecified; now read from the contract's own `read_xlsx(...)` call, as
  `run-assertions.ps1` already does, so the two cannot disagree.
- Output parsing must split on the first *n* commas — `ASSERT` details contain commas and
  `ANCHOR,Job #,219,PASS` carries a space and a `#`.
- AC20 gained drift semantics: a hash mismatch with a later mtime is a SharePoint sync to quote and
  continue past, not a failure to fix.
- `-LakeRoot` must be absolute, matching `Resolve-ExtractRoot`'s rule, which exists because a relative
  path bit a verifier mid-run.
- AC0 now notes that a worktree gets its own `<project-id>` lake — good isolation, but it leaves an
  orphan the verifier should delete.
- `observed` as VARCHAR needs `TRY_CAST(... AS DOUBLE)` for ordering; also noted that the harness already
  compares snapshot values numerically, so `materialize.ps1` must not implement a different comparison.
- SKIPPED runs write no history rows — correct, but now stated so the gaps do not read as missing data.
- PLAN-4 §8's standing-context budget (**≤ 4 description lines**, max two new skills) was unstated;
  `skills/lakehouse/SKILL.md` is the second and final one.
- `LOAD ducklake;` is required before `duckdb_settings()` will even list the DuckLake settings.

## Scope change

Deliverable 2 deleted — it was the only deliverable with no plan step behind it, and B1 removed its
justification. The reviewer judged the remainder one coherent spec that should stay together, since
`check_history` is only meaningful if the same run writes the manifest, and `lake-status.ps1` is the only
way to observe either. `compat_sha256` was explicitly kept inside this item rather than split out — it is
one more hash in a decision that already computes three.

## Main-session verification of the review

| claim | result |
|---|---|
| `count(*) FROM range(900M)` is constant-folded | confirmed — **0.105 s**; non-foldable equivalent 1.804 s |
| DuckLake locks the second writer under genuine overlap | confirmed — B exit 1, `IO Error ... File is already open`, wrote nothing |
| inlining limit is 10 rows | confirmed — `ducklake_default_data_inlining_row_limit,10` |
| real contract writes Parquet | confirmed — **954.4 KB**, `tables_inserted_into`, catalog 3,852 KB |
| retry settings exist | confirmed — 10 / 1.5 / 100 |
| harness emits no value for `ASSERT` lines | confirmed — `ASSERT,vendorname_ratio_floor,PASS`, nothing more |
| check-row counts | confirmed — GL **16**, `All_Sales_Data` **23**, so 78 for two runs of both |

All held. The revision was written against them.
