# TASK — Dialect layer: macro file, polyglot routing, and a correctness fixture

Plan: PLAN-2.md (item 1)

> **Round 2 is open.** The `Plan:` header moved from `PLAN-1.md` to `PLAN-2.md` because round 1
> exposed a factual error in the plan itself. Read `# CORRECTIONS — round 2` at the bottom; where it
> conflicts with the body above, **the corrections win.** The body is left unedited on purpose —
> `RESULT-1.md` was written against it.

**Serves:** Writing SQL against local files without tripping over DuckDB's dialect. Today Cortex Code
writes Snowflake SQL fluently and DuckDB SQL badly — `IFF`, `NVL`, `DIV0`, `TRY_TO_NUMBER`,
`TO_VARCHAR` all fail on DuckDB, and every failure costs a retry round mid-analysis. After this,
those constructs work, the ones that still don't are listed by name, and there is a fixture that
proves which is which by comparing **values and types**, not by the absence of an error message.

Nothing else in PLAN-1 can be built first: items 2–8 all write SQL through this layer.

*Round 1. Revised after `REVIEW-task-1.md`; every fix below was re-measured in-session.*

---

## Why this is a spec and not a one-liner

There are two mechanisms and they are not interchangeable:

- **Macros** are value-correct but structurally limited. They cannot reach syntax (`TOP n`, `MINUS`,
  `NUMBER(38,2)`, `LISTAGG ... WITHIN GROUP`).
- **`polyglot`** transpiles whole statements and reaches all of that — but it is **not transparent**
  (plain `SELECT IFF(...)` still fails; the SQL must be wrapped) and it has a **measured wrong
  translation**: `TRY_TO_NUMBER('abc')` errors where Snowflake returns NULL.

So the deliverable is both mechanisms plus the rule for which to use, and a fixture that can detect
a wrong *value* rather than only a raised error.

---

## Deliverables

Five new files, one edited. **No new skill** — this extends `skills/query/`, so the standing-context
budget (item 8: ≤ 4 description lines per new skill, max two new skills) is untouched. Do not edit
`skills/query/SKILL.md` frontmatter.

| Path | What it is |
|---|---|
| `skills/query/duckdb-compat.sql` | 17 tracked macros |
| `skills/query/duckdb-compat-tests.csv` | 41-row correctness fixture |
| `tools\ensure-duckdb-compat.ps1` | idempotent `.read` delivery into `state.sql` |
| `tools\run-compat-tests.ps1` | three-mode fixture runner |
| `skills/query/duckdb-compat.md` | before/after table, residuals, pinned versions, routing rule |
| `skills/query/SKILL.md` *(edit)* | short routing section, body only |

### 1. `skills/query/duckdb-compat.sql` — 17 macros

Promote the verified local seed at `.duckdb-skills/sf-compat.sql`, which is **gitignored via
`.gitignore:3`** and therefore un-backed-up. Take all 17 of its macros **except `DATEADD`**, leaving
16:

`IFF`, `NVL`, `NVL2`, `ZEROIFNULL`, `NULLIFZERO`, `DIV0`, `DIV0NULL`, `TO_VARCHAR`, `TO_NUMBER`,
`TRY_TO_NUMBER`, `TRY_TO_DATE`, `EQUAL_NULL`, `REGEXP_SUBSTR`, `CHARINDEX`, `LEN`, `UUID_STRING`

Verified in-session: those 16 load and `duckdb_functions()` reports exactly 16.

**`DATEADD` is excluded.** The seed's version returns TIMESTAMP where Snowflake returns DATE — a
silent type drift. It stays out until fixed and type-asserted. Raw DuckDB has no `DATEADD` at all
(`Catalog Error: Scalar Function with name dateadd does not exist! Did you mean "date_add"?`), so
excluding it leaves that construct failing in the macro column, and `polyglot` is its only path.
State that in `duckdb-compat.md` rather than leaving the gap unexplained.

**Add one macro, `xl_date(serial)`** — Excel serial → DATE, so the conversion is named once instead
of retyped per column. The body must produce DATE, not TIMESTAMP; the trailing cast is load-bearing.
Verified: `(DATE '1899-12-30' + to_days(46204::BIGINT))::DATE` → `2026-07-01`, `typeof` = `DATE`.

Total: **17 macros.** File is BOM-free (`[IO.File]::WriteAllText`), never
`Set-Content -Encoding UTF8`.

### 2. `tools\ensure-duckdb-compat.ps1` — delivery, and not via `attach-db`

`skills/attach-db/SKILL.md:111-137` is POSIX bash (`grep -q`, `cat >> <<'STATESQL'`, `mkdir -p`,
`$HOME`) and does not run on this machine. Specifying it as the delivery path would ship macros that
never load. **Touching the eight bash skills is out of scope for this spec.**

`duckdb -init` takes exactly one file and a second `-init` **silently replaces the first** (verified).
Every session-mode call already spends that slot on `state.sql`
(`skills/query/SKILL.md:31,58,66,79,129`; `skills/attach-db/SKILL.md:143`). So delivery is a
`.read` line inside `state.sql`, not a second `-init`.

Behaviour:

