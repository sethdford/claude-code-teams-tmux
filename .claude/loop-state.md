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
      "file": "failures.json",
      "relevance": 85,
      "summary": "Contains E2E test failures including stale pipeline locks, missing artifact writes, and integration test issues that directly impact E2E test execution in the build stage"
    },
    {
      "file": "metrics.json",
      "relevance": 75,
      "summary": "Provides build_duration_s (7095s) and test_duration_s (1459s) baselines for estimating build stage timing and setting reasonable iteration limits"
    },
    {
      "file": "success-patterns.json",
      "relevance": 65,
      "summary": "Shows successful patterns for bug fixes and feature development (complexity 60-65, 3 iterations, standard template) that inform build loop strategy for similar-complexity E2E work"
    },
    {
      "file": "patterns.json",
      "relevance": 60,
      "summary": "Project conventions (Node/vitest/npm/commonjs) needed to understand test setup, execution environment, and file structure for the E2E test build"
    },
    {
      "file": "knowledge.json",
      "relevance": 40,
      "summary": "Contains test failure patterns and fix strategies (mktemp issues, test setup, JSON validation) that may prevent build failures in the test stage"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 10 new discoveries
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Quarantine E2E Test Issues From Production Issue Tracker — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Quarantine E2E Test Issues From Production Issue Tracker

## Implementation Checklist
- [ ] Task 1: Add `labels.e2e_test` + `labels.quarantine` to `config/defaults.json`
- [ ] Task 2: Create `scripts/lib/issue-quarantine.sh` with fail-open `quarantine_filter_json`
- [ ] Task 3: `sw-e2e-integration-test.sh` — ensure label exists, apply it, assert it stuck
- [ ] Task 4: `daemon-poll-github.sh` — filter after `gh_record_success`, before `issue_count`
- [ ] Task 5: `sw-triage.sh` — filter `:463`, `:695`; search qualifier on `:669`
- [ ] Task 6: `sw-strategic.sh` — filter `:115`, `:116`, `:286`, `:380`, `:388`
- [ ] Task 7: Create `scripts/sw-lib-issue-quarantine-test.sh` (14 cases incl. fail-open + wiring)
- [ ] Task 8: Register suite in `package.json` and `scripts/sw-test-all.sh`
- [ ] Task 9: Document quarantine label in `.claude/CLAUDE.md` Test Harness section
- [ ] Task 10: `bash -n` + shellcheck all touched scripts
- [ ] Task 11: Run new suite + daemon/triage/strategic/poll suites
- [ ] Task 12: `npm test` green; `shipwright version check` green
- [ ] Task 13: Verify existing synthetic issues carry a quarantined label; label any strays
- [ ] `scripts/lib/issue-quarantine.sh` exists, is Bash 3.2 clean, `VERSION` matches `package.json`, idempotently sourceable
- [ ] `sw-e2e-integration-test.sh` creates its issue with the `sw:e2e-test` label and asserts the label is present on the created issue
- [ ] `daemon-poll-github.sh`, `sw-triage.sh`, `sw-strategic.sh` exclude quarantined issues by default, and the daemon's logged count reflects the post-filter set
- [ ] Exclusion is overridable via config (`labels.quarantine`) and env (`SHIPWRIGHT_LABELS_E2E_TEST`) — no hardcoded label strings at any call site
- [ ] `quarantine_filter_json` provably fails open: malformed and empty input pass through, exit 0 (cases 8–9)
- [ ] `scripts/sw-lib-issue-quarantine-test.sh` passes 14/14, registered in `package.json`
- [ ] `npm test` green; `shipwright version check` green; `bash -n` clean on all touched scripts

## Context
- Pipeline: autonomous
- Branch: ci/issue-1303
- Issue: none
- Generated: 2026-08-07T01:54:31Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests require explicit acceptance criteria (README modified correctly), edge cases (concurrent modifications, AUTO: markers), and reproducible test patterns across all pipeline stages

## Testing Strategy Expertise

Apply these testing patterns:

### Test Pyramid
- **Unit tests** (70%): Test individual functions/methods in isolation
- **Integration tests** (20%): Test component interactions and boundaries
- **E2E tests** (10%): Test critical user flows end-to-end

### What to Test
- Happy path: the expected successful flow
- Error cases: what happens when things go wrong?
- Edge cases: empty inputs, maximum values, concurrent access
- Boundary conditions: off-by-one, empty collections, null/undefined

### Test Quality
- Each test should verify ONE behavior
- Test names should describe the expected behavior, not the implementation
- Tests should be independent — no shared mutable state between tests
- Tests should be deterministic — same result every run

### Coverage Strategy
- Aim for meaningful coverage, not 100% line coverage
- Focus coverage on business logic and error handling
- Don't test framework code or simple getters/setters
- Cover the branches, not just the lines

### Mocking Guidelines
- Mock external dependencies (APIs, databases, file system)
- Don't mock the code under test
- Use realistic test data — edge cases reveal bugs
- Verify mock interactions when the side effect IS the behavior

### Regression Testing
- Write a failing test FIRST that reproduces the bug
- Then fix the bug and verify the test passes
- Keep regression tests — they prevent the bug from recurring

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Test Pyramid Breakdown**: Explicit count of unit/integration/E2E tests and their coverage targets (e.g., "70 unit tests covering business logic, 12 integration tests for API boundaries, 3 E2E tests for critical paths")
2. **Coverage Targets**: Target coverage percentage per layer and which critical paths MUST be tested
3. **Critical Paths to Test**: Specific test cases for the happy path, 2+ error cases, and 2+ edge cases

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-08-07T03:15:30Z
last_iteration_at: 2026-08-07T03:15:30Z
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

