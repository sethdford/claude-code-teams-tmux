---
goal: "Template Success Rate Tracking and Intelligence-Driven Recommendation Engine

## Plan Summary
Perfect! I've created a comprehensive implementation plan for the Template Success Rate Tracking and Intelligence-Driven Recommendation Engine. The plan is ready for your review.

## Plan Summary

I've analyzed the issue and created a detailed plan that includes:

### **Key Decision: Centralized SQLite Database** ✓
- Reuses existing `sw-db.sh` infrastructure
- Fast queries for dashboard and CLI
- Proper indexing for (project_type, template) lookups
- Atomic transactions prevent race conditions

### **Architecture Overview**
- **Data Collection**: Hook into pipeline completion to record (template, project_type, success, duration, cost)
- **Metrics Storage**: Two tables—`template_metrics` (aggregated) and `template_executions` (detailed log)
- **Recommendation Engine**: Scoring algorithm (50% success rate, 20% speed, 20% cost, 10% recency)
- **CLI Command**: `shipwright template recommend` with confidence scores
- **Daemon Integration**: Auto-template selection when `auto_template: true`
- **Dashboard Widget**: 7d/30d/90d success rate trends with sample counts
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Template Success Rate Tracking and Intelligence-Driven Recommendation Engine
## Context
## Decision
### Architecture: Three-layer system built on existing infrastructure
## Alternatives Considered
## Implementation Plan
### Files to create
### Files to modify
### Dependencies
### Risk areas
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 72,
      "summary": "Defines project structure (Node.js/vitest), source layout (src/), test patterns (*.test.js), and conventions. Critical for implementing template success rate tracking with correct test structure and imports."
    },
    {
      "file": "failures.json",
      "relevance": 48,
      "summary": "Documents recurring test failures in sw-cleanup.sh, sw-feedback-test.sh, and sw-hello-test.sh. Relevant because the feature tracks success rates—understanding known failure patterns informs baseline metrics and detection logic."
    },
    {
      "file": "patterns.json",
      "relevance": 16,
      "summary": "Simple project_type detection (nodejs) with timestamp. Redundant with more detailed first patterns.json entry; minimal value for build stage implementation."
    },
    {
      "file": "global.json",
      "relevance": 8,
      "summary": "Empty cross-repo learnings array. No actionable patterns or intelligence to inform template success rate tracking implementation."
    },
    {
      "file": "metrics.json",
      "relevance": 6,
      "summary": "Empty baselines object. No baseline metrics available to establish success rate thresholds or historical context."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Template Success Rate Tracking and Intelligence-Driven Recommendation Engine — Resolution: 

## Skill Guidance (backend issue, AI-selected)
## Data Pipeline Expertise

Apply these data engineering patterns:

### Schema Design
- Define schemas explicitly — never rely on implicit structure
- Use migrations for all schema changes (never manual ALTER TABLE)
- Add indexes for frequently queried columns
- Consider denormalization for read-heavy paths

### Data Integrity
- Use transactions for multi-step operations
- Implement idempotency keys for operations that could be retried
- Validate data at ingestion — reject bad data early
- Use constraints (NOT NULL, UNIQUE, FOREIGN KEY) in the database layer

### Query Patterns
- Avoid N+1 queries — use JOINs or batch loading
- Use EXPLAIN to verify query plans for complex queries
- Paginate large result sets — never SELECT * without LIMIT
- Use parameterized queries — never string concatenation for SQL

### Migration Safety
- Migrations must be reversible (include rollback steps)
- Test migrations on a copy of production data
- Add new columns as nullable, then backfill, then add NOT NULL
- Never drop columns in the same deploy as code changes

### Backpressure & Resilience
- Implement circuit breakers for external data sources
- Use dead letter queues for failed processing
- Set timeouts on all external calls
- Monitor queue depths and processing latency

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Schema Changes**: Full migration SQL with both forward and rollback scripts, plus data backfill strategy if required
2. **Data Flow Diagram**: Text diagram showing data ingestion → processing → output with failure points marked
3. **Idempotency Strategy**: How the system handles duplicate requests (idempotency keys, deduplication, side-effect safety)
4. **Rollback Plan**: Step-by-step process to revert schema changes and restore data consistency

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


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0

## Failure Diagnosis (Iteration 3)
Classification: unknown
Strategy: retry_with_context
Repeat count: 1"
iteration: 3
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-13T23:10:46Z
last_iteration_at: 2026-03-13T23:10:46Z
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
### Iteration 1 (2026-03-13T22:58:32Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":766823,"duration_api_ms":657934,"num_turns":67,"resu

### Iteration 2 (2026-03-13T23:03:57Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":4933,"duration_api_ms":240551,"num_turns":1,"result"

