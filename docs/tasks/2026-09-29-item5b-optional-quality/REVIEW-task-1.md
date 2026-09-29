# REVIEW — TASK.md (item 5b: make quality definitions optional), round 1

Reviewer: `task-reviewer`. Round 1, on the spec only — no implementer had run.
Verdict at the time: **NOT READY**, five blocking items.

Recorded here because the reviewer reports inline. `PLAN-4.md` confirmed unedited since frozen (`fb4eecb`).
All five claimed findings independently reproduced; the fifth's *role* was misread (B4).

## The correction that mattered most: `@fingerprint` does not do what the spec said

The draft justified keeping `@fingerprint` required because it "detects a rename" and because
`materialize.ps1:268` depends on it. **Both reasons were wrong.**

- A renamed source column fails DuckDB's binder first — `Binder Error: Referenced column "Market_RENAMED"
  not found in FROM clause!` — so the harness reports `ERROR` and the fingerprint is never evaluated.
  Reproduced in the main session. The binder catches renames; the fingerprint only restates the view's own
  `SELECT` alias list and catches an edit to it the author forgot to re-declare.
- `materialize.ps1:268` calls `Get-ContractDirectiveLiteral`, which returns `$null` on absence
  (`:230`), and the fingerprint row is written only inside `if ($fingerprintStatus)` (`:425`). No ripple.

The directive still belongs on the required side — it needs no opinion about the data — but the spec now
gives the true reason, rejects auto-derivation explicitly (a self-derived fingerprint always matches), and
records both so the next session does not relitigate it.

## Blocking defects, and the fixes applied

**B1 — AC3 could not detect the most likely wrong implementation of the guard.** `-- @asert` is caught by
every plausible implementation, so it proved nothing about the form chosen. A regex alternation of the
seven keywords without `\b` — a natural reading of the draft — accepts `-- @snapshotX`, `-- @sheets`,
`-- @assertion` and `-- @snapshot_committedX`, reintroducing the hole for four typo families while passing
AC3, AC4 and AC12. Reproduced in the main session. Fixed: the guard is pinned to maximal-word extraction
with case-sensitive whole-word membership, alternation is explicitly forbidden, AC3b tests all four prefix
typos, and a mutation proves AC3b catches what AC3 cannot.

**B2 — AC9's 78 was unreachable by the commands given.** A second unchanged run SKIPs
(`materialize.ps1:343-366`) and writes no `check_history` rows, so the stated procedure returns **39**.
`-Force` does not help — it is used only downstream of the decision. Item 6's own `RESULT-1.md` records
that the second pass must be a `target_missing` REFRESH by dropping the tables. Fixed, and item 6's
refresh-escape sentence restored.

**B3 — AC8 could be satisfied by diffing a run against itself**, and live `SNAPSHOT` values make
byte-equality refresh-fragile. Fixed: the baseline must come from `9bbf700` in a throwaway worktree before
any edit, with differences confined to `SNAPSHOT` observed values treated as workbook drift.

**B4 — Deliverable 3 and AC11 fixed a bug that does not exist.** `lake-status.ps1:140`'s `$syntheticIds`
is a NOTE-suppression list, not an expectation that `ANCHOR`/`ROWS_FLOOR` rows exist; `-History`
iterates only rows present, so absence is already tolerated. "Not declared" was also unobtainable —
`check_history` cannot distinguish never-declared from absent, and the script receives a contract name,
not a path. Fixed: Deliverable 3 cut, "not declared" moved to out-of-scope with the reason, AC11 rewritten
to prove all three modes run cleanly unchanged.

**B5 — "This is not a regression" was false for case B.** Removing Guard 1 would turn a standalone
`check-contract.ps1` run on a contract whose *only* assertion is misspelled from a loud error into
silence. Fixed by resolution (a): the unknown-directive guard goes into `check-contract.ps1` too, with
AC3c covering case B, since `check-contract.ps1` is a command Phil can run and should not be the one
entry point that drops typos.

## Non-blocking issues fixed

- Case handling was unspecified; PowerShell `-match` is case-insensitive while `[regex]::Match` is not.
  Pinned to case-sensitive so the guard names the typo itself.
- A residual typo family stays open — `-- @ assert x: 1` and a missing `@` are not directive-shaped under
  any parser. Now stated as a known residual; AC3 renamed so it no longer claims "the typo hole is closed".
- Two implementation traps a one-line change would miss: `ANCHOR_TOTAL`/`ANCHOR_NONNULL` are generated
  unconditionally at `:404-405` and required at `:437`/`:444`, and a missing key `continue`s past
  `TRUNCATION_*`, `CONSISTENCY_*` and `FINGERPRINT`; and `$rowsFloorInt` defaults to `0` at `:227`,
  producing an always-true `ROWS_FLOOR,0,<n>,PASS`. Both now named, with mutations.
- AC4's pass condition depended on the live workbook; now "no `unknown directive` line appears".
- AC1's fixture filter was underspecified; now pinned to all sixteen raw columns.
- AC5's 52,037 was quoted from committed snapshots, not measured; now labelled as such.
- AC13 had no command and an undefined file set; both now given.
- The "works once given every directive" block omitted two lines of real output; now complete.
- Plan drift: this supersedes item 4's Decision 1, which a future session would otherwise read as current.
  `RESULT-1.md` and `SHIPPED.md` must now record that the live grammar lives in the two tools' headers.

## Main-session verification

| claim | result |
|---|---|
| a sheet-side rename yields a Binder Error, not `FINGERPRINT,DRIFT` | confirmed — `ERROR` / `Binder Error: Referenced column … not found` |
| alternation without `\b` accepts four prefix typos | confirmed — `snapshotX`, `sheets`, `assertion`, `snapshot_committedX` all accepted |
| maximal-word extraction flags all four and accepts the valid lines | confirmed |

All held. The revision was written against them.
