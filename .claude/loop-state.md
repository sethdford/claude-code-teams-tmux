---
goal: "Build Loop Hardcoded Policy Extraction - Move Tunables to Config

## Plan Summary
The plan is complete. Key decisions:

1. **Extend existing `config/defaults.json`** rather than creating a new file — the config library already reads from it and there's an existing `loop` section with 8 keys
2. **35+ hardcoded values identified**, plan targets 15+ highest-impact ones for extraction
3. **Zero new files** — everything is an extension of existing patterns (`_config_get`, `defaults.json`, `daemon-config.json`)
4. **Precedence preserved:** CLI flag > env var > daemon-config.json > policy.json > defaults.json
5. **10 tasks** covering config schema, loader function, value replacement, show-config, and testing
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Build Loop Hardcoded Policy Extraction - Move Tunables to Config
## Context
## Decision
### 1. Extend `config/defaults.json` with 15+ new keys under `loop`
### 2. Replace hardcoded values with `_config_get_int` / `_config_get` calls
# Before (sw-loop.sh:106)
# After
### 3. Add `--show-config` flag to `sw-loop.sh`
### 4. Preserve full precedence chain
### 5. Convergence scoring: config-driven, not policy-driven
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 85,
      "summary": "Contains 4 known test failure patterns with root causes and fixes. Directly applicable to build stage to avoid regressions and fix common issues in sw-cleanup.sh, sw-feedback.sh, sw-hello-test.sh, and sw-daemon.sh"
    },
    {
      "file": "patterns.json",
      "relevance": 72,
      "summary": "Detailed project conventions (vitest test runner, CommonJS imports, src/ structure, *.test.js pattern) are essential for build stage to understand testing setup and code organization"
    },
    {
      "file": "patterns.json",
      "relevance": 38,
      "summary": "Generic bootstrap project type detection (nodejs). Less specific than detailed patterns entry; provides minimal build-stage guidance"
    },
    {
      "file": "decisions.json",
      "relevance": 8,
      "summary": "Empty decisions array. No captured decision context to inform the build stage"
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Empty baselines object. No performance or quality metrics to guide optimization during build"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Hardcoded Policy Extraction - Move Tunables to Config — Resolution: 

## Skill Guidance (refactor issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Comprehensive test coverage is critical for core sw-loop.sh modifications—unit tests for config loading/fallback behavior, integration tests for override hierarchy, and regression tests to ensure build loop behavior is unchanged.

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
started_at: 2026-03-10T16:53:43Z
last_iteration_at: 2026-03-10T16:53:43Z
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

