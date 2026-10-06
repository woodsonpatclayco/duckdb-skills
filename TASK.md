Plan: PLAN-5.md
Serves: **A tool run from the wrong folder stops and says so, instead of quietly building or
reading a second lakehouse.** This is item 1 of 4 in deploying duckdb-skills to Claude Code.
Once the skills are available in every Claude Code session, they will be run from every kind of
folder, so the project they act on has to be chosen deliberately before deployment.

# Item 1 — One project, chosen deliberately

PLAN-5 §"Item 1", plus facts 2–4.

## Measured facts this spec rests on — taken 2026-10-06 on this machine

- **Three things decide "which project" today, and nothing makes them agree.**
  - **Lake and extract roots:** `Get-ProjectId` (`tools\dsk-paths.ps1`) uses the git root of the
    current folder, or **the current folder itself** when it is not in a git repo.
  - **Contracts folder:** `materialize.ps1:119-120` and `run-assertions.ps1:139-140` use
    `<parent of the script's folder>\contracts`.
  - **State file:** `ensure-duckdb-compat.ps1:11-22` has its own `Get-RepoRoot`, with the same
    current-folder fallback.
- **The resolvers create folders on every call.**
  - **Default roots:** `Resolve-ExtractRoot` and `Resolve-LakeRoot` run `New-Item -Force` on the
    default root.
  - **Explicit roots:** `Resolve-LakeRoot` also creates an explicit `-LakeRoot`.
  - **Effect:** read-only tools create folders as a side effect of being asked what exists.
  - **Evidence:** the current-folder fallback already produced three stray project folders,
    `~\.duckdb-skills\c-users-woodsonp-claude-dev-_verify-2a`, `…-_verify-2b` and
    `…-_verify-2b-r2`.
- **Callers of the resolvers.**
  - **Read-only:** `lake-status.ps1:61`, `list-extracts.ps1:72`, `extract-status.ps1:116`,
    `extract-decide.ps1:194`, `cross-query.ps1:483,549,674`.
  - **Writing:** `materialize.ps1:135`, `publish-extract.ps1:85`.
- **"Nothing yet" outputs already exist.**
  - **`lake-status`:** prints `no lake`, exit 0, when the catalog file is missing
    (`lake-status.ps1:68-70`).
  - **`list-extracts`:** prints `no extracts registered under <root>`, exit 0, when the root is
    missing or empty (`list-extracts.ps1:83-92`).
  - **`cross-query`:** refuses with `ERROR,lake,no lake at <root> -- run tools\materialize.ps1
    first` (`cross-query.ps1:557`).
- **Promised output lines that must not move.**
  - **`ensure-duckdb-compat`:** its first line is the state-file path (`:36-37`).
  - **`extract-status -Name`:** its first line is the age in minutes and nothing else (`:4-6`).
  - **`list-extracts`:** prints `project-id:` and `extract root:` header lines when the default
    root is used (`:78-81`). An archived acceptance check (item 2a AC1) asserts them.
  - **`materialize`:** prints `LAKE_ROOT,<path>` and CSV-shaped result lines. It runs
    `run-assertions.ps1 -Contract <file>` as a child process and parses its output.
- **Neither `C:\Users\woodsonp` nor `%TEMP%` is inside a git repo** (checked with
  `git rev-parse --show-toplevel`). A scratch folder under either one is a genuine non-repo
  folder.
- **A `git worktree` is its own git root.** A tool run in a worktree resolves to a project named
  after the worktree path, not after this repo. `prove-no-snowflake.ps1:36-40` already records
  this trap.

## Decisions

1. **The project root is the git root of the current folder. There is no fallback.**
   `Get-ProjectId`'s current-folder branch is deleted. A new function in `dsk-paths.ps1`
   returns the project root, or throws a refusal. Every tool and `Get-ProjectId` use it, so
   there is one definition.
