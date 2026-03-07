---
goal: "Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

## Plan Summary
Based on my analysis of the codebase, I'll now create a comprehensive implementation plan for the Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning.

## Implementation Plan: Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

---

## Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     Pipeline Execution                          │
│  (sw-pipeline.sh → record_stage_end → hook to metrics)         │
└──────────────────────┬──────────────────────────────────────────┘
                       │
        ┌──────────────▼──────────────┐
        │ Stage Duration Recorder      │ (stage-duration-metrics.sh)
        │ • Record duration + status   │
        │ • Capture repo_hash         │
        │ • Write to SQLite           │
        └──────────────┬──────────────┘
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning
## Context
## Decision
### 1. Timeout Enforcement in Pipeline Execution
### 2. Config Application Layer (new)
### 3. Audit Trail (new tables)
### 4. Configuration Schema
### 5. Metrics Tracking
### 6. Dashboard API
### 7. Data Flow
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 85,
      "summary": "Project structure (Node.js, vitest, npm), source directory layout, test patterns (*.test.js), and import conventions (commonjs) — essential setup information for implementing the timeout engine feature"
    },
    {
      "file": "failures.json",
      "relevance": 42,
      "summary": "Test failure patterns from this codebase showing heartbeat detection and output formatting issues — useful precedents for avoiding similar bugs during build stage"
    },
    {
      "file": "patterns.json",
      "relevance": 18,
      "summary": "Confirms project type as nodejs with detection metadata — redundant with first patterns.json, minimal additional value"
    },
    {
      "file": "metrics.json",
      "relevance": 8,
      "summary": "Empty baselines object; potentially relevant for recording P95 duration metrics, but currently contains no data"
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "Empty decisions array; could track architectural decisions for the timeout engine, but no existing entries"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

## Implementation Checklist
- [ ] **Task 1**: Create database schema migration (stage_durations, timeout_recommendations, timeout_adjustments tables)
- [ ] **Task 2**: Implement `db_save_stage_duration()` and related accessor functions in `sw-db.sh`
- [ ] **Task 3**: Create `scripts/lib/stage-duration-metrics.sh` with recording functions
- [ ] **Task 4**: Integrate `record_stage_duration()` hook in `pipeline-state.sh::mark_stage_complete()`
- [ ] **Task 5**: Create `scripts/lib/timeout-recommendation-engine.sh` with stats calculations
- [ ] **Task 6**: Implement percentile calculation and 30-day rolling window logic
- [ ] **Task 7**: Create `scripts/sw-adaptive-timeout.sh` CLI with `analyze` subcommand
- [ ] **Task 8**: Implement `apply` subcommand with config update and dry-run support
- [ ] **Task 9**: Extend `daemon-config.json` with `adaptive_timeouts` configuration section
- [ ] **Task 10**: Add daemon patrol hook for periodic timeout analysis
- [ ] **Task 11**: Update pipeline templates with adaptive timeout fields
- [ ] **Task 12**: Implement timeout avoidance metrics tracking functions
- [ ] **Task 13**: Add timeout-related events for audit trail
- [ ] **Task 14**: Add timeout recommendations API endpoint to dashboard server
- [ ] **Task 15**: Add timeout metrics visualization to DORA dashboard
- [ ] **Task 16**: Create comprehensive test suite `sw-adaptive-timeout-test.sh`
- [ ] **Task 17**: Write documentation and add to CLAUDE.md AUTO:core-scripts
- [ ] **Task 18**: Integration test: Run pipeline with metrics collection → analysis → apply cycle
- [ ] **Task 19**: Performance test: Verify percentile calculations scale to 1000+ records
- [ ] **Task 20**: Manual testing: Verify manual_timeout override is respected

## Context
- Pipeline: standard
- Branch: feat/adaptive-stage-timeout-engine-with-p95-d-212
- Issue: #212
- Generated: 2026-03-07T19:31:03Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **performance**: Percentile calculations (P50, P95, P99) on large datasets can be expensive; rolling window maintenance must be efficient to avoid slowing down the daemon.
- **testing-strategy**: Probabilistic timing behavior is hard to test; need deterministic test fixtures, Monte Carlo validation for percentile accuracy, and edge case coverage (small samples, all-equal values, no data).

## Performance Expertise

Apply these optimization patterns:

### Profiling First
- Measure before optimizing — identify the actual bottleneck
- Use profiling tools appropriate to the language/runtime
- Focus on the critical path — optimize what users experience

### Caching Strategy
- Cache expensive computations and repeated queries
- Set appropriate TTLs — stale data vs freshness trade-off
- Invalidate caches on write operations
- Use cache layers: in-memory (L1) → distributed (L2) → database (L3)

### Database Performance
- Add indexes for frequently queried columns (check EXPLAIN plans)
- Avoid N+1 queries — use batch loading or JOINs
- Use connection pooling
- Consider read replicas for read-heavy workloads

### Algorithm Complexity
- Prefer O(n log n) over O(n²) for sorting/searching
- Use appropriate data structures (hash maps for lookups, trees for ranges)
- Avoid unnecessary allocations in hot paths
- Pre-compute values that are used repeatedly

### Network Optimization
- Minimize round trips — batch API calls where possible
- Use compression for large payloads
- Implement pagination — never return unbounded result sets
- Use CDNs for static assets

### Benchmarking
- Include before/after benchmarks for performance changes
- Test with realistic data volumes (not just unit test fixtures)
- Measure p50, p95, p99 latencies — not just averages

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Baseline Metrics**: Current performance metrics before optimization (p50/p95/p99 latency, throughput, resource usage)
2. **Optimization Targets**: Specific targets (e.g., "reduce p95 latency from 250ms to <100ms") with rationale
3. **Profiling Strategy**: Tools and methodology to identify bottlenecks (CPU profiler, memory profiler, query analyzer, benchmarks)
4. **Benchmark Plan**: Before/after benchmarks with realistic data volume and success criteria for each optimization

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
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-07T19:37:12Z
last_iteration_at: 2026-03-07T19:37:12Z
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

