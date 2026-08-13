---
goal: "E2E test: add comment to README [automated]

## Specification: E2E test: add comment to README [automated]

### Goals
- E2E test: add comment to README [automated]

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json (hash-consistency-repo)",
      "relevance": 95,
      "summary": "Build-stage pattern with low complexity, 1 iteration, npm test strategy, and test-focused goal—directly matches profile of E2E test task"
    },
    {
      "file": "success-patterns.json (test-repo-complexity)",
      "relevance": 90,
      "summary": "Low-complexity build fix completing in 1 iteration with npm test, demonstrates quick single-iteration pattern matching this E2E scenario"
    },
    {
      "file": "index.json",
      "relevance": 70,
      "summary": "Tracks build-stage test failures and provides timeout remediation guidance—relevant if test execution stalls during build"
    },
    {
      "file": "success-patterns.json (test-repo-corrupt)",
      "relevance": 65,
      "summary": "Two build-stage patterns with npm test and low complexity, shows prior successful builds though less specific to documentation tasks"
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 60,
      "summary": "Build-stage patterns with npm test and low complexity, provides generic build success baseline but lacks task-specific context"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 6 new discoveries
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Add Unit Test Suites for the 5 Untested Core Scripts — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add Unit Test Suites for the 5 Untested Core Scripts

## Implementation Checklist
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

## Context
- Pipeline: autonomous
- Branch: ci/issue-1714
- Issue: none
- Generated: 2026-08-13T21:51:19Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **e2e-test-orchestration**: Guide implementation of test isolation (worktrees/temp dirs), GitHub API mocking, Shipwright-specific test harness integration, and assertion patterns.

## E2E Test Orchestration for Shipwright

E2E tests in Shipwright must isolate state, mock GitHub, and integrate with the existing test harness (`scripts/sw-*-test.sh` pattern).

### Test Isolation

- Use temporary directories or git worktrees to avoid cross-test contamination
- Clean up all artifacts (temp files, stashed commits, test branches) in trap handlers
- Verify no heartbeat files, state files, or lock files leak into next test

### GitHub Mocking

- Mock GitHub API calls with local functions or stub binaries in test's temp directory
- Stub `gh` CLI if used, or intercept HTTP calls via environment variables (`GH_HOST`, `GITHUB_TOKEN`)
- Verify mocked API contracts match actual GitHub API expectations (field names, response structures)

### Test Harness Integration

- Follow established pattern: `source scripts/lib/compat.sh`, define test functions, emit PASS/FAIL counters
- Use `assert_equal "expected" "actual" "test-case-name"` helpers for readable failure output
- Register test in `package.json` scripts so `npm test` discovers it

### Idempotence & Cleanup

- Each test must produce the same result on repeated runs (no file permission issues, no stale state)
- `trap "cleanup" EXIT` must remove all temporary state without failing
- Avoid hardcoded paths—use `${TMPDIR:-/tmp}` for portability

### Assertion Patterns

- Assert on file contents (use `grep`, `jq`, or `diff` to avoid brittle string matching)
- Assert on exit codes, not just stdout (tests can produce output and still fail)
- Verify side effects: did the commit get made? Does the branch exist? Check git state directly.
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-08-13T22:38:20Z
last_iteration_at: 2026-08-13T22:38:20Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

