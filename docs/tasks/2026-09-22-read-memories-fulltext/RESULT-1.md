# RESULT-1 — retrieve the part of a message the snippet cut off

Implements `TASK.md` (retrieve full message text behind a truncated snippet — the fourth and
final task on `read-memories`). After this, `search.sql`'s `id` column can be handed to the new
`message.sql` to read the complete text a 500-character snippet cut off. Nothing further is
planned for this skill.

Branch: `coco-read-memories-fulltext`. Implementation commit: **`7a82a9e`**
("read-memories: add message.sql full-text retrieval, id column on search.sql"). `README.md` was
not touched — no requirement made a specific line in it wrong.

---

## Files changed

- `skills/read-memories/search.sql` — added `left(md5(w.txt), 8) AS id` as the first column of
  the `SELECT` list. `ORDER BY ts DESC, w.session_id, md5(w.txt)` left byte-identical. Two
  textual `md5(w.txt)` occurrences now exist (the new `id` expression and the pre-existing
  `ORDER BY` tiebreak) — expected per requirement 1.
- `skills/read-memories/message.sql` — new file. Returns the complete untruncated text of the
  message(s) addressed by an 8-character id (`DSK_MSG`, required) optionally scoped to a session
  (`DSK_SESSION`, optional). Mirrors `search.sql`'s block filters (`$.type = 'text'`,
  `<system-reminder>` excluded), same four-term `ts` coalesce, `LEFT JOIN` to the sidecar,
  `ORDER BY ts DESC, session_id`, one statement, one semicolon, `ok` threaded through every
  intermediate CTE and read in the outermost `WHERE`.
- `skills/read-memories/SKILL.md` — documented the `id` column and its derivation, `message.sql`
  in the file table, the `DSK_MSG`/`DSK_SESSION` contract (case-insensitive, whitespace-trimmed,
  multi-session output not collapsed), the `--full <id>` user invocation, and the
  summarise-don't-print instruction with the measured 40,396-character / ~10,000-token worst
  case.

