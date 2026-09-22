# VERIFY-1 -- independent verification of RESULT-1.md

Verifying: RESULT-1.md (round 1, commit 5635576). Worktree used: disposable
git worktree at C:\Users\woodsonp\Claude\Dev\_verify-noise, detached at
5635576. All work below was read-only against tracked files; scratch files
were written only under $env:TEMP\noguard\. git status --short before and
after this session shows only the pre-existing ?? RESULT-1.md; HEAD is
unchanged at 563557617fbd6489d9c11b26f1fdc3eef8a84786.

## Overall verdict: SHIP

All 15 acceptance checks reproduce independently. The disclosed guard deviation
is real, necessary, and does not alter returned rows. One cosmetic caveat noted
below (a coincidental substring match), which is not a defect.

## Per-check table

| Check | Expected | My result | Verdict |
|---|---|---|---|
| B1 (4 files, 1 block each) | 1 header/block per file, no cross-contamination, 1 `;`/file | coverage=**403** now (was 401 in RESULT-1, drift); sqlresults-summary=`1184,1037`; sqlresults(`row(s) returned`)=339 lines/1 header; search(`read_xlsx`)=16 lines/1 header. Semicolons: coverage.sql:1, search.sql:1, sqlresults-summary.sql:1, sqlresults.sql:1 | PASS -- see caveat below on a literal "guard" grep hit |
| B2 (false zeros gone) | no distinct_files/0,NULL/bare 0 outside own file | confirmed via Select-String, zero matches | PASS |
| B3 (coverage sees whole corpus) | >=399 and > sub-level count | coverage=403, sub-level (Get-ChildItem *\*.history.jsonl)=366 -> 403>366 | PASS |
| B4 (sqlresults both tool names) | total>=1179, with_rows_returned>=1033 | 1184,1037 (sqlresults-summary.sql); sqlresults.sql w/ `row(s) returned` returns rendered result sets | PASS |
| B5 (search readable prose) | >=1 hit, role/ts non-empty, prose not JSON | 2 corpus hits + 1 session-drift hit, all readable, role/ts populated | PASS |
| B6 (--here scoping + replace()) | scoped < unscoped, >0; both replace() present | scoped(this worktree path)=0/0 (expected -- new path never logged before); scoped against real duckdb-skills path=45, unscoped=82 (45<<82, both >0); both replace() calls present verbatim at line 69 | PASS |
| B7 (empty keyword) | search/sqlresults error+exit1; coverage/summary exit0 | search.sql -> "Invalid Input Error: DSK_KEYWORD is required", EXIT=1; sqlresults.sql -> same, EXIT=1; coverage.sql -> 403,EXIT=0; sqlresults-summary.sql -> 1184,1037,EXIT=0 | PASS |
| B8 (control) | non-zero exit, IO error | IO Error: Failed to open file "...bogus.sql", EXIT=1 | PASS (control, unchanged) |
| B9 (no struct/column errors) | zero matches; read_ndjson/json count = columns{} count | zero matches; both counts = 5; $.type filters: search='text', both sqlresults*='tool_result' | PASS |
| B10 (system-reminder excluded) | >=1 hit, 0 with <system-reminder> | 110 hits (111 lines - header), 0 matches for <system-reminder> | PASS |
| B11 (behavioral equivalence) | old answer block subset-of new output; new totals >= old | Compare-Object on extracted old vs new search answer blocks -> empty (identical, 16/16 lines); old(DSK_MODE=sqlresults, empty kw)=1184,1037 vs new sqlresults-summary.sql=1184,1037, equal | PASS -- hit the same encoding pitfall RESULT-1 describes, see notes below |
| B12 (live plugin) | exactly 5 files, hashes match, live search works | listing = exactly the 5 expected names; all 5 SHA256 hashes match repo copies; live search(read_xlsx)=16 lines/1 header | PASS |
| B13 (blast radius) | empty diff-stat outside scope; git status only task artifacts | git diff --stat upstream/main -- . :(exclude)... = empty; git status --short = ?? RESULT-1.md only | PASS |
| B14 (committed before RESULT) | commit exists, no M lines | HEAD=5635576 read-memories: split search.sql...; git status --short has no M lines | PASS |
| B15 (frontmatter/contract) | name+description only; required patterns present; DSK_MODE gone; narrate contract present | frontmatter exactly name/description; matches for all 4 required patterns; zero DSK_MODE matches anywhere; narrate/Absorb line present at SKILL.md:10 | PASS |

