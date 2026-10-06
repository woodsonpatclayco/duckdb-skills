# REVIEW-task-1 — task-reviewer on the first item-3b draft (commit c7bc8b9)

**Verdict: NOT READY.** The fixes were wording only.
- **What the reviewer checked:** read-only connector facts against DATAHUB, the connector's
  own source, and the real `dt_projects` extract.
- **What it found:** a correct implementation would still have failed several checks, for
  Windows I/O reasons.

All findings below were folded into TASK.md.

## Round-2 risks — fixed

1. **Redirected Python output on Windows is cp1252, and CSV rows end `\r\r\n`.** PowerShell
   counted 4 lines for a 2-line CSV. Now pinned: `sys.stdout.reconfigure(encoding='utf-8',
   newline='\n')` and `lineterminator='\n'`.
2. **The connector's browser sign-in `print()`s to stdout** (`webbrowser.py:166-177`). That
   corrupts the CSV/JSON when a token has expired. Now pinned:
   - `connect()` runs inside `redirect_stdout(sys.stderr)`;
   - verifier calls have a 180 s timeout, and `Initiating login request` on stderr means NOT
     RUN;
   - the main session does a sign-in check before the build and before the verification.
3. **Nothing supplied `--project-id` under `-ExtractRoot`.** The skill now says where it comes
   from, and AC3 passes `verify-3b`.
4. **A BOM from PowerShell-written `.sql` files would break the guard.** sf.py now reads with
   `utf-8-sig`, and the Conventions pin `[IO.File]::WriteAllText`.
5. **A trailing `;` or `--` comment would break `FROM (<query>)`.** sf.py now strips one
   trailing `;` and wraps the query with newlines.
6. **M1 re-ran the whole of AC3.** It now runs `unload` alone and expects `runtime_seconds`
   to be missing.
7. **Decision 6 (README) was a no-op.** It now reads "README is not changed".
8. **The sidecar's `source_rows` and `source_last_altered` were unchecked.** Both are now
   checked by shape, not by value, because `DT_PROJECTS` moves: 42,167 rows became 42,257.
9. **The guard is a guardrail, not a boundary.** Stated now, with `cursor.execute()`'s
   single-statement default as the backstop (measured).

## Confirmed sound (read-only measurements)

- **SHOW TABLES** CSV columns are lowercase `rows`/`bytes`.
- **`QUERY_HISTORY_BY_SESSION()`** filtered by `QUERY_ID` found the row on the first try.
- **AC1's `NO_SUCH_CONNECTION` proof** raises locally, so it shows the guard ran without
  connecting.
- **AC4 should pass legitimately.** The real extract's 107 columns are in ORDINAL_POSITION
  order, with matching types; the 2 LTZ columns, `START_DATE` and `FINISH_DATE`, appear as
  `TIMESTAMP`.
- **`bytes_check=AGREES`** is exact, and the old files sum to the sidecar's `output_bytes`.
