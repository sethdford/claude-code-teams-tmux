---
goal: "Stage Duration Profiler with Performance Regression Detection and Bottleneck Alerts

## Plan Summary
Plan written to `.claude/pipeline-artifacts/plan.md`. Here's the summary:

## Plan: Stage Duration Profiler

### Architecture Decision
**Approach B (chosen):** Query existing SQLite `pipeline_stages` table + `events.jsonl` fallback. Zero new data storage needed — stages already emit `stage.completed` events with `duration_s` and write to `pipeline_stages`.

### Files (3 new, 3 modified)

| File | Action | Purpose |
|------|--------|---------|
| `scripts/lib/stage-profiler.sh` | **NEW** | Library: percentile computation, regression detection, bottleneck analysis, adaptive export |
| `scripts/sw-stage-profiler.sh` | **NEW** | CLI: `profile`, `check`, `bottlenecks`, `budget`, `report`, `export`, `widget`, `trends` |
| `scripts/sw-stage-profiler-test.sh` | **NEW** | 25 test cases covering all functions |
| `scripts/lib/pipeline-execution.sh` | MODIFY | Add 3-line profiler hook after stage completion (success + failure paths) |
| `scripts/sw` | MODIFY | Add `stage-profiler|profiler` CLI route |
| `package.json` | MODIFY | Register test suite |

### Key Design Points
- **Regression detection**: Flag when `duration_s > P95 * 1.2` with 5s minimum absolute delta
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Stage Duration Profiler with Performance Regression Detection and Bottleneck Alerts
## Context
## Decision
### Component Diagram
### Interface Contracts
### Data Flow
### Error Boundaries
## Alternatives Considered
### 1. New Dedicated SQLite Table for Profiler Data
### 2. Extend `sw-regression.sh` with Stage Duration Regression
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json (node/javascript/vitest)",
      "relevance": 85,
      "summary": "Project uses Node.js, JavaScript, vitest, npm — essential tech stack context for building and testing the performance profiler feature"
    },
    {
      "file": "success-patterns.json (Fix bug - f4af3e)",
      "relevance": 70,
      "summary": "Shows successful shell script fix pattern with 3 iterations and loop/audit/cleanup approach — directly applicable to debugging the stage duration profiler implementation"
    },
    {
      "file": "success-patterns.json (add auth module)",
      "relevance": 65,
      "summary": "Demonstrates multi-iteration feature development (5 iterations, TDD approach) with npm test strategy — relevant baseline for complexity estimation of new profiler feature"
    },
    {
      "file": "failures.json (cannot read property undefined + ReferenceError)",
      "relevance": 60,
      "summary": "Common JavaScript build errors with established fixes — likely to occur during performance profiler development; 100% fix effectiveness rate provides confidence"
    },
    {
      "file": "failures.json (sw-cleanup.sh dry-run and heartbeat detection)",
      "relevance": 55,
      "summary": "Shows shell script testing patterns and heartbeat monitoring — relevant if profiler integrates with Shipwright's heartbeat or cleanup mechanisms"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Stage Duration Profiler with Performance Regression Detection and Bottleneck Alerts — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Stage Duration Profiler with Performance Regression Detection and Bottleneck Alerts

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/stage-profiler.sh` — Core library with percentile computation, regression detection, bottleneck analysis, and adaptive export functions
- [ ] Task 2: Create `scripts/sw-stage-profiler.sh` — CLI script with all subcommands (profile, check, bottlenecks, budget, report, export, widget, trends, reset, help)
- [ ] Task 3: Create `scripts/sw-stage-profiler-test.sh` — Test suite with ~25 test cases covering all library and CLI functions
- [ ] Task 4: Modify `scripts/lib/pipeline-execution.sh` — Source the profiler library and add profiler hooks after stage completion (success + failure paths)
- [ ] Task 5: Modify `scripts/sw` — Add `stage-profiler|profiler` route to CLI router and help text
- [ ] Task 6: Modify `package.json` — Register test suite in npm test script
- [ ] Task 7: Run test suite and verify all tests pass
- [ ] Task 8: Run existing pipeline tests to verify no regressions
- [ ] `shipwright profiler profile` shows P50/P95/mean/samples for all stages
- [ ] `shipwright profiler check` detects regressions >20% above P95 and exits 1
- [ ] `shipwright profiler bottlenecks` ranks top 5 slowest stages over last 7 days
- [ ] `shipwright profiler budget` identifies stages exceeding timeout budget
- [ ] `shipwright profiler report --json` produces valid JSON with all analysis sections
- [ ] `shipwright profiler widget` produces dashboard-compatible JSON
- [ ] `shipwright profiler export` writes data consumable by adaptive timeout engine
- [ ] Pipeline execution calls `profiler_analyze_stage` after each stage (success + failure)
- [ ] `profiler.regression` events emitted when regressions detected
- [ ] All ~25 tests in `sw-stage-profiler-test.sh` pass
- [ ] Existing `sw-pipeline-test.sh` still passes (no regressions)
- [ ] Works without SQLite (JSONL fallback)

## Context
- Pipeline: standard
- Branch: ci/stage-duration-profiler-with-performance-347
- Issue: #347
- Generated: 2026-04-04T10:30:30Z

## Skill Guidance (performance issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **performance**: Profiler overhead is a direct risk—code must measure stage durations with minimal impact; consider sampling vs 100% capture tradeoff.
- **data-pipeline**: This issue is fundamentally about collecting, storing, and analyzing time-series performance data—data engineering patterns directly apply to schema design, query performance, and data freshness.

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
"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-04T10:37:40Z
last_iteration_at: 2026-04-04T10:37:40Z
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

