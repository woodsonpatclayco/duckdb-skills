# PLAN-5 — Deploy duckdb-skills to Claude Code

> A **new plan**, not a fifth version of the archived local-SQL plan
> (`docs\plans\2026-09-30-local-sql-surface\PLAN-1..4.md`). Numbered on from it at Phil's
> request (2026-10-06).

**Serves:** Phil can use the lakehouse, Snowflake-extract and query skills from any Claude Code
session in any project, not only from inside this repo. Development of the plugin moves from
Cortex Code to Claude Code at the same time.

Three items, three specs, in order. Each item depends on the one before it.

## Why this exists

Every item 1–8 tool has only ever worked because Phil ran it from inside this repo. Nothing from
the local-SQL plan is deployed anywhere:

- **Claude Code** does not have the plugin installed (`~\.claude\plugins\installed_plugins.json`
  lists only `context-graph`).
- **Cortex Code** has `~\.snowflake\cortex\plugins\duckdb-skills`, but that install is a clone of
  the **original public project** (`github:duckdb/duckdb-skills#main`, upstream commit `7feda8e`,
  2026-09-21). It has no `lakehouse`, no `snowflake-extract`, no `tools\`, and it has upstream's
  `read-memories`, not the fork's.

## Measured facts — checked in this repo, 2026-10-06

1. **Scripts already find each other by `$PSScriptRoot`.** `materialize.ps1:117-122`,
   `run-assertions.ps1:139-142` and `cross-query.ps1:62-65` load `dsk-paths.ps1`, the compat
   file and the registry relative to their own folder. Those links survive being installed
   somewhere else.
2. **Three different things decide "which project", and they can disagree.**
   - **Lake and extract folders** come from `Get-ProjectId` (`dsk-paths.ps1`): the git root of the
     **current folder**, or the current folder itself if it is not in a git repo.
   - **The contracts folder** is `<parent of the script's folder>\contracts`
     (`materialize.ps1:119-120`, `run-assertions.ps1:139-140`). That is **this repo** today. In a
     plugin install it would be the **plugin's own copy**.
   - **The workbook** is whatever path is written into the contract's `read_xlsx('...')`
     (`materialize.ps1:260`).

   So a run from another folder can read this repo's contracts, open this repo's workbook, and
   write to a lake keyed on a different project.
