# REVIEW — TASK.md (item 2c: clear item 2b's multi-object debt), round 1

Reviewer: `task-reviewer`. Round 1, on the spec only — no implementer had run.
Verdict at the time: **NOT READY**, nine blocking items.

Recorded here because the reviewer reports inline. `PLAN-4.md` confirmed frozen, last commit `fb4eecb`,
unmodified since the spec that froze it.

## The root cause behind five of the nine

**The spec treated fixtures as durable committed artifacts.** They are none of those things:

- `.gitignore:3` excludes `.duckdb-skills/`, so `git ls-files` tracks only the four generator scripts and
  a verifier's worktree starts with **no fixtures at all**.
- They are **time-relative** — every age is stamped from `UtcNow` at generation.
- They are **split across two roots** — `~\.duckdb-skills\fixtures\` (2a's `ages`/`damaged`/`empty`) and
  project-local `.duckdb-skills\fixtures\decide` (2b's verdict family).
- The shipped tree is **days stale**: `minus90` reports **`age=6401`**, `minus1500` **`age=7811`**.

Every "measured" figure in the D1 block and every acceptance check naming a fixture inherited that error.
Fixed with a convention at the top of the spec: regenerate first with an absolute `-Root`, always pass
`-ExtractRoot` explicitly, and pin verdict tokens rather than `age=` digits.

## Blocking defects, and the fixes applied

**B1 — the two-object fixture would have returned `REFRESH (malformed sidecar: parallel array mismatch)`
and every multi-object check would have failed.** `registry.sql:78-80` compares all three `source_*`
arrays against `len(source_objects)` and short-circuits at `extract-decide.ps1:175`, before stage 1. The
spec described only `source_objects` and `source_rows`, and `New-DecideFields` hardcodes `source_bytes`
and `source_last_altered` as single-element arrays — so an implementer copying it produces a malformed
sidecar. Fixed: the fixture spec now states all three arrays at length 2, and the parallel-array rule is
documented as a load-bearing constraint, because `Test-RowsStage` loops on `$Baseline.Count` and
PowerShell returns `$null` for an out-of-range read rather than throwing — the registry check is the only
thing closing that hole, and it is invisible in the tool itself.

**B2 — AC5 could not pass, and D1's ages were invented.** The spec said "age 1500 minutes against a
default ceiling of 1440"; the fixture is at **7811**, because the number was read from the fixture's
*name* rather than its output. AC5's other half — "`minus90` (age 90, under the ceiling) gives
`SKIPPED (no evidence) age=90`" — was impossible: `minus90` is at 6401, four times past the ceiling, so it
returns `REFRESH (no evidence past ceiling)` and AC5 fails on correct code. AC7 likewise passed at the
*default* ceiling and proved nothing. Fixed by the regeneration convention plus AC7 now running both
directions with explicit `DSK_MAX_AGE_MINUTES` values, 1440 and 60.

**B3 — "fixtures are committed" was false.** Fixed: they are generated, not committed; every check
regenerates first and passes an absolute `-ExtractRoot`, never the default, because `PLAN-4:470-473`
records that `<project-id>` differs inside a linked worktree by design.

**B4 — AC4 passed on unmodified code and could not fail on half its own scope.** The stderr bug fires only
when stage 2 is reached, so any call whose rows *moved* short-circuits and emits nothing even when broken;
AC4 named no fixture or values. Worse, the reviewer proved the bug **does not fire at two objects at all**
— so AC4's "on both the single-object and two-object fixtures" was already satisfied pre-fix on the
two-object half, and its mutation test only failed on the single-object half. Its grep half was
self-grading against a **pre-existing legitimate** `2>$null` at line 165. Fixed: AC4 pins fixture, values
and expected verdict, requires the **pre-fix non-zero byte count** on the single-object command, and
asserts the grep by count (`2>$null` = 1 at line 165, `SilentlyContinue` = 0, `ErrorActionPreference` = 0).

**B5 — D2 was misdiagnosed, and one authorised fix reproduces the bug.** The mechanism is not an index
into a placeholder array; line 248 assigns the result of an `if` **statement**, whose output pipeline
enumerates a single-element array to its element. Verified in the main session:
`$x = if ($true) { [object[]]::new(1) }` → **NULL**; at `new(2)` it survives as `Object[]` count 2; and
`[string[]]::new(1)` → **NULL**, which is precisely the "pass a correctly-typed array of nulls" fix the
first draft authorised. Fixed: the real mechanism is stated, retyping is explicitly forbidden, the fix
must hold at N=1, and a mutation test now proves the real mechanism was addressed rather than the
misdiagnosed one.

**B6 — AC11 was unfalsifiable.** It swept `~\.duckdb-skills\fixtures\` — 2a's trees, which have no
recorded decide verdicts — and skipped the `decide` family that does. "item 2b's recorded behaviour" was
undefined, though it exists and is retrievable at
`docs\tasks\2026-09-24-item2b-snowflake-extract\RESULT-1.md:205-220` (14 rows, verdict + command + exit
code — confirmed present in the main session). And the carve-out for "the two abstain cases this item
deliberately changes" was **factually wrong**: rows `g_null_baseline` and `m_null_current` both supply a
comparable `-CurrentLastAltered`, so stage 2 returns `unchanged` and neither reaches the new both-abstain
branch. Fixed: the file and line range are named, all 14 rows must match exactly with **no** carve-out,
±3 on age, and the `ages` tree is quoted separately as a snapshot.

**B7 — the nine measured rows rested on a fixture that no longer exists.** The only multi-object sidecars
on disk are the deliberately-damaged `array_mismatch` and `bad_json`. Fixed: the spec now states the
fixture was scratch and is unrecoverable, gives its exact shape, and frames the nine rows as expectations
to be re-established rather than evidence to inherit.

**B8 — AC8's empty-element case tested the wrong rule.** `"100,,200"` flattens to three elements, so the
length check fires first and the empty-element rule is never exercised. Fixed with `-CurrentRows "100,"`,
which flattens to exactly two, plus a note explaining why the original could not test it.

**B9 — the D1 evidence command was not runnable as quoted.** Without `-ExtractRoot` it resolves to the
real per-project root and returns `REFRESH (no sidecar)`. Fixed by the always-pass-`-ExtractRoot`
convention.

## Non-blocking issues fixed in the same revision

- The `Serves:` line named the debt rather than the capability. Reworded.
- The comma-safety argument covered only integers. `-CurrentLastAltered` holds timestamps, and ISO 8601
  permits a comma as the fractional-second separator — safe only because `InvariantCulture` rejects it.
  Now stated per parameter.
- An unstated behaviour change: `SIDECAR.md:20` names "the object is a view" as a reason a row count is
  unavailable, so a view-backed extract moves from *never refresh* to *refresh once per ceiling period* —
  a real recurring warehouse cost. Now stated under Deliverable 3.
- Three checks had no command despite the spec claiming all did (AC12, AC13, AC14). All three now name
  commands and expected output; AC13 also names `damaged` and `decide\n_malformed`, the only sources of
  two of the 13 verdicts.
- A per-object semantics gap the nine cases missed: `[100,null]` with B's `last_altered` moved yields
  `SKIPPED (ambiguous: last_altered moved, rows unchanged)` where "rows unchanged" was never evaluated for
  B. Ceiling-bounded, so not silent-staleness-forever, but the verdict overstates its evidence. Added as a
  tenth fixture row and accepted as a known bounded miss.
- No branch was named. Now `item2c-multi-object-debt`.
- AC6 was an unlabelled control that already passes on unmodified code. Labelled.
- AC9's "accepted as two nulls" named no observable outcome. Now states the verdict.
- AC1's before/after had no mechanism. Now specifies `git show 337b29d:tools/extract-decide.ps1` into a
  temp copy.

## Plan drift the reviewer required be stated

`PLAN-4:301-303` enumerates **eight** specs exhaustively, and item 2b's `SHIPPED.md:4` states "Item 2 is
now complete and Track A is done". This spec reopens a closed item and adds two verdicts, which
`PLAN-4:432-439` did not contemplate — by the project's own rule that an item's definition changing means
a new plan version, that is a `PLAN-5.md` delta. Recorded explicitly in the spec header instead: the count
becomes nine and that `SHIPPED.md` sentence is now wrong. Silence was the option that goes wrong later.

The reviewer also found `PLAN-4:436-439` argues for D1's fix more strongly than the first draft did —
*"Without the ceiling the miss is unbounded, and `DSK_FORCE=1` does not bound it because it requires Phil
to already suspect what the check failed to tell him"* — now quoted in the spec.

## What the reviewer confirmed as correct

- **All three findings are real.** D1 unbounded and reachable at any object count; D2 reproduced verbatim
  at line 125, non-terminating; D3's binding table correct in both failing forms.
- **The multi-object rule is correct**, and closer to fully covered than the spec argued, because the
  parallel-array check eliminates the entire length-mismatch family before the stages run.
- **Comma-splitting is the right fix** — repeated parameters break the documented `[string[]]` contract, a
  JSON argument has to survive the quote handling being fixed, and dot-sourcing is unreachable from
  anything that shells out.
- **The two new verdicts are right** and cannot shadow the ambiguous branch, which returns before line 260.

## Main-session verification of the review

| claim | result |
|---|---|
| `if ($true) { [object[]]::new(1) }` is NULL; `new(2)` survives | confirmed — NULL / `Object[]` count 2 |
| `[string[]]::new(1)` through an `if` is also NULL | confirmed — the authorised fix reproduces the bug |
| fixture ages are stale | confirmed — `minus90` **6401**, `minus1500` **7811** |
| parallel-array mismatch short-circuits | confirmed — `REFRESH (malformed sidecar: parallel array mismatch)` |
| `registry.sql` enforces all three arrays | confirmed — three `IS DISTINCT FROM len(source_objects)` clauses |
| item 2b's 14-row baseline exists at `RESULT-1.md:205-220` | confirmed — rows a–n with verdict, command, exit |
| rows `g` and `m` supply a comparable `last_altered` | confirmed — neither reaches the both-abstain branch |

All held. The revision was written against them.
