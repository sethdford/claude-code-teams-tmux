# Pipeline Tasks — Add Test Suites for the 5 Untested Scripts

## Implementation Checklist
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
- [x] Task 11: Run full `npm test` aggregate — 1st run 166/167; root-caused the lone
      failure (`sw-project-detect-test`) to a Linux date-parse bug in
      `project_detect_all`, fixed in e1c9435b; re-running to confirm 167/167
- [x] Task 12: Reverted `.claude/` cache churn (intelligence-cache, platform-hygiene,
      test-holdout manifest, loop-state) from the working tree
- [x] Task 13: N/A — `35eb5145` is already the tip of `main`; this branch has no
      diff against it, so there is nothing to rewrite or squash
- [x] Task 14: N/A — the 5 suites (583f0f8c, 84327c87) are already merged to `main`.
      No PR to open for #3736; the issue can be closed on the merged work
- [x] Each of the 5 scripts has a `scripts/<name>-test.sh` using harness conventions
- [x] New test files registered so `npm test` picks them up
- [x] AUTO:test-suites section consistent — `docs check` reports 0 stale
- [x] All 5 new suites pass locally (79/79)
- [x] Full `npm test` aggregate green — 167 passed, 0 failed, 0 timed out (566s)
- [x] No `.claude/` cache churn left in the tree

## Context
- Pipeline: standard
- Branch: test/add-test-suites-for-the-5-untested-scrip-3736
- Issue: #3736
- Generated: 2026-09-03T05:05:27Z
