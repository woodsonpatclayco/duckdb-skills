# REVIEW-task-1 — `task-reviewer` on TASK.md (search output honesty bundle)

Verdict at review time: **NOT READY** — 3 blockers, 4 would-cause-a-round, 7 nits, 1
confirmation. All findings applied to `TASK.md`.

The reviewer re-verified the load-bearing expressions **in place** rather than in isolation,
because the previous task lost a round to exactly that mistake.

## The finding that would have shipped wrong

**The `WHERE` matched with `ILIKE`; the window position came from `strpos`.** In a `LIKE`
pattern `_` matches any single character, so a keyword containing an underscore matches text
that does not contain the keyword — and `strpos` then returns 0, so the window silently
reverts to the first 500 characters, exactly the defect being fixed.

Measured live on keyword `sql_execute`: **1 of 5 returned rows had a snippet not containing
the keyword.** Proof in isolation:

```
('sessionXid ' || repeat('z',600)) ILIKE '%session_id%'   →  true
strpos(lower(...), 'session_id')                          →  0
```

Worse, my check C1 used only `dangling blob` — a wildcard-free keyword that passes. So the
spec would have **certified the defect as fixed**. The fix: `strpos` is now the predicate as
well as the position, so match and window are the same computation by construction. This
removes accidental wildcard matching, which is a correctness improvement in its own right and
is now stated as a deliberate behaviour change.

| # | Sev | Finding | Fix applied |
|---|---|---|---|
| 1 | blocker | `ILIKE` vs `strpos` mismatch, above. C1 certified it as fixed | New requirement 1 makes `strpos > 0` the predicate in both keyword files. C1 split into C1a (`dangling blob`) and **C1b (`sql_execute`)** with a mechanical `snippet_missing_kw = 0` assertion. New defect section 1 documents the wildcard problem |
| 2 | blocker | C6's drift clause contradicted its own mechanism: under `ts DESC` with a fixed `LIMIT`, a new row at the top **necessarily** pushes one off the tail — which C6 called a FAIL. Every legitimate drift event would have been reported as failure | C6 now requires N-in-at-top **and** N-off-tail **and** no middle reordering, together, as acceptable drift |
| 3 | blocker | C6's before/after evidence was unrunnable: PowerShell 5.1's `>` writes UTF-16LE with a BOM, and DuckDB fails with `Parser Error: syntax error at or near " ■"`. Reviewer hit this | The literal `git show ... \| Set-Content -Encoding ASCII` pipeline is now in the check. Confirmed the old file then runs standalone at `4cb9814` (no `DSK_MODE`) |
| 4 | round | C6 said "capture to files" with no location; C13 fails on any untracked file in the repo. The task broke its own check | Captures go to `$env:TEMP\dsk-c6-*.txt`; added a non-requirement forbidding repo writes, and C13 now names a stray capture as the thing to look for |
| 5 | round | The new `matches` column appears on every row, so one new corpus match changes all 40 lines — not "a row entering at the top", so C6's byte-identity test could fail on correct work | C6 compares with `matches` projected out; a uniform change to it with row identity and order unchanged is explicitly drift |
| 6 | round | Requirement 7's "tiebreak chain that cannot tie" is factually false — measured 3 groups of 2 rows tying on `(session_id, md5(result_text))`. A verifier could demonstrate ties and flag the requirement unmet | Reworded to the property that actually matters: byte-stable output, with tied rows identical in every selected column. The measured tie count is quoted |
| 7 | round | Requirement 3 (extract text once) — the change the spec itself calls highest-risk — had **no acceptance check at all**. Every other requirement had one | C9 now greps for `json_extract_string(b.c,'$.text')` at most once and `strpos` exactly once (two `strpos` calls would mean predicate and window can disagree — defect 1 again) |
| 8 | confirmed | Requirements 3 and 10 **are** satisfiable together — reviewer built the full four-CTE chain and got `Invalid Input Error: DSK_KEYWORD is required`, exit 1. But the spec said only *that* `ok` must stay threaded, not how far | Requirement 10 now says `ok` must be carried through **every** intermediate CTE and read in the outermost `WHERE`. Also notes `strpos(txt,'') = 1`, so the guard is the only thing preventing silent degradation to prefix behaviour |
| 9 | nit | C2's escape hatch ("if no keyword produces an undecorated row, say so") invited a weaker answer than available — `the` yields 38 undecorated rows, min `chars` 45 | Hatch removed; `the` named with the measured figures |
| 10 | nit | C4's under-the-cap half named no keyword, so an implementer could pick one with zero matches and pass vacuously | `dangling blob` named (6 rows, matches 6), with ">= 1 row required, zero proves nothing" |
| 11 | nit | C5's "non-increasing down the output" is not mechanically checkable — snippets contain embedded newlines, so line order is not row order | C5 now requires stating the extraction method and asserting first ts = max |
| 12 | nit | Five checks pass on the untouched repo but only one was labelled CONTROL. Reviewer ran C7, C13a, C13c and C12's listing half at `4cb9814`: all pass | C7, C8, C10, C11, C12-listing and C13a/C13c now labelled CONTROL; C12's hash half and C13b marked as genuinely new |
| 13 | nit | C3 grepped captured output for a Unicode ellipsis — but a cp1252 capture mangles the character before the grep runs, so it passes spuriously | C3 now greps the **source** `.sql` and `SKILL.md`, which is authoritative |
| 14 | nit | C9 checked one term of the four-term `ts` coalesce | Now greps `coalesce` and requires the pasted line to show all four terms |
| 15 | nit | Requirement 6's reversal of the previous task's non-requirement was clear, but a verifier reading the archive first might still flag it | C5 now says the reversal is intended and that the prior `SHIPPED.md` is superseded |

Also verified sound and unchanged: `count(*) OVER ()` is pre-`LIMIT` **in the real four-CTE
shape** (40 rows, `matches = 6965`, uniform); `strpos`/`substr` agree on non-ASCII;
multiple keyword occurrences, a match at position 1, and text shorter than the window all
behave as claimed; two `unnest` calls on the same list zip rather than cross-product, so the
naive form of requirement 3 does not fan out. `4cb9814` confirmed as the correct before-SHA.

One number was removed rather than corrected: the spec quoted "126 vs 117 lines" for the old
file's instability, and the reviewer measured 89. Line count *is* the unstable quantity, so
the spec now asks for instability without a figure to reproduce.

No plan exists; line 3 declares that with a reason, per convention.
