Plan: PLAN-5.md
Serves: **The skills appear in every Claude Code session as `/duckdb-skills:<skill>`,
installed from Phil's GitHub fork.** This is item 4, the last item of PLAN-5. Items 1, 2, 3a and
3b have shipped, so the plugin is built to run from Claude Code's plugin folder. This item makes
the repo's documentation and marketplace file correct for that install. Phil then runs the
install and the proof.

# Item 4 — Installed in Claude Code

PLAN-5 §"Item 4".

## Measured facts this spec rests on — taken 2026-10-06 on `main` at `c17a9c8`

- **A Claude Code CLI is available** at `C:\Users\woodsonp\.local\bin\claude.exe` (version
  2.1.224). It is not on Git Bash's `PATH`.
  - **What it offers:** non-interactive `claude plugin marketplace add <source>`,
    `claude plugin install <plugin>@<marketplace>`, `claude plugin list`,
    `claude plugin marketplace update` and `claude plugin validate <path>`.
  - **Why it matters:** Phil can install from PowerShell. The Code tab cannot open `/plugin`'s
    interactive dialog.
- **`claude plugin validate .` on this repo today:** `Validation passed with warnings`, with one
  warning: `description: No marketplace description provided`.
  - **`--strict` mode:** `validate --strict` exits **1** on that warning.
  - **The field:** the marketplace expects a top-level `"description"`. Phil's `xlsx-family`
    marketplace uses exactly that.
- **The fork has GitHub Issues disabled.** The anonymous API reports `"has_issues": false` for
  `woodsonpatclayco/duckdb-skills`, the default for forks. An "issues page" link would be dead.
- **The repo is public and reachable.** `woodsonpatclayco/duckdb-skills` is the right
  `marketplace add` source form; `xlsx-family` is registered as
  `GitHub (woodsonpatclayco/xlsx-refresh)`.
- **What an install copies:** `marketplace add` clones **GitHub**, not the local tree. With
  `"source": "./"`, the cache copy is every tracked file, `tools\` included. `_data/` and
  `.duckdb-skills/` are gitignored and absent, and nothing needs them.
- **`${CLAUDE_PLUGIN_ROOT}` arrives with forward slashes.** Claude Code 2.1.224's plugin skill
  loader turns backslashes into forward slashes when it substitutes the variable. A session
  will show `C:/Users/woodsonp/.claude/plugins/cache/…`.
- **README line 78** (the `read-memories` entry, written in item 3a) ends "It cannot see Cortex
  Code sessions." It stays.
- **README lines 191–195 (Platform support)** say Windows is not fully supported. That is
  upstream's statement, and it stays.
- **README.md is still written for upstream and Cortex Code in these places:**
  - **Lines 5–10, the fork note:** it says "adapted for Cortex Code" and that `read-memories`
    searches Cortex logs. Both are false since item 3a.
  - **Lines 21–29 and 33–38, install and update:** they use `duckdb/duckdb-skills` and
    `duckdb-skills@duckdb-skills`. The fork's marketplace is `woodsonp-duckdb-skills` (item 2).
  - **Line 164, local development:** it clones `github.com/duckdb/duckdb-skills.git`.
  - **Line 201, reporting issues:** it points at upstream's issue tracker.
  - **The "Skills" list (lines 40–95)** has no entry for the fork's `lakehouse` or
    `snowflake-extract`.
- **Plugin identity, from item 2:**
  - the plugin is `duckdb-skills`, in marketplace `woodsonp-duckdb-skills`;
  - the repository is `https://github.com/woodsonpatclayco/duckdb-skills`;
  - the version is `0.2.4`;
  - `"source": "./"`.
