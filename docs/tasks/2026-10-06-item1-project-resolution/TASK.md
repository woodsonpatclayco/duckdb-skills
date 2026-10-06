Plan: PLAN-5.md
Serves: **A tool run from the wrong folder stops and says so, instead of quietly building or
reading a second lakehouse.** This is item 1 of 4 in deploying duckdb-skills to Claude Code.
Once the skills are available in every Claude Code session, they will be run from every kind of
folder. So the project they act on has to be chosen deliberately before deployment.

# Item 1 — One project, chosen deliberately

PLAN-5 §"Item 1", plus facts 2–4.

## Measured facts this spec rests on — taken 2026-10-06 on this machine

- **Three things decide "which project" today, and nothing makes them agree.**
  - **Lake and extract roots:** `Get-ProjectId` (`tools\dsk-paths.ps1`) uses the git root of
    the current folder, or **the current folder itself** when it is not in a git repo.
  - **Contracts folder:** `materialize.ps1:119-120` and `run-assertions.ps1:139-140` use
    `<parent of the script's folder>\contracts`.
  - **State file:** `ensure-duckdb-compat.ps1:11-22` has its own `Get-RepoRoot`, with the
    same current-folder fallback.
- **The resolvers create folders on every call.**
  - **Default roots:** `Resolve-ExtractRoot` and `Resolve-LakeRoot` run `New-Item -Force` on
    the default root.
  - **Explicit roots:** `Resolve-LakeRoot` also creates an explicit `-LakeRoot`.
  - **Effect:** read-only tools create folders as a side effect of being asked what exists.
  - **Evidence:** the current-folder fallback already produced
    `~\.duckdb-skills\c-users-woodsonp-claude-dev-_verify-2a`, `…-_verify-2b` and
    `…-_verify-2b-r2`.
- **Resolver callers.**
  - **Read-only:** `lake-status.ps1:61`, `list-extracts.ps1:72`, `extract-status.ps1:116`,
    `extract-decide.ps1:194`, `cross-query.ps1:483,549,674`.
  - **Writing:** `materialize.ps1:135` and `publish-extract.ps1:85`.
  - **`materialize`'s order:** it resolves the lake (`:135`) **before** discovering contracts
    (`:149`).
- **Today's "nothing yet" outputs, measured at the base commit.**
  - `lake-status` prints `no lake`, exit 0.
  - `list-extracts` and `extract-status` (no `-Name`) print `no extracts registered under
    <root>`, exit 0.
  - `extract-decide -Name x` prints `REFRESH (no sidecar)`, exit 0.
  - `cross-query` refuses a missing lake with `ERROR,lake,no lake at <root> -- run
    tools\materialize.ps1 first`, **exit 1** (`cross-query.ps1:556`).
- **`cross-query -Sql` takes a path to a `.sql` file**, not SQL text (`cross-query.ps1:2`).
  - **No inputs:** a query that references no extract and no lake table is refused at `:460`,
    before the lake is looked at.
- **`materialize`'s outcome words:**
  - **First run of a contract:** `MATERIALIZE,<name>,REFRESHED,<rows>,reason=no_manifest`
    (`:531`).
  - **Failed checks:** `MATERIALIZE,<name>,REFUSED,reason=checks_failed`, exit 1.
  - **Where `MATERIALIZED` appears:** only in `lake-status`'s `outcome=` column.
- **Both shipped contracts fail their checks against today's workbook.** `Data Extracts.xlsm`
  was modified 2026-10-06 11:39. Measured with `run-assertions -Contract`:
  - **`Clayco_Job_Costs_from_GL`:**
    - `ASSERT,glperiod_ratio_floor,FAIL`;
    - `read_xlsx: Failed to parse cell 'I3': Could not convert string 'City of DeKalb' to
      DOUBLE`.
  - **`All_Sales_Data`:**
    - `ASSERT,matchproject_ratio_floor,FAIL`;
    - `SNAPSHOT_DRIFT` on `enddate_nn` (145→377), `salesyear_distinct` (4→9) and
      `earntotal_nn` (201→445).

  Any `materialize` of a real contract today ends `REFUSED`. That is **not** an item-1 defect,
  and no check below may depend on the contracts passing.
