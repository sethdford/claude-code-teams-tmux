# Tasks — Add Unit Test Suites for the 5 Untested Core Scripts

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-1714

## Checklist
- [ ] Task 1: Reproduce the 5-script selection; capture `SW_TEST_REPORT` baseline TSV
- [ ] Task 2: Read `lib/test-helpers.sh`; pin exact assertion signatures
- [ ] Task 3: `scripts/shipwright-file-suggest-test.sh` — 8 cases, fixture tree + mock git
- [ ] Task 4: `scripts/sw-tmux-role-color-test.sh` — table-driven role→color, recorder tmux mock
- [ ] Task 5: `scripts/sw-tmux-status-test.sh` — stage colors/icons, heartbeat freshness, dispatch
- [ ] Task 6: `scripts/sw-event-schema-sync-test.sh` — drift/sync/`--write`, isolated fixture repo
- [ ] Task 7: `scripts/sw-test-all-test.sh` — discovery, filter, timeout, TSV report, process-group kill
- [ ] Task 8: `chmod +x` all five; shellcheck clean
- [ ] Task 9: Run each new suite individually via `--pattern`
- [ ] Task 10: Full `npm test`; suite count +5; zero regressions vs baseline TSV
- [ ] Task 11: `shipwright docs sync` to refresh `AUTO:test-suites`
- [ ] Task 12: `git status` clean of fixtures and unintended tracked-file edits
- [ ] Five new `scripts/*-test.sh` files exist, executable, one per target script
- [ ] Each has ≥8 assertions covering happy path, error path, and at least one edge case
- [ ] Each exits 0 with `FAIL: 0` on both macOS and Linux CI
- [ ] Each completes in <30s (well under the 300s watchdog)
- [ ] `bash scripts/sw-test-all.sh --list` includes all five with no `package.json` change
- [ ] `npm test` green; total suite count is exactly baseline + 5
- [ ] No pre-existing suite changed status vs the baseline TSV
- [ ] `git status` clean after two consecutive full runs — no fixture leakage,

## Notes
- Generated from pipeline plan at 2026-08-13T21:51:21Z
- Pipeline will update status as tasks complete
