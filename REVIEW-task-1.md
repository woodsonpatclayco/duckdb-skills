# REVIEW-task-1 — `task-reviewer` on TASK.md (remove read-memories output noise)

Verdict at review time: **NOT READY** — 2 blockers, 6 would-cause-a-round, 3 nits.
All findings applied to `TASK.md`.

The reviewer verified the two claims the whole spec rests on, both by running them:

- **Gated aggregates really do emit a false row.** `SELECT count(*) ... WHERE
  getenv('DSK_MODE') = 'other'` → `0,NULL`, exit 0. The diagnosis in the spec is correct,
  including the aggregate-vs-non-aggregate distinction.
- **A nonexistent `-f` file exits non-zero.** `IO Error: Failed to open file`, exit 1. So
  requirement 6 as originally written was not a design problem — but it was not a
  requirement either, since nothing an implementer writes affects it.

| # | Sev | Finding | Fix applied |
|---|---|---|---|
| F1 | blocker | R1 ("exactly one statement") collided with R5 ("use `error()`") — the obvious guard is a second statement, which fails B1 on the very file being cleaned. Implementer forced to break one requirement to satisfy the other | R1 now says one **semicolon**, and a `WITH` clause carrying the guard is explicitly part of that single statement. Reviewer-verified CTE guard shape quoted in the spec |
| F2 | blocker | R4 delegated how to split `sqlresults`' two behaviours, but the fix section said three files, R3 said "the mode is the filename", and B1 said "for each of the three modes" — taking the option the spec called simpler broke three checks | Four files mandated: `search.sql`, `sqlresults.sql`, `sqlresults-summary.sql`, `coverage.sql`. The one-file option is the aggregate trap being removed, so it is now rejected, not delegated |
| F3 | round | B13 `git status` expected exactly `?? RESULT-1.md`. Measured: `?? TASK.md` is untracked **today**, and the round adds two more artifacts — three `??` lines, so it fails on correct work. Same defect as last round's A7, corrected in the sibling command only | Now an artifact-set assertion: every line must be one of the three known artifacts; any other path or any M/A/D line is a FAIL |
| F4 | round | B10 (now B11) was not executable — no extraction procedure for the answer block, `<pre-change-sha>` undefined, and "identical rows" contradicts the spec's own floors clause on a corpus the implementer's session is appending to | Full PowerShell recipe with `Compare-Object`, SHA named (`2e23118`), expectation changed to old-is-a-subset-of-new with drift quoted |
| F5 | round | R9's stale-file deletion was conditioned on "if the split renames anything" — nothing is renamed, so it was a no-op and B12's orphan clause was unfalsifiable. Live/repo hashes also **already match today**, so the hash check passed untouched | Deletion is unconditional; B12 now enumerates the exact five filenames and requires per-file hash pairs pasted |
| F6 | round | R9 (deploy) vs R10 (commit) had no stated order; deploy-then-edit fails B12 on correct work. Also unsaid that copying into the live clone leaves it dirty, inviting an implementer to "tidy" it — which is forbidden | New requirement 7 fixes the order explicitly; requirement 8 states the live clone will show dirty and must be left so |
| F7 | nit | Old R6 (nonexistent mode file fails) was a verification, not a requirement — it passes before any work and invited inventing a sentinel file | Moved into B8, labelled **CONTROL** with the measured output inline; a non-requirement now forbids making it pass |
| F8 | round | `sqlresults` with an empty keyword has the identical bug R5 fixed for search — `ILIKE '%%'` returns 20 arbitrary rows. R5 was scoped to search only, so a faithful implementer would leave it open | Requirement 4 now covers both keyword-filtered files, and states the other two must ignore `DSK_KEYWORD`. B7 tests all four |
| F9 | round | Missing coverage: R1 (statement count), the `<system-reminder>` exclusion, the `$.type` filter, `columns = {}` on every read, and R10 (commit ordering) | Added: semicolon count in B1, new **B10** for `<system-reminder>` (called out as the highest-risk regression — it *was* the original bug), read/columns count parity and `$.type` greps in B9, new B14 for the commit |
| F10 | nit | B3's "361" sub-level count was stale on arrival with no way to re-measure | Command supplied; measured fresh at **363**; comparison is now computed, not compared to a literal |
| F11 | nit | Two "preserve unchanged" items were breakable while believed preserved: `--here` named the property not the mechanism (dropping `replace()` still passes, because `$PWD.Path` already uses backslashes), and "`type = 'text'` only in search mode" read as a permission rather than an obligation | The `--here` expression is now quoted verbatim with the trap explained, and B6 greps for both `replace()` calls; the type clause is split per file |

Reviewer also confirmed the fix is sound and that **none of the three rejected
alternatives was rejected on faulty reasoning**. One unconsidered alternative was added to
the rejected list so it does not resurface: `-c` dispatch or a `.read` include, both of
which reintroduce hazards already documented in `SKILL.md`.

Checks the reviewer ran: the two load-bearing claims, B8 (exit 1), B13 cmd1 (empty today),
B13 cmd2 (**`?? TASK.md`** — the failure), B12 hashes (already identical), plus the guard
CTE shape. Four checks were found to already pass on the untouched repo and are now
labelled CONTROL.

No plan exists; line 3 declares that with a reason, which is correct per convention.
