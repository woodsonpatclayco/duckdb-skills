# REVIEW-task-1 — `task-reviewer` on TASK.md (port read-memories to Cortex Code)

Verdict: **NOT READY** at time of review. 5 blockers, 6 would-cause-a-round, 3 nits.
All 14 findings applied to `TASK.md` in commit `b6edd21`.

The reviewer ran several of the spec's own checks read-only. Two of them failed on an
untouched repo.

| # | Sev | Finding | Fix applied |
|---|---|---|---|
| 1 | blocker | A7 cmd 1 not empty today — `TASK.md` + `.cortex-plugin/plugin.json` differ from `upstream/main` | Added `:(exclude)` for both, plus `RESULT-1.md`; stated why |
| 2 | blocker | A7 cmd 2 expects `?? .cortex-plugin/` but that file is **tracked** — unsatisfiable without `git rm`, which a non-requirement forbids | Expected output now exactly one line, `?? RESULT-1.md`, with a do-not-`git rm` warning |
| 3 | blocker | Finding 7's field list holds for 37/393 sessions. Measured: 39 sidecars have `created_at`, **389 do not** — sub-level sidecars use `creationDate` (epoch ms). So finding 8's coalesce yields NULL for ~90% of sessions, making "never blank" unsatisfiable and A3 a guaranteed fail | Finding 7 rewritten as two sidecar shapes with an explicit `columns=`; coalesce now ends `created_at::TIMESTAMP, epoch_ms(creationDate)` |
| 4 | blocker | Requirement 7 (`--here`) had no channel into `search.sql` — DuckDB has no cwd function and `$PWD` is not an env var, so A11 was unrunnable | Third env var `DSK_CWD`; empty string = no filter; invocation block updated. (`getenv()` itself verified working on v1.5.5) |
| 5 | blocker | A11's `=` fails on drive-letter case: sidecar stores `c:\Users\...`, `$PWD.Path` renders `C:` → zero rows, which reads as a clean pass | Mandated case-insensitive, separator-normalised compare; named the expected session; **zero sessions is now explicitly a FAIL** |
| 6 | round | Never stated whether `tool_use`/`tool_result` are searched. Measured for `Project Miner`: 186 tool_result, 112 tool_use, 22 text, 6 thinking — including them floods output and re-admits quoted system-reminders | Requirement 4 now restricts search mode to `type = 'text'` only |
| 7 | round | `DSK_MODE`'s recovery value never named — verifier could not re-run A5 | Mode table added: `search` / `sqlresults` / `coverage`; unknown value exits non-zero |
| 8 | round | A5's "show ONE recovered result set" had no command and no pass rule | Split into A5a (counts) and A5b (rendered set with header + `N row(s) returned`) |
| 9 | round | A1 had no command, and no mode returned a file count — would force an ad-hoc query, which A1 itself forbids | `coverage` mode added; A1 now a literal invocation. Floors refreshed to >= 394 / > 357 |
| 10 | round | A9 was near-vacuous: `thinking` prose lives at `$.thinking`, so matching `$.text` excludes it by accident — the check passed without requirement 5 | A9 now asserts the explicit `$.type` filter exists in `search.sql` |
| 11 | round | A3's keyword `read_xlsx` has only 3 text blocks, 2 clean — no margin; any reasonable extra filter takes it to 0 | Margin stated; search mode forbidden from filtering by `role`, deduping, or requiring a raw timestamp |
| 12 | nit | Sidecar glob yields ~428 `.json` vs ~394 history files; "393/393" and the `.jsonl` exclusion were both wrong | Documented; unmatched sidecars drop, no 1:1 assertion |
| 13 | nit | Requirements 2, 3, 10 had no acceptance coverage | New check A12 (grep SKILL.md for invocation, user-facing form, do-not-narrate) |
| 14 | nit | "say which lines in `RESULT-1.md` and stop" — ambiguous whether to abandon the task | Clarified: name the lines, change nothing in `README.md`, continue |

Checks the reviewer executed: A7 (both — both failed), A2 (would pass: 15 clean of 22
text hits), A3 (would pass: 2 rows), A11 (1 session, case mismatch), A1 counts (394),
`getenv()` on v1.5.5. Not run — they need the artifact: A4, A5, A6, A8, A9, A10.

No plan exists; `TASK.md` line 3 declares that with a reason, which is correct per
convention. No drift finding.
