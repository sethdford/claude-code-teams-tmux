# Tasks — Cache intelligence-layer GraphQL contributor/blame lookups across pipeline stages within a single run

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-4430

## Checklist
- [ ] Given one pipeline run, each distinct `blame_<owner>_<repo>_<path>` and
- [ ] A failed/empty contributor or blame lookup is cached and not retried within the run.
- [ ] A cache entry whose wall-clock TTL expired mid-run still hits while the run pin is
- [ ] With `SW_GH_CACHE_RUN_ID` unset, cache behaviour is byte-identical to today.
- [ ] `gh_cache_prewarm` returns 0 and issues zero network calls under `NO_GITHUB=true`.
- [ ] Run manifests older than 24h are reaped; `shipwright github cache clear` removes them.
- [ ] New tests added to `sw-github-graphql-test.sh`; **all existing suites still pass**
- [ ] `shellcheck` clean; bash 3.2 compatible (no `declare -A`, no `readarray`, no `${var,,}`).
- [ ] `shipwright version check` passes; `.claude/CLAUDE.md` env-var table updated.

## Notes
- Generated from pipeline plan at 2026-09-07T04:13:16Z
- Pipeline will update status as tasks complete