2. **The refusal message:**
   `ERROR: not inside a git repository: <current folder>. Run from your project folder, or pass
   <the explicit option(s) this tool accepts>.`
   The tool exits **2**, prints nothing else to stdout, and creates nothing.
3. **Explicit options bypass the project, but only for what they name.**
   - **`-LakeRoot` / `-ExtractRoot`:** they let lake and extract tools run outside a repo.
   - **`-StateFile`:** it lets `ensure-duckdb-compat` run outside a repo.
   - **Contracts:** `materialize` and `run-assertions` also need contracts. Outside a repo they
     need `-Contract <path>` as well. Without it they refuse, even with `-LakeRoot`.
4. **The contracts folder is `<project root>\contracts`** in `materialize` and `run-assertions`
   (default discovery, no `-Contract`). It is no longer `<script's parent>\contracts`. The compat
   file, `run-assertions.ps1` and `check-contract.ps1` are still found by `$PSScriptRoot`. They
   are part of the tool, not of the project.
5. **The resolvers create nothing unless the caller asks.** `Resolve-LakeRoot` and
   `Resolve-ExtractRoot` gain a `-Create` switch, applied to explicit and default roots alike.
   - **Who passes `-Create`:** only `materialize` and `publish-extract`.
   - **Who never does:** `lake-status`, `list-extracts`, `extract-status`, `extract-decide` and
     `cross-query`.
   - **What read-only tools print instead:** their existing "nothing yet" answer, unchanged.
   - **`cross-query -Save` with no lake:** it refuses with the existing `no lake at` message.
     It never creates a lake.
6. **Every tool writes `project: <project-id> (<project root>)` to stderr**, once, near the
   start. It goes to stderr, not stdout, so no promised stdout line moves and no parser that
   reads stdout changes.
   - **When the project is bypassed:** if a tool runs entirely on explicit options outside a
     repo, it writes `project: none (explicit roots)`.
   - **`materialize`:** it also writes `contracts: <folder>` to stderr when it discovers
     contracts.
   - **What you must check:** no caller merges a child tool's stderr into the stdout it parses.
     Search for `2>&1` around invocations of these tools; `materialize` → `run-assertions` is
     the known one. Where a caller does merge, the child must stay silent on stderr in that
     mode. `run-assertions -Contract` is the case to check.
