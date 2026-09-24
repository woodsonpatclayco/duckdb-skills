# REVIEW ? TASK.md item 2b, round 1

Reviewer: `task-reviewer`. Verdict **NOT READY**, ten blocking issues, six proved by running commands
rather than argued. All applied.

The reviewer endorsed the central design bet before finding fault with the interfaces: pulling every
decision and every filesystem mutation into scripts IS achievable, and nothing labelled `[command]`
secretly needs Snowflake. It verified this by reading `registry.sql` -- it already emits
`age_minutes`, `stale`, `past_ceiling`, `reason` and all three `source_*` arrays, so the
decision needs nothing a caller cannot pass in.

## Blocking (all fixed)

| # | Issue | Fix applied |
|---|---|---|
| B1 | **AC4's fixtures do not exist and nothing creates them.** 2a's generator produces baselines of 10/20/30/40/50/15314/42161/1 -- never 100, never a null element, never age 30. Worse, it **resets `ages`/`damaged`/`empty` on every run**, so hand-built fixtures there are destroyed by AC6; and `.duckdb-skills/` is gitignored, so a verifier sees none of them. AC4 -- the check closing the `hardcoded SKIP` hole -- would return NOT RUN. This is 2a's own pass-2 finding returning verbatim. | `tools\make-decide-fixtures.ps1` added as a committed deliverable writing to its **own** root `fixtures\decide`. |
| B2 | **No defined behaviour when the agent has not yet probed Snowflake -- which is the MAIN path.** ""Checking is free"" requires a FRESH answer with zero Snowflake calls, then a probe only if past the window. AC4 supplied current values in all eight rows, so the first call was never exercised. The agent also had no way to learn WHICH objects to probe, and no authority to open `_extract.json` itself. | New verdict `STALE (probe required) age= window= objects=`, printing the objects in order; arrays declared positional against `source_objects`; the script declared the only reader of the sidecar. AC4 rows a and i together now prove zero-call FRESH. |
| B3 | **`FRESH` contradicted `SIDECAR.md` on clock skew.** Measured: `registry.sql` returns `age_minutes=-45 stale=false reason=[]`, so a decision built on `stale` emits FRESH while `extract-status.ps1` says `UNKNOWN (clock skew)` for the same file. Two shipped tools disagreeing about one sidecar. | `REFRESH (clock skew) age=` verdict added, plus AC4 row j. |
| B4 | **`-CurrentRows <int[]>` destroys the null-is-never-zero rule.** Measured: `[int[]]` binds `100,$null,102` as **100,0,102**. So probing a view -- SIDECAR.md's own example -- would say ""the table emptied"" and force a spurious refresh. | Signature changed to `<string[]>` with a literal `null` token; AC4 row m added for a null on the CURRENT side. |
| B5 | **A multi-line `query` breaks both shipped 2a readers -- a latent defect 2b is the first to trigger.** Both parse `registry.sql`'s CSV as a line array, and `ConvertFrom-Csv` treats each element as a record. Reproduced: `list-extracts.ps1` reports `age_minutes=UNKNOWN row_count=NULL`, and `extract-status.ps1`'s first line is **blank**, violating 2a's own first-line contract -- for a valid sidecar whose only sin is the byte-exact multi-line query SIDECAR.md **requires**. | Both readers now join before parsing (`($csvLines -join ""`n"") | ConvertFrom-Csv`), verified to give 1 record / age 91. `registry.sql` unchanged. New **AC17** covers it. |
| B6 | **Eight of seventeen sidecar fields had no stated source, and one is unobtainable.** `publish-extract.ps1` would correctly refuse to publish, stranding the implementer at step 6 -- likely outcome, invented values in production sidecars. `database` cannot be read: the spec itself says `CURRENT_DATABASE()` is empty. No SQL returns `connection`. | `publish-extract.ps1` now stamps `sidecar_version`/`materialized_at`/`window_minutes`/`expires_at` itself and rejects them if supplied -- a clock reading is a decision, and this makes AC9 true by construction. New materialize step 3 captures `role`/`warehouse`/`connection`=DATAHUB/`database`= the qualifier of the first source object. |
| B7 | **""Extract both functions verbatim"" is unexecutable.** Diffed: `Get-ProjectId` is byte-identical but `Resolve-ExtractRoot` is not -- `extract-status.ps1` returns a string, `list-extracts.ps1` returns `(string, bool)` whose flag gates the header lines **2a's AC1 asserts**. | The shared version keeps the tuple form; `extract-status.ps1` takes element [0]. Called out as the one place the refactor cannot be literal. |
| B8 | **AC2 was satisfiable without a restore path, and AC1+AC2 could not tell rename-aside from delete-then-move.** The ""path that vanishes"" injection fails at the sidecar write, before `<live>` is touched, so the restore code never runs. A delete-then-move publish passes AC1 too. | Injection pinned to an **open handle inside staging** (verified to throw `Access to the path ... is denied`, with `FileShare.ReadWrite`); the vanishing-path route forbidden; AC2 now also asserts no `<live>.old` remains. |
| B9 | **Three sidecar states and the first-materialize path had no verdict.** `name mismatch` and `parallel array mismatch` read cleanly with a valid age, so an implementer would print FRESH for a malformed sidecar. And AC5's ""exit 2 for -Name not found"" collided with `REFRESH (no sidecar)` -- the first-ever materialize sits exactly on that boundary. | `REFRESH (malformed sidecar: <reason>)` added; absent directory -> `REFRESH (no sidecar)` exit **0**; exit 2 reserved for parameter errors, with the state-versus-action distinction from 2a stated. AC4 rows l and n. |
| B10 | **AC6 quoted expectations that do not match the checks it re-runs**, named no path to 2a's ACs (they are in an archive folder), and was invalidated by 2b's own AC7 populating the default root. | Bands corrected to 2a's own 0-2 / 89-93 / 1499-1503, the archive path named, AC6 ordered before AC7, and AC1's `no extracts` line excluded from the gate. |

