Plan: PLAN-4.md — **reopens item 2** to repair defects in shipped code. It adds no capability the plan
did not already ask for, but PLAN-4:301-303 enumerates eight specs and item 2b's `SHIPPED.md:4` says
"Track A is done", so the count becomes **nine** and that sentence is now wrong. Recorded here rather
than edited into either file.
Serves: an extract built from more than one Snowflake table can be freshness-checked at all — and an
extract whose source metadata is unavailable stops being served as current forever.

# TASK — Clear item 2b's multi-object debt, and two defects found doing it (item 2c)

`docs\tasks\2026-09-24-item2b-snowflake-extract\SHIPPED.md:110` recorded:

> **Multi-object extracts are unverified.** Every `extract-decide.ps1` fixture has exactly one
> `source_objects` entry … the first multi-object extract should be treated as untested ground.

Building the first multi-object fixture found the multi-object **rule is correct**, and three things
around it are not. Two are defects in shipped, verified code; one of those serves arbitrarily stale data
forever.

**Why one item rather than three:** D3 is a prerequisite for testing the debt at all, and fixing D1
separately would mean committing a fixture that encodes the wrong `[null,null]` verdict and rewriting it
next round.

---

## Conventions that are not optional

- **Regenerate the fixture trees before running any acceptance check, and state the absolute root used.**
  This is the most important line in the spec. Fixtures are **generated scratch, not committed
  artifacts**: `.gitignore:3` excludes `.duckdb-skills/`, so `git ls-files` tracks only the four
  generator scripts and a verifier's worktree starts with **no fixtures at all**. They are also
  **time-relative** — every age is stamped from `UtcNow` at generation. The shipped tree is days old:
  `minus90` currently reports **`age=6401`** and `minus1500` **`age=7811`**, not 90 and 1500.
  - `tools\make-extract-fixtures.ps1 -Root <absolute>` resets `ages`/`damaged`/`empty`.
  - `tools\make-decide-fixtures.ps1 -Root <absolute>` resets the `decide` tree.
  - **Do not edit `make-extract-fixtures.ps1`** — item 2b's spec forbade it and 2a's AC10 asserts it.
- **Always pass `-ExtractRoot <absolute path>` explicitly.** Never rely on the default: it is
  `~\.duckdb-skills\<project-id>\extracts`, and `PLAN-4:470-473` records that `<project-id>` differs
  inside a linked worktree by design, where it is empty. A command quoted without `-ExtractRoot`
  returns `REFRESH (no sidecar)` — measured.
- **Pin verdict tokens, not `age=` digits.** Allow ±3 minutes on any age, exactly as item 2b's
  `RESULT-1.md:222-224` did.
- **Write files with `[IO.File]::WriteAllText` plus `New-Object Text.UTF8Encoding($false)`.**
- PowerShell 5.1: `;` never `&&`, absolute paths.
- **Gate on `$LASTEXITCODE`, not on stderr** — except AC4, where *stderr being empty* is the point.
- `extract-decide.ps1` **never touches Snowflake** and must not start.
- Do not touch `docs\tasks\`, the contracts, the harness, the lakehouse tools, or
  `skills\query\duckdb-compat.sql`. `tools\dsk-paths.ps1` is dot-sourced by five tools; if touched, all
  five must be re-run.
- Branch: `item2c-multi-object-debt`.

---

## A load-bearing constraint that is invisible in the tool

`registry.sql` rejects any sidecar whose three `source_*` arrays are not the same length as
`source_objects`:

```sql
WHEN len(source_rows)          IS DISTINCT FROM len(source_objects)
  OR len(source_bytes)         IS DISTINCT FROM len(source_objects)
  OR len(source_last_altered)  IS DISTINCT FROM len(source_objects) THEN 'parallel array mismatch'
