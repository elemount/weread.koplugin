# macOS release test — v1.7.2

- Date / executor: 2026-10-07 / Codex
- Candidate: `_meta.lua` and `main.lua` version 1.7.2; based on `main` at `1456c0e`
- Candidate ZIP: `/tmp/weread.koplugin-v1.7.2-candidate.zip`
- Candidate ZIP SHA-256: `06a1ad4097dc997af660dd43e391559eb33fb3a40f06885503ded29f688db22d`
- Host: macOS 27.0.1, arm64
- KOReader SHA / runtime: unavailable; `KOREADER_DIR` is not configured and no local runtime was found
- UI automation / Kindle: no UI automation tool or connected Kindle was available
- Network boundary: mock contract tests only; no real WeRead account or service used

## Automated checks

| Check | Result | Evidence |
| --- | --- | --- |
| Lua specs | PASS | `bash scripts/run_lua_specs.sh` — all 72 specs passed |
| Namespace | PASS | `bash scripts/check_lua_namespace.sh` |
| Luacheck | PASS | 158 files, 0 warnings, 0 errors |
| Mock API contract | PASS | `python3 scripts/test_mock_weread.py` — 2 tests passed |
| Python compilation | PASS | `python3 -m py_compile scripts/*.py` |
| Release notes extraction | PASS | `scripts/extract_release_notes.sh 1.7.2` |
| Package and ZIP integrity | PASS | `scripts/package_release.sh`, `unzip -t`; one top-level `weread.koplugin/` directory |
| Credential scan | PASS | No credential-shaped values found |
| KOReader PluginLoader integration | BLOCKED | Runner requires a checkout at the pinned KOReader commit; `KOREADER_DIR` is unavailable |

## Core UI cases

The real KOReader window checklist could not be run because no KOReader runtime or UI automation tool was available. Each case remains BLOCKED; automated specs and package checks are not UI acceptance.

| Case | Result | Evidence / reason |
| --- | --- | --- |
| C01 Load and entry | BLOCKED | No KOReader runtime |
| C02 Settings persistence | BLOCKED | No KOReader runtime |
| C03 Real reading | BLOCKED | No KOReader runtime |
| C04 Bookshelf navigation | BLOCKED | No KOReader runtime |
| C05 Bookshelf layout | BLOCKED | No KOReader runtime |
| C06 Search, filters, offline cache | BLOCKED | No KOReader runtime |
| C07 Book details and chapter selection | BLOCKED | No KOReader runtime |
| C08 Download and open | BLOCKED | No KOReader runtime |
| C09 Cancel download | BLOCKED | No KOReader runtime |
| C10 Resume download | BLOCKED | No KOReader runtime |
| C11 Packaging and fallback | BLOCKED | No KOReader runtime |
| C12 Book association and chapter mapping | BLOCKED | No KOReader runtime |
| C13 Match pause and resume | BLOCKED | No KOReader runtime |
| C14 Highlights and reflow | BLOCKED | No KOReader runtime |
| C15 Thought popup and edge behavior | BLOCKED | No KOReader runtime |
| C16 Source footnotes | BLOCKED | No KOReader runtime |
| C17 Chapter end and prefetch | BLOCKED | No KOReader runtime |
| C18 Progress sync | BLOCKED | No KOReader runtime |
| C19 Open-book and session cleanup | BLOCKED | No KOReader runtime |
| C20 Candidate package restart | BLOCKED | ZIP structure verified; install/restart in KOReader was unavailable |

## Applicable extended and Kindle checks

| Case | Result | Reason |
| --- | --- | --- |
| E07 Non-touch/layout compatibility | BLOCKED | Content and reader layout changed; no KOReader runtime or UI automation |
| Kindle candidate smoke test | BLOCKED | No Kindle connected; device loading, page turns, popup, refresh and ghosting were not checked |

Other extended cases were not triggered by the files changed for v1.7.2. The release acceptance remains incomplete with these explicitly BLOCKED items.
