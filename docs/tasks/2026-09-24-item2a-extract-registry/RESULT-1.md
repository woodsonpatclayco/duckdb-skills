# RESULT — item 2a: extract sidecar schema, registry, and freshness tools

**Serves:** Being able to ask "what Snowflake data do I already have locally, and how old is
it?" and get a truthful answer from one command. This delivers the read half of the extract
system (sidecar schema + registry + freshness) that item 2b's write half will produce data for.

Commit: `1612b89` on branch `item2a-extract-registry` (worktree HEAD before this file was
`263febe`). This file's own commit follows below.

All twelve acceptance checks pass. Every check was run with a fresh
`tools\make-extract-fixtures.ps1 -Root .duckdb-skills\fixtures` immediately before it, exactly as
the spec requires, so the numbers below are reproducible from a clean fixture tree, not from
whatever state happened to exist earlier in the session.

---

## Files changed

| File | What / why |
|---|---|
| `skills/snowflake-extract/SIDECAR.md` | New. The 14-row sidecar schema contract (17 underlying fields — the `connection`/`role`/`database`/`warehouse` row bundles four), the pinned-type/age-formula matched pair, the freshness rule, and the malformed-sidecar reason vocabulary. |
| `skills/snowflake-extract/registry.sql` | New. Reads exactly one extract's `_extract.json` per invocation (`duckdb -csv -f`), pins all 17 sidecar fields via `read_json(..., columns={...})`, computes `age_minutes`, `reason` (name mismatch / parallel array mismatch), `stale`, and `past_ceiling` per the guarded formulas in SIDECAR.md. |
| `tools\list-extracts.ps1` | New. Enumerates `-ExtractRoot` with `Get-ChildItem -Directory`, invokes `registry.sql` once per directory, prints every extract newest-first with age/row_count/size/an output_bytes-vs-disk check, plus a total. No verdict column (by design — see Deviations). |
| `tools\extract-status.ps1` | New. Same per-directory read, but for one named extract (or every extract, sorted by directory, if `-Name` omitted): first line is the bare age in minutes, then window/verdict/size. |
| `tools\make-extract-fixtures.ps1` | New. Regenerates `<Root>\ages`, `<Root>\damaged`, `<Root>\empty` from scratch every run; deletes `<Root>\absent` if present and never recreates it. All stamps from `[DateTime]::UtcNow`. Test scaffolding, not a plan deliverable. |
| `README.md` | Edited. Added the state-file precedence decision to the existing "Session state" section (paragraph immediately after the `read-memories` note) — project-local wins, with the reason and the deliberate, unresolved contradiction with `skills/query/SKILL.md:22-25` stated explicitly. No resolution code touched anywhere. |

---

## Acceptance checks

Every command below was run against `.duckdb-skills\fixtures` (gitignored, regenerated fresh
immediately before each check). Full raw session log matches what's excerpted here.

### AC1 — `<project-id>` resolves legally — **PASS**

```
> tools\make-extract-fixtures.ps1 -Root .duckdb-skills\fixtures
fixtures regenerated under C:\Users\woodsonp\Claude\Dev\duckdb-skills\.duckdb-skills\fixtures
> tools\list-extracts.ps1
project-id: c-users-woodsonp-claude-dev-duckdb-skills
extract root: C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts
no extracts registered under C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts
EXIT=0
```

Gate, checked programmatically against the printed id (not by re-deriving it from the tool):
non-empty ✓, no `:` ✓, no `\` or `/` ✓, `Test-Path` on the printed root succeeds after the run ✓.
The id matches the spec's stated snapshot for this worktree, quoted as a snapshot only — it is not
asserted as a fixed literal in the code.

### AC2 — zero extracts is not an error — **PASS**

```
> tools\make-extract-fixtures.ps1 -Root .duckdb-skills\fixtures
> tools\list-extracts.ps1  -ExtractRoot .duckdb-skills\fixtures\empty
no extracts registered under C:\...\fixtures\empty
EXIT=0
> tools\extract-status.ps1 -ExtractRoot .duckdb-skills\fixtures\absent
no extracts registered under C:\...\fixtures\absent
EXIT=0
```

Confirmed separately that `.duckdb-skills\fixtures\absent` does not exist after either run
(`Test-Path` → `False`) — the explicit `-ExtractRoot` was never created.

### AC3 — age is correct, and in UTC — **PASS**

```
> tools\make-extract-fixtures.ps1 -Root .duckdb-skills\fixtures
> tools\extract-status.ps1 -Name now -ExtractRoot .duckdb-skills\fixtures\ages
0
window: 60
verdict: FRESH
size: 2819 bytes
EXIT=0
literal materialized_at: 2026-09-23T23:40:09Z
local wall clock now: 2026-09-23T18:40:09

