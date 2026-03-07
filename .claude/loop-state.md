---
goal: "Systematic Hardcoded Policy Discovery and Migration to Config

## Plan Summary
All 3 background agents completed. The final agent confirmed 48 hardcoded values found, 22 already configurable, 26 migration candidates — closely matching the issue's reported "44 hardcoded values, 62 fallback blocks."

The agent also identified the best top-5 migration targets, which I'll update in the plan:

1. **`sw-loop.sh:96-97`** — `EXTENSION_SIZE=5`, `MAX_EXTENSIONS=3` (loop flexibility, adaptive-tunable)
2. **`sw-loop.sh:101-102`** — `CIRCUIT_BREAKER_THRESHOLD=3`, `MIN_PROGRESS_LINES=5` (loop exit conditions)
3. **`sw-daemon.sh:237-246`** — `PATROL_INTERVAL=3600`, `PATROL_MAX_ISSUES=5`, `PATROL_FAILURES_THRESHOLD=3` (patrol tuning)
4. **`sw-adaptive.sh:46-55`** — `MIN_TIMEOUT=60`, `MAX_TIMEOUT=7200`, etc. (adaptive bounds)
5. **`sw-pipeline.sh:162`** — `max_lines=10000` (plan artifact rejection threshold)

The plan at `.claude/plan.md` is complete and ready for the build stage. All research is done — the plan covers architecture, task decomposition, risk analysis, testing approach, and definition of done.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Systematic Hardcoded Policy Discovery and Migration to Config
## Context
## Decision
### Layer 1: Schema & Persistence (config/policy.json)
### Layer 2: Query Interface (lib/config-loader.sh)
# In any script that needs a policy value:
# Get a policy value (returns config value, or fallback, or hardcoded default)
# Get with validation (returns value if within bounds, otherwise error)
# Check if policy exists and report confidence
### Layer 3: Adaptive Integration
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 90,
      "summary": "Contains project structure conventions (source_dir: src/, test_pattern: *.test.js, test_runner: vitest, import_style: commonjs) critical for locating hardcoded policies and understanding codebase layout during discovery"
    },
    {
      "file": "failures.json",
      "relevance": 45,
      "summary": "Documents recent test failures in sw-cleanup.sh, sw-daemon.sh, and sw-hygiene.sh that may block build or indicate codebase state issues; some failures may be relevant context for understanding what needs fixing"
    },
    {
      "file": "patterns.json (second)",
      "relevance": 25,
      "summary": "Identifies project as nodejs type with bootstrap detection timestamp; basic metadata with limited actionable value for policy discovery work"
    },
    {
      "file": "metrics.json",
      "relevance": 15,
      "summary": "Contains empty baselines object; currently provides no useful metrics or benchmarks for guiding policy discovery implementation"
    },
    {
      "file": "global.json",
      "relevance": 10,
      "summary": "Both common_patterns and cross_repo_learnings arrays are empty; no cross-repo context available to inform policy discovery approach"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Systematic Hardcoded Policy Discovery and Migration to Config — Resolution: 

## Skill Guidance (refactor issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **performance**: Regex-based discovery across 100+ large scripts must complete in seconds; scanning shouldn't block pipeline execution. Optimize patterns and consider parallel scanning.
- **testing-strategy**: Discovery engine accuracy is critical: high false positives (migrate wrong values) break production; false negatives (miss values) defeat the purpose. Need comprehensive unit + integration tests.
- **hardcoded-value-discovery**: Specialized skill for identifying magic numbers, timeouts, retry limits, thresholds in bash with high precision; ranking by safety and impact for prioritized migration.

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

## Hardcoded Value Discovery for Bash Scripts

Systematically identify and classify hardcoded values in bash scripts to enable data-driven configuration.

### Discovery Patterns

**Numeric Values in Common Contexts:**
- Timeouts: `sleep 30`, `timeout 60`, `TIMEOUT=120` → migrate to config.timeouts
- Retry/Loop Limits: `for ((i=0; i<5; i++))`, `MAX_RETRIES=3` → config.limits
- Thresholds: `if [[ $count -gt 100 ]]`, `THRESHOLD=500` → config.thresholds
- Delays/Intervals: `--interval 5`, `POLL_SECONDS=10` → config.intervals

**Fallback Patterns:**
- `${VAR:-default}` → classify as conditional fallback (low priority)
- `|| echo "fallback"` → classify as error fallback (medium priority)
- `cmd || true` → classify as error suppression (assess risk)
- `if [[ -z $VAR ]]; then ... fi` → classify as missing-value fallback

### Confidence Scoring

Rank migrations 1-5 (highest ROI first):
- **Score 5 (Migrate First)**: High-variance values that adaptive tuner can optimize (timeouts, poll intervals, retry counts). Low risk of correctness impact.
- **Score 4**: Well-scoped values with clear semantics. Easy to validate migrated behavior matches hardcoded baseline.
- **Score 3**: Values that affect performance but not correctness. Medium risk; need good monitoring.
- **Score 2**: Values with ambiguous semantics or used in multiple contexts. Risky; consider per-context overrides.
- **Score 1**: Security-critical values or values with subtle interactions. Migrate only with extensive testing.

### Implementation Checklist

- [ ] Build regex library for each pattern (timeouts, retry limits, thresholds, intervals)
- [ ] For each match: extract value + 2 lines of context (to understand purpose)
- [ ] Classify by type + context
- [ ] Assign confidence score based on safety profile
- [ ] Group by semantic domain (auth timeouts vs. polling intervals)
- [ ] Generate config schema stub
- [ ] Flag values with multiple conflicting definitions (same variable set to different values)
- [ ] Flag values in critical paths (retry logic, deployment steps)
- [ ] Output discovery report: [filename:line] [value] [type] [context] [score]
"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-03-07T01:00:25Z
last_iteration_at: 2026-03-07T01:00:25Z
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
### Iteration 1 (2026-03-07T01:00:25Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":525913,"duration_api_ms":528490,"num_turns":117,"res

