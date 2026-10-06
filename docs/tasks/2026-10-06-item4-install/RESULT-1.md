# RESULT-1 — item 4 (Installed in Claude Code)

## Files changed
- `.claude-plugin/marketplace.json` — added top-level `"description"` (same text as plugin.json). The top-level field satisfied the validator on the first try.
- `README.md` — fork note rewritten (5 lines); Discover-tab subsection deleted; install/update point at the fork with CLI equivalents and the version-bump sentence; `lakehouse` and `snowflake-extract` entries added; local-dev clone URL is the fork; issues section replaced. Line 87 (read-memories, "It cannot see Cortex Code sessions.") and Platform support untouched.
- `RESULT-1.md` — this file.

## Acceptance checks
**AC1 PASS.** `claude.exe plugin validate --strict .` -> `✔ Validation passed`, exit=0.
Control at base 80088b6 (throwaway detached worktree, removed after): `⚠ Found 1 warning: description: No marketplace description provided...` / `✘ Validation failed (--strict treats warnings as errors)`, exit=1.

**AC2 PASS.** Hits of `duckdb/duckdb-skills|duckdb-skills@duckdb-skills|Cortex Code`:
- README.md:5 (fork note, upstream link)
- README.md:9 (fork note, "Cortex Code is not a target of this fork.")
- README.md:87 (unchanged read-memories sentence, "It cannot see Cortex Code sessions.")
- README.md:222 (the one upstream issues URL)
Stale update line (`marketplace update duckdb-skills$`): no hits (rc=1).
Present: hits for `woodsonpatclayco/duckdb-skills` (18, 25, 187), `duckdb-skills@woodsonp-duckdb-skills` (19, 26), `plugin marketplace update woodsonp-duckdb-skills` (36, 43), `plugin update duckdb-skills@woodsonp-duckdb-skills` (37, 44).
Version-bump sentence (line 47): "A change reaches an installed copy only when `version` in `.claude-plugin\plugin.json` and `marketplace.json` is bumped."

**AC3 PASS.** README.md:109 `/duckdb-skills:lakehouse what's the lake status?`; README.md:116 `/duckdb-skills:snowflake-extract pull the job costs extract`. `skills/lakehouse/SKILL.md:2:name: lakehouse`; `skills/snowflake-extract/SKILL.md:2:name: snowflake-extract`.

## Deviations
- README line numbers shifted (line 78 is now 87) because of added text; content unchanged.
- The fork note's "What it changes" sentence is a single phrase list per decision 2.

## Not done
Nothing. Final check (install) is Phil's, after merge.

## Concerns
- git warns that LF will be replaced by CRLF in marketplace.json (autocrlf); harmless.
