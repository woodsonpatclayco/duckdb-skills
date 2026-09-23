# TASK — Dialect layer: macro file, polyglot routing, and a correctness fixture

Plan: PLAN-1.md (item 1)

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
