# SHIPPED — the truncated part of a message is now reachable

Date: 2026-09-22 · Branch: `coco-read-memories-fulltext` · Implementation commit: `7a82a9e`
Verified at `7a82a9e` in a disposable worktree. Verdict: **SHIP** — 13 of 14 checks PASS,
D9 adjudicated as a defect in my check's wording, not in the code.

Fourth and final task on this skill. Predecessors: `2026-09-22-coco-read-memories` (built it),
`2026-09-22-read-memories-output-noise` (one result block per run),
`2026-09-22-read-memories-honest-output` (match-centred snippets, `chars`, `matches`,
newest-first, deterministic).

## The point of it

**Before:** search reported `chars: 4200` beside a 500-character snippet. You could see that
text was hidden and how much — but nothing in the skill could show it to you. `chars` meant
*"there is text you cannot reach."*

**After:** every hit carries an 8-character `id`, and `message.sql` returns that message
whole. Verified end to end: a truncated 1,870-character hit retrieved complete, with the
snippet found at position 534 inside the full text.

## What shipped

| File | Change |
|---|---|
| `search.sql` | `id` = `left(md5(w.txt), 8)` added as the **first** column |
| `message.sql` | **New.** Returns `id, session_id, ts, role, title, chars, txt` — complete untruncated text |
| `SKILL.md` | The `id` column, `message.sql`, the `DSK_MSG` / `DSK_SESSION` contract, `--full <id>` |

`DSK_MSG` is required and errors with exit 1 if empty. `DSK_SESSION` is optional. Matching is
`lower(trim(...))`, so an uppercase paste still resolves. No `LIMIT`, no paging, no
truncation.

## The retrieval key, and why it is what it is

`(session_id, ts)` — the obvious choice — is **not a key**: it collapses to **451 distinct
values across 8,506 blocks**, because roughly half of all rows carry no timestamp and the
display `ts` then comes from a session-level sidecar field shared by every row in that
session.

`left(md5(txt), 8)` has **zero collisions across 8,472 distinct texts**, and it was already
being computed as `search.sql`'s ordering tiebreak, so exposing it cost nothing. The 8
duplicate groups that exist are *identical text* — verified directly: the count of keys
mapping to more than one distinct text is **0**, globally and per session.

**19 ids legitimately span several sessions** (worst: `8bbc2d2f`, 5 rows across 4 sessions).
Same text, different conversations. All rows are returned, with their differing `session_id`,
`ts`, and `title` — that attribution is the useful part and must not be collapsed.

## Verification worth trusting

- **The id space was stress-tested behaviourally, not just structurally.** The verifier fed
  **156 distinct `(id, session_id)` pairs from 5 different keyword searches** through
  `message.sql`: 0 unresolved, 0 `chars` mismatches. It also tried and failed to construct a
  case where the two files' filters disagree.
- **No truncation anywhere.** The 40,396-character worst case retrieves at exactly 40,396
  with all 427 newlines and its tail intact. The verifier independently re-queried the corpus
  for the current longest block to confirm the test target had not aged out.
- **The guard genuinely fires**, confirmed behaviourally as well as structurally — `ok` is
  threaded `msg_guard → hist → blocks → texted → outer WHERE`. DuckDB silently eliminates an
  unreferenced `error()` CTE, so presence is not proof.

## D9: my check was wrong, the code was right

D9 inherited the clause "ZERO occurrences of `guard`" from an earlier task, where it detected
a stray SQL result block. Applied to a file whose whole job is returning arbitrary
conversation text, it fails the moment you retrieve a message that *discusses* the skill's own
guard CTEs — which is exactly what the mandated test id does.

The verifier inspected every capture and confirmed each occurrence sits inside a `txt` or
`snippet` data field, never a header, alias, or leaked block; the three untouched files have
zero occurrences; no header collides across files.

**The implementer reported this as a FAIL rather than reading past it, which is the correct
behaviour** — a check whose wording is wrong should be escalated, not silently reinterpreted.
The lesson: a check that bans a *string* is unsafe against a file that returns user data.
Ban a *header*, or assert the header count.

## What deliberately did NOT change

- **`sqlresults.sql`, `sqlresults-summary.sql`, `coverage.sql`.** Untouched, verified by
  `git diff --stat`.
- **Everything in `search.sql` except the `SELECT` list.** The window size, `LIMIT 40`,
  `ORDER BY`, and the `strpos`-once predicate are byte-identical. The `ORDER BY` keeps its own
  `md5(w.txt)` — two textual occurrences of that expression are expected and correct, because
  hoisting it would restructure the most-hardened block in the file and `ORDER BY id` would
  sort differently (prefix vs full hash).
- **No paging in `message.sql`.** A 40 KB field round-trips losslessly through `-csv`, so
  paging would be complexity without benefit.
- **The `tool_result.sqldata` mystery.** 47 raw-text occurrences, 0 extractable rows.
  Undiagnosed across all four tasks, deliberately.
- **The other 8 skills, `.claude-plugin/`, `.cortex-plugin/`.** Untouched, so the fork keeps
  merging cleanly from `upstream/main`.

## Known limitations carried forward

- **A keyword longer than roughly 380 characters** can have its own tail cut out of the
  snippet (from task 3). Now much less consequential — you can retrieve the full message.
- **`sqlresults.sql` ordering** was made deterministic in task 3; nothing outstanding.
- **Requirement 12 is documentation, not enforcement.** `SKILL.md` instructs the agent to
  summarise a retrieved message rather than print it, and states the worst case concretely
  (40,396 characters ≈ 10,000 tokens). No check can prove a future agent obeys it; the only
  verification is that the line exists.

## Process notes

Six blockers in spec review, **four of them in the checks rather than the requirements**:

- Two `Select-String` commands **threw** in PowerShell 5.1 (two paths passed positionally) and
  the throw produces no matching lines — so "expected zero matches" read as a pass from a
  command that never grepped.
- One check **failed on correct work**: PowerShell capture rewrites LF as CRLF, inflating the
  40,396-character field to 41,046. The tempting fix — stripping carriage returns — would have
  masked a real truncation bug.
- One check was **circular**, asking for two hand-written queries whose agreement was the
  thing under test. It was the check guarding the one requirement labelled a correctness
  requirement.
- One check **could not fail**: `\bid\b` already matched `<session-id>.json` in the untouched
  file.

Two findings changed the design: uppercase ids silently returned nothing (hashes are lowercase
hex), and multi-session ids had no specified output shape, so an implementer could reasonably
have discarded the attribution.