## Non-blocking applied

`DSK_FORCE` pinned to exactly `1`; multi-object stage-1 rule (any moved = moved, all abstain =
abstain); `-SidecarPath`/`-SidecarJson` split rather than one overloaded parameter; stage 2 compares
parsed UTC timestamps not strings (string compare would make ""unchanged"" permanently unreachable);
publish exit 3 distinct from decide's 2; AC10's backdating carved out from the no-fabrication rule;
`dsk-paths.ps1` forbidden from setting `Continue` or `Set-StrictMode` at file scope
(dot-sourcing leaks both); relative `-ExtractRoot` rejected outright rather than calling
`SetCurrentDirectory`; `C:\Users\woodsonp` protected from being ""improved"" to `C:\Users\woodsonp`; verdict
vocabularies declared separate on purpose so nobody harmonises them; environment basics added; AC15
resolves `parquet_glob` by name per the plan rather than hard-coding a path; AC16 switched to
`--diff-filter=A` because a plain diff cannot show a file is new; AC12/AC13 given literal tokens to
assert; AC7's query stated literally and its three internal values required to match unconditionally.

## Drift from the plan

**Omission, two, both fixed:** PLAN-3 requires querying **by name** without touching Snowflake -- AC15
hard-coded a path instead, so it never exercised name-to-path. And the spec deferred state.sql precedence
without saying why; it now says 2a already recorded it.

**Drift: none.** Every version-3 instruction survives -- rows-only stage 1, bytes never compared,
`last_altered` never against `materialized_at`, ambiguous verdict with age inline, the 1440 ceiling,
no per-session cap, per-project isolation, stage-path collision stated literally.

**The four findings deferred from item 2's pass-1 review are closed**, with one qualification the
reviewer raised and the spec now states: AC4 row b proves the refresh **decision**, but only AC12 proves
the **pull**, so AC12 now says so explicitly rather than letting row b be read as covering both.

## What the reviewer said to keep

The architecture bet itself. The measured-facts ordering, with `Move-Item` first because it would ship
invisibly. The two-object role assignment turning drift into a third confirmation that bytes must never be
compared. AC7 refusing to hard-code a row count on a drifting dynamic table. `runtime_seconds` with the
`EXECUTION_STATUS` filter and the `-1790201630243` evidence. The ceiling scoped to the ambiguous
branch only -- the subtle part, since an unchanged `last_altered` means genuinely unaltered. The
out-of-scope section, which matches 2a's SHIPPED non-changes line by line. AC9 as the single best skill
check: the one thing 2a could not prove.

## Scope

Not split. Sixteen checks is really two harnesses -- AC1-AC5 fixtures, AC7-AC14 one skill invocation with
observations taken along the way. The genuine risk is the refactor, so `dsk-paths.ps1` and the reader
fixes land as their **own commit** with AC6 and AC17 run there, before anything else.
