# TASK — Extract registry and freshness checking (item 2a)

Plan: PLAN-3.md (item 2, first of two specs)

**Serves:** Being able to ask "what Snowflake data do I already have locally, and how old is it?" and
get a truthful answer from one command. This is the half of the extract system that *reads* — the
sidecar schema plus the registry and freshness tools over it. Item 2b adds the skill that *writes*
sidecars by pulling from Snowflake.

After this: a command listing every local extract newest-first with its age and size, and a command
giving one extract's age, freshness verdict and size — both correct across time zones, both fine when
nothing exists yet, and neither lying when a sidecar is damaged.

*Round 1, revised after `REVIEW-task-1.md`. Every figure below was measured in-session.*

---

## Why this is split from 2b, and what that costs

PLAN-3 changed item 2 from one spec to two, making the plan **eight specs, not seven**. Two reasons:

- **A verifier cannot re-run the write half.** Materialize needs `snowflake_sql_execute`, an agent
  tool, and `<project-id>` legitimately differs in the linked `git worktree` verification runs in — so
  the verifier's extract root is empty and the implementer's extracts are invisible to it. Everything
  in *this* spec is a literal command over generated fixtures, re-runnable by Phil and by a verifier
  that regenerates its own.
- **The sidecar schema is the interface between the halves.** Freezing it first is cheaper than
  discovering a missing field once both exist — review has now found **five** fields the plan had not
  named.

**No Snowflake connection is used or needed anywhere in this spec.** If a check seems to need one, the
check is wrong.

---

## Measured facts

### The UTC trap — and the pinned type and the age formula are a matched pair

For one sidecar stamped 90 minutes ago:

| `columns = {...}` pin | age expression | result |
|---|---|---|
| `materialized_at: 'TIMESTAMP'` | `date_diff('minute', materialized_at, timezone('UTC', now()))` | **90** ✓ |
| `materialized_at: 'TIMESTAMPTZ'` | *same expression* | **390** ✗ |
| `materialized_at: 'VARCHAR'` | `date_diff('minute', materialized_at::TIMESTAMPTZ, now())` | **90** ✓ |
| `materialized_at: 'TIMESTAMP'` | `date_diff('minute', materialized_at::TIMESTAMP, now()::TIMESTAMP)` | **−297** ✗ |

Two different 300-minute errors in opposite directions. The machine is UTC−5 (`America/Chicago`).

**The trap is subtler than "DuckDB cannot parse `Z`".** A *string* `'...Z'::TIMESTAMPTZ` resolves
correctly. The problem is that **`read_json` infers `materialized_at` as a naive `TIMESTAMP` and
discards the `Z`**, so by the time you cast, the offset is already gone.

**Pin `materialized_at: 'TIMESTAMP'` and use `timezone('UTC', now())`.** Do not mix the pairs.

### A malformed sidecar kills the whole query, and `ignore_errors` cannot save it

```
duckdb -c "SELECT name FROM read_json('<root>/*/_extract.json')"
→ Invalid Input Error: Malformed JSON in file "...\bad\_extract.json", at byte 16 ...   exit=1

... read_json(..., ignore_errors=true)
→ Invalid Input Error: ... Parse errors cannot be ignored for JSON formats other than
  'newline_delimited'                                                                   exit=1
```

One bad sidecar among good ones takes the entire listing down. `ignore_errors` is **refused** for
ordinary JSON, and where it does apply it drops the file silently, which is worse.

**Consequence, and it is architectural: the registry enumerates directories in PowerShell and reads
each sidecar in a separate `duckdb -f` invocation.** A single glob over all sidecars cannot meet this
spec's requirements.

### `glob()` matches files, not directories

```
SELECT count(*) FROM glob('<root>/*')    → 0
SELECT count(*) FROM glob('<root>/*/*')  → 2
```

So an extract directory holding `.parquet` and **no** `_extract.json` is invisible to any glob over
`*/_extract.json` — it cannot be "reported with a reason" by a glob-based registry. Another reason
enumeration is `Get-ChildItem -Directory`.

