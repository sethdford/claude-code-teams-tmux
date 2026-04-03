---
goal: "Success Pattern Library with Automatic Pattern Replay Engine

## Plan Summary


Now I have a comprehensive understanding of the entire system. Let me write the implementation plan.

---

# Implementation Plan: Success Pattern Library with Automatic Pattern Replay Engine

## Brainstorming: Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** Capture success patterns on pipeline completion, store them in the existing memory directory, inject the top-matching pattern into the build loop prompt, and expose them via the dashboard. The A/B testing and export are secondary but included in acceptance criteria.

**Implicit requirements:**
- Must integrate with existing `memory_finalize_pipeline()` flow — not a separate hook
- Must use the same locking/atomic-write patterns as `failures.json`
- Pattern matching must be fast (pure `jq`, no Claude call) since it runs on every build loop iteration
- Must not break existing memory injection budget (200K chars) — success patterns share context space
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Success Pattern Library with Automatic Pattern Replay Engine
## Executive Summary
## Context
### Problem Statement
### Constraints
### Requirements Met by Design
## Decision
### Chosen Approach: New Library Module with Atomic File Operations
### Design Decisions (Context + Rationale)
## Alternatives Considered
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json (first entry)",
      "relevance": 95,
      "summary": "Contains actual success pattern structures with detailed metadata (id, goal, approach, iterations, files_changed, test_strategy, cost). Directly shows the data model and examples for the feature being built."
    },
    {
      "file": "success-patterns.json (second entry)",
      "relevance": 90,
      "summary": "Another complete success pattern example demonstrating pattern capture from a feature build, including loop iterations, audit logs, and approach history. Shows realistic pattern data from recent project work."
    },
    {
      "file": "failures.json (first entry)",
      "relevance": 70,
      "summary": "Contains test stage failures and root causes from recent builds in this repo. Relevant for understanding failure patterns that automatic replay should handle or detect."
    },
    {
      "file": "patterns.json (first entry)",
      "relevance": 65,
      "summary": "Documents project conventions (vitest test runner, npm, commonjs imports, test pattern). Understanding the build environment is essential for implementing pattern replay."
    },
    {
      "file": "failures.json (fifth entry)",
      "relevance": 55,
      "summary": "Shows common build-stage variable initialization failures and their fixes. Relevant for understanding what errors the pattern library should capture and replay mitigations for."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Success Pattern Library with Automatic Pattern Replay Engine — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Success Pattern Library with Automatic Pattern Replay Engine

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/success-patterns.sh` with capture, match, inject, export functions
- [ ] Task 2: Add A/B testing functions (assign, record, report) to success-patterns.sh
- [ ] Task 3: Source the module in `scripts/sw-memory.sh` and hook into `memory_finalize_pipeline()`
- [ ] Task 4: Add success pattern section to `memory_inject_context("build")` in sw-memory.sh
- [ ] Task 5: Add success pattern injection to prompt composition in `scripts/lib/loop-iteration.sh`
- [ ] Task 6: Pass additional metadata in `scripts/lib/pipeline-commands.sh` success path
- [ ] Task 7: Add `/api/success-patterns` endpoints to `dashboard/server.ts`
- [ ] Task 8: Add `fetchSuccessPatterns` to `dashboard/src/core/api.ts` and types to `api.ts`
- [ ] Task 9: Add Success Patterns section to `dashboard/src/views/insights.ts`
- [ ] Task 10: Create `scripts/sw-success-patterns-test.sh` test suite
- [ ] Task 11: Register test suite in `package.json`
- [ ] Task 12: Run full test suite to verify no regressions
- [x] No secrets in code
- [x] No user input executed as code
- [x] File paths validated (no directory traversal — uses `repo_memory_dir()`)
- [x] JSON built via jq --arg (injection-safe)
- [x] File permissions inherit from ~/.shipwright/ directory

## Context
- Pipeline: standard
- Branch: feat/success-pattern-library-with-automatic-p-338
- Issue: #338
- Generated: 2026-04-03T18:32:45Z

## Skill Guidance (backend issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **performance**: Pattern indexing and retrieval happens synchronously during build loop initialization—ensure lookups are sub-100ms or risk stalling build startup.
- **testing-strategy**: Validate A/B test design: proper randomization (deterministic per issue to avoid reroll bias), control/treatment bucket sizes, duration, and success rate measurement consistency.

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
max_iterations: 30
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-04-03T18:47:14Z
last_iteration_at: 2026-04-03T18:47:14Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-04-03T18:47:09Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":435296,"duration_api_ms":405362,"num_turns":94,"resu

