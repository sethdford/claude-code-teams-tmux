# Tasks — Complete Test Coverage for Final 3 Untested Scripts

## Status: In Progress
Pipeline: standard | Branch: test/complete-test-coverage-for-final-3-untes-481

## Checklist
- [ ] Task 1: Read `sw-tracker-providers-test.sh` setup pattern for gh mock reuse
- [ ] Task 2: Create `sw-tmux-role-color-test.sh` with tmux mock + 13 assertions
- [ ] Task 3: Create `sw-tmux-status-test.sh` with state file + heartbeat fixtures + 14 assertions
- [ ] Task 4: Create `sw-tracker-github-test.sh` with gh mock + 18 assertions covering all 8 provider_* functions
- [ ] Task 5: Make all 3 test scripts executable (`chmod +x`)
- [ ] Task 6: Register all 3 in `package.json` `"test"` chain
- [ ] Task 7: Run each new test in isolation — verify PASS, no FAIL
- [ ] Task 8: Run `npm test` to confirm full suite still green
- [ ] Task 9: Confirm test count is 103 (was 100, +3 new suites)
- [ ] Task 10: Verify each test uses `set -euo pipefail`, ERR trap, PASS/FAIL counters, tmp dir cleanup trap
- [ ] 3 new test files created, each follows the harness pattern (set -euo pipefail, ERR trap, PASS/FAIL counters, mktemp dir + cleanup trap)
- [ ] Each suite has ≥10 assertions covering happy path + edge cases + NO_GITHUB guard (for tracker-github)
- [ ] All 3 wired into `package.json` test chain
- [ ] `npm test` exits 0 end-to-end
- [ ] No real `gh`, real `tmux`, or real network calls in any test
- [ ] No mutation of user's real `~/.shipwright/` (use `HOME=$TEMP_DIR`)

## Notes
- Generated from pipeline plan at 2026-05-14T19:03:56Z
- Pipeline will update status as tasks complete
