Plan: PLAN-5.md
Serves: **The skills work when the plugin lives in Claude Code's plugin folder and the session is
in some other project.** This is item 2 of 4 in deploying duckdb-skills to Claude Code. Item 1
(shipped) made every tool pick the project from the current folder. This item makes the skills
find their scripts inside the plugin, wherever it is installed. After this come 3a (undo the
Cortex Code adaptations), 3b (Snowflake through the Python connector), then 4 (install).

# Item 2 — The plugin runs from wherever it is installed

PLAN-5 §"Item 2", plus facts 5, 6 and 8, and the Claude Code documentation facts.

## Measured facts this spec rests on — taken 2026-10-06 on `main` at `25f42ad`

- **Since item 1, the scripts themselves are location-independent.** Contracts, lake and
  extracts come from the current folder's git root. The compat file, `run-assertions.ps1` and
  `check-contract.ps1` come from `$PSScriptRoot`. What still assumes the repo layout is
  **the skill text**.
- **Skill text that names a script by a repo-relative path** (`tools\…`), excluding
  `read-memories`, which item 3a replaces:
  - **`skills\lakehouse\SKILL.md`:** lines 11, 12, 30, 33, 38, 42, 93, 115, 118 and 123.
  - **`skills\snowflake-extract\SKILL.md`:** lines 14, 28, 35, 36, 89, 99, 104, 109 and 143.
  - **`skills\read-file\SKILL.md`:** lines 21 and 23.
  - **`skills\query\SKILL.md`:** line 161.
  - **Other path mentions:** `skills\lakehouse\SKILL.md:44` names `skills\query\duckdb-compat.sql`.
  - **No invocation form:** none of these skills says *how* to run a `.ps1` (shell, flags).
    The model improvises it.