- Parameter `-StateFile <absolute path>`, optional.
- **Default resolution is the project-local file only:** `<repo root>\.duckdb-skills\state.sql`,
  created along with its parent if absent. **`<project-id>` and the `$HOME\.duckdb-skills\` branch
  are deliberately out of scope for this spec** — see "Deferred decision" below. Do not invent a
  project-id here.
- **The script's first output line is always the resolved absolute state-file path**, so writing to
  the wrong file is observable rather than silent.
- If any `$HOME\.duckdb-skills\*\state.sql` exists, print a second line:
  `NOTE: home-side state files exist: <paths>. If this session uses one, re-run with -StateFile.`
  Informational; it does not change the exit code.
- Insert `.read <absolute path to duckdb-compat.sql, forward slashes>` as the **first line**.
  Forward slashes are required — a backslash path fails `Error: cannot open` (verified).
- **First line, not appended.** `CREATE OR REPLACE MACRO` lands in the current catalog; after an
  `ATTACH`/`USE` of a read-only database that fails. At line 1 the current catalog is `memory`,
  which is always writable.
- **Idempotent.** Scan every line for an existing `.read` of this file, comparing
  case-insensitively and separator-normalized. Never write a second one.
- **Strip a leading UTF-8 BOM if present** and never write one. PowerShell 5.1's
  `Set-Content -Encoding UTF8` emits bytes 239,187,191, and a BOM ahead of a dot-command breaks it:
  `Parser Error: syntax error at or near "."` / `∩╗┐.read` / `Encountered errors while executing
  init file`. Use `[IO.File]::WriteAllText`.
- Preserve every existing line verbatim.

### 3. `skills/query/duckdb-compat-tests.csv` — the fixture

Replaces `.duckdb-skills/dialect-probe.ps1`, which cannot serve: line 44 decides pass/fail with
`-match 'Error|error:'` — the exact anti-pattern PLAN-1 forbids — and it has no expected-value or
expected-type column, so it counts absence of errors, not correctness.

Columns: `name, sql, expected_value, expected_type, check_mode`. `check_mode` is a fifth column
beyond the four PLAN-1:233 lists; record in `duckdb-compat.md` that it was added and why.

**Contract on `sql`: a complete statement returning exactly one row and exactly one column.** That
is what makes value *and* type assertable uniformly across all three modes. Carry over the probe's
41 construct names and its SQL text, adapted to that contract — e.g.
`SELECT IFF(1>0,'y','n') AS v`, `SELECT value AS v FROM TABLE(FLATTEN(input=>[1,2])) LIMIT 1`.

Adapting must not change **which construct is under test**. Worked example, because the obvious
adaptation is wrong: `GROUP BY position` must become `SELECT a AS v FROM (SELECT 1 a) GROUP BY 1`
(verified: returns `1`). Reducing it to `SELECT count(*) AS v FROM (SELECT 1) GROUP BY 1` moves the
ordinal onto the aggregate and fails `Binder Error: GROUP BY clause cannot contain aggregates!` —
turning a raw-passing construct into a false regression. Where the one-column contract would remove
the column the construct depends on, drop something else instead.

Adding an alias and bounding to one row does not change **whether a construct binds**, so the raw
pass set should be preserved. Prove that rather than assume it — see AC6.

#### Types: the target is DuckDB's rendering of Snowflake's semantics

`expected_value` is **Snowflake's answer**. `expected_type` is the **DuckDB type name that correctly
represents Snowflake's type**, written exactly as `typeof()` renders it — not Snowflake's own type
name, which `typeof()` can never return. So: `DECIMAL(38,6)` not `NUMBER`; `VARCHAR` not
`VARCHAR(10)`; `BIGINT` for integer counts; `INTEGER[]` for `ARRAY`; `STRUCT(a INTEGER)` for
`OBJECT`. Compare as an exact string.

A DuckDB type that is merely *named* differently is not a failure. A DuckDB type that is
*semantically wrong* — a date arriving as TIMESTAMP — is a failure, and is the whole reason
`DATEADD` is excluded from the macro file.

Two rows will never match Snowflake's type name and must be recorded as expected-by-design rather
than as regressions: **`ARRAY_AGG`** (Snowflake `ARRAY`, DuckDB `INTEGER[]`) and
**`OBJECT_CONSTRUCT`** (Snowflake `OBJECT`, DuckDB `STRUCT(a INTEGER)`). Note the latter's `typeof()`
contains a comma and so comes back CSV-quoted.

#### Determinism

**Three rows must be rewritten**, because an expected value cannot be pinned against a moving clock.
`CURRENT_DATE` appears at exactly three places in the probe (lines 11, 13, 15). Swapping it for a
date literal does not change binding:

| Name | Probe SQL | Fixture SQL | expected_value / type |
|---|---|---|---|
| `DATEADD` | `DATEADD('day',1,CURRENT_DATE)` | `...,DATE '2026-07-01'` | `2026-07-02` / `DATE` |
| `DATE_TRUNC str` | `DATE_TRUNC('month',CURRENT_DATE)` | `...,DATE '2026-07-15'` | `2026-07-01` / `DATE` |
| `TO_CHAR fmt` | `TO_CHAR(CURRENT_DATE,'YYYY-MM')` | `...,DATE '2026-07-15',...` | `2026-07` / `VARCHAR` |

**Two further rows are irreducibly non-deterministic** — separate from the three above — and take
`check_mode = type_only`: `CURRENT_TIMESTAMP()` and `SEQ/UNIFORM` (`UNIFORM(1,10,RANDOM())`). Every
other row is `check_mode = value_and_type`.

#### NULL

A row whose Snowflake answer is NULL carries `expected_value` as the four characters `NULL`.
Verified: DuckDB's `-csv` writer renders SQL NULL as `NULL` and the empty string as an empty field,
so the two are distinguishable. Do not pass `-nullvalue`. This matters for `NULLIFZERO(0)`,
`TRY_CAST('x' AS INT)`, the `NVL` family, and `TRY_TO_NUMBER('abc')` — the single case PLAN-1:62-68
exists to protect.

Write the CSV BOM-free, fields double-quoted, internal double quotes doubled.

### 4. `tools\run-compat-tests.ps1` — the runner

Runs every fixture row in three modes and prints a before/after table.

- Parameters: `-Fixture` (default `skills\query\duckdb-compat-tests.csv`), `-CompatFile` (default
  `skills\query\duckdb-compat.sql`), `-Mode raw|macro|polyglot|all` (default `all`),
  `-ExpectedDuckdbVersion` (default `v1.5.5`), `-ExpectedPolyglotVersion` (default `8f1666d`).
- **SQL goes into a temp `.sql` file invoked with `duckdb -f`, never inline `-c`.** PowerShell
  expands `$` inside double-quoted strings. Temp files written BOM-free.
- **Mode definitions.** Raw loads nothing. Macro loads `-CompatFile`. **Polyglot loads
  `-CompatFile` as well**, because that is the shipped configuration a session actually runs — label
  the column `polyglot (macros loaded)` and say so in `duckdb-compat.md`. This is not a neutral
  choice: verified, `SELECT TO_VARCHAR(123) AS v` through `polyglot_query` **fails without the
  macros and returns `123` with them**, which is exactly the composition PLAN-1:57-58 relies on.
- **`LOAD polyglot;` must be the first statement in polyglot mode.** Verified: without it,
  `polyglot_query` fails `Catalog Error: Table Function with name polyglot_query does not exist!`
  and exits 1; with it, exit 0. `duckdb_extensions()` shows `installed=true, loaded=false` — it does
  not autoload.
- Per row and mode, generate this shape. The `tag` literals are required so blocks are
  self-identifying:

  ```
  CREATE OR REPLACE TEMP TABLE _r AS <statement>;
  SELECT 'META' AS tag, count(*) AS n, (SELECT count(*) FROM (DESCRIBE _r)) AS cols FROM _r;
  SELECT 'VAL' AS tag, * FROM _r;
  SELECT 'TYP' AS tag, typeof(COLUMNS(*)) FROM _r LIMIT 1;
  ```

  where `<statement>` is the fixture `sql` in raw and macro modes, and
  `SELECT * FROM polyglot_query('<sql, single quotes doubled>', 'snowflake')` in polyglot mode.
  Verified output shape:

  ```
  tag,n,cols
  META,1,1
  tag,v
  VAL,12.300000
  tag,v
  TYP,"DECIMAL(38,6)"
  ```

- **Parse with `ConvertFrom-Csv` per block, never by splitting on commas** — `typeof()` of a DECIMAL
  contains a comma and is returned CSV-quoted. Identify blocks by the `tag` value, **not by line
  position**: blocks 2 and 3 share the header `v`, and a zero-row or multi-column result changes the
  number of lines per block.
- **Capture stderr to a temp file (`2>$errFile`), never `2>&1` into the pipeline.** Merging turns
  DuckDB's `-init` banner into a PowerShell `NativeCommandError` — the exact trap below. DuckDB
  writes errors to stderr, so without this capture the error-class condition is vacuous.
- **Pass** = exit code 0 **and** no error class in stderr **and** `n` = 1 **and** `cols` = 1 **and**
  type matches `expected_type` **and** (unless `type_only`) value matches `expected_value`.
- **Never decide pass/fail by matching the bare word `Error`.** This already cost one full debugging
  cycle. Treat any stderr line matching `^[A-Za-z ]+Error:` as an error class and quote the first
  such line in the report. Observed classes include `Catalog Error`, `Parser Error`, `Binder Error`,
  `Conversion Error`, `Invalid Input Error`, `Permission Error`, `IO Error`. DuckDB's `-init` banner
  (`-- Loading resources from ...`) is also on stderr and is **not** an error. Exit code remains the
  primary signal.
- **In polyglot mode, emit `polyglot_transpile` output for every row**, pass or fail. PLAN-1 requires
  transpiled SQL to be surfaceable because of the `TRY_TO_NUMBER` class of flaw; a runner that only
  shows it on failure cannot support that discipline. Write it to a file the report points at.
- **Assert the pins first.** Print DuckDB version and `polyglot` `extension_version` from
  `duckdb_extensions()`. Measured this session: DuckDB **v1.5.5** (`d8cdaa33fd`), `polyglot`
  **`8f1666d`**, `install_mode` **REPOSITORY**, `installed_from` **community**. On mismatch against
  the `-Expected*` parameters, print a `PIN DRIFT` banner naming expected and actual and **exit
  non-zero**, with the remedy stated: re-run the fixture and update the pin and the before/after
  table in `duckdb-compat.md`. That is what "pin" means operationally — `polyglot` is a **community**
  extension (unlike `ducklake` and `excel`, which are core), so a rebuild could change transpilation
  silently, the same risk class as the `TRY_TO_NUMBER` flaw.
- **Reject a malformed fixture row** (`cols` ≠ 1) with a message naming the row, rather than
  silently comparing the wrong column.
- Exit 0 only if every row met its expectation in at least the mode the report claims for it;
  non-zero otherwise. An error class may never read as pass.

### 5. `skills/query/duckdb-compat.md`

- The before/after table: one row per construct, columns
  `name | raw | macro | polyglot (macros loaded)`.
- **Raw-set reconciliation by name** against the baseline 17 — see AC6.
- **The residual list: whatever the fixture reports**, not a number asserted in advance. PLAN-1's
  pre-merge list of six was measured against macros alone and is stale. Documented so a session
  rewrites rather than retrying blindly.
- The 17-macro inventory, and why `DATEADD` is absent.
- The type rule, and the two expected-by-design type mismatches (`ARRAY_AGG`, `OBJECT_CONSTRUCT`).
- The pinned versions and what pin drift means.
- That `check_mode` is a fifth fixture column beyond PLAN-1's four, and why.
- That `<project-id>` is deliberately undefined here and is item 2's to settle.
- Routing rule, long form.

### 6. `skills/query/SKILL.md` — body edit only

A short section stating:

- Write plain DuckDB SQL with the macros loaded.
- Reach for `polyglot_query('<sql>','snowflake')` when a construct fails with a `Catalog Error`, or
  when lifting SQL verbatim from Snowflake. **Single quotes inside the wrapped string must be
  doubled**, and **`LOAD polyglot;` is required first** — it does not autoload.
- **`LOAD polyglot;` must come before `SET enable_external_access=false`.** Verified: issued after
  the sandbox `SET` lines it fails `Permission Error: Loading external extensions is disabled
  through configuration`. `SKILL.md:115-119` puts the `SET` lines first, so a session copying that
  block must insert the `LOAD` above them. With that ordering polyglot does run under the ad-hoc
  sandbox — `TOP 1` transpiled and returned `1`.
- **Always surface `polyglot_transpile` output when polyglot runs** — it has a known wrong
  translation, so the transpiled SQL is part of the answer, not debug detail.
- Macros compose *inside* `polyglot_query` (verified: `TO_VARCHAR(123)` → `123` with macros loaded,
  and **fails without them**).
- Macros arrive via `state.sql`, never a second `-init`.
- Pointer to `duckdb-compat.md` for residuals.

---

## Deferred decision — `<project-id>`

PLAN-1:308 says `<project-id>` is *"derived from the project root path, as
`skills/query/SKILL.md:24-27` already does"*. That is `git rev-parse --show-toplevel | tr '/' '-'`,
which on Windows yields `C:-Users-woodsonp-Claude-Dev-duckdb-skills` — **the drive colon survives,
and a colon is not a legal Windows directory name.** The plan's pointer is therefore not
implementable as written, and items 2 and 6 both depend on the term
(`~\.duckdb-skills\<project-id>\extracts\...`, `...\lake.ducklake`).

This spec **does not resolve it** and does not need to: item 1's delivery target is a project-local
`state.sql`. Settling it here would mean defining a term against a frozen plan that says something
different. It belongs in item 2's spec, together with the plan revision that carries it — at which
point the state-file precedence in `SKILL.md:22-25` (which prefers the home-side file when it
exists) also needs deciding.

---

## Out of scope

- **`DATEADD` macro.** Excluded until type-asserted.
- **`<project-id>` and the `$HOME\.duckdb-skills\` state path.** Deferred above.
- **Porting the eight bash skills.** Their bash blocks stay as they are.
- **Deleting or tracking `.duckdb-skills/sf-compat.sql` or `dialect-probe.ps1`.** They stay local and
  gitignored as evidence. No `.gitignore` change. But **nothing may load the seed after this** — the
  `.read` line points at the tracked file (AC4 checks this).
- **Any Snowflake connection.** The fixture is entirely offline.
- **New skills, and any frontmatter/description edit.**
- **Items 2–8.** No extracts, no lakehouse, no workbook reads. `xl_date` ships here because it is a
  macro, not because workbook work starts.

---

## Acceptance checks

Run from the repo root. Every expected value was measured in-session unless marked *derived*.

AC1–AC5 use `duckdb -c` deliberately. PLAN-1:124-126 bans inline `-c` because PowerShell expands
`$` inside double quotes; none of these strings contains a `$`. Generated SQL still goes through a
temp `.sql` file with `-f`.

**AC1 — macro inventory is 17 and `DATEADD` is absent.**

```powershell
duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT count(*) AS n FROM duckdb_functions() WHERE function_type='macro' AND upper(function_name) IN ('IFF','NVL','NVL2','ZEROIFNULL','NULLIFZERO','DIV0','DIV0NULL','TO_VARCHAR','TO_NUMBER','TRY_TO_NUMBER','TRY_TO_DATE','EQUAL_NULL','REGEXP_SUBSTR','CHARINDEX','LEN','UUID_STRING','XL_DATE')"
duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT count(*) AS dateadd FROM duckdb_functions() WHERE function_type='macro' AND upper(function_name)='DATEADD'"
```

Expected: `n` = **17**, `dateadd` = **0**. (The 16-name form returned **16** against the seed this
session, exit 0, banner on stderr so the CSV parses clean.) `-init` here is an isolated check only —
it is **not** the delivery path.

**AC2 — `xl_date` returns DATE, not TIMESTAMP.**

```powershell
duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT xl_date(46204) AS v, typeof(xl_date(46204)) AS t"
```

Expected: `2026-07-01`, `DATE`.

**AC3 — `TRY_TO_NUMBER`, the case polyglot gets wrong.**

```powershell
duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT TRY_TO_NUMBER('12.3') AS v, typeof(TRY_TO_NUMBER('12.3')) AS t, TRY_TO_NUMBER('abc') IS NULL AS abc_null"
```

Expected: `12.300000`, `"DECIMAL(38,6)"` — CSV-quoted, because the type name contains a comma — and
`true`. Do not report the quoting as a mismatch.

**AC4 — delivery is idempotent, BOM-safe, and points at the tracked file.** Use scratch paths under
`.duckdb-skills\ac4\` (already gitignored); do not modify a real `state.sql`. Four runs, printing
`state.sql` after each:

1. Fresh missing `state.sql` → file created, `.read` at line 1.
2. Same file again → **byte-identical**, exactly one `.read` line.
3. A `state.sql` whose only line is an `ATTACH` → `.read` first, **`ATTACH` line intact**, one
   `.read`.
4. A `state.sql` written with `Set-Content -Encoding UTF8` (so it carries BOM bytes 239,187,191) →
   after the run, no BOM, and `duckdb -init <that file> -csv -c "SELECT TO_VARCHAR(1) AS v"` returns
   `1` rather than `Parser Error: syntax error at or near "."`.

Also show the `.read` target resolves to `skills/query/duckdb-compat.sql`, **not**
`.duckdb-skills/sf-compat.sql`, and that the script's first output line is the resolved state path.

**AC5 — a macro resolves the way a session actually invokes it.** Against AC4 case 3's scratch file
(`.read` plus a real `ATTACH`):

```powershell
duckdb -init .duckdb-skills\ac4\state.sql -csv -c "SELECT TO_VARCHAR(123) AS v"
```

Expected `123`. Verified working in this shape (`.read` + `ATTACH` in one file → `123`, exit 0).

**AC6 — the fixture measures correctness, and nothing regressed.** Run
`tools\run-compat-tests.ps1 -Mode all` and report:

- The before/after table, 41 rows, every row asserting **value and returned type** — the first
  correctness-based measurement in this project, since raw 17 / macro 28 / polyglot 36 are
  error-free counts only.
- The **raw pass count, reconciled by name** against this baseline. These 17 names are reproduced
  here because the probe is gitignored and a verifier in a clean worktree cannot run it:

  `IFNULL, QUALIFY, DATEDIFF, DATE_TRUNC str, TRY_CAST, LISTAGG, VARCHAR(n), ILIKE, GROUP BY
  position, ARRAY_AGG, SPLIT_PART, POSITION IN, MEDIAN, PERCENTILE_CONT, QUALIFY+PARTITION,
  CONCAT_WS, IS DISTINCT FROM`

  If the count is not 17, name every construct that moved and why. A bare number is not
  reconciliation; a justified difference is acceptable, an unexplained one is not.
- **Zero regressions:** no construct that passes raw fails in **both** macro and polyglot.
- Expected shape: raw = **17**; macro ≥ **28**; polyglot ≥ **36** *(derived — the 28/36 figures are
  prior error-free counts, so a type-asserted run may land lower; a shortfall must be explained per
  construct, not merely reported)*.
- The residual list — constructs no mode reaches — copied into `duckdb-compat.md`.
- The `PIN` line showing DuckDB **v1.5.5** and polyglot **`8f1666d`**.
- Exit code 0.

**AC7 — the one-column contract is enforced, not assumed.** Run the runner against a scratch fixture
at `.duckdb-skills\ac7\bad-fixture.csv` holding one deliberately malformed row
(`SELECT 1 AS a, 2 AS b`). Expected: a message naming that row and a non-zero exit — not a silent
comparison against the first column. Verified that the shape does surface it: `META,1,2`.

**AC8 — the `Error`-matching trap is actually avoided.** Behavioural, not a grep: macro mode must
report a pass count of **at least 20**. Under bare `Error` matching every macro row fails, because
the `-init` banner reaches stderr and PowerShell raises `NativeCommandError` — reproduced in this
session's own output. A healthy macro column is proof the runner matches error *classes*. Also
confirm the runner contains no bare-word `Error` match; the grep supports the behavioural check, it
does not replace it.

**AC9 — pin drift fails loudly.** Parameter only, so a verifier in a clean worktree can run it:

```powershell
tools\run-compat-tests.ps1 -ExpectedPolyglotVersion deadbee
```

Expected: a `PIN DRIFT` banner naming expected `deadbee` and actual `8f1666d`, the remedy line, and a
non-zero exit.

---

## Commit and handoff

Work on branch **`item1-dialect-layer`**. Commit there before writing `RESULT-1.md`. Verification
runs in a separate agent against a `git worktree` at that commit, so uncommitted work is invisible
to it.

`RESULT-1.md` must include the AC6 before/after table and the AC6 raw-set reconciliation inline —
those are the two outputs Phil reads to judge whether the dialect problem is actually fixed.

---

# CORRECTIONS — round 2

Round 1 shipped working machinery with a dishonest fixture. `VERIFY-1.md` returned **DO NOT SHIP**,
and it was right: two rows asserted what the macro produces as if it were Snowflake's answer, which
is precisely what this deliverable exists to prevent. Both were then checked against a live
Snowflake connection and both defects are confirmed real.

**Nothing about the runner, the delivery script, or the macro-loading mechanics needs to change.**
Every mechanical claim in `RESULT-1.md` was independently reproduced, the value/type comparison is
live (mutation-tested two ways), and the `DATE_TRUNC str` discovery is a genuine finding that the
old error-only probe could never have made. Keep all of it. What changes is fixture **content**, and
one macro.

## C1 — `TO_NUMBER` and `TRY_TO_NUMBER` must be scale 0, not scale 6

Measured on CLAYCO-DATAHUB, with `SYSTEM$TYPEOF()`:

| Expression | Snowflake value | Snowflake type |
|---|---|---|
| `TRY_TO_NUMBER('12.3')` | `12` | `NUMBER(38,0)` |
| `TO_NUMBER('12.3')` | `12` | `NUMBER(38,0)` |
| `TRY_TO_NUMBER('abc')` | `NULL` | — |

Snowflake's `TO_NUMBER` / `TRY_TO_NUMBER` default to `NUMBER(38,0)`: no fractional digits, rounded
half-away-from-zero. The seed's `DECIMAL(38,6)` silently **preserves** decimals production rounds
away — on cost data, a query ported from Snowflake returns `12.3` locally where production returns
`12`.

**Change both macros to `DECIMAL(38,0)`.** Verified that DuckDB then agrees with Snowflake on every
case tested:

| input | Snowflake | DuckDB `TRY_CAST(x AS DECIMAL(38,0))` |
|---|---|---|
| `'12.3'` | `12` | `12` |
| `'12.7'` | `13` | `13` |
| `'-12.7'` | `-13` | `-13` |
| `'12.5'` | `13` | `13` |
| `''` | `NULL` | `NULL` |
| `'abc'` | `NULL` | `NULL` |
| `'1e3'` | `1000` | `1000` |

`typeof` = `DECIMAL(38,0)`, which is the DuckDB rendering of `NUMBER(38,0)`.

**AC3 in the body above is wrong and is superseded.** It asserted `12.300000` / `DECIMAL(38,6)`,
which is the seed's behaviour, not Snowflake's. This was a spec defect, not an implementation one —
the implementer built exactly what it was told.

## C2 — every fixture row declares where its expectation came from

Add **two** columns: `source` (sixth) and `note` (seventh, empty unless `source = deviation`). The
header becomes `name, sql, expected_value, expected_type, check_mode, source, note`. The runner reads
the fixture with `Import-Csv`, so extra columns need no parser change.

`source` is exactly one of:

- **`snowflake`** — the expectation is Snowflake's answer, taken from the measured table in C7.
- **`deviation`** — the value is equal but DuckDB's **type kind** differs and cannot be reproduced:
  fixed-point → floating (`NUMBER(4,3)` → `DOUBLE`), `ARRAY` → `INTEGER[]`, `OBJECT` → `STRUCT`,
  `VARIANT` → a concrete type, or a precision that varies with input precision. **Requires a
  non-empty `note` naming exactly what differs.**
- **`duckdb-native`** — no Snowflake equivalent exists. Only `xl_date` qualifies.

### The line `deviation` may not cross

A length or precision difference inside the **same** type kind is not a deviation at all — it is the
canonical rendering the body's type rule already defines (`VARCHAR(10)` → `VARCHAR`,
`NUMBER(9,0)` → `BIGINT`). Those rows stay `snowflake`. Do not reclassify them; if you do, the
verified count becomes meaningless because two readers will disagree by a dozen rows.

**A row whose value differs, or whose type difference would produce a wrong answer downstream, is
never a `deviation`.** It keeps `source = snowflake`, keeps Snowflake's answer as its expectation, and
**fails**, appearing in the residual list. A row may not move from the residual list into the
`deviation` set.

`DATE_TRUNC str` is the worked counter-example. Snowflake returns `2026-07-01` / `DATE`; DuckDB
returns `2026-07-01 00:00:00` / `TIMESTAMP`. Both are temporal types, so a loose reading of "type kind
differs" would admit it — and admitting it would convert the single most valuable finding of round 1
into a pass. It stays `snowflake` and stays failing. See C3.

### Numeric values compare numerically

Snowflake's fixed-point scale makes several expectations render differently from DuckDB's while being
the same number: `MEDIAN(1)` is `1.000` on Snowflake and `1.0` on DuckDB. **When both the expected and
actual values parse as decimal, compare numerically; otherwise compare as strings.** Without this the
value check degenerates into a formatting check, and the only way to pass would be to copy DuckDB's
rendering — the defect this round exists to remove. Type comparison stays an exact string match.

### The `deviation` set

Exactly these, each with a `note`: `DIV0`, `DIV0NULL`, `ARRAY_AGG`, `OBJECT_CONSTRUCT`, `MEDIAN`,
`PERCENTILE_CONT`, `RATIO_TO_REPORT`, `FLATTEN`. Every one is justified by a measurement in C7. Any
addition beyond these eight must be named in `RESULT-2.md` with its Snowflake measurement and its
reason.

`CURRENT_TIMESTAMP()` and `SEQ/UNIFORM` stay `check_mode = type_only` and `source = snowflake`:
`TIMESTAMP_LTZ(9)` → `TIMESTAMP WITH TIME ZONE` and `NUMBER(2,0)` → `BIGINT` are canonical renderings.

## C3 — `DATE_TRUNC str` keeps its `DATE` expectation

Confirmed live: Snowflake's `DATE_TRUNC('month', DATE '2026-07-15')` returns `2026-07-01` typed
`DATE`. DuckDB returns `TIMESTAMP` for `month`, `year`, `day` and `week`, polyglot's transpile is a
pass-through to the same function, and there is no macro seam. **Do not weaken this row to
`TIMESTAMP` to make it pass.** It is a true residual and the fixture is working correctly by failing
it in all three modes.

It follows that **raw = 16, not 17, is the correct number** and the body's AC6 expectation of 17 is
superseded. The 17th construct was only ever passing because the old probe never checked types.

## C4 — report the counts three ways, split by honesty

The single pass count now overstates correctness, because `deviation` rows pass on a relaxed
expectation. The runner must report, per mode: **verified** (passes whose `source` is `snowflake`),
**deviation** (passes on a `deviation` or `duckdb-native` row), and **fail**. The three sum to the row
total.

The before/after table in `duckdb-compat.md` gains the `source` column so the distinction is visible
where the numbers are read, and `VERIFY-1.md`'s finding — that at least 2 of 26 macro passes and 1 of
33 polyglot passes were false positives — is recorded there as the reason the split exists.

## C5 — the console header label

Non-blocking, from `VERIFY-1.md`: the runner's stdout header prints `polyglot` where the spec asks for
`polyglot (macros loaded)`. The correct label is already in `duckdb-compat.md`. Fix the header.

## C6 — three more macros are wrong, and seven were never tested at all

C2 audits the fixture; **seven of the 17 shipped macros have no fixture row**, so a defect in them is
structurally invisible. `DIV0NULL`, `TO_NUMBER`, `TRY_TO_DATE`, `CHARINDEX`, `LEN`, `UUID_STRING` and
`xl_date` ship untested. Three carry real defects, all measured on both engines:

**`REGEXP_SUBSTR` returns `''` where Snowflake returns NULL.** Snowflake's no-match answer is NULL
(measured: `IS_NULL`); DuckDB's `regexp_extract('abc','[0-9]+')` returns the empty string. DuckDB's
CSV writer distinguishes NULL from empty, so this is a silently different answer that changes
`COUNT()`, `IS NULL` filters and `NVL` chains. The existing fixture row only tests the matching case,
so it passes and the defect ships. **Fix, verified:**

```sql
CREATE OR REPLACE MACRO REGEXP_SUBSTR(s, p) AS
  CASE WHEN regexp_matches(s, p) THEN regexp_extract(s, p) END;
