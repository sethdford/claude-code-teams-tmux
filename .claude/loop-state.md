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
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 85,
      "summary": "Two low-complexity build stage patterns with npm test strategy and single-iteration completion—directly applicable to automated build work"
    },
    {
      "file": "success-patterns.json (hash-consistency-repo)",
      "relevance": 82,
      "summary": "Build stage pattern with 'Specific test goal', low complexity, single iteration, npm test strategy—matches test automation context"
    },
    {
      "file": "index.json",
      "relevance": 75,
      "summary": "Build stage pattern index identifying test_failure signature with timeout fix recommendation—provides failure recovery guidance"
    },
    {
      "file": "success-patterns.json (test-repo-corrupt)",
      "relevance": 72,
      "summary": "Two build stage patterns with npm test strategy, low complexity, single iteration—applicable to simple automated test fixes"
    },
    {
      "file": "success-patterns.json (test-repo-complexity)",
      "relevance": 70,
      "summary": "Low complexity build stage fix pattern with typo root cause—relevant for simple README/documentation modification tasks"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 7 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Detect and Auto-Resolve Duplicate/Runaway E2E Test Issue Creation — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Detect and Auto-Resolve Duplicate/Runaway E2E Test Issue Creation

## Implementation Checklist
- [ ] `patrol_duplicate_issues` exists as a **top-level** function in `scripts/lib/daemon-patrol.sh` and groups open issues by normalized title + sorted label set.
- [ ] Groups with `count > threshold` close all but the newest member, each with an explanatory comment naming the kept issue.
- [ ] Threshold configurable via `patrol.duplicate_issue_threshold` (flat, as the issue specifies) **and** `patrol.duplicate_issues.threshold`; env override `SW_PATROL_DUPLICATE_ISSUE_THRESHOLD` works through `_smart_int`.
- [ ] `--dry-run` logs every intended closure and executes none; verified by a test asserting the `gh` mock recorded zero `issue close` invocations.
- [ ] Unit tests pass for: no duplicates (no-op), duplicates at/below threshold (no-op), duplicates above threshold (closes exactly the expected set, keeps the newest).
- [ ] Additional tests pass for: human-labelled cluster (no-op), assigned issue excluded, closure cap respected, `NO_GITHUB=true` no-op.
- [ ] `./scripts/sw-lib-daemon-patrol-test.sh` green; `npm test` green.
- [ ] `shellcheck scripts/lib/daemon-patrol.sh scripts/sw-daemon.sh` clean at the repo's existing severity level.
- [ ] `emit_event` fires `patrol.duplicate_detected`, `patrol.duplicate_closed`, `patrol.duplicate_dry_run`.
- [ ] `.claude/CLAUDE.md` documents the config keys; `shipwright docs check` exits 0.

## Context
- Pipeline: standard
- Branch: test/detect-and-auto-resolve-duplicate-runawa-3524
- Issue: #3524
- Generated: 2026-09-02T03:57:52Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E test fixture must define clear scenarios (setup state, action, assertion); this skill ensures the test validates both successful README comment injection and failure modes without flakiness

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
started_at: 2026-09-02T05:24:22Z
last_iteration_at: 2026-09-02T05:24:22Z
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