- **Claude Code substitutes `${CLAUDE_PLUGIN_ROOT}` in `SKILL.md` text** with the plugin's
  install folder.
  - **Source:** the documentation
    ([components](https://code.claude.com/docs/en/plugins/components.md#path-variables-and-persistent-data)).
    It is not observed on this machine yet; item 4 observes it.
  - **The install folder is versioned:** `~\.claude\plugins\cache\<marketplace>\<plugin>\<version>\`.
- **`ensure-duckdb-compat.ps1:76-94` only ever adds a line.**
  - **What it checks:** whether the *exact* current `.read <compat path>` line is present,
    and prepends it if not.
  - **What goes wrong:** when the path changes (every plugin update moves the folder), the
    old line stays. DuckDB's `-init` then fails on a `.read` of a file that no longer exists.
- **The `.read` line it writes is unquoted** (`ensure-duckdb-compat.ps1:56`), and DuckDB
  1.5.5 rejects an unquoted path containing spaces. Measured by the reviewer:
  - unquoted spaced path: `Usage: '.read FILE'`, and `-init` exits 1;
  - `.read '<path>'`: exit 0.

  Every other tool already single-quotes its paths (`materialize.ps1:509`,
  `run-assertions.ps1:502`, `check-contract.ps1:178`). Plugin paths may contain spaces, so this
  is a real defect for this item.
- **`ensure-duckdb-compat` creates `<project>\.duckdb-skills\state.sql`.** This repo's
  `.gitignore` already ignores `.duckdb-skills/`. Other projects' `.gitignore` files do not.
- **`.claude-plugin\plugin.json` and `marketplace.json` still describe upstream.**
  - **Owner:** `duckdb`, and the repository is `https://github.com/duckdb/duckdb-skills`.
  - **Version:** `0.2.4`.
  - **Description:** it lists no lakehouse or extract skills.
  - **Marketplace name:** `duckdb-skills`, the same as upstream's.
- **The `claude` CLI is not on the Git Bash `PATH`,** so `claude plugin validate` cannot be
  assumed to be available.

## Decisions

1. **One invocation form, stated once per skill.**
   - **Where:** each of the four skills gains a short section, "Running the tools", near the
     top.
   - **What it says:**
     > Run every script with
     > `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/tools/<script>.ps1" <args>`
     > from the project folder (the tools resolve the project from the current folder, item 1).
     > Quote the path; it may contain spaces.
   - **The other references:** every `tools\<script>.ps1` mention in the lines listed above
     becomes `${CLAUDE_PLUGIN_ROOT}/tools/<script>.ps1`. That includes prose mentions, so no
     bare `tools\` path is left to copy.
   - **`lakehouse:44`:** it becomes `${CLAUDE_PLUGIN_ROOT}/skills/query/duckdb-compat.sql`.
   - **Library, not tool:** the section also says, in one sentence, "`dsk-paths.ps1` is a
     library, not a tool. Read the extract root from `list-extracts`' `extract root:` line
     instead of dot-sourcing it." This covers `snowflake-extract:35`.
   - **Where the script ran is shown by the command line, not by the output.** No tool
     prints its own folder, so the evidence of where a script ran is the substituted command,
     which contains the plugin path. Item 4's proof must be worded the same way.
2. **Forward slashes after the variable.** PowerShell accepts them, they survive Git Bash, and
   they need no escaping in Markdown.
3. **`ensure-duckdb-compat` replaces instead of adding, and quotes the path.**
   - **The line it writes:** `.read '<forward-slash absolute path>'`, in single quotes, as
     `materialize.ps1:509` does.
   - **The removal rule:** before writing, it removes every line matching `^\s*\.read\s` whose
     argument ends in `/skills/query/duckdb-compat.sql` once normalized. Normalizing means
     trimming, stripping one pair of surrounding `'` or `"`, turning `\` into `/`, and
     lower-casing. This also removes the unquoted lines the current version wrote.
   - **Then:** it prepends the new line, and re-joins the remaining lines with CRLF in their
     original order.
   - **What it never touches:** any other `.read` line, `ATTACH`, `LOAD` or anything else in
     the file, and the order of the remaining lines.
   - **Unchanged:** the BOM handling and the "first output line is the state-file path"
     promise.
4. **`ensure-duckdb-compat` keeps `.duckdb-skills/` out of git.**
   - **When the default project state file is used** (no `-StateFile`), it checks the path:
     `git check-ignore -q <project root>\.duckdb-skills\state.sql`.
   - **If it is not ignored:** it appends a line `.duckdb-skills/` to `<project root>\.gitignore`,
     creating the file if absent.
     - **How it writes:** with `[IO.File]::AppendAllText`, using LF (`0x0A`) only and no BOM.
     - **Formatting:** if the file is non-empty and does not end in `0A`, it writes `0A` first.
     - **Contents:** nothing else in the file changes.
   - **If it is already ignored:** the `.gitignore` is left byte-identical.
   - **With `-StateFile`:** no `.gitignore` is touched.
   - **Output:** it reports the addition as one stdout line,
     `NOTE: added .duckdb-skills/ to <path>\.gitignore`. That line comes after line 1, so the
     first line's promise holds.
5. **The plugin names the fork, and the version does not change.**
   - **`plugin.json` and `marketplace.json`:**
     - `author`/`owner` name `woodsonpatclayco`, with url `https://github.com/woodsonpatclayco`;
     - `repository` and `homepage` are `https://github.com/woodsonpatclayco/duckdb-skills`.
   - **The description** names the lakehouse, Snowflake extracts, Excel contracts, querying,
     and reading files. It is the same text in both.
   - **The plugin `name` stays `duckdb-skills`,** so skills are still `/duckdb-skills:<skill>`.
   - **The marketplace's own top-level `name` becomes `woodsonp-duckdb-skills`,** so it cannot
     collide with upstream's `duckdb-skills` marketplace if that is ever added. The install
     name in item 4 becomes `duckdb-skills@woodsonp-duckdb-skills`.
     - **What the rename does not prevent:** installing upstream's plugin as well would still
       collide on the `/duckdb-skills:` skill names.
   - **`version` stays `0.2.4`.** The bump happens after PLAN-5 archives.

## Deliverables

- **The four skill files**, changed per decisions 1–2: `skills\lakehouse\SKILL.md`,
  `skills\snowflake-extract\SKILL.md`, `skills\read-file\SKILL.md` and `skills\query\SKILL.md`.
- **`tools\ensure-duckdb-compat.ps1`**, per decisions 3–4, with its header comment updated.
- **`.claude-plugin\plugin.json` and `.claude-plugin\marketplace.json`**, per decision 5.
- **`RESULT-1.md`** at repo root. This is round 1 of item 2's own task set.

## Out of scope — do not do these

- **`skills\read-memories\`:** item 3a replaces it.
- **The polyglot and Snowflake-macro content** of `skills\query\SKILL.md` (lines 158–191) and
  `duckdb-compat.md`: item 3a removes them. Line 161 still gets its path rewritten, because it
  must not be left as a bare `tools\`.
- **`allowed-tools`, Snowflake access, and the `snowflake_sql_execute` steps:** that is item 3b.
- **The `PROJECT_ROOT … || echo "$PWD"` state lookups** in `query` and `attach-db`: leave them
  unchanged.
- **The README:** items 3a and 4 handle it.
- **Any script under `tools\`** other than `ensure-duckdb-compat.ps1`.
- **The `version` field.**
- **Installing the plugin:** that is item 4.

## Conventions

- **The verifier works in a throwaway `git worktree` at the implementer's commit**, called `$W`.
- **Tools run as child processes**, exactly as in item 1 (see
  `docs\tasks\2026-10-06-item1-project-resolution\TASK.md` "Conventions"):

  ```powershell
  Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',<tool>,<args…> `
    -WorkingDirectory <dir> -RedirectStandardOutput <o.txt> -RedirectStandardError <e.txt> `
    -NoNewWindow -Wait -PassThru
  ```

  Never use `2>`/`2>&1` on a `powershell` call.
- **`$P`:** a copy of the plugin made the way a marketplace copies it, which is every tracked
  file.
  - **How to build it:** `git -C $W archive --format=zip -o $Z HEAD`, where `$Z` is a `.zip`
    path under `%TEMP%`. Then `Expand-Archive -LiteralPath $Z -DestinationPath $P`. That gives
    145 files at base, equal to `git ls-files`.
  - **Do not pipe to `tar` and do not redirect with `>`.** Both corrupt the archive or reject
    `C:\` paths on this machine.
  - **Its path must contain a space and sit outside any repo:**
    `%TEMP%\dsk plugin copy <n>\duckdb-skills`.
  - **`$P\contracts\` is deleted.**
  - **Several copies:** `$P1` and `$P2` are two such copies, in different folders.
- **How a skill's command is run (AC2).** Do not call `bash -c` from PowerShell. PS 5.1 strips
  inner double quotes, and `bash` may resolve to WSL.
  - **Build the command:** take decision 1's form verbatim and replace `${CLAUDE_PLUGIN_ROOT}`
    with `$P`'s Windows path **with backslashes**, e.g.
    `C:\Users\woodsonp\AppData\Local\Temp\dsk plugin copy 1\duckdb-skills`. That is the
    riskiest form Claude Code can substitute. Fill in `<script>`/`<args>`, and double-quote
    any argument path.
  - **Write it:** to `$S\ac2.sh` with `[IO.File]::WriteAllText($sh, $cmd + "`n")`, which gives
    LF and no BOM.
  - **Run it:** with
    `Start-Process 'C:\Program Files\Git\bin\bash.exe' -ArgumentList $sh -WorkingDirectory $W -RedirectStandardOutput … -RedirectStandardError … -NoNewWindow -Wait -PassThru`.
  - **Record it:** quote the exact command line in `RESULT`/`VERIFY`.
- **`$G`:** a fresh folder under `%TEMP%` with `git init` run in it.
- **`snap`, guarded cleanup, and never touching the real project's lake/extracts:** all as in
  item 1.
- **No check here writes to the real lake.**

## Acceptance checks

**AC1 — No bare repo-relative script path is left in the four skills.**
- **Search:**

  ```powershell
  Select-String -Path "$W\skills\lakehouse\SKILL.md","$W\skills\snowflake-extract\SKILL.md","$W\skills\read-file\SKILL.md","$W\skills\query\SKILL.md" `
    -Pattern '(?<!\$\{CLAUDE_PLUGIN_ROOT\}/)(tools[\\/]|skills[\\/]query[\\/]duckdb-compat)'
  ```

  **Expect: 0 matches.**
- **Prefixed occurrences:** quote each file's count in `RESULT-1.md`.
- **The section:** `Select-String -SimpleMatch` for decision 1's command line finds exactly 1
  match per file.

**AC2 — The skills' command form runs from a copy whose path has spaces and backslashes.**
- **How:** run every command by the harness in Conventions, with `$W` as the working
  directory. What this proves is that the **form** survives a spaced backslash path.
- **`lakehouse`:** `lake-status.ps1 -LakeRoot "<scratch>"`.
  - stdout `no lake`, exit 0;
  - stderr `project: <W id> (<$W>)`.
- **`snowflake-extract`:** `list-extracts.ps1 -ExtractRoot "<scratch>"`.
  - stdout `no extracts registered under <scratch>`, exit 0.
- **`read-file`:** first run `tools\make-truncation-fixtures.ps1 -Path "<scratch with a space>"`.
  Then `list-sheets.ps1 "<that folder>\dsk-fixture-a.xlsx"`.
  - stdout is exactly `position=1 name=Sheet1 contract_filename=contracts\Sheet1.sql`, then
    `total_sheets=1`;
  - exit 0.
- **Record:** quote each exact command line. The `$P` path in it is the evidence of where the
  script ran.

**AC3 — Two plugin versions leave one compat line, and nothing else moves.**
- **Setup:** in `$G`, write `$G\.duckdb-skills\state.sql` with these four lines:
  - `ATTACH 'x.duckdb' AS x;`
  - `.read C:/some/other/file.sql`
  - `.read C:/old plugin/skills/query/duckdb-compat.sql`, the legacy unquoted form;
  - `LOAD excel;`
- **Run `ensure-duckdb-compat`** from `$G` using `$P1`'s copy, then again using `$P2`'s copy.
- **After the second run:**
  - **Exactly one line** contains `duckdb-compat.sql`. It equals
    `.read '<$P2 with forward slashes>/skills/query/duckdb-compat.sql'`, so the legacy line is
    gone.
  - **The other three original lines** are present, in their original order.
  - **No BOM**, and line 1 of the tool's stdout is the state-file path.
- **Third run, again with `$P2`:** the file is byte-identical to after the second run.
- **DuckDB accepts it:** remove the `ATTACH` and `.read C:/some/other…` lines, whose targets
  do not exist. Then
  `duckdb -init "$G\.duckdb-skills\state.sql" -c "SELECT xl_date(46204)"` prints `2026-07-01`
  and exits 0. With the unquoted spaced line the current code writes, this exits 1.

**AC4 — `.duckdb-skills/` gets gitignored, once, without disturbing the file.**
Cases A and B run `$P1`'s `ensure-duckdb-compat.ps1` from `$G`. Case C runs it from `$W`.
- **Case A, a fresh `$G` with no `.gitignore`:**
  - afterwards `.gitignore` is exactly the 16 bytes `.duckdb-skills/` + `0A`;
  - `git -C $G status --porcelain` shows `.gitignore` and **not** `.duckdb-skills/`;
  - stdout has a line starting `NOTE: added`;
  - a second run leaves `.gitignore` byte-identical and prints no line starting
    `NOTE: added`.
- **Case B, a fresh `$G` whose `.gitignore` is `node_modules` with no trailing newline:**
  afterwards it is exactly `node_modules` `0A` `.duckdb-skills/` `0A`.
- **Case C, from `$W`, whose `.gitignore` already ignores it (with no trailing newline):**
  `$W\.gitignore` is byte-identical before and after (control).

**AC5 — Plugin identity.**
- **Valid JSON:** both files parse with `ConvertFrom-Json`.
- **Repository and owner:** `repository` (and the marketplace plugin entry's `repository`)
  are `https://github.com/woodsonpatclayco/duckdb-skills`, and the owner is
  `woodsonpatclayco`.
- **Names:** the plugin `name` is `duckdb-skills` and the marketplace `name` is
  `woodsonp-duckdb-skills`.
- **Version:** `0.2.4` in both.
- **Validator (optional):** if a `claude` executable is found (`Get-Command claude`), run
  `claude plugin validate $W` and quote the output. If it isn't found, say so. This is not
  pass/fail.

## Mutation proof — must fail, then pass again after revert

- **M1:** restore the add-only behaviour in `ensure-duckdb-compat` (skip the removal step).
  **AC3 must fail**, with two `duckdb-compat.sql` lines.

Mutate only inside `$W`. Revert by re-checking-out the committed file there.

## Final check — Phil

There is nothing for Phil to run until item 4. The real `${CLAUDE_PLUGIN_ROOT}` substitution is
only observable once the plugin is installed. Item 4's proof covers it.