3. **The no-repo fallback has already created stray project folders.** `~\.duckdb-skills\`
   holds `…-_verify-2a`, `…-_verify-2b` and `…-_verify-2b-r2` beside the real
   `c-users-woodsonp-claude-dev-duckdb-skills`. Earlier verifier runs from non-repo scratch
   folders created all three.
4. **Read-only tools create folders.** `Resolve-ExtractRoot` and `Resolve-LakeRoot` both run
   `New-Item -Force` when the default root is missing. `lake-status`, `list-extracts`,
   `extract-status`, `extract-decide` and `cross-query` call them.
5. **Skills tell the model to run `tools\<script>.ps1` by a path relative to the repo.** That
   covers `skills\lakehouse\SKILL.md`, `skills\snowflake-extract\SKILL.md`,
   `skills\read-file\SKILL.md:21,23` and `skills\query\SKILL.md:161`. Under a plugin install the
   session's folder is the user's project, so the path is not found.
6. **`ensure-duckdb-compat.ps1:51-53` writes the compat file's absolute path into the project's
   `state.sql`, and adds new lines rather than replacing old ones.**
7. **`.claude-plugin\marketplace.json` and `plugin.json` still name upstream.** The owner is
   `duckdb` and the repository is `github.com/duckdb/duckdb-skills`, at version `0.2.4`.
   `"source": "./"` means an install copies the whole repo, including `contracts\` and `docs\`.

**From the Claude Code documentation (not yet observed on this machine):**

- `${CLAUDE_PLUGIN_ROOT}` is substituted into `SKILL.md` text, as well as hooks and commands.
  ([components](https://code.claude.com/docs/en/plugins/components.md#path-variables-and-persistent-data))
- The install lives in a **versioned** folder, `cache\<marketplace>\<plugin>\<version>\`, so
  `${CLAUDE_PLUGIN_ROOT}` changes on every update.
  ([loading](https://code.claude.com/docs/en/plugins/loading.md#find-plugins-on-disk))
- **New commits do not reach an install unless `version` changes.**
  ([releases](https://code.claude.com/docs/en/plugins/host-marketplace.md#release-a-new-version))

Item 3's proof is where these three get observed.

## Item 1 — One project, chosen deliberately

**Serves:** A tool run from the wrong folder stops and says so, instead of quietly building or
reading a second lakehouse.

- **One resolver decides the project:** the git root of the current folder. Lake root, extract
  root **and contracts folder** all come from it. The contracts folder becomes
  `<project root>\contracts` in `materialize` and `run-assertions`, no longer the parent of the
  script's folder. Today both give the same answer, so nothing changes for this repo.
  `prove-requery.ps1` stays repo-relative, because it is development scaffolding.
- **No repo means stop.** Outside a git repo, every resolver-using tool exits non-zero with a
  message naming the folder, and creates nothing. This includes `ensure-duckdb-compat`.
  - **Explicit roots:** `-LakeRoot` / `-ExtractRoot` still work outside a repo for lake and
    extract tools.
  - **Contracts:** `materialize` and `run-assertions` additionally need a project for their
    contracts, so outside a repo they need `-Contract <path>`.
- **Inside a repo, read-only tools create nothing and otherwise behave as now.**
  - **Which tools:** `lake-status`, `list-extracts`, `extract-status`, `extract-decide` and
    `cross-query`.
  - **A new project:** they keep today's "nothing yet" answers with exit 0 (`no lake`,
    `no extracts registered`). A new project is normal, not an error.
  - **Who may create the folder:** only `materialize`, `publish-extract` and the
    snowflake-extract skill's staging step may create the project folder under
    `~\.duckdb-skills\`.
- **Tools say which project they resolved to, without breaking promised output.**
  - **Where a tool has no promised line format:** it prints `project:`, `contracts:` and
    `lake root:` / `extract root:` lines.
  - **Exempt, so their output stays as promised:** `ensure-duckdb-compat` (line 1 is the state
    file), `extract-status` (line 1 has a fixed meaning) and `cross-query` (its output is result
    data). They write the project line to stderr instead.
  - `list-extracts` keeps its existing `project-id:` line exactly as it is.

**Proof:** this runs in the verifier's throwaway worktree, never against the real lake.
- **From the worktree:** `materialize -LakeRoot <scratch>` prints a project and contracts folder
  that both name the worktree. Its contracts run against the scratch lake.
- **From a non-repo scratch folder:** `lake-status` exits non-zero with the message. A listing
  of `~\.duckdb-skills\` is identical before and after.
- **From a fresh `git init` folder:** `list-extracts` prints `no extracts registered` with
  exit 0, and creates no folder.

**Final check, run by Phil by hand after merge:** `materialize` from this repo reports `SKIPPED`
for both shipped contracts.

**Consequence for verifiers:** future verifier scratch folders must `git init` or pass explicit
roots. The spec says so.

## Item 2 — The plugin runs from wherever it is installed

**Serves:** The skills work when the plugin lives in Claude Code's plugin folder and the session
is in some other project.

- **Script paths:** every skill that names a `tools\` script calls it as
  `${CLAUDE_PLUGIN_ROOT}\tools\<script>.ps1` (the five `SKILL.md` locations in fact 5).
- **Compat line in `state.sql`:** `ensure-duckdb-compat` **replaces** any existing
  `duckdb-compat.sql` line in `state.sql` instead of adding a second one. Otherwise every plugin
  update leaves a dead `.read` line pointing at the previous version's folder.
- **`.duckdb-skills\` in other projects:** `ensure-duckdb-compat` creates `.duckdb-skills\`
  inside whichever project it runs in. It adds that folder to the project's `.gitignore` if it
  is not already ignored.
- **Plugin identity:** `.claude-plugin\` names the fork (`woodsonpatclayco/duckdb-skills`), not
  upstream.

**Proof:** copy the plugin to a scratch folder outside the repo and **delete the copy's
`contracts\`**. With the worktree as the current folder, run the copy's
`materialize.ps1 -LakeRoot <scratch>`.
- **What it must show:** the copy's script folder, the worktree as the contracts folder, and
  both contracts processed.
- **Why it can't pass falsely:** under the old rule the copy would find no contracts and error.
- **State file:** running `ensure-duckdb-compat` twice from two different copies leaves exactly
  one `duckdb-compat.sql` line in `state.sql`.

## Item 3 — Installed in Claude Code

**Serves:** The skills appear in every Claude Code session as `/duckdb-skills:<skill>`.

- Push the fork and install it as a marketplace from GitHub, the way `context-graph` is
  installed (that one points `source` at a subfolder; this one uses `"./"`, which also works).
- The README's opening note stops saying "Cortex Code fork" and describes both hosts.
- **How fixes reach the install:** only a `version` change does. Every release is a version bump
  in `plugin.json` and `marketplace.json`, cut after its plan archives, and then
  `/plugin update`. A fix pushed without a bump does not reach Claude Code.

**Proof, run by Phil:**
- **In a fresh Claude Code session in this repo:** the `lakehouse` skill runs `lake-status`. The
  output shows the script ran from `~\.claude\plugins\cache\...\<version>\`, names this project,
  and lists both contracts. That observes the three documentation facts above.
- **In a non-repo folder:** a session gets item 1's refusal.

**Version bump** (`0.2.4` → `0.3.0`) happens **after** this plan archives, not inside item 3. A
version must never be cut while plan or task files sit at root.

## Deliberately not changing

- **The Cortex Code install.** It stays on its upstream clone. Repointing Cortex at the fork is a
  one-line `registry.json` change Phil can ask for separately. This plan does not touch
  `~\.snowflake\`.
- **`read-memories`.**
  - **Under Claude Code:** it keeps searching **Cortex Code** logs. Those still exist on disk,
    so it works, but it cannot see Claude Code sessions.
  - **Why not now:** adding Claude Code's log format means a second parser across five SQL
    files. That is its own item, outside this plan's Serves line.
- **Where Phil's two contracts live.** They stay in this repo's `contracts\`, which keeps working
  because this repo is a git project. The plugin copy also carries them, harmlessly: nothing
  reads them from there after item 1. Moving them to an analysis repo is a later decision.
- **The `query` and `attach-db` skills' own state lookup** (`skills\query\SKILL.md:22-25`,
  `skills\attach-db\SKILL.md:84-89`, inherited from upstream).
  - **What they do:** they keep falling back to the current folder outside a git repo.
  - **The effect:** a plain DuckDB query from a non-repo folder still works, but without the
    compat macros, because `ensure-duckdb-compat` refuses there.
  - **Why accepted:** ad-hoc file reading should not require a repo.
- **Excel table discovery (`xlsx_tables()`, `list-sheets` table listing).** Phil kept it out of
  this plan (2026-10-06). It needs its own plan.
- **The stray `_verify-*` folders** under `~\.duckdb-skills\` are left in place. Item 1 stops new
  ones being created. Deleting the old ones is separate.
- **Freshness, checks, the extract registry, `cross-query`'s join logic.** No behaviour change
  beyond where paths come from.
