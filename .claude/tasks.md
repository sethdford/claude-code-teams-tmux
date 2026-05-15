# Tasks — Complete Test Coverage for Final 3 Untested Scripts

## Status: In Progress
Pipeline: standard | Branch: test/complete-test-coverage-for-final-3-untes-481

## Checklist
- [ ] T1: Run all 3 target test suites individually; record PASS/FAIL totals and any WARN lines
- [ ] T2: Inventory `sw-tmux-role-color.sh` branch coverage; add any missing role/edge tests
- [ ] T3: Inventory `sw-tmux-status.sh` widget + dispatcher coverage; add missing branches
- [ ] T4: Inventory `sw-tracker-github.sh` provider_* coverage (9 functions × {happy, error, NO_GITHUB})
- [ ] T5: Verify `HOME=$TMPDIR/home` is exported in every test file (event isolation)
- [ ] T6: Verify `PATH=$TMPDIR/bin:$PATH` exported so real `gh`/`tmux` never invoked
- [ ] T7: If `tracker.notify` WARN persists, register event in `config/event-schema.json`
- [ ] T8: Run `npm test` end-to-end; confirm zero new failures
- [ ] T9: Produce scripts-without-tests audit and confirm empty result
- [ ] T10: Commit changed test files (and event-schema if touched) with conventional message linking #481
- [ ] All three test files parse cleanly (`bash -n`) and run under `set -euo pipefail`
- [ ] All three exit 0 with PASS=total and FAIL=0
- [ ] Full `npm test` passes with no new failures
- [ ] No `scripts/sw-*.sh` (excluding `*-test.sh` and shared libs) lacks a matching `-test.sh`
- [ ] No WARN lines from the test runs that point to schema gaps
- [ ] Single commit on branch with body referencing #481

## Notes
- Generated from pipeline plan at 2026-05-15T01:23:46Z
- Pipeline will update status as tasks complete