`glob()` is still the right tolerant primitive for the zero-extracts guard: it returns **0**, exit
**0**, for both an empty and an absent directory, where bare `read_json` raises
`IO Error: No files found that match the pattern` and exits 1. `~\.duckdb-skills\` **does not exist on
this machine today**, so that is the state of every clean run.

### An unset environment variable reaches DuckDB as the empty string

```
getenv('DSK_WINDOW_MINUTES')::INTEGER                                        → Conversion Error: Could not convert string '' to INT32, exit=1
coalesce(try_cast(nullif(getenv('DSK_WINDOW_MINUTES'),'') AS INTEGER), 60)   → 60
```

### A NULL age does not compare the way a filter assumes

| expression | result |
|---|---|
| `NULL > 60` | **NULL** — not `true` |
| `coalesce(NULL > 60, true)` | **true** |

A damaged sidecar yields a NULL age, and a naive `age > window` filter reports it as **not stale**.
Guard every freshness comparison with `coalesce(..., true)`.

### `read_json` tolerates a missing optional field, and a BOM

Two sidecars where one omits `runtime_seconds`: schemas unified, absent value read as `NULL`, exit 0.
A sidecar written *with* a UTF-8 BOM was read fine, exit 0 — so the BOM rule here is about the
writer's habit, not about a failure it prevents.

### Fixture figures, taken from a real extract

A real `COPY INTO` → `GET` cycle produced the numbers the fixtures imitate, so 2b's output is directly
comparable: `DB_CONTROL_TOWER.SCH_PROJECT_OPERATIONS.DT_PARENT_PROJECTS`, **15,314** rows,
`source_bytes` 1,037,312, `output_bytes` **380,104** across 8 Parquet files, `runtime_seconds` 0.32.
Second object: `DT_PROJECTS`, **42,161** rows.

### Why `source_bytes` is provenance and never compared

Two readings of `DT_PROJECTS` ~9 minutes apart: `ROW_COUNT` held at **42,161** while `BYTES` moved
**7,463,424 → 7,430,144**. Dynamic-table refresh reorganises micro-partitions. 2b compares rows only;
2a's job is to carry all three baselines so 2b can.

---

## Deliverables

| Path | What it is |
|---|---|
| `skills/snowflake-extract/SIDECAR.md` | the sidecar schema as a written contract |
| `skills/snowflake-extract/registry.sql` | per-extract `read_json` read, run with `duckdb -f` |
| `tools\list-extracts.ps1` | every extract, newest first, with age and size, plus a total |
| `tools\extract-status.ps1` | one extract's age, verdict, and size |
| `tools\make-extract-fixtures.ps1` | regenerates the fixture tree — **test scaffolding, not a plan deliverable**, named here so it is not read as unasked-for scope |

**No `SKILL.md` in this spec.** Frontmatter and the description budget belong to 2b, where a new skill
actually appears.

### Fixtures must be generated, not committed

`.duckdb-skills/` is **gitignored** (`.gitignore:3`), so fixtures cannot reach the verifier's
worktree; git cannot commit an empty directory either, so `fixtures\empty` would silently become
`fixtures\absent`. And stamps **decay** — a 90-minute fixture measured **93** minutes later in the
same session, outside any tight band.

So `tools\make-extract-fixtures.ps1 [-Root <path>]` is committed and the fixtures are not:

- Deletes and recreates the whole tree, so it is idempotent.
- **Stamps from `[DateTime]::UtcNow`, never `Get-Date`.** This is load-bearing: a fixture stamped in
  *local* time makes the broken naive-local implementation report a clean 0/90/1500 and pass AC3 while
  being wrong against every real sidecar. Because the stamp is UTC and the machine is UTC−5, the
  sidecar string is ~5 hours *ahead* of the local wall clock.
- Writes every file with `[IO.File]::WriteAllText`, never `Set-Content -Encoding UTF8`.
- Creates three separate roots so a damaged fixture cannot contaminate an unrelated check:
  `fixtures\ages\`, `fixtures\damaged\`, `fixtures\empty\`. Deletes `fixtures\absent` if present.
- **Every acceptance check begins by running it**, so ages are always freshly computed.

### Interfaces

```
tools\list-extracts.ps1        [-ExtractRoot <path>]
tools\extract-status.ps1       [-Name <extract>] [-ExtractRoot <path>]
tools\make-extract-fixtures.ps1 [-Root <path>]
```

- `-ExtractRoot` defaults to `~\.duckdb-skills\<project-id>\extracts`. **The default root is created
  if absent; an explicitly passed `-ExtractRoot` is never created** — it is a fixture or verification
  path, and creating it would make the absent-root check unrepeatable.
- `-ExtractRoot` is resolved to an **absolute** path before substitution into SQL, so results do not
  depend on `duckdb`'s working directory.
- `-Name` omitted means every extract. **With `-Name` given, the first line of output is the age in
  minutes and nothing else** — no header, no banner.
- Window arrives as `$env:DSK_WINDOW_MINUTES` (`skills/read-memories/SKILL.md:32-43` convention).
  **Unset means 60**, and the output states which window it used. `$env:DSK_MAX_AGE_MINUTES` defaults
  to **1440**; 2a only *reports* the ceiling, 2b acts on it.
- SQL lives in `registry.sql`, invoked `duckdb -f`, never inline `-c` — PowerShell expands `$` inside
  double quotes and breaks any `'$.field'` JSON path. Parameters arrive as environment variables. *(An
  ad-hoc `-c` Phil types by hand is fine; the rule is about generated SQL containing `$` or a JSON
  path.)*
- **Zero extracts is an ordinary outcome:** print `no extracts registered under <root>`, exit **0**.
  Guard with `glob()` or a file test before any `read_json`.

### Output vocabulary and exit codes — pinned, because four checks assert on them

The verdict is **exactly one of**: `FRESH`, `EXPIRED`, `UNKNOWN (<reason>)`. The ceiling is a suffix
`PAST-CEILING` on the same line. These are the literal strings the checks grep for.

**Exit codes: 0 for any successful report**, whatever the verdict — including `EXPIRED`, `UNKNOWN`,
and zero extracts. Non-zero only for a usage error: **2** for `-Name <x>` where no extract `<x>` exists
under the root, printing `extract <x> not found under <root>`.

### `<project-id>`

PLAN-3's definition: `git rev-parse --show-toplevel` if inside a work tree else the current directory,
resolved to a full path, lowercased, trailing separator removed, then `\` and `/` → `-` and every `:`
deleted. For this repo: `c-users-woodsonp-claude-dev-duckdb-skills`. **Compute it; never pin the
literal** — in a linked worktree it differs by design.

**This writes outside the repo** (`~\.duckdb-skills\`), which PLAN-3 approved deliberately: extracts
are production Snowflake data and in-repo they are one `git add -A` from being committed. 2a creates
the default root if absent but writes no extract into it.

### State-file precedence — decided here, implemented nowhere

PLAN-3 leaves this to whichever item first needs the home-side path. **Decision: project-local
`state.sql` wins when it exists.** It is more discoverable, `tools\ensure-duckdb-compat.ps1` already
behaves that way, and `skills/query/SKILL.md:22-25` (which prefers home-side) is POSIX bash that does
not run on this machine.

**Record it in `README.md`'s existing "Session state" section** (`README.md:96-105`), which already
describes both locations and is where a reader would look — **not** in `SIDECAR.md`, which is a schema
document. Change no resolution code, and **leave the contradiction with `skills/query/SKILL.md:22-25`
standing deliberately — say so**, so a future session does not "reconcile" one to the other and
silently change where macros land. Nothing here reads `state.sql`: `registry.sql` runs with `-f`
specifically to stay out of that question.

### The sidecar schema — `<extract dir>\_extract.json`

Frozen by this spec and built on by 2b, item 6 and item 8. UTF-8, no BOM. All fields required unless
marked optional.

| field | type | notes |
|---|---|---|
| `sidecar_version` | integer | value **`1`**. Without it a later schema change is undetectable and old sidecars are indistinguishable from new ones. |
| `name` | string | the identity, and **must equal the containing directory's name** — a mismatch is a malformed sidecar. Not the query text: whitespace or a changed `LIMIT` makes an identical result set look like a different query. |
| `query` | string | verbatim SQL. **Not the identity key** — that is `name`. But it **is** the input 2b re-executes on refresh, so it must round-trip byte-exact; do not normalise whitespace. |
| `source_objects` | array of string | fully-qualified |
| `materialized_at` | string | UTC, ISO 8601 with `Z`. **The extract's version token** — item 6's manifest records it beside the contract hash, closing PLAN-3's named risk that a lakehouse table has no tie to which extract version it used. |
| `window_minutes` | integer | writer's window, **provenance only** |
| `expires_at` | string | UTC, **provenance only** |
| `row_count` | integer | rows in the extract |
| `output_bytes` | integer | from `COPY INTO`'s result — the extract's own size |
| `connection`, `role`, `database`, `warehouse` | string | the same query under a different role returns different rows |
| `source_rows` | array of integer, **elements nullable** | `SHOW TABLES` rows per source object at materialize time — **2b's stage-1 baseline**. A `null` element means no metadata row count was available (e.g. the object is a view); stage 1 cannot decide for it and 2b falls through to stage 2. **`null` is never `0`** — `0` reads as "the table emptied". A null element does not violate the parallel-array rule; a *missing* element does. |
| `source_bytes` | array of integer | **provenance only, never compared** — bytes move on refresh with unchanged content |
| `source_last_altered` | array of string | UTC ISO 8601 per source object — **2b's stage-2 baseline**, compared against the *current* `LAST_ALTERED` and **never against `materialized_at`**, which on a dynamic table would make "unchanged" unreachable |
| `runtime_seconds` | number, **optional** | omitted rather than wrong. A negative value means `EXECUTION_STATUS = 'SUCCESS'` was not filtered and an in-flight query's elapsed time was recorded. |

The three `source_*` arrays are **parallel to `source_objects`**; a length mismatch is malformed.

### The freshness rule

```
age_minutes   = date_diff('minute', materialized_at, timezone('UTC', now()))   -- materialized_at pinned TIMESTAMP
stale         = coalesce(age_minutes > effective_window, true)                  -- window from the READER
past_ceiling  = coalesce(age_minutes > DSK_MAX_AGE_MINUTES, true)
```

- **`window_minutes` and `expires_at` are provenance and never inputs to a decision.** The reader's
  window governs. AC6 exists to tell a correct implementation from one that merely agrees most of the
  time.
- **No sidecar, malformed sidecar, or NULL age = `UNKNOWN`, never `FRESH`.** The `coalesce(..., true)`
  above is what enforces it.
- **A negative age means clock skew** — report `UNKNOWN (clock skew)`, never `FRESH`.
- **Age is never mtime.** Every `GET` rewrites the Parquet, so mtime always advances and would report
  fresh for exactly the data most likely to be stale. Read file timestamps for **size only**.

### The registry

A **view over the sidecars**, not a second copy, so it cannot drift. Enumeration is
`Get-ChildItem <root>\* -Directory`; each `<dir>\_extract.json` is read in a **separate `duckdb -f`
invocation**, so one damaged sidecar fails that extract and not the listing. A non-zero exit from a
per-extract read is reported `UNKNOWN (unreadable sidecar)`; a directory with no `_extract.json` is
`UNKNOWN (no sidecar)`.

Columns, pinned via `columns = {...}` so the set cannot shift as extracts accumulate: `name`, `path`,
`parquet_glob`, `query`, `source_objects`, `materialized_at`, `expires_at`, `row_count`, `role`,
`database`, `warehouse`, `age_minutes`, `size_bytes`. Newest first.

**`path` is the extract directory, absolute. `parquet_glob` is `<path>\*.parquet`.** Both are pinned so
neither item 8 nor any other consumer has to construct a path. **Size means every file in the extract
directory including `_extract.json`**, matching
`Get-ChildItem <dir> -Recurse -File | Measure-Object -Sum Length`.

---

## Out of scope

- **All of 2b:** no `COPY INTO`, `GET` or `REMOVE`, no materialize, no refresh, no two-stage
  invalidation logic, no `DSK_FORCE`. This spec defines the schema those depend on and reads what they
  write.
- **No `SKILL.md`, no new skill directory entry, no frontmatter** — 2b's.
- **The registry-first instruction belongs to 2b**, with its explicit unenforceability caveat
  (`skills/read-memories/SKILL.md:15-18` precedent). Named here so it cannot fall between the specs.
- **No deletion or retention.** 2a makes growth *visible* via the size report; acting on it stays
  manual. **Do not add cleanup.**
- **No change to `state.sql` resolution anywhere**, and no touching the eight bash skills.
- **The `snowflake` DuckDB extension is never loaded** — its ADBC teardown defect once left an
  unkillable process holding a driver lock that required a reboot
  (`docs/duckdb-snowflake-findings.md`).
- **No Snowflake connection.**

---

## Acceptance checks

**Every check begins with `tools\make-extract-fixtures.ps1 -Root .duckdb-skills\fixtures`**, so ages
are freshly computed and a verifier reproduces them exactly. All are commands Phil can run. The real
extract root is never touched.

**AC1 — `<project-id>` resolves legally.** One command printing the resolved id and default root.

The **gate** is the properties: non-empty, **no `:`**, **no `\` or `/`**, and the printed root is
creatable (`Test-Path` succeeds after the run). The literal
`c-users-woodsonp-claude-dev-duckdb-skills` is a **snapshot true only in the main worktree** — quote
it, do not assert it. Asserting a recomputation of the tool against the tool proves nothing.

**AC2 — zero extracts is not an error.**

```powershell
tools\list-extracts.ps1  -ExtractRoot .duckdb-skills\fixtures\empty
tools\extract-status.ps1 -ExtractRoot .duckdb-skills\fixtures\absent
```

The generator deletes `fixtures\absent`, and an explicit `-ExtractRoot` is never created, so the
absent case stays absent on re-run. Expected both: `no extracts registered under <root>` and
`$LASTEXITCODE` **0**. A bare `read_json` here raises `IO Error: No files found that match the pattern`
and exits 1 — the failure this check prevents, and the state of every clean machine.

**AC3 — age is correct, and in UTC.** Three fixtures in `fixtures\ages`: stamped **now**, **−90 min**,
**−1500 min**. Run `extract-status.ps1 -Name <each>` three times so the first-line rule has a subject.

Expected first lines: **0–2**, **89–93**, **1499–1503**. Bands are wide because elapsed time between
generation and run dominates, not boundary counting.

Decisively, **none of these wrong values may appear** — each is a 300-minute error, and the table makes
the check self-explaining:

| fixture | correct | naive-local (`now()::TIMESTAMP`) | double-shift (`TIMESTAMPTZ` pin) |
|---|---|---|---|
| now | 0–2 | ≈ −299 | ≈ 301 |
| −90 | 89–93 | ≈ **−209** | ≈ **390** |
| −1500 | 1499–1503 | ≈ **1201** | ≈ **1800** |

Also print each fixture's literal `materialized_at` beside the local wall-clock time, so the ~5-hour
gap is visible and a local-stamped fixture cannot silently rescue a broken implementation.

**AC4 — verdict tracks the window.** With `fixtures\ages` and `$env:DSK_WINDOW_MINUTES='60'`: now →
`FRESH`, −90 → `EXPIRED`. Then `'1440'`: −90 → `FRESH`, −1500 → `EXPIRED`. Grep the literal tokens.

**AC5 — unset window defaults to 60 and says so.** `Remove-Item Env:\DSK_WINDOW_MINUTES`, then the
−90 fixture reports `EXPIRED` **and the output states the window used (60)**. It must not exit 1 with
`Conversion Error: Could not convert string '' to INT32`.

**AC6 — the reader's window governs, not `expires_at` and not the sidecar's own window.** Two fixtures
in `fixtures\ages`, **both aged 90 minutes**:

| fixture | `window_minutes` | `expires_at` | read with | expected |
|---|---|---|---|---|
| (i) | 1440 | far future | `DSK_WINDOW_MINUTES=60` | `EXPIRED` |
| (ii) | 30 | in the past | `DSK_WINDOW_MINUTES=1440` | `FRESH` |

This catches three wrong implementations with two fixtures: comparing against `expires_at` inverts
both, and using the sidecar's `window_minutes` also inverts both. Quote both verdicts.

**AC7 — damaged sidecars are `UNKNOWN`, never `FRESH`, and never break the listing.** Six directories
in `fixtures\damaged`, of which **two are healthy**. Run `list-extracts.ps1` over that root **once**
and show all six reported in one run with `$LASTEXITCODE` **0** — that is the check that the
per-directory read actually isolates failures:

1. `.parquet` files, **no `_extract.json`** → `UNKNOWN (no sidecar)` *(invisible to any glob — this is
   why enumeration is `Get-ChildItem -Directory`)*
2. `_extract.json` that is **not valid JSON** → `UNKNOWN (unreadable sidecar)` *(bare `read_json`
   exits 1 for the whole query here; `ignore_errors=true` is refused for non-newline-delimited JSON)*
3. valid JSON, **`materialized_at` missing** → `UNKNOWN`, age NULL, exit 0
4. `source_rows` has **fewer elements than `source_objects`** → `UNKNOWN (parallel array mismatch)`
5. **`materialized_at` unparseable** (`"yesterday"`) → `UNKNOWN (unreadable sidecar)` — a *different*
   code path from case 3, which hard-fails a pinned `TIMESTAMP` read
6. `name` **does not match its directory name** → `UNKNOWN (name mismatch)`

None may report `FRESH`. Then re-run with `$env:DSK_WINDOW_MINUTES='999999'` and confirm the four
damaged ones are still `UNKNOWN` — a huge window must not launder a damaged sidecar into freshness.

**AC8 — the registry lists, orders, and is derived not stored.** Three healthy fixtures in
`fixtures\ages` with distinct `materialized_at`. `list-extracts.ps1` prints all three **newest first**
with `name`, `row_count`, `age_minutes`, `size_bytes`. Use the pinned figures (**15,314** for
`parent_projects`, **42,161** for `dt_projects`) so 2b's real output is comparable. Then **delete one
fixture directory** and re-run: it is gone. A view cannot fake that.

**AC9 — the size report is self-checking and can fail.** The generator writes, in the
`parent_projects` fixture, a filler `data_0_0_0.snappy.parquet` of exactly **380,104** bytes, and two
sidecars declaring `output_bytes`:

- `parent_projects` declares **380,104** → report prints **AGREES**
- a second fixture over the same-size file declares **999,999** → report prints
  **`DISAGREES (declared 999999, on disk 380104)`**

Both outcomes asserted, so the check can fail. Also: each extract's reported bytes equal
`Get-ChildItem <dir> -Recurse -File | Measure-Object -Sum Length`, and the printed **total equals the
sum of the printed parts**.

**AC10 — the ceiling is reported, not acted on.** With `DSK_MAX_AGE_MINUTES` unset (default 1440):
the −1500 fixture carries the `PAST-CEILING` suffix, the −90 one does not. Confirm 2a **mutated
nothing** — the fixture tree's file list and `materialized_at` values are unchanged after the run.

**AC11 — `registry.sql` has no BOM.** First three bytes are not `239,187,191`. *(The read-back half is
deliberately not asserted: a BOM'd sidecar was measured to read fine, so the rule is about the
writer's habit, not a failure it prevents.)*

**AC12 — the schema contract matches the code.** Two commands:

1. Parse field names from `SIDECAR.md`'s table (the backticked token in each row's first cell) into a
   sorted list; run `DESCRIBE SELECT * FROM read_json('<complete fixture>', columns={...})` with
   `-csv`, sort its `column_name` values, and print the **symmetric difference**. Expected: **empty**.
2. Against a fixture omitting `runtime_seconds`, print `runtime_seconds IS NULL`. Expected **`true`**,
   exit 0.

---

## Commit and handoff

Work on branch **`item2a-extract-registry`**. Commit before writing `RESULT-1.md`. Verification runs in
a separate agent against a `git worktree` at that commit; because every check regenerates its own
fixtures via a committed script, the verifier can re-run **all twelve** without Snowflake and without
depending on the implementer's `<project-id>`.

`RESULT-1.md` must give verbatim output per check, the three ages from AC3 with the wrong-value table
(the UTC evidence), both verdicts from AC6, all six lines from AC7's single run, and the final
`SIDECAR.md` field table — that table is what 2b, item 6 and item 8 build against.
