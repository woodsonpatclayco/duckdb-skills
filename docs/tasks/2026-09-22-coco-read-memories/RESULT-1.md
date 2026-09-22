# RESULT-1 — port `read-memories` to Cortex Code session logs

Commit: `c91cc89e78b00147c2a75fc981c4cce3144f85d6` on branch `coco-read-memories`.

Files changed:
- `skills/read-memories/SKILL.md` — rewritten. Frontmatter trimmed to `name`/`description`
  (Cortex Code named in the description); body documents the user invocation, the agent's
  literal `duckdb -csv -f` invocation with the three env vars, the three `DSK_MODE` values,
  and the do-not-narrate contract.
- `skills/read-memories/search.sql` — new. Three env-var-driven modes (`search`,
  `sqlresults`, `coverage`), reads `content` as `JSON` throughout (never a struct), globs
  both `*.history.jsonl` and `*\*.history.jsonl`, joins the two sidecar shapes explicitly,
  and derives `ts` via the finding-8 coalesce.

All commands below were run from `C:\Users\woodsonp\Claude\Dev\duckdb-skills` unless a check
says otherwise. DuckDB CLI v1.5.5.

---

## A1 — corpus fully covered

```powershell
$env:DSK_MODE = 'coverage'; $env:DSK_KEYWORD = ''; $env:DSK_CWD = ''
duckdb -csv -f "C:\Users\woodsonp\Claude\Dev\duckdb-skills\skills\read-memories\search.sql"
```

Actual output:
```
guard
distinct_files
396
total,with_rows_returned
0,NULL
session_id,tool_name,result_text
session_id,ts,role,title,snippet
```

`distinct_files = 396`. Measured sub-level-only count on this machine at check time:
`Get-ChildItem <conversations> -Directory | Get-ChildItem -File -Filter '*.history.jsonl'`
→ **358**. 396 >= 394 and 396 > 358.

**RAN — PASS.** (Note: the `guard` line and the empty `sqlresults`/`search` headers below the
real result are a side effect of running all three mode-branches as separate statements in
one script, guarded by `WHERE getenv('DSK_MODE') = '...'` — see "Concerns" below.)

## A2 — keyword search returns conversation, not injected context

Keyword `Project Miner`, mode `search`:

Actual output: 15 hit rows (full session ids/snippets in the shell transcript above this
report was drafted from; omitted here for length — none is a `<system-reminder>` line).
Verified explicitly:

```powershell
Select-String -Path <captured-output> -Pattern '<system-reminder>' | Measure-Object
```
→ `Count : 0`

**RAN — PASS.** >= 1 hit (15), zero hits contain `<system-reminder>`.

## A3 — known-present keyword found, rendered readably

Keyword `read_xlsx`, mode `search`:

Actual output:
```
guard
distinct_files
0
total,with_rows_returned
0,NULL
session_id,tool_name,result_text
session_id,ts,role,title,snippet
6487c5f7-0e12-433c-a6dd-799c169bbf80,2026-09-21 20:38:45.363,assistant,Session Data Storage and Query Caching,"Installed and working. The Windows caveat turned out to be smaller than advertised.
**Verified against a real file:** `C:\Users\woodsonp\Clayco Staging\2026-08-27\Project Miner - Executive Cost Report Summary.xlsx` — spaces in the path, read correctly, headers and all. Path handling, the thing the README warns about, is fine for the core read path.
**What's installed:** `~\.snowflake\cortex\plugins\duckdb-skills\` — 9 skills, registered and synced. No transformation needed beyond adding the Co"
6487c5f7-0e12-433c-a6dd-799c169bbf80,2026-09-21 20:38:45.363,assistant,Session Data Storage and Query Caching,"Both assumptions need adjusting.
**`attach-db` — no, it does not persist your data.** It only registers an *already-existing* `.duckdb` file so later queries can find it. It writes `ATTACH 'clayco.duckdb' AS clayco;` into a `state.sql`. If the file doesn't exist yet, you get an empty database.
The persistence is a separate step you do first — `CREATE TABLE ... AS SELECT`. So it's two moves:
```
1. materialize:  CREATE TABLE cost_summary AS SELECT * FROM read_xlsx('<path>', all_varchar=true)
2"
```

2 rows. `role` = `assistant` on both, `ts` = `2026-09-21 20:38:45.363` on both (non-empty).
Snippets are readable prose, not `{'type': 'text', ...}` dumps.

**RAN — PASS.** Matches the margin warning exactly (2 clean of 3 total).

## A4 — known-absent keyword, control

Keyword `zzqqxx-not-a-real-token`, mode `search`:

Actual output:
```
guard
distinct_files
0
total,with_rows_returned
0,NULL
session_id,tool_name,result_text
session_id,ts,role,title,snippet
```
(zero data rows under the `search` header) — `EXITCODE_IS_0` confirmed via `$LASTEXITCODE`
written to a file immediately after the run.

**RAN — PASS.** 0 rows, exit 0, no binder error, no stack trace.

## A5 — SQL result recovery covers both tool names

**A5a — coverage of both tool names**, mode `sqlresults`, `DSK_KEYWORD=''`:

```
guard
distinct_files
0
total,with_rows_returned
1179,1033
session_id,tool_name,result_text
session_id,ts,role,title,snippet
```

`total = 1179 >= 1175`, `with_rows_returned = 1033 >= 1029`. Breakdown confirmed separately
during development: `snowflake_sql_execute` 1123/983, `sql_execute` 56/50 — both names
matched, not just the legacy one (which would have floored at 56/50).

**RAN — PASS.**

**A5b — one result set actually rendered**, mode `sqlresults`, `DSK_KEYWORD='13262'` (a
project id known present in a previously-recovered result):

Actual output (first recovered block, full text preserved):
```
session_id,tool_name,result_text
1484f3d0-13b5-4cd4-b064-c1d743bd2858,sql_execute,"24 row(s) returned.

