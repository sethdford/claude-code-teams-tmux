---
goal: "Platform Self-Improvement Health Dashboard and Auto-Issue Generator

## Plan Summary
# Implementation Plan: Platform Self-Improvement Health Dashboard & Auto-Issue Generator

## Issue: #207

---

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A bash script (`sw-platform-health.sh`) that collects platform health metrics (hardcoded count, fallback count, TODO/FIXME/HACK counts, script sizes), stores snapshots as JSON, and exposes them via a dashboard API endpoint + frontend tab. An auto-issue generator function creates GitHub issues when thresholds are exceeded.

**Implicit requirements**:
- Must follow existing bash 3.2 conventions (`set -euo pipefail`, no `declare -A`)
- Must gate GitHub API calls behind `$NO_GITHUB`
- Must emit events via `emit_event()` for observability
- Must integrate with existing patrol system (called from daemon patrol cycle)
- Must store trend data for 7/30 day deltas (requires historical snapshots)

**Acceptance criteria** (from issue):
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Platform Self-Improvement Health Dashboard and Auto-Issue Generator
## Context
## Decision
### Component Diagram
### Data Flow (with failure points)
### Key Design Decisions
### Interface Contracts
### Error Contracts
## Alternatives Considered
## Implementation Plan
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {"file": "patterns.json", "relevance": 95, "summary": "Detailed project structure captured 2026-03-07: Node.js, vitest test runner, src/ source dir, commonjs imports, *.test.js pattern — essential conventions for building"},
    {"file": "patterns.json", "relevance": 70, "summary": "Node.js project type confirmation from bootstrap detection 2026-02-21, provides baseline context"},
    {"file": "failures.json", "relevance": 60, "summary": "Previous test failures (sw-cleanup.sh output format, intelligence classification wiring) inform what mistakes to avoid during build"},
    {"file": "metrics.json", "relevance": 5, "summary": "Baseline metrics currently empty, minimal relevance for build stage"},
    {"file": "decisions.json", "relevance": 5, "summary": "Decision log empty, no prior decisions available to inform current work"}
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Platform Self-Improvement Health Dashboard and Auto-Issue Generator — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Platform Self-Improvement Health Dashboard and Auto-Issue Generator

## Implementation Checklist
- [ ] Task 1: Create `sw-platform-health.sh` with `platform_health_scan` and `platform_health_snapshot` functions
- [ ] Task 2: Add `platform_health_trends` and `platform_health_alerts` for 7/30 day deltas and threshold checking
- [ ] Task 3: Add `platform_health_auto_issue` with GitHub dedup and `NO_GITHUB` gating
- [ ] Task 4: Add CLI subcommands (`scan`, `show`, `json`, `auto-issue`, `history`) and terminal display
- [ ] Task 5: Add `GET /api/platform-health` endpoint to `dashboard/server.ts`
- [ ] Task 6: Add "Platform Health" tab with charts to `dashboard/public/index.html`
- [ ] Task 7: Integrate auto-issue into `sw-patrol-meta.sh` patrol cycle
- [ ] Task 8: Feed platform health snapshot into `sw-strategic.sh` context
- [ ] Task 9: Add `platform-health` route in `scripts/sw` CLI router and register test in `package.json`
- [ ] Task 10: Write comprehensive test suite `sw-platform-health-test.sh`
- [ ] Task 11: Run `npm test` and fix any test failures
- [ ] `shipwright platform-health scan` outputs valid JSON with hardcoded_count, fallback_count, todo/fixme/hack counts, top 10 scripts
- [ ] `shipwright platform-health show` displays formatted terminal output
- [ ] `GET /api/platform-health` returns JSON matching the endpoint spec (tested with curl)
- [ ] Dashboard "Platform Health" tab renders with debt trend chart, script size table, alert cards
- [ ] Auto-issue generator creates GitHub issues when thresholds exceeded (hardcoded > 50, script > 3000 lines, debt_trend_7d > +5)
- [ ] Issues have title "Platform Self-Improvement: [area]", labels `platform`, `technical-debt`
- [ ] Dedup prevents duplicate issues for same alert condition
- [ ] `NO_GITHUB=true` gracefully skips issue creation
- [ ] Platform health data appears in strategic agent context

## Context
- Pipeline: standard
- Branch: feat/platform-self-improvement-health-dashboa-207
- Issue: #207
- Generated: 2026-03-07T03:09:20Z

## Skill Guidance (backend issue, AI-selected)
## API Design Expertise

Apply these API design patterns:

### RESTful Conventions
- Use nouns for resources, HTTP verbs for actions (GET /users, POST /users, DELETE /users/:id)
- Return appropriate status codes: 200 OK, 201 Created, 400 Bad Request, 404 Not Found, 422 Unprocessable
- Use consistent error response format: `{ "error": { "code": "...", "message": "..." } }`
- Version APIs when breaking changes are needed (/v1/users, /v2/users)

### Request/Response Design
- Accept and return JSON (Content-Type: application/json)
- Use camelCase for JSON field names
- Include pagination for list endpoints (limit, offset or cursor)
- Support filtering and sorting via query parameters

### Input Validation
- Validate ALL input at the API boundary — never trust client data
- Return specific validation errors with field names
- Sanitize strings against injection (SQL, XSS, command injection)
- Set reasonable size limits on request bodies

### Error Handling
- Never expose stack traces or internal errors to clients
- Log full error details server-side
- Use consistent error codes that clients can programmatically handle
- Include request-id in responses for debugging

### Authentication & Authorization
- Verify auth on EVERY endpoint (don't rely on frontend-only checks)
- Use principle of least privilege for authorization
- Validate tokens/sessions on each request
- Rate limit sensitive endpoints (login, password reset)

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Endpoint Specification**: For each endpoint: HTTP method, path, request body schema, response schema, success/error status codes
2. **Error Codes**: Complete list of all possible error responses with status code and error message format
3. **Rate Limiting**: If applicable, specify rate limit strategy (requests per minute, burst limits, throttle behavior)
4. **Versioning**: API version number and deprecation policy if breaking changes are possible

If any section is not applicable, explicitly state why it's skipped.
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
"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-07T03:18:04Z
last_iteration_at: 2026-03-07T03:18:04Z
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