> tools\extract-status.ps1 -Name minus90 -ExtractRoot .duckdb-skills\fixtures\ages
90
window: 60
verdict: EXPIRED
size: 2831 bytes
EXIT=0
literal materialized_at: 2026-09-23T22:10:09Z
local wall clock now: 2026-09-23T18:40:09

> tools\extract-status.ps1 -Name minus1500 -ExtractRoot .duckdb-skills\fixtures\ages
1500
window: 60
verdict: EXPIRED PAST-CEILING
size: 2837 bytes
EXIT=0
literal materialized_at: 2026-09-22T22:40:09Z
local wall clock now: 2026-09-23T18:40:09
```

First lines: **0**, **90**, **1500** — all inside the required bands (0–2, 89–93, 1499–1503). The
~5-hour gap between each literal `materialized_at` and the local wall clock is visible above,
confirming the fixture is UTC-stamped, not local-stamped (machine is UTC−5).

Wrong-value table, for reference (not reproduced by this implementation — shown to make the check
self-explaining, as the spec asks):

| fixture | correct (measured above) | naive-local (`now()::TIMESTAMP`) | double-shift (`TIMESTAMPTZ` pin) |
|---|---|---|---|
| now | **0** | ≈ −299 | ≈ 301 |
| −90 | **90** | ≈ −209 | ≈ 390 |
| −1500 | **1500** | ≈ 1201 | ≈ 1800 |

None of the wrong-column values appear anywhere in this implementation's output.

### AC4 — verdict tracks the window — **PASS**

Verbatim output:

```
--- window=60, now ---
0
window: 60
verdict: FRESH
size: 2819 bytes
--- window=60, minus90 ---
90
window: 60
verdict: EXPIRED
size: 2831 bytes
--- window=1440, minus90 ---
90
window: 1440
verdict: FRESH
size: 2831 bytes
--- window=1440, minus1500 ---
1500
window: 1440
verdict: EXPIRED PAST-CEILING
size: 2837 bytes
```

(The `minus1500` line also carries `PAST-CEILING`, correctly and independently of AC4's own
assertion — the default ceiling is 1440 and age is 1500. This is expected, not a defect: AC4 only
greps for `FRESH`/`EXPIRED`, both present as required.)

### AC5 — unset window defaults to 60 and says so — **PASS**

```
Remove-Item Env:\DSK_WINDOW_MINUTES
> tools\extract-status.ps1 -Name minus90 -ExtractRoot .duckdb-skills\fixtures\ages
90
window: 60
verdict: EXPIRED
size: 2831 bytes
EXIT=0
```

No `Conversion Error`; window is reported as 60.

### AC6 — the reader's window governs, not `expires_at` and not the sidecar's own window — **PASS**

```
$env:DSK_WINDOW_MINUTES='60'
> tools\extract-status.ps1 -Name ac6_far_window -ExtractRoot .duckdb-skills\fixtures\ages
   (window_minutes=1440 in the sidecar, expires_at = +1 year)
90
window: 60
verdict: EXPIRED

$env:DSK_WINDOW_MINUTES='1440'
> tools\extract-status.ps1 -Name ac6_short_window -ExtractRoot .duckdb-skills\fixtures\ages
   (window_minutes=30 in the sidecar, expires_at = −1 year)
