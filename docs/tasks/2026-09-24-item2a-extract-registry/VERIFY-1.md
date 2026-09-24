# VERIFY-1 — independent verification of RESULT-1.md (item 2a)

Verifier: `verifier`, in a disposable `git worktree` at `C:\Users\woodsonp\Claude\Dev\_verify-2a`,
commit `8549e42`. Live tree confirmed at `8549e42` with `git status` clean afterwards and no stray
fixture directory; worktree removed.

## Verdict: SHIP

All twelve acceptance checks reproduced independently from a clean shell. Both requested integrity
attacks landed as intended. No defect from `REVIEW-task-1.md`'s twenty was found to have returned, and
no overstatement was found in `RESULT-1.md`.

Because this spec is deliberately 100% local with committed fixture generation, the verifier re-ran
**all twelve** — the thing the 2a/2b split was for.

| Check | Observed | Verdict |
|---|---|---|
| AC1 | `c-users-woodsonp-claude-dev-_verify-2a` (note: the worktree's id, as designed), no `:`, no separator, root creatable, exit 0 | PASS |
| AC2 | both messages exact, exit 0 twice, `absent` still absent | PASS |
| AC3 | **0 / 90 / 1500**, all in band; `materialized_at` `2026-09-24T00:25:24Z` against local `2026-09-23T19:25:24` — the ~5h gap visible | PASS |
| AC4 | window 60: now→FRESH, −90→EXPIRED; window 1440: −90→FRESH, −1500→EXPIRED | PASS |
| AC5 | `90 / window: 60 / verdict: EXPIRED`, exit 0 | PASS |
| AC6 | `ac6_far_window`→EXPIRED, `ac6_short_window`→FRESH | PASS |
| AC7 | one run, 8 lines (2 healthy + 6 damaged), all damaged `UNKNOWN`, exit 0; re-run at window 999999 **byte-identical** | PASS |
| AC8 | order 0,10,45,90,90,90,90,1500; after deletion gone next run, total dropped by exactly 381,002 | PASS |
| AC9 | `parent_projects`→AGREES; `size_mismatch`→`DISAGREES (declared 999999, on disk 380104)`; parts sum to total | PASS |
| AC10 | −90→EXPIRED, −1500→EXPIRED PAST-CEILING; file list and sidecar contents byte-identical before/after | PASS |
| AC11 | `registry.sql` first bytes `45,45,32`; sidecar `123,13,10` | PASS |
| AC12 | 17 fields vs 17 `DESCRIBE` columns, symmetric difference **empty**; `runtime_seconds IS NULL` → `true` | PASS |

## Mutation tests — is AC3 decisive, or decorative?

The verifier mutated `registry.sql` inside the worktree to each known-wrong form and re-ran AC3,
restoring byte-exact from `git cat-file blob` afterwards (never `git checkout --`):

| mutation | predicted wrong value | observed | AC3 |
|---|---|---|---|
| naive local — `date_diff('minute', materialized_at::TIMESTAMP, now()::TIMESTAMP)` | ≈ −209 | **−210**, verdict `UNKNOWN (clock skew)` | **FAILS correctly** |
| double shift — pin `TIMESTAMPTZ`, keep `timezone('UTC', now())` | ≈ 390 | **390** exactly | **FAILS correctly** |

**AC3 is decisive.** Both wrong forms are caught, with observed values matching predictions almost
exactly. Worth noting the naive-local mutation was additionally caught by the clock-skew rule — a
negative age reported `UNKNOWN (clock skew)` rather than a plausible-looking number, which is the
belt-and-braces the spec asked for. `registry.sql` confirmed restored (`git status`, `git diff` both
empty; first bytes re-checked).

## Per-directory isolation — real, not cosmetic

| test | result |
|---|---|
| single glob `read_json('<damaged>/*/_extract.json')` | `Invalid Input Error: Malformed JSON …` **exit 1** |
| same glob with `ignore_errors=true` | `Parse errors cannot be ignored for JSON formats other than 'newline_delimited'` **exit 1** |
| `list-extracts.ps1` over the **identical** damaged root | all 8 directories reported, **exit 0** |
| ordering dependency — a 9th damaged dir `zzz_last_bad` sorting **last** | all 9 reported, `UNKNOWN (unreadable sidecar)`, **exit 0** |

The architecture is genuinely what makes this work: a bare glob dies on the same fixture set the tool
handles cleanly, and the explicit `exit 0` after the loop — not a fallthrough `$LASTEXITCODE` — is what
holds when the broken directory is enumerated last. The implementer found and fixed that leak during
its own run; the fix is verified rather than taken on trust.

## The remaining checks

- **NULL-age guard is real**, not accidental: `coalesce(date_diff(...) > window, true)` present at
  `registry.sql:84-85`, and behaviourally a window of 999,999 left all six damaged cases `UNKNOWN`
  with byte-identical output. A huge window cannot launder a damaged sidecar into freshness.
- **Fixtures stamped from `[DateTime]::UtcNow`** — confirmed in code and by the measured ~5h gap. This
  is load-bearing: a local-stamped fixture would let the naive-local implementation pass AC3.
- **Verdict tokens and exit codes exact.** The verifier tested exit 2 itself:
  `extract does_not_exist not found under <root>`, exit 2.
- **Explicit `-ExtractRoot` never created**; the absent root stayed absent across three runs.
- **`README.md:107-115`** records the decision, names the contradiction with
  `skills/query/SKILL.md:22-25` explicitly, and states no resolution code changed.
  `git diff 263febe 8549e42 -- tools/ensure-duckdb-compat.ps1 skills/query/SKILL.md` is **empty**. The
  verifier additionally ran `tools\run-compat-tests.ps1` — exit 0, `REGRESSION: none`, so item 1 is
  unharmed.

## One clarification the verifier raised, and it is right

`path` and `parquet_glob` are **correctly absent from `SIDECAR.md`**. They are not sidecar JSON fields
— they are `registry.sql`'s own computed output columns (`getvariable('dsk_dir') AS path`,
`registry.sql:57-58`). The spec discusses them under "The registry", not under the schema, and treating
them as sidecar fields would be wrong. Items 2b, 6 and 8 consume them from the registry, not from the
JSON.

## A defect in the spec's own text, confirmed

`TASK.md`'s AC7 says "Six directories … of which **two are healthy**" and later "confirm the **four**
damaged ones", while enumerating **six** numbered damaged cases between those two sentences. Both counts
are leftovers from before cases 5 and 6 were added in the second review pass.

This is a spec-text defect, **not a coverage gap** — the implementer built 8 directories (6 damaged + 2
healthy) and verified all six, and the verifier reproduced all six in one run. `TASK.md` is frozen by
`RESULT-1.md`, so the text is left as written and the error is recorded here and in `SHIPPED.md` rather
than edited in place.

## Environment note from the verifier, worth keeping

Two early parallel bash calls raced on shell state: PowerShell's `cd` updates `$PWD` but **not** .NET's
`Environment.CurrentDirectory`, and the fixture script resolves `-Root` via
`[System.IO.Path]::GetFullPath()`, which uses the .NET value. That briefly regenerated fixtures under
the *live* tree's already-gitignored `.duckdb-skills\fixtures\`. No tracked file in either tree was
touched, the stray directory was deleted, and both trees verified clean. The verifier then pinned
`[System.IO.Directory]::SetCurrentDirectory(...)` before each command.

This is a real trap for any future tool resolving a relative path via .NET while a session uses `cd`.
