# SHIPPED — Item 2b, materialize / publish / refresh. Track A complete.

Plan: `PLAN-4.md` item 2, second of two specs. Branch `item2b-snowflake-extract`. Verified SHIP by
`VERIFY-2.md` after two rounds. **Item 2 is now complete and Track A is done** — items 3–8 remain.

## What shipped

| Path | What it is |
|---|---|
| `tools\dsk-paths.ps1` | the single definition of `<project-id>` and extract-root resolution |
| `tools\extract-decide.ps1` | the freshness / two-stage decision, eleven verdicts, no Snowflake path |
| `tools\publish-extract.ps1` | writes the sidecar, publishes rename-aside |
| `tools\make-decide-fixtures.ps1` | fixtures for the decision table |
| `skills/snowflake-extract/SKILL.md` | the agent flow, including the TZ projection step |
| `tools\list-extracts.ps1`, `tools\extract-status.ps1` | *(edited)* dot-source `dsk-paths.ps1`, and the CSV-parse fix |

## The point of it, in one before/after

Before: a Snowflake result existed only inside a conversation. Asking a follow-up meant re-reading it
from context or re-running the query against a warehouse, and it could never be joined to a spreadsheet.

After, two real extracts on local disk:

```powershell
cd C:\Users\woodsonp\Claude\Dev\duckdb-skills
tools\list-extracts.ps1
```

```
name=parent_projects age_minutes=22 row_count=15314 size_bytes=518925  bytes_check=AGREES
name=dt_projects     age_minutes=30 row_count=42167 size_bytes=5223915 bytes_check=AGREES
```

Then query either by name with **no Snowflake call**:

```powershell
duckdb -csv -c "SELECT count(*) FROM 'C:/Users/woodsonp/.duckdb-skills/c-users-woodsonp-claude-dev-duckdb-skills/extracts/dt_projects/*.parquet'"
```

→ `42167`, in well under a second, against 107 columns of real project data.

## What the two rounds actually bought

**Round 1's blocker was the valuable part.** `COPY INTO ... FILE_FORMAT=(TYPE=PARQUET)` **refuses to
unload `TIMESTAMP_TZ` or `TIMESTAMP_LTZ`**:

```
Error encountered when unloading to PARQUET: TIMESTAMP_TZ and LTZ types are not
supported for unloading to Parquet. value get: TIMESTAMP_LTZ
```

So an extract query cannot be a blind `SELECT *`. Blast radius measured: **4 of 197 tables (2.0%)** in
`SCH_PROJECT_OPERATIONS`, 10 columns — and it is not rare by accident, because `CURRENT_TIMESTAMP()`
returns `TIMESTAMP_LTZ(9)`, so any audit-stamped table can carry one. The fix projects **only** the TZ
columns as `CONVERT_TIMEZONE('UTC', "<col>")::TIMESTAMP_NTZ AS "<col>"` and leaves everything else alone.

**Proved lossless by an independent path, not by assertion.** Snowflake
`DATE_PART(EPOCH_SECOND, START_DATE)` gave `1567746000 / 1459746000 / 1739426400`; DuckDB `epoch()` on
the landed Parquet gave the same three. The round-1 draft of that check compared `CONVERT_TIMEZONE`
against `CONVERT_TIMEZONE` — it would have passed on a value six hours out.

**Four traps closed, each of which would have produced a confident wrong answer:**

- **`Move-Item` onto an existing directory does not replace — it nests.** The stale Parquet stays put,
  the fresh copy lands in a subdirectory, and `<dir>\*.parquet` reads the **old data at exit 0**. Publish
  is rename-aside with `[IO.Directory]::Move`. Verified twice by mutation: collapsed to `Move-Item`, AC1
  fails; changed to delete-then-move, AC1 still passes but **AC2 loses the extract entirely**.
- **A multi-line `query` corrupted both shipped 2a readers** — `ConvertFrom-Csv` over a line array treats
  each element as a record, so a valid sidecar read as `UNKNOWN` with a blank first line. Latent in
  shipped code; 2b writes the first sidecars that trigger it, and a 107-column projection is 3,074 chars
  across many lines.
