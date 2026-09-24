# TASK — Materialize, publish, and refresh extracts (item 2b)

Plan: PLAN-4.md (item 2, second of two specs)

> **Round 2 is open.** The `Plan:` header moved from `PLAN-3.md` to `PLAN-4.md` because round 1 found a
> platform limitation the plan did not know about. Read `# CORRECTIONS — round 2` at the bottom; where it
> conflicts with the body above, **the corrections win.** The body is left unedited on purpose —
> `RESULT-1.md` was written against it.

**Serves:** Actually getting Snowflake data onto local disk once and reusing it. Item 2a shipped the
half that *reads* sidecars — the registry and freshness tools. This is the half that *writes* them: a
named query lands as Parquet, carries a sidecar describing itself, and re-pulls itself when stale
without asking. After this, Track A is complete and item 8's cross-source join becomes possible.

Depends on item 1 and item 2a, both shipped. `skills/snowflake-extract/SIDECAR.md` is the frozen
contract this spec must populate; `registry.sql` reads it back.

*Round 1, revised after `REVIEW-task-1.md`. Every figure below was measured in-session.*

**Environment:** Windows, PowerShell 5.1. Chain with `;` never `&&`. Absolute paths. Dot-source with
`. (Join-Path $PSScriptRoot 'dsk-paths.ps1')`, never a relative `. .\dsk-paths.ps1`.

---

## The architecture, and why it is not "the agent does everything"

`COPY INTO`, `GET`, `REMOVE` and `SHOW TABLES` run through `snowflake_sql_execute`, an **agent tool** no
script can call. The naive conclusion is that all of 2b is agent-driven prose demonstrated only by skill
invocation — and that is how item 2's first draft was written, and it is wrong. It puts the two most
dangerous steps beyond the reach of any check Phil can run.

So the split is drawn tighter: **every decision and every filesystem mutation is a script; the agent
only moves bytes and feeds values in.**

| step | who | testable without Snowflake? |
|---|---|---|
| read baselines, unload, download, clean the stage, look up runtime | agent | no |
| **decide** refresh / skip / ambiguous / forced / ceiling | `tools\extract-decide.ps1` | **yes** |
| **write the sidecar and publish the directory** | `tools\publish-extract.ps1` | **yes** |

This is achievable, not aspirational: `registry.sql` already emits `age_minutes`, `stale`,
`past_ceiling`, `reason` and all three `source_*` arrays, so the decision needs nothing from Snowflake a
caller cannot pass in.

---

## Measured facts

### `Move-Item` onto an existing directory silently serves stale data

First, because it would ship invisibly. Reproduced:

```
Move-Item -LiteralPath <staging> -Destination <live>     # <live> exists
→ succeeded ($? = True)

<live>\data_0_0_0.snappy.parquet          <- "STALE"
<live>\<name>.new\data_0_0_0.snappy.parquet  <- "FRESH"
```

It does not fail and does not replace — it moves staging **inside** live, so the stale Parquet stays put
and `<live>\*.parquet` reads **old data, exit 0, no warning**. First materialize works (no target);
every refresh does not.

`[IO.Directory]::Move` onto an existing target throws
`Cannot create a file when that file already exists` — the safe behaviour. There is no atomic
directory-replace on NTFS. **Publish is rename-aside, and `Move-Item` is forbidden for it.**

An **open handle on a file inside** the staging directory makes `[IO.Directory]::Move` throw
`Access to the path '…' is denied` — verified with `FileShare.ReadWrite` as well as `None`, so it is a
robust way to inject a publish failure at the second move.

### A multi-line `query` breaks 2a's readers — a latent defect 2b is the first to trigger

`SIDECAR.md:12` requires `query` to *"round-trip byte-exact; do not normalise whitespace"*, and a real
`COPY INTO … FROM (<query>)` is usually multi-line. Both shipped readers parse `registry.sql`'s CSV as a
**line array** (`extract-status.ps1:93`, `list-extracts.ps1:75`), and `ConvertFrom-Csv` treats each array
element as a record, so a quoted field containing a newline corrupts the row:

```
list-extracts.ps1  → name=p1 age_minutes=UNKNOWN row_count=NULL
extract-status.ps1 → first line BLANK, verdict: UNKNOWN
```

A perfectly valid sidecar reads as `UNKNOWN`, and the blank first line breaks 2a's own "first output line
is the age" contract. 2a never hit it because its generator writes single-line queries.

The fix is one line in each reader, verified:

