# VERIFY-1 — independent verification of RESULT-1.md

Verifies: **RESULT-1.md** (retrieve the full text behind a truncated search snippet — the
fourth and final task on `read-memories`). Worktree used for this verification: a disposable
`git worktree` at `C:\Users\woodsonp\Claude\Dev\_verify-full`, detached at commit `7a82a9e`
(the implementer's commit). All numbers below come from commands run against that path.

## Overall verdict: SHIP

13 of 14 checks pass outright on independent re-run, matching RESULT-1.md's own numbers almost
exactly (small drift on floor-based counts is expected — the corpus grows every session,
including this verification). D9 fails its literal wording for a reason that is a defect in the
check, not in the code — see adjudication below.

## Per-check table

| Check | Expected | Actual (this verification) | Verdict |
|---|---|---|---|
| D1 | 1 row; chars match; length(txt)=chars; pos>0; keyword present | `1,1,1870,1870,1870,534,true` | PASS |
| D2 | chars=40396 exactly; newlines=427; tail present | `1,40396,40396,427,...,"...root reason L284 exists."` | PASS |
| D3 | id stable across 3 runs; exactly 2 `md5` lines | `10,10,10,0,0`; 2 lines, both `w.txt` | PASS |
| D4 | 0 unresolved pairs; filters char-identical; corpus ≥8497 | 156/156 resolved across 5 keywords (see below) | PASS |
| D5a | 0 rows, exit 0 | header-only, exit=0 | PASS |
| D5b | uppercase id resolves to same row as D2 | `c443c766,...,40396` | PASS |
| D5c | ≥2 sessions, 1 distinct txt, not DISTINCTed away | `5,4,1,1` | PASS |
| D6 | non-zero exit + named error; then junk vars ignored | `exit=1`, `"DSK_MSG is required"`; then `exit=0`, correct row | PASS |
| D7 | exactly 1 `;` per file, 5 files | 1,1,1,1,1 | PASS |
| D8a | ≥1 hit, 0 with system-reminder | `n=19, with_sysrem=0` | PASS |
| D8b | 0 snippets missing keyword (position-based) | `n=12, snippet_missing_kw_strict=0` | PASS |
| D8c | matches uniform, > rows returned | `n_rows=40, distinct_matches=1, matches_val=7099` | PASS |
| D8d | ts non-increasing | `violations=0` | PASS |
| D8e-h | strpos×1, coalesce 4-term, both replace(), LIMIT 40/20/none | all confirmed by direct read of file | PASS |
| D9 | 1 header/run; 0 "guard"; no header collision | header-uniqueness PASS; literal "guard" substring FAILS (see adjudication) | PARTIAL — same as RESULT-1's own honest report |
| D10 | control diff empty; only 3 files changed; status clean-except-artifacts | empty; 3 files, 127 ins/5 del; only `?? RESULT-1.md` | PASS |
| D11 | commit exists; status has no `M` lines | `7a82a9e`; only `?? RESULT-1.md` | PASS |
| D12 | 6 files live; hashes match; live round-trip works | 6 names; 6/6 `match=True`; `1,1,1870,1870,1870,534,true` | PASS |
| D13 | 0 ellipsis, 0 DSK_MODE, correct frontmatter, all doc patterns present | 0 matches both; frontmatter confirmed; all 6 patterns found | PASS |
| D14 | exact header; ts/role/title equal; 4-term coalesce; LEFT JOIN | header exact; values equal; both confirmed | PASS |

## D9 adjudication (priority item 1)

Checked directly: searched for the literal substring `guard` in the actual capture files for
all five `.sql` files, run exactly as D9 specifies (message.sql against D1's id, `3ef45859`).

- `sqlresults.sql`, `sqlresults-summary.sql`, `coverage.sql` captures: **zero** occurrences of
  `guard`.
- `search.sql` and `message.sql` captures: occurrences found, and in both cases the match is
  inside a **data field** (the `snippet`/`txt` column of a genuine retrieved message), not a
  header, not a stray CTE alias, not a leaked column name. The actual matched text:
  `"**C7–C11 (controls)** and **C10** (empty-keyword guard) all pass, including verifying `ok`
  s..."` (search.sql) and `"...(empty-keyword guard) all pass, including verifying `ok` survives
  every new intermediate CTE."` (message.sql) — this is conversation content from an earlier
  session discussing this skill's own `kw_guard`/`msg_guard` machinery, not the SQL leaking
  anything.
- No file's header (`id,session_id,ts,role,title,snippet,chars,matches` /
  `id,session_id,ts,role,title,chars,txt` / `session_id,tool_name,result_text,matches` /
  `total,with_rows_returned` / `distinct_files`) contains "guard" and none collides with
  another file's header.

**Verdict: the code is correct; the check wording is at fault.** "ZERO occurrences of 'guard'"
was written to catch a stray leaked result block or CTE alias, and it does that correctly for
three of the five files. For the other two, it is not robust against a self-referential corpus —
this skill's own conversation history discusses building the guard it uses, so any message
retrieved from that history that talks about the guard will trip a literal substring check
regardless of SQL correctness. RESULT-1.md's own report of this is accurate and not an attempt
to read past a real failure — it names the exact caveat, quotes the literal FAIL, and explains
why. I agree with that assessment.

## The id space (priority item 2)

**Structural:** the block-filter lines are character-identical between the two files:
```
search.sql:96:  AND w.block_type = 'text'
search.sql:98:  AND w.txt NOT ILIKE '%<system-reminder>%'
message.sql:82:  AND w.block_type = 'text'
message.sql:83:  AND w.txt NOT ILIKE '%<system-reminder>%'
```

**Behavioural:** ran 5 different `DSK_KEYWORD` searches (`the`, `guard`, `session`, `error`,
`commit`), collected every returned `(id, session_id)` pair, de-duplicated to **156 distinct
pairs**, and fed every one to `message.sql`, comparing the `chars` `message.sql` returned to the
`chars` the originating search row reported:

```
pairs_tested,pairs_unresolved,pairs_mismatched
156,0,0
```

Zero unresolved, zero mismatched, across a materially wider net than RESULT-1's own single-
keyword (`the`, 40 pairs) test. No disagreement found; I did not find a way to construct one —
the two files' `texted` CTEs are built from identical upstream CTEs (`hist`, `side`, `blocks`)
with identical filter predicates, differing only in how the empty-input guard is wired in
(irrelevant to which rows pass once a valid input is supplied) and in the columns each keeps
downstream.

## Truncation (priority item 3)

- D2 exact case re-verified independently: `chars=40396`, `length(txt)=40396`, `newline_count=427`,
  tail `"...ommitted_Costs_Granular`, and it has no master column at all — which is the root
  reason L284 exists."` — matches RESULT-1.md exactly.
- Independently found the current longest clean text block by direct query (same filters as
  message.sql/search.sql), not trusting D2's cited id:
  ```
  id,session_id,chars
  c443c766,3b5ff798-b435-4c1c-8159-254ecaddde27,40396
  c225bb0c,...,40071
  31763fe9,...,38604
  ...
  ```
  `c443c766` is still the longest — the id had not aged out, confirming D2's own claim.

## The guard (priority item 4)

- `DSK_MSG=''` → `exit=1`, `Invalid Input Error: DSK_MSG is required` — the guard genuinely
  fires, not merely present in source text.
- Read the file directly: `ok` originates in `msg_guard`, is selected into `hist` (joined via
  `, msg_guard` alongside the `read_ndjson` read), carried into `blocks` (`b.ok`), into `texted`
  (`b.ok`), and read in the final `WHERE w.ok = 1` — threaded through every intermediate CTE, not
  present-but-unreferenced. Confirmed both structurally (read of message.sql) and behaviourally
  (the guard actually raised the error above; DuckDB would have silently ignored an
  unreferenced CTE).
- Junk `DSK_KEYWORD='junkvalue'`, `DSK_CWD='C:\nonexistent\junk'` alongside a valid `DSK_MSG`:
  `exit=0`, correct row returned (`c443c766,40396`) — both ignored as required.

## Case folding & multi-session (priority item 5)

- D5b: `DSK_MSG='C443C766'` → `c443c766,...,40396` — same row as D2, case-insensitive match
  confirmed.
- D5c: `DSK_MSG='8bbc2d2f'`, `DSK_SESSION=''` → `count(*)=5, count(DISTINCT session_id)=4,
  count(DISTINCT txt)=1` — all 5 rows present, not DISTINCTed away, identical text across 4
  differing sessions.

## search.sql regression (priority item 6, D8/D3)

All of D8a-h re-run and confirmed (table above). D8b specifically used `position()` rather than
`LIKE`, per the task's own warning about `_` being a wildcard: `snippet_missing_kw_strict=0`
across 12 hits (RESULT-1 reported 11 — expected drift, the corpus has grown by one hit since).
D3's structural claim (exactly two `md5(w.txt)` occurrences, one in SELECT as `id`, one in
`ORDER BY`, ordering line unchanged from `8634580`) confirmed by direct read of `search.sql` and
by `git diff --stat 8634580` showing `search.sql | 1 +` only.

