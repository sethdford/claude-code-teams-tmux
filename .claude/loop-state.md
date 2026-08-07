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
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Describes project structure: node type, vitest runner, npm, JavaScript, src/ layout, *.test.js pattern — essential context for building E2E tests in this codebase"
    },
    {
      "file": "failures.json",
      "relevance": 85,
      "summary": "Documents E2E test artifact failure: plan.md/review.md not written to .claude/pipeline-artifacts/, causing cascading E2E test failures — directly relevant to understanding E2E test expectations"
    },
    {
      "file": "success-patterns.json",
      "relevance": 70,
      "summary": "Contains successful build patterns with iteration counts (3 iterations), durations (~45-150s), and test strategy (npm test) — provides reference for expected build performance and approach"
    },
    {
      "file": "metrics.json",
      "relevance": 55,
      "summary": "Historical baselines: build_duration_s=7095, test_duration_s=1459 — gives performance context for build and test stages"
    },
    {
      "file": "knowledge.json",
      "relevance": 50,
      "summary": "Captures test infrastructure issues (mktemp directory failures, stale heartbeats) — relevant for understanding test setup and CI environment concerns"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 7 new discoveries
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[design] Design completed for Adaptive Build-Loop Iteration Budget from Historical Outcomes — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 
[intake] Stage intake completed — Resolution: 
[spec_generation] Stage spec_generation completed — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Adaptive Build-Loop Iteration Budget from Historical Outcomes

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/adaptive-iterations.sh` — load guard, `VERSION=3.3.0`, tunables
- [ ] Task 2: Implement `adaptive_iterations_cohort` (bash 3.2 safe, always returns a key)
- [ ] Task 3: Implement `_iter_samples_for_cohort` with `fromjson? // empty` malformed-line tolerance
- [ ] Task 4: Implement `_iter_samples_global` (job_id group-by over `loop.iteration_complete`)
- [ ] Task 5: Implement `_iter_percentile` in awk (no `sort` pipeline)
- [ ] Task 6: Implement `adaptive_iterations_suggest` — 3-tier fallback + asymmetric clamping
- [ ] Task 7: Implement `adaptive_iterations_record_outcome` + `adaptive_iterations_explain`
- [ ] Task 8: Wire into `sw-loop.sh` — source, `--adaptive-iterations` flag, `apply_adaptive_budget()` hook, outcome emit, help text
- [ ] Task 9: Write `scripts/sw-adaptive-iterations-test.sh` (18 unit tests, table below)
- [ ] Task 10: Add flag-exists + default-off assertions to `sw-loop-test.sh`
- [ ] Task 11: Regenerate `config/event-schema.json` via `sw-event-schema-sync.sh --write`
- [ ] Task 12: Document in `.claude/CLAUDE.md` (config table + cold-start caveat)
- [ ] Task 13: Run new suite + `sw-loop-test.sh` + full `npm test`
- [ ] Task 14: `shellcheck` clean; `shipwright version check` passes
- [ ] `adaptive_iterations_suggest` returns a history-derived budget for a well-sampled cohort and the unmodified static default when history is absent, empty, malformed, or under-sampled — **AC #1**
- [ ] `shipwright loop --adaptive-iterations` enables it; `loop.adaptive_iterations` in `daemon-config.json` enables it; **default is off** and `git diff` shows no behavior change on any existing path when unset — **AC #2**
- [ ] All 18 unit tests pass, covering no-history fallback, sufficient-history adjustment, and malformed/missing file degradation — **AC #3**
- [ ] `loop.budget_selected` (cohort, budget, default, source tier, sample count) and `loop.budget_outcome` (cohort, iterations, converged, budget) appear in `events.jsonl` and are registered in `config/event-schema.json` — **AC #4**
- [ ] `--max-iterations N` given explicitly still wins — `MAX_ITERATIONS_EXPLICIT` honored
- [ ] `npm test` green (all auto-discovered suites); `shellcheck` clean; bash 3.2 constructs only

## Context
- Pipeline: standard
- Branch: feat/adaptive-build-loop-iteration-budget-fro-1502
- Issue: #1502
- Generated: 2026-08-07T18:39:44Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: E2E tests for file modification need careful structuring around git state, temporary worktrees, and cleanup; this guides scenario design and fixture setup.
- **e2e-test-automation**: Automated README modification in tests requires robust file handling, git state isolation, and detection of transient failures; this skill provides patterns specific to this pattern.

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

## E2E Test Automation for File Modification

### Test Isolation & Git State
File-modifying E2E tests must use worktrees or isolated temp directories to avoid polluting the main working tree. Always:
- Create a fresh worktree or temp directory per test run
- Verify git state is clean before starting
- Use `git reset --hard` or cleanup hooks to restore state after test completion
- Never rely on test execution order for cleanup

### Idempotency & Repeatability
- Run the test twice in succession; both runs must succeed with identical results
- If your test modifies a file, the second run must detect that modification and either skip or validate existing state
- Avoid hardcoding line numbers or positions—use markers (`<!-- AUTO:section-id -->`) to find insertion points

### Assertion Patterns
- Assert on file *content* (use `grep` or content comparison), not just file *existence*
- Verify git diff output to confirm the modification is what you expected
- Check that git can track the change (no binary files, encoding issues, or CRLF conflicts)

### Failure Diagnosis
- Log the full `git status`, `git diff`, and file content on assertion failure
- Capture the diff so reviewers can see exactly what was supposed to change
- If cleanup fails, fail the test loudly—don't silently leave state behind

### README-Specific Patterns
When testing README modifications:
- Preserve existing content and comments; only add new sections or markers
- Use HTML comment markers (`<!-- AUTO:section -->`) to delineate auto-managed sections
- Validate markdown syntax after modification (check for broken links, mismatched brackets)
- Test both initial addition and update scenarios (section doesn't exist vs. already exists)
"
iteration: 0
max_iterations: 3
status: running
test_cmd: "npm test"
model: sonnet
agents: 1
started_at: 2026-08-07T19:30:27Z
last_iteration_at: 2026-08-07T19:30:27Z
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

