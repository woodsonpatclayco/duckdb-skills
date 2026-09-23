# REVIEW — TASK.md round 1 (item 1, dialect layer)

Reviewer: `task-reviewer`. Verdict: **NOT READY** — eleven blocking items, all wording fixes with
replacement text supplied; none required rethinking the plan. All eleven applied in the revision.

The reviewer ran read-only DuckDB probes, which is where most of the value came from — three of the
findings were factual errors in the spec, not ambiguity.

## Blocking issues found (all fixed)

| # | Issue | Fix applied |
|---|---|---|
| B1 | `expected_type` defined as **Snowflake's** type name, which `typeof()` can never return. At least ten of the raw-17 would fail type assertion in every mode, making AC6's "zero regressions" and "counts strictly greater than raw" unachievable. Internally contradictory with AC2 (`DATE`) and AC3 (`DECIMAL(38,6)`), both DuckDB names. | `expected_type` is now the DuckDB type name that correctly *represents* Snowflake's type, as `typeof()` renders it. Semantically wrong types (date → TIMESTAMP) still fail. |
| B2 | **`LOAD polyglot;` appeared nowhere.** Verified: without it, `Catalog Error: Table Function with name polyglot_query does not exist!`, exit 1. As written, polyglot mode failed all 41 rows and deliverable 6 shipped a broken recipe. Second half: `LOAD` must precede `SET enable_external_access=false`, else `Permission Error`. `SKILL.md:115-119` puts the `SET` lines first. | `LOAD polyglot;` mandated as first statement in polyglot mode; ordering constraint stated in deliverable 6. |
| B3 | Polyglot mode never said whether the macro file is loaded — and it changes the answer. Verified: `TO_VARCHAR(123)` through `polyglot_query` **fails without macros, returns `123` with them**. Two implementers would produce different columns. | Polyglot mode loads the compat file; column labelled `polyglot (macros loaded)`. |
| B4 | The spec's own fixture example was **invalid SQL**: `SELECT count(*) AS v FROM (SELECT 1) GROUP BY 1` → `Binder Error: GROUP BY clause cannot contain aggregates!`. `GROUP BY position` is a raw-17 passer, so following the example literally records a false regression. | Replaced with the verified `SELECT a AS v FROM (SELECT 1 a) GROUP BY 1`, plus a rule about adaptations that change which ordinal resolves. |
| B5 | "Four rows must be rewritten" — only three listed. `CURRENT_DATE` appears at exactly three places in the probe. | Corrected to three; the two `type_only` rows called out as separate. |
| B6 | How a NULL expectation is written was never stated — and NULL is the plan's headline case (`TRY_TO_NUMBER('abc')`). | `expected_value` = the four characters `NULL`; verified DuckDB `-csv` renders NULL as `NULL` and empty string as an empty field. |
| B7 | AC6 demanded reconciliation against "the probe's original 17", but those names are nowhere in the spec and the probe is gitignored — a verifier in a clean worktree could not run the check. | All 17 names pasted into AC6. |
| B8 | The four-statement runner shape runs, but the spec said nothing about **parsing** it, and the obvious parse breaks three ways: blocks 2 and 3 share the header `v`; `DECIMAL(38,6)` comes back CSV-quoted so comma-splitting fails; zero-row results shift line positions. | Mandated self-labelling `tag` literals (`META`/`VAL`/`TYP`) and `ConvertFrom-Csv` per block, never comma splitting or line position. |
| B9 | Error capture unspecified. DuckDB writes errors to **stderr**, so the error-class condition was vacuous; and the natural idiom `2>&1` is the exact `NativeCommandError` trap the spec warns about two lines later. Class list also missing `Permission Error`, `IO Error`. | `2>$errFile`, never `2>&1`; treat `^[A-Za-z ]+Error:` as a class; `-init` banner explicitly not an error. |
| B10 | AC9 permitted an uncommitted one-line edit — invisible to a worktree verifier, so it returns NOT RUN. | Parameter only: `-ExpectedPolyglotVersion deadbee`. |
| B11 | `<project-id>` inverted `SKILL.md:22-25`'s precedence (home wins there, not project-local), so the script could write to the file sessions don't use — with every AC still passing. And the transform was wrong: `tr '/' '-'` leaves the drive colon, which is not a legal Windows directory name, so PLAN-1:308's pointer is unimplementable. | Removed `<project-id>` from this spec entirely; default resolution is project-local only; script prints the resolved path and notes any home-side state files. The term is deferred to item 2, with the conflict documented under "Deferred decision". |

## Non-blocking improvements (applied)

Macro count wording (17 minus `DATEADD` leaving 16); justification for AC1–AC5 using `-c` against
PLAN-1's ban; scratch paths named in AC4/AC7; `check_mode` recorded as a fifth column beyond
PLAN-1's four; branch named; `ARRAY_AGG` and `OBJECT_CONSTRUCT` named as expected-by-design type
mismatches; AC3 CSV-quoting note; AC5 pointed at AC4's scratch file; AC6 given an expected shape;
AC8 threshold raised from "non-zero" to ≥ 20.

Also applied outside the spec: PLAN-1's `DRAFT, not frozen` banner was stale once `TASK.md` named it.
Corrected in place — it alters no instruction, so it is a clarification rather than a `PLAN-2`.

## Drift from PLAN-1

- **Omission: none.** All five of item 1's acceptance bullets (PLAN-1:245-254) map to ACs, plus the
  pin requirement (228-231) and the `polyglot_transpile` discipline (224-225).
- **Real drift: `<project-id>`.** PLAN-1:308 points at an unimplementable derivation. Resolved by
  removing it from this spec rather than redefining a term against a frozen plan. Item 2's spec must
  settle it and carry the plan revision.
- **Silent expansion, minor:** the `-Mode` runner and `duckdb-compat.md` are not named in item 1,
  though both are implied by what it demands.
- **No non-goal violated.**

## What the reviewer said to leave alone

The two-mechanism framing; excluding `DATEADD` with the reason stated; refusing the `attach-db` bash
path with the POSIX constructs named; `.read` at line 1 with the read-only-catalog rationale; every
BOM and forward-slash detail in AC4 (reproduced character-for-character, including `∩╗┐.read`);
AC8's behavioural framing of the `Error` trap; the four pinned versions; the "Out of scope" section.

## Scope

Keep as one spec. PLAN-1:196 intends `{1}` as one spec, and AC1–AC5 prove the macro half
independently of the fixture half.

## Verified DuckDB claims

Every behavioural claim the reviewer could test held: the `duckdb_functions()` query shape,
`typeof(COLUMNS(*))`, `(SELECT count(*) FROM (DESCRIBE _r))`, `.read` at line 1 of an `-init` file,
`-init` with both `-c` and `-f`, a second `-init` silently replacing the first, the BOM failure, the
forward-slash requirement, and the pins (`polyglot 8f1666d`/REPOSITORY/community; `ducklake` and
`excel` core; DuckDB `v1.5.5 d8cdaa33fd`).

Independently re-measured in the main session before applying the fixes: `LOAD polyglot` requirement,
the `tag`-block output shape, and the `GROUP BY` correction.
