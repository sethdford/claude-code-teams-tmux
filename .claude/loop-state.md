---
goal: "Template Schema Validator for Pre-Execution Configuration Validation

## Plan Summary
Now I have all the context I need. Let me produce the implementation plan.

---

## Implementation Plan: Template Schema Validator

### Socratic Design Analysis

**Minimum viable change:** A single bash script (`sw-template-validate.sh`) that validates pipeline template JSON against known constraints, plus integration into `load_pipeline_config()` for fail-fast, plus a test suite.

**Implicit requirements:** The validator must handle all 9 existing templates without false positives. It must work with composed pipelines too (the intelligence layer output). It must not break when users add custom config fields (forward-compatible).

**Acceptance criteria (from issue + inferred):**
1. `shipwright template validate <file>` exits 0 for valid, 1 for invalid with clear error messages
2. Validates stage names against known set, gate values, timeout positivity, required fields
3. Pipeline startup calls validator before execution (fail-fast in `load_pipeline_config`)
4. All 9 built-in templates pass validation
5. Test suite covers valid templates, missing fields, bad types, unknown stages, bad gates, bad ordering

### Alternatives Considered
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Template Schema Validator for Pre-Execution Configuration Validation
## Context
## Decision
### Architecture
### Validation Rules
### Valid Stage IDs
### Valid Gate Values
### Error Accumulation Pattern
### Fail-Fast Integration
### CLI Interface
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Project structure and conventions directly needed for build: test_runner=vitest, source_dir=src/, test_pattern=*.test.js, import_style=commonjs. Critical for writing and organizing the template schema validator."
    },
    {
      "file": "failures.json",
      "relevance": 68,
      "summary": "Recent test failures show mktemp /tmp/claude directory issues (seen 8 times in last 24h). Relevant to understand test setup constraints and potential filesystem issues during validator testing."
    },
    {
      "file": "patterns.json",
      "relevance": 22,
      "summary": "Confirms Node.js project type detected on 2026-02-21. Low specificity compared to detailed patterns entry; redundant with first patterns.json which provides fuller configuration."
    },
    {
      "file": "metrics.json",
      "relevance": 8,
      "summary": "Empty baselines object. Not relevant to current build task; no performance baselines are recorded."
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "Empty decisions array. No architectural or implementation decisions recorded from previous work that would inform validator design."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Template Schema Validator for Pre-Execution Configuration Validation — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Template Schema Validator for Pre-Execution Configuration Validation

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-validation.sh` with core validation logic
- [ ] Task 2: Create `scripts/sw-template-validate.sh` CLI entry point
- [ ] Task 3: Add `template` command routing to `scripts/sw`
- [ ] Task 4: Integrate validator into `load_pipeline_config()` in `scripts/lib/pipeline-cli.sh`
- [ ] Task 5: Create `scripts/sw-template-validate-test.sh` test suite
- [ ] Task 6: Register test suite in `package.json`
- [ ] Task 7: Run all 9 built-in templates through validator to confirm no false positives
- [ ] Task 8: Run test suite and verify all tests pass

## Context
- Pipeline: standard
- Branch: feat/template-schema-validator-for-pre-execut-259
- Issue: #259
- Generated: 2026-03-14T20:36:44Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Design comprehensive test matrix covering: valid templates (by complexity), all validation failure modes (undefined stages, invalid gates, non-positive timeouts, missing required fields), boundary conditions, unicode/special chars.

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
max_iterations: 10
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-14T21:00:09Z
last_iteration_at: 2026-03-14T21:00:09Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-03-14T20:52:17Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":428765,"duration_api_ms":400121,"num_turns":43,"resu

### Iteration 2 (2026-03-14T21:00:09Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":313299,"duration_api_ms":267514,"num_turns":48,"resu