```

Measured, this short-circuits at `extract-decide.ps1:175`, **before stage 1**:

```
-Name array_mismatch -CurrentRows 100  ->  REFRESH (malformed sidecar: parallel array mismatch)  exit 0
```

**This is the only thing closing a silent hole.** `Test-RowsStage` loops on `$Baseline.Count`, and
PowerShell returns `$null` for an out-of-range array read rather than throwing — so a short `source_rows`
would silently skip objects and a long one would silently ignore supplied values. Nothing in
`extract-decide.ps1` itself enforces the lengths. State this in the tool's header so a future refactor
cannot quietly remove the guard.

It also means **the two-object fixture must carry all three arrays at length 2.** `New-DecideFields`
currently hardcodes `source_bytes` and `source_last_altered` as single-element arrays, so an implementer
who copies it produces a malformed sidecar and every multi-object check returns the mismatch verdict
instead of a real one.

---

## Measured facts

Measured against `tools\extract-decide.ps1` at `337b29d`.

### The multi-object rule is correct — the debt is discharged by fixtures, not repair

A two-object fixture, `source_objects` `["DB.SCH.A","DB.SCH.B"]`. The probe request lists both in order:

```
STALE (probe required) age=90 window=60 objects=DB.SCH.A,DB.SCH.B
```

The combination rule — **any object moved ⇒ moved; at least one comparable and none moved ⇒ unchanged;
nothing comparable ⇒ abstain** — behaved correctly in every case:

| probe | verdict | correct? |
|---|---|---|
| `[100,200]` both unchanged | `SKIPPED (source unchanged)` | yes |
| `[100,201]` second moved | `REFRESH (stale, source moved)` | yes |
| `[101,200]` first moved | `REFRESH (stale, source moved)` | yes |
| `[null,200]` first unknown, second unchanged | `SKIPPED (source unchanged)` | yes |
| `[null,201]` first unknown, second moved | `REFRESH (stale, source moved)` | yes |
| rows same, second `last_altered` moved | `SKIPPED (ambiguous: last_altered moved, rows unchanged)` | yes |
| rows same, both `last_altered` same | `SKIPPED (source unchanged)` | yes |
| 3 values for 2 objects | usage error, **exit 2** | yes |
| **`[null,null]` nothing comparable** | **`SKIPPED (source unchanged)`** | **NO — D1** |

**That fixture was scratch and no longer exists.** These nine rows are **expectations to be
re-established**, not evidence to be inherited. Deliverable 4 must recreate the fixture to this exact
shape: `source_objects` `["DB.SCH.A","DB.SCH.B"]`, `source_rows` `[100,200]`, `source_bytes`
`[2048,2048]`, `source_last_altered` both `<now − 1d>`, `materialized_at` `<now − 90m>`,
`window_minutes` 60, `name` equal to the directory name.

Also uncovered: the per-object stages aggregate, so `source_rows` `[100,null]` with current `[100,null]`
and object B's `last_altered` moved yields `SKIPPED (ambiguous: last_altered moved, rows unchanged)` —
where "rows unchanged" is true for A and **never evaluated** for B. It is ceiling-bounded, so not
silent-staleness-forever, but the verdict overstates its evidence. Add it as a tenth fixture row and
accept it as a known, bounded miss rather than changing the wording.

### D1 — No evidence reads as "source unchanged", and is unbounded

`extract-decide.ps1:260` prints `SKIPPED (source unchanged)` whenever **both** stages return `abstain` —
nothing comparable at all. `abstain` is not `unchanged`; it means the tool has no information. That
violates the principle `SIDECAR.md:20` and the tool's own header lines 18–20 are built on: a null row
count means "no metadata available" and must never read as a known value. The tool applies that rule
correctly to a single null among comparable ones, then discards it when every element is null.

**It is not bounded by the ceiling.** The ceiling is tested only inside the `stage2 -eq 'moved'` branch,
so it never fires here. Measured on the shipped single-object `minus1500` fixture:

```
-Name minus1500 -ExtractRoot <abs>\fixtures\ages -CurrentRows null
  ->  SKIPPED (source unchanged)   exit 0     at age 7811, against a default ceiling of 1440