Diff-stat of the round's own commit (d44c494 -> 5635576) confirms blast radius
is exactly the 5 documented files, README.md untouched:
```
skills/read-memories/SKILL.md               |  54 +++++++-------
skills/read-memories/coverage.sql           |  16 ++++
skills/read-memories/search.sql             | 111 ++++------------------------
skills/read-memories/sqlresults-summary.sql |  31 ++++++++
skills/read-memories/sqlresults.sql         |  50 +++++++++++++
5 files changed, 141 insertions(+), 121 deletions(-)
```

## Item 1 -- the disclosed guard deviation, verified independently

Claim (a): the unreferenced guard shape is dead-code-eliminated. Confirmed
with a minimal repro, run fresh in this worktree, DSK_KEYWORD unset:
```
duckdb -csv -c "WITH kw_guard AS (SELECT CASE WHEN coalesce(getenv('DSK_KEYWORD'), '') = ''
  THEN error('DSK_KEYWORD is required') ELSE 1 END AS ok), hist AS (SELECT 1 AS a)
  SELECT a FROM hist, kw_guard;"
-> a / 1, EXIT=0
```
The guard column is never read, error() never fires. Matches RESULT-1's claim
exactly.

Claim (b): threading ok into the final WHERE forces evaluation and fires
correctly, without altering rows for a non-empty keyword. Confirmed the
firing half:
```
$env:DSK_KEYWORD=''
duckdb -csv -c "... SELECT a FROM hist, kw_guard WHERE kw_guard.ok = 1;"
-> Invalid Input Error: DSK_KEYWORD is required, EXIT=1
```

For the row-preservation half -- the one the task flagged as mattering most --
I did not trust prose. I built no-guard variants of the real search.sql and
sqlresults.sql (guard CTE and ok column stripped entirely, everything else
byte-identical) and compared against the shipped, guard-threaded files for
several keywords used elsewhere in this verification:

- search.sql, keyword read_xlsx: guarded=3, no-guard=3
- search.sql, keyword duckdb (unscoped): guarded=17, no-guard=17
- search.sql, keyword Project Miner: guarded=16, no-guard=16
- sqlresults.sql, keyword row(s) returned: guarded=1037, no-guard=1037

All four pairs identical. (I initially compared row-level CSV output under
LIMIT/ORDER BY session_id instead of COUNT(*) and got a false alarm -- 306 vs
329 lines, then 306 vs 228 on two runs of the UNMODIFIED file back to back.
That is real, pre-existing nondeterminism in ORDER BY session_id LIMIT 20 when
many rows tie on session_id -- confirmed present in the old single-file
version at 2e23118 too, identical ORDER BY/LIMIT shape, so it is not a
regression introduced by this round. Switching to COUNT(*) with no LIMIT
removes the tie-breaking noise and gives a clean, deterministic comparison.)

Conclusion: both halves of the claim hold. The threaded guard fires on an
empty keyword and returns exactly the same rows as no guard at all on a
non-empty one. The deviation from the literal spec text was necessary -- the
spec's own quoted shape does not work, as claim (a) confirms -- and the fix
does not silently filter data.

## Item 2 -- B1 semicolon count

Confirmed exactly 1 semicolon per file. Read all four comments that were
candidates for the described rewrite: search.sql's "DSK_KEYWORD substring to
match, required (...)" and "--here scoping, '' = no directory filter", and
sqlresults.sql's "corpus's lifetime, match both via...". Compared against the
pre-round file at d44c494 (which still used semicolons as punctuation:
"substring to match; '' = no keyword filter", etc.) -- the meaning of each
comment is intact after the comma rewrite; none reads as incorrect SQL or
misleading documentation.

## Item 3 -- requirement 2 preserve-verbatim checklist

| Item | Found |
|---|---|
| both glob depths, every history read | *.history.jsonl + *\*.history.jsonl present in all 4 files that read history (coverage.sql:12-13, search.sql:35-36, sqlresults-summary.sql:13-14, sqlresults.sql:23-24) |
| explicit columns={} on every read | 5 read_ndjson/read_json calls, 5 "columns = {" -- all explicit, content typed 'JSON' everywhere |
| LIKE '%sql_execute' not narrowed | present verbatim in both sqlresults-summary.sql:26 and sqlresults.sql:40 |
| 4-term ts coalesce | search.sql:57-58: coalesce(b.user_sent_time::TIMESTAMP, b.assistant_sent_time::TIMESTAMP, s.created_at::TIMESTAMP, epoch_ms(s.creationDate)) -- all four terms intact |
| both replace() in --here comparison | search.sql:69, both calls present verbatim |
| $.type='text' + <system-reminder> exclusion in search.sql | both present (search.sql:65,67) |
| $.type='tool_result' in both sqlresults files | present in sqlresults.sql:39 and sqlresults-summary.sql:25 |