```

Measured: match → `123`, no-match → NULL, `typeof` → `VARCHAR`. Add a no-match fixture row and keep
the matching one.

**`UUID_STRING()` returns type `UUID`, not VARCHAR.** Snowflake returns `VARCHAR(36)`. This is the
same disqualifying class as the TIMESTAMP drift that excluded `DATEADD`. **Fix, verified:**
`CAST(uuid() AS VARCHAR)` → `typeof` `VARCHAR`, length 36.

**`TRY_TO_DATE` disagrees with Snowflake on all-digit strings — the exact shape this project's
workbook data uses.** Measured: Snowflake `TRY_TO_DATE('46204')` = **`1970-01-01`** (it reads digit
strings as an epoch offset); DuckDB `TRY_CAST('46204' AS DATE)` = **NULL**. Both agree on
`'2026-07-01'`. **Do not "fix" this and do not weaken the expectation.** Record Snowflake's answer,
let the row fail, and document it in `duckdb-compat.md` as a known divergence — with the consequence
stated plainly: **`xl_date()` is the correct tool for Excel serials and `TRY_TO_DATE` must not be used
for them**, because on Snowflake `46204` silently becomes a 1970 date rather than NULL. PLAN-2's
workbook section is built on serial `46204`, so this matters to item 4.

**`DIV0` / `DIV0NULL` value correctness is reachable** — the body left this as "if you can", which is
not an instruction. **Fix, verified:**

```sql
CREATE OR REPLACE MACRO DIV0(a, b) AS CAST(CASE WHEN b = 0 THEN 0 ELSE a / b END AS DECIMAL(38,6));
CREATE OR REPLACE MACRO DIV0NULL(a, b) AS CAST(CASE WHEN b = 0 OR b IS NULL THEN 0 ELSE a / b END AS DECIMAL(38,6));
```

DuckDB's `/` always yields DOUBLE even with a decimal operand, so the outer cast is required.
Measured: `DIV0(1,0)` → `0.000000`, `DIV0(10,4)` → `2.500000`, `typeof` → `DECIMAL(38,6)`,
`DIV0NULL(1,NULL)` → `0.000000`. Values now match Snowflake exactly; only the precision digit
(`NUMBER(7,6)`/`NUMBER(8,6)`) is unreachable, which is what makes these `deviation` rows.

**Add a fixture row per untested macro.** Nine new rows, expectations from C7:

| name | sql | expected_value | expected_type | source |
|---|---|---|---|---|
| `DIV0NULL` | `SELECT DIV0NULL(1,NULL) AS v` | `0.000000` | `DECIMAL(38,6)` | deviation |
| `TO_NUMBER` | `SELECT TO_NUMBER('12.3') AS v` | `12` | `DECIMAL(38,0)` | snowflake |
| `TRY_TO_DATE serial` | `SELECT TRY_TO_DATE('46204') AS v` | `1970-01-01` | `DATE` | snowflake |
| `TRY_TO_DATE iso` | `SELECT TRY_TO_DATE('2026-07-01') AS v` | `2026-07-01` | `DATE` | snowflake |
| `CHARINDEX` | `SELECT CHARINDEX('b','abc') AS v` | `2` | `BIGINT` | snowflake |
| `LEN` | `SELECT LEN('abc') AS v` | `3` | `BIGINT` | snowflake |
| `UUID_STRING` | `SELECT UUID_STRING() AS v` | *(type_only)* | `VARCHAR` | snowflake |
| `REGEXP_SUBSTR no match` | `SELECT REGEXP_SUBSTR('abc','[0-9]+') AS v` | `NULL` | `VARCHAR` | snowflake |
| `xl_date` | `SELECT xl_date(46204) AS v` | `2026-07-01` | `DATE` | duckdb-native |

**The fixture is 50 rows from this round on** (41 + 9). Use 50 in AC10 and AC11.

## C7 — Snowflake measurements, supplied rather than delegated

The body lists "any Snowflake connection" as out of scope and says the fixture is entirely offline.
**That bullet is superseded for expectations only.** The measurements were taken in the main session on
CLAYCO-DATAHUB with `SYSTEM$TYPEOF()` and are reproduced here as facts. **Do not re-derive them, and
do not infer any expectation from DuckDB's output.** The `[SBn]`/`[LOB]` suffixes are Snowflake
internal storage hints and are not part of the type.

| construct | Snowflake value | Snowflake type | canonical DuckDB `expected_type` |
|---|---|---|---|
| `IFF(1>0,'y','n')` | `y` | `VARCHAR(1)` | `VARCHAR` |
| `NVL(NULL,'x')` | `x` | `VARCHAR(134217728)` | `VARCHAR` |
| `NVL2(NULL,'a','b')` | `b` | `VARCHAR(1)` | `VARCHAR` |
| `IFNULL(NULL,1)` | `1` | `NUMBER(1,0)` | `INTEGER` |
| `ZEROIFNULL(NULL)` | `0` | `NUMBER(2,0)` | `INTEGER` |
| `NULLIFZERO(0)` | `NULL` | `NUMBER(1,0)` | `INTEGER` |
| `DECODE(1,1,'a',2,'b','c')` | `a` | `VARCHAR(1)` | `VARCHAR` |
| `DIV0(1,0)` | `0.000000` | `NUMBER(7,6)` | `DECIMAL(38,6)` *(deviation)* |
| `DIV0(10,4)` | `2.500000` | `NUMBER(8,6)` | `DECIMAL(38,6)` *(deviation)* |
| `DIV0NULL(1,NULL)` | `0.000000` | `NUMBER(7,6)` | `DECIMAL(38,6)` *(deviation)* |
| `DATEADD('day',1,DATE '2026-07-01')` | `2026-07-02` | `DATE` | `DATE` |
| `DATEDIFF('day',…)` | `31` | `NUMBER(9,0)` | `BIGINT` |
| `DATE_TRUNC('month',DATE '2026-07-15')` | `2026-07-01` | `DATE` | `DATE` |
| `TO_VARCHAR(123)` | `123` | `VARCHAR` | `VARCHAR` |
| `TO_CHAR(DATE '2026-07-15','YYYY-MM')` | `2026-07` | `VARCHAR` | `VARCHAR` |
| `TRY_CAST('x' AS INT)` | `NULL` | `NUMBER(38,0)` | `INTEGER` |
| `TRY_TO_NUMBER('12.3')` | `12` | `NUMBER(38,0)` | `DECIMAL(38,0)` |
| `TO_NUMBER('12.3')` | `12` | `NUMBER(38,0)` | `DECIMAL(38,0)` |
| `TRY_TO_DATE('46204')` | `1970-01-01` | `DATE` | `DATE` |
| `TRY_TO_DATE('2026-07-01')` | `2026-07-01` | `DATE` | `DATE` |
| `LISTAGG(x,',')` | `a,b` | `VARCHAR(134217728)` | `VARCHAR` |
| `EQUAL_NULL(NULL,NULL)` | `TRUE` | `BOOLEAN` | `BOOLEAN` |
| `'1'::NUMBER(10,2)` | `1.00` | `NUMBER(10,2)` | `DECIMAL(10,2)` |
| `CAST(1 AS NUMBER(38,2))` | `1.00` | `NUMBER(38,2)` | `DECIMAL(38,2)` |
| `CAST('a' AS VARCHAR(10))` | `a` | `VARCHAR(10)` | `VARCHAR` |
| `'A' ILIKE 'a'` | `TRUE` | `BOOLEAN` | `BOOLEAN` |
| `RATIO_TO_REPORT(1) OVER ()` | `1.000000` | `NUMBER(7,6)` | `DOUBLE` *(deviation)* |
| `ARRAY_AGG(1)` | `[1]` | `ARRAY` | `INTEGER[]` *(deviation)* |
| `OBJECT_CONSTRUCT('a',1)` | `{"a":1}` | `OBJECT` | `STRUCT(a INTEGER)` *(deviation)* |
| `FLATTEN(...).value` | `1` | `VARIANT` | `INTEGER` *(deviation)* |
| `CURRENT_TIMESTAMP()` | *(clock)* | `TIMESTAMP_LTZ(9)` | `TIMESTAMP WITH TIME ZONE` |
| `SPLIT_PART('a.b','.',1)` | `a` | `VARCHAR(3)` | `VARCHAR` |
| `REGEXP_SUBSTR('abc123','[0-9]+')` | `123` | `VARCHAR` | `VARCHAR` |
| `REGEXP_SUBSTR('abc','[0-9]+')` | **`NULL`** | `VARCHAR` | `VARCHAR` |
| `POSITION('b' IN 'abc')` | `2` | `NUMBER(9,0)` | `BIGINT` |
| `MEDIAN(1)` | `1.000` | `NUMBER(4,3)` | `DOUBLE` *(deviation)* |
| `PERCENTILE_CONT(0.5) …` | `1.000` | `NUMBER(4,3)` | `DOUBLE` *(deviation)* |
| `UNIFORM(1,10,RANDOM())` | *(random)* | `NUMBER(2,0)` | `BIGINT` |
| `CONCAT_WS('-','a','b')` | `a-b` | `VARCHAR(3)` | `VARCHAR` |
| `1 IS DISTINCT FROM NULL` | `TRUE` | `BOOLEAN` | `BOOLEAN` |
| `UUID_STRING()` | *(random)* | `VARCHAR(36)` | `VARCHAR` |
| `LEN('abc')` | `3` | `NUMBER(18,0)` | `BIGINT` |
| `CHARINDEX('b','abc')` | `2` | `NUMBER(9,0)` | `BIGINT` |

`TRY_TO_NUMBER` rounding, measured on both engines and in agreement: `'12.3'`→`12`, `'12.7'`→`13`,
`'-12.7'`→`-13`, `'12.5'`→`13`, `''`→NULL, `'abc'`→NULL, `'1e3'`→`1000`.

Structural constructs (`QUALIFY`, `QUALIFY+PARTITION`, `GROUP BY position`, `TOP n`, `MINUS`,
`LISTAGG WITHIN GROUP`, `VARCHAR(n)`) return the integer or string literal they select, typed
`NUMBER(1,0)` → `INTEGER` or `VARCHAR(n)` → `VARCHAR`. Their existing expectations are already correct
and need no change beyond setting `source = snowflake`.

## Revised acceptance checks for round 2

AC1, AC2, AC4, AC5, AC7, AC8, AC9 are **unchanged and already passed independently** — re-run them to
confirm no regression, but they are not the point of this round.

**AC6 is superseded by AC11.** Its derived `macro ≥ 28` / `polyglot ≥ 36` figures are **retired**: they
were error-free counts from the old probe, never recorded per construct, and `RESULT-1.md` showed they
cannot be reconciled exactly. Do not measure against them and do not report a shortfall against them.
AC6's other outputs — the before/after table, the residual list, the PIN line — move into AC11
unchanged, now carrying the `source` column.

**AC3-R2 (supersedes AC3).**

```powershell
duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT TRY_TO_NUMBER('12.3') AS v, typeof(TRY_TO_NUMBER('12.3')) AS t, TRY_TO_NUMBER('12.7') AS r, TRY_TO_NUMBER('-12.7') AS rn, TRY_TO_NUMBER('abc') IS NULL AS abc_null, TO_NUMBER('12.3') AS tn"
duckdb -init skills\query\duckdb-compat.sql -csv -c "SELECT DIV0(1,0) AS a, DIV0(10,4) AS b, typeof(DIV0(10,4)) AS t, DIV0NULL(1,NULL) AS c, REGEXP_SUBSTR('abc123','[0-9]+') AS m, REGEXP_SUBSTR('abc','[0-9]+') IS NULL AS nomatch_null, typeof(UUID_STRING()) AS u, length(UUID_STRING()) AS ulen"
```

Expected, first line: `12`, `"DECIMAL(38,0)"`, `13`, `-13`, `true`, `12`. Second line: `0.000000`,
`2.500000`, `"DECIMAL(38,6)"`, `0.000000`, `123`, `true`, `VARCHAR`, `36`. Every value matches a C7
measurement.

**AC10 — no row carries an unmarked or unjustified expectation.**

```powershell
duckdb -csv -c "SELECT source, count(*) AS n FROM read_csv('skills/query/duckdb-compat-tests.csv') GROUP BY 1 ORDER BY 1"
duckdb -csv -c "SELECT name, source, note FROM read_csv('skills/query/duckdb-compat-tests.csv') WHERE source <> 'snowflake' ORDER BY name"
duckdb -csv -c "SELECT count(*) AS unclassified FROM read_csv('skills/query/duckdb-compat-tests.csv') WHERE source IS NULL OR source NOT IN ('snowflake','deviation','duckdb-native') OR (source='deviation' AND (note IS NULL OR note=''))"
```

Expected: `deviation` = **8**, `duckdb-native` = **1**, `snowflake` = **41**, total **50**; the second
command lists exactly `ARRAY_AGG`, `DIV0`, `DIV0NULL`, `FLATTEN`, `MEDIAN`, `OBJECT_CONSTRUCT`,
`PERCENTILE_CONT`, `RATIO_TO_REPORT` with non-empty notes, plus `xl_date` as `duckdb-native`;
`unclassified` = **0**.

Then run `git diff skills/query/duckdb-compat-tests.csv` and, for **every** row whose `expected_value`
or `expected_type` changed from round 1, quote the C7 line that justifies it. A changed expectation
with no measurement beside it is the round-1 defect recurring.

**AC11 — the three-way split, reconciled row by row.** Run `tools\run-compat-tests.ps1 -Mode all`.
Expected: three counts per mode summing to **50**, plus a reconciliation table against `RESULT-1.md`'s
per-row verdicts naming **every** row whose verdict or classification changed, with the reason.

The one figure derivable in advance, so a mismatch is visible: **raw verified over the original 41
rows = 15.** Round 1 recorded 16 raw passes; `ARRAY_AGG` is one of them and is now a `deviation` row,
so it is not a verified pass. C3's "raw = 16" is the *pass* count, not the verified count.

Macro and polyglot verified counts are reported as measured and **will be lower than round 1's 26 and
33** — that is the correction working. But a bare count is not acceptable: every point of difference
must be attributable to a named row, either reclassified to `deviation` or corrected by C1/C6. Any
residue that cannot be attributed to a named row must be reported as an unexplained gap.

**AC12 — the fixture still catches a wrong answer.** On a copy under `.duckdb-skills\ac12\`, using the
same rows `VERIFY-1.md` used so the movement is comparable: set `IFNULL`'s `expected_value` to `999`
and confirm it flips to FAIL with raw verified 15 → 14; separately set `QUALIFY`'s `expected_type` to
`VARCHAR` and confirm the same movement. Never mutate the tracked fixture.

**AC13 — a semantic failure cannot be relabelled into a pass.** This is the guard on C2, and without
it `deviation` is a one-word fix for any failing row. On a copy under `.duckdb-skills\ac13\`, set
`DATE_TRUNC str` to `source=deviation`, `expected_type=TIMESTAMP`, `note=x`, and run `-Mode all`.
Expected: the row is **not** counted as verified in any mode, and `DATE_TRUNC str` still appears in the
residual list. State in `RESULT-2.md` which mechanism produced that outcome — an explicit rejection in
the runner, or the row failing on value (`2026-07-01` vs `2026-07-01 00:00:00`). Either is acceptable;
an unexamined pass is not.

## What must not change

- The runner's **tag-block** parsing, stderr handling, error-class matching, pin assertion,
  malformed-row rejection, and `polyglot_transpile` emission. All verified working. C4's counting
  split and C2's numeric value comparison are the only runner changes in scope.
- `tools\ensure-duckdb-compat.ps1` in full. AC4's four cases and AC5 all passed independently.
- The exclusion of `DATEADD`, and `xl_date` returning `DATE`.
- `skills/query/SKILL.md`'s frontmatter — still untouched.
- The `<project-id>` deferral. `PLAN-2.md` now defines the term, but item 1 still writes only to the
  project-local `state.sql` and still prints the path it resolved. Do not implement the home-side
  branch in this round.

## Handoff

Same branch, `item1-dialect-layer`. Commit before writing `RESULT-2.md`. `RESULT-2.md` must include
the 50-row table with each row's `source`, the three-way counts per mode, the AC11 reconciliation, and
the verbatim output of AC3-R2, AC10, AC11, AC12 and AC13.