- **`[int[]]` coerces `$null` to `0`** in PowerShell, which would have meant "the table emptied" on any
  view and forced spurious refreshes. Current row counts are strings with a literal `null` token.
- **An in-flight query reports `TOTAL_ELAPSED_TIME = -1790201630243`.** `runtime_seconds` filters
  `EXECUTION_STATUS = 'SUCCESS'` or omits the field.

**Checking is genuinely free.** `extract-decide.ps1` answers `FRESH` with **no Snowflake call at all** —
confirmed structurally, its only external call is `& duckdb`. It emits `STALE (probe required)` naming the
objects to probe, and only then does the agent touch Snowflake. When it does, stage 1 is metadata-only:
`QUERY_TYPE = SHOW`, `WAREHOUSE_SIZE` empty, `BYTES_SCANNED` = 0.

## What deliberately did NOT change

- **`SIDECAR.md` and `registry.sql` are untouched** — proven by diff across both rounds. They are the
  frozen interface items 6 and 8 build against.
- **`path` and `parquet_glob` are registry output columns, not sidecar fields.** Do not "add the missing
  fields".
- **`source_bytes` is provenance and must never be compared.** Measured three times: rows held while
  bytes moved (`DT_PROJECTS` 7,463,424 → 7,430,144 → 7,437,824; `DT_PARENT_PROJECTS` 1,037,312 →
  1,041,408 with rows unchanged). Stage 1 compares **rows only**. Adding bytes back would refresh on
  nearly every read and destroy the saving.
- **The ambiguous SKIP is deliberate, and bounded.** `LAST_ALTERED` advances on every dynamic-table
  refresh regardless of content, so treating it as a change would refresh constantly.
  `DYNAMIC_TABLE_REFRESH_HISTORY` is **not authorized** for this role, so there is no better signal. The
  accepted miss — an in-place UPDATE preserving the row count — is bounded by `DSK_MAX_AGE_MINUTES`
  (1440), not left forever.
- **2a's verdict vocabulary is unchanged.** 2a reports *state* (`FRESH`/`EXPIRED`/`UNKNOWN`); 2b decides
  an *action* (`FRESH`/`REFRESH`/`SKIPPED`/`STALE`). `EXPIRED` has no 2b counterpart. **Do not
  "harmonise" them.**
- **No retention or cleanup** beyond `<live>.old` on a successful publish and the stage copy after `GET`.
  Growth is visible via the size report; acting on it stays manual.
- **No per-session refresh cap.** The window is the only throttle.
- **The `snowflake` DuckDB extension is still never loaded.**
- **The `state.sql` contradiction still stands on purpose** — `README.md` records project-local wins,
  `skills/query/SKILL.md:22-25` still prefers home-side. That bash does not run on Windows. Do not
  reconcile them.

## Known gap, recorded not closed

**Multi-object extracts are unverified.** Every `extract-decide.ps1` fixture has exactly one
`source_objects` entry, so the multi-object stage-1/stage-2 rule — and round 1's
`@(… | ConvertFrom-Json)` double-nesting fix — have no passing evidence. The nesting bug was invisible to
single-object fixtures because `.Count` reads as 1 either way. Deferred deliberately; the first
multi-object extract should be treated as untested ground.

## Two facts about the tooling, learned the hard way

- **`snowflake_object_search`'s index is stale.** It reported `DT_PROJECTS` as 113 columns; it has
  **107**, confirmed twice against `INFORMATION_SCHEMA.COLUMNS` with contiguous ordinals 1–107. Fine for
  discovery, not for a figure a check depends on.
- **The `verifier` agent has no Snowflake access; the `implementer` does.** Both rounds confirmed it. So
  a `[skill]` check can never be certified by the verifier — the main session must re-run those itself,
  which is why `VERIFY-1.md` and `VERIFY-2.md` each carry a Part B.

## Process note

Round 1 passed 16 of 17 checks and was still incomplete, because the seventeenth exposed a platform
limitation the spec had assumed away. The spec was wrong, not the implementation — and the implementer
stopped and asked rather than casting columns to make it pass. That was the right call, and it is why
round 2 was a paragraph of prose and three checks rather than a redesign.