Nothing on the list was dropped.

## Item 4 -- B11 re-run

Re-ran independently, hit the exact encoding pitfall RESULT-1 describes: a
naive "git show 2e23118:... > file.sql" using PowerShell's default redirect
produced a UTF-16-with-BOM file that DuckDB rejected (Parser Error: syntax
error at or near a box-drawing character). Re-extracted with
"| Out-File -Encoding utf8", after which old.sql ran correctly and reproduced
the exact 4-block noise pattern from TASK.md (guard / distinct_files 0 /
total,with_rows_returned 0,NULL / two headers with no rows / the real answer).
Compare-Object between the extracted old answer block (16 lines) and the new
search.sql output (16 lines) is EMPTY -- confirmed, no row present in old is
missing from new. Summary comparison: old under DSK_MODE=sqlresults, empty
keyword -> 1184,1037; new sqlresults-summary.sql -> 1184,1037. Equal, matching
RESULT-1's claim.

## Item 5 -- B12 re-run

Live plugin directory listing is exactly the 5 expected names. All 5 SHA256
hashes match the worktree copies exactly (full hashes captured, byte digest
identical to RESULT-1's truncated ones). A search run directly against the
live path returns one clean block, 16 lines, matching the repo-path run.

## Independent search of my own choosing

Keyword "verify" (plausible real recall query), unscoped:
```
$env:DSK_KEYWORD='verify'; $env:DSK_CWD=''
duckdb -csv -f ".\skills\read-memories\search.sql"
EXIT=0, 82 lines total (1 header + 81 hit rows)
```
Header count check: exactly 1 occurrence of session_id,ts,role,title,snippet
in the output. No guard, distinct_files, or total,with_rows_returned noise
lines anywhere. First few rows, pasted raw:
```
session_id,ts,role,title,snippet
60778add-dfe0-4aac-a822-76d49b38779d,2026-07-30 18:26:51.022,assistant,Review Comments on Contract Budget Lines,Now let me verify the rewire produces identical numbers to the name-based logic.
60778add-dfe0-4aac-a822-76d49b38779d,2026-07-30 18:26:51.022,assistant,Review Comments on Contract Budget Lines,"25 of 26 categories match (1,552 of 1,557 lines). Let me verify the mapping is 1:1 before recommending it."
a5acdbd9-1273-471e-90c8-7971380f488b,2026-07-30 21:46:13.609,assistant,Handle Procore Format Project Numbers,Now verifying the budget branch still returns the same totals after the join changes.
```
One block, real attributed prose, no fabricated facts. This is the entire
point of the task and it is achieved. (Cosmetic note, not a defect: some
em-dash/arrow characters render as mojibake in this PowerShell console's
codepage -- a terminal display artifact present identically in RESULT-1's own
pasted output, not something this round's SQL changed.)

## Discrepancies vs RESULT-1.md

- Corpus counts drifted further, as both documents predicted: my coverage.sql
  read 403 vs RESULT-1's 401; sub-level glob count 366 vs their 364. Both
  still satisfy the floor and the B3 inequality. Not a defect.
- A literal Select-String -Pattern "guard" across the four B1 outputs finds
  one hit in my sqlresults.sql run (keyword row(s) returned): a real
  recovered SQL schema row containing a column literally named SUBGUARD
  (| SUBGUARD | TEXT |). RESULT-1's own equivalent run reported zero matches.
  This is not a behavioral discrepancy -- it is a byproduct of the
  pre-existing ORDER BY session_id LIMIT 20 nondeterminism documented above:
  which 20 of 1037 matching rows come back varies run to run when many rows
  tie on session_id, so RESULT-1's specific run didn't happen to include this
  row and mine did. It is coincidental data content, not the fabricated
  "guard" header block B1 exists to catch, and it does not indicate the noise
  defect has returned. Worth knowing about if anyone re-runs B1's literal
  grep and gets a hit: check what matched before treating it as a regression.
- No other discrepancy found. Every other pasted figure, hash, and message in
  RESULT-1.md reproduced either exactly or within the disclosed corpus-drift
  margin.
