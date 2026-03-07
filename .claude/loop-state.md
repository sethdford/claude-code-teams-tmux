---
goal: "Post-Merge Production Feedback Integration and Regression Learning

## Plan Summary


All three background research agents have completed. The plan at `.claude/plan.md` is finalized with comprehensive understanding of all integration points across memory, intelligence, feedback, webhook, event bus, dashboard, and pipeline systems. Ready for the build stage.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Post-Merge Production Feedback Integration and Regression Learning
## Context
## Decision
## Alternatives Considered
### Alternative A: Extend `sw-webhook.sh` to Handle Post-Merge Events
### Alternative B: New `sw-post-merge-monitor.sh` + Thin Integration Points (CHOSEN)
### Alternative C: Extend `sw-feedback.sh` with `monitor` Subcommand
## Implementation Plan
### Files to Create
### Files to Modify
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Documents known test failures (sw-cleanup.sh output, sw-daemon.sh classify_failure, sw-hygiene.sh exit code) with fixes. Critical for build stage to avoid reintroducing same bugs and guide test debugging."
    },
    {
      "file": "patterns.json",
      "relevance": 92,
      "summary": "Project structure and conventions (vitest test runner, npm, source_dir=src/, test_pattern=*.test.js, commonjs imports). Essential for running build and test stages correctly."
    },
    {
      "file": "patterns.json",
      "relevance": 15,
      "summary": "Generic project_type detection (nodejs, bootstrap source). Redundant with detailed patterns.json entry; minimal actionable value for build stage."
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Empty baseline metrics. No prior performance data to guide optimization or detect regressions in build stage."
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "Empty decisions log. No prior architectural or implementation decisions captured to inform build decisions."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Post-Merge Production Feedback Integration and Regression Learning — Resolution: 

## Skill Guidance (backend/infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **observability**: Monitor the feedback system itself post-deployment: webhook processing lag, memory/intelligence update latency, regression detection accuracy, false positive trends.
- **testing-strategy**: Complex distributed flow requires both unit tests (webhook parsing, event creation) and integration tests per AC (merge → CI failure → regression event → memory updated).

## Observability: Watch the Deploy Like a Hawk

Post-deploy monitoring catches what tests miss. Real traffic reveals real problems.

### What to Monitor (by Priority)

**P0 — Immediate (first 5 minutes):**
- Error rate: any increase over baseline?
- Health check: still returning 200?
- Latency: p50/p95/p99 within normal range?
- Memory/CPU: any sudden spikes?

**P1 — Short-term (5-30 minutes):**
- Business metrics: are users completing key flows?
- Queue depths: are background jobs processing normally?
- Connection pools: any exhaustion or leak patterns?
- Disk usage: any unexpected growth?

**P2 — Medium-term (1-24 hours):**
- Memory trends: gradual leak over time?
- Error rate trends: slowly increasing?
- User-reported issues: any new support tickets?
- Performance degradation under sustained load?

### Anomaly Detection Patterns
- **Spike detection**: >2x baseline error rate in any 1-minute window
- **Trend detection**: steadily increasing error rate over 5-minute window
- **Absence detection**: expected periodic events stop occurring
- **Latency shift**: p95 latency increases >50% from baseline

### Log Analysis
- Search for new ERROR/FATAL/PANIC entries not present before deploy
- Check for stack traces — they indicate unhandled exceptions
- Look for retry storms — repeated failed attempts at the same operation
- Monitor for resource exhaustion messages (OOM, connection refused, disk full)

### Auto-Rollback Triggers
Automatically rollback if ANY of these occur:
- Health check fails 3 consecutive times
- Error rate exceeds threshold for 2+ minutes
- Critical service dependency becomes unreachable
- Memory usage exceeds 90% of limit

### Monitoring by Issue Type

**Frontend changes:**
- JavaScript error rates in browser (if client-side monitoring exists)
- Asset load failures (404s on new bundles)
- Core Web Vitals regression (LCP, FID, CLS)

**API changes:**
- Response status code distribution (2xx vs 4xx vs 5xx)
- Request throughput — drops indicate client-side breakage
- Authentication failures — spikes indicate auth regression

**Database changes:**
- Query latency per endpoint
- Connection pool utilization
- Slow query log entries
- Replication lag (if applicable)

### Incident Escalation
If monitoring detects issues:
1. Execute rollback (if auto-rollback enabled)
2. Create incident issue with monitoring data
3. Attach relevant logs and metrics
4. Tag the original issue with `incident` label
5. Do NOT silence alerts — let them fire

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Monitoring Checklist**: P0/P1/P2 metrics to watch (error rate, latency, memory, health checks) with specific thresholds
2. **Anomaly Detection Triggers**: Explicit conditions that trigger alerts (spike detection >2x, trend detection over 5min, absence detection, latency shift >50%)
3. **Log Analysis**: Search strategy for new ERROR/FATAL entries, stack traces, retry storms, resource exhaustion patterns
4. **Auto-Rollback Decision Criteria**: Conditions that trigger automatic rollback (health check failures, error rate threshold, critical dependency unreachable, memory exhaustion)

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
Repeat count: 1

## Failure Diagnosis (Iteration 4)
Classification: unknown
Strategy: alternative_approach
Repeat count: 2
INSTRUCTION: This error has occurred 2 times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements

## Failure Diagnosis (Iteration 5)
Classification: unknown
Strategy: alternative_approach
Repeat count: 3
INSTRUCTION: This error has occurred 3 times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements

## Failure Diagnosis (Iteration 6)
Classification: unknown
Strategy: alternative_approach
Repeat count: 4
INSTRUCTION: This error has occurred 4 times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements"
iteration: 6
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-03-07T02:16:29Z
last_iteration_at: 2026-03-07T02:16:29Z
consecutive_failures: 0
total_commits: 5
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-03-07T00:54:43Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":253090,"duration_api_ms":245041,"num_turns":60,"resu

### Iteration 2 (2026-03-07T01:03:01Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":413950,"duration_api_ms":279799,"num_turns":70,"resu

### Iteration 3 (2026-03-07T01:26:09Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":1029617,"duration_api_ms":333195,"num_turns":80,"res

### Iteration 4 (2026-03-07T01:37:38Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":268362,"duration_api_ms":105450,"num_turns":32,"resu

### Iteration 5 (2026-03-07T01:46:25Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":441820,"duration_api_ms":152137,"num_turns":49,"resu

