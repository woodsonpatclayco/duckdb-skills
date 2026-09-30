# REVIEW-task-1 — item 7 (workbook proof, routing, extension non-goal)

Reviewed: `TASK.md` (untracked draft at root), round 1 draft. No `RESULT-*.md` at root, so this is
the first review of round 1 and nothing is frozen yet. `Plan: PLAN-4.md` is the newest plan;
`PLAN-4.md` has one commit (`fb4eecb`, 2026-09-24) and no uncommitted edits, so the frozen plan
record is intact.

## Verdict: NOT READY — all fixes are wording; no plan change needed

Two defects will cost a round unless fixed now:

- **AC5 will fail for the verifier.** The verifier works in a worktree, and there the extract tools
  resolve to a different, empty extract root.
- **AC3 and AC4 cannot be run as written.** `materialize.ps1` has no way to process a *set* of
  scratch contracts.

Everything else is tightening. **The change with the largest effect on round count is F1**: give
every extract-tool entrypoint an explicit fixture `-ExtractRoot`, and add `extract-decide.ps1`.

## What the implementer will build (written from TASK.md alone, before reading the plan)

**`tools\prove-requery.ps1`**
- Copies the live `Data Extracts.xlsm` to a temp folder.
- Rewrites both shipped contracts to point at the copy.
- Materializes both into a temp lake.
- Deletes the copy, then shows in a fresh read-only DuckDB process that the lake still returns the
  same row counts, manifest counts and GL `SUM(JOB_COSTS)` as the source did.

**`tools\prove-no-snowflake.ps1`**
- Puts a temporary `duckdb.cmd` first on `PATH`. The shim runs the real `duckdb.exe` and then
  appends a query that writes the loaded-extension list to a side file.
- Runs about 14 PowerShell entrypoints plus three `.sql` entrypoints through the shim.
- Prints one `EXT,…` verdict line per entrypoint. The verdicts are `HUNG`, `FAIL`, `NO_EVIDENCE`
  and `PASS`.
- Has three opt-in controls: `fts` detection, a failed call, and a hang.

**Skill text**
- `read-file` routes `.xlsm` to `read_xlsx`.
- `read-file` gains an "Excel workbooks" section: use the lake if a contract covers the sheet;
  otherwise use a careful `all_varchar` read and say the types are unverified.
- `lakehouse` gets one sentence.

**`materialize.ps1`**
- A missing or unreadable workbook no longer stops the remaining contracts.
- A new `errored=` count is appended to `SUMMARY`.

**Verification:** 15 acceptance checks and 6 mutations.

The restatement matches what PLAN-4 §7 asks for, plus part D. Part D is a scope question for Phil
(see F17).

## Round-2 risks, most likely first

### F1 — In the verifier's worktree, the extract tools find no extracts, so AC5 fails

Quoted: *"`tools\list-extracts.ps1` | none (reads the real extract root; read-only)"* and
*"`tools\extract-status.ps1` | `-Name parent_projects`"*.

Why the default root breaks in a worktree:
- `Resolve-ExtractRoot`'s default is `~\.duckdb-skills\<project-id>\extracts`.
- `<project-id>` comes from `git rev-parse --show-toplevel` (`tools\dsk-paths.ps1:42-54,63-68`).
- Today the default resolves to `c-users-woodsonp-claude-dev-duckdb-skills`, which holds
  `dt_projects` and `parent_projects`.
- In the throwaway worktree that AGENTS.md mandates for the verifier, it resolves to a *new, empty*
  directory, and creates it as a side effect.

What happens then:
- `list-extracts` prints `no extracts registered` having made **zero** `duckdb` calls, so it is
  `NO_EVIDENCE`.
- `extract-status -Name parent_projects` exits **2** (`extract-status.ps1:126-129`), so it is `FAIL`.
- The implementer, working in the main checkout, sees PASS. The verifier sees FAIL. That is a lost
  round.

