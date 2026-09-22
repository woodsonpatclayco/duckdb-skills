# PLAN-1 — Snowflake dialect locally, and Snowflake extracts with a freshness window

## What this is for

Two things Phil asked for, plus one his own experience surfaced mid-design:

1. **Stop stumbling on DuckDB dialect.** Cortex Code writes Snowflake SQL fluently and DuckDB
   SQL badly. Phil has already noticed this in live sessions. Measured below: 24 of 41 common
   Snowflake constructs fail on DuckDB v1.5.5.
2. **Make sessions reach for DuckDB liberally when it's the right tool.** The skills can
   already do the useful patterns; nothing fires them, because no description mentions
   Snowflake results, joining Snowflake data to a workbook, or "several questions about one
   result set".
3. **Guard against acting on stale Snowflake data.** A local extract carries an expiry; a
   session past that window re-pulls rather than answering from the snapshot.

## Measured facts this plan rests on

All verified in-session on 2026-09-22, on this machine.

**Transport — settled, and simpler than first drafted.** The app's built-in Snowflake
connection can land Parquet on local disk with no new dependency:

- `COPY INTO @~/<dir>/ FROM (<query>) FILE_FORMAT=(TYPE=PARQUET)` writes server-side.
- `GET @~/<dir>/ 'file://C:/...'` pulls it to local disk — **verified working** through
  `snowflake_sql_execute`.
- DuckDB then reads it back as `decimal(5,0)`, `decimal(12,2)`, and `'01100'` as VARCHAR
  with the leading zero intact.

Consequences: no `.venv`, no pip dependency, no hardcoded interpreter path, no CSV hop, no
Okta browser prompt (the app session is already authenticated), and **rows never pass through
the conversation** — so the "result too large for context" case genuinely works.

Two gotchas, both verified: `GET` fails `ENOENT` unless the local target directory already
exists, and the stage copy persists until `REMOVE`, so it bills storage if left.

Rejected: the Python connector (needs a venv this repo doesn't have, and pops an Okta browser
window, which would make a "silent" refresh not silent). Rejected: `snow` CLI (not installed,
and has no Parquet output — only CSV, forcing a type-losing hop). Rejected:
`nnnkkk7/snowflake-emulator` — reasoning under item 1.

**Dialect gap — measured, not assumed.** 41 common Snowflake constructs run against DuckDB
v1.5.5: **17 passed, 24 failed.** Every failure is a loud `Catalog Error` at bind time,
before any data is read — never a silently wrong value.

A 17-macro shim closed **15 of 15** function-level failures, with correct values:
`DIV0(10,0)`→`0`, `IFF(NULL,'t','f')`→`f`, `EQUAL_NULL(NULL,NULL)`→`true`,
`TO_VARCHAR(1234.50)` preserving scale. A working seed exists at
`.duckdb-skills/sf-compat.sql`, which is **gitignored** (`.gitignore:3`) — so the evidence
this plan rests on is currently un-backed-up. Item 1 moves both the shim and the construct
fixture to tracked paths.

**How the shim loads — verified, and the obvious approach is broken.** `duckdb -init` accepts
exactly **one** file, and a second `-init` *silently replaces* the first rather than merging:

```
duckdb -init sf-compat.sql -init other.sql -c "SELECT IFF(1>0,'y','n')"
→ Catalog Error: Scalar Function with name iff does not exist!   (other.sql's macro loads fine)
```

Every session-mode call already spends that slot on state — `skills\query\SKILL.md:31,58,66,79,129`
and `skills\attach-db\SKILL.md:143` all pass `-init "$STATE_DIR/state.sql"`. So a shim
delivered as its own `-init` file would pass a standalone acceptance check and be **absent from
every real query**. That is precisely the class of failure Phil cannot detect by reading code.

The working composition, verified: a `.read <path>` line inside `state.sql`, appended
idempotently (state.sql is append-only per `skills\attach-db\SKILL.md:121`). `.read`
**requires forward slashes** — a backslash path fails with `Error: cannot open`. Composed this
way, shim and state macros both resolve in one invocation (returned `shim_ok,7`).

Six constructs are beyond a macro because they are syntax or type level: `NUMBER(38,2)`,
`TOP n`, `MINUS`, `CURRENT_TIMESTAMP()`, `FLATTEN`, `LISTAGG ... WITHIN GROUP`.

**One measured caution, load-bearing for the shim's spec.** The draft `DATEADD` macro returns
`2026-03-15 00:00:00` — a TIMESTAMP, where Snowflake returns a DATE. A 17-line file written
deliberately and tested immediately still drifted on type. So the shim's acceptance checks
must assert **returned types as well as values**, per macro. This is also the whole argument
against the emulator: hundreds of untested mappings, where a mistranslation returns a wrong
number instead of an error.

## Why not the emulator

`nnnkkk7/snowflake-emulator` (Go + DuckDB, v0.0.9, 3 contributors, last release 8 months ago)
does offer the one thing a shim cannot — full dialect including syntax-level constructs. It
is still the wrong trade here:

