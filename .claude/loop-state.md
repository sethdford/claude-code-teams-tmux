---
goal: "Refactor - Decompose sw-loop.sh into Modular lib/loop-*.sh Components

## Plan Summary
Here is the complete implementation plan:

---

# Implementation Plan: Decompose sw-loop.sh into Modular lib/loop-*.sh Components

## Brainstorming: Design Analysis

### Requirements Clarity
**Minimum viable change:** Extract all functions from `sw-loop.sh` (currently 2,530 lines) into cohesive `lib/loop-*.sh` modules, leaving only CLI parsing, orchestration (`run_single_agent_loop`, `run_loop_with_restarts`, `main`), and signal handling in the main file. Target: < 800 lines in `sw-loop.sh`.

**Implicit requirements:** Module source ordering matters (tokens.sh must load before iteration.sh since `run_claude_iteration()` calls `accumulate_loop_tokens()` and `_extract_text_from_json()`). All global variables must remain accessible.

### Alternatives Considered

**Approach A: Minimal extraction (5 modules)** — Only create the modules explicitly named in the issue (iteration, convergence, context, restart, error-feedback). Most already exist. Adds ~1 new module.
- Pro: Minimal blast radius. Con: Won't hit < 800 line target — quality/audit/multi-agent code (~750 lines) stays in main file.

**Approach B: Full extraction (6 new modules)** — Extract ALL remaining function groups (tokens, error-feedback, quality, git, multi-agent, display) into dedicated modules.
- Pro: Achieves < 800 line target. Each module is independently testable. Matches pipeline/recruit refactor pattern. Con: More files, more source statements.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Refactor - Decompose sw-loop.sh into Modular lib/loop-*.sh Components
## Context
## Decision
### Chosen Approach: **Approach B — Full Extraction (6 new modules)**
### Module Responsibilities
## Alternatives Considered
### 1. Approach A: Minimal Extraction (5 modules)
### 2. Approach C: Aggressive Consolidation (3 new modules)
### 3. Approach D: Lazy Module Loading
## Component Diagram
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Recent test failures from shell scripts (sw-cleanup.sh, sw-feedback.sh, etc.) show common bugs in bash: sed expression handling, mktemp directory creation, JSON output validation. These patterns are directly applicable when refactoring sw-loop.sh to avoid similar pitfalls."
    },
    {
      "file": "patterns.json (first entry)",
      "relevance": 20,
      "summary": "Describes project as Node.js/JavaScript with vitest test runner. While Shipwright is Node-based, this entry focuses on JS conventions; shell script refactoring requires different patterns and practices."
    },
    {
      "file": "patterns.json (second entry)",
      "relevance": 10,
      "summary": "Generic project type detection indicating Node.js. Minimal actionable context for bash shell script refactoring work."
    },
    {
      "file": "patterns.json (third entry)",
      "relevance": 5,
      "summary": "Empty patterns cache from an unrelated test repo. No relevant information for this task."
    },
    {
      "file": "metrics.json",
      "relevance": 0,
      "summary": "Empty baselines container. No metrics or performance data relevant to refactoring."
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
- **testing-strategy**: New modular tests must achieve parity with existing test coverage; define test patterns for each lib/loop-*.sh component that exercise module boundaries and integration points.

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
max_iterations: 30
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-03-14T22:16:50Z
last_iteration_at: 2026-03-14T22:16:50Z
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

