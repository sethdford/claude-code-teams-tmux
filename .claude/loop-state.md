---
goal: "Build Loop Failure Mode Classification and Adaptive Recovery

## Plan Summary
## Implementation Plan: Build Loop Failure Mode Classification and Adaptive Recovery

### Overview

This feature adds intelligent failure classification to the build loop, enabling mode-specific recovery strategies instead of generic retries. When the loop fails, it will analyze error patterns from `error-summary.json` and `progress.md`, classify the failure into one of 5 modes, apply a targeted recovery strategy, and log the action for observability.

---

## Files to Modify

1. **scripts/lib/loop-failure-modes.sh** (NEW) — Failure classification and recovery strategy engine
2. **scripts/sw-loop.sh** — Integrate failure detection and recovery coordination
3. **scripts/lib/loop-restart.sh** — Update restart logic to use classified failure modes
4. **scripts/sw-loop-test.sh** — Add tests for each failure mode classification
5. **package.json** — Register the new test suite

---

## Architecture Decision Record
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Build Loop Failure Mode Classification and Adaptive Recovery
## Context
## Decision
### Component Diagram
### Interface Contracts
# ─── Primary API ──────────────────────────────────────────────────
# classify_loop_failure() → stdout: failure mode string
# Reads: $LOG_DIR/error-summary.json, $LOG_DIR/progress.md
# Reads globals: ITERATION, MAX_ITERATIONS, CONSECUTIVE_FAILURES
# Writes: $LOG_DIR/failure-classification.json (atomic)
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 92,
      "summary": "Contains failure patterns with root causes and fixes directly relevant to failure mode classification. Shows test failures and recovery strategies needed for build loop adaptive recovery."
    },
    {
      "file": "patterns.json",
      "relevance": 58,
      "summary": "Project structure (vitest, node, npm) provides context for understanding test failures and designing recovery strategies appropriate to the runtime environment."
    },
    {
      "file": "patterns.json",
      "relevance": 45,
      "summary": "Basic project type (nodejs) detection provides minimal context about the environment where failures occur and recovery must execute."
    },
    {
      "file": "metrics.json",
      "relevance": 15,
      "summary": "Empty baselines offer no historical data for failure classification or adaptive tuning of recovery strategies."
    },
    {
      "file": "decisions.json",
      "relevance": 10,
      "summary": "Empty decisions log provides no prior adaptive recovery choices or classification rules to leverage."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Failure Mode Classification and Adaptive Recovery — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Build Loop Failure Mode Classification and Adaptive Recovery

## Implementation Checklist
- [ ] Create `scripts/lib/loop-failure-modes.sh` with module guard
- [ ] Implement `classify_loop_failure_mode()` dispatcher
- [ ] Implement `_detect_context_exhaustion()` heuristic
- [ ] Implement `_detect_infinite_loop()` heuristic
- [ ] Implement `_detect_test_flakiness()` heuristic
- [ ] Implement `_detect_dependency_issue()` heuristic
- [ ] Implement `get_recovery_strategy()` function
- [ ] Implement `apply_recovery_context_exhaustion()`
- [ ] Implement `apply_recovery_infinite_loop()`
- [ ] Implement `apply_recovery_test_flakiness()`
- [ ] Implement `apply_recovery_dependency_issue()`
- [ ] Implement `apply_recovery_code_error()`
- [ ] Update sw-loop.sh: source new module at top
- [ ] Add failure classification call in `run_loop_with_restarts()` at failure point
- [ ] Add `--failure-mode` flag to sw-loop.sh argument parser
- [ ] Emit event: `loop.failure_mode_classified` with mode, confidence, evidence
- [ ] Call recovery strategy before session restart
- [ ] Emit event: `loop.recovery_strategy_applied` with strategy, actions
- [ ] Update `loop-restart.sh` to accept failure_mode in restart briefing
- [ ] Inject mode-specific guidance into restart briefing

## Context
- Pipeline: standard
- Branch: feat/build-loop-failure-mode-classification-a-246
- Issue: #246
- Generated: 2026-03-10T12:33:19Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Design isolated test cases for each failure mode (context exhaustion, infinite loop, test flakiness, dependency issue, code error) with reproducible trigger conditions

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


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-10T13:22:39Z
last_iteration_at: 2026-03-10T13:22:39Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-03-10T12:52:35Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":15622,"duration_api_ms":387303,"num_turns":4,"result