7. **`ensure-duckdb-compat` uses the shared resolver.**
   - **Its own `Get-RepoRoot` is deleted.**
   - **Outside a repo without `-StateFile`:** it refuses per decision 2 and creates no
     `.duckdb-skills\`.
   - **Inside a repo:** behaviour is unchanged, including line 1.
8. **Development scaffolding stays as it is.** `prove-requery.ps1`, `prove-no-snowflake.ps1`,
   the `make-*-fixtures.ps1` scripts and `run-compat-tests.ps1` keep their current
   path logic. If one now hits the refusal (run from a non-repo folder without explicit
   roots), fix the **call** inside it by passing explicit roots. Do not weaken the rule.

## Deliverables

- `tools\dsk-paths.ps1`:
  - the project-root function;
  - `Get-ProjectId` uses it;
  - `-Create` on both resolvers;
  - its header comment updated to describe the new rules.
- The nine tools named above, changed per decisions 1–7: `lake-status`, `list-extracts`,
  `extract-status`, `extract-decide`, `cross-query`, `materialize`, `run-assertions`,
  `publish-extract`, `ensure-duckdb-compat`.
- **Skills:**
  - `skills\lakehouse\SKILL.md` and `skills\snowflake-extract\SKILL.md` each gain one short
    paragraph:
    - the tools must run inside the project's git repo, or with explicit roots;
    - read-only tools never create folders;
    - the `project:` line on stderr names what was resolved.
  - **Step 1 of `snowflake-extract` keeps telling the model to create `<root>\<name>.new\`.**
    It must now also create `<root>` itself if it is missing, because `list-extracts` no longer
    does.
- `RESULT-1.md` at repo root.

## Out of scope — do not do these

- Skill paths to scripts (`tools\…` relative to the repo). That is item 2.
- `state.sql` line replacement and `.gitignore` of `.duckdb-skills\` in other projects. That is
  item 2.
- Deleting the `_verify-*` folders under `~\.duckdb-skills\`.
- Any change to freshness, checks, the extract registry or `cross-query`'s join logic.
- Running anything against the real lake (`~\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\`)
  except the read-only commands in AC5.

## Conventions

- PowerShell 5.1. Absolute paths. Match the surrounding code's style and its existing exit-code
  idiom: 2 for usage/refusal, 1 for errors.
- **The verifier runs in a throwaway `git worktree`.** Every check below is written for that.
  The worktree is a git repo, so it resolves to its own project id. That is expected. Never
  "fix" it.
- **Scratch folders:** `$S` means a fresh folder under `%TEMP%`, which is not inside a git repo.
  `$G` means a fresh folder under `%TEMP%` on which `git init` has been run. Create new ones per
  check.
- **Home-folder snapshot:** `snap` means
  `Get-ChildItem -Recurse -Directory ~\.duckdb-skills | ForEach-Object FullName | Sort-Object`.
  Wherever a check says "unchanged", compare `snap` before and after.

## Acceptance checks

**AC1 — Outside a repo, every tool refuses and creates nothing.**
- **Setup:** from `$S`, take `snap`.
- **Run each of the following** (the tool path is the worktree's `tools\`):
  - `lake-status`, `list-extracts` and `extract-status`;
  - `extract-decide -Name x`;
  - `cross-query -Sql "SELECT 1 FROM lake.x"` (or whatever the tool's minimal lake-referencing
    form is);
  - `materialize`, `run-assertions` and `ensure-duckdb-compat`;
  - `publish-extract` with any staging dir and sidecar.
- **Expect:** each exits **2** with stdout starting
  `ERROR: not inside a git repository: <$S>`.
- **Afterwards:** `snap` is unchanged, and `$S` is still empty.

**AC2 — Outside a repo, explicit roots work and still create nothing for read-only tools.**
- **Read-only, from `$S`:** `lake-status -LakeRoot $S\nolake` prints `no lake`, exit 0, and
  `$S\nolake` does **not** exist afterwards.
  `list-extracts -ExtractRoot $S\noext` prints `no extracts registered under $S\noext`, exit 0,
  and `$S\noext` does not exist afterwards.
- **Contracts need `-Contract` too:** from `$S`, `materialize -LakeRoot $S\lake` exits 2 with
  the refusal.
- **With `-Contract` it runs:**
  `materialize -LakeRoot $S\lake -Contract <worktree>\contracts\Clayco_Job_Costs_from_GL.sql`
  runs, reports `MATERIALIZED` (or the tool's existing first-run outcome word) for
  `Clayco_Job_Costs_from_GL`, and creates `$S\lake`.
- **Stderr:** it includes `project: none (explicit roots)`.

**AC3 — In a brand-new repo, read-only tools answer "nothing yet" and create nothing.**
- **Setup:** from `$G`, take `snap`.
- **`lake-status`:** prints `no lake`, exit 0.
- **`list-extracts`:** prints `project-id: <G's id>`, then
  `extract root: <home>\.duckdb-skills\<G's id>\extracts`, then `no extracts registered under …`,
  exit 0.
- **`extract-status` and `extract-decide -Name x`:** each exits 0 or with its existing
  "not registered" code. Record each tool's stdout in `RESULT-1.md`, alongside the same
  command's stdout at the base commit run against an existing empty `-ExtractRoot`. The two
  must match.
- **`cross-query -Save t -Sql "SELECT 1 AS a"`:** refuses with `no lake at`.
- **Afterwards:** `snap` is unchanged, so no `<G's id>` folder exists.

