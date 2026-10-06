# REVIEW-task-1 — task-reviewer on the first item-2 draft (commit 19c3155)

**Verdict: NOT READY.**
- **The checks:** two commands in the spec failed on this machine exactly as written.
- **A real product bug:** the tool change had one that no check would have caught.

All findings below were folded into TASK.md.

## Round-2 risks — fixed

1. **AC2's `bash -c` from PowerShell 5.1 strips inner quotes.** The reviewer ran
   `bash -c 'printf "[%s]\n" "a b" c'` and got `[a]n`. `bash` may also resolve to WSL.
   - **Now:** an LF `.sh` file is run by Git's `bash.exe` via `Start-Process`, with a backslash
     spaced plugin path. Tested: `no lake`, exit 0.
2. **Building `$P` with `git archive | tar` corrupted the archive in PS 5.1**, and GNU tar
   rejects `C:\` paths.
   - **Now:** `git archive --format=zip -o` plus `Expand-Archive`. Tested: 145 files, equal
     to `git ls-files`.
3. **Product bug: `.read` lines were unquoted, and DuckDB rejects a spaced unquoted path.**
   Tested: exit 1 unquoted, exit 0 quoted. AC3 only inspected text, so it would have certified
   a broken `state.sql`.
   - **Now:** the line is single-quoted, and the legacy unquoted line is removed.
   - **AC3:** it now runs `duckdb -init … SELECT xl_date(46204)` and expects `2026-07-01`.
4. **The read-file fixture has one sheet, not two.** The exact expected output is now pinned.
5. **`.gitignore` line endings and BOM were unpinned.** They are now LF-only via
   `AppendAllText`, with exact bytes in AC4.
6. **"No NOTE" could fail on an unrelated home-side NOTE.** It is now "no `NOTE: added`".
7. **AC4 did not say which tool copy runs.** It is pinned now.
8. **AC1 had no literal command and missed `lakehouse:44`.** The exact `Select-String` is now
   given.
9. **`snowflake-extract:35` said to dot-source a script.** The "library, not tool" sentence
   was added.

## Drift from the plan — now stated in TASK.md

- **The plan's proof said the output shows "the copy's script folder", but no tool prints
  that.** The spec now says the command line is the evidence. Item 4's proof must be worded
  the same way.
- **The materialize-in-plugin-layout control was dropped.** Item 1 already proved contracts
  come from the project, and Phil prefers few checks.
- **Small expansions, all harmless:**
  - the "Running the tools" section;
  - the marketplace renamed to `woodsonp-duckdb-skills` (install name
    `duckdb-skills@woodsonp-duckdb-skills`);
  - the new description;
  - the `NOTE: added` line.