90
window: 1440
verdict: FRESH
```

**Both verdicts, exactly as required: `ac6_far_window` → `EXPIRED`; `ac6_short_window` →
`FRESH`.** Both fixtures are aged 90 minutes. If the implementation had consulted `expires_at`
(future for the first, past for the second) or the sidecar's own `window_minutes` (1440 vs. 30),
both verdicts would invert. Neither happened.

### AC7 — damaged sidecars are `UNKNOWN`, never `FRESH`, and never break the listing — **PASS**

Single `list-extracts.ps1` run over `fixtures\damaged` (8 directories: the 6 damaged cases below,
plus `healthy_a`/`healthy_b`), all six damaged cases reported in that one run, exit 0:

```
name=healthy_a age_minutes=10 row_count=7 size_bytes=2835 bytes_check=AGREES
name=healthy_b age_minutes=500 row_count=9 size_bytes=2835 bytes_check=AGREES
name=array_mismatch age_minutes=UNKNOWN (parallel array mismatch) row_count=5 size_bytes=2966 bytes_check=AGREES
name=bad_json age_minutes=UNKNOWN (unreadable sidecar) row_count=NULL size_bytes=2063 bytes_check=n/a
name=missing_materialized_at age_minutes=UNKNOWN row_count=5 size_bytes=2828 bytes_check=AGREES
name=name_mismatch age_minutes=UNKNOWN (name mismatch) row_count=5 size_bytes=2856 bytes_check=AGREES
name=no_sidecar age_minutes=UNKNOWN (no sidecar) row_count=NULL size_bytes=2048 bytes_check=n/a
name=unparseable_timestamp age_minutes=UNKNOWN (unreadable sidecar) row_count=NULL size_bytes=2860 bytes_check=n/a
total_size_bytes=21291
EXIT=0
```

**All six damaged lines, from that single run:**
1. `no_sidecar` → `UNKNOWN (no sidecar)`
2. `bad_json` → `UNKNOWN (unreadable sidecar)`
3. `missing_materialized_at` → `UNKNOWN` (bare)
4. `array_mismatch` → `UNKNOWN (parallel array mismatch)`
5. `unparseable_timestamp` → `UNKNOWN (unreadable sidecar)`
6. `name_mismatch` → `UNKNOWN (name mismatch)`

No line says `FRESH`. Re-run with `$env:DSK_WINDOW_MINUTES='999999'` over the same root produced
**identical** output (same 8 lines, same total, `EXIT=0`) — a huge window did not launder any
damaged sidecar into freshness. This is expected for `list-extracts.ps1` since it has no verdict
column at all (see Deviations); as supplementary, stronger evidence, `extract-status.ps1 -Name`
was also run for each of the six under both the default window and `DSK_WINDOW_MINUTES=999999`,
and all twelve reports came back `UNKNOWN` with the identical reason each time — this is the half
of the check where the window really could have laundered `array_mismatch` and `name_mismatch`
(both have a valid, non-null age), and it didn't:

```
default window                              window=999999
no_sidecar               → UNKNOWN (no sidecar)              → UNKNOWN (no sidecar)
bad_json                 → UNKNOWN (unreadable sidecar)       → UNKNOWN (unreadable sidecar)
missing_materialized_at  → UNKNOWN                            → UNKNOWN
array_mismatch            → UNKNOWN (parallel array mismatch)  → UNKNOWN (parallel array mismatch)
unparseable_timestamp    → UNKNOWN (unreadable sidecar)       → UNKNOWN (unreadable sidecar)
name_mismatch             → UNKNOWN (name mismatch)            → UNKNOWN (name mismatch)
```

**Discrepancy, reported as instructed rather than silently resolved:** the spec's own AC7 header
says "Six directories in `fixtures\damaged`, of which two are healthy" (implying 6 total) and later
"confirm the **four** damaged ones are still UNKNOWN" — but the same paragraph enumerates exactly
six numbered damaged cases. `REVIEW-task-1.md` records that cases 5 and 6 were added in the second
review pass ("Fifth and sixth damaged cases added"); both stale counts (six-total, four-damaged)
read as leftovers from before that addition that were never updated to eight-total/six-damaged. I
did not adjust the spec text or weaken the check — I built 8 directories (6 damaged + 2 healthy)
and verified all six damaged cases, per this task's explicit instruction to do so.

### AC8 — the registry lists, orders, and is derived not stored — **PASS**

```
> tools\list-extracts.ps1 -ExtractRoot .duckdb-skills\fixtures\ages
name=now age_minutes=0 row_count=10 size_bytes=2819 bytes_check=AGREES
name=size_mismatch age_minutes=10 row_count=1 size_bytes=380907 bytes_check=DISAGREES (declared 999999, on disk 380104)
name=dt_projects age_minutes=45 row_count=42161 size_bytes=500849 bytes_check=AGREES
name=ac6_far_window age_minutes=90 row_count=40 size_bytes=2854 bytes_check=AGREES
name=ac6_short_window age_minutes=90 row_count=50 size_bytes=2858 bytes_check=AGREES
name=minus90 age_minutes=90 row_count=20 size_bytes=2831 bytes_check=AGREES
name=parent_projects age_minutes=90 row_count=15314 size_bytes=381002 bytes_check=AGREES
name=minus1500 age_minutes=1500 row_count=30 size_bytes=2837 bytes_check=AGREES
total_size_bytes=1276957
```

Newest-first ordering holds throughout (0, 10, 45, 90, 90, 90, 90, 1500). `parent_projects` shows
`row_count=15314` and `dt_projects` shows `row_count=42161` — the two pinned figures from the real
extract cycle, so 2b's real output will be directly comparable.

```
--- delete parent_projects, re-run ---
name=now ... 
name=size_mismatch ...
name=dt_projects ...
name=ac6_far_window ...
name=ac6_short_window ...
name=minus90 ...
name=minus1500 ...
total_size_bytes=895955
```

`parent_projects` is gone from the second run, and the total dropped by exactly its own
`size_bytes` (1276957 − 381002 = 895955) — the listing is derived from the filesystem on every
call, not cached.

### AC9 — the size report is self-checking and can fail — **PASS**

```
name=parent_projects age_minutes=90 row_count=15314 size_bytes=381002 bytes_check=AGREES
name=size_mismatch age_minutes=10 row_count=1 size_bytes=380907 bytes_check=DISAGREES (declared 999999, on disk 380104)
total_size_bytes=1276957
```

Independent disk check (not the tool's own arithmetic):

```
parent_projects parquet_bytes=380104 total_bytes=381002
size_mismatch    parquet_bytes=380104 total_bytes=380907
```

`parent_projects` declares `output_bytes=380104`; the on-disk `.parquet` sum is exactly 380104 →
`AGREES`. `size_mismatch` declares `output_bytes=999999` over a `.parquet` file of the *same* size
(380104) → `DISAGREES (declared 999999, on disk 380104)` — the literal text the spec requires,
produced from real byte counts, not hardcoded. `total_size_bytes=1276957` was independently checked
by summing the eight `size_bytes` values printed in the same run — they add up exactly.

### AC10 — the ceiling is reported, not acted on — **PASS**

```
DSK_MAX_AGE_MINUTES unset (default 1440)
> tools\extract-status.ps1 -Name minus90 -ExtractRoot .duckdb-skills\fixtures\ages
90 / verdict: EXPIRED                    (no PAST-CEILING)
> tools\extract-status.ps1 -Name minus1500 -ExtractRoot .duckdb-skills\fixtures\ages
1500 / verdict: EXPIRED PAST-CEILING     (suffix present)
```

Before/after snapshot of every fixture's `name=materialized_at` in `fixtures\ages`, taken
immediately before and after both `extract-status.ps1` calls, is byte-for-byte identical (`diff`
against the two snapshots is empty), and the directory listing is unchanged — confirms the reads
mutated nothing in the fixture tree.

### AC11 — `registry.sql` has no BOM — **PASS**

```
first three bytes: 45,45,32
```

(`--` `+` space — a SQL comment, not `239,187,191`.) The same check was also run against
`SIDECAR.md` and all three `.ps1` tools during development; all clean.

### AC12 — the schema contract matches the code — **PASS**

Point 1 — symmetric difference between `SIDECAR.md`'s parsed field names (17, since the
`connection`/`role`/`database`/`warehouse` row expands to four) and `DESCRIBE SELECT * FROM
read_json(<complete fixture>, columns={...})`'s 17 column names:

```
=== symmetric difference (SIDECAR.md only) ===
=== symmetric difference (DESCRIBE only) ===
```

Both empty, as required.

Point 2 — against `dt_projects` (the fixture that omits `runtime_seconds`):

```
runtime_seconds_is_null
true
EXIT=0
```

---

## The `SIDECAR.md` field table (final, as shipped)

| field | type | notes |
|---|---|---|
| `sidecar_version` | integer | value **`1`**. Without it a later schema change is undetectable and old sidecars are indistinguishable from new ones. |
| `name` | string | the identity, and **must equal the containing directory's name** — a mismatch is a malformed sidecar. Not the query text: whitespace or a changed `LIMIT` makes an identical result set look like a different query. |
| `query` | string | verbatim SQL. **Not the identity key** — that is `name`. But it **is** the input 2b re-executes on refresh, so it must round-trip byte-exact; do not normalise whitespace. |
| `source_objects` | array of string | fully-qualified |
| `materialized_at` | string | UTC, ISO 8601 with `Z`. **The extract's version token** — item 6's manifest records it beside the contract hash, closing the named risk that a lakehouse table has no tie to which extract version it used. |
| `window_minutes` | integer | writer's window, **provenance only** |
| `expires_at` | string | UTC, **provenance only** |
| `row_count` | integer | rows in the extract |
| `output_bytes` | integer | from `COPY INTO`'s result — the extract's own size |
| `connection`, `role`, `database`, `warehouse` | string | the same query under a different role returns different rows |
| `source_rows` | array of integer, **elements nullable** | `SHOW TABLES` rows per source object at materialize time — 2b's stage-1 baseline. A `null` element means no metadata row count was available (e.g. the object is a view); stage 1 cannot decide for it and 2b falls through to stage 2. **`null` is never `0`** — `0` reads as "the table emptied". A null element does not violate the parallel-array rule; a *missing* element does. |
| `source_bytes` | array of integer | **provenance only, never compared** — bytes move on refresh with unchanged content |
| `source_last_altered` | array of string | UTC ISO 8601 per source object — 2b's stage-2 baseline, compared against the *current* `LAST_ALTERED` and **never against `materialized_at`**, which on a dynamic table would make "unchanged" unreachable |
| `runtime_seconds` | number, **optional** | omitted rather than wrong. A negative value means `EXECUTION_STATUS = 'SUCCESS'` was not filtered and an in-flight query's elapsed time was recorded. |

(14 markdown rows, 17 fields — matches `registry.sql`'s `read_json(..., columns={...})` pin
exactly, verified by AC12.)

---

## Deviations from the spec, with reasons

- **`registry.sql`'s `SELECT` list carries more columns than the "Columns, pinned via `columns =
  {...}`" bullet names** (13 in the spec's bullet: `name, path, parquet_glob, query,
  source_objects, materialized_at, expires_at, row_count, role, database, warehouse, age_minutes,
  size_bytes`). My `registry.sql` also emits `output_bytes`, `connection`, `window_minutes`,
  `sidecar_version`, `source_rows`, `source_bytes`, `source_last_altered`, `runtime_seconds`,
  `reason`, `stale`, and `past_ceiling`. `output_bytes` is required by AC9's AGREES/DISAGREES
  check and `reason`/`stale`/`past_ceiling` are required by AC6/AC7/AC10 — none of these are
  optional given the acceptance checks, so I read the "Columns" bullet as describing the
  registry's *headline* display columns (which `list-extracts.ps1` prints, unchanged from that
  list except for the addition of the reason-aware age text and the bytes-check annotation) rather
  than a literal, closed CSV header for `registry.sql` itself. `size_bytes` specifically is
  **not** produced by `registry.sql` at all — it is computed in PowerShell via `Get-ChildItem
  -Recurse -File | Measure-Object -Sum Length`, per the spec's own recipe for it, since DuckDB has
  no portable "total bytes under this directory" primitive and the spec gives the PowerShell
  formula directly.
- **`list-extracts.ps1` has no FRESH/EXPIRED verdict column at all**, by design: the deliverable
  table splits "age and size" (list) from "age, verdict, and size" (status) explicitly, and the
  pinned registry columns list has no stale/verdict field. AC7's "never FRESH" is satisfied
  because the tool cannot print a verdict token to begin with; I ran the supplementary
  `extract-status.ps1 -Name` sweep over all six damaged cases under both the default and huge
  window (shown under AC7 above) as the stronger, falsifiable version of that same guarantee.
- **AC7's damaged-fixture count**: built 8 directories (6 damaged + 2 healthy) against the spec's
  inconsistent "six total" / "four damaged" wording — see the discrepancy note under AC7. Not a
  deviation from behavior, just from a number the spec's own text does not agree with itself on.
- **`extract-status.ps1` without `-Name`** prints one line per extract (`name=... age_minutes=...
  verdict=... size_bytes=...`) preceded by a single `window: N` line. This mode is exercised only
  by AC7's supplementary sweep and AC2's zero-extract guard in this task; its exact line format
  isn't pinned by any acceptance check, so I chose something legible and consistent with
  `list-extracts.ps1`'s format rather than inventing a second one.

## Not done / not applicable

Nothing in the spec's scope was left undone. Everything explicitly out of scope (2b's write path,
`COPY INTO`/`GET`/`REMOVE`, `SKILL.md`, deletion/retention, `state.sql` resolution changes, the
`snowflake` DuckDB extension, any Snowflake connection) was correctly not touched — confirmed by
`git status` showing only the six files listed under "Files changed" above.
