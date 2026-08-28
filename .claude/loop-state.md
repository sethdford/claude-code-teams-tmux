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
      "file": "success-patterns.json (test-repo-complexity)",
      "relevance": 85,
      "summary": "Low complexity fix with 1 iteration in build stage using npm test. Single file change pattern matches simple E2E test task profile."
    },
    {
      "file": "success-patterns.json (test-repo-corrupt)",
      "relevance": 82,
      "summary": "Two low-complexity build stage patterns with 1 iteration each, npm test strategy. Demonstrates rapid single-iteration build success patterns."
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 82,
      "summary": "Two low-complexity build patterns with 1 iteration, npm test, test.sh files. Similar complexity and stage profile to automated E2E test."
    },
    {
      "file": "success-patterns.json (hash-consistency-repo)",
      "relevance": 78,
      "summary": "Low complexity test-related goal with 1 iteration in build stage. Pattern for simple, focused test work matches E2E test automation profile."
    },
    {
      "file": "index.json",
      "relevance": 65,
      "summary": "Contains test_failure pattern in build stage with 5 occurrences. Provides debugging context if test execution fails during build."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 5 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Detect and Alert on E2E Test Issue Spam Flooding Open Issues Queue — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Detect and Alert on E2E Test Issue Spam Flooding Open Issues Queue

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/issue-noise.sh` skeleton (load guard, VERSION, `_noise_cfg`)
- [ ] Task 2: Implement `noise_issue_confidence` with override-label precedence *(blocks 3, 5, 8, 11)*
- [ ] Task 3: Implement `is_noise_issue` and `noise_filter_issues`
- [ ] Task 4: Implement `noise_check_flood` with hourly alert dedupe *(depends on 3)*
- [ ] Task 5: Skip noise issues in `triage_score_issue` before the intelligence + timeline calls *(depends on 2)*
- [ ] Task 6: Filter + flood-check in `daemon_poll_github` before the scoring loop *(depends on 3, 4)*
- [ ] Task 7: Source the lib from `sw-daemon.sh` and defensively from `daemon-triage.sh`
- [ ] Task 8: Opt-in auto-close of high-confidence noise in `daemon_on_success`, fail-closed on fetch error *(depends on 2)*
- [ ] Task 9: Harden `sw-e2e-integration-test.sh` — body marker, `EXIT INT TERM` trap, stale-issue sweep
- [ ] Task 10: Filter noise from the three `sw-strategic.sh` context fetches *(depends on 3)*
- [ ] Task 11: Write `scripts/sw-lib-issue-noise-test.sh` *(depends on 2, 3, 4)*
- [ ] Task 12: Add skip + non-E2E regression cases to `sw-lib-daemon-triage-test.sh` *(depends on 5)*
- [ ] Task 13: Register the suite in `package.json`; add `noise_issues` to `config/defaults.json`
- [ ] Task 14: Document the `noise_issues` config block in `.claude/CLAUDE.md`
- [ ] Task 15: Run `npm test` for touched suites + `shipwright version check`; verify shellcheck clean
- [ ] `scripts/lib/issue-noise.sh` exists, is shellcheck-clean, bash 3.2 compatible (no `declare -A`, no `readarray`, no `${var,,}`/`${var^^}`), and has `VERSION` matching `package.json`
- [ ] `triage_score_issue` returns `0` for label-, marker-, and title-matched noise issues and emits `daemon.triage_skipped`
- [ ] Non-E2E issue scores are **byte-identical** to pre-change values (asserted numerically in `sw-lib-daemon-triage-test.sh`)
- [ ] "E2E test flake in checkout flow" (human-filed, no marker/label) is **not** detected as noise — asserted
- [ ] A noise issue carrying `p0`/`urgent`/`security` is **not** detected as noise — asserted

## Context
- Pipeline: standard
- Branch: ci/detect-and-alert-on-e2e-test-issue-spam-3108
- Issue: #3108
- Generated: 2026-08-28T03:42:45Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests must define clear scenarios and assertions; this skill ensures the test exercises the full pipeline (plan→build→test→PR) rather than isolated components

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
started_at: 2026-08-28T04:05:40Z
last_iteration_at: 2026-08-28T04:05:40Z
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