- **Promised stdout lines that must not move.**
  - **`ensure-duckdb-compat`:** its line 1 is the state-file path.
  - **`extract-status -Name`:** its line 1 is the age in minutes.
  - **`list-extracts`:** its `project-id:` and `extract root:` headers (item 2a AC1).
  - **`materialize`:** its `LAKE_ROOT,…` line and its CSV result lines.
- **How `materialize` handles `run-assertions`' stderr.**
  - **Merged:** `materialize` runs `run-assertions` as a child with stderr merged
    (`materialize.ps1:384-388`, `Continue` set around it).
  - **Ignored:** its parser (`:402-436`) acts only on lines matching its own prefixes, so an
    extra stderr line is ignored.
- **PowerShell 5.1 stderr behaviour, measured by the reviewer.**
  - **`[Console]::Error.WriteLine` works:** it reaches a child's stderr cleanly when the
    child is run via `Start-Process … -RedirectStandardError`.
  - **`powershell -File … 2> file` mangles it:** the file gets
    `powershell.exe : project: …` plus `At line…` wrapper lines.
  - **Under `$ErrorActionPreference='Stop'`:** `2>&1` and `2>$null` both turn the first
    stderr line into a terminating error.
  - **`Write-Host`** goes to stdout under `powershell -File`.
- **`prove-no-snowflake.ps1:326`** runs `materialize` with `2>&1 | Out-Null` under script-level
  `Stop` (`:54`). It will throw once `materialize` writes to stderr. The other callers were
  checked and are unaffected:
  - `prove-requery.ps1:142` already sets `Continue`.
  - `Invoke-Entrypoint` uses ProcessStartInfo.
  - The `make-*` scripts and `run-compat-tests` call none of these tools.
- **Neither `C:\Users\woodsonp` nor `%TEMP%` is inside a git repo.** A `git worktree` is its own
  git root, so a tool run in a worktree resolves to a project named after the worktree path.

## Decisions

1. **The project root is the git root of the current folder. There is no fallback.**
   `Get-ProjectId`'s current-folder branch is deleted. A new function in `dsk-paths.ps1`
   returns the project root or throws a refusal. Every tool and `Get-ProjectId` use it.
2. **The refusal is**
   `ERROR: not inside a git repository: <current folder>. Run from your project folder, or pass
   <the explicit option(s) this tool accepts>.`
   - **Exit code:** 2.
   - **Output:** the refusal is the only stdout. Nothing goes to stderr and nothing is
     created.
   - **Tools that need a new catch:** `lake-status`, `materialize`, `cross-query`,
     `run-assertions` and `ensure-duckdb-compat` have no try/catch around resolution today.
     Add one that prints the message with `Write-Output` and runs `exit 2`, as
     `list-extracts.ps1:71-76` does.
3. **Explicit options bypass the project, but only for what they name.**
   - **`-LakeRoot` / `-ExtractRoot`:** lake and extract tools can run outside a repo.
   - **`-StateFile`:** `ensure-duckdb-compat` can run outside a repo.
   - **`materialize` and `run-assertions`** also need `-Contract <path>` outside a repo.
   - **Every refusal happens before any resolver is called with `-Create`.**
4. **The contracts folder is `<project root>\contracts`** for default discovery in `materialize`
   and `run-assertions`. The compat file, `run-assertions.ps1` and `check-contract.ps1` stay
   found by `$PSScriptRoot`.
5. **The resolvers create nothing unless the caller passes `-Create`.**
   - **Covers both kinds of root:** explicit and default.
   - **Who passes it:** only `materialize` and `publish-extract`.
   - **What read-only tools print instead:** their existing "nothing yet" answers, unchanged.

   **Two behaviour changes follow, and both are intended:**
   - **`publish-extract -ExtractRoot <missing folder>` now creates it.** Today it fails at
     `Directory.Move`.
   - **`cross-query -Save` with no lake now refuses**, with the existing `no lake at`
     message, exit 1. Today an extract-only `-Save` creates a lake as a side effect.
     Materializing is how a lake starts.