The excluded list is also wrong. Quoted: *"`list-sheets.ps1`, `extract-decide.ps1`, … which never
launch `duckdb`"*. In fact `tools\extract-decide.ps1:216` runs `& duckdb -csv -f $registrySql`
whenever the sidecar exists (`:207-210`).

**Replace the two table rows, and delete `extract-decide.ps1` from the excluded list, with:**

> | `tools\make-extract-fixtures.ps1` | `-Root <scratch>\xfx` (absolute). Setup, not an entrypoint — it never launches `duckdb` |
> | `tools\list-extracts.ps1` | `-ExtractRoot <scratch>\xfx\ages` |
> | `tools\extract-status.ps1` | `-Name parent_projects -ExtractRoot <scratch>\xfx\ages` |
> | `tools\extract-decide.ps1` | `-Name parent_projects -ExtractRoot <scratch>\xfx\ages` |
>
> **No entrypoint may rely on a default root.** `Resolve-ExtractRoot` and `Resolve-LakeRoot` key their
> default on `git rev-parse --show-toplevel`. In a worktree that is a different, empty project
> directory, so the default-root runs would make zero `duckdb` calls. The fixture root contains
> `parent_projects` with a sidecar (`make-extract-fixtures.ps1:148`), so each of these three
> entrypoints makes at least one probed call.

### F2 — AC3 and AC4 cannot be run with `materialize.ps1` as it is

Quoted AC3: *"Materialize both shipped contracts' scratch copies into a scratch lake … Remove the
**first-processed** contract's workbook only. Run `materialize.ps1` again"*.

Why this is not runnable:
- Without `-Contract`, `materialize.ps1` processes only `<its own repo root>\contracts\*.sql`
  (`materialize.ps1:119-120,156-168`).
