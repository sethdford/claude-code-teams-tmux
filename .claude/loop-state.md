---
goal: "Pipeline Outcome Tracking Dashboard with 7d/30d Success Rate Trend and Alert Threshold

## Plan Summary
Now I have everything I need. Let me write the implementation plan.

---

# Implementation Plan: Pipeline Outcome Tracking Dashboard

## Socratic Design Analysis

### Requirements Clarity
- **Minimum viable change**: Add a success rate widget to the overview tab that computes 7d/30d rates from existing `pipeline.completed` events, shows trend arrow, color-codes status, and triggers alert on degradation.
- **Implicit requirements**: Real-time updates via existing WebSocket push (no polling), breakdown drill-down, consecutive failure count.
- **Acceptance criteria**: Defined in issue — 7d/30d rates, trend indicator, alert badge, click-to-expand breakdown.

### Alternatives Considered

**Approach A: Compute success rates in `getFleetState()` and push via WebSocket (CHOSEN)**
- Pros: Real-time updates for free (2s push cycle), no additional API calls, stays in sync with existing metrics
- Cons: Adds ~20 lines of computation to each push cycle
- Blast radius: Extends `FleetState` interface (additive), new HTML widget, new renderer function
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Pipeline Outcome Tracking Dashboard with 7d/30d Success Rate Trend and Alert Threshold
## Context
## Decision
### Component Diagram
### Data Flow
### Interface Contracts
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {"file": "patterns.json (first entry)", "relevance": 75, "summary": "Defines Node.js project structure (vitest test runner, src/ source dir, commonjs imports) essential for understanding build/test pipeline for the dashboard feature"},
    {"file": "patterns.json (second entry)", "relevance": 65, "summary": "Confirms Node.js project type and bootstrap metadata relevant to build stage configuration"},
    {"file": "failures.json", "relevance": 45, "summary": "Shows common test failure patterns (mktemp errors, test output issues) that may recur during dashboard build/test stages"},
    {"file": "metrics.json", "relevance": 8, "summary": "Empty baselines object provides minimal context for outcome tracking"},
    {"file": "decisions.json", "relevance": 5, "summary": "Empty decisions array; no relevant prior architectural decisions captured"}
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pipeline Outcome Tracking Dashboard with 7d/30d Success Rate Trend and Alert Threshold — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Pipeline Outcome Tracking Dashboard with 7d/30d Success Rate Trend and Alert Threshold

## Implementation Checklist
- [ ] Task 1: Add `SuccessRateInfo` interface to `dashboard/types/index.ts` and `dashboard/src/types/api.ts`, extend FleetState
- [ ] Task 2: Implement `computeSuccessRate()` function in `dashboard/server.ts`
- [ ] Task 3: Wire `computeSuccessRate()` into `getFleetState()` return value
- [ ] Task 4: Add success rate widget HTML container to `dashboard/public/index.html`
- [ ] Task 5: Add CSS styles for success rate widget, trend arrows, alert badge, and breakdown panel
- [ ] Task 6: Implement `renderSuccessRate()` in `dashboard/src/views/overview.ts`
- [ ] Task 7: Add breakdown drill-down (click to expand per-template table)
- [ ] Task 8: Build the TypeScript bundle (`dashboard/public/dist/main.js`)
- [ ] Task 9: Write test suite for success rate computation and widget behavior
- [ ] Task 10: Manual verification — simulate pipeline outcomes, verify widget updates and alert triggers
- [ ] Overview tab shows success rate widget with 7d and 30d rates
- [ ] Trend indicator shows correct arrow (up/down/stable) based on ±5% threshold
- [ ] Color coding: green >80%, amber 60-80%, rose <60%
- [ ] Alert badge appears when `rate_7d < (rate_30d - 20%)` OR `rate_7d == 0%` with activity
- [ ] Consecutive failure count displayed
- [ ] Widget updates in real-time via WebSocket (no manual refresh)
- [ ] Click shows breakdown by template with success/fail counts
- [ ] All tests pass (`npm test`)
- [ ] TypeScript compiles without errors

## Context
- Pipeline: standard
- Branch: feat/pipeline-outcome-tracking-dashboard-with-252
- Issue: #252
- Generated: 2026-03-11T00:48:29Z

## Skill Guidance (backend issue, AI-selected)
## Systematic Debugging: Root Cause Analysis

A previous attempt at this stage FAILED. Do NOT blindly retry the same approach. Follow this 4-phase investigation:

### Phase 1: Evidence Collection
- Read the error output from the previous attempt carefully
- Identify the EXACT line/file where the failure occurred
- Check if the error is a symptom or the root cause
- Look for patterns: is this a known error type?

### Phase 2: Hypothesis Formation
- List 3 possible root causes for this failure
- For each hypothesis, identify what evidence would confirm or deny it
- Rank hypotheses by likelihood

### Phase 3: Root Cause Verification
- Test the most likely hypothesis first
- Read the relevant source code — don't guess
- Check if previous artifacts (plan.md, design.md) are correct or flawed
- If the plan was correct but execution failed, focus on execution
- If the plan was flawed, document what was wrong

### Phase 4: Targeted Fix
- Fix the ROOT CAUSE, not the symptom
- If the previous approach was fundamentally wrong, choose a different approach
- If it was a minor error, make the minimal fix
- Document what went wrong and why the new approach is better

IMPORTANT: If you find existing artifacts from a successful previous stage, USE them — don't regenerate from scratch.

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Root Cause Hypothesis**: List 3 possible root causes ranked by likelihood with specific evidence that would confirm/deny each
2. **Evidence Gathered**: Exact file:line location of failure, error messages, logs, code examination results, artifact validation (plan.md, design.md correctness)
3. **Fix Strategy**: Description of the ROOT CAUSE fix (not the symptom), with rationale for why this approach differs from the previous failed attempt
4. **Verification Plan**: How to verify the fix works (test cases, specific checks, expected behavior confirmation)

If any section is not applicable, explicitly state why it's skipped.
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
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-11T00:54:45Z
last_iteration_at: 2026-03-11T00:54:45Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