6. **The resolved project goes to stderr, written with `[Console]::Error.WriteLine(...)`.**
   - **Not `Write-Host`:** under `powershell -File` it goes to stdout.
   - **Not `Write-Error`:** it is terminating under `Stop`.

   **Departs from PLAN-5.** The plan put project lines on stdout wherever no format was
   promised. All of them go to stderr instead, because then no stdout line in any tool moves.
   `materialize` already prints `LAKE_ROOT` on stdout and `list-extracts` already prints its
   roots. The stderr line is printed exactly once per run:

   | situation | stderr | stdout |
   |---|---|---|
   | inside a repo, any options | `project: <id> (<root>)` | normal |
   | outside a repo, explicit options cover everything | `project: none (explicit roots)` | normal |
   | outside a repo, a default is needed | nothing | the refusal only, exit 2 |

   - **`materialize` also writes `contracts: <folder>`** when it discovers contracts.
   - **`run-assertions` writes its line like every other tool.** `materialize` merges it,
     harmlessly (see the facts). Do not add a silent mode.
7. **`ensure-duckdb-compat` uses the shared resolver.** Its own `Get-RepoRoot` is deleted.
   Inside a repo its behaviour is unchanged, line 1 included.
8. **Development scaffolding keeps its path logic, with one exception:** the fix at
   `prove-no-snowflake.ps1:326`.
   - **The fix:** wrap that call in
     `$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; …;
     $ErrorActionPreference = $prevEap`, the idiom `prove-requery.ps1:140-144` uses.
   - **Nothing else in scaffolding changes.**

## Deliverables

- **`tools\dsk-paths.ps1`:**
  - the project-root function;
  - `Get-ProjectId` uses it;
  - `-Create` on both resolvers;
  - the header comment rewritten for the new rules.
- **The nine tools** — `lake-status`, `list-extracts`, `extract-status`, `extract-decide`,
  `cross-query`, `materialize`, `run-assertions`, `publish-extract`, `ensure-duckdb-compat` —
  changed per decisions 1–7.
- **`prove-no-snowflake.ps1:326`**, per decision 8.
- **Skills:**
  - `skills\lakehouse\SKILL.md` and `skills\snowflake-extract\SKILL.md` each gain one short
    paragraph:
    - the tools run inside the project's git repo, or with explicit roots;
    - read-only tools never create folders;
    - the `project:` line on stderr names what was resolved.
  - Step 1 of `snowflake-extract` also tells the model to create `<root>` if it is missing,
    before `<root>\<name>.new\`.
- **`RESULT-1.md`** at repo root.

## Out of scope — do not do these

- **Skill paths to scripts:** that is item 2.
- **`state.sql` line replacement and gitignoring `.duckdb-skills\` in other projects:** also
  item 2.
- **The `PROJECT_ROOT=… || echo "$PWD"` lookups** in `skills\query\SKILL.md` and
  `skills\attach-db\SKILL.md`, and `README.md`. Leave them unchanged.
- **The `_verify-*` folders** under `~\.duckdb-skills\`: do not delete them.
- **Freshness, checks, the extract registry and `cross-query`'s join logic:** no changes.
- **The failing contracts:** do not fix or touch them. Phil handles that separately.
- **The real lake and extracts:** run nothing against
  `~\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\` except AC5's read-only
  commands.

## Conventions

- PowerShell 5.1 and absolute paths. Use exit codes 2 for usage or refusal and 1 for errors.
- **The verifier works in a throwaway `git worktree` at the implementer's commit**, called `$W`.
  It resolves to its own project id. That is expected.
- **How every tool is run in the checks.** Each run is a child process:

  ```powershell
  $p = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',<tool>,<args…> `
       -WorkingDirectory <dir> -RedirectStandardOutput <o.txt> -RedirectStandardError <e.txt> `
       -NoNewWindow -Wait -PassThru
  ```

  - **Meaning of the words:** "stdout" and "stderr" mean those two files, and the exit code is
    `$p.ExitCode`.
  - **Never** use `2>` or `2>&1` on a `powershell` call to capture stderr.
- **Scratch folders.** Make fresh ones per check.
  - **`$S`:** a folder under `%TEMP%` that is not inside a git repo. It stays empty and is the
    working directory.
  - **`$Q`:** a second non-repo folder for inputs.
  - **`$G`:** a folder under `%TEMP%` with `git init` run in it. Its id is
    `<G id>` = `Get-ProjectId` run there.
