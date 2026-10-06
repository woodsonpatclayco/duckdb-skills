# REVIEW-plan-5 — plan-reviewer on the first PLAN-5 draft (commit 4d64dcd)

**Verdict: REVISE.** The approach and the order of the three items are right. Two proofs and one
rule needed fixing. All findings below were folded into PLAN-5.md.

## Blocking — fixed

1. **Item 1's proof could not pass in the verifier's worktree, and could write to the real lake.**
   - **In the worktree:** a worktree is its own git root, so it gets a different project id.
     There, "materialize reports SKIPPED" would instead build a new stray project folder and
     materialize Phil's real workbooks. `prove-no-snowflake.ps1:36-40` already records this
     trap.
   - **Fixed:** the proof now uses scratch `-LakeRoot` and shows what got resolved. The real-lake
     SKIPPED check moved to a manual check Phil runs after merge.
2. **Item 2's proof could pass without the fix.**
   - **Why:** a marketplace copy (`source: "./"`) carries `contracts\` byte-identical, so the old
     "parent of script folder" rule would also SKIP.
   - **Fixed:** the copy has `contracts\` deleted. Output must name the copy as the script folder
     and the project as the contracts folder.
3. **"Read-only tools refuse when the project folder is missing" broke fresh projects.**
   - **What broke:** `lake-status:68-70` and `list-extracts:83-86` correctly print "nothing yet"
     with exit 0. The extract skill runs `list-extracts` first every time.
   - **Fixed:** refusal applies only outside a git repo. Inside one, read-only tools create
     nothing and keep their current answers. `extract-decide` joined the read-only group. The
     extract skill's staging step may create the extract root.
4. **"Project on the first output line" collided with promised output formats.**
   - **Affected tools:** `ensure-duckdb-compat:37`, `extract-status:4`, `list-extracts`'
     existing `project-id:` (2a AC1), and `cross-query`'s result data.
   - **Fixed:** those are exempt and write the project line to stderr.

## Non-blocking — folded in

- **Dead `.read` lines:** plugin updates change the cache path, so `ensure-duckdb-compat`'s
  prepend-only `state.sql` handling would leave a dead line. Item 2 now replaces the line.
- **Updates need a version change:** new commits reach an install only when `version` changes.
  The Claude Code docs confirm it (see PLAN-5 documentation facts). Item 3 states the release
  rule.
- **`read-memories` was scope growth.** Moved to "deliberately not changing".
- **`query` / `attach-db` keep the current-folder fallback.** Now stated as intended.
- **`.duckdb-skills\` in other projects** gets gitignored by `ensure-duckdb-compat`.
- **Paths the first draft missed:** `extract-decide.ps1:194`, `read-file\SKILL.md:21,23` and
  `query\SKILL.md:161` were missing from the facts. Added. `run-assertions` is named in item 1.
  `prove-requery` is declared repo-relative.
- **The `${CLAUDE_PLUGIN_ROOT}` question is settled from the documentation** before item 2,
  rather than measured inside it.
- **Header note:** PLAN-5 is a new plan, not a fifth version of the local-SQL plan.