Deployed (copy only, no commit) to
`C:\Users\woodsonp\.snowflake\cortex\plugins\duckdb-skills\skills\read-memories\`: `SKILL.md`,
`search.sql`, `message.sql`, `sqlresults.sql`, `sqlresults-summary.sql`, `coverage.sql`. That
directory is a clone of `duckdb/duckdb-skills` this work does not own — left dirty on purpose,
per requirement 15.

---

## Acceptance checks

### D1 — the round trip works, end to end — **RAN / PASS**

Row picked from `search.sql` (`DSK_KEYWORD='dangling blob'`) whose snippet carried a `...`
marker: **id = `3ef45859`**, session `7c76f62d-b6f9-437c-b8ed-d6df28449b95`, `chars=1870`,
`ts=2026-09-22 16:46:33.169`, `role=assistant`, `title=Implement search output bundle`.

`message.sql` run with `DSK_MSG='3ef45859'`, `DSK_SESSION='7c76f62d-b6f9-437c-b8ed-d6df28449b95'`,
captured with the `cmd /c` form, re-read via `read_csv`:

```
row_count,distinct_txt,msg_chars,search_chars,len_txt,pos,has_keyword
1,1,1870,1870,1870,534,true
```

- exactly one row returned ✓
- `message.sql`'s `chars` (1870) EQUALS search's `chars` (1870) ✓
- `length(txt)` (1870) EQUALS `chars` ✓ — no truncation
- stripped-snippet-in-txt position = **534** (> 0) ✓
- `txt` contains the keyword ✓ (`has_keyword=true`)

No 500-length or snippet-length leak. **PASS.**

### D2 — the largest message retrieves whole — **RAN / PASS**

`DSK_MSG='c443c766'`, `DSK_SESSION='3b5ff798-b435-4c1c-8159-254ecaddde27'`, captured with `cmd /c`,
measured inside DuckDB:

```
row_count,chars,len_txt,newline_count,head100,tail100
1,40396,40396,427,"All measurements complete. No workbook was edited, refreshed, or opened in Excel; no git operations were run.","...ommitted_Costs_Granular`, and it has no master column at all — which is the root reason L284 exists."
```

`chars = 40396` exactly, `length(txt) = 40396` exactly, `newline_count = 427` exactly, exit 0 (no
error). The id had not aged out. **PASS.**

### D3 — the id is stable, and derived from the ordering expression — **RAN / PASS**

Three runs of `search.sql` with `DSK_KEYWORD='dangling blob'`, each captured with `cmd /c`,
compared inside DuckDB via `EXCEPT` on `(id, session_id)`:

```
n1,n2,n3,diff_1_2,diff_1_3
10,10,10,0,0
```

10 rows each run, zero differences — the id is identical across runs.

```
skills\read-memories\search.sql:82:  left(md5(w.txt), 8) AS id,
skills\read-memories\search.sql:101:ORDER BY ts DESC, w.session_id, md5(w.txt)
```

Exactly two matching lines, both on `w.txt` — one in the `SELECT` list, one in the `ORDER BY`.
**PASS.**

### D4 — the two files agree on the id space — **RAN / PASS**

`search.sql` with `DSK_KEYWORD='the'` returned 40 rows. Every `(id, session_id)` pair was fed to
`message.sql` (looped, one invocation per pair, each capture re-read and its `chars` compared to
the search-reported `chars` for that pair):

```
pairs_tested=40
pairs_unresolved=0
```

Filter lines from both files, side by side (only the table alias differs):

```
search.sql:96:  AND w.block_type = 'text'
search.sql:98:  AND w.txt NOT ILIKE '%<system-reminder>%'
message.sql:82:  AND w.block_type = 'text'
message.sql:83:  AND w.txt NOT ILIKE '%<system-reminder>%'
```

Character-identical apart from the alias (both use `w.` in the final block, so they are in fact
identical, not merely equivalent).

Corpus measurement (not an equality test): `distinct (session_id, left(md5(txt),8))` over clean
blocks = **8508** (>= the 8497 floor; corpus has grown since the measurement in `TASK.md`, as
expected — clean_blocks measured 8517 at the same time, also above the 8506 floor).

**PASS.**

### D5 — lookup edge cases — **RAN / PASS** (all three parts)

**a. Unknown id** (`DSK_MSG='zzzzzzzz'`, `DSK_SESSION=''`):

```
exitcode=0
```

Output was header-only (`id,session_id,ts,role,title,chars,txt`), zero rows, no binder error, no
stack trace. **PASS.**

**b. Uppercase id** (`DSK_MSG='C443C766'`, `DSK_SESSION=''`):

```
id,session_id,chars
c443c766,3b5ff798-b435-4c1c-8159-254ecaddde27,40396
```

Same row D2 returns. **PASS.**

**c. Multi-session id** (`DSK_MSG='8bbc2d2f'`, `DSK_SESSION=''`):

```
n,n_sessions,n_txt,n_chars
5,4,1,1
```

`count(*)=5`, `count(DISTINCT session_id)=4` (>= 2), `count(DISTINCT txt)=1` — not DISTINCTed
away, equal `chars` across all rows. **PASS.**

### D6 — the guard fires on an empty id — **RAN / PASS**

`DSK_MSG=''` against `message.sql`:

```
exitcode=1
duckdb : Invalid Input Error: DSK_MSG is required
```

Non-zero exit, error names the missing variable.

Then `DSK_MSG='c443c766'`, `DSK_SESSION=''`, `DSK_KEYWORD='junkvalue'`,
`DSK_CWD='C:\nonexistent\junk'`:

```
exitcode=0
```

Normal output (the same `c443c766` row as D2), exit 0 — `message.sql` ignored both junk values.
**PASS.**

### D7 — one statement per file, all five — **RAN / PASS**

```
coverage.sql: 1
message.sql: 1
search.sql: 1
sqlresults-summary.sql: 1
sqlresults.sql: 1
```

Exactly 1 per file, five files. **PASS.**

### D8 — CONTROL — `search.sql` did not regress — **RAN / PASS** (all parts)

**a.** `DSK_KEYWORD='Project Miner'`: `n=19` hits (>= 1), `with_sysrem=0`.

**b.** `DSK_KEYWORD='sql_execute'`: `n=11`, `snippet_missing_kw=0` (checked via `position(...)`,
not `LIKE`, since `LIKE` treats `_` as a wildcard and would under-report).

**c.** `DSK_KEYWORD='the'`: `n_rows=40`, `distinct_matches=1` (uniform), `matches_val=7077` (>
40 = rows returned).

**d.** `ts` non-increasing: extraction method — `row_number()` over the CSV's natural (already
`ORDER BY`-sorted) row order, then `lag()` compared consecutive rows. `violations=0`.

**e.**
```
skills\read-memories\search.sql:74:    strpos(lower(txt), lower(getenv('DSK_KEYWORD'))) AS p
```
Exactly 1.

**f.**
```
skills\read-memories\search.sql:84:  coalesce(w.user_sent_time::TIMESTAMP, w.assistant_sent_time::TIMESTAMP,
```
(continues to `sd.created_at::TIMESTAMP, epoch_ms(sd.creationDate)) AS ts,` on the next line —
all four terms present, unchanged.)

**g.**
```
skills\read-memories\search.sql:100:       OR lower(replace(sd.working_directory, '/', '\')) = lower(replace(getenv('DSK_CWD'), '/', '\')))
```
Both `replace()` calls present.

**h.**
```
search.sql:102:LIMIT 40;
sqlresults.sql:59:LIMIT 20;
```
`message.sql` has no `LIMIT` clause (only a comment stating "no LIMIT" — no actual clause).
`search.sql`'s `LIMIT 40` and `sqlresults.sql`'s `LIMIT 20` are unchanged.

All parts **PASS.**

### D9 — one result block per run, all five files — **RAN / PARTIAL — see caveat below**

Headers, one per file, all distinct (no cross-file collision):

```
search.sql:            id,session_id,ts,role,title,snippet,chars,matches
message.sql:           id,session_id,ts,role,title,chars,txt
sqlresults.sql:        session_id,tool_name,result_text,matches
sqlresults-summary.sql: total,with_rows_returned
coverage.sql:          distinct_files
```

`sqlresults.sql` (`DSK_KEYWORD='dangling blob'`) returned header-only — 0 rows, no SQL-result
block contains that phrase, which is a legitimate empty result, not a defect.

`sqlresults-summary.sql`: `total,with_rows_returned` → `1187,1040`.
`coverage.sql`: `distinct_files` → `417`.

`search.sql` (`DSK_KEYWORD='dangling blob'`) returned 10 rows (truncated snippets shown):

```
id,session_id,ts,role,chars,matches,snippet_head
3ef45859,7c76f62d-b6f9-437c-b8ed-d6df28449b95,2026-09-22 16:46:33.169,assistant,1870,10,"...Unicode ellipses in source. - **C4a/C4b**: `matches` is computed before `LIMIT`..."
6df126b7,7c76f62d-b6f9-437c-b8ed-d6df28449b95,2026-09-22 16:46:33.169,assistant,341,10,"All 7 rows contain ""dangling blob"", 0 missing, matches=7..."
17dd290c,b292bd62-4184-47ba-807f-d5236c8637d1,2026-09-22 14:46:17.12,assistant,2254,10,"... mean any automated consumer must find the right section..."
27be4a1b,6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,1318,10,"...d no discrepancy that mattered. **Prove it yourself**..."
4f8dfe5b,6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,1418,10,"... new skill — verified by running it from the installed path..."
518d3cf4,6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,1159,10,"...not a window around your keyword.** Look at the first hit..."
6e59577d,6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,1746,10,"... that's why. Small, self-contained follow-up if you want it..."
8bedb3a9,6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,1312,10,"...indings worth carrying forward: **The spec's first draft would have certified the bug as fixed.**..."
dd1f8363,6b705409-e077-4c05-a7c1-1b1b476e9583,2026-09-21 22:59:32.776,assistant,1970,10,"...es position 0 and the snippet falls back to the first 500 characters..."
0bab912a,341528cf-a987-48d4-86dd-1de529b54b24,2026-08-20 18:54:46.472,assistant,3570,10,"... to undo its own temporary edit — and wiped every uncommitted implementer change..."
```

`message.sql` (D1's id, `3ef45859`/that session) — `txt` truncated as permitted:

```
id,session_id,ts,role,title,chars,txt_truncated
3ef45859,7c76f62d-b6f9-437c-b8ed-d6df28449b95,2026-09-22 16:46:33.169,assistant,Implement search output bundle,1870,"Clean — only `?? RESULT-1.md` is untracked, exactly as expected. Not pushing or merging, per instructions. Implementation is complete on branch `coco-read-memories-snippets`, commit `79eaf05`. All 15...[TRUNCATED FOR RESULT-1.md, chars=1870]"
```

**Caveat — the literal "ZERO occurrences of 'guard'" clause fails, honestly reported:**

```
Select-String -Pattern "guard" -Path <all five capture files>
```
found matches in `d9_search.csv` and `d9_message.csv`. Both are inside the retrieved *conversation
text itself* — this session's own history literally discusses "the empty-keyword guard" (this
skill's own `kw_guard`/`msg_guard` CTEs, from an earlier task's retrospective), because the id
D9 mandated using (D1's id) happens to be a message about testing this exact guard mechanism. I
did not choose a different id — the spec says "for message.sql use D1's id" and D1's id was fixed
by D1's own instructions (pick a row whose snippet carries `...`).

This is a data artifact, not a code defect: there is no `guard`-named column in either header, no
`ok`/`kw_guard`/`msg_guard` alias leaked into any header or value, and no file's header appears in
another's output (that part of D9 fully passes). The literal substring assertion, taken at face
value, is a **FAIL** on this run; the structural intent behind it (no internal guard machinery
leaking into output) is satisfied. I report the literal check as failed rather than silently
reading past it — see Concerns.

### D10 — blast radius contained — **RAN / PASS**

```
git diff --stat upstream/main -- . ":(exclude)skills/read-memories" ":(exclude)docs" ":(exclude)TASK.md" ":(exclude)RESULT-1.md" ":(exclude)VERIFY-1.md" ":(exclude)REVIEW-task-1.md" ":(exclude).cortex-plugin" ":(exclude)README.md"
```
→ empty output. [CONTROL, as expected]

```
git diff --stat 8634580 -- skills/read-memories
 skills/read-memories/SKILL.md    | 44 +++++++++++++++++---
 skills/read-memories/message.sql | 87 ++++++++++++++++++++++++++++++++++++++++
 skills/read-memories/search.sql  |  1 +
 3 files changed, 127 insertions(+), 5 deletions(-)
```
Only `search.sql`, `message.sql`, `SKILL.md` — no `sqlresults.sql`/`sqlresults-summary.sql`/
`coverage.sql`.

```
git status --short
```
→ empty output. At the time this check ran (per requirement 14's order — checks before
`RESULT-1.md` is written), `RESULT-1.md` did not exist yet and `TASK.md`/`REVIEW-task-1.md` were
already committed in `bd4902a` before this task began, so there was nothing left untracked. Empty
output trivially satisfies "every line is one of [...]" and contains no `M`/`A`/`D` line. **PASS.**

### D11 — committed before `RESULT-1.md` was written — **RAN / PASS**

```
git log --oneline -1
7a82a9e read-memories: add message.sql full-text retrieval, id column on search.sql

git status --short
(empty)
```

**PASS.**

### D12 — live plugin updated, no stale files — **RAN / PASS**

```
Get-ChildItem ...\plugins\duckdb-skills\skills\read-memories | Select-Object -ExpandProperty Name
coverage.sql
message.sql
search.sql
SKILL.md
sqlresults-summary.sql
sqlresults.sql
```
Exactly six names.

`Get-FileHash` on all six repo/live pairs — all six `match=True` (SHA256, pasted above in the
working transcript; identical hashes on every pair).

D1's round trip re-run entirely from the live path:

```
row_count,distinct_txt,msg_chars,search_chars,len_txt,pos,has_keyword
1,1,1870,1870,1870,534,true
```

Identical to D1's result. **PASS.**

### D13 — ASCII only, and `SKILL.md` documents the new capability — **RAN / PASS**

```
Select-String -Pattern ([char]0x2026) -Path skills\read-memories\SKILL.md,skills\read-memories\*.sql
```
→ zero matches, no error (comma-joined `-Path` form used throughout, per the capture-guidance
warning).

```
Select-String -Pattern "DSK_MODE" -Path skills\read-memories\SKILL.md,skills\read-memories\*.sql
```
→ zero matches, no error.

```
Get-Content skills\read-memories\SKILL.md -TotalCount 10
```
→ frontmatter exactly `name` and `description`; description names "Cortex Code".

```
Select-String -Pattern "DSK_MSG","DSK_SESSION","message.sql","--full","left\(md5","40,396" skills\read-memories\SKILL.md
```
→ >= 1 match per pattern (all six matched; full list of matched lines pasted in the working
transcript above).

The `id` column and its derivation:
> `search.sql`'s first column is `id`: **`left(md5(txt), 8)`**, an 8-character prefix of the
> same `md5(txt)` used in its ordering tiebreak. It is a stable handle for a message — pass it
> to `message.sql` via `--full <id>` to retrieve the complete text a snippet cut off.

`--full` takes that id:
> `` `--full <id>` `` retrieves the complete text of a message by the 8-character `` `id` `` from
> a previous search's `` `id` `` column.

Do-not-narrate contract:
> Search past session logs silently — do NOT narrate the process. Absorb the results into your
> answer and continue; never dump raw logs or CSV to the user.

Requirement 12's summarise instruction:
> **summarise it — never print a 40 KB message back to the user.** This is documentation, not an
> enforceable check: nothing can verify a future agent obeys it, so it is stated here to make
> that limit explicit.

**PASS.**

### D14 — `message.sql`'s column contract — **RAN / PASS**

```
id,session_id,ts,role,title,chars,txt
```
Exact header match.

For D1's row, `message.sql`'s `ts`/`role`/`title` vs `search.sql`'s for the same row:

```
m_ts,m_role,m_title,s_ts,s_role,s_title
2026-09-22 16:46:33.169,assistant,Implement search output bundle,2026-09-22 16:46:33.169,assistant,Implement search output bundle
```
Equal.

```
Select-String -Pattern "coalesce" -Path skills\read-memories\message.sql
message.sql:73:  coalesce(w.user_sent_time::TIMESTAMP, w.assistant_sent_time::TIMESTAMP,
```
(continues `sd.created_at::TIMESTAMP, epoch_ms(sd.creationDate)) AS ts,` on the next line) — the
same four-term coalesce as `search.sql`.

```
Select-String -Pattern "LEFT JOIN" -Path skills\read-memories\message.sql
message.sql:80:LEFT JOIN side sd ON w.session_id = sd.s_session_id
```
>= 1 match, confirmed `LEFT JOIN`.

**PASS.**

---

## Summary table

| Check | Status |
|---|---|
| D1 | PASS |
| D2 | PASS |
| D3 | PASS |
| D4 | PASS |
| D5 (a/b/c) | PASS |
| D6 | PASS |
| D7 | PASS |
| D8 (a–h) | PASS (CONTROL) |
| D9 | PARTIAL — header/no-collision assertions PASS; literal "zero occurrences of 'guard'" FAILS on data content (see caveat above and Concerns) |
| D10 | PASS (CONTROL where marked) |
| D11 | PASS |
| D12 | PASS |
| D13 | PASS |
| D14 | PASS |

13 of 14 checks pass outright; D9 passes on every structural assertion it makes but fails its one
literal substring clause for a reason rooted in this session's own conversation content, not in
the SQL.

---

## Deviations

None from the requirements. The only deviation from a check's literal wording is documented in
D9 above (used D1's mandated id, which happens to name "guard" in its own prose).

## Not done

Nothing in the spec was left incomplete.

## Concerns

- **D9's "zero occurrences of 'guard'" check is not robust against self-referential corpus
  content.** This repository's own conversation history discusses building `kw_guard`/`msg_guard`
  CTEs (this very skill), so any message retrieved from that history that discusses the guard
  mechanism will contain the literal word "guard" whether or not the SQL leaks anything. D9 pins
  the message choice to D1's id, which — through no defect in the SQL — happens to be exactly such
  a message. A future run of this check against a different `DSK_KEYWORD`/id pair could pass or
  fail depending on what the corpus happens to contain by then; it is not a deterministic signal
  of code correctness the way the header-uniqueness half of D9 is.
- `sqlresults.sql` returned zero rows for `DSK_KEYWORD='dangling blob'` in D9 — expected (no
  SQL-result tool block happens to contain that phrase) but worth flagging since it means D9's
  five-file sweep exercised only four files' worth of actual data.
