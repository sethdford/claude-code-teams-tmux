---
goal: "Build Loop Goal Achievement Verification Checkpoint System

## Plan Summary
# Build Loop Goal Achievement Verification Checkpoint System — Implementation Plan

## Overview
This plan implements an explicit goal verification checkpoint system in the Shipwright build loop that reduces iteration waste and prevents "iteration exhaustion" failures. Checkpoints inject a verification prompt every N iterations (default: 3), asking the agent to confirm goal achievement before continuing.

---

## Component Diagram

```
┌────────────────────────────────────────────────────────────────┐
│                      sw-loop.sh (main loop)                    │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  ITERATION = 1 → MAX_ITERATIONS                        │  │
│  │                                                        │  │
│  │  Every N iterations (goal_check_interval):            │  │
│  │    ├─ Read current iteration count                    │  │
│  │    ├─ Check if (ITERATION % goal_check_interval)==0   │  │
│  │    ├─ Yes: Inject checkpoint prompt                  │  │
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions

[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Test failure patterns and root causes directly inform checkpoint verification requirements. Shows common failure modes (missing output, JSON formatting, file creation) that the checkpoint system must detect and report."
    },
    {
      "file": "patterns.json (first entry)",
      "relevance": 75,
      "summary": "Project conventions (vitest test runner, src/ directory, *.test.js pattern, CommonJS imports) define where checkpoint verification logic should be integrated and what test format expectations are."
    },
    {
      "file": "patterns.json (second entry)",
      "relevance": 10,
      "summary": "Minimal project type metadata (Node.js, detected via bootstrap). Provides basic context but limited detail compared to first patterns.json entry."
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "Empty decisions array; no prior architectural decisions captured. Could be relevant if populated with build loop strategy decisions."
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Empty baselines dict. Would be relevant for establishing success criteria for goal achievement verification, but currently unpopulated."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Goal Achievement Verification Checkpoint System — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Build Loop Goal Achievement Verification Checkpoint System

## Implementation Checklist
- [ ] Checkpoint configuration helpers (`get_goal_check_config()`, `is_goal_check_enabled()`) added to sw-loop.sh
- [ ] Checkpoint injection function (`inject_goal_checkpoint()`) added
- [ ] Checkpoint prompt builder (`build_checkpoint_prompt()`) added
- [ ] Response parser (`parse_goal_checkpoint_response()`) added
- [ ] State variables (`GOAL_CHECK_ENABLED`, `GOAL_CHECK_INTERVAL`, `GOAL_REACHED`, `CHECKPOINT_TRIGGERED`) added
- [ ] Initialization function (`init_goal_checkpoint_system()`) called at script startup
- [ ] Main loop modified to: check for checkpoint, inject prompt, parse response
- [ ] LOOP_COMPLETE logic extended to handle GOAL_ACHIEVED signal
- [ ] CLI flags added: `--goal-check-interval N`
- [ ] daemon-config.json updated with `loop.goal_check_interval` schema (default: 3)
- [ ] Checkpoint injection at multiples of 3 (and custom intervals)
- [ ] Checkpoint skipped before iteration 2
- [ ] GOAL_ACHIEVED signal detection
- [ ] Early loop exit on goal achieved
- [ ] Configuration loading (defaults, overrides, invalid values)
- [ ] Prompt content verification (includes goal, context, signal instruction)
- [ ] All 10+ test cases in sw-loop-test.sh passing
- [ ] CLAUDE.md "Build Loop Capabilities" section updated
- [ ] Checkpoint feature described with example usage
- [ ] Configuration documented: `loop.goal_check_interval`, `SW_GOAL_CHECK_INTERVAL` env var

## Context
- Pipeline: standard
- Branch: arch/build-loop-goal-achievement-verification-268
- Issue: #268
- Generated: 2026-03-14T18:22:47Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **systematic-debugging**: If checkpoint injection creates unexpected loop behavior, use structured investigation rather than blind retries; log decision points, checkpoint verdicts, and agent responses to diagnose failures.
- **testing-strategy**: Design tests covering checkpoint timing (iteration 1, mid-checkpoint, at exhaustion), config validation (invalid intervals), and verdict accuracy (goal truly achieved vs. false positive).

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
started_at: 2026-03-14T18:30:20Z
last_iteration_at: 2026-03-14T18:30:20Z
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

