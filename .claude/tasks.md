# Tasks — Add Test Suites for the 5 Untested Scripts

## Status: In Progress
Pipeline: standard | Branch: test/add-test-suites-for-the-5-untested-scrip-3736

## Checklist
- [x] Task 1: Create `sw-event-schema-sync-test.sh` (done in 583f0f8c — 10 tests)
- [x] Task 2: Create `sw-test-all-test.sh` (done in 583f0f8c, fixed in 84327c87 — 12 tests)
- [x] Task 3: Create `sw-tmux-role-color-test.sh` (done in 583f0f8c — 26 tests)
- [x] Task 4: Create `sw-tmux-status-test.sh` (done in 583f0f8c — 19 tests)
- [x] Task 5: Create `sw-tracker-github-test.sh` (done in 583f0f8c — 12 tests)
- [x] Task 6: Register all 5 in `package.json` test scripts
- [x] Task 7: Confirm `npm test` auto-discovery picks up all 5
- [x] Task 8: Regenerate AUTO:test-suites section in `.claude/CLAUDE.md`
- [x] Task 9: Verify `shipwright docs check` reports 0 stale
- [x] Task 10: Verify all 5 suites pass in isolation (79/79)
- [ ] Task 11: Run full `npm test` aggregate to rule out cross-suite regression
- [ ] Task 12: Revert `.claude/` cache churn from the working tree
- [ ] Task 13: Clean up the `35eb5145` WIP commit
- [ ] Task 14: Open PR closing #3736 with the verification evidence
- [x] Each of the 5 scripts has a `scripts/<name>-test.sh` using harness conventions
- [x] New test files registered so `npm test` picks them up
- [x] AUTO:test-suites section consistent — `docs check` reports 0 stale
- [x] All 5 new suites pass locally (79/79)
- [ ] Full `npm test` aggregate green (no regression in the other suites)
- [ ] PR diff contains only test-suite work — no `.claude/` cache churn

## Notes
- Generated from pipeline plan at 2026-09-03T05:05:28Z
- Pipeline will update status as tasks complete
