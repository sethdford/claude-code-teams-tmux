---
goal: "Cost-Per-Issue Attribution Engine with ROI Dashboard and Budget Forecasting

## Plan Summary
The plan is complete. It covers:

- **Schema v7 migration** with `cost_attributions` table, FK to `pipeline_runs`, idempotency via UNIQUE constraint
- **7 files** to modify/create, **12 implementation tasks**, **12 test cases**
- **3 new CLI subcommands**: `analyze`, `roi`, `forecast`
- **2 new dashboard endpoints**: `/api/costs/roi`, `/api/costs/forecast`
- **Integration points**: pipeline stage completion + loop iteration token accumulation
- **Dual-write pattern** consistent with existing `cost_record()` approach
- **3 failure modes** analyzed with concrete mitigations
- **Full rollback plan** that leaves existing data untouched
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Cost-Per-Issue Attribution Engine with ROI Dashboard and Budget Forecasting
## Context
## Decision
### Architecture: 5 Components with Inward-Pointing Dependencies
### Component 1: Schema v7 Migration — `cost_attributions` Table
### Component 2: Attribution Engine — `scripts/lib/cost-attribution.sh`
# Record a cost attribution for a specific stage+iteration of an issue pipeline
# Idempotent: UNIQUE(job_id, stage, iteration) → INSERT OR REPLACE
# Returns: 0 on success, 1 on error
# Query per-issue cost breakdown
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Project structure baseline: Node.js/JavaScript, vitest test runner, npm package manager, CommonJS imports — directly describes the build environment for this task"
    },
    {
      "file": "failures.json",
      "relevance": 55,
      "summary": "Common JavaScript/Node.js build failures with mitigation data: uninitialized variables (100% fix rate), undefined references (66% fix rate) — actionable patterns to watch for in build stage"
    },
    {
      "file": "failures.json",
      "relevance": 50,
      "summary": "Generic JavaScript build errors with root causes and fixes: variable initialization, missing declarations — applicable guidance for cost-attribution-engine implementation"
    },
    {
      "file": "failures.json",
      "relevance": 45,
      "summary": "ENOENT/missing dependency pattern with npm install mitigation (95% effectiveness) — setup prerequisite for Node.js build"
    },
    {
      "file": "success-patterns.json",
      "relevance": 40,
      "summary": "Two similar-complexity patterns (60–65 complexity, 3 iterations, 2.5 USD cost) using standard template — baseline expectations for feature development in this repo"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Cost-Per-Issue Attribution Engine with ROI Dashboard and Budget Forecasting — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cost-Per-Issue Attribution Engine with ROI Dashboard and Budget Forecasting

## Implementation Checklist
- [ ] Task 1: Add `cost_attributions` table schema + indexes to `sw-db.sh` `init_schema()`
- [ ] Task 2: Add v6->v7 migration to `sw-db.sh` `migrate_schema()` and bump SCHEMA_VERSION to 7
- [ ] Task 3: Add `db_record_attribution()` and query functions to `sw-db.sh`
- [ ] Task 4: Create `scripts/lib/cost-attribution.sh` with recording, ROI, and forecasting functions
- [ ] Task 5: Integrate attribution recording into `scripts/lib/pipeline-commands.sh`
- [ ] Task 6: Integrate iteration-level attribution into `scripts/sw-loop.sh`
- [ ] Task 7: Add `analyze` and `forecast` CLI commands to `scripts/sw-cost.sh`
- [ ] Task 8: Add dashboard API endpoints to `dashboard/server.ts`
- [ ] Task 9: Create `scripts/sw-cost-attribution-test.sh` test suite
- [ ] Task 10: Extend `scripts/sw-db-test.sh` with attribution table tests
- [ ] Task 11: Register new test suite in `package.json` and run full test suite
- [ ] `cost_attributions` table exists in schema v7 with FK to `pipeline_runs`
- [ ] Pipeline stages record attribution after each stage completes
- [ ] Loop iterations record attribution after each iteration
- [ ] `shipwright cost analyze --issue N --breakdown` shows per-stage cost breakdown
- [ ] `shipwright cost analyze --roi` shows cost/success by template and complexity
- [ ] `shipwright cost forecast --template T --complexity C` returns estimated cost with confidence
- [ ] Dashboard serves `/api/costs/roi`, `/api/costs/forecast`, `/api/costs/attribution`
- [ ] All 17 new tests pass in `sw-cost-attribution-test.sh`
- [ ] Existing test suites still pass

## Context
- Pipeline: standard
- Branch: feat/cost-per-issue-attribution-engine-with-r-345
- Issue: #345
- Generated: 2026-04-03T18:40:18Z

## Skill Guidance (backend issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: Build comprehensive tests for cost attribution logic under diverse conditions: multi-iteration builds, model switches, stage skips, and budget exhaustion scenarios.

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
Repeat count: 0

## Failure Diagnosis (Iteration 3)
Classification: unknown
Strategy: retry_with_context
Repeat count: 1

## Failure Diagnosis (Iteration 4)
Classification: unknown
Strategy: alternative_approach
Repeat count: 2
INSTRUCTION: This error has occurred 2 times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements"
iteration: 4
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-04T01:37:21Z
last_iteration_at: 2026-04-04T01:37:21Z
consecutive_failures: 0
total_commits: 3
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-04-04T01:12:55Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":3656,"duration_api_ms":738553,"num_turns":1,"result"

### Iteration 2 (2026-04-04T01:21:25Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":378253,"duration_api_ms":295316,"num_turns":60,"resu

### Iteration 3 (2026-04-04T01:34:09Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":421428,"duration_api_ms":141419,"num_turns":21,"resu