PROJECT_ID,TYPE,STATUS,N,AMT

13262,Field PO,Approved,11,78508.82000
13262,Field PO,Returned,10,0.00000
13262,Field Subcontract,Approved,1,4138.96000
13262,Field Subcontract,Draft,1,0.00000
13262,Purchase Order,Approved,12,30534491.00000
13262,Purchase Order,Draft,2,-21127069.20000
13262,Services Agreement over 100k,Approved,10,8031005.00000
13262,Specialty Contract,Approved,15,914441.58000
13262,Specialty Contract,Draft,2,-111023.08000
13262,Subcontract,Approved,107,935584405.03000
13262,Subcontract,Draft,8,-525295218.12000
13262,Survey,Approved,9,146825.06000
13262,Testing Laboratory/Inspecting Consultant AGC 630,Approved,2,50000.00000
13285,Purchase Order,Approved,3,24765698.83000
13285,Purchase Order,Draft,1,-17816426.83000
13285,Subcontract,Approved,9,84613668.43000
13285,Subcontract,Draft,3,-44837706.91000
13286,Purchase Order,Approved,3,23886912.00000
13286,Purchase Order,Draft,1,-13925450.00000
13296,Purchase Order,Approved,11,79604643.29000
13296,Purchase Order,Draft,5,-46231575.11000
13296,Specialty Contract,Approved,1,35000.00000
13296,Subcontract,Approved,50,322217026.00000
13296,Subcontract,Draft,3,-46796049.26000"
```
20 result sets were recovered in total for this keyword. This first one contains a
comma-delimited header (`PROJECT_ID,TYPE,STATUS,N,AMT`), data rows, and the line
`24 row(s) returned.` — all three required elements present in one block.

**RAN — PASS.**

## A6 — no struct-key or missing-column failures anywhere

Grepped every captured output file from A2–A5b for the two failure strings:

```powershell
Select-String -Path <A2>,<A3>,<A4>,<A5a>,<A5b> -Pattern "Could not find key","Referenced column" -SimpleMatch
```
Output: no matches (empty).

**RAN — PASS**, for every check A1–A5 (A1's output is reproduced above and contains neither
string either).

## A7 — blast radius contained

Run **after** the commit (`c91cc89`), per requirement 11.

```powershell
git diff --stat upstream/main -- . ":(exclude)skills/read-memories" ":(exclude)TASK.md" ":(exclude)RESULT-1.md" ":(exclude).cortex-plugin"
```
Actual output:
```
 REVIEW-task-1.md | 31 +++++++++++++++++++++++++++++++
 1 file changed, 31 insertions(+)
```

**RAN — FAIL, but not caused by this task's change.** `REVIEW-task-1.md` is a Cortex-fork
artifact — same category as `TASK.md` and `.cortex-plugin/plugin.json` — added on this
branch by the reviewer step and committed at `425802b`, before this implementation started.
The spec's exclude list (requirement/A7 text) names `TASK.md`, `RESULT-1.md`, and
`.cortex-plugin` explicitly as deliberate exclusions but does not name `REVIEW-task-1.md`,
so the command as literally written is not empty. I did not add `REVIEW-task-1.md` to the
exclude list myself — that would be editing the acceptance check rather than reporting
against it. `git diff --stat` for **only** the paths this task actually touched confirms the
blast radius is contained to `skills/read-memories/`:

```powershell
git diff --stat upstream/main -- skills
```
```
 skills/read-memories/SKILL.md   | 60 +++++++++++++++++++++++--------------
 skills/read-memories/search.sql | 153 +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
 2 files changed, 213 insertions(+), 153 deletions(-)