- A translation layer neither of us can inspect, in front of cost data, failing **silently**
  where the shim's gaps fail loudly.
- Requires Docker running permanently.
- Its HTTP transport replaces `duckdb -f`, discarding the ad-hoc sandboxing already built into
  `skills\query\SKILL.md` step 5.
- Its DuckDB is a separate CGO build, so the `spatial`, `excel`, and `sqlite` extensions
  `read-file` depends on are absent.
- Data must be loaded into its own database file rather than read straight from a Parquet
  extract.

## Design decisions (settled with Phil, 2026-09-22)

**Freshness is a judgment, not a hard gate.** Each extract carries a window and a computed
expiry. The session decides whether the work is staleness-sensitive from the nature of the
data — transactional tables go stale fast, dimensional ones (`DT_PROJECTS`) do not.

**The window follows work mode**, reusing the analysis/dev distinction already governing these
sessions (`AGENTS.md`, "Which mode of work this is"):

| Mode | Default window | Why |
|---|---|---|
| Analysis | **1 hour** | answering from stale numbers is the real risk |
| Dev | **24 hours** | shape matters, currency doesn't; re-pulling is pure cost |

**The reader's mode governs, not the writer's.** Settling the reviewer's blocking ambiguity: a
dev-mode extract with a 24h window, read 3 hours later by an analysis-mode session, is
**stale**. The sidecar records the window it was written with as a fact; the effective window
is passed in by the reading session (`DSK_WINDOW_MINUTES`), so the freshness check is testable
without needing to detect mode.

**Past the window: re-pull silently.** Phil chose this over refuse-and-offer. Bounded so it
cannot compound: **at most one refresh per extract per session**, so one expired file read by
two skills re-pulls once, not twice. Print the sidecar's recorded `row_count` and
`runtime_seconds` *before* refreshing, and report actual elapsed time in one line after. No
prompt at any point.

Stated plainly rather than implied: **the first materialize is unguarded** — it has no prior
runtime to report, so the circular-mitigation gap is documented, not papered over.

**A failed re-pull must not silently fall back to stale data.** If the refresh errors
(expired auth, suspended warehouse, network), report the failure and the extract's age, and do
not present its contents as current. This is the most likely route to the exact outcome the
feature exists to prevent.

**No sidecar = unknown age = stale.** Same principle as `read-memories`, where `chars` and
`matches` exist so a query cannot quietly withhold something. Age is that idea applied to
time.

## Platform constraint — load-bearing

The eight upstream skills are POSIX bash (`test -f`, `$HOME`, `find`, `command -v`, heredocs)
and the README states Windows is unsupported upstream. Only `read-memories` was written for
this machine, and its conventions are the ones to copy:

- Windows / PowerShell 5.1; chain with `;` never `&&`; absolute paths.
- SQL in `.sql` files invoked with `duckdb -f`, **never** inline `-c`, because PowerShell
  expands `$` inside double-quoted strings and breaks any `'$.type'` JSON path.
- Parameters arrive as environment variables set before the call.
- Path comparisons case-insensitive and separator-normalized.

**Verified traps for every acceptance check in this plan:**

- DuckDB writes its `-init` banner to **stderr**, and PowerShell surfaces that as
  `NativeCommandError`. A check that greps output for the bare word `Error` therefore reports
  total failure on a completely working shim — this happened during design and cost a full
  debugging cycle. Match DuckDB's error classes only: `Catalog Error`, `Parser Error`,
  `Binder Error`, `Conversion Error`.
- The exit code, however, **is** trustworthy: a successful `-init` run exits `0`
  (`LASTEXITCODE = 0` verified). The `NativeCommandError` is a pipeline artifact of `2>&1`,
  not a failure signal. Use `2>$null` plus value/type assertions.

## Standing context cost — a constraint on item 4

Nine skill descriptions load at every session start whether used or not, and invoking one
costs 70–208 lines. So routing is **wording**, and the new skill's description is the only
new standing text — budget it at ≤ 4 lines, comparable to `read-memories`. README prose is
free; it is not auto-loaded.

## Items

Sequence is **1 → 2 → 3 → 4**. Items 1 and 2 each leave the repo working and are separately
shippable, so this is staged rather than all-or-nothing. Item 3 needs 1 and 2; item 4 needs 2.
Item 1 goes first because it fixes something Phil hits today and needs nothing else to land.

### 1 — Snowflake dialect compatibility shim

Promotes the verified seed to a tracked file at **`skills\query\sf-compat.sql`**, covering the
15 function-level gaps and documenting the 6 syntax-level constructs it cannot cover so a
session rewrites them rather than retrying blindly.

Delivery, per the verified constraint above: `attach-db` appends a
`.read C:/forward/slash/path/to/sf-compat.sql` line to `state.sql` idempotently. **Not** a
second `-init`. Sessions with an existing `state.sql` must get the line added without
disturbing its ATTACH/LOAD/secret lines.

