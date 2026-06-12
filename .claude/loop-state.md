---
goal: "Real-Time Adaptive Timeout & Resource Adjustment Engine

## Plan Summary
# Implementation Plan: Real-Time Adaptive Timeout & Resource Adjustment Engine

## Executive Summary

Build an intelligent timeout adjustment system that learns from historical stage durations, detects progress mid-flight, and prevents both premature timeouts and runaway processes. The system will track stage execution patterns by complexity bucket, calculate adaptive timeouts at P90 percentile, extend timeouts when progress is detected, and abort early on stalls.

---

## Brainstorming: Design Decisions & Reasoning

### Requirements Clarity Analysis

**Minimum viable change**: Track stage duration history, calculate P90 timeout at stage start, optionally extend mid-flight if progress detected. Dashboard visualization of adjustments is secondary.

**Implicit requirements identified**:
1. Timeout adjustment must not regress existing pipeline success rates
2. History must survive pipeline runs (persist to database)
3. Complexity bucketing must be reproducible (not random/drift)
4. Progress detection must be low-overhead (no expensive scans)
5. Configuration precedence: config.timeout > adaptive timeout > template default
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Real-Time Adaptive Timeout & Resource Adjustment Engine
## Context
## Decision
### Component decomposition (each has one reason to change)
### Component Diagram
### Interface Contracts
### Data Flow
### Error Boundaries
## Alternatives Considered
## Implementation Plan
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Real-Time Adaptive Timeout & Resource Adjustment Engine

### Goals
- Track stage duration history in db (repo_hash, stage_name, issue_complexity, duration_seconds)
- Calculate adaptive timeout as percentile (P90) of historical durations for similar complexity
- Fallback to template timeout when insufficient history (<5 samples)
- Extend timeout mid-flight if stage shows progress (new commits, test output, file changes)
- Abort early if stage stalls (no progress for 10% of timeout window)
- Emit timeout_adjusted event with old/new timeout and reason
- Integration with daemon-config.json timeout overrides (config takes precedence)
- Dashboard visualization of timeout adjustments per run
- Unit tests for timeout calculation and extension logic
- **Priority**: P0

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json (2026-03-29)",
      "relevance": 95,
      "summary": "Multiple successful feature patterns showing standard template, 3 iterations, npm test strategy, 60-65 complexity—directly applicable to building this timeout feature with the same approach and expectations"
    },
    {
      "file": "patterns.json (2026-05-22)",
      "relevance": 90,
      "summary": "Project structure and conventions (Node/vitest/src/commonjs)—essential context for understanding build environment and test runner for this feature"
    },
    {
      "file": "issues.json",
      "relevance": 75,
      "summary": "Timeout bug fix pattern using semaphore solution—directly relevant to building an adaptive timeout feature; shows successful timeout handling approach"
    },
    {
      "file": "failures.json (detailed, 4 entries)",
      "relevance": 65,
      "summary": "Common test failures (mktemp path issues, cleanup output format, sed syntax)—helps anticipate and avoid test infrastructure issues during build stage"
    },
    {
      "file": "metrics.json (2026-05-15)",
      "relevance": 55,
      "summary": "Baseline build duration (2089s)—provides context for expected build time and helps set realistic iteration expectations"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Real-Time Adaptive Timeout & Resource Adjustment Engine — Resolution: 

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **adaptive-timeout-algorithm-design**: This issue requires careful design of the P90 percentile algorithm, progress detection heuristics (commits, test output, file changes), stall detection thresholds, and thread-safe mid-flight extension.
- **data-pipeline**: Design database schema for duration history with repo_hash, stage_name, complexity, duration_seconds—and ensure efficient percentile queries without scanning all historical data.
- **performance**: Timeout calculation and progress detection must not add significant overhead to pipeline execution; optimize percentile computation and stall-check logic.

## Adaptive Timeout Algorithm Design

Design and implement a robust timeout adaptation algorithm that adjusts stage timeouts mid-flight based on historical data and real-time progress signals.

### Percentile Calculation
- Calculate P90 for stages of similar complexity (use complexity bins, not exact matches)
- Require minimum 5 historical samples before using adaptive timeout; fallback to template timeout otherwise
- Handle edge cases: all identical durations, single extreme outlier, Nan/null values
- Exclude the top 1% of durations to avoid skewing from stuck/killed stages

### Complexity Scoring
- Define complexity signals: file count, change size (lines added/deleted), test count, dependency count
- Bucket into categories (low: <50 files, medium: 50-200, high: >200) rather than continuous scoring
- If no historical data for exact bucket, use next-larger bucket as fallback

### Progress Detection
- Track three signals: new commits pushed to branch, test runner activity (test output appearing), file system changes (files written to disk)
- Progress = any signal detected in past 30% of timeout window
- Extend timeout by 50% of original if progress detected (cap at 2x original)
- Log when extension happens: timestamp, old/new timeout, which signals detected

### Stall Detection
- After 90% of timeout elapsed with no progress signals, consider stage stalled
- Before aborting, emit warning event giving stage 10 more seconds to show progress
- Only abort if still stalled at 100% + 10s threshold
- Do NOT kill if file descriptor activity detected (process may be flushing buffers)

### Thread Safety
- Timeout extension reads historical data once at stage start (immutable snapshot)
- Lock the timeout value before modification to prevent race with abort logic
- Store adjustment reason in state for event emission

### Event Emission
- Emit `timeout_adjusted` with keys: old_timeout_seconds, new_timeout_seconds, reason ("progress_detected"), complexity_bucket, p90_percentile_seconds
- Emit `timeout_stall_warning` with 10s countdown if hitting stall threshold
- Emit `timeout_aborted` with final duration_seconds if stage exceeds extended timeout

### Configuration Integration
- daemon-config.json `timeout_overrides.stage_name` takes precedence over calculated timeout
- If override set, use it directly (skip percentile calculation, disable mid-flight extension)
- Log when override applied

### Fallback Logic
- < 5 samples: use template timeout from pipeline config
- > 5 samples: use P90 from historical data
- If complexity bucket has no data, try next-larger bucket (low → medium → high)
- If still no data after climbing buckets, use template timeout

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
iteration: 1
max_iterations: 30
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-06-12T19:47:29Z
last_iteration_at: 2026-06-12T19:47:29Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

