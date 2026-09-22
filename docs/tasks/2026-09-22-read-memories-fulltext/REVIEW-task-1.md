# REVIEW-task-1 — `task-reviewer` on TASK.md (retrieve the truncated part of a message)

Verdict at review time: **NOT READY** — 6 blockers, 4 would-cause-a-round, 4 nits. All
findings applied to `TASK.md`. Four of the six blockers were in the **checks**, not the
requirements.

The reviewer verified both load-bearing measurements in place, and both held — but found the
evidence-gathering instructions around them broken.

## Measurements confirmed

- **The 8-character id is safe.** Under `search.sql`'s exact filters: 8,506 clean blocks,
  8,472 distinct texts, **8,472 distinct `left(md5(txt),8)` — zero prefix collisions**. The
  "harmless by construction" claim was tested directly: keys mapping to more than one
  *distinct text* = **0**, globally and per session.
- **`-csv` carries a 40 KB field losslessly.** `c443c766` is exactly 40,396 chars / 427
  newlines / 196 quotes, and round-trips intact — so "no paging" is correct.
- **New fact the spec did not have:** 19 ids occur in **more than one session** (worst:
  `8bbc2d2f`, 5 rows across 4 sessions). Identical text, different attribution.

| # | Sev | Finding | Fix applied |
|---|---|---|---|
| 1 | blocker | Two D13 `Select-String` commands **throw** in PowerShell 5.1 — two paths passed positionally. The ellipsis check produces no matching lines *while failing*, so it reads as "ZERO matches → PASS" from a command that never grepped anything | Comma-joined `-Path` form throughout, plus a stated rule in a new capture-guidance section: **a throwing `Select-String` is a FAIL, not zero matches** |
| 2 | blocker | The capture method was unspecified, and the obvious one corrupts the evidence. PowerShell 5.1 rewrites LF as CRLF: the true 40,396-char field re-reads as **41,046**. D2's `length(txt) = chars` would fail by 650 on correct work — or get "fixed" with a `replace(txt, chr(13), '')` that hides a real bug | New "How to capture output" section mandating `cmd /c "duckdb ... > ""%TEMP%\cap.csv"""` and asserting inside DuckDB via `read_csv`, never by measuring strings in PowerShell |
| 3 | blocker | D4 was **circular**: it asked for two hand-written queries whose equivalence was the very thing under test, proving only that their author was self-consistent. It guarded the spec's own stated correctness requirement | Replaced with a real round-trip: every `(id, session_id)` from a 40-row search fed through `message.sql`, expecting `pairs_unresolved = 0`, plus a side-by-side filter-line diff, plus the corpus count relabelled as a measurement not a test |
| 4 | blocker | Requirement 1's "reuse the same `md5(txt)` expression" is **not literally achievable** — `txt` is only available as `w.txt` in the final block, so the correct edit yields two textual `md5(w.txt)` occurrences. The alternatives were forbidden (hoisting restructures the hardest-won block; `ORDER BY id` changes the order). D3 would have read the only safe implementation as FAIL | Requirement 1 now gives the exact line to add, states two occurrences are expected and correct, and forbids both alternatives by name. D3 expects exactly two `md5` lines and says which |
| 5 | blocker | D13's `\bid\b` grep **already passes on the untouched file** — it matches `<session-id>.json`, since `-` is a word boundary. It could not fail, so it was no evidence the `id` column got documented | Pattern replaced with `left\(md5` and `40,396`, plus an explicit instruction to quote the specific lines; the dead pattern is named so nobody reinstates it |
| 6 | blocker | `message.sql` had **no specified ordering**, and multi-row output is real (5 rows across 4 sessions). Unordered output is nondeterministic between runs — the exact defect task 2 documented and left alone in `sqlresults.sql`. Shipping it again in a new file is a regression by repetition, and it makes D9 unreproducible | Requirement 2 mandates `ORDER BY ts DESC, session_id`, and notes an `ORDER BY` is not a `LIMIT` so requirement 7 does not forbid it |
| 7 | round | D1's substring assertion was semantically sound but mechanically unspecified — both values are CSV fields with doubled quotes and embedded newlines, so a PowerShell `.Contains()` fails for encoding reasons. "Stripped" was also undefined when text legitimately ends in `...` | D1 now gives the assertion as SQL: `position(regexp_replace(regexp_replace(snippet,'^\.\.\.',''),'\.\.\.$','') IN txt) > 0`, run against re-read captures |
| 8 | round | An uppercase or padded id was silently indistinguishable from an unknown one — `md5()` emits lowercase, and `DSK_MSG='C443C766'` returns zero rows. A user pasting from a terminal that upper-cased it gets "no such message" for a message that exists | Requirement 3 now matches `lower(trim(getenv('DSK_MSG')))`, with no format validation; D5b tests the uppercase case |
| 9 | round | Requirement 3 made `DSK_SESSION` optional but never said what multi-session output should look like, and D1 never exercised it. An implementer could reasonably `DISTINCT` the rows away | New requirement 4 states all rows are returned with differing attribution and must not be collapsed; new D5c tests `8bbc2d2f` for `>= 2` sessions and `count(DISTINCT txt) = 1` |
| 10 | round | Requirement 2's column contract had **no check**. A `message.sql` omitting `title`, or using a two-term `ts` coalesce, passed everything | New **D14**: exact header line, `ts`/`role`/`title` equal to search's for the same row, the four-term coalesce grepped, and a `LEFT JOIN` required so sessions without a sidecar still return |
| 11 | nit | Requirement 12's summarise-don't-print instruction read as a behavioural guarantee, but nothing can verify a future agent obeys it | Relabelled as documentation-only with the verification ceiling stated, and strengthened with the concrete figure (40,396 chars ≈ 10,000 tokens) in `SKILL.md` |
| 12 | nit | `search.sql`'s `id` column position was unspecified, affecting anything parsing CSV positionally | Requirement 1 fixes it as the **first** column |
| 13 | nit | D2 said `chars >= 40396`; the value is exact and the corpus cannot lengthen an existing block, so `>=` invited accepting a wrong number | Now an exact assertion, with the drift clause carved out for it |
| 14 | nit | Corpus floors were stale (8,464 / 8,489) | Refreshed to measured values: 8,506 blocks, 8,472 distinct, 8,497 keyed |

Checks the reviewer ran: both D13 greps (**both threw**), the `\bid\b` pattern (**already
matches**), D7 (1 per file across the four existing files), D10 cmd1 (empty, correctly
CONTROL), the collision analysis, the 40 KB CSV round trip both ways (`cmd /c` lossless;
PowerShell inflates by 650), and D5/D6 against a prototype `message.sql` — unknown id gave
header-only at exit 0, empty id gave `Invalid Input Error: DSK_MSG is required` at exit 1, so
the guard shape does fire when `ok` is threaded.

No plan exists; line 3 declares that with a reason, per convention.