- **An installed plugin lives in a versioned cache folder,**
  `~\.claude\plugins\cache\woodsonp-duckdb-skills\duckdb-skills\<version>\`. Skills reach their
  scripts through `${CLAUDE_PLUGIN_ROOT}` (item 2).
  - **What item 2 established:** no tool prints its own folder. The evidence of where a script
    ran is **the substituted command line** the session shows.

## Decisions

1. **The marketplace gets a description,** so `claude plugin validate` passes with **no**
   warnings. Use whichever field the validator expects; the implementer finds it by running the
   validator. Reuse `plugin.json`'s description text.
2. **README fork note (lines 5–10) is rewritten** as a short note, under 10 lines, saying:
   - **What it is:** a Claude-Code-first fork of `duckdb/duckdb-skills` (keep the upstream
     link), used on Windows.
   - **What it adds:** the `lakehouse` skill (contracts materialized into DuckLake) and the
     `snowflake-extract` skill (Snowflake extracts through the Python connector, `tools\sf.py`).
   - **What it changes:** a Windows-adapted `read-memories`, `xl_date()` in the compat file,
     and project resolution by git root (tools refuse outside a git repo).
   - **Cortex Code** is not a target of this fork.
   - **Departs from PLAN-5 item 4,** which said the note "describes both hosts". PLAN-5's own
     Claude-Code-first decision (commit 13d056a) superseded that. The note names Cortex Code
     only to say it is not a target.
3. **Install, update and local-dev sections point at the fork.**
   - **Install:** `/plugin marketplace add woodsonpatclayco/duckdb-skills` and
     `/plugin install duckdb-skills@woodsonp-duckdb-skills`, each with its CLI equivalent
     (`claude plugin marketplace add …`, `claude plugin install …`).
   - **The "From the Discover tab" subsection is deleted.** It describes upstream's listing,
     not this fork.
   - **Update:** `/plugin marketplace update woodsonp-duckdb-skills` and
     `/plugin update duckdb-skills@woodsonp-duckdb-skills`, with CLI equivalents
     `claude plugin marketplace update woodsonp-duckdb-skills` and
     `claude plugin update duckdb-skills@woodsonp-duckdb-skills`.
   - **Add one sentence:** **a change reaches an installed copy only when `version` in
     `.claude-plugin\plugin.json` and `marketplace.json` is bumped.**
   - **Local development:** clone the fork, then `claude --plugin-dir .`.
   - **Issues:** the fork has GitHub Issues disabled. Replace the upstream issues link with:
     "Report problems to the fork's owner; upstream DuckDB bugs go to
     https://github.com/duckdb/duckdb-skills/issues."
4. **Two skill entries are added to "Skills",** in the existing style: a heading, 1–3
   sentences, and one example invocation each.
   - **`lakehouse`:** materialize Excel contracts into a DuckLake lake, then check status and
     history.
   - **`snowflake-extract`:** pull a named Snowflake query to local Parquet, with a freshness
     registry.

   No other entry changes. The upstream skills missing from the list (`convert-file`,
   `s3-explore`, `spatial`) stay missing; that was upstream's choice.
5. **`version` stays `0.2.4`.** The bump to `0.3.0` happens after PLAN-5 archives (PLAN-5
   §"Item 4").

## Deliverables

- `.claude-plugin\marketplace.json`, per decision 1.
- `README.md`, per decisions 2–4.
- `RESULT-1.md` at repo root.

## Out of scope — do not do these

- **Installing anything,** or writing anywhere under `~\.claude\`. That includes running
  `claude plugin marketplace add`/`install` and `--plugin-dir` sessions. Phil runs the install
  himself, after merge.
- **Any `skills\`, `tools\`, `contracts\` or `checks\` file.**
- **`.cortex-plugin\`:** it stays as it is, unused by Claude Code.
- **`version`.**
- **README sections other than those named in decisions 2–4.** In particular:
  - line 78's "It cannot see Cortex Code sessions";
  - Platform support (lines 191–195).

## Conventions

- **The verifier works in a throwaway worktree, `$W`, at the implementer's commit.**
- **The CLI path** is `C:\Users\woodsonp\.local\bin\claude.exe`. `claude plugin validate` only
  reads the given folder.

## Acceptance checks

**AC1 — The marketplace validates cleanly.**
- **Run:** `claude.exe plugin validate --strict $W`.
- **Expect:** exit 0 and `Validation passed`. Quote the output.
- **Control:** at base, the same command exits 1 on the `description` warning.

**AC2 — The README no longer sends anyone to upstream or Cortex Code.**
- **Run:** `git -C $W grep -n -e "duckdb/duckdb-skills" -e "duckdb-skills@duckdb-skills" -e "Cortex Code" -- README.md`.
- **Expect** every hit to be one of:
  - a line of the fork note (at most 3 lines) naming upstream or saying Cortex Code is not a
    target;
  - line 78's existing sentence, "It cannot see Cortex Code sessions.", unchanged;
  - the one upstream issues URL from decision 3.

  Quote every hit with its line number.
- **No stale update line:** `git -C $W grep -n -e "marketplace update duckdb-skills$" -- README.md`
  returns nothing.
- **Present:** each of these strings has at least 1 hit in
  `git -C $W grep -n -F -e "woodsonpatclayco/duckdb-skills" -e "duckdb-skills@woodsonp-duckdb-skills" -e "plugin marketplace update woodsonp-duckdb-skills" -e "plugin update duckdb-skills@woodsonp-duckdb-skills" -- README.md`.
  Quote the version-bump sentence.

**AC3 — The new skill entries name real skills.**
- `git -C $W grep -n -e "/duckdb-skills:lakehouse" -e "/duckdb-skills:snowflake-extract" -- README.md`
  has at least 1 hit for each.
- `git -C $W grep -n "^name:" -- skills/lakehouse/SKILL.md skills/snowflake-extract/SKILL.md`
  gives `name: lakehouse` and `name: snowflake-extract`.

## Final check — Phil, after merge

**Precondition (the main session, not Phil):** the merge is pushed, so
`git ls-remote origin refs/heads/main` equals `git rev-parse main`.

Run these in PowerShell (not in the Code tab):

```powershell
& "$env:USERPROFILE\.local\bin\claude.exe" plugin marketplace add woodsonpatclayco/duckdb-skills
```

```powershell
& "$env:USERPROFILE\.local\bin\claude.exe" plugin install duckdb-skills@woodsonp-duckdb-skills
```

```powershell
& "$env:USERPROFILE\.local\bin\claude.exe" plugin list
```

**Expect:** `plugin list` shows `duckdb-skills@woodsonp-duckdb-skills` at version `0.2.4`.

**Then two fresh Claude Code sessions:**
- **In this repo:** ask `/duckdb-skills:lakehouse what's the lake status?`. The session runs
  `lake-status.ps1`.
  - **The command line it shows** contains
    `.claude/plugins/cache/woodsonp-duckdb-skills/duckdb-skills/0.2.4/tools/lake-status.ps1`.
    Claude Code writes it with forward slashes; backslashes would be equally fine. That
    observes the `${CLAUDE_PLUGIN_ROOT}` substitution and the versioned cache folder.
  - **What a failure looks like:** a path under `Claude\Dev\duckdb-skills\tools`, or a literal
    `${CLAUDE_PLUGIN_ROOT}`, means substitution failed, **even if the output looks right**. In
    this repo the model could fall back to the repo's own copy of the script.
  - **The output** lists `All_Sales_Data` and `Clayco_Job_Costs_from_GL`. It also contains
    `project: c-users-woodsonp-claude-dev-duckdb-skills (C:\Users\woodsonp\Claude\Dev\duckdb-skills)`.
  - **`Clayco_Job_Costs_from_GL` may show `outcome=REFUSED`** until the real lake is
    rematerialized (see items 1 and 3a). That is not an install failure.
- **In a folder that is not a git repo** (for example `Documents`): ask the same thing. It
  answers `ERROR: not inside a git repository: …` (item 1).

If both hold, PLAN-5 archives and `version` is bumped to `0.3.0`. Phil then moves to it with:

```powershell
& "$env:USERPROFILE\.local\bin\claude.exe" plugin marketplace update woodsonp-duckdb-skills
```

```powershell
& "$env:USERPROFILE\.local\bin\claude.exe" plugin update duckdb-skills@woodsonp-duckdb-skills
```