The construct list becomes a **tracked fixture** — `skills\query\sf-compat-tests.csv`, one row
per construct with `name, sql, expected_value, expected_type`. The existing probe cannot serve
as this fixture: `.duckdb-skills\dialect-probe.ps1:44` decides pass/fail with
`-match 'Error|error:'`, the exact anti-pattern this plan forbids, and it has no expected-value
or expected-type column, so it structurally cannot catch the `DATEADD` drift.

Acceptance: a before/after table over the fixture — pass count rises from 17, **zero
regressions** among the original 17 — with every row asserting **both value and returned type**.
Run through `-init "$STATE_DIR/state.sql"`, the way a session actually invokes it, not against
the shim directly. Fully observable by Phil in one command.

### 2 — the `snowflake-extract` skill

Materialize, sidecar, freshness check, bounded silent refresh. Covers:

- `COPY INTO` Parquet → `GET` into a local directory it creates first → `REMOVE` the stage copy.
- **One directory per extract**, not one file: `COPY INTO` splits output by default
  (`data_0_0_0.snappy.parquet`, …). Queried as `<dir>\*.parquet`, sidecar at
  `<dir>\_extract.json`, and the temp-then-rename is a **directory** rename — which also
  settles the concurrent-refresh torn-file case.
- Stage path convention stated literally, including how an extract name maps to a stage
  subdirectory and what happens when two sessions pick the same name.
- Sidecar fields, named explicitly rather than left to implementation: query text, source
  objects, UTC `materialized_at`, window written, computed expiry, `row_count`, warehouse, and
  **connection name, role, and database** — the same query under a different role returns
  different rows, so a row count is meaningless without them.
- `runtime_seconds` comes from Snowflake, not a shell clock: `TOTAL_ELAPSED_TIME` for the COPY's
  query id via `QUERY_HISTORY_BY_SESSION()`. There is no shell to time, and agent wall-clock
  would measure tool-call overhead rather than query cost. If that lookup proves unreliable,
  drop the field and have the pre-refresh line report `row_count` and bytes instead — but say
  which, because leaving it open is a correction round.
- Sidecar read with `read_json` from a `.sql` file, per the established convention.
- Freshness check whose **first output line is the age**, taking the window as a parameter.
- One extract location, absolute, confirmed gitignored — extracts are production data and must
  never be committable.
- `allowed-tools` must include the Snowflake execute tool. Note the field may be advisory:
  **eight** skills declare `allowed-tools: Bash`, but `read-memories` declares none at all and
  runs `duckdb` fine. So verify by invocation, not by frontmatter.

Acceptance, all naming real values: a known row count matching the sidecar; an age in minutes
from a backdated fixture sidecar; an expiry that actually trips; a missing sidecar treated as
stale; and **one command reporting total extract size on disk**, so unbounded growth is visible.

**The once-per-session refresh cap is documentation, not an enforceable check.** Skills are
stateless shell invocations with no per-session store, so the cap lives in the agent's own
context. Stated here explicitly rather than implied, following the honest precedent at
`skills\read-memories\SKILL.md:15-18`. Nothing in the acceptance list can prove it.

### 3 — a worked end-to-end check

One command Phil runs himself proving the whole path: pull a small real result, land it, query
it locally with Snowflake dialect via the shim, and show the age line. This is the deliverable
that makes items 1 and 2 reviewable by someone who does not read code — and it is the only
check that proves shim and extract **compose**, which is exactly where the `-init` trap bites.

Two requirements so it tests the real path: the DuckDB step must run through
`-init "$STATE_DIR/state.sql"`, and ad-hoc mode's `allowed_paths`
(`skills\query\SKILL.md:90`) must include the extract glob. Verified during design:
`-init` macros do survive the sandbox — `IFF` still resolves after
`SET lock_configuration=true`.

### 4 — routing, so it gets used

Worthless if items 1–3 exist but never fire. The new skill's description names the triggers in
Phil's language: Snowflake result, extract, join Snowflake to Excel, several questions about
one result set. README gains the four patterns and the freshness rule. Tight wording only, per
the context-cost constraint.

Depends on item 2's sidecar format being settled.

## Deliberately not in scope

- **Sidecar awareness inside `read-file` and `query`.** Dropped on the reviewer's argument:
  it cannot be added without touching those skills' bash internals, which would leave them
  half-ported, and they don't run on Windows today anyway — so the change would be
  unobservable on Phil's machine. The extract skill reports age itself.
- **Porting the eight upstream skills to PowerShell.** A real gap, but mixing a Windows port
  into this feature makes both unreviewable.
- **The emulator**, for the reasons above.
- **Scheduled or background refresh.** Refresh happens when a session reads an expired
  extract, never on a timer.
- **Extract retention and cleanup.** No automatic deletion. The size-reporting command in item
  2 makes growth visible; acting on it stays manual.
- **Any write outside this repo**, including under `~/.snowflake/`.
