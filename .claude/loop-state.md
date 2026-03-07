---
goal: "Pipeline Cost-Performance Dynamic Optimizer with Burst Mode

## Plan Summary
Plan created at `.claude/plan.md`. Summary of key decisions:

**Architecture**: New `scripts/lib/loop-burst.sh` module (following the `loop-convergence.sh` pattern) with 4 functions, integrated via 4-5 lines in `sw-loop.sh`'s main loop.

**Files**: 1 new (`lib/loop-burst.sh`), 3 modified (`sw-loop.sh`, `sw-loop-test.sh`, `sw-tmux-status.sh`)

**Key design choices**:
- Separate sourced module over inline code — keeps `sw-loop.sh` from growing and enables isolated testing
- Conservative burst triggers: requires score > 70 (test trend + velocity + commits), < 3 iterations remaining, AND budget > 2x estimated cost-to-complete
- Safe defaults everywhere — any error in burst logic results in no burst (never blocks the loop)
- Burst is one-shot per iteration with automatic revert on failure

**12 tasks** covering implementation, integration, dashboard badge, and 9+ unit tests.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Pipeline Cost-Performance Dynamic Optimizer with Burst Mode
## Context
## Decision
### Interface Contract
# Returns integer 0-100 on stdout. Safe default: 0 on any error.
# Sets BURST_ACTIVE, BURST_ORIGINAL_MODEL, overrides CLAUDE_MODEL. 
# Safe default: BURST_ACTIVE=false on any error.
# Called at iteration start. Reverts model if previous burst failed.
# Always resets BURST_ACTIVE=false (burst is one-shot per iteration).
# Fire-and-forget JSON append to ~/.shipwright/costs.json .burst_decisions[]
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 92,
      "summary": "4 known test failures from previous builds: sw-cleanup.sh stale heartbeat output, classify_failure not wired in daemon, sw-hygiene.sh platform-refactor exit code. Critical to avoid repeating during build stage."
    },
    {
      "file": "patterns.json (project config)",
      "relevance": 85,
      "summary": "Project structure essential for build: vitest test runner, npm, commonjs imports, src/ directory, *.test.js pattern. Captured today, highly current."
    },
    {
      "file": "patterns.json (bootstrap)",
      "relevance": 18,
      "summary": "Minimal project type info (nodejs) from Feb 21. Overlaps with detailed patterns.json but much less actionable for build stage."
    },
    {
      "file": "metrics.json",
      "relevance": 14,
      "summary": "Empty baselines structure exists but no data. Could inform build decisions if populated with performance baselines."
    },
    {
      "file": "global.json",
      "relevance": 10,
      "summary": "Empty cross-repo learnings and patterns. Low current value but could contain useful patterns if populated from other builds."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pipeline Cost-Performance Dynamic Optimizer with Burst Mode — Resolution: 

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **performance**: Cost-performance scoring runs on every loop iteration (hot path); must complete in <100ms to avoid slowing the build without reducing latency overhead.
- **testing-strategy**: Complex business logic (progress scoring, budget validation, threshold conditions) needs comprehensive unit tests covering: happy path, budget edge cases, progress stall scenarios, and fallback failures.

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


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-07T01:33:34Z
last_iteration_at: 2026-03-07T01:33:34Z
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
### Iteration 1 (2026-03-07T01:03:31Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":724764,"duration_api_ms":520216,"num_turns":73,"resu

