# RESULT-1 -- item 1: one project, chosen deliberately

Branch `item1-project-resolution`, from main a3d7e7f. All checks run through the spec's
`Start-Process -RedirectStandardOutput/-RedirectStandardError` capture. `$W` = throwaway
worktree at the implementation commit, `$B` = throwaway worktree at `git merge-base HEAD main`
(a3d7e7f); both removed afterwards. Scratch folders lived under `%TEMP%` and are deleted.
Cleanup of `~\.duckdb-skills\<G id>\` was guarded (id must start with
`c-users-woodsonp-appdata-local-temp-`); the real project folders and the `_verify-*` folders
were never touched.

## Files changed

- `tools\dsk-paths.ps1` -- new `Get-ProjectRootOrNull`, `Get-ProjectRoot` (throws the refusal),
  `Write-ProjectNote` (stderr via `[Console]::Error.WriteLine`); `Get-ProjectId` uses it (no
  current-folder fallback); `-Create` and `-Hint` on both resolvers (nothing created without
  `-Create`, explicit roots included); header comment rewritten.
- `tools\lake-status.ps1`, `list-extracts.ps1`, `extract-status.ps1`, `extract-decide.ps1` --
  catch refusal (`Write-Output`, `exit 2`), then `Write-ProjectNote`. `list-extracts` header
  comment no longer claims the default root is created.
- `tools\cross-query.ps1` -- catch refusals on both resolvers (exit 2); project note printed once
  (`$projectNoted`); no lake now refuses for `-Save` as well as for lake inputs (decision 5).
- `tools\materialize.ps1` -- project check before any resolver (needs `-LakeRoot` and
  `-Contract` outside a repo); contracts dir = `<project root>\contracts`; `Resolve-LakeRoot
  -Create`; `contracts: <folder>` on stderr at discovery.
- `tools\run-assertions.ps1` -- dot-sources `dsk-paths.ps1`; same project resolution
  (`-Contract` needed outside a repo); contracts dir from project root; writes its project line.
- `tools\publish-extract.ps1` -- `Resolve-ExtractRoot -Create`; project note.
- `tools\ensure-duckdb-compat.ps1` -- own `Get-RepoRoot` deleted; shared resolver; `-StateFile`
  bypass; project note.
- `tools\prove-no-snowflake.ps1:326` -- `Continue` wrapped around the materialize call (decision 8).
- `skills\lakehouse\SKILL.md`, `skills\snowflake-extract\SKILL.md` -- one "Which project the
  tools act on" paragraph each; snowflake-extract step 1 also says to create `<root>` if missing.

## Acceptance checks

**AC1 -- PASS.** From `$S` (non-repo, empty), all nine tools, each exit 2, stderr empty, stdout a
single line `ERROR: not inside a git repository: C:\Users\woodsonp\AppData\Local\Temp\dsk_S1. Run
from your project folder, or pass <opts>.` with opts = `-LakeRoot` (lake-status, cross-query),
`-ExtractRoot` (list-extracts, extract-status, extract-decide, publish-extract),
`-LakeRoot and -Contract` (materialize), `-Contract` (run-assertions), `-StateFile`
(ensure-duckdb-compat). `snap` equal before/after: True. `$S` empty: True. `$Q` held only
`lakex.sql` (publish-extract's `nostage` not created).

**AC2 -- PASS.**
- `lake-status -LakeRoot $S\nolake`: stdout `no lake`, exit 0, stderr `project: none (explicit
  roots)`, `$S\nolake` exists: False.
- `materialize -LakeRoot $Q\lake` (no contract): exit 2 with the refusal
  (`... pass -LakeRoot and -Contract.`), `$Q\lake` exists: False.
- `materialize -LakeRoot $Q\lake -Contract $W\contracts\Clayco_Job_Costs_from_GL.sql`: exit 1;
  stdout included `LAKE_ROOT,...\dsk_Q2\lake`,
  `MATERIALIZE,Clayco_Job_Costs_from_GL,REFUSED,reason=checks_failed`,
  `SUMMARY,contracts=1,refreshed=0,skipped=0,refused=1,...`; stderr `project: none (explicit
  roots)`; `$Q\lake\lake.ducklake` exists: True. (REFUSED path is the one the spec allows; the
  workbook's `I3 'City of DeKalb'` error appears as an `ERROR,` line.)

**AC3 -- PASS.** `<G id>` = `c-users-woodsonp-appdata-local-temp-dsk_g3`. From `$G`:
- `lake-status`: `no lake`, exit 0.
- `list-extracts`: exactly the three specified lines, exit 0.
- `extract-status`: `no extracts registered under C:\Users\woodsonp\.duckdb-skills\<G id>\extracts`, exit 0.
- `extract-decide -Name x`: `REFRESH (no sidecar)`, exit 0.
- `cross-query -Sql $Q\lakex.sql -Save t`: `ERROR,lake,no lake at C:\Users\woodsonp\.duckdb-skills\<G id>\lake -- run tools\materialize.ps1 first`, exit 1.
- All five stderr: `project: <G id> (C:\Users\woodsonp\AppData\Local\Temp\dsk_G3)`.
- `snap` equal: True; `<G id>` folder exists: False.

**AC4 -- PASS.** `$G` with `contracts\` holding only `Clayco_Job_Costs_from_GL.sql`; `materialize`
from `$G`, no options: exit 1; stderr
`project: <G id> (...\dsk_G3)` + `contracts: C:\Users\woodsonp\AppData\Local\Temp\dsk_G3\contracts`;
stdout `MATERIALIZE,Clayco_Job_Costs_from_GL,REFUSED,reason=checks_failed` and
`SUMMARY,contracts=1,...`; `~\.duckdb-skills\<G id>\lake\lake.ducklake` exists: True.
`lake-status` from `$G`: `STATUS,Clayco_Job_Costs_from_GL,...,outcome=REFUSED`. Guarded cleanup run.

**AC5 -- PASS.** `<R>` = the real project folder; `list-extracts -ExtractRoot`, `extract-status
-Name parent_projects -ExtractRoot`, `lake-status -LakeRoot`, from `$B` and `$W`: all exit 0 in
both; stdout identical after the specified masks (True x3); `$B` stderr empty; `$W` stderr exactly
`project: c-users-woodsonp-appdata-local-temp-dsk_w (C:\Users\woodsonp\AppData\Local\Temp\dsk_W)`;
`snap` equal: True. (Real lake-status showed All_Sales_Data snapshot 22 and Clayco_Job_Costs_from_GL
snapshot 25, both MATERIALIZED -- untouched.)

**AC6 (control) -- PASS.** New repo `$G`, `~\.duckdb-skills\<G id>` absent beforehand. `publish-extract
-Name ac6_demo ...` (sidecar passed as `-SidecarJson`, four stamped fields omitted): stdout
`published C:\Users\woodsonp\.duckdb-skills\c-users-woodsonp-appdata-local-temp-dsk_g6\extracts\ac6_demo`,
exit 0; `list-extracts` then listed `name=ac6_demo age_minutes=0 row_count=1 size_bytes=910 ...`.
Guarded cleanup run.

**AC7 -- PASS.** `ensure-duckdb-compat` from `$G`: exit 0; stdout line 1
`C:\Users\woodsonp\AppData\Local\Temp\dsk_G3\.duckdb-skills\state.sql`; state.sql holds exactly one
line, `.read C:/Users/woodsonp/AppData/Local/Temp/dsk_W/skills/query/duckdb-compat.sql`; stderr
`project: <G id> (...\dsk_G3)`.

**AC8 -- PASS.** From `$W`, `prove-no-snowflake.ps1 -Only lake-status`: exit 0; last lines:
`EXT,lake-status,exit=0,elapsed=0.9,calls=1,probed=1,unprobed=0,not_a_session=0,probe_missing=0,loaded=autocomplete;core_functions;ducklake;icu;json;parquet;shell,PASS`
`SUMMARY,entrypoints=1,pass=1,fail=0,no_evidence=0,hung=0,forbidden=snowflake`. `snap` equal: True.
(I did not separately demonstrate the throw at the base commit.)

**M1 -- PASS (fails then passes).** Mutated `$contractsDir` in `$W\tools\materialize.ps1` back to
`<script parent>\contracts`: AC4 run gave `contracts: ...\dsk_W\contracts` and
`SUMMARY,contracts=2,...` (both shipped contracts). After `git checkout --` of the file: `contracts=1`.

**M2 -- PASS (fails then passes).** Made `Resolve-ExtractRoot` ignore `-Create` in `$W`: AC3 `snap`
equal: False, diff = `...\dsk_g5` and `...\dsk_g5\extracts` (cleaned with guard). After revert:
`snap` equal: True.

## Deviations

- The refusal text's option list is per tool (listed in AC1) since the spec said "the explicit
  option(s) this tool accepts"; wording otherwise exactly as specified.
- Final check ("Phil runs this himself") and the real default lake: NOT run, per instructions.
- `publish-extract` resolves/creates the extract root before its `-StagingDir does not exist`
  check (as at base order); after a non-repo refusal nothing is created, but in a repo a bad
  `-StagingDir` leaves an empty extract root. Spec decision 3 only covers refusals.

## Not done

Nothing in the spec left undone. `skills\query`, `attach-db`, README, `_verify-*` folders and the
failing contracts untouched, per Out of scope.

## Concerns

- Both shipped contracts REFUSE against today's workbook (stated in the spec; not touched).
- `cross-query`'s duplicate resolver call at the "run" stage (old line ~674) is now dead code
  (never reached with the resolver unset); left as is to stay minimal.
- `ensure-duckdb-compat` still emits its `NOTE: home-side state files exist` line (stdout) as before.
- Tool runs under Windows show the project path in the case git reports it (e.g. `dsk_W`); the
  id is lower-cased as before.
