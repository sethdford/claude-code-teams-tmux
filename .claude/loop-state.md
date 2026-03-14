---
goal: "Shipwright Quickstart - One-Command Setup for Standard Projects

## Plan Summary
Now I have all the context needed. Let me create the implementation plan.

---

# Implementation Plan: `shipwright quickstart`

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A single `scripts/sw-quickstart.sh` that detects project type, runs `sw-init.sh` + `sw-prep.sh` + `sw-doctor.sh` in sequence with progress indicators, plus CLI routing and a test suite.

**Implicit requirements**: 
- Must work outside a git repo (init is global, prep requires git — handle gracefully)
- Should not re-run init if already set up (idempotent)
- Must handle `--help`/`--version` like every other script
- Needs to respect `$NO_GITHUB` for offline use

### Alternatives Considered
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# ADR: Shipwright Quickstart — One-Command Setup for Standard Projects
## Context
## Decision
### Data Flow
### Component Diagram
## Interfaces & Contracts
### `detect_project_type()`
# Input: None (reads filesystem in CWD)
# Output: Prints three space-separated values to stdout
#   $1 = project_type (string: "nodejs", "python", "go", "rust", "ruby", "java", "unknown")
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains 6 specific test failures with root causes and fixes (sw-cleanup.sh dry-run output, sw-feedback-test.sh JSON output, mktemp /tmp/claude directory, sed flag issue, stale heartbeat detection, fork resource exhaustion). Critical for build stage to avoid/handle known test failures."
    },
    {
      "file": "patterns.json (first)",
      "relevance": 88,
      "summary": "Contains project conventions from Shipwright repo: source_dir (src/), test_runner (vitest), test_pattern (*.test.js), package_manager (npm), language (javascript), import style (commonjs). Essential for configuring build/test environment."
    },
    {
      "file": "patterns.json (second)",
      "relevance": 55,
      "summary": "Project type detection (nodejs) from bootstrap. Provides basic type confirmation but lacks detailed conventions needed for build setup."
    },
    {
      "file": "metrics.json",
      "relevance": 15,
      "summary": "Contains empty baselines object. Minimal utility for build stage context."
    },
    {
      "file": "patterns.json (third)",
      "relevance": 8,
      "summary": "Contains empty patterns from test_repo (wrong repository). Not applicable to Shipwright build context."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Shipwright Quickstart - One-Command Setup for Standard Projects — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Shipwright Quickstart - One-Command Setup for Standard Projects

## Implementation Checklist
- [ ] Task 1: Create `scripts/sw-quickstart.sh` with boilerplate (shebang, VERSION, helpers, show_help, main)
- [ ] Task 2: Implement `detect_project_type()` function with all 6 project type detectors
- [ ] Task 3: Implement `check_init_needed()` function
- [ ] Task 4: Implement `run_phase()` timing wrapper and phase orchestration in `main()`
- [ ] Task 5: Implement summary output with total elapsed time and phase results
- [ ] Task 6: Add `quickstart` routing to `scripts/sw` CLI router
- [ ] Task 7: Add `quickstart` to help text in `scripts/sw`
- [ ] Task 8: Create `scripts/sw-quickstart-test.sh` with all test cases
- [ ] Task 9: Register test in `package.json` test chain
- [ ] Task 10: Run test suite and fix any failures
- [ ] Task 11: Add quickstart entry to CLAUDE.md command tables
- [ ] `shipwright quickstart` runs all 3 phases (init → prep → doctor) end-to-end
- [ ] Auto-detects Node.js, Python, Go, Rust, Ruby, Java projects
- [ ] Idempotent — skips init if already set up
- [ ] Handles non-git-repo gracefully (runs init only)
- [ ] Shows progress indicators and timing for each phase
- [ ] `--help`, `--version`, `--skip-init`, `--skip-prep`, `--skip-doctor`, `--force` flags work
- [ ] Test suite passes with all 16 tests green
- [ ] CLI router dispatches `shipwright quickstart` correctly
- [ ] Completes in <5 minutes on standard repos (init skipped if present)

## Context
- Pipeline: standard
- Branch: feat/shipwright-quickstart-one-command-setup-269
- Issue: #269
- Generated: 2026-03-14T21:37:41Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Six supported project types (Node/Python/Go/Rust/Ruby/Java) require a structured test matrix; need fast/slow test splits and clear coverage goals before implementation starts.

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
model: haiku
agents: 1
started_at: 2026-03-14T21:40:38Z
last_iteration_at: 2026-03-14T21:40:38Z
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

