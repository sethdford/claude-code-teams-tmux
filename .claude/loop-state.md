---
goal: "Build Loop Test Output Intelligent Summarization and Failure Prioritization

## Plan Summary
Now I have a complete picture. Let me write the implementation plan.

---

# Implementation Plan: Build Loop Test Output Intelligent Summarization

## Brainstorming: Design Analysis

### Requirements Clarity
- **Minimum viable change**: A new lib module that processes raw test output, clusters/categorizes/prioritizes errors, and produces a focused summary. Integration into `compose_prompt()` replacing the current crude `tail -50` + `grep 10 lines` approach.
- **Implicit requirements**: Must handle multiple test frameworks (vitest, jest, pytest, go test, bash test harness), must not break when jq is unavailable, must work within the existing `error-summary.json` pipeline.
- **Acceptance criteria defined by issue**: categorize, cluster, prioritize, generate focused prompt, integration in sw-loop.sh, test suite, docs.

### Alternatives Considered

**Approach A: Replace `write_error_summary()` entirely**
- Pros: Single integration point, cleaner
- Cons: High blast radius — `write_error_summary` is called from the main loop, changes could break existing behavior
- Verdict: Too risky
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Build Loop Test Output Intelligent Summarization and Failure Prioritization
## Context
## Decision
### Component Diagram
### Data Flow
### Interface Contracts
### Error Boundaries
### Priority Scoring Model
### Relationship to `error-actionability.sh`
## Alternatives Considered
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains actual test failure patterns, root causes, categorization, and frequency metrics — directly relevant data for building intelligent test output summarization and failure prioritization system"
    },
    {
      "file": "patterns.json (first entry with project metadata)",
      "relevance": 75,
      "summary": "Defines project structure (vitest test runner, npm, src/ directory, commonjs imports) which is essential context for parsing and understanding test output format"
    },
    {
      "file": "patterns.json (second entry with project_type: nodejs)",
      "relevance": 30,
      "summary": "Minimal nodejs project type detection; provides basic project classification but less actionable detail than full project metadata"
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Contains empty baselines object; not applicable to current build stage"
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "Contains empty decisions array; no prior decision context to inform feature development"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Test Output Intelligent Summarization and Failure Prioritization — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Build Loop Test Output Intelligent Summarization and Failure Prioritization

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/loop-test-summarizer.sh` with module guard, VERSION, and core functions (`summarize_test_output`, `_extract_error_blocks`, `_categorize_error`, `_cluster_errors`, `_prioritize_clusters`, `_generate_focused_prompt`)
- [ ] Task 2: Implement error extraction that handles multi-line stack traces and multiple test frameworks
- [ ] Task 3: Implement categorization logic (syntax/type/assertion/integration/runtime/unknown)
- [ ] Task 4: Implement clustering by file path and normalized error pattern
- [ ] Task 5: Implement priority scoring and sorting
- [ ] Task 6: Implement focused prompt generation with top 3-5 clusters and remainder count
- [ ] Task 7: Write JSON output with atomic file writes (tmp + mv)
- [ ] Task 8: Source `loop-test-summarizer.sh` in `sw-loop.sh` and call after `write_error_summary()`
- [ ] Task 9: Modify `compose_prompt()` in `loop-iteration.sh` to prefer intelligent summary with fallback
- [ ] Task 10: Create test suite `scripts/sw-loop-test-summarizer-test.sh` with mock test output for 10/50/100 error scenarios
- [ ] Task 11: Register test suite in `package.json`
- [ ] Task 12: Add documentation to CLAUDE.md under Build Loop Capabilities
- [ ] Task 13: Run test suite and verify all tests pass
- [ ] `scripts/lib/loop-test-summarizer.sh` exists with all 6 core functions
- [ ] Categorizes failures into syntax/type/assertion/integration/runtime/unknown
- [ ] Clusters related failures (same file, same pattern) — "5 auth failures" not 5 separate
- [ ] Prioritizes by impact: syntax > runtime > type > integration > assertion
- [ ] Generates focused prompt with top 3-5 clusters and suggested fix order
- [ ] Integrated in `sw-loop.sh` after `write_error_summary()`
- [ ] Integrated in `compose_prompt()` with graceful fallback to existing behavior

## Context
- Pipeline: standard
- Branch: feat/build-loop-test-output-intelligent-summa-275
- Issue: #275
- Generated: 2026-03-15T08:27:41Z

## Skill Guidance (testing issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **testing-strategy**: This issue is fundamentally about improving test failure analysis and prioritization; testing-strategy provides patterns for test categorization, mock output generation, and validation of the summarizer across diverse test frameworks.
- **performance**: This feature's entire purpose is context optimization (preventing token waste with focused summaries); performance skill ensures the summarizer itself is fast enough that overhead doesn't defeat the goal.

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
"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-15T08:32:35Z
last_iteration_at: 2026-03-15T08:32:35Z
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

