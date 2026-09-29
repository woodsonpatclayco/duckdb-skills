Plan: PLAN-4.md
Serves: an extract built from more than one Snowflake table can be freshness-checked at all — and
an extract whose source metadata is unavailable stops being served as current forever.

# RESULT-1 — Item 2c: clear item 2b's multi-object debt (D1/D2/D3)

Branch `item2c-multi-object-debt`. Two commits, pushed:

- **`43e2c40`** — `tools\extract-decide.ps1`, `tools\make-decide-fixtures.ps1`,
  `skills\snowflake-extract\SKILL.md`. The bulk of the work, most of it inherited from a prior
  implementer session that halted before committing.
- **`4d41739`** — `tools\extract-decide.ps1` only. A documentation-only fix (see "Found wrong in
  the inherited work" below) made after reviewing the inherited diff against the spec's own
  checklist.

This session picked up uncommitted work in two files and finished it: reviewed both diffs against
the spec, found and fixed one gap, wrote the fifth deliverable (`SKILL.md`), ran all 14 acceptance
checks with actual command output, ran all five required mutation proofs in both directions,
committed, and pushed.

**Absolute fixture root used throughout:** `C:\Users\woodsonp\Claude\Dev\duckdb-skills\.duckdb-skills\fixtures`.
Regenerated with:
```
powershell -NoProfile -File tools\make-decide-fixtures.ps1 -Root C:\Users\woodsonp\Claude\Dev\duckdb-skills\.duckdb-skills\fixtures\decide
powershell -NoProfile -File tools\make-extract-fixtures.ps1 -Root C:\Users\woodsonp\Claude\Dev\duckdb-skills\.duckdb-skills\fixtures
```
The `ages`/`damaged`/`empty` trees land directly under that root; the `decide` tree at
`<root>\decide`. Every command below passes the matching absolute path as `-ExtractRoot`.

---

## Review of the inherited diffs (before building on them)

**`tools\make-decide-fixtures.ps1` (+73 lines):** matches the spec's deliverable 4. `two_object`
and `two_object_w6` are built through a hand-written `New-DecideFieldsMulti`, not through
`New-DecideFields` (which hardcodes single-element `source_bytes`/`source_last_altered` arrays and
would have produced a malformed two-object sidecar). Verified both sidecars on disk carry all
three `source_*` arrays at length 2 (see below). `$RowsBaseline` is typed `[object[]]` so
`two_object_w6`'s null element survives `ConvertTo-Json` as a JSON `null`, not a coerced `0` —
confirmed by reading the generated JSON directly.

**`tools\extract-decide.ps1` (+74/−9, before this session's follow-up commit):** all three defects
addressed as specified:
- **D3** (deliverable 1): `Split-CommaJoined` splits and trims each element on commas, applied to
  both `-CurrentRows` and `-CurrentLastAltered` after the `-CurrentRows`-supplied check, before the
  length/value validation. Both parameters stay `[string[]]`, and the existing multi-value array
  form is untouched.
- **D2** (deliverable 2): the placeholder fix is a `@(...)` wrap forcing array semantics on the
  `if`-statement's own output (`$currentLastAltered = @(if (...) { $CurrentLastAltered } else {
  [object[]]::new($sourceObjectsList.Count) })`), **not** a retype of the placeholder. This is the
  correct mechanism per the spec's own diagnosis — retyping reproduces the bug (proved by mutation
  4 below).
- **D1** (deliverable 3): a new `if ($stage1 -eq 'abstain' -and $stage2 -eq 'abstain')` branch,
  reached only after both `moved` branches have already returned, printing
  `SKIPPED (no evidence) age=<n>` or `REFRESH (no evidence past ceiling)` bounded by
  `DSK_MAX_AGE_MINUTES`.
- The one legitimate `2>$null` (the `& duckdb` call) is still the only one in the file.

**Found wrong in the inherited work:** the header verdict list correctly went from 11 to 13 lines,
but the spec's explicit second instruction — "confirm... the parallel-array constraint is
documented there as load-bearing" — was **not done**. `registry.sql`'s length-mismatch guard
(closing the silent-skip/silent-ignore hole in `Test-RowsStage`/`Test-LastAlteredStage`) was
nowhere in `extract-decide.ps1`'s header. Fixed in commit `4d41739`, adding a paragraph stating the
guard, why it is load-bearing, and that a future refactor must not remove it under the assumption
this script already enforces the lengths. This is documentation-only — no logic changed, and every
check below was re-run after the fix to confirm behavior was unaffected.

No other defect found in the inherited diffs.

---

## Fixture verification

`two_object\_extract.json` and `two_object_w6\_extract.json`, read back after regeneration:
`source_objects` `["DB.SCH.A","DB.SCH.B"]`, `source_rows` `[100,200]` / `[100,null]`,
`source_bytes` `[2048,2048]`, `source_last_altered` both two-element arrays — all three parallel
arrays at length 2 in both fixtures, as `registry.sql` requires.

---

## Deliverable 5 — `skills\snowflake-extract\SKILL.md`

Not started by the inherited work. Added in this session: the "Read" section's `STALE (probe
required)` bullet now states the comma-joined form (`powershell -File` cannot bind separate values
to an array parameter) with a worked two-object example
(`-CurrentRows 100,205 -CurrentLastAltered "<a-timestamp>,<b-timestamp>"`); the `REFRESH (...)`
bullet now names `REFRESH (no evidence past ceiling)` explicitly; the `SKIPPED (...)` bullet now
names `SKIPPED (no evidence) age=<n>` explicitly and states it means "no comparable metadata", not
"source unchanged". The frontmatter `description: >` block is untouched — still 4 content lines
(verified: lines 4–7 of the file, unchanged from item 2b's own AC16 pin).

---

## Acceptance checks

### AC1 — the debt, discharged through the documented path — PASS

Before (pre-fix script, `git show 337b29d:tools/extract-decide.ps1`, run from a mirror tree so its
sibling `dsk-paths.ps1`/`registry.sql` resolve):
```
> powershell -NoProfile -File <mirror>\tools\extract-decide.ps1 -Name two_object -ExtractRoot <abs>\decide -CurrentRows 100,200
expected 2 values for 2 source objects, got 1
exit=2
```
After:
```
> powershell -NoProfile -File tools\extract-decide.ps1 -Name two_object -ExtractRoot <abs>\decide -CurrentRows 100,200
SKIPPED (source unchanged)
exit=0
```

### AC2 — the whole matrix, through `-File` — PASS, all 10 rows

Fixture `two_object` (`source_rows` `[100,200]`, `source_last_altered` both baselined the same,
age ~90–100 across the session):

| row | command (`-CurrentRows` / `-CurrentLastAltered`) | actual output | exit |
|---|---|---|---|
| 1 both unchanged | `100,200` / `<same>,<same>` | `SKIPPED (source unchanged)` | 0 |
| 2 second moved | `100,201` | `REFRESH (stale, source moved)` | 0 |
| 3 first moved | `101,200` | `REFRESH (stale, source moved)` | 0 |
| 4 first unknown, second unchanged | `null,200` | `SKIPPED (source unchanged)` | 0 |
| 5 first unknown, second moved | `null,201` | `REFRESH (stale, source moved)` | 0 |
| 6 rows same, second last_altered moved | `100,200` / `<same>,<moved>` | `SKIPPED (ambiguous: last_altered moved, rows unchanged) age=90` | 0 |
| 7 rows same, both last_altered same | `100,200` / `<same>,<same>` | `SKIPPED (source unchanged)` | 0 |
| 8 3 values for 2 objects | `100,200,300` | `expected 2 values for 2 source objects, got 3` | 2 |
| 9 `[null,null]` nothing comparable | `null,null` | `SKIPPED (no evidence) age=91` | 0 |

Fixture `two_object_w6` (`source_rows` `[100,null]`), row 10 (W6, per-object aggregation):
```
-CurrentRows 100,null -CurrentLastAltered "<same>,<moved-for-B>"
-> SKIPPED (ambiguous: last_altered moved, rows unchanged) age=90
```
Every verdict token matches TASK.md's "Measured facts" table exactly, including row 9's D1 fix
(previously the wrong `SKIPPED (source unchanged)`, now correctly `SKIPPED (no evidence)`).

### AC3 — the array form still works — PASS

Re-ran rows 1, 2, 9, and 10 as `& .\tools\extract-decide.ps1 ... -CurrentRows @('100','200')` (and
`@('null','null')`, `@('100','null')`) in-process: identical verdicts and exit codes to AC2 in
every case checked.

### AC4 — stderr is empty on a call that actually reaches stage 2 — PASS

- Single object, **no** `-CurrentLastAltered` (the only case that discriminates — see below):
  `-Name c_unchanged -CurrentRows 100` → `SKIPPED (source unchanged)`, stderr **0 bytes** (post-fix).
  **Pre-fix, same command**: stdout unchanged, stderr **1424 bytes**
  (`Cannot index into a null array. ... extract-decide.ps1:125 ... $c = ConvertTo-UtcSecond $Current[$i]`)
  — non-zero, confirming this half discriminates.
- Two objects, no `-CurrentLastAltered`: `-Name two_object -CurrentRows 100,200` →
  `SKIPPED (source unchanged)`, stderr **0 bytes** (post-fix). Not tested pre-fix — the spec states,
  and this session confirms by construction, that the placeholder survives at N≥2 so the unfixed
  code is already clean there; a stderr comparison at two objects would not discriminate.
- **Note on the spec's literal AC4 wording**: passing `-CurrentLastAltered <same-value>` alongside
  `-CurrentRows` does **not** reach the buggy placeholder branch at all (the branch only fires when
  `-CurrentLastAltered` is *absent*, forcing the placeholder). Confirmed empirically: the same
  `c_unchanged` call *with* `-CurrentLastAltered` supplied gave 0 bytes stderr both pre- and
  post-fix. The single-object case that actually discriminates omits `-CurrentLastAltered`
  entirely, matching the mechanism described in TASK.md's D2 section ("stage 2 is reached... via
  the placeholder"). Both single-object stderr byte counts above use that form.

Anti-suppression, by count:
```
> Select-String -Path tools\extract-decide.ps1 -Pattern '2>\$null'
tools\extract-decide.ps1:205:$csvLines = & duckdb -csv -f $registrySql 2>$null   (count: 1)
SilentlyContinue: count 0
ErrorActionPreference: count 0
```
(Line 205, not the spec's stated 165 — the file has grown since the spec's own line-numbered
measurement against `337b29d`; it is still the single `& duckdb` call site.)

### AC5 — no evidence is bounded — PASS

Ages tree freshly regenerated:
```
> extract-decide.ps1 -Name minus1500 -ExtractRoot <abs>\ages -CurrentRows null
REFRESH (no evidence past ceiling)
> extract-decide.ps1 -Name minus90 -ExtractRoot <abs>\ages -CurrentRows null
SKIPPED (no evidence) age=92
```

### AC6 — control, must pass before and after — PASS

`minus1500`'s baseline `source_rows[0]` read from its sidecar = `30`:
```
> extract-decide.ps1 -Name minus1500 -ExtractRoot <abs>\ages -CurrentRows 30
SKIPPED (source unchanged)
```

### AC7 — the ceiling is the bound, not a constant — PASS

`minus90`, identical command, both directions:
```
$env:DSK_MAX_AGE_MINUTES='1440'; extract-decide.ps1 -Name minus90 -CurrentRows null -> SKIPPED (no evidence) age=93
$env:DSK_MAX_AGE_MINUTES='60';   extract-decide.ps1 -Name minus90 -CurrentRows null -> REFRESH (no evidence past ceiling)
```

### AC8 — usage errors survive — PASS, all 3 cases

Against `two_object`:
```
-CurrentRows 100,200,300 -> expected 2 values for 2 source objects, got 3        exit=2
-CurrentRows 100         -> expected 2 values for 2 source objects, got 1        exit=2
-CurrentRows "100,"      -> invalid -CurrentRows value '': expected an integer or the literal 'null'   exit=2
```
The third case is the empty-element rule: `"100,"` splits/trims to `["100",""]`, length 2 (matches
the object count, so the length check does not fire first), then the empty string fails the
integer/`null` check and exits 2 — never silently treated as the literal `null`.

### AC9 — element parsing is unchanged — PASS

```
-CurrentRows "100,abc"    -> invalid -CurrentRows value 'abc': expected an integer or the literal 'null'   exit=2
-CurrentRows "null,NULL"  -> SKIPPED (no evidence) age=93   exit=0
```

### AC10 — `-CurrentLastAltered` gets the same treatment — PASS

```
> extract-decide.ps1 -Name two_object -CurrentRows 100,200 -CurrentLastAltered "2026-09-28T18:04:06Z,2026-09-28T20:00:00Z"
SKIPPED (ambiguous: last_altered moved, rows unchanged) age=93
```

### AC11 — no regression on the shipped single-object fixtures — PASS, all 14 rows

Decide tree freshly regenerated; every row from `RESULT-1.md:205-220` (item 2b) re-run with the
same baseline `<same>` = `2026-09-28T18:04:06Z` and `<moved>` = `2026-09-29T12:00:00Z`:

| row | expected token | actual output | exit |
|---|---|---|---|
| a | `FRESH` | `FRESH` | 0 |
| b | `REFRESH (stale, source moved)` | `REFRESH (stale, source moved)` | 0 |
| c | `SKIPPED (source unchanged)` | `SKIPPED (source unchanged)` | 0 |
| d | `SKIPPED (ambiguous: ...) age=<n>` | `SKIPPED (ambiguous: last_altered moved, rows unchanged) age=94` | 0 |
| e | `REFRESH (ambiguous past ceiling)` | `REFRESH (ambiguous past ceiling)` | 0 |
| f | `REFRESH (forced)` | `REFRESH (forced)` | 0 |
| g | `SKIPPED (source unchanged)` | `SKIPPED (source unchanged)` | 0 |
| h | `SKIPPED (ambiguous: ...) age=<n>` | `SKIPPED (ambiguous: last_altered moved, rows unchanged) age=95` | 0 |
| i | `STALE (probe required) age=<n> window=<w> objects=<list>` | `STALE (probe required) age=95 window=60 objects=DB.SCH.A` | 0 |
| j | `REFRESH (clock skew) age=<n>` | `REFRESH (clock skew) age=-40` | 0 |
| k | `REFRESH (stale, source moved)` | `REFRESH (stale, source moved)` | 0 |
| l | `REFRESH (no sidecar)` | `REFRESH (no sidecar)` | 0 |
| m | `SKIPPED (source unchanged)` | `SKIPPED (source unchanged)` | 0 |
| n | `REFRESH (malformed sidecar: name mismatch)` | `REFRESH (malformed sidecar: name mismatch)` | 0 |

All 14 verdict tokens match exactly. Rows `g` and `m` both fell through to stage 2 (rather than the
new both-abstain branch), exactly as the spec requires. All ages within ±3 of item 2b's own
recorded nominal values.

`ages` tree snapshot (no recorded per-verdict baseline — drift to quote, not a failure):
```
ac6_far_window    : STALE (probe required) age=95 window=60 objects=DB.SCH.AC6_FAR_WINDOW
ac6_short_window  : STALE (probe required) age=95 window=60 objects=DB.SCH.AC6_SHORT_WINDOW
dt_projects       : FRESH
minus1500         : STALE (probe required) age=1505 window=60 objects=DB.SCH.MINUS1500
minus90           : STALE (probe required) age=95 window=60 objects=DB.SCH.MINUS90
now               : FRESH
parent_projects   : STALE (probe required) age=95 window=60 objects=DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS
size_mismatch     : FRESH
```

### AC12 — the other extract tools still work — PASS

```
> tools\extract-status.ps1 -Name minus90 -ExtractRoot <abs>\ages
95
> tools\list-extracts.ps1 -ExtractRoot <abs>\ages
name=now age_minutes=5 row_count=10 size_bytes=2819 bytes_check=AGREES
...
total_size_bytes=1276957
> tools\publish-extract.ps1 -Name nonexistent_ac12_check -StagingDir C:\nonexistent-staging-dir -SidecarPath C:\nonexistent-sidecar.json -ExtractRoot <abs>\ages
-StagingDir does not exist: C:\nonexistent-staging-dir
exit=2
```
`dsk-paths.ps1` was not touched this round, so re-running all five tools was not strictly required
by that rule, but `extract-status.ps1`/`list-extracts.ps1`/`publish-extract.ps1` were run anyway as
AC12 itself requires.

### AC13 — the header contract matches the code — PASS, 13-row table

| verdict | tree | fixture | command (abbreviated) | actual output |
|---|---|---|---|---|
| `FRESH` | decide | `a_fresh` | `-Name a_fresh` | `FRESH` |
| `STALE (probe required) age=<n> window=<w> objects=<list>` | decide | `i_probe` | `-Name i_probe` | `STALE (probe required) age=95 window=60 objects=DB.SCH.A` |
| `REFRESH (stale, source moved)` | decide | `b_moved` | `-Name b_moved -CurrentRows 101 -CurrentLastAltered <moved>` | `REFRESH (stale, source moved)` |
| `SKIPPED (source unchanged)` | decide | `c_unchanged` | `-Name c_unchanged -CurrentRows 100 -CurrentLastAltered <same>` | `SKIPPED (source unchanged)` |
| `SKIPPED (ambiguous: ...) age=<n>` | decide | `d_ambiguous` | `-Name d_ambiguous -CurrentRows 100 -CurrentLastAltered <moved>` | `SKIPPED (ambiguous: last_altered moved, rows unchanged) age=94` |
| `REFRESH (ambiguous past ceiling)` | decide | `e_past_ceiling` | `-Name e_past_ceiling -CurrentRows 100 -CurrentLastAltered <moved>` | `REFRESH (ambiguous past ceiling)` |
| `SKIPPED (no evidence) age=<n>` | ages | `minus90` | `-Name minus90 -CurrentRows null` | `SKIPPED (no evidence) age=92` |
| `REFRESH (no evidence past ceiling)` | ages | `minus1500` | `-Name minus1500 -CurrentRows null` | `REFRESH (no evidence past ceiling)` |
| `REFRESH (clock skew) age=<n>` | decide | `j_clock_skew` | `-Name j_clock_skew -CurrentRows 100 -CurrentLastAltered <same>` | `REFRESH (clock skew) age=-40` |
| `REFRESH (forced)` | decide | `f_forced` | `DSK_FORCE=1; -Name f_forced` | `REFRESH (forced)` |
| `REFRESH (no sidecar)` | decide | `l_absent` | `-Name l_absent` (directory never created) | `REFRESH (no sidecar)` |
| `REFRESH (unreadable sidecar)` | **damaged** | `bad_json` | `-Name bad_json` | `REFRESH (unreadable sidecar)` |
| `REFRESH (malformed sidecar: <reason>)` | **damaged** | `array_mismatch` | `-Name array_mismatch -CurrentRows 100` | `REFRESH (malformed sidecar: parallel array mismatch)` |

`REFRESH (unreadable sidecar)` and `REFRESH (malformed sidecar: ...)` come from the `damaged` tree
(`tools\make-extract-fixtures.ps1`'s own fixtures), named explicitly per the spec's note. (The
decide tree's own `n_malformed` fixture also produces the malformed-sidecar verdict, with reason
`name mismatch` rather than `parallel array mismatch`; either satisfies the verdict row — this
table uses `array_mismatch` since it demonstrates the length-guard finding from "A load-bearing
constraint" section directly.)

### AC14 — no BOM — PASS, all 3 changed files

```
tools\extract-decide.ps1          : 60,35,13   (not 239,187,191)
tools\make-decide-fixtures.ps1    : 60,35,13   (not 239,187,191)
skills\snowflake-extract\SKILL.md : 45,45,45   (not 239,187,191)
```

---

## Mutation proof — all 5, each failing then passing after revert

1. **Remove the comma-splitting** (drop `$CurrentRows = @(Split-CommaJoined $CurrentRows)`):
   `-CurrentRows 100,200` against `two_object` → `expected 2 values for 2 source objects, got 1`,
   exit 2 (AC1 fails). Reverted → `SKIPPED (source unchanged)`, exit 0 (AC1 passes again).
2. **Map both-abstain back to `SKIPPED (source unchanged)`**: AC2's `[null,null]` row on
   `two_object` → `SKIPPED (source unchanged)` (wrong; fails). AC5's `minus1500` →
   `SKIPPED (source unchanged)` instead of `REFRESH (no evidence past ceiling)` (fails). Reverted →
   `SKIPPED (no evidence) age=100` and `REFRESH (no evidence past ceiling)` respectively (both pass).
3. **Drop the ceiling check from the no-evidence branch**: `minus1500` + `-CurrentRows null` →
   `SKIPPED (no evidence) age=1509` instead of `REFRESH (no evidence past ceiling)` (AC5 fails).
   `minus90` + `DSK_MAX_AGE_MINUTES=60` → `SKIPPED (no evidence) age=99` instead of
   `REFRESH (no evidence past ceiling)` (AC7's 60-direction fails). Reverted → both directions
   correct again.
4. **Retype the placeholder as `[string[]]::new(N)` instead of forcing array semantics**: single
   object, `-Name c_unchanged -CurrentRows 100` (no `-CurrentLastAltered`) → stdout unchanged
   (`SKIPPED (source unchanged)`) but stderr **1380 bytes**, reproducing the exact `Cannot index
   into a null array` error (AC4's single-object half fails). Reverted → stderr 0 bytes again. This
   confirms the fix addresses the real mechanism (array-semantics unrolling), not the misdiagnosed
   one (placeholder type).
5. **Suppress with a second `2>$null` instead of guarding**: added `2>$null` to the
   `Test-LastAlteredStage` call alongside reintroducing the retyped placeholder. Result: stderr byte
   count alone reads 0 (would falsely appear to pass), but `Select-String` on `2>\$null` now counts
   **2**, not the required 1 (AC4's count assertion fails). Reverted → count back to 1, byte count
   still 0 by the real fix.

After all five mutation round-trips, `git diff --stat tools/extract-decide.ps1` against the commit
matched exactly (no residual mutation left in place), confirmed before committing.

---

## Summary

| Check | Result |
|---|---|
| AC1 | PASS |
| AC2 | PASS (all 10 rows) |
| AC3 | PASS |
| AC4 | PASS |
| AC5 | PASS |
| AC6 | PASS |
| AC7 | PASS |
| AC8 | PASS |
| AC9 | PASS |
| AC10 | PASS |
| AC11 | PASS (all 14 baseline rows reproduced exactly, plus ages snapshot) |
| AC12 | PASS |
| AC13 | PASS (13-row table) |
| AC14 | PASS |
| Mutation 1–5 | PASS (all fail-then-pass both directions) |

**All 14 acceptance checks pass. All five mutation proofs behave both directions.**

## Commit

- `43e2c40` — the bulk of the work (inherited + this session's SKILL.md addition).
- `4d41739` — follow-up: documents the parallel-array length guard in the header (see "Found wrong
  in the inherited work" above). Pushed as a second commit rather than amending `43e2c40`, since
  `43e2c40` had already been pushed before the gap was found.

Both commits pushed to `origin/item2c-multi-object-debt`.

## Not done

Nothing in the spec's deliverables or acceptance checks was skipped.

## Concerns / disagreements with the spec

- **AC4's literal wording is slightly imprecise about which single-object call discriminates.**
  The spec's own "Measured facts" section (D2) is explicit that the bug fires "only when stage 2 is
  reached... via the placeholder" — i.e. only when `-CurrentLastAltered` is *absent*. But AC4's
  checklist entry says "single object: `-Name c_unchanged -ExtractRoot <abs> -CurrentRows 100`" —
  which happens to already omit `-CurrentLastAltered`, so the literal command is correct, but a
  reader skimming only the AC4 bullet (without cross-referencing the D2 section) could easily add
  `-CurrentLastAltered <same>` "for completeness" and get a false-clean 0-byte result even on the
  unfixed script, since supplying `-CurrentLastAltered` explicitly bypasses the placeholder branch
  entirely. Not a defect in the delivered fix — the AC4 command as literally written does
  discriminate — but worth flagging since it is easy to accidentally test around the bug. I noted
  this explicitly in AC4 above rather than silently using the discriminating form without comment.
- No disagreement with any deliverable, verdict wording, or acceptance-check target. The one
  substantive gap found (missing header documentation of the parallel-array guard) is exactly what
  the handoff asked me to check for, and is fixed and reported above rather than silently patched.
