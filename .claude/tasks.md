# Tasks — Autonomous Test Gap Filler & Platform Hygiene Agent

## Status: In Progress
Pipeline: standard | Branch: test/autonomous-test-gap-filler-platform-hygi-631

## Checklist
- [ ] Task 1: Fix `grep -c` double-output in `metrics()` `debt_count`
- [ ] Task 2: Enforce `auto()` ordering — metrics before file_issues
- [ ] Task 3: Add `platform_hygiene_patrol()`; wire into `patrol_meta_run`/`patrol_meta_auto`
- [ ] Task 4: De-duplicate `patrol_meta_untested_scripts()` against the agent
- [ ] Task 5: Register `platform-hygiene`/`hygiene-patrol` in `scripts/sw` router + help
- [ ] Task 6: Patrol-integration + dedup + failing-`gh` assertions in `sw-patrol-meta-test.sh`
- [ ] Task 7: `is_sourced_only` + metrics-trend + router-reachability assertions in `sw-platform-hygiene-test.sh`
- [ ] Task 8: Update `.claude/CLAUDE.md` AUTO sections + command table
- [ ] Task 9: Confirm `VERSION` sync; `version check`/`doctor` green
- [ ] Task 10: Run `npm test`; confirm zero regressions
- [ ] `shipwright platform-hygiene {auto|report|metrics|help}` dispatches via the CLI router (alias `hygiene-patrol`).
- [ ] `patrol_meta_run` and `patrol_meta_auto` invoke the hygiene agent; the patrol summary reflects test-gap + debt findings; `patrol.platform_hygiene_complete` emitted.
- [ ] No duplicate "add tests for X" issues between the legacy check and the new agent.
- [ ] `sw-tmux-role-color.sh` and `sw-tmux-status.sh` have passing suites (✔ 11/11, 9/9); `sw-tracker-github.sh` documented as sourced-only and excluded from the coverage denominator (asserted).
- [ ] `metrics` writes atomic snapshots with `coverage_pct`, `debt_count`, and trend deltas to `$METRICS_FILE`/`$HISTORY_FILE`; `grep -c` pitfall fixed; metrics computed before issue filing.
- [ ] New unit/integration assertions added and green; `npm test` passes with **zero regressions**.
- [ ] `VERSION` in `sw-platform-hygiene.sh` matches `package.json`; `shipwright version check` and `doctor` pass.
- [ ] `.claude/CLAUDE.md` AUTO sections updated; `shipwright docs check` clean.

## Notes
- Generated from pipeline plan at 2026-06-11T21:17:50Z
- Pipeline will update status as tasks complete
