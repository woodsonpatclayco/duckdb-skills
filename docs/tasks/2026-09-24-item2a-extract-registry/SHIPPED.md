# SHIPPED — Item 2a, the extract registry and freshness tools

Plan: `PLAN-3.md` item 2, first of two specs. Branch `item2a-extract-registry`. Verified SHIP by
`VERIFY-1.md`, round 1 — no correction round.

## What shipped

| Path | What it is |
|---|---|
| `skills/snowflake-extract/SIDECAR.md` | the sidecar schema contract, 17 fields |
| `skills/snowflake-extract/registry.sql` | per-extract `read_json`, run with `duckdb -f` |
| `tools\list-extracts.ps1` | all extracts, newest first, age + size + total |
| `tools\extract-status.ps1` | one extract's age, verdict, size |
| `tools\make-extract-fixtures.ps1` | regenerates the fixture tree |
| `README.md` | state-file precedence decision recorded in "Session state" |

## The point of it, in one before/after

Before: nothing knew what Snowflake data was already on disk, or how old it was.

After, two commands:

```powershell
cd C:\Users\woodsonp\Claude\Dev\duckdb-skills
tools\make-extract-fixtures.ps1 -Root .duckdb-skills\fixtures
tools\list-extracts.ps1 -ExtractRoot .duckdb-skills\fixtures\ages
tools\extract-status.ps1 -Name minus90 -ExtractRoot .duckdb-skills\fixtures\ages
```

The first lists every extract newest-first with age, row count and size plus a total; the second prints
`90` as its first line, then the window used and the verdict. Both work against generated fixtures, so
there is nothing to set up and no Snowflake involved.

## What this round actually bought

**A freshness checker that isn't five hours wrong.** DuckDB's `read_json` infers an ISO-8601 `Z`
timestamp as a *naive local* value and discards the offset. There are two ways to get this wrong and
they fail in opposite directions:

| form | age reported for a 90-minute-old extract |
|---|---|
| **correct** — pin `TIMESTAMP`, `date_diff(..., timezone('UTC', now()))` | **90** |
| naive local — `now()::TIMESTAMP` | **−210** |
| double shift — pin `TIMESTAMPTZ`, same formula | **390** |

The verifier mutated the shipped SQL into both wrong forms and confirmed the acceptance check catches
each. That is the difference between a check and a decoration.

**A registry that survives a damaged sidecar.** One malformed `_extract.json` makes a glob over all
sidecars exit 1 and take the whole listing with it, and `ignore_errors=true` is **refused** by DuckDB
for non-newline-delimited JSON. So enumeration is `Get-ChildItem -Directory` with a **separate
`duckdb -f` per extract**. Proved behaviourally: a bare glob dies on the same fixture set the tool
handles cleanly at exit 0.

**Three traps closed that would each have produced a confident wrong answer:**

- `NULL > 60` is **NULL**, not `true` — so a naive filter reports a damaged sidecar as *not stale*.
  Every comparison is `coalesce(..., true)`. A window of 999,999 was tested and cannot launder a
  damaged sidecar into `FRESH`.
- `glob('<root>/*')` returns **0** — it matches files, not directories — so an extract directory with
  no sidecar is invisible to any glob-based registry.
- `list-extracts.ps1` initially leaked `$LASTEXITCODE` from the last `duckdb` subprocess, so the whole
  run reported failure whenever the last directory enumerated happened to be a damaged one. Found by
  the implementer, fix verified with a damaged directory deliberately sorted last.

## What deliberately did NOT change

- **None of item 2b exists.** No `COPY INTO`, `GET`, `REMOVE`, no materialize, no refresh, no
  two-stage invalidation, no `DSK_FORCE`, and **no `SKILL.md`** — the new skill's frontmatter and its
  description budget belong to 2b. The registry-first instruction, with its unenforceability caveat, is
  2b's too.
- **`path` and `parquet_glob` are deliberately NOT sidecar fields.** They are `registry.sql`'s computed
  output columns. Items 2b, 6 and 8 consume them from the registry, not from the JSON. Do not "add the
  missing fields" to `SIDECAR.md`.
- **`source_bytes` is provenance and must never be compared.** `DT_PROJECTS` held 42,161 rows while its
  bytes moved 7,463,424 → 7,430,144 in nine minutes, because dynamic-table refresh reorganises
  micro-partitions. 2b's stage-1 check compares **rows only**. Adding bytes back would trigger a
  warehouse pull on nearly every read.
- **No resolution code changed anywhere.** `git diff 263febe 8549e42 -- tools/ensure-duckdb-compat.ps1
  skills/query/SKILL.md` is empty, and `tools\run-compat-tests.ps1` still exits 0 with
  `REGRESSION: none`, so item 1 is unharmed.
- **The `state.sql` contradiction is left standing on purpose.** `README.md` records that project-local
  wins; `skills/query/SKILL.md:22-25` still prefers home-side. That bash does not run on Windows, so
  the practical effect is nil. **Do not "reconcile" them** — doing so silently changes where macros
  land.
- **No deletion or retention.** The size report makes growth visible; acting on it stays manual.
- **The `snowflake` DuckDB extension is still never loaded.**

## Known defect in the spec's own text

`TASK.md`'s AC7 says "six directories … of which **two are healthy**" and then "confirm the **four**
damaged ones", while listing **six** numbered damaged cases between those sentences. Both counts are
leftovers from before cases 5 and 6 were added in the second review pass.

**Not a coverage gap** — 8 directories were built (6 damaged + 2 healthy) and all six damaged cases were
verified in one run. `TASK.md` was frozen by `RESULT-1.md`, so the text is left as written and the error
is recorded here instead of edited in place.

## A trap worth carrying forward

PowerShell's `cd` updates `$PWD` but **not** .NET's `Environment.CurrentDirectory`. Any tool resolving a
relative path with `[System.IO.Path]::GetFullPath()` will resolve against the .NET value and can write
somewhere unexpected. It bit the verifier mid-run. Pin
`[System.IO.Directory]::SetCurrentDirectory((Get-Location).Path)` or pass absolute paths.

## Process note

This shipped in one round. The reason is that the previous item's review pass forced the spec to define
five things it had left open — the pinned-type/formula pair, the verdict vocabulary, exit codes, the
schema contract, and how fixtures come into existence — before an implementer saw it. Two review passes
on the spec cost less than the one correction round they replaced.