```
No other skill under `skills/` is touched.

```powershell
git status --short
```
Actual output (before this file existed): empty. After writing this file it will show
exactly `?? RESULT-1.md` (verified — see next check).

**RAN — cmd 1 FAIL (pre-existing gap in the exclude list, unrelated to this change,
see above) / cmd 2 PASS.**

## A8 — no relative-path assumptions

Re-ran A1 with cwd = `C:\Users\woodsonp`:

```powershell
Push-Location C:\Users\woodsonp
$env:DSK_MODE = 'coverage'; $env:DSK_KEYWORD = ''; $env:DSK_CWD = ''
duckdb -csv -f "C:\Users\woodsonp\Claude\Dev\duckdb-skills\skills\read-memories\search.sql"
```
Actual output:
```
guard
distinct_files
396
total,with_rows_returned
0,NULL
session_id,tool_name,result_text
session_id,ts,role,title,snippet
```

`distinct_files = 396`, identical to the run from the repo directory (A1).

**RAN — PASS.**

## A9 — thinking blocks excluded (mechanism, not accident)

```powershell
Select-String -Pattern "\$\.type" skills\read-memories\search.sql
```
Actual output:
```
skills\read-memories\search.sql:60:    WHERE json_extract_string(c, '$.type') = 'tool_result'
skills\read-memories\search.sql:89:    WHERE json_extract_string(c, '$.type') = 'tool_result'
skills\read-memories\search.sql:146:  AND json_extract_string(b.c, '$.type') = 'text'
```

Explicit block-type filter present (`= 'text'` in the search branch at line 146; the two
`= 'tool_result'` filters are in `sqlresults` mode).

Keyword `Project Miner` (A2's run): all 15 returned rows come from the `search` branch, which
filters strictly to `$.type = 'text'`; no `thinking` block can appear in that result set by
construction, since `thinking` prose lives at `$.thinking`, not `$.text`, and the block-type
filter excludes anything not typed `text` before the text match is even evaluated.

**RAN — PASS.**

## A10 — frontmatter is Cortex-correct

```powershell
Get-Content skills\read-memories\SKILL.md -TotalCount 10
```
Actual output:
```
---
name: read-memories
description: >
  Search past Cortex Code session logs (~/.snowflake/cortex/conversations/) to recall prior
  decisions, patterns, or unresolved work. Use when the user says "do you remember", "what
  did we do", references past conversations, or you need context from prior Cortex Code
  sessions.
---