## D12 — live plugin (priority item 7)

- Exactly six files at the live path, names matching the required set.
- SHA256 hash comparison for all six repo/live pairs: all `match=True`.
- D1's round trip re-run entirely against the live path (`C:\Users\woodsonp\.snowflake\cortex\
  plugins\duckdb-skills\skills\read-memories\`): `1,1,1870,1870,1870,534,true` — identical to
  the repo-path result.

## Workflow assessment (beyond the checks)

Picked a genuinely truncatable hit from the `guard` search (a row with `chars` well above the
500-char snippet window), retrieved it in full using only what `SKILL.md` documents (`--full
<id>` → set `DSK_MSG`/`DSK_SESSION`, run `message.sql`). The retrieval matched the search's
`chars` exactly and returned the untruncated text with the snippet's stripped content locatable
inside it (confirmed via the `position()` check pattern from D1, reused for a second id).

**The workflow closes the gap as designed.** A reader can go from "chars: 1870 beside a
500-character snippet" to the complete text using nothing but the two env vars SKILL.md
documents, with no paging, no format validation surprises, and correct behavior on the edge
cases (unknown id, uppercase id, multi-session id).

One minor thing worth naming, not a defect: SKILL.md tells the agent to set `DSK_SESSION` to
the row's `session_id` "to scope to one occurrence, or leave it '' to return every occurrence."
If an agent doesn't carry the `session_id` forward from the search step and an id happens to be
one of the ~19 that spans multiple sessions, the agent gets back several identical-text rows
instead of one — correct per requirement 4, but only obviously correct if the agent already
knows that multi-session ids exist. SKILL.md does state this, so it's documented, not hidden;
it's just easy to skip past on a first read.

## Discrepancies against RESULT-1.md

None found beyond expected corpus-growth drift on floor counts (D8b: 12 vs 11; D8c matches: 7099
vs 7077; coverage distinct_files: 418 vs 417) — all in the direction the task's own rules say to
expect ("above a stated number is drift"). No check that RESULT-1.md claimed PASS failed for me,
and D9's caveat is reproduced identically to RESULT-1's own honest report of it.

## Tree integrity

`git status --short` before and after this verification shows only `?? RESULT-1.md` (present
before I started, since I only read it). No tracked file was modified; all captures were written
to `$env:TEMP` per the capture-method instructions.
