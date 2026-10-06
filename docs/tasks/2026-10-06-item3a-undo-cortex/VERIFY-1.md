# VERIFY-1 — independent verification of item 3a (commit 6a5a521)

**Who and where.**
- **Verifier:** the `verifier` agent.
- **Worktree:** a throwaway one, `$W`, at `…\scratchpad\verify-item3a`, detached at `6a5a521`.
- **Base:** `$B` was a second throwaway worktree at `b54e9f7`, removed afterwards.
- **Scratch lake:** `%TEMP%\vl3a`.
- **Who wrote this file:** the verifier has no write tool, so the main session saved its
  report here.

**Tree gate:**
- `git -C $W status --short` was empty after the M1 revert and after `$B` was removed.
- `~\.duckdb-skills\` holds no new folders. The real project lake was not written. The
  verifier's only action in the main checkout was AC4's read-only log search.

**RESULT-1.md:** no discrepancy with it.

| Check | Actual (quoted) | Verdict |
|---|---|---|
| AC1 at `$W` | `2023-03-15`, `DATE`; `Catalog Error: Scalar Function with name iff does not exist!` (exit 1); function list `xl_date` | PASS |
| AC1 control at `$B` | IFF → `1`; list `CHARINDEX,DIV0,DIV0NULL,EQUAL_NULL,IFF,LEN,NULLIFZERO,NVL,NVL2,REGEXP_SUBSTR,TO_NUMBER,TO_VARCHAR,TRY_TO_DATE,TRY_TO_NUMBER,UUID_STRING,ZEROIFNULL,xl_date` | PASS |
| AC2 | `$W`: 0 lines, exit 1. `$B`: 140 lines, exit 0 | PASS |
| AC3 | Baseline `$B`: `All_Sales_Data REFRESHED 484 reason=no_manifest`, `Clayco_Job_Costs_from_GL REFRESHED 57777 reason=no_manifest`, both `CHECKS_PASSED,true`. After `$W`: both `REFRESHED`, `reason=compat_sha256` only, checks true, `SUMMARY,contracts=2,refreshed=2,skipped=0,refused=0,forced=0,errored=0`. `EXCEPT ALL` both directions: 0/0 (sales, 484 rows), 0/0 (GL, 57,777 rows) | PASS |
| AC4 | `--here` path `C:/Users/woodsonp/.claude/projects/C--Users-woodsonp-Claude-Dev-duckdb-skills/*.jsonl`: 40 rows (LIMIT), all `C--Users-woodsonp-Claude-Dev-duckdb-skills`. No `--here`: 40 rows, 39 + 1 from `C--Users-woodsonp`; unlimited counts 68 and 1. Description contains `shared memory` and `Claude Code` | PASS |
| AC5 | `$B`: `SUMMARY,entrypoints=14,pass=13,fail=1`. `$W`: `SUMMARY,entrypoints=12,pass=11,fail=1`. Missing at `$W`: exactly `run-compat-tests`, `read-memories:search`. Shared labels have identical verdicts; `gl-facts` FAIL at both (known, out of scope) | PASS |
| M1 — IFF macro re-added | `IFF(true,1,2)` → `1`, list `IFF,xl_date`, so AC1 fails; after revert, `iff does not exist` again | PASS (fails, then passes) |

**Scope:** `git diff b54e9f7 6a5a521 --stat` shows 16 files, all named in the spec plus
RESULT-1.md. None of these changed:
- `contracts\`;
- `checks\gl-facts.sql`;
- `.claude-plugin\` and `.cortex-plugin\`;
- README lines 5–10;
- any tool other than `prove-no-snowflake` (edited as specified) and `run-compat-tests`
  (deleted).

**Read as a user:**
- **`read-memories`:** it matches decision 5. It says Claude Code transcripts, shared memory
  first, and that it cannot see Cortex Code. It uses Windows-form paths, the `--here` mapping
  is correct, and the project column is non-empty.
- **`query`:** it matches decision 2, with the dialect section gone and an "Excel serial
  dates" pointer added.
- **`duckdb-compat.md`:** 24 lines.

**Concerns, none blocking:**
- **README lines 5–10:** they still describe Cortex log search. Item 4 rewrites them.
- **AC4 counts:** `LIMIT 40` caps the with-versus-without-`--here` comparison. The unlimited
  counts are the stronger evidence.

**Overall verdict: SHIP.**
