# SHIPPED — Make quality definitions optional in contracts (item 5b)

Shipped 2026-09-29. A correction to shipped items 4 and 5 that Phil asked for directly; it corresponds
to no PLAN-4 step. Verified SHIP on round 1: 13 of 13 acceptance checks and 7 of 7 mutation proofs
independently reproduced, AC8 against the verifier's **own** `9bbf700` baseline rather than the
implementer's.

Commit: `304e6d9`, merged as `c820100`.

## The principle, in Phil's words

> "Most of the queries will not even have quality definitions. It should be something I prompt to be
> added, not added automatically and guessed at."

Before this item a contract with correct types and no quality opinions was **illegal** — three
`missing required directive` errors. That forced invented thresholds, and invented thresholds get
ignored: the cry-wolf failure arriving through the front door.

## What changed

Directives now split by one question: **does it need an opinion about the data?**

| directive | now | why |
|---|---|---|
| `-- @sheet` | required | no opinion — the harness cannot read the sheet without it |
| `-- @fingerprint` | required | no opinion — a restatement of the contract's own column list |
| `-- @anchor` | **optional** | opinion: "this column is always populated" |
| `-- @rows_floor` | **optional** | opinion: a threshold Phil chooses |
| `-- @assert` | **zero or more** | opinion |
| truncation + consistency | always run | invariants needing no input |

A quality-free contract is now valid and still gets the protection that needs no judgment. An undeclared
anchor or floor emits **nothing** — no placeholder line, no invented default, no status outside item 6's
`PASS|FAIL|DRIFT|ERROR` enum.

## The live bug it closed

A misspelled directive keyword was **silently dropped** whenever the contract also had one valid
assertion. `-- @asert` beside a working `-- @assert` returned exit 0 and the misspelled check never ran.
Guard 1 only fired when the typo was the *only* assertion — so it caught the harmless case and missed the
dangerous one.

Replaced by an **unknown-directive guard** in both `run-assertions.ps1` and `check-contract.ps1`. It
extracts the whole word after `@` and tests exact, case-sensitive membership in the seven keywords. It is
deliberately **not** a regex alternation of the keywords: that natural form accepts `-- @snapshotX`,
`-- @sheets`, `-- @assertion` and `-- @snapshot_committedX` as valid, reintroducing the hole for four
whole families of typo. AC3b exists to catch exactly that, and a mutation proves AC3b catches what the
simpler AC3 cannot.

## What deliberately did NOT change

- **Both shipped contracts.** SHA-256-identical to `9bbf700`, and every directive kept. They cover Phil's
  two most important sheets, where he should have opinions.
- **Their output.** Byte-identical harness output, 54 lines, against the verifier's independent
  `9bbf700` baseline.
- **Item 6.** `check_history` still totals 78 across two materializations — GL 16 per run,
  `All_Sales_Data` 23 per run. `tools\lake-status.ps1` is SHA-256-identical to `9bbf700`; it already
  tolerated missing rows, so the fix the first draft specified for it was removed as unnecessary.
- **`@fingerprint` stays hand-written**, deliberately not auto-derived. A bind-only query over the view
  reproduces it exactly, but a self-derived fingerprint always matches, destroying the one thing it
  catches.
- **Guard 2** (a malformed `@assert` line is an error) is unchanged.
- **`docs\tasks\`**. Items 4 and 5's archives still describe the grammar as it was then.

## Item 4's Decision 1 is superseded

Anyone reading `docs\tasks\2026-09-24-items34-sheet-discovery-contract\TASK.md` will find a grammar
description that is no longer current, in two respects: **Guard 1 has been removed**, and **an
unknown-directive guard has been added**. The live grammar now lives in the headers of
`tools\run-assertions.ps1` and `tools\check-contract.ps1`.

## Corrections worth keeping

**`@fingerprint` does not detect an upstream rename.** The first draft kept it required on the grounds
that it "detects a rename". Measured: a renamed source column fails DuckDB's binder first —
`Binder Error: Referenced column … not found in FROM clause!` — so the harness reports `ERROR` and the
fingerprint is never evaluated. It catches only an edit to the contract's own column list that the author
forgot to re-declare. Its second claimed justification, that `materialize.ps1` depends on it, was also
wrong. It stays required because it needs no judgment, not because it guards against upstream change.

**The spec's anchoring test could not fail.** Mutation 7 claimed that removing the guard's start-anchor
would trip on a prose line in the GL contract. The implementer ran it, found it did not, and said so
rather than reshaping the guard to force a failure. The cause: all 18 mid-line `@word` mentions in the two
shipped contracts are *known* keywords, and so was AC12's own example, `see @anchor above`. An unanchored
guard extracts a known word and accepts it. The verifier supplied the missing test — a prose line
mentioning an *unknown* word, `-- note: ask @phil about the Q3 numbers` — which passes silently against
the shipped anchored guard and fails with `unknown directive: -- @phil` against a mutated unanchored one,
in both entry points. The implementation was right throughout; the spec's test was the defect.

## Known residual, not closed

A line with whitespace between `@` and the keyword — `-- @ assert x: 1` — or with the `@` missing
entirely is not directive-shaped under any parser and is still silently ignored. Reproduced by the
verifier. Recorded rather than claimed as fixed.

## Found in passing, not fixed

`materialize.ps1` uses a contract's filename as an **unquoted SQL identifier**, so a hyphenated contract
filename fails with `Parser Error: syntax error at or near "-"`. Confirmed pre-existing at `9bbf700` and
unaffected by this item. Both shipped contracts use underscores, so it has never fired — but it will the
first time a contract is named after a sheet containing a hyphen. Out of scope; worth an item if and when
contracts start being generated.

## What this makes possible

`tools\list-sheets.ps1` can now generate a typed, assertion-free contract for any of the workbook's 26
sheets, with quality definitions added one sheet at a time when Phil asks. Not built here; a separate
request.