```
$raw | ConvertFrom-Csv                  → records=2, age=[]        (shipped)
($raw -join "`n") | ConvertFrom-Csv     → records=1, age=[91]      (fixed)
```

`registry.sql` is **not** changed. This is a PowerShell parsing fix.

### The two pinned objects, and their drift

Measured 2026-09-23 and again 2026-09-24:

| object | rows then → now | bytes then → now |
|---|---|---|
| `DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS` | **15,314 → 15,314** | 1,037,312 → **1,041,408** |
| `DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PROJECTS` | **42,161 → 42,162** | 7,463,424 → **7,437,824** |

- **`DT_PARENT_PROJECTS` is the stable one** — rows unchanged over 16 hours while bytes moved **twice**.
  A third independent confirmation that **bytes must never be compared**.
- **`DT_PROJECTS` is the volatile one** — it gained a row overnight.

**Both are snapshots, not assertions.** See AC7's gate.

### Transport, verified end to end

`COPY INTO @~/<stage>/ FROM (<query>) FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE`
→ `rows_unloaded 15314`, `output_bytes 380104`, 321 ms. `LIST` showed **8** files,
`data_0_0_0.snappy.parquet` … `data_0_7_0` — eight for a 15k-row table, which is why one directory per
extract is not optional. `GET` → 8 × `DOWNLOADED`; **the local directory must exist first** or it fails
`ENOENT`. DuckDB read `<dir>/*.parquet` → 15,314 rows, `DATE` preserved. `REMOVE` → 8 × `removed`, and
`LIST @~/` then returns 0 rows.

### Stage 1 costs no warehouse compute

| query | QUERY_TYPE | WAREHOUSE_SIZE | BYTES_SCANNED |
|---|---|---|---|
| `SHOW TABLES LIKE …` | `SHOW` | *(empty)* | **0** |
| `COPY INTO @~/…` | `UNLOAD` | `X-Small` | 1,037,312 |

`WAREHOUSE_SIZE` empty and `BYTES_SCANNED` = 0 is the observable proof. It is a metadata-only command on
the ordinary connection, **not** a second "no-warehouse connection".

### `runtime_seconds`, with a trap

`QUERY_HISTORY_BY_SESSION` works and **the session persists across separate `snowflake_sql_execute`
calls** (same `SESSION_ID` across six). Must be **database-qualified**
(`DB_CONTROL_TOWER.INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION`) — bare fails `invalid identifier`
because `CURRENT_DATABASE()` is empty. **Filter `EXECUTION_STATUS = 'SUCCESS'`**: an in-flight query
reported `TOTAL_ELAPSED_TIME = -1790201630243`.

### `last_altered` is not a change signal, and there is no better one

Both pinned objects are dynamic tables whose `LAST_ALTERED` advances on **every** refresh regardless of
content. **`DYNAMIC_TABLE_REFRESH_HISTORY` is not available to this role** — the `INFORMATION_SCHEMA`
function returns zero rows, `SNOWFLAKE.ACCOUNT_USAGE` is `not authorized`. The ambiguous verdict is
forced, not chosen.

### `registry.sql` reports a negative age as not-stale

A future-dated sidecar: `age_minutes=-45 stale=false past_ceiling=false reason=[]`. So a decision built
naively on `stale` emits `FRESH` for clock skew, while `extract-status.ps1:126-128` says
`UNKNOWN (clock skew)`. Two shipped tools must not disagree about one sidecar — see the verdict table.

### `[int[]]` destroys the null-is-never-zero rule

```
[int[]] binding 100,$null,102  →  100, 0, 102
```

`SIDECAR.md:20` requires `null` never to read as `0`, because `0` means "the table emptied". Current
values are therefore **strings**.

### The implementer can reach Snowflake

Probed: a subagent has `snowflake_sql_execute`, returns role `CLYCO_PWRUSR_COST_MGMT_GROUP` and
warehouse `WH_POWER_USERS_XS`, and `LIST @~/` succeeds. The `[skill]` checks are delegable. **If any
Snowflake call fails, stop and report — never fabricate a result or hand-write a sidecar to make a check
pass.** (The one carve-out: AC10 may rewrite `materialized_at` to age an extract. That is legitimate
fixture manipulation; no other field may be touched.)

---

## Deliverables

| Path | What it is |
|---|---|
| `tools\dsk-paths.ps1` | the single copy of `<project-id>` and extract-root resolution |
| `tools\extract-decide.ps1` | the freshness / two-stage decision, as a command |
| `tools\publish-extract.ps1` | writes the sidecar and publishes rename-aside |
| `tools\make-decide-fixtures.ps1` | regenerates `fixtures\decide` for AC4/AC5. Test scaffolding, named so it is not read as unasked-for scope. |
| `skills/snowflake-extract/SKILL.md` | the agent flow that calls the three |
| `tools\list-extracts.ps1`, `tools\extract-status.ps1` *(edit)* | dot-source `dsk-paths.ps1`, **and** fix the CSV parse |

### 1. `tools\dsk-paths.ps1` — one definition, not three

The two shipped tools each carry their own copy (`extract-status.ps1:33,47`). A **third** is exactly the
drift PLAN-3 warns about for a term items 2 and 6 both build paths from.

- **`Get-ProjectId` is byte-identical between the two copies** — move it verbatim.
- **`Resolve-ExtractRoot` is NOT identical.** `extract-status.ps1:47` returns a bare string;
  `list-extracts.ps1:50` returns `(string, bool)` where the bool means "the default root was used", and
  it gates the `project-id:` / `extract root:` header lines that **2a's AC1 asserts**. The shared version
  keeps the **tuple** form; `extract-status.ps1` takes element `[0]` and discards the flag. Both callers'
  observable output is unchanged. This is the one place the refactor cannot be literal.
- **`dsk-paths.ps1` must set no `$ErrorActionPreference` and no `Set-StrictMode` at file scope** —
  dot-sourcing leaks both into all four callers, and AC6 runs from the repo root and would not catch it.
- **Do not "improve" `$HOME` to `$env:USERPROFILE`.** On a redirected profile they differ, and that would
  relocate every extract.
- **Relative `-ExtractRoot` is rejected** with `-ExtractRoot must be an absolute path`. Both functions
  resolve via `[System.IO.Path]::GetFullPath()`, which uses .NET's `CurrentDirectory` — and PowerShell's
  `cd` does **not** update it. This bit 2a's verifier mid-run. Rejecting relative paths is the decision;
  do not instead call `SetCurrentDirectory`.
- PLAN-3's definition stands: `git rev-parse --show-toplevel` if inside a work tree else the current
  directory, full path, lowercased, trailing separator removed, `\` and `/` → `-`, `:` deleted.
  **Compute it; never pin the literal** — it differs in a worktree by design.

**Land this as its own commit and run AC6 at that commit**, before AC7 exists. It is the only part
touching shipped verified code.

### 2. `tools\extract-decide.ps1` — the decision

```
tools\extract-decide.ps1 -Name <extract> [-ExtractRoot <path>]
                         [-CurrentRows <string[]>] [-CurrentLastAltered <string[]>]
```

Prints exactly one verdict line:

| verdict | when |
|---|---|
| `FRESH` | age within the window and not negative. No Snowflake call needed to reach this. |
| `STALE (probe required) age=<n> window=<w> objects=<comma-separated>` | past the window and **no current values supplied** |
| `REFRESH (stale, source moved)` | past window, stage 1 says rows moved |
| `SKIPPED (source unchanged)` | past window, stage 1 rows equal, stage 2 `last_altered` equal |
| `SKIPPED (ambiguous: last_altered moved, rows unchanged) age=<n>` | past window, rows equal, `last_altered` moved |
| `REFRESH (ambiguous past ceiling)` | as above but age > `DSK_MAX_AGE_MINUTES` |
| `REFRESH (clock skew) age=<n>` | `age_minutes` **negative**. `SIDECAR.md`: negative age is never `FRESH`. 2a reports this state as `UNKNOWN (clock skew)`; 2b's action is to re-pull. |
| `REFRESH (forced)` | `DSK_FORCE` is exactly the string `1` |
| `REFRESH (no sidecar)` | `<root>\<name>\` absent — the **first-ever materialize** |
| `REFRESH (unreadable sidecar)` | invalid JSON, or `materialized_at` unparseable |
| `REFRESH (malformed sidecar: <reason>)` | `registry.sql` returns a non-empty `reason` — `name mismatch` or `parallel array mismatch`. A valid age never launders a malformed sidecar into `FRESH`. |

**The two-call protocol, which is what makes checking free.** First call supplies no current values. If
the age is inside the window the answer is `FRESH` and **Snowflake is not touched at all**. Only
`STALE (probe required)` sends the agent to probe, and it prints the objects to probe, in order.

- **`-CurrentRows` and `-CurrentLastAltered` are positional against `source_objects`**, in the order
  `STALE (probe required)` prints them. A different element count is a usage error, exit **2**:
  `expected <n> values for <n> source objects, got <m>`.
- **The agent never reads `_extract.json` directly.** `extract-decide.ps1` is the only reader — that is
  why the verdict prints the object list.
- **`-CurrentRows` takes strings.** The literal token `null` (case-insensitive) means no metadata count
  was available; anything else must parse as `[long]` or it is a usage error, exit 2. `[int[]]` would
  coerce `$null` to `0`, and `0` means "the table emptied".
- **Stage 1 compares `source_rows` only. `source_bytes` is never compared.**
- **Multi-object rule:** any object whose rows moved makes stage 1 say moved. An object with `null` on
  either side abstains. If **every** object abstains, stage 1 abstains entirely and stage 2 decides.
- **Stage 2 parses both sides as UTC timestamps and compares to the second** — never string equality
  (the sidecar holds `yyyy-MM-ddTHH:mm:ssZ`, `CONVERT_TIMEZONE` returns a different rendering, so string
  compare would make "unchanged" unreachable and collapse the two SKIP branches permanently). A value
  that will not parse abstains. **Never compare against `materialized_at`.**
- **The ambiguous verdict prints the age on the same line.** A bare `SKIPPED (ambiguous)` lets a
  three-day-old extract look like a decision rather than a risk.
- **The ceiling bounds the accepted failure** — an in-place UPDATE preserving the row count. Without it
  the miss is forever, and `DSK_FORCE` does not bound it because it needs Phil to already suspect what
  the check failed to tell him. `DSK_MAX_AGE_MINUTES` defaults to **1440**, and the ceiling applies to
  the **ambiguous branch only**: an unchanged `last_altered` means genuinely unaltered, so skipping
  forever is correct there.
- **`DSK_FORCE` is exactly the string `1`.** Any other value, `0` included, is not forced.
- Reuse 2a's age arithmetic: `materialized_at` pinned `TIMESTAMP`,
  `date_diff('minute', materialized_at, timezone('UTC', now()))`, comparisons wrapped
  `coalesce(..., true)`. Prefer calling `registry.sql` over re-implementing it — but note it reports a
  negative age as `stale=false`, so clock skew must be handled before consulting `stale`.
- Window from `$env:DSK_WINDOW_MINUTES`, **unset means 60**, and the output states the window used.
- **Exit 0 for every verdict**, including all `REFRESH` ones and an absent directory. Exit **2** only for
  parameter errors. 2a's `extract-status.ps1` exits 2 for an absent extract because it *reports state*;
  this script decides an *action*, and "not there yet" has a perfectly good action.
- **This script decides and prints. It never pulls, writes, or mutates anything.**

### 3. `tools\publish-extract.ps1` — the sidecar write and the dangerous rename

```
tools\publish-extract.ps1 -Name <extract> -StagingDir <path>
                          (-SidecarPath <path> | -SidecarJson <string>)
                          [-ExtractRoot <path>]
```

Two mutually exclusive sidecar parameters, not one overloaded one — a JSON document on a PowerShell 5.1
command line is a quoting minefield, so `-SidecarPath` is the expected route.

**The script stamps four fields itself and rejects them if supplied**, because a clock reading is a
decision and an agent is a poor clock — this is what makes AC9 true by construction:

- `sidecar_version` = `1`
- `materialized_at` = `[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')`
- `window_minutes` = `$env:DSK_WINDOW_MINUTES`, unset means 60
- `expires_at` = `materialized_at` + `window_minutes`

Sequence:

1. Validate against `SIDECAR.md`: every required field present, `name` equal to the target directory
   name, and the three `source_*` arrays the same length as `source_objects`. **Refuse to publish an
   invalid sidecar**, exit **3** — each of those conditions is one 2a reports as `UNKNOWN`, so publishing
   one creates an extract the registry cannot read.
2. Write `<StagingDir>\_extract.json` BOM-free via
   `[IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding($false)))`.
3. Publish:
   - if `<live>` exists → `[IO.Directory]::Move(<live>, <live>.old)`
   - `[IO.Directory]::Move(<StagingDir>, <live>)`
   - delete `<live>.old`
4. If the second move fails, `<live>.old` still holds the previous extract — **restore it and report the
   failure.** Never leave the extract absent, and never leave `<live>.old` behind on the restore path.
5. A leftover `<live>.old` or `<live>.new` from an interrupted publish is **reported, not silently
   deleted** — it is evidence.

**Post-condition: after a successful publish `<live>` contains no subdirectory.** That is what catches
the `Move-Item` nesting bug, and it belongs in the script as well as in AC1.

### 4. `tools\make-decide-fixtures.ps1`

AC4 and AC5 need baselines the 2a generator does not produce (age 30, a `source_rows` baseline of 100, a
`null` element, a future-dated stamp). And 2a's `make-extract-fixtures.ps1` **resets `ages`, `damaged`
and `empty` on every run** (`:107-109`), so hand-built fixtures in those roots are destroyed by AC6.

So this writes to its **own root**, `.duckdb-skills\fixtures\decide`, one directory per AC4 row named
`a_fresh` … `l_absent`. **Do not edit `make-extract-fixtures.ps1`** — 2a's AC10 asserts 2a mutated
nothing. Stamps from `[DateTime]::UtcNow`, never `Get-Date`; BOM-free writes; `source_rows` baseline
`100` except the null and absent rows.

### 5. `skills/snowflake-extract/SKILL.md`

Frontmatter `description` is **≤ 4 lines of content** after `description: >` — the one new skill item 2
spends against item 8's ceiling of two. `allowed-tools` must include the Snowflake execute tool; the field
may be advisory (eight skills declare `allowed-tools: Bash` while `read-memories` declares none and runs
`duckdb` fine), so **verify by invocation, not frontmatter**.

**Materialize:**

1. Resolve the extract root via `dsk-paths.ps1`. **Create `<root>\<name>.new\` before `GET`** — it fails
   `ENOENT` otherwise.
2. `SHOW TABLES` each source object → `source_rows`, `source_bytes`; and
   `INFORMATION_SCHEMA.TABLES.LAST_ALTERED` → `source_last_altered` via
   `CONVERT_TIMEZONE('UTC', LAST_ALTERED)`.
3. Capture provenance: `role` from `CURRENT_ROLE()`, `warehouse` from `CURRENT_WAREHOUSE()`,
   `connection` = the literal **`DATAHUB`** (no SQL returns the connection name), and `database` = **the
   database qualifier of the first `source_objects` entry** — `CURRENT_DATABASE()` is empty on this
   connection, so it cannot be read from the session. **Do not invent a value for any field; if one
   cannot be obtained, stop and report.**
4. `COPY INTO @~/duckdb-skills/<project-id>/<name>__<8 hex>/` with
   `FILE_FORMAT = (TYPE = PARQUET) HEADER = TRUE OVERWRITE = TRUE`. Capture `rows_unloaded` →
   `row_count`, and `output_bytes`.
5. `GET` into `<root>\<name>.new\`.
6. Look up `TOTAL_ELAPSED_TIME` for that `COPY INTO`, `EXECUTION_STATUS = 'SUCCESS'` only → 
   `runtime_seconds`. If unobtainable, **omit the field and say so**.
7. `publish-extract.ps1`.
8. `REMOVE` the stage path.

**Stage-path collision is settled by construction:** the random 8-hex suffix per materialize plus the
`REMOVE` after `GET` means two sessions choosing the same name cannot collide on the stage. Rename-aside
settles the local side.

**Read:** call `extract-decide.ps1` **with no current values**. On `FRESH`, stop — no Snowflake call. On
`STALE (probe required)`, probe the printed objects in order and call again. On any `REFRESH (…)`,
re-materialize **silently, no prompt** — print the sidecar's `row_count` and `runtime_seconds` *before*
refreshing so the wait is predictable, and one line of elapsed time after. The **first materialize is
unguarded** — no prior runtime exists.

**A failed re-pull must not serve stale data as current.** Print the literal
`STALE: refresh failed, serving nothing; extract age <n> minutes`.

**The window is the throttle; there is no per-session cap.** A refresh rewrites `materialized_at`, so
later reads see a fresh extract — at most one refresh per window per extract, no session state. Do not
add a cap: an all-day session with a 60-minute window would refresh once and then serve seven-hour-old
data.

**Registry-first, and unenforceable.** The skill instructs sessions to run `tools\list-extracts.ps1`
before querying Snowflake. Nothing can compel a future session to look first — skills are stateless shell
invocations. Follow the precedent at `skills/read-memories/SKILL.md:15-18`. This is item 2's only
unenforceable claim.

**Defaults follow work mode:** 60 minutes analysis, 1440 dev, via `DSK_WINDOW_MINUTES`. The reader's mode
governs; the sidecar's `window_minutes` is the writer's fact only.

### 6. The two shipped readers — two changes each

Dot-source `dsk-paths.ps1`, **and parse `registry.sql`'s CSV as one joined string**:
`($csvLines -join "`n") | ConvertFrom-Csv`. Over a line array `ConvertFrom-Csv` breaks any quoted field
containing a newline. `registry.sql` is unchanged.

---

## Out of scope

- **No change to `SIDECAR.md` or `registry.sql`.** They are the frozen interface. If a field seems
  missing, say so and stop.
- **`path` and `parquet_glob` are not sidecar fields** — they are `registry.sql` output columns.
- **2a's verdict tokens do not change.** 2a reports *state* (`FRESH`/`EXPIRED`/`UNKNOWN`); 2b decides an
  *action* (`FRESH`/`REFRESH`/`SKIPPED`/`STALE`). `EXPIRED` has no 2b counterpart because 2b answers
  refresh-or-skip instead. `FRESH` means the same in both. **Do not "harmonise" them.**
- **No change to `state.sql` resolution.** 2a already recorded the precedence decision in `README.md`;
  2b does not need the home-side path, so there is nothing new to settle.
- **No retention or cleanup** beyond `<live>.old` on a successful publish and the stage copy after `GET`.
- **No scheduled or background refresh, no long-lived service.**
- **No shared/global extract store** — per-project isolation is deliberate.
- **The `snowflake` DuckDB extension is never loaded** (`docs/duckdb-snowflake-findings.md`).
- **No lakehouse, no workbooks** — items 3–6.

---

## Acceptance checks

**[command]** = Phil runs it. **[skill]** = agent invokes. Fixture checks use `-ExtractRoot` against
`.duckdb-skills\fixtures\…` and never touch the real extract root, **except AC15**, which is called out
explicitly.

### The dangerous mechanics — all [command]

**AC1 [command] — publish replaces, and the `Move-Item` bug is absent.** Build a live dir whose Parquet
reads `STALE` and a staging dir whose Parquet reads `FRESH`; run `publish-extract.ps1`.

Expected: live Parquet reads **`FRESH`**, `<live>` contains **no subdirectory**, no `.old`/`.new`
remains. Then **rebuild the fixture** (a successful publish consumes the staging dir) and run a bare
`Move-Item <staging> <live>`: expected `$?` = **True**, live Parquet still **`STALE`**, and a nested
**`<live>\<name>.new\`** holding the fresh copy. Both halves must be shown — the second is what proves
the check tests something real.

**AC2 [command] — a failed publish does not lose the extract.** Inject the failure **at the second move
specifically**, by holding an open handle on a file inside staging:
`$fs = [IO.File]::Open('<staging>\keep.txt','Open','Read','ReadWrite')` — verified to make
`[IO.Directory]::Move` throw `Access to the path … is denied` while still allowing `_extract.json` to be
written. Close the handle afterwards.

**Do not** inject by pointing `-StagingDir` at a non-existent path: that fails before `<live>` is renamed
aside, so the restore path never runs and this check passes on an implementation that has none.

Expected: the failure is reported; `duckdb -csv -c "SELECT count(*) FROM '<live>/*.parquet'"` returns the
original row count; **no `<live>.old` remains**. With AC1 this is what distinguishes rename-aside from
delete-then-move — a delete-then-move publish passes AC1 and fails here with the extract gone.

**AC3 [command] — an invalid sidecar is refused.** Four attempts, each reporting a named reason, exiting
**3**, and leaving `<live>` unchanged: a missing required field; `sidecar_version` ≠ 1; `name` not
matching the target directory; `source_rows` shorter than `source_objects`.

**AC4 [command] — the decision table, every branch.** Begin with
`tools\make-decide-fixtures.ps1 -Root .duckdb-skills\fixtures\decide`. Drive `extract-decide.ps1` and
quote each verdict **in full, no ellipsis**:

| # | age | rows baseline → current | `last_altered` | env | expected verdict |
|---|---|---|---|---|---|
| a | 30 | 100 → 100 | same | window 60 | `FRESH` |
| b | 90 | 100 → **101** | moved | window 60 | `REFRESH (stale, source moved)` |
| c | 90 | 100 → 100 | same | window 60 | `SKIPPED (source unchanged)` |
| d | 90 | 100 → 100 | **moved** | window 60 | `SKIPPED (ambiguous: last_altered moved, rows unchanged) age=90` |
| e | **1500** | 100 → 100 | moved | window 60 | `REFRESH (ambiguous past ceiling)` |
| f | 30 | 100 → 100 | same | `DSK_FORCE=1` | `REFRESH (forced)` |
| g | 90 | **null** → 100 | same | window 60 | `SKIPPED (source unchanged)` — stage 1 abstains, stage 2 decides. Print which stage decided. |
| h | 90 | 100 → 100 | moved, **`source_bytes` changed** | window 60 | `SKIPPED (ambiguous: …) age=90` — bytes change nothing |
| i | 90 | *(not supplied)* | — | window 60 | `STALE (probe required) age=90 window=60 objects=DB.SCH.A` |
| j | **−45** (future) | 100 → 100 | same | window 60 | `REFRESH (clock skew) age=-45` |
| k | 90 | 100 → **101** | **same** | window 60 | `REFRESH (stale, source moved)` — stage 1 short-circuits without stage 2 |
| l | — | *(directory absent)* | — | window 60 | `REFRESH (no sidecar)`, exit **0** |
| m | 90 | 100 → **null** | same | window 60 | stage 1 abstains, **not** `REFRESH` |
| n | 90 | *(name mismatch sidecar)* | — | window 60 | `REFRESH (malformed sidecar: name mismatch)` |

Row **b** is the one that matters most: without it an implementation hardcoded to `SKIP` passes
everything else. Rows **h** and **m** prove bytes are not compared and that `null` is not `0`. Rows **a**
and **i** together prove a `FRESH` answer is reachable with **zero** Snowflake calls.

**AC5 [command] — exit codes and the window default.** Every AC4 verdict exits **0**, including all
`REFRESH` ones and row l's absent directory. Exit **2** only for parameter errors — show a malformed
`-CurrentRows` element and an array-length mismatch, with the literal messages. With
`DSK_WINDOW_MINUTES` unset, a 90-minute extract is past the window and the output **states it used 60**.

**AC6 [command] — the refactor changed nothing. Run at the refactor commit, before AC7.** Re-run AC1,
AC2, AC3 and AC8 from `docs\tasks\2026-09-24-item2a-extract-registry\TASK.md`, plus
`tools\run-compat-tests.ps1`.

Expected, quoting numbers: AC3's three ages inside 2a's own bands **0–2 / 89–93 / 1499–1503** (not
0/90/1500 — 2a widened these deliberately); AC8's listing newest-first with `15314` and `42161`; compat
suite exit **0** with `REGRESSION: none`. For AC1 the gate is 2a's — non-empty id, no `:`, no separator,
and both header lines `project-id:` and `extract root:` present. AC1's
`no extracts registered under …` line is **not** part of the gate: AC7 legitimately populates that root.

**AC17 [command] — a multi-line `query` round-trips.** Publish a fixture whose sidecar `query` contains
an embedded newline, then `tools\extract-status.ps1 -Name <x> -ExtractRoot <fixtures>`. Expected: first
line a **number**, not blank, and verdict `FRESH`. Then read `_extract.json` back and show `query` is
**byte-identical** to what was supplied, newline included.

### The Snowflake path — [skill]

**AC7 [skill] — materialize both pinned objects.** Query for each is literally
`SELECT * FROM <fully-qualified object>`. Materialize `DT_PARENT_PROJECTS` as `parent_projects` and
`DT_PROJECTS` as `dt_projects`.

**The gate is internal consistency**, because both drift. These **three must be equal unconditionally**:
`COPY INTO`'s `rows_unloaded`, the sidecar's `row_count`, and
`duckdb -csv -c "SELECT count(*) FROM '<dir>/*.parquet'"`. If live `SHOW TABLES` rows differ from
`source_rows[0]`, quote both with timestamps as **mid-run drift** and re-run once. Quote the snapshots
(**15,314**, **42,162**) alongside — a difference is **drift to report, not a failure to fix**.

Also: the directory holds **multiple** `.parquet` files, and `LIST @~/duckdb-skills/…` returns **0 rows**
afterwards.

**AC8 [skill] — types survive.** `DESCRIBE` over the landed `parent_projects` Parquet shows
`PARENT_ACTUAL_START` typed **`DATE`**.

**AC9 [skill] — a freshly materialized extract reads age 0, not 300.** Immediately after AC7,
`tools\extract-status.ps1 -Name parent_projects`. Expected first line **0 or 1**. This is the one thing
2a could not prove: its UTC arithmetic against a sidecar written by the real pipeline.

**AC10 [skill] — stage 1 skips against unchanged source, at no warehouse cost.** Backdate
`parent_projects`' `materialized_at` past the window (the one permitted fixture edit), then read it.
Expected `SKIPPED` — and print the sidecar's `source_last_altered[0]` and the live value **side by
side**, so which branch fired is visible and the other is ruled out. Evidence it cost nothing, from
`QUERY_HISTORY_BY_SESSION` with `QUERY_ID`s quoted: the `SHOW TABLES` probe at `QUERY_TYPE = SHOW`,
**`WAREHOUSE_SIZE` empty**, **`BYTES_SCANNED` = 0**, beside AC7's `COPY INTO` row at `X-Small`.

**AC11 [skill] — the window bounds frequency.** Immediately after a refresh, a second read reports
`FRESH` and does **not** re-pull.

**AC12 [skill] — `DSK_FORCE=1` re-pulls a fresh extract**, printing the literal `REFRESH (forced)`.
*AC4 row b proves the decision; this check proves the pull.*

**AC13 [skill] — a failed re-pull does not serve stale data.** Force a failure (an unqualified object
name will do). Expected the literal `STALE: refresh failed, serving nothing; extract age <n> minutes`,
the previous extract intact.

**AC14 [skill] — `runtime_seconds` is sane or absent.** Across every sidecar written this round it is
absent or **> 0**, and at least one carries a positive value with the `QUERY_ID` and
`TOTAL_ELAPSED_TIME` it came from quoted.

**AC15 [command] — the whole point, end to end. This one does touch the real extract root**, by
exception. `list-extracts.ps1` shows both extracts by name with row counts, ages, and
`bytes_check=AGREES` for both — if it disagrees, quote both numbers as drift to report, **not** to fix by
editing `list-extracts.ps1`. Then resolve `dt_projects`' **`parquet_glob` from the registry by name**
(not a hard-coded path — this is the plan's lookup-by-name requirement and the first use of a column 2a
built for items 6 and 8) and `duckdb -csv -c "SELECT count(*) FROM '<that glob>'"` returns its row count
with **no Snowflake call**. Then delete one extract's directory and show the registry no longer lists it.

**AC16 [command] — description budget.** `skills/snowflake-extract/SKILL.md`'s `description` is **≤ 4
lines of content** after `description: >`, and
`git diff --name-only --diff-filter=A main...HEAD -- skills/` lists exactly
`skills/snowflake-extract/SKILL.md`.

---

## Commit and handoff

Branch **`item2b-snowflake-extract`**. **`dsk-paths.ps1` plus the two reader edits land as their own
commit, with AC6 and AC17 run at that commit**, before anything else. Commit again before writing
`RESULT-1.md`.

Verification runs in a `git worktree` at the final commit. The verifier **can** reach Snowflake
(probed), but `<project-id>` differs in a worktree so its extract root is empty — it must re-materialize
(AC7) before re-running AC9, AC10 or AC15.

`RESULT-1.md` must state `[command]` or `[skill]` per check with verbatim output, and inline: AC1's
**both halves**, **every row** of AC4's table, AC7's three-way consistency per extract with the snapshots
beside them, and AC10's two `QUERY_HISTORY` rows with their `QUERY_ID`s.

---

# CORRECTIONS — round 2

Round 1 delivered working machinery. Sixteen of seventeen checks passed, the two publish mutation
attacks confirmed the rename-aside is load-bearing rather than decorative, and the Snowflake half was
**independently re-run by the main session** and holds: three-way row consistency 15,314 = 15,314 =
15,314, a real-pipeline sidecar reading age **0** / `FRESH`, `PARENT_ACTUAL_START` typed `DATE`, zero
subdirectories after publish, registry `bytes_check=AGREES`.

**Nothing about `dsk-paths.ps1`, `publish-extract.ps1`, `extract-decide.ps1`, the CSV-parse fix, or the
reader refactor needs to change.** Do not touch them beyond what C2 requires. This round closes one gap.

## Why the verifier could not certify half of this round

The `verifier` agent **does not have `snowflake_sql_execute`**, despite the round-1 brief telling it that
it did, and has no `snow` CLI. So AC7–AC14 and half of AC15 came back **NOT RUN** — a verification gap,
not a defect. The main session re-ran them instead.

**Consequence for this round, and it is a standing rule now:** a `[skill]` check cannot be certified by
the verifier. Write `RESULT-2.md` so the main session can re-run every `[skill]` check from the verbatim
SQL and commands recorded in it. Quote the literal statements you ran, not a description of them.

## C1 — the blocker was real, and so is the fix

`COPY INTO ... FILE_FORMAT=(TYPE=PARQUET)` refuses TZ types. Reproduced independently:

```
Error encountered when unloading to PARQUET: TIMESTAMP_TZ and LTZ types are not
supported for unloading to Parquet. value get: TIMESTAMP_LTZ
```

`DT_PROJECTS` carries two such columns, `START_DATE` and `FINISH_DATE`, both `TIMESTAMP_LTZ`. The spec
required the query to be literally `SELECT * FROM <object>`, which cannot work on that table. **That was
a spec defect, not an implementation defect** — the implementer stopped and asked rather than
improvising, which was the right call.

Blast radius, measured on `DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS`: **4 of 197 tables (2.0%)**, 10
columns. Not rare by accident — `CURRENT_TIMESTAMP()` returns `TIMESTAMP_LTZ(9)`, so audit-stamped
tables carry one.

**The workaround, verified end to end by the main session:**

```sql
CONVERT_TIMEZONE('UTC', <col>)::TIMESTAMP_NTZ AS <col>
```

`COPY INTO` then succeeds, and the value round-trips losslessly: Snowflake's `2019-09-06 05:00:00.000`
arrived in DuckDB as `2019-09-06 05:00:00` typed **`TIMESTAMP`**, matching Snowflake's own UTC rendering
exactly.

## C2 — the skill builds the query; it never issues a blind `SELECT *`

`skills/snowflake-extract/SKILL.md`'s materialize flow gains a step **before** `COPY INTO`:

1. Query `<db>.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = '<sch>' AND TABLE_NAME = '<obj>' ORDER BY
   ORDINAL_POSITION`, splitting `<db>`/`<sch>`/`<obj>` from the fully-qualified source object. **Bare
   `INFORMATION_SCHEMA` fails `invalid identifier` on this connection** — the same reason
   `QUERY_HISTORY_BY_SESSION` must be qualified (frozen body, "`runtime_seconds`, with a trap").
2. If **no** column has `DATA_TYPE IN ('TIMESTAMP_TZ','TIMESTAMP_LTZ')`, the query stays
   `SELECT * FROM <object>` — unchanged for the 98%, so this costs nothing there.
3. Otherwise build an **explicit column list** in ordinal order, projecting only the TZ columns as
   `CONVERT_TIMEZONE('UTC', "<col>")::TIMESTAMP_NTZ AS "<col>"` and naming every other column plainly.
   **Do not cast anything else** — a blanket cast would be a second, unmeasured change.

   **Every column name is emitted double-quoted**, in both the cast and the plain projections.
   `COLUMN_NAME` comes back from `INFORMATION_SCHEMA.COLUMNS` **without** its quotes, so a bare
   identifier is a syntax error on any column created as a quoted identifier and on any reserved word
   — **`START` is reserved in Snowflake**, on a table that already has `START_DATE`. Quoting the exact
   `COLUMN_NAME` is a no-op for ordinary upper-case names and correct for the rest; if a `COLUMN_NAME`
   contains a `"`, double it.

   **Ordinal order is required, not cosmetic**: it is what makes the projection produce the same
   Parquet schema `SELECT *` would have. AC18's column-count assertion plus the first and last column
   names quoted in `RESULT-2.md` are the evidence.
4. Record that query verbatim in the sidecar's `query`, using `\n` alone as the line separator (not
   `\r\n` — AC19 compares it against Snowflake's own record of it). `SIDECAR.md` requires byte-exact
   round-trip, so what landed stays reconstructible from what the sidecar says was run. This is also
   why round 1's multi-line CSV fix matters: a projected 113-column query **will** be multi-line.

**The projection is re-derived on every materialize, including every refresh.** The sidecar's `query`
records the projection used for *that* materialize, so it may legitimately differ between two refreshes
of one extract if the source's columns changed — the extract's identity is its `name`, never its query
text (`SIDECAR.md:11`). **Do not replay a stored explicit column list:** an upstream column added after
the first materialize would be silently dropped, including a new TZ column, which would defeat the
fail-loud rule below.

**Scope of this rule:** it applies when the query is a whole-object `SELECT * FROM <object>` with
exactly one entry in `source_objects`. For a hand-written or multi-object query the author supplies the
projection and is responsible for TZ columns; state the same limitation and the same failure mode in the
skill text.

**This step runs inside the materialize flow only**, which already starts a warehouse for `COPY INTO`.
AC10's zero-warehouse-cost proof for the *freshness check* is therefore unaffected — worth saying,
because it is the non-obvious reason this addition is safe.

State in the skill text that **the resulting DuckDB type is a naive `TIMESTAMP` holding UTC**, not
`TIMESTAMPTZ`, and that the same UTC-comparison discipline applies as for `materialized_at` — compare
against `timezone('UTC', now())`, never `now()`.

**Failure mode to state explicitly:** if `COPY INTO` still fails with a type-unload error after
projection, **stop and report the column and its type.** Do not widen the cast to make it pass.

## C3 — `RESULT-2.md` must name who approved what

Round 1's `RESULT-1.md` said *"you chose to skip dt_projects"*. Phil confirms he **was** asked directly —
the implementer used `ask_user_question` and acted on a real answer. No fabrication. But the phrasing
read as an invented approval, because the main session made no such call and no artifact recorded one.

**Rule: when a subagent asks Phil something mid-run, `RESULT-<n>.md` must record the mechanism, the
question, and the answer** — "asked Phil via `ask_user_question`: *<question>*; he answered *<answer>*".
Never "you chose", which is ambiguous about who was asked and leaves a reader unable to distinguish a
real approval from a fabricated one.

## Revised acceptance checks

AC1–AC6 and AC16–AC17 are **unchanged and already passed independently** — re-run to confirm no
regression. AC8–AC14 are unchanged in substance but must now record verbatim SQL per the rule above.

**AC7-R2 (supersedes AC7) — materialize both pinned objects, including the TZ one.**

- `parent_projects` over `DT_PARENT_PROJECTS`: no TZ columns, so the query stays
  `SELECT * FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS`. Confirmed working by the
  main session — `rows_unloaded` 15,314, 7 files.
- `dt_projects` over `DT_PROJECTS`: **113 columns, two of them `TIMESTAMP_LTZ`.** The query must be the
  generated explicit projection. Quote the generated SQL in full — it is the artifact this round exists
  to produce.

Gate is internal consistency, unconditionally: `rows_unloaded` = sidecar `row_count` =
`duckdb -csv -c "SELECT count(*) FROM '<dir>/*.parquet'"`. Snapshots to quote beside it, **not** assert:
15,314 and **42,167** (the most recent observation; 42,162 the day before — both are drifting dynamic
tables, so a difference is drift to report). Assert only that the directory holds **more than one**
`.parquet` file — the count varies with unload parallelism (8, then 6, then 7 observed).

Also: `LIST @~/duckdb-skills/…` returns **0 rows** after each `REMOVE`.

**AC18 [skill] — the TZ columns land as usable timestamps, at the right instant.**

```powershell
duckdb -csv -c "SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM '<dir>/*.parquet') WHERE column_name IN ('START_DATE','FINISH_DATE')"
duckdb -csv -c "SELECT count(*) AS ncols FROM (DESCRIBE SELECT * FROM '<dir>/*.parquet')"
```

Expected: both columns typed **`TIMESTAMP`** (not VARCHAR, not `TIMESTAMP WITH TIME ZONE`), and `ncols`
**equal to the row count of C2 step 1's `INFORMATION_SCHEMA.COLUMNS` query** — quote both numbers. A
short projection is a silent column loss, and internal row-count consistency cannot detect it.

Then prove the **instant**, with a reference that does **not** reuse the projection — comparing
`CONVERT_TIMEZONE(...)` against `CONVERT_TIMEZONE(...)` would pass on a timezone-shifted value, which is
exactly the bug worth catching. Pick three rows by an identifying key (name the key in `RESULT-2.md`):

```sql
SELECT <key>, DATE_PART(EPOCH_SECOND, START_DATE) AS epoch_s
FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PROJECTS
WHERE <key> IN (<three literal keys>) ORDER BY <key>
```
```powershell
duckdb -csv -c "SELECT <key>, epoch(START_DATE)::BIGINT AS epoch_s FROM '<dir>/*.parquet' WHERE <key> IN (<three literal keys>) ORDER BY <key>"
```

Expected: `epoch_s` **equal per key**, at second granularity. DuckDB's `epoch()` reads a naive
`TIMESTAMP` as UTC, so equality proves the landed value is the correct instant rather than merely
self-consistent. **A difference that is an exact multiple of 3600 is a timezone shift — stop and report
it, do not adjust the comparison.** Also show `count(START_DATE)` is non-zero and min/max are plausible
project dates, not 1970 or NULL.

*Note: `TIMESTAMP_LTZ(9)` is nanosecond and DuckDB `TIMESTAMP` is microsecond, so sub-microsecond
precision truncates. Irrelevant to whole-second project dates, hence the second granularity above.*

**AC19 [skill] — the projection is recorded, not lost.** "Byte-identical to what was executed" needs a
reference other than the sidecar itself, or it cannot fail. Retrieve the `COPY INTO`'s `QUERY_TEXT` from
`<db>.INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION()` for the `QUERY_ID` AC14 already quotes, extract the
`FROM ( … )` body, and show it is **identical to the sidecar's `query`** after normalising `\r\n` to
`\n` on both sides — quote both strings in full. Show the sidecar's `query` contains
`CONVERT_TIMEZONE('UTC', "START_DATE")::TIMESTAMP_NTZ` and the same for `FINISH_DATE`. Then confirm
`tools\extract-status.ps1 -Name dt_projects` prints a **numeric** first line — round 1's CSV fix holding
under a realistic 113-column multi-line payload rather than a one-line fixture.

**AC20 [skill] — a non-TZ table is untouched by the new step.** This must be tied to a **fresh**
materialize: the round-1 sidecar already on disk satisfies the literal check, so as a bare string
comparison it passes before any round-2 work is done.

After AC7-R2 re-materializes `parent_projects` through the projection-aware flow, quote its sidecar's
`materialized_at` and show it is **later than the value present before this round began** — quote both.
Then show its `query` is exactly
`SELECT * FROM DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS` (fully qualified; `RESULT-1.md`
abbreviated this when transcribing — do not copy the abbreviation), with no projection and no casts.
Also quote the `INFORMATION_SCHEMA.COLUMNS` evidence that drove the decision: **zero** TZ columns for
`DT_PARENT_PROJECTS` against **two** for `DT_PROJECTS`. Without that, the rule is indistinguishable from
special-casing two table names.

**AC15-R2 (supersedes AC15)** — now runnable in full. Both extracts listed by name with row counts, ages
and `bytes_check`; `dt_projects`' `parquet_glob` resolved **from the registry by name** and counted with
no Snowflake call. Then **delete `parent_projects` specifically**, show the registry drops it, and
re-materialize it.

**`dt_projects` must survive the round intact** — AC18 reads its Parquet and AC19 its sidecar, and both
must stay re-runnable by the main session after the implementer exits. Deleting it would destroy the
evidence for this round's whole purpose. Quote `list-extracts.ps1` a final time showing both present.

## Handoff

Same branch, `item2b-snowflake-extract`. Commit before writing `RESULT-2.md`.

**Supersedes the frozen body's "Verification runs in a `git worktree`" paragraph, which is now known
false.** The verifier has **no** `snowflake_sql_execute` and no `snow` CLI; it cannot materialize and
cannot run any `[skill]` check. Its scope is **AC1–AC6, AC16, AC17**, plus the local-artifact halves of
AC19 and AC20 — and for those it must pass
`-ExtractRoot C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts`
(the main tree's root, read-only), because a worktree's `<project-id>` resolves elsewhere. It must write
`VERIFY-2.md` recording every `[skill]` check as **NOT RUN, tool unavailable**, naming them, so the gap
is on disk rather than implied. The main session then re-runs the `[skill]` checks from the verbatim SQL
in `RESULT-2.md` and appends its findings to `VERIFY-2.md`, marked as a main-session re-run.

**Round 1's accepted deviations are contract now — do not change them and do not re-report them:**
absolute `-ExtractRoot` when re-running 2a's checks (the relative-path rejection makes 2a's literal
invocations unrunnable), the `try/catch` added to both readers for a clean exit 2, and publish's exit 1
(runtime failure) / exit 2 (leftover `.old`/`.new`) classes.

**Known gap, recorded rather than closed:** every `extract-decide.ps1` fixture is single-object, so the
multi-object stage-1/stage-2 rule and round 1's `@(… | ConvertFrom-Json)` nesting fix have no passing
evidence. Deferred deliberately; state it in `RESULT-2.md` so a later round does not assume it passed.

For the re-run checks (AC1–AC6, AC8–AC14, AC16, AC17): a **PASS/FAIL line per check**, plus verbatim
output only where it differs from `RESULT-1.md`.

`RESULT-2.md` must include:

- the **generated `dt_projects` projection SQL in full**, with its first and last column names called out
- the **new `SKILL.md` section quoted verbatim**, plus `git diff -- skills/snowflake-extract/SKILL.md`
  showing nothing else in that file changed. **The text must state the rule generically — by column
  type, not by table name — and must not name `DT_PROJECTS`, `START_DATE` or `FINISH_DATE` as special
  cases.** The skill text is the deliverable; one successful execution by an implementer who already
  knows the rule proves nothing about whether the next session can follow it.
- AC18's `ncols`-versus-`INFORMATION_SCHEMA` count and the three-key epoch comparison
- AC19's two query strings in full
- verbatim SQL for every `[skill]` check, so the main session can re-run them — the verifier cannot
