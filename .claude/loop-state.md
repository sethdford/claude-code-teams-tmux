---
goal: "Build Loop Stuck Detection and Emergency Abort System

## Plan Summary
Implementation plan written to `.claude/pipeline-artifacts/plan.md`.

**Summary of the plan:**

**Problem:** Build loops can burn all 20 iterations when agents make zero forward progress. The existing `detect_stuckness()` triggers soft recovery (session restart), but there's no hard abort for truly idle loops.

**Solution:** Add `detect_zero_progress()` to `lib/loop-convergence.sh` — a focused function checking 3 signals per iteration:
1. No new git commits
2. Test pass/fail status unchanged  
3. No file modifications (via portable `git diff --stat HEAD` fingerprint)

If all 3 fire for 3 consecutive iterations (configurable via `--zero-progress-threshold`), the loop aborts immediately with `STATUS="stuck_zero_progress"` and message "STUCK - no forward progress detected".

**Files:** 3 modified (`lib/loop-convergence.sh`, `sw-loop.sh`, `sw-loop-test.sh`), 1 created (`docs/BUILD-LOOP.md`). ~80 lines new production code, ~80 lines tests. 12 tasks total.

**Key design decision:** Separate function (not merged into existing 7-signal stuckness detection) because they serve different purposes — `detect_stuckness()` = "try harder" (soft), `detect_zero_progress()` = "nothing is happening" (hard abort).
 count. If it hits 3, abort immediately with `STATUS="stuck_zero_progress"`.

**Implicit requirements:**
- Must not interfere with existing `detect_stuckness()` (which triggers session restarts)
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Build Loop Stuck Detection and Emergency Abort System
## Context
## Decision
### Three Signals (all must fire simultaneously)
### Abort Threshold
### Grace Period
### Counter Reset
### Integration Point
### Observability
## Component Diagram
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 90,
      "summary": "Documents 32+ test failure patterns including stale heartbeat detection, mktemp issues, and JSON output problems. Critical for detecting stuck builds and understanding failure signatures that trigger emergency abort."
    },
    {
      "file": "patterns.json (nodejs project conventions)",
      "relevance": 48,
      "summary": "Specifies test runner (vitest), test pattern (*.test.js), and import style (commonjs). Essential for configuring build loop detection logic and understanding how tests execute."
    },
    {
      "file": "patterns.json (nodejs project type)",
      "relevance": 18,
      "summary": "Confirms project is Node.js type. Useful for build stage setup but less specific than conventions data."
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Empty baselines object. Not applicable to current context."
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "Empty decisions array. No relevant content for build loop stuck detection."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Stuck Detection and Emergency Abort System — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Build Loop Stuck Detection and Emergency Abort System

## Implementation Checklist
- [ ] Task 1: Add `detect_zero_progress()` function to `scripts/lib/loop-convergence.sh`
- [ ] Task 2: Add `_file_mtime_fingerprint()` and `_file_mtime_monitored()` helpers
- [ ] Task 3: Integrate zero-progress check in `sw-loop.sh` main loop (after ~line 2375)
- [ ] Task 4: Initialize `ZERO_PROGRESS_COUNT` at loop start in `sw-loop.sh`
- [ ] Task 5: Add `--zero-progress-threshold` CLI flag to argument parser
- [ ] Task 6: Add `--zero-progress-threshold` to help text
- [ ] Task 7: Add 7 structural tests to `sw-loop-test.sh`
- [ ] Task 8: Add E2E mock test (zero-progress agent triggers abort) to `sw-loop-test.sh`
- [ ] Task 9: Add counter-reset structural test to `sw-loop-test.sh`
- [ ] Task 10: Create `docs/BUILD-LOOP.md` with stuck detection documentation
- [ ] Task 11: Run `sw-loop-test.sh` and verify all tests pass
- [ ] Task 12: Run `sw-convergence-test.sh` to verify no regressions

## Context
- Pipeline: standard
- Branch: ci/build-loop-stuck-detection-and-emergency-284
- Issue: #284
- Generated: 2026-03-20T21:43:42Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Implement with testability first: state snapshots must be reproducible, mock stuck scenarios deterministically, and validate both detection accuracy and abort side effects

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
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-20T21:59:25Z
last_iteration_at: 2026-03-20T21:59:25Z
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
### Iteration 1 (2026-03-20T21:59:25Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":269759,"duration_api_ms":231792,"num_turns":34,"resu

