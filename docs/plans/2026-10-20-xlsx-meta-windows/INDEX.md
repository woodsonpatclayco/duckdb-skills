# Ship the xlsx_meta extension on Windows: plan archive

Archived 2026-10-20, after step 5 shipped. Plugin version 0.6.0.

**The plan:** `PLAN-7.md`, unchanged since it was written. The steps landed as planned.

| step | what it delivered | commit | proof |
|---|---|---|---|
| 1 | GitHub Actions Windows build of `xlsx_meta` for DuckDB v1.5.5; the SQL tests pass there (274 assertions) | `b404d27` | the run's Test step; `LOAD` + `xlsx_tables` on the fixture |
| 2 | The binary committed at `extension/bin/v1.5.5/windows_amd64/`; `tools/fetch-xlsx-meta.ps1` | `e403e68` | `tools\fetch-xlsx-meta.ps1` prints `loaded: xlsx_meta <commit> in DuckDB v1.5.5` |
| 3 | `parity.sh` runs on Windows. Seven real workbooks agree: every listing and 3,127 lookups match | `2e46dd8` | `test/parity.sh` (Windows form in the extension README) |
| 4 | The query skill and contract tools use the extension, with the Python fallback | `b50013d` | `tests\prove-xlsx-meta-route.ps1` |
| 5 | 0.6.0, README, `docs/SHIPPED.md` | (release commit) | from the installed plugin |

**Found along the way:** Windows Python prints `xlsx_meta.py tables/names` listings in cp1252,
and `-I` ignores `PYTHONUTF8`. Pass `-X utf8` instead. This only affected the parity comparison.
Files written with `-o` were already UTF-8.
