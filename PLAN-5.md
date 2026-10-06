# PLAN-5 — Deploy duckdb-skills to Claude Code

**Serves:** Phil can use the lakehouse, Snowflake-extract and query skills from any Claude Code
session in any project, not only from inside this repo. Development of the plugin moves from
Cortex Code to Claude Code at the same time.

Three items, three specs, in order. Each item depends on the one before it.

## Why this exists

Every item 1–8 tool has only ever worked because Phil ran it from inside this repo. Nothing from
PLAN-1..4 is deployed anywhere:

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
4. **Every read-only tool creates folders.** `Resolve-ExtractRoot` and `Resolve-LakeRoot` both
   run `New-Item -Force` when the default root is missing, and `lake-status`, `list-extracts`,
   `extract-status` and `cross-query` call them.
5. **The skills tell the model to run `tools\<script>.ps1` by a path relative to the repo**
   (`skills\lakehouse\SKILL.md`, `skills\snowflake-extract\SKILL.md`). Under a plugin install the
   session's folder is the user's project, so the path is not found.
6. **`read-memories` searches Cortex Code logs only** (`~\.snowflake\cortex\conversations\`).
7. **`.claude-plugin\marketplace.json` and `plugin.json` still name upstream.** The owner is
   `duckdb` and the repository is `github.com/duckdb/duckdb-skills`, at version `0.2.4`.

**Not yet measured:** how a Claude Code skill refers to a file in its own plugin's folder, for
example a `${CLAUDE_PLUGIN_ROOT}`-style variable substituted into `SKILL.md`. No installed plugin
on this machine uses one. Item 2's spec must measure this before it chooses a mechanism.

## Item 1 — One project, chosen deliberately

**Serves:** A tool run from the wrong folder stops and says so, instead of quietly building or
reading a second lakehouse.

- **One resolver decides the project:** the git root of the current folder. Lake root, extract
  root **and contracts folder** all come from it. The contracts folder becomes
  `<project root>\contracts`, no longer the parent of the script's folder. Today both give the
  same answer, so nothing changes for this repo.
- **No repo means stop.** Outside a git repo, every tool exits non-zero with a message naming the
  folder and offering `-LakeRoot` / `-ExtractRoot`. It creates nothing. Passing an explicit root
  still works, unchanged.
- **Read-only tools never create a project folder.** `lake-status`, `list-extracts`,
  `extract-status` and `cross-query` refuse if the project's folder under `~\.duckdb-skills\`
  does not exist yet. Only `materialize` and `publish-extract` may create it.
- **Every tool prints the project it resolved to** on its first output line, so a wrong one is
  obvious.
- `ensure-duckdb-compat.ps1` falls back to the current folder in the same way. It follows the
  same rule.

**Proof:** from a non-repo scratch folder, `lake-status` exits non-zero with the message, and
the listing of `~\.duckdb-skills\` is identical before and after. From this repo, `materialize`
reports `SKIPPED` for both shipped contracts, so nothing about the real lake moved.

**Consequence for verifiers:** future verifier scratch folders must `git init` or pass explicit
roots. The spec says so.

## Item 2 — The plugin runs from wherever it is installed

**Serves:** The skills work when the plugin lives in Claude Code's plugin folder and the session
is in some other project.

- Skills invoke scripts by the plugin's own location, not by a repo-relative `tools\` path. The
  mechanism comes from the measurement above. If Claude Code offers no substitution variable, the
  fallback is a skill instruction to resolve the path from the skill's own base directory, which
  Claude Code shows when it loads a skill.
- Contracts, checks and examples come from the user's project (item 1). The plugin ships none of
  them as inputs.
- `read-memories` searches Claude Code session logs (`~\.claude\projects\`) when running under
  Claude Code. Cortex Code search keeps working exactly as it does now.
- `.claude-plugin\` names the fork (`woodsonpatclayco/duckdb-skills`), not upstream.

**Proof:** copy the plugin to a folder outside this repo and run its `materialize.ps1` with this
repo as the current folder. Both contracts report `SKIPPED`. That shows the scripts came from the
copy and the contracts and lake came from the project. `read-memories` run under Claude Code
finds a phrase from this session.

## Item 3 — Installed in Claude Code

**Serves:** The skills appear in every Claude Code session as `/duckdb-skills:<skill>`.

- Install from the GitHub fork as a marketplace, the same way `context-graph` is installed. The
  fork must be pushed first.
- The README's opening note stops saying "Cortex Code fork" and describes both hosts.

**Proof:** in a fresh Claude Code session in this repo, the `lakehouse` skill runs
`lake-status`. The output shows the script ran from `~\.claude\plugins\cache\...`, names this
project, and lists both contracts. A session in a non-repo folder gets item 1's refusal.

**Version bump** (`0.2.4` → `0.3.0`) happens **after** this plan archives, not inside item 3. A
version must never be cut while plan or task files sit at root.

## Deliberately not changing

- **The Cortex Code install.** It stays on its upstream clone. Repointing Cortex at the fork is a
  one-line `registry.json` change Phil can ask for separately. This plan does not touch
  `~\.snowflake\`.
- **Where Phil's two contracts live.** They stay in this repo's `contracts\`, which keeps working
  because this repo is a git project. Moving them to an analysis repo is a later decision.
- **Excel table discovery (`xlsx_tables()`, `list-sheets` table listing).** Phil kept it out of
  this plan (2026-10-06). It needs its own plan.
- **The stray `_verify-*` folders** under `~\.duckdb-skills\` are left in place. Item 1 stops new
  ones being created. Deleting the old ones is separate.
- **Freshness, checks, the extract registry, `cross-query`'s join logic.** No behaviour change
  beyond where paths come from.