- With `-Contract`, it processes exactly one file, so there is no "second contract".
- Scratch contracts may not go in `contracts\` (Conventions).
- Both shipped contracts read the **same** workbook (`All_Sales_Data.sql:76`,
  `Clayco_Job_Costs_from_GL.sql:70`). "Remove the first-processed contract's workbook only" is
  impossible unless each contract gets its own copy. AC3's "both scratch workbooks" hints at this
  but never says it.
- "First-processed" is never defined.
- AC4 inherits all of this.
- The implementer will improvise, and Phil will have to adjudicate the deviation.

**Add under D, before AC3:**

> **Scratch tree for AC3, AC4 and mutation 5.** `materialize.ps1` finds contracts only in
> `<its repo root>\contracts\`. So build `<scratch>\tree\`:
> - `tools\` — a copy of every `tools\*.ps1`. Take them from this branch for "after" and from
>   `main` (`git show main:tools/<f>`) for "before".
> - `skills\query\duckdb-compat.sql` — a copy.
> - `contracts\` — the two scratch contracts only.
>
> Each scratch contract points at its **own** workbook copy, `<scratch>\wb\All_Sales_Data.xlsm` and
> `<scratch>\wb\Clayco_Job_Costs_from_GL.xlsm`, because both shipped contracts read the same
> workbook. Run it as
> `powershell -NoProfile -ExecutionPolicy Bypass -File <scratch>\tree\tools\materialize.ps1 -LakeRoot <scratch>\lake`.
> Contracts are processed in `Sort-Object Name` order (`materialize.ps1:161-163`), so the
> first-processed contract is **`All_Sales_Data`**.

**AC3 expected output, after the fix:**
```
MATERIALIZE,All_Sales_Data,ERROR
ERROR,All_Sales_Data,workbook path does not exist: <scratch>\wb\All_Sales_Data.xlsm
MATERIALIZE,Clayco_Job_Costs_from_GL,SKIPPED
SUMMARY,contracts=2,refreshed=0,skipped=1,refused=0,forced=0,errored=1
```
Exit is 1.

**AC3 expected output, before the fix (`main`'s copy):** the output ends at
`ERROR,All_Sales_Data,could not read workbook at … (see output above)`. There is no
`Clayco_Job_Costs_from_GL` line and no `SUMMARY` line, and exit is 1.

I checked by reading that `SKIPPED` is right. On the second run the GL contract's workbook mtime
and SHA, its contract SHA and the compat SHA are all unchanged, and the target exists with rows
(`materialize.ps1:345-360`). Removing the other workbook changes none of these.

### F3 — Mutation 3 cannot fail AC7, because the verdict rule decides the control first

Quoted: *"else `FAIL` if … **or if the entrypoint's own exit code was non-zero**; else
`NO_EVIDENCE` if `probed = 0`"*, and AC7: *"`NO_EVIDENCE` or `FAIL` (not `PASS`)"*.

`control_error` is itself a `duckdb -f` call that errors, so its own exit code is 1. The exit-code
rule makes it `FAIL` before the `probed = 0` rule is ever consulted. Mutation 3 ("treat `probed = 0`
as `PASS`") therefore leaves AC7's result unchanged. It is a mutation that cannot fail.

**Replace the `control_error` bullet and AC7 with:**

> - `control_error` — a scratch `.ps1` that runs `& duckdb -f <scratch>\error.sql` (containing
>   `SELECT * FROM no_such_table;`) and then `exit 0`. It is modelled on `list-extracts.ps1`, which
>   exits 0 after a failed sidecar read.
>
> **AC7** — `-Only control_error` prints
> `EXT,control_error,exit=0,…,calls=1,probed=0,unprobed=1,…,NO_EVIDENCE` and the script exits
> non-zero. It must be exactly `NO_EVIDENCE`. A control that exits non-zero would be decided `FAIL`
> by the exit-code rule and would never test the `probed = 0` rule.

### F4 — Mutation 5 targets a line whose meaning the fix changes

Quoted: *"Restore `exit 1` at `materialize.ps1:283` → AC3 fails"*.

After D, a missing workbook takes the **new** `Test-Path` branch, which runs before the hash read.
Line 283 then serves only the "exists but unreadable" case, which is AC4. Restoring `exit 1` there
leaves AC3 passing.

**Replace with:**

> 5a. In the new missing-workbook branch, replace `continue` with `exit 1` → AC3 fails
>     (`Clayco_Job_Costs_from_GL` and `SUMMARY` are absent).
> 5b. In the unreadable-workbook branch (today's `materialize.ps1:283`), restore `exit 1` → AC4
>     fails.

### F5 — Probe-file collisions would go unnoticed, because AC10 cannot fail

Quoted: *"How the shim names them is the implementer's choice, but the run must prove it: the
number of logged calls equals probed + unprobed."*

The problems:
- The obvious `.cmd` choice is `%RANDOM%`. `cmd.exe` seeds it from the clock at start-up, so
  shims started in the same second get the same value.
- `run-compat-tests.ps1` alone makes about 202 sequential calls in about 24 s: 50 fixture rows × 3
  modes, 50 transpiles, the pin check and `-version`. That is several calls per second.
- On a collision, the second call's probe file overwrites the first. Every log line still finds
  "a" file, so it counts as probed.
- If `unprobed` is derived as `calls − probed`, `calls = probed + unprobed` holds by arithmetic
  whatever the shim did.

**Replace that sentence with:**

> The shim appends one line per call to the call log **after** `duckdb.exe` returns:
> `<entrypoint label>|<exit code>|<probe path>|<args>`. Capture `%ERRORLEVEL%` into a variable on
> the line immediately after the `duckdb.exe` line.
>
> Before invoking `duckdb.exe`, the shim chooses a probe path that does not exist yet (retry while
> `if exist`), and creates it empty. Every tool here calls `duckdb` sequentially, so check-then-create
> is enough. Do not rely on `%RANDOM%` alone.
>
> Classify each logged call like this:
>
> | condition | classification |
> |---|---|
> | the args contain `-version` | `not_a_session` |
> | probe file non-empty | `probed` |
> | probe file empty, exit ≠ 0 | `unprobed` |
> | probe file empty, exit = 0 | `probe_missing`, which **fails the entrypoint** |
>
> **AC10** shows, per entrypoint:
> - `calls` — the number of log lines;
> - the number of **distinct** probe paths, which must equal `calls`;
> - `probed`, `unprobed` and `not_a_session`;
> - `probe_missing`, which must be 0.

### F6 — The probe file's format depends on each tool's output mode

Quoted: *"same probe appended inside a `.sql` run in `-json` mode | … log written as JSON"*.

The probe inherits whatever output mode the tool's script left. The files come out in three
formats:

| tools | mode left behind |
|---|---|
| materialize, run-assertions, lake-status, `gl-facts.sql` (`.mode csv`/`.headers off`) | csv, no header |
| check-contract (`-json`) | JSON |
| run-compat-tests, the extract tools (`-csv`) | csv with a header |

The parser then has to handle all three, and a parser that misses one silently reads zero
extensions.

**Replace the probe's `-c` sequence with:**

> `-c ".output <probe>" -c ".mode list" -c ".headers off" -c "SELECT extension_name FROM duckdb_extensions() WHERE loaded ORDER BY 1;" -c ".output"`
>
> Every probe file is then one extension name per line, whatever mode the tool used.

### F7 — Safety: step 5 could delete the live workbook under AC2's second mutation

Quoted step 5: *"**Remove the scratch workbook** (rename or delete)"*. AC2's second mutation says:
*"skip step 2's rewrite so the scratch contracts still point at the live workbook"*.

If the implementer finds "the workbook to remove" by reading it back from a contract's `read_xlsx`
text, as `materialize.ps1` itself does, then under that mutation step 5 renames or deletes **the
live `Data Extracts.xlsm`**. The guard should stop the run before this, but the mutation exists
precisely to test the guard.

**Add to step 5, and to AC3 and AC4:**

> Remove only the path this script created in step 1, held in a variable. First assert that the
> path is under the step-1 scratch directory. Never derive a path to remove, rename or lock from a
> contract's `read_xlsx` text: under AC2's second mutation, that text is the live workbook's path.

### F8 — A normal SharePoint sync would fail the run

Quoted step 8: *"`LIVE_WORKBOOK,CHANGED` (the latter fails the run)"*, and AC14: *"The live
workbook's SHA-256 and `LastWriteTime` are unchanged across the whole implementation."*

The spec itself records that the workbook refreshed today. Item 6's AC20 already settled the rule
for this (`docs\tasks\2026-09-25-item6-lakehouse-materialize\TASK.md:406-410`).

**Replace with:**

> Print one of:
> - `LIVE_WORKBOOK,unchanged` — hash and mtime are both equal.
> - `LIVE_WORKBOOK,SYNCED,<old mtime>-><new mtime>` — the mtime is later. That is a SharePoint sync:
>   drift, quoted, and it does not fail the run.
> - `LIVE_WORKBOOK,CHANGED` — the hash differs at the **same** mtime. That is a write by this run,
>   and it fails.
>
> AC14 applies the same rule.

### F9 — AC9 will fail intermittently, and it skips the tool most likely to hide a broken argument

Quoted AC9: *"For `lake-status.ps1` …, `list-extracts.ps1`, and `check-contract.ps1` … stdout …
**identical**"*.

Two problems:
- **Flakiness.** `list-extracts` prints `age_minutes`, which is
  `date_diff('minute', materialized_at, now())` (`skills\snowflake-extract\registry.sql:74`). Two
  runs seconds apart differ whenever a minute boundary falls between them.
- **Missing coverage.** `run-compat-tests.ps1` is the only tool that passes `-init`, and the only
  one that redirects stderr to a file (`2>$errFile`). Its exit code ignores row failures, because
  only `MALFORMED` sets `$hadFailure` (`:204-207,302-305`). If the shim mangled `-init`, macro mode
  would fail, the pass counts would drop, and `run-compat-tests` would still exit 0. AC5 would say
  `PASS`, and AC9 never looks at it.

Leakage (mutation 1) is still caught without `run-compat-tests`: `check-contract` parses its stdout
with `ConvertFrom-Json`, and `lake-status` turns every stdout line into a `STATUS` line.

**Replace AC9 with:**

> For `run-compat-tests.ps1`, `check-contract.ps1` on each shipped contract, `list-extracts.ps1`
> (fixture root) and `lake-status.ps1` (a scratch lake built by an unshimmed `materialize.ps1`),
> stdout run through the shim is identical to stdout run without it, and so is the exit code.
> Before comparing `list-extracts` output, replace each `age_minutes=<n>` with `age_minutes=*`.
> Show the diff output, which must be empty.

### F10 — Some entrypoints assume the repo root as working directory; entrypoint output would bury the report

Paths relative to the working directory:
- `checks\gl-facts.sql` resolves its `.read` lines against the working directory (its header, lines
  4-6).
- `run-compat-tests.ps1` resolves `-Fixture`, `-CompatFile` and its scratch directory against it
  (`:5-6,16`), and deletes and recreates `<cwd>\.duckdb-skills\run-compat-tests`.

The spec also never says where each entrypoint's own output goes. Without that, AC5's run prints
the compat tables and matching session-log text from `search.sql`.

**Add to B:**

> Every entrypoint runs with its working directory set to the repo root. Each entrypoint's stdout
> and stderr go to a scratch file, not to this script's output. The script prints only `EXT` and
> `SUMMARY` lines. For any entrypoint that is not `PASS`, it also prints that entrypoint's last 20
> output lines before removing scratch.

### F11 — The lake-status row is ambiguous and depends on run order

Quoted: *"`tools\lake-status.ps1` | `-LakeRoot <same scratch>`; and `-History Clayco_Job_Costs_from_GL`"*.

This row can be read as two runs where only the first carries `-LakeRoot`. The second would then
read the **real** lake read-only: it exists, at 8,663,040 bytes. And if lake-status runs before
materialize has built the scratch lake, it prints `no lake` having made zero `duckdb` calls, so it
is `NO_EVIDENCE` (`lake-status.ps1:67-70`).

**Replace with:**

> `-LakeRoot <scratch lake>`; and `-History Clayco_Job_Costs_from_GL -LakeRoot <scratch lake>` —
> both run after the two materialize runs, and the order is load-bearing. `-Only` on a lake-status
> label first builds the lake with an unshimmed `materialize.ps1`.

### F12 — AC4 points at a recipe that is not in that file

Quoted: *"Re-run item 6's AC18 lock recipe (see `docs\tasks\2026-09-25-item6-lakehouse-materialize\TASK.md`)"*.

That TASK.md only says *"Hold an exclusive lock on a scratch copy"* (`:396`). The actual recipe and
the verbatim output are in that folder's `RESULT-1.md:343-362`: a separate PowerShell process holds
the file open with `FileShare.None`. That recipe also used `-Contract`, which has no second
contract, so AC4 needs F2's scratch tree.

**Replace with:**

> Use item 6's lock recipe (`docs\tasks\2026-09-25-item6-lakehouse-materialize\RESULT-1.md:343-362`):
> a separate `powershell` process holds `<scratch>\wb\All_Sales_Data.xlsm` open with
> `[IO.File]::Open(<path>, 'Open', 'Read', 'None')`. Then run F2's scratch-tree `materialize.ps1`.
>
> Expected:
> - the verbatim `File is already open in …powershell.exe (PID <n>)`, with `<n>` equal to the
>   holder's PID;
> - then a `MATERIALIZE,Clayco_Job_Costs_from_GL,…` line;
> - `errored=1`, and exit non-zero.

### F13 — `-version`: I measured what happens; the spec should state it

Quoted: *"Measure what happens; if the probe cannot run, classify the call `not_a_session`"*.

I ran `duckdb -version -c "SELECT 42 AS after_version"`. It printed
`v1.5.5 (Variegata) d8cdaa33fd`, ignored the `-c` without error, and exited 0. So the probe never
runs on that call.

Classifying by outcome ("exit 0 and no probe file means not a session") would also swallow a real
probe failure, so classify by argument. Also, the spec cites `run-compat-tests.ps1:27`; the call is
at line **28**.

**Replace with:**

> Measured: `duckdb -version` ignores a trailing `-c` and exits 0, so no probe file is written. A
> call whose arguments include `-version` is `not_a_session`, decided **by argument**. Any other
> exit-0 call with an empty probe file is `probe_missing` (F5).

### F14 — `errored` is undefined, and the SUMMARY consumer search has a known answer

Quoted: *"`SUMMARY` gains a trailing `,errored=<n>`"*.

The spec never says which errors count. `materialize.ps1:260-264` (no `read_xlsx` found) already
prints `ERROR,…` and is counted in none of the four buckets.

**Add:**

> `errored` = the number of contracts that printed an `ERROR,<contract>,…` line and were counted in
> neither `refreshed`, `skipped` nor `refused`. That includes the no-`read_xlsx` case at
> `materialize.ps1:260-264`.
>
> After D, every `SUMMARY` satisfies `contracts = refreshed + skipped + refused + errored`. `forced`
> is a subset of `refreshed` (`:521-522`). AC3 and AC4 show that the sum holds.
>
> The other `exit 1` paths are unchanged and still end the run without a `SUMMARY`: the catalog
> lock at 322, and the lake-write failures at 463, 492 and 514. These are whole-lake conditions.

**Consumer search.** I ran `git grep "SUMMARY,"`. `materialize.ps1:525` is the only place the line
is produced, and no code parses it; the only other `SUMMARY,` line in code is run-assertions' own,
unrelated one. The only copies are literal strings in archived docs:

- item 6 `SHIPPED.md:25`
- item 6 `VERIFY-1.md:64`
- item 6 `RESULT-1.md:46,70,95,238,257`
- item 5b `RESULT-1.md:372,382,417`

Re-running those commands will now show `,errored=0` appended. The spec should say that this is
expected drift, not a regression, and that the archive is not edited.

### F15 — AC12 is not a literal command, and AC8 depends on other sessions

Quoted AC12: *"Evaluate `read-file`'s CASE expression against `'…/Data Extracts.xlsm'`"*.

I ran the current `.xlsx`/`.xls` arm against `'C:/x/Data Extracts.xlsm'`. It returned
`blob_case`. So AC12's first half can genuinely fail before the fix, which is good.

**Replace AC12's first half with:**

> Put the `read_any` block from `skills\read-file\SKILL.md` into `<scratch>\readany.sql`, verbatim,
> with `RESOLVED_PATH` replaced by the scratch copy's path in forward slashes. Run
> `duckdb -csv -f <scratch>\readany.sql`.
> - Before (`main`): `DESCRIBE` shows `content` as `BLOB`, and `row_count` = 1.
> - After: `DESCRIBE` shows the 2 columns of the `MetaData` sheet, and `row_count` = 2.
>
> Reading the first sheet is expected. It is why the new section exists. Do not "fix" it by adding
> `sheet=` to `read_any`.

AC8 quoted: *"afterwards no `duckdb.exe` exists that was not in the recorded set"*. Phil often has
other sessions running, and any of them can start a `duckdb.exe` in that window.

**Replace with:**

> …prints `HUNG` with `elapsed` ≤ 15 s. Afterwards, no `duckdb.exe` whose `Win32_Process.CommandLine`
> contains the control's scratch `.sql` path is still running.

### F16 — Smaller items: fix these in the same revision

- **Pin the entrypoint labels and their count.** AC5's *"(materialize and lake-status twice each)"*
  leaves out that check-contract also runs twice. With F1 there are 15 labelled runs, so pin
  `SUMMARY,entrypoints=15,…`. List the labels, for example `check-contract:GL`,
  `check-contract:All_Sales_Data`, `materialize:1`, `materialize:2`, `lake-status`,
  `lake-status:history`. `-Only` takes these names.
- **The live path is written in the wrong form for the guard.** The spec writes it with
  backslashes (`TASK.md:122`), but both contracts hold it **once each, in forward-slash form**. I
  checked: forward-slash count 1, backslash count 0, per contract. Say so, or the guard trips on
  its first run.
- **"against scratch locations only" is not true for every row.** `check-contract`,
  `run-assertions` and `materialize` (without `-Contract`) all read the **live** workbook,
  read-only, through the shipped contracts. State that rather than claim scratch.
- **The timing table is not complete.** It says *"every PowerShell entrypoint"* but omits
  `make-truncation-fixtures.ps1`, `extract-decide.ps1` and `search.sql`. `search.sql` scans 1,096
  files (180.3 MB) under `~\.snowflake\cortex\conversations`. Measure it before relying on 120 s.
  The "every" claim was inferred, not measured.
- **Say which `DSK_*` variables `search.sql` needs.** Set `DSK_KEYWORD='lakehouse'` and
  `DSK_CWD=''` in this script's process only.
- **Clarify the `read-file` exclusion in B.** B excludes `read-file` because it "does not run on
  Windows", but C relies on sessions reading that same skill on Windows. Say the exclusion is about
  probing the bash skills, not about the text.

### F17 — Scope: part D is Phil's decision, not the spec's

PLAN-4 §7 does not ask for any change to `materialize.ps1`. Part A does not need D either: A's steps
never re-materialize after the workbook is removed. That was an observation made while measuring,
not a step.

D changes shipped item-6 behaviour and item 6's output contract (`SUMMARY`). It also brings in
most of this spec's risk: F2, F4, F12, F14, and the scratch tree.

It is a real defect, small, and honestly disclosed. It is still expansion, so it should be put to
Phil explicitly rather than ride inside item 7. If he declines, cut D, AC3, AC4, mutation 5 and the
SUMMARY search. If he accepts, add one sentence under the `Serves:` line saying so.

Item 6 checks that D does **not** break:
- **AC17** (catalog lock): the `exit 1` at 322 is untouched.
- **AC18** (locked workbook): verbatim `IO Error` with PID, non-zero exit, table unchanged. All of
  it still holds with `-Contract`.
- **AC0's `SUMMARY` literal**: this changes, but only as the drift described in F14.

## Drift from the plan (PLAN-4 §7, `PLAN-4.md:615-629`)

- **Drift, disclosed and justified.** The plan's Serves test was *"point the contract at a
  nonexistent path"*. The spec removes the workbook instead, because a lake query never evaluates
  the contract. The plan's *"pinned GL row count"* becomes a count computed in the same run,
  because the workbook moved: 61,741 → 62,377. The plan's `duckdb_extensions()` check becomes an
  in-process probe, because a fresh process proves nothing. And *"within budget"* becomes a 120 s
  hang detector. All four are argued in the spec's measured facts, and none needs changing.
- **Omission.** None. The routing decision, the behavioural non-goal and the Serves test are all
  present.
- **Silent expansion.** Part D (F17). The `lakehouse` sentence and the `.xlsm` CASE arm are small
  and sit inside "workbook routing", so they are acceptable.
- **Header.** `Plan: PLAN-4.md` is the newest version, and it is unedited since its only commit
  (`fb4eecb`).

## Weak acceptance checks

| check | why it is weak | stronger version |
|---|---|---|
| AC7 | Can never be `NO_EVIDENCE`: the control's non-zero exit makes it `FAIL` first, so mutation 3 cannot fail it. | F3 — a control that exits 0, with exactly `NO_EVIDENCE` required |
| AC10 | `calls = probed + unprobed` is true by arithmetic if `unprobed` is derived from it. Probe-file collisions pass. | F5 — distinct probe paths = calls; `probe_missing` = 0 |
| AC3 / AC4 | Cannot be run without a multi-contract scratch setup. "First-processed" is undefined. The two contracts share one workbook. | F2 and F12, with the literal expected lines |
| Mutation 5 | Targets a line the fix repurposes. AC3 would still pass. | F4 — 5a and 5b |
| AC9 | `age_minutes` makes it fail intermittently. It skips `run-compat-tests`, whose exit code hides a broken `-init`. | F9 |
| AC8 | "No new `duckdb.exe`" fails if another session starts one. "About 3 s" has no bound. | F15 — match on command line; `elapsed` ≤ 15 s |
| AC12 | "Evaluate the CASE expression" is not a command. | F15 — run the skill's block verbatim; before `BLOB`, 1 row; after 2 columns, 2 rows |
| AC14 / step 8 | Fails on a normal SharePoint sync. | F8 — the item-6 AC20 rule |
| AC11 | Passes on an untouched repo, because `PATH` is changed only inside the process. It can fail only if the implementer persisted `PATH`. | Keep it, but label it a control |
| AC2, first mutation | Querying `contract_view` in a fresh process fails for "view not defined", whatever the workbook's state. It proves little. | Add a mutation that skips step 5 (the workbook stays present). The line must then `FAIL`. For that to work, PASS must also require a `workbook_present=false` measured by `Test-Path` at step 6, not a hard-coded literal. |

**Checks I actually ran.** All were read-only or in-memory `duckdb`.

- **Live-path count in each contract:** forward-slash 1, backslash 0, for both contracts.
- **AC12 control:** today's CASE returns `blob_case` for `.xlsm`.
- **`duckdb -version -c …`:** the `-c` is ignored and exit is 0.
- **`-init` + `-f` + `-c` ordering:** the init file runs first, and the probe runs last with the
  file's loads visible. `-- Loading resources from …` goes to stderr only.
- **Extension state:** `fts`, `snowflake`, `ducklake`, `excel` and `polyglot` are all installed and
  none are loaded.
- **`duckdb` calls in `tools\`:** every call is `& duckdb …` resolved through `PATH`. There is no
  absolute `duckdb.exe`, no `Start-Process` and no `cmd /c`, so the shim intercepts every call,
  including in the nested `powershell -File` children.
- **Arguments passed to `duckdb`:** only flags and file paths under `$env:TEMP` or the repo, with no
  spaces, `%` or quotes. SQL always travels in files, and the `Clayco, Inc` path appears only inside
  SQL files. So `.cmd` mangling is not a live risk for today's tools. It becomes one only if a
  worktree or scratch path contains `%`, `^`, `&` or `!`, and F9 adds the check that would catch it.
- **Snowflake-loading SQL:** no `TYPE snowflake`, `LOAD snowflake` or `INSTALL snowflake` appears in
  any `.sql`, `.ps1` or `.csv`.
- **Sandbox settings:** none in `tools\*.ps1`.

**Checks that cannot be run yet.** AC1, AC2, AC5-AC10 and AC13 depend on tools that do not exist
yet, so they fail on the unmodified repo.

## Safety

- **Loading `snowflake`.** I found no route in the spec as written. The probe calls only
  `duckdb_extensions()`, which lists extensions without loading any. The controls use `fts`.
  Nothing in the repo attaches with `TYPE snowflake`. That matters, because autoload is on and the
  extension is installed, so an `ATTACH … (TYPE snowflake)` could load it; keep this in "Out of
  scope".
- **Writing to the live workbook.** The one real risk is F7: under AC2's mutation, step 5 could
  rename or delete the live workbook.
- **Touching the real lake.** Only through F11's ambiguous `-History` row, and that is read-only.
  Otherwise the real lake is untouched.
- **Side effect of default roots.** A default-root run creates an empty
  `~\.duckdb-skills\<worktree-id>\` directory. F1 removes this.