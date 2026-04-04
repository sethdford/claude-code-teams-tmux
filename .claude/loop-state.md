---
goal: "Fallback Pattern Eliminator with Config Migration and Safety Validation

## Plan Summary
The plan has been fully analyzed and designed. Here's the complete implementation plan summary:

---

# Fallback Pattern Eliminator — Implementation Plan

## Approach
**Extend existing `config.sh` + `defaults.json`** — the simplest approach that builds on the existing 4-level config precedence chain (env > daemon-config > policy > defaults).

## 15 Files Touched (3 new, 12 modified)

### New Files
| File | Purpose |
|------|---------|
| `config/defaults.schema.json` | JSON Schema Draft-07 for defaults.json validation |
| `scripts/sw-config-validate-test.sh` | 10+ test cases for config validation |
| `docs/migration-guide-fallback-config.md` | Operator migration guide with key mapping |

### Modified Files
| File | Change |
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Fallback Pattern Eliminator with Config Migration and Safety Validation
## Context
## Decision
### 1. Centralize 34 fallback values into `config/defaults.json`
# Before: bypasses config chain, default hidden in source
# After: env override preserved, config chain consulted, defaults.json is single source of truth
### 2. Add JSON Schema validation (`config/defaults.schema.json`)
### 3. Add `_config_validate()` and `_config_validate_file()` to `scripts/lib/config.sh`
### New config keys added to `defaults.json`
## Component Diagram
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains build-stage failures for uninitialized variables ('cannot read property of undefined' with 100% fix effectiveness) and missing declarations ('referenceerror is not defined' with 66% effectiveness). Directly applicable to build phase debugging."
    },
    {
      "file": "failures.json",
      "relevance": 90,
      "summary": "EONENT 'no such file directory' error with npm install fix (95% effectiveness). Critical for build-stage setup and dependency installation validation."
    },
    {
      "file": "patterns.json",
      "relevance": 85,
      "summary": "Project configuration baseline (Node.js, vitest, npm, CommonJS imports, src/ source dir). Essential for understanding build environment and toolchain setup."
    },
    {
      "file": "success-patterns.json",
      "relevance": 72,
      "summary": "Captured success pattern for similar complexity work (complexity 60, standard template, 3 iterations, npm test strategy). Provides reference iteration strategy and timeline expectations."
    },
    {
      "file": "failures.json",
      "relevance": 65,
      "summary": "Test-stage failures with patterns for variable initialization and property access (sw-cleanup.sh stale heartbeat detection). Variable initialization patterns are applicable to build-phase debugging."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Fallback Pattern Eliminator with Config Migration and Safety Validation — Resolution: 

## Skill Guidance (refactor issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Config migration requires comprehensive test coverage for both the validation logic (catches real config errors) and fallback behavior (graceful degradation still works).
- **documentation**: Operators with custom configs need a clear, step-by-step migration guide showing how their existing hardcoded fallbacks map to the new schema and what config changes are required.

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

## Documentation Expertise

For documentation-focused issues, apply a lightweight approach:

### Scope
- Focus on accuracy over comprehensiveness
- Update only what's actually changed or incorrect
- Remove outdated information rather than marking it deprecated
- Keep examples current and runnable

### Writing Style
- Use active voice and present tense
- Lead with the most important information
- Use code examples for anything technical
- Keep paragraphs short — 2-3 sentences max

### Structure
- Start with a one-line summary of what this documents
- Include prerequisites and setup if applicable
- Provide a quick start / most common usage first
- Put advanced topics and edge cases later

### Skip Heavy Stages
This is a documentation change. The following pipeline stages can be simplified:
- **Design stage**: Skip — documentation doesn't need architecture design
- **Build stage**: Focus on file edits only, no compilation needed
- **Test stage**: Verify links work and examples are syntactically correct
- **Review stage**: Focus on accuracy and clarity, not code patterns

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **What to Document**: List of documentation files created/modified with specific sections added to each
2. **What to Skip**: Explicitly state which topics are NOT documented and why (e.g., "Advanced topic X is out of scope for this issue")
3. **Audience**: Who will read this documentation (developers, users, operators) and what level of detail is appropriate

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-04T01:17:21Z
last_iteration_at: 2026-04-04T01:17:21Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-04-04T01:17:21Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":801624,"duration_api_ms":721301,"num_turns":100,"res