```

**Correcting the first draft of this spec:** it reported that age as "1500 minutes", inferred from the
fixture's *name* rather than read from its output. The real age is **7811**, because the shipped tree was
generated 2026-09-23/24. The finding survives — it is unbounded, and 7811 makes that more emphatic, not
less — but the figure was not measured, and this is the third consecutive spec in which a confident
"measured" number came from a setup nobody re-checked. Hence the regeneration convention above.

`PLAN-4:436-439` already argues for exactly the fix this needs, more strongly than the first draft did:
*"Without the ceiling the miss is unbounded, and `DSK_FORCE=1` does not bound it because it requires Phil
to already suspect what the check failed to tell him."*

The header's stated asymmetry is correct and must survive: *"an unchanged last_altered is never bounded,
since it means genuinely unaltered."* **Unchanged** stays unbounded. **Abstain** must not.

### D2 — The documented normal invocation writes a PowerShell error to stderr

```
Cannot index into a null array.
At ...\tools\extract-decide.ps1:125 char:9
+         $c = ConvertTo-UtcSecond $Current[$i]
```

Non-terminating, so the verdict and exit code are still right — which is why item 2b's fixtures missed
it: they checked the verdict line and the exit code, and nothing looked at stderr.

**The first draft diagnosed the mechanism wrongly, and the fix it authorised reproduces the bug.** It is
*not* an index into a placeholder array. Line 248 assigns the result of an `if` **statement**, whose
output pipeline **enumerates a single-element array to its element**. Measured:

```
$x = if ($true) { [object[]]::new(1) }  ->  $x is NULL
$y = if ($true) { [object[]]::new(2) }  ->  $y is Object[], count 2
$z = if ($true) { [string[]]::new(1) }  ->  $z is NULL      <- "pass a correctly-typed array of nulls"
```

So at **one** source object `$currentLastAltered` is plain `$null`; at two or more the placeholder
survives and **the bug does not fire at all**. Two consequences:

- Retyping the placeholder — the obvious reading of "pass a correctly-typed array of nulls" — ships the
  identical defect. Do not do it.
- Any check requiring zero stderr on a *two-object* fixture passes on the unfixed code. Only the
  single-object case discriminates.

It also fires **only when stage 2 is reached**: a call whose rows moved short-circuits at line 243 and
emits no stderr even when broken.

### D3 — Multi-object values cannot be passed through the documented invocation

`-CurrentRows`/`-CurrentLastAltered` are `[string[]]`, and PowerShell 5.1 **cannot bind more than one
value to an array parameter through `powershell -File`**:

| invocation | what binds |
|---|---|
| `powershell -File s.ps1 -CurrentRows 100,200` | `count=1`, `[0]="100,200"` |
| `powershell -File s.ps1 -CurrentRows 100 200` | `count=1`, `[0]="100"` — second token dropped |
| `& .\s.ps1 -CurrentRows @('100','200')` | `count=2` — works |

So every multi-object call through `-File` fails with `expected 2 values for 2 source objects, got 1`,
exit 2. `powershell -File` is how every tool here is invoked, and `SKILL.md:94` tells the caller to pass
values "positional against that same object list" without specifying the form — so an agent following the
skill cannot use a multi-object extract at all. Single-object worked by accident: one value binds as one
element and `count=1` matches one object.

A platform constraint, not a coding slip, so the fix belongs in the parameter contract.

### Exposure is confined to these two parameters

Only `extract-decide.ps1`'s `-CurrentRows` and `-CurrentLastAltered` are **script** parameters of array
type. The others in `materialize.ps1`, `run-assertions.ps1`, and `extract-decide.ps1`'s two helpers are
internal function parameters, which `-File` binding never touches. `publish-extract.ps1` has none.

---

## Deliverables

### 1. `extract-decide.ps1` — accept comma-joined values (D3)

Keep `[string[]]`; **split each element on commas and trim** before validation, so all three forms work:

- `-CurrentRows @('100','200')` → 2 (existing contract, unchanged)
- `-CurrentRows "100,200"` → 2 (new; what `-File` delivers)
- `-CurrentRows 100,200` via `-File` → 2

Safe for **both** parameters, and the reason differs per parameter, so state both: `-CurrentRows`
elements are an integer or the literal `null`, neither of which can contain a comma; `-CurrentLastAltered`
elements are timestamps parsed by `[DateTimeOffset]::TryParse` under `InvariantCulture`, and although
ISO 8601 permits a comma as the fractional-second separator, `InvariantCulture` will not accept one.

An empty element is a usage error, exit 2 — never silently a null. The length check then compares the
flattened count against `source_objects.Count`, preserving the existing mismatch behaviour.

### 2. `extract-decide.ps1` — stop writing to stderr on the happy path (D2)

Fix the `if`-statement enumeration at line 248 by forcing array semantics (a `,`-prefix or `@(...)`
wrapping at the assignment), by guarding the index in `Test-LastAlteredStage`, or by not calling stage 2
when `-CurrentLastAltered` is absent. **Do not retype the placeholder** — `[string[]]::new(1)` through an
`if` is also `$null`. Whatever is chosen must hold at **N=1**, the only case that currently fails.

Do not suppress errors globally. The script already contains exactly **one** legitimate `2>$null`, at
line 165 on the `& duckdb` call; it must remain the only one. AC4 asserts that by count.

### 3. `extract-decide.ps1` — a bounded no-evidence verdict (D1)

Two new verdicts, replacing `SKIPPED (source unchanged)` when **both** stages abstain:

```
SKIPPED (no evidence) age=<n>
REFRESH (no evidence past ceiling)
```

Bounded by `DSK_MAX_AGE_MINUTES` exactly as the ambiguous branch is. `SKIPPED (source unchanged)` keeps
its meaning and stays unbounded, because it reflects real evidence of no change. The ambiguous branch is
entered only on `stage2 -eq 'moved'` and returns before line 260, so the new branch sees exactly
`(abstain, abstain)` and cannot shadow it.

Update the header's verdict list: **11 → 13**.

**State the consequence.** `SIDECAR.md:20` gives "the object is a view" as a reason a row count is
unavailable. So a view-backed extract with no `last_altered` evidence changes from *never refresh* to
*refresh once per ceiling period* — the intended direction, but a real recurring warehouse cost that
nobody has costed. It belongs in the eventual `SHIPPED.md` under what deliberately changed.

### 4. `tools\make-decide-fixtures.ps1` — multi-object fixtures

A two-object fixture family covering all nine rows above plus the tenth (W6) case, built to the exact
shape stated in "Measured facts", with **all three parallel arrays at length 2**. Existing single-object
fixtures keep their names and behaviour — five tools and item 2b's acceptance set depend on them.

### 5. `skills/snowflake-extract/SKILL.md`

State the comma-joined form as the one that works through `powershell -File`, with a worked two-object
example. Add both new verdicts to the routing list, and say that `SKIPPED (no evidence)` means the probe
returned no comparable metadata — **not** that the source is unchanged. Do not exceed the existing
description-line budget.

---

## Out of scope

- The lakehouse, contracts, assertion harness, compat macros.
- `publish-extract.ps1`, `extract-status.ps1`, `list-extracts.ps1` — except as AC12 re-runs them.
- Direction-aware row tolerance; items 7 and 8.
- Any live Snowflake call. Entirely fixture-driven, so the verifier can certify all of it.
- Re-materializing either real extract.
- Editing `make-extract-fixtures.ps1`.

---

## Acceptance checks

Every check names a command. Each begins by regenerating its tree with an absolute `-Root` and passes
that path as `-ExtractRoot`. None needs Snowflake.

**AC1** *The debt, discharged through the documented path.*
`powershell -NoProfile -File tools\extract-decide.ps1 -Name <two-object fixture> -ExtractRoot <abs> -CurrentRows 100,200`
prints `SKIPPED (source unchanged)`, exit 0. For the "before": run the same command against
`git show 337b29d:tools/extract-decide.ps1` written to a temp copy, and quote
`expected 2 values for 2 source objects, got 1` / exit 2.

**AC2** *The whole matrix, through `-File`.* All nine rows plus the tenth, with `[null,null]` now giving
`SKIPPED (no evidence) age=<n>`. Quote each verdict and exit code.

**AC3** *The array form still works.* Every AC2 case in-process as
`& .\tools\extract-decide.ps1 ... -CurrentRows @('100','200')` gives the identical verdict.

**AC4** *Stderr is empty on a call that actually reaches stage 2.* Capture stderr separately; quote the
verdict beside the byte count.
- single object: `-Name c_unchanged -ExtractRoot <abs> -CurrentRows 100` → `SKIPPED (source unchanged)`,
  stderr **0 bytes**.
- two objects: `-Name <two-object fixture> -CurrentRows 100,200` → `SKIPPED (source unchanged)`, stderr
  **0 bytes**.

**Also record the pre-fix byte count for the single-object command** — it must be non-zero, and it is the
only half that discriminates, because the placeholder survives at N≥2 and the unfixed code is already
clean there. A call whose rows *moved* short-circuits before stage 2 and emits no stderr even when
broken, so it does not satisfy this check.

Anti-suppression, asserted by count: `2>$null` appears exactly **once** (line 165, the `& duckdb` call),
`SilentlyContinue` **zero** times, `ErrorActionPreference` **zero** times. Show the `Select-String`
output and the counts.

**AC5** *No evidence is bounded.* With the `ages` tree freshly regenerated:
`minus1500` (age 1500) + `-CurrentRows null` → **`REFRESH (no evidence past ceiling)`**;
`minus90` (age 90) + `-CurrentRows null` → **`SKIPPED (no evidence) age=90`** (±3).

**AC6** *Control — must pass before and after.* On `minus1500` with the baseline row count supplied
(read `source_rows[0]` from the sidecar), the verdict is still `SKIPPED (source unchanged)`. This asserts
the branch this item does **not** change: unchanged means genuinely unaltered and is deliberately
unbounded.

**AC7** *The ceiling is the bound, not a constant.* Freshly regenerated `minus90`, identical command,
both directions: `DSK_MAX_AGE_MINUTES=1440` → `SKIPPED (no evidence) age=90`;
`DSK_MAX_AGE_MINUTES=60` → `REFRESH (no evidence past ceiling)`. Show the env value used for each.

**AC8** *Usage errors survive.* Against the two-object fixture: `-CurrentRows 100,200,300` → exit 2;
`-CurrentRows 100` → exit 2; **`-CurrentRows "100,"`** → exit 2 on the **empty-element** rule. Note
`"100,,200"` cannot test that rule — it flattens to three elements and the length check fires first with
`expected 2 values for 2 source objects, got 3`.

**AC9** *Element parsing is unchanged.* `-CurrentRows "100,abc"` → exit 2 with the existing
`invalid -CurrentRows value` message. `-CurrentRows "null,NULL"` → accepted as two nulls, producing
`SKIPPED (no evidence) age=<n>`, exit 0 (the token is case-insensitive per the header).

**AC10** *`-CurrentLastAltered` gets the same treatment.* Comma-joined through `-File` with two
timestamps: rows unchanged and one `last_altered` moved gives
`SKIPPED (ambiguous: last_altered moved, rows unchanged) age=<n>`.

**AC11** *No regression on the shipped single-object fixtures.* Regenerate the `decide` tree, then re-run
**all 14 rows** of item 2b's recorded table at
`docs\tasks\2026-09-24-item2b-snowflake-extract\RESULT-1.md:205-220`, using the commands recorded there.
All 14 verdict tokens must match **exactly, with no exceptions** — rows `g` and `m` both supply a
comparable `-CurrentLastAltered`, so stage 2 returns `unchanged` and neither reaches the new both-abstain
branch. `age=` may drift ±3. Separately re-run the `ages` tree and quote its verdicts as a snapshot;
those have no recorded per-verdict baseline, so a difference there is drift to quote, not a failure.

**AC12** *The other extract tools still work.* Name each command and its expected first line:
`tools\extract-status.ps1`, `tools\list-extracts.ps1`, `tools\publish-extract.ps1`. Required whether or
not `dsk-paths.ps1` was touched, because five tools dot-source it.

**AC13** *The header contract matches the code.* A 13-row table: verdict, tree, fixture, full command,
actual output. Note `REFRESH (unreadable sidecar)` and `REFRESH (malformed sidecar: …)` come from the
`damaged` tree and `decide\n_malformed` — name them explicitly.

**AC14** *No BOM.* For each changed file, `Get-Content <file> -Encoding Byte -TotalCount 3` and assert
the bytes are not `239 187 191`.

### Mutation proof required

Each failing, then passing after revert.

- **remove the comma-splitting** → AC1 fails, back to `got 1`.
- **map both-abstain back to `SKIPPED (source unchanged)`** → AC2's `[null,null]` row and AC5 both fail.
- **drop the ceiling check from the no-evidence branch** → AC5's `minus1500` half fails, and AC7's
  `DSK_MAX_AGE_MINUTES=60` direction fails.
- **retype the placeholder as `[string[]]::new(N)` instead of forcing array semantics** → AC4's
  single-object half fails with non-zero stderr. This is the mutation that proves the fix addresses the
  real mechanism rather than the misdiagnosed one.
- **suppress with a second `2>$null` instead of guarding** → AC4's count assertion catches it.

---

## Commit and handoff

Branch `item2c-multi-object-debt`. Commit before writing `RESULT-1.md`; the verifier works from a
throwaway worktree at that commit. Push separately with an explicit timeout.

`RESULT-1.md` must record: the absolute fixture root used and the regeneration commands; exact commands
and output for AC1–AC14; mutation evidence both directions; AC1's before/after quoted from the actual
pre-fix script; and anything not verified, named plainly.