- **`$Q\lakex.sql`** contains `SELECT * FROM lake.x`.
- **`snap`:**
  `Get-ChildItem -Recurse -Directory ~\.duckdb-skills | ForEach-Object FullName | Sort-Object`.
  "Unchanged" means `snap` is equal before and after. If another session visibly changed the
  real project's folders mid-check, quote that as drift, not as a failure.
- **Guarded cleanup.** Before deleting `~\.duckdb-skills\<G id>\`, assert that `<G id>` starts
  with `c-users-woodsonp-appdata-local-temp-`. Delete that folder only.

## Acceptance checks

**AC1 — Outside a repo, every tool refuses and creates nothing.**
- **Setup:** from `$S`, take `snap`.
- **Run each of the following** (all under `$W\tools\`):
  - `lake-status`, `list-extracts` and `extract-status`;
  - `extract-decide -Name x`;
  - `cross-query -Sql $Q\lakex.sql`;
  - `materialize` and `run-assertions`;
  - `ensure-duckdb-compat`;
  - `publish-extract -Name x -StagingDir $Q\nostage -SidecarJson '{}'`.
- **Expect, for each:**
  - exit **2**;
  - stdout is the single line starting `ERROR: not inside a git repository: <$S>`;
  - stderr is empty.
- **Afterwards:** `snap` is unchanged and `$S` is empty.

**AC2 — Outside a repo, explicit roots work, and refusals still create nothing.**
- **From `$S`, `lake-status -LakeRoot $S\nolake`:**
  - prints `no lake`, exit 0;
  - stderr is `project: none (explicit roots)`;
  - **`$S\nolake` does not exist afterwards.** At the base commit it would. This is the real
    check.
- **From `$S`, `materialize -LakeRoot $Q\lake` with no `-Contract`:**
  - exits 2 with the refusal;
  - **`$Q\lake` does not exist afterwards.**
- **From `$S`,
  `materialize -LakeRoot $Q\lake -Contract $W\contracts\Clayco_Job_Costs_from_GL.sql`:**
  - **stdout:** a `MATERIALIZE,Clayco_Job_Costs_from_GL,` line followed by either
    `REFRESHED` or `REFUSED,reason=checks_failed`. The live workbook decides which, and either
    proves the routing.
  - **exit code:** 0 or 1 to match.
  - **on disk:** `$Q\lake\lake.ducklake` exists.
  - **stderr:** contains `project: none (explicit roots)`.

**AC3 — In a brand-new repo, read-only tools answer "nothing yet" and create nothing.**
- **Setup:** from `$G`, take `snap`.
- **`lake-status`:** stdout `no lake`, exit 0.
- **`list-extracts`:** stdout is exactly three lines, exit 0:
  - `project-id: <G id>`
  - `extract root: C:\Users\woodsonp\.duckdb-skills\<G id>\extracts`
  - `no extracts registered under C:\Users\woodsonp\.duckdb-skills\<G id>\extracts`
- **`extract-status`:** stdout
  `no extracts registered under C:\Users\woodsonp\.duckdb-skills\<G id>\extracts`, exit 0.
- **`extract-decide -Name x`:** stdout `REFRESH (no sidecar)`, exit 0.
- **`cross-query -Sql $Q\lakex.sql -Save t`:** stdout
  `ERROR,lake,no lake at C:\Users\woodsonp\.duckdb-skills\<G id>\lake -- run tools\materialize.ps1 first`,
  exit 1.
- **Every one of these five:** stderr is `project: <G id> (<$G>)`.
- **Afterwards:** `snap` is unchanged, so no `<G id>` folder exists.

**AC4 — Contracts come from the project, not from the script's folder.**
- **Setup:** in `$G`, create `contracts\` holding a copy of **only**
  `Clayco_Job_Costs_from_GL.sql`.
- **Run:** from `$G`, run `$W\tools\materialize.ps1` with no options.
- **Expect:**
  - **stderr:** includes `project: <G id> (<$G>)` and `contracts: <$G>\contracts`.
  - **stdout:** includes `SUMMARY,contracts=1,` and one
    `MATERIALIZE,Clayco_Job_Costs_from_GL,(REFRESHED|REFUSED)` line.
  - **on disk:** `~\.duckdb-skills\<G id>\lake\lake.ducklake` exists.
- **Discriminator:** under the old rule this run processes `$W`'s **two** contracts
  (`contracts=2`).
- **Then:** `lake-status` from `$G` lists `Clayco_Job_Costs_from_GL` (any `outcome=`).
- **Cleanup:** the guarded cleanup.

**AC5 — Promised stdout is unchanged; the project goes to stderr.**
- **Base:** `git merge-base HEAD main`, checked out as a second throwaway worktree `$B`.
- **Run from both `$B` and `$W`,** pointed read-only at the real roots:
  - `list-extracts -ExtractRoot <R>\extracts`;
  - `extract-status -Name parent_projects -ExtractRoot <R>\extracts`;
  - `lake-status -LakeRoot <R>\lake`.
  - Here `<R>` = `C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills`.
- **Masks before comparing:**
  - in `list-extracts`, `age_minutes=\d+` → `age_minutes=N`;
  - in `extract-status`, line 1 `^\d+$` → `N`.
- **Expect:**
  - stdout is identical between `$B` and `$W`;
  - `$W` stderr is exactly one line, `project: <W id> (<$W>)`;
  - `snap` is unchanged.

**AC6 (control) — `publish-extract` still creates the extract root in a new repo.** This passes
at base too. It guards against `publish-extract` losing `-Create`.
- **Setup:**
  - from `$G`, assert that `~\.duckdb-skills\<G id>` does not exist;
  - build the staging dir `$G\stage\ac6_demo` with
    `duckdb -c "COPY (SELECT 1 AS a) TO '<stage>/data.parquet'"`.
- **Run:**
  `publish-extract -Name ac6_demo -StagingDir $G\stage\ac6_demo -SidecarJson <json>` with
  this sidecar:
  `{"name":"ac6_demo","query":"SELECT 1 AS a","source_objects":["DB.S.T"],"row_count":1,"output_bytes":<file size>,"connection":"DATAHUB","role":"R","database":"DB","warehouse":"WH","source_rows":[1],"source_bytes":[1],"source_last_altered":["2026-10-06T00:00:00Z"]}`
  - **Do not supply the four stamped fields.** `publish-extract.ps1:65-69` exits 3 if they
    are given.
- **Expect:**
  - stdout `published C:\Users\woodsonp\.duckdb-skills\<G id>\extracts\ac6_demo`, exit 0;
  - `list-extracts` from `$G` then lists `ac6_demo`.
- **Cleanup:** the guarded cleanup.

**AC7 — `ensure-duckdb-compat` inside a repo.**
- **Run:** from `$G`.
- **Expect:**
  - stdout line 1 is `<$G>\.duckdb-skills\state.sql`;
  - that file has exactly one `.read …duckdb-compat.sql` line (control: this also holds at
    base);
  - **stderr is `project: <G id> (<$G>)`**, which is the new part.

**AC8 — The scaffolding fix holds.** From `$W`, `prove-no-snowflake.ps1 -Only lake-status` gets
past its materialize call without throwing. Quote its last lines.

## Mutation proofs — each must fail, then pass again after revert

- **M1:** point the contracts folder back at `<script's parent>\contracts`. **AC4 must fail**
  with `contracts=2`.
- **M2:** make `Resolve-ExtractRoot` always create the root, ignoring `-Create`. **AC3 must
  fail**, because `snap` changes. Run the guarded cleanup afterwards.

Mutate only inside `$W`. Revert by re-checking-out the committed file there.

## Final check — Phil runs this himself after merge

```powershell
cd C:\Users\woodsonp\Claude\Dev\duckdb-skills; .\tools\materialize.ps1
```

**Expect:**
- **stderr:**
  `project: c-users-woodsonp-claude-dev-duckdb-skills (C:\Users\woodsonp\Claude\Dev\duckdb-skills)`
  and `contracts: C:\Users\woodsonp\Claude\Dev\duckdb-skills\contracts`.
- **stdout:** one `MATERIALIZE,…` line each for `All_Sales_Data` and
  `Clayco_Job_Costs_from_GL`, and `SUMMARY,contracts=2,…`.

**Until the workbook issue is resolved, both are expected to be `REFUSED,reason=checks_failed`.**
That writes REFUSED rows into the real lake's history, which is how the lake records a refused
refresh. It does not change the served data.