Search past session logs silently — do NOT narrate the process. Absorb the results into your
```

Frontmatter contains exactly `name` and `description`. No `argument-hint`, no
`allowed-tools`. Description names Cortex Code explicitly.

**RAN — PASS.**

## A11 — `--here` actually scopes

```powershell
cd C:\Users\woodsonp\Claude\Dev\duckdb-skills
$env:DSK_MODE = 'search'; $env:DSK_KEYWORD = ''; $env:DSK_CWD = $PWD.Path
duckdb -csv -f "C:\Users\woodsonp\Claude\Dev\duckdb-skills\skills\read-memories\search.sql"
```

Distinct session ids returned: `6b705409-e077-4c05-a7c1-1b1b476e9583` (title "DuckDB Skills
Fork for Cortex Code") and `c4f272f9-cf56-4b93-bda9-edf20a20775b` (title "Review
read-memories spec"). Both are present — `6b705409...` matches the spec's named target
exactly. The second is a `task-reviewer` subagent spawned from within the first session; its
own sidecar was checked directly and also carries
`"working_directory": "c:\\Users\\woodsonp\\Claude\\Dev\\duckdb-skills"` (verified with a raw
`Get-Content` of its `.json` sidecar, not inferred). So both hits are genuinely scoped to this
directory — zero sessions from elsewhere. Exit code confirmed `0`.

**RAN — PASS.** More than one session is expected drift per the spec's own note; zero would
have been the failure condition, and that did not occur.

## A12 — documented contract present in SKILL.md

```powershell
Select-String -Pattern "DSK_KEYWORD","DSK_CWD","duckdb -csv -f","/duckdb-skills:read-memories" skills\read-memories\SKILL.md
```
Actual output:
```
skills\read-memories\SKILL.md:16:/duckdb-skills:read-memories <keyword> [--here]
skills\read-memories\SKILL.md:24:The user never sets `DSK_KEYWORD`, `DSK_MODE`, or `DSK_CWD` directly — the agent sets them
skills\read-memories\SKILL.md:25:before running `search.sql`. Set `DSK_CWD` to the empty string when `--here` was not given;
skills\read-memories\SKILL.md:29:$env:DSK_KEYWORD = '<keyword>'; $env:DSK_MODE = 'search'; $env:DSK_CWD = $PWD.Path
skills\read-memories\SKILL.md:30:duckdb -csv -f "<abs path>\skills\read-memories\search.sql"
skills\read-memories\SKILL.md:33:Omit the last line of `$env:DSK_CWD = ...` (leave it `''`) when `--here` was not passed.
skills\read-memories\SKILL.md:47:| `sqlresults` | recovering a past Snowflake SQL result set by keyword, or a `total`/`with_rows_returned` coverage count when `DSK_KEYWORD` is `''` |
```

At least one match per pattern, confirmed. Do-not-narrate contract (requirement 10), lines
10–11 of `SKILL.md`:
```
Search past session logs silently — do NOT narrate the process. Absorb the results into your
answer and continue; never dump raw logs or CSV to the user.
```

**RAN — PASS.**

---

## Summary

| Check | Verdict |
|---|---|
| A1 | PASS |
| A2 | PASS |
| A3 | PASS |
| A4 | PASS |
| A5a | PASS |
| A5b | PASS |
| A6 | PASS |
| A7 | cmd1 FAIL (pre-existing, see below) / cmd2 PASS |
| A8 | PASS |
| A9 | PASS |
| A10 | PASS |
| A11 | PASS |
| A12 | PASS |

## Deviations

- **Mode dispatch has a minor cosmetic side effect.** `search.sql` implements the three
  `DSK_MODE` branches as separate top-level statements in one file, each gated by
  `WHERE getenv('DSK_MODE') = '<mode>'`, plus a leading guard statement that raises via
  `error()` for any other value (verified: `EXITCODE_IS_1` and the literal string
  `unknown DSK_MODE: <value>` printed to stderr when tested with a bogus mode during
  development). Because DuckDB always prints a statement's header even for a 0-row result,
  every invocation shows the `guard` header plus the two non-selected modes' empty headers
  ahead of the real result (visible in every "Actual output" block above). This does not
  affect any acceptance check's content — each check greps for or reads a specific value,
  which is always present and unambiguous — but it is not perfectly clean output. No
  alternative was found that both (a) keeps this in one `.sql` file invoked via `-f` with no
  wrapper script, and (b) achieves a hard non-zero exit with a literal error message on an
  invalid mode (both explicit requirements). This tradeoff was made in that direction because
  requirement 2's exit-code/message behavior is unambiguous in the spec, while output
  cleanliness is not separately checked.
- **Performance, not correctness:** because `getenv()` is evaluated at runtime, DuckDB cannot
  prove the two non-selected mode branches are unreachable, so each invocation still fully
  scans the log corpus for all three branches (coverage's file list, sqlresults' tool_result
  blocks, search's text blocks) even though only one mode's result matters. All acceptance
  checks completed in a few seconds regardless; this was not optimized away since nothing in
  the spec requires it and doing so would need either a wrapper script (ruled out) or
  DuckDB scripting features beyond plain SQL.

## Not done / could not satisfy as literally written

- **A7 cmd 1** cannot be made to pass as literally written without either (a) editing the
  acceptance check itself, which is not this task's to do, or (b) modifying
  `REVIEW-task-1.md`/deleting it, which would destroy a review artifact unrelated to
  `read-memories`. Reported as FAIL with full explanation above; the substantive question the
  check exists to answer — "did this task's change leak outside `skills/read-memories/`?" —
  is answered by the scoped `git diff --stat upstream/main -- skills` shown in that section,
  which is empty except for the two files this task was asked to change.

## README.md staleness (not modified, per the spec's non-requirements)

`README.md` documents `read-memories` and is now stale in two places:
- **Lines 70–75**: describes `read-memories` as searching "past Claude Code session logs"
  and offloading large results "to a temporary DuckDB file for interactive drill-down" —
  neither is true of this rewrite (it searches Cortex Code logs; there is no temp-file
  drill-down mechanism, per the non-requirement forbidding `state.sql` use).
- **Line 125**: lists `read-memories` among the skills that "use `duckdb-docs` to
  troubleshoot DuckDB errors automatically" — the rewritten skill makes no reference to
  `duckdb-docs`.

No change was made to `README.md`, per the spec's explicit instruction.