**AC4 — Contracts come from the project, not from the script's folder.** This is the check that
fails under the old rule.
- **Setup:** in `$G`, create `contracts\` holding a copy of **only**
  `Clayco_Job_Costs_from_GL.sql`.
- **Run:** from `$G`, run the **worktree's** `tools\materialize.ps1` with no options, so the
  default lake root is used.
- **Expect, on stderr:** `project: <G's id> (<$G>)` and `contracts: <$G>\contracts`.
- **Expect, on stdout:** exactly one contract processed (`SUMMARY,contracts=1,…`), named
  `Clayco_Job_Costs_from_GL`, with a first-run outcome.
- **Expect, on disk:** `~\.duckdb-skills\<G's id>\lake\lake.ducklake` exists, because
  `materialize` may create.
- **Then run** `lake-status` from `$G`: it lists that one contract.
- **Under the old rule** this run would have processed the worktree's **two** contracts.
- **Cleanup:** delete `~\.duckdb-skills\<G's id>\` and nothing else.

**AC5 — Promised stdout is unchanged; the project goes to stderr.**
- **Commands:** run each of these from the worktree at the **base commit** and again at the
  **new commit**, both pointed read-only at the real roots:
  - `list-extracts -ExtractRoot <real extracts root>`;
  - `extract-status -Name parent_projects -ExtractRoot <real extracts root>`;
  - `lake-status -LakeRoot <real lake root>`.
- **The real roots:**
  - extracts: `~\.duckdb-skills\c-users-woodsonp-claude-dev-duckdb-skills\extracts`;
  - lake: `…\lake`.
  - All three commands are read-only (`lake-status` attaches `READ_ONLY`).
- **Expect:** stdout is byte-identical between the two runs, except for the age-in-minutes
  values, which move with the clock. Mask them and say how in `RESULT-1.md`.
- **New-commit stderr:** each run's stderr has exactly one `project:` line.
- **Afterwards:** `snap` is unchanged.
- **The `materialize` → `run-assertions` path:** show that `materialize`'s parsing still works.
  AC4 already ran it. Quote its `SUMMARY` line.

**AC6 — `publish-extract` still creates the extract root in a new repo.**
- **Setup:** from `$G`, build a minimal staging dir: one Parquet file written by DuckDB, plus a
  sidecar JSON valid per `skills\snowflake-extract\SIDECAR.md`.
- **Run:** `publish-extract` with the default root.
- **Expect:**
  - it succeeds, and `list-extracts` from `$G` lists the extract;
  - `~\.duckdb-skills\<G's id>\extracts\<name>\` exists.
- **Cleanup:** delete `~\.duckdb-skills\<G's id>\`.

**AC7 — `ensure-duckdb-compat` inside a repo is unchanged.**
- **Run:** from `$G`, `ensure-duckdb-compat`.
- **Expect:** line 1 is `<$G>\.duckdb-skills\state.sql`, and the file contains exactly one
  `.read …duckdb-compat.sql` line.
- **Stderr:** has the `project:` line.

## Mutation proofs — each must fail, then pass again after revert

- **M1:** point the contracts folder back at `<script's parent>\contracts`. **AC4 must fail**,
  because two contracts get processed.
- **M2:** make `Resolve-ExtractRoot` always create the root (ignore `-Create`). **AC3 must fail**,
  because `snap` changes.

Do mutations in the verifier's worktree only, and revert by re-checking-out the committed file
there.

## Final check — Phil runs this himself after merge

```powershell
cd C:\Users\woodsonp\Claude\Dev\duckdb-skills; .\tools\materialize.ps1
```

**Expect:**
- **Stderr:** `project: c-users-woodsonp-claude-dev-duckdb-skills (C:\Users\woodsonp\Claude\Dev\duckdb-skills)`
  and `contracts: C:\Users\woodsonp\Claude\Dev\duckdb-skills\contracts`.
- **Stdout:** both contracts `SKIPPED` (or `REFRESHED` naming the workbook if it changed since
  the last run, which is still correct).
