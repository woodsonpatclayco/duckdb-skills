# REVIEW-task-1 — task-reviewer on the first item-4 draft (commit 9767904)

**Verdict: NOT READY.** Five short wording fixes; the plan is sound. All findings below were
folded into TASK.md.

## Round-2 risks — fixed

1. **AC2 could not pass.** README line 78 ("It cannot see Cortex Code sessions"), which
   decision 4 forbids touching, hits the `Cortex Code` pattern. AC2 now lists every allowed
   kind of hit.
2. **The fork has GitHub Issues disabled** (`has_issues: false`), so "point at the fork's
   issues page" would have made a dead link. The README now says to report to the fork's
   owner and sends upstream bugs to upstream's tracker.
3. **The Final check expected backslashes,** but Claude Code 2.1.224 substitutes
   `${CLAUDE_PLUGIN_ROOT}` with forward slashes. The false pass is now named: in this repo a
   fallback to the repo's own `tools\` would give identical output, so the path is the only
   discriminator.
4. **"Then the plugin update" was not a command,** and AC2 could not catch the stale
   `marketplace update duckdb-skills` line. Both update commands are now literal, and AC2
   checks them.
5. **The Final check needs the merge on GitHub,** because `marketplace add` clones GitHub. A
   push precondition is added.

## Smaller fixes

- **AC1** uses `validate --strict`: exit 0 is now expected, against exit 1 at base (measured).
- **"stderr" replaced** by "the output also contains", which Phil can see in a session.
- **`Clayco_Job_Costs_from_GL` may show `outcome=REFUSED`** in the real lake. Noted as not an
  install failure.
- **Platform support (lines 191–195) and line 78** are named as out of scope.
- **Drift from PLAN-5 item 4 stated:** "describes both hosts" was superseded by the plan's own
  Claude-Code-first decision.

## Confirmed (read-only)

- **README line numbers:** all correct.
- **CLI:** the `plugin marketplace add`, `plugin install`, `plugin list` and `plugin update`
  commands exist.
- **The repo** is public and reachable.
- **The cache layout** is `cache\<mkt>\<plugin>\<version>\`, and the install copies tracked
  files including `tools\`.
- **The non-repo refusal** reproduces from `%TEMP%`.
