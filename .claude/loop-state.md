---
goal: "Refactor - Decompose sw-loop.sh into Modular lib/loop-*.sh Components

## Plan Summary
## Implementation Plan Summary

I've created a detailed implementation plan for decomposing **sw-loop.sh** (2,530 lines) into 8 modular components. The plan is saved at `/home/runner/.claude/projects/-home-runner-work-shipwright-shipwright/plan.md`

### Key Highlights

**🎯 Goal**: Reduce main sw-loop.sh from 2,530 → <800 lines while preserving 100% behavior

**📦 8 New Modules to Extract**:
1. `loop-cli.sh` — Argument parsing and help display
2. `loop-models.sh` — Model selection (adaptive/audit)
3. `loop-testing.sh` — Test execution and validation
4. `loop-quality.sh` — Quality gates, audit agent, DoD checking
5. `loop-prompt.sh` — Prompt composition for workers
6. `loop-multi-agent.sh` — Multi-agent orchestration
7. `loop-circuit-breaker.sh` — Budget gates and stuckness detection
8. `loop-output.sh` — Display, formatting, summary

**✅ Existing 8 Modules** (already extracted, 2,034 lines):
- loop-iteration.sh, loop-convergence.sh, loop-error-feedback.sh, loop-tokens.sh, loop-restart.sh, loop-progress.sh, loop-git.sh, loop-display.sh
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Refactor - Decompose sw-loop.sh into Modular lib/loop-*.sh Components
## Context
## Decision
### Phased approach: integrate existing modules first, then extract new ones
### Why NOT follow the plan's 8 new modules
### Module source order
# ─── Foundation (no inter-module deps) ────────────────────────
# ─── Mid-tier (depends on foundation) ────────────────────────
# ─── High-tier (depends on mid-tier) ─────────────────────────
### Component Diagram
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 72,
      "summary": "Contains actual test failure patterns from Shipwright scripts including bash/sed issues. Directly relevant to understanding test patterns and common bash scripting problems that may affect sw-loop.sh decomposition and its new modular components"
    },
    {
      "file": "patterns.json",
      "relevance": 48,
      "summary": "Shows project structure (Node.js, vitest, npm, commonjs imports). Relevant for understanding test conventions and patterns that would apply to new test files for the modular lib/loop-*.sh components"
    },
    {
      "file": "patterns.json",
      "relevance": 18,
      "summary": "Confirms Node.js project detection. Minimal relevance—only confirms project type already known from other memory entries"
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Empty baselines object. Not relevant to the refactoring task"
    },
    {
      "file": "decisions.json",
      "relevance": 3,
      "summary": "Empty decisions array. Not relevant to the refactoring task"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Refactor - Decompose sw-loop.sh into Modular lib/loop-*.sh Components — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Refactor - Decompose sw-loop.sh into Modular lib/loop-*.sh Components

## Implementation Checklist
- [ ] Task 1: Create `lib/loop-tokens.sh` — extract token tracking, cost, adaptive model, budget gate functions
- [ ] Task 2: Create `lib/loop-error-feedback.sh` — extract diagnose_failure, run_test_gate, write_error_summary
- [ ] Task 3: Create `lib/loop-quality.sh` — extract audit agent, quality gates, DoD, guard_completion, holistic gate, compose_audit_* functions
- [ ] Task 4: Create `lib/loop-git.sh` — extract git helpers and validate_claude_output
- [ ] Task 5: Create `lib/loop-multi-agent.sh` — extract worktree setup, worker script generation, multi-agent launch/wait/cleanup
- [ ] Task 6: Create `lib/loop-display.sh` — extract show_banner and show_summary
- [ ] Task 7: Update `sw-loop.sh` — remove extracted functions, add source statements for new modules, verify < 800 lines
- [ ] Task 8: Run existing `sw-loop-test.sh` to verify zero regressions
- [ ] Task 9: Create unit test files for all 6 new modules
- [ ] Task 10: Register new test suites in `package.json`
- [ ] Task 11: Update CLAUDE.md architecture section with new module structure
- [ ] Task 12: Run full test suite (`npm test`) — all tests pass
- [ ] `sw-loop.sh` is under 800 lines (target) — orchestration only
- [ ] All 6 new `lib/loop-*.sh` modules exist with module guards
- [ ] Every function previously in sw-loop.sh is in exactly one module (no duplication)
- [ ] Existing `sw-loop-test.sh` passes with zero modifications
- [ ] 6 new test files created and registered in `package.json`
- [ ] All new tests pass
- [ ] `npm test` (full suite) passes
- [ ] No behavior change — pure refactor (identical function signatures and global variable usage)

## Context
- Pipeline: standard
- Branch: refactor/refactor-decompose-sw-loop-sh-into-modul-276
- Issue: #276
- Generated: 2026-03-14T22:06:35Z

## Skill Guidance (refactor issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Design test structure that validates both module contracts (unit tests per lib/loop-*.sh) and integration behavior to catch subtle bugs from function extraction and module coupling.
- **systematic-debugging**: If extraction reveals unexpected behavior, apply structured investigation rather than guessing—capture error signatures, trace state flow across module boundaries, identify root causes in interdependencies.

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


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 30
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-15T02:03:57Z
last_iteration_at: 2026-03-15T02:03:57Z
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
### Iteration 1 (2026-03-15T01:33:54Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":1184748,"duration_api_ms":1067808,"num_turns":116,"r

