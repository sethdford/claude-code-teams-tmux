---
goal: "Per-Stage Reliability Dashboard with Automatic Config Rollback

## Plan Summary
Plan written to `.claude/pipeline-artifacts/plan.md`. Here's a summary:

## Key Design Decisions

**Approach:** Pure SQL aggregation over the existing `pipeline_stages` table (Alternative A) rather than a materialized metrics table. This avoids adding new write paths to pipeline execution code -- only query functions and 2 new tables for config snapshots/rollback audit.

## Files Changed (6 total)

| File | Change |
|------|--------|
| `scripts/sw-db.sh` | Schema v7 migration (2 tables), 7 new functions |
| `scripts/lib/daemon-poll-health.sh` | `daemon_check_stage_rollback()`, `daemon_snapshot_config()` |
| `scripts/lib/daemon-poll.sh` | 2 lines in poll loop for rollback check + snapshot |
| `scripts/sw` | 3-line CLI route for `stage-health` |
| `scripts/sw-stage-health.sh` | **NEW** ~300 lines -- CLI dashboard |
| `scripts/sw-stage-health-test.sh` | **NEW** ~400 lines -- 25 tests |

## 10 Tasks (with dependency chain)

1. Schema migration v6->v7 (blocks 2,3)
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Per-Stage Reliability Dashboard with Automatic Config Rollback
## Context
## Decision
## Alternatives Considered
### Alternative A: Pure SQL Aggregation (CHOSEN ✓)
### Alternative B: Materialized Metrics Table
## Implementation Plan
### Files to Create
### Files to Modify
### Dependencies
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json (fifth entry)",
      "relevance": 95,
      "summary": "JS-specific build failures with 100% fix effectiveness rate for 'cannot read property of undefined' and 66% for missing variable declarations. Directly applicable to catch issues during build stage for JS dashboard project."
    },
    {
      "file": "patterns.json (first entry)",
      "relevance": 90,
      "summary": "Project structure metadata: Node.js, vitest test runner, npm package manager, CommonJS imports. Essential context for building and testing this feature in the correct environment."
    },
    {
      "file": "success-patterns.json (first entry)",
      "relevance": 85,
      "summary": "Recent success pattern showing 3-iteration build, npm test strategy, and files changed patterns. Provides template for expected build cycle and test execution for feature work."
    },
    {
      "file": "failures.json (second entry)",
      "relevance": 80,
      "summary": "JavaScript build-stage failures: undefined property access (100% fix rate) and ReferenceError issues (66% fix rate). Gives specific patterns to watch for during dashboard development."
    },
    {
      "file": "failures.json (third entry)",
      "relevance": 75,
      "summary": "ENOENT/missing dependency installation failure with 95% fix effectiveness. Critical for reliability—missing npm install is a common build blocker that should be automated."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Per-Stage Reliability Dashboard with Automatic Config Rollback — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Per-Stage Reliability Dashboard with Automatic Config Rollback

## Implementation Checklist
- [ ] Task 1: Add `config_snapshots` and `config_rollbacks` tables to `sw-db.sh` `init_schema()`, bump SCHEMA_VERSION to 7, add v6->v7 migration block
- [ ] Task 2: Add `db_stage_health()`, `db_stage_health_all()`, `db_stage_failure_types()`, `db_stage_success_rate_recent()` query functions to `sw-db.sh`
- [ ] Task 3: Add `db_save_config_snapshot()`, `db_get_last_good_config()`, `db_record_rollback()`, `db_recent_rollback_count()` functions to `sw-db.sh`
- [ ] Task 4: Create `scripts/sw-stage-health.sh` with CLI parsing, overview, single-stage detail, trend, and rollback-history views
- [ ] Task 5: Add `daemon_check_stage_rollback()` and `daemon_snapshot_config()` to `scripts/lib/daemon-poll-health.sh`
- [ ] Task 6: Integrate rollback check and config snapshot calls into `scripts/lib/daemon-poll.sh` poll loop
- [ ] Task 7: Add `stage-health` command route to `scripts/sw`
- [ ] Task 8: Create `scripts/sw-stage-health-test.sh` test suite with ~25 tests covering aggregation, snapshots, rollback logic, and CLI output
- [ ] Task 9: Run full test suite (`npm test`) and fix any regressions
- [ ] Task 10: Update CLAUDE.md docs table entries for new files
- [ ] `shipwright stage-health` displays per-stage success_rate, p50_duration, p95_duration, failure types
- [ ] `shipwright stage-health build --days 7` shows 7-day view for specific stage
- [ ] `shipwright stage-health --json` returns machine-readable JSON
- [ ] `shipwright stage-health --days 90` supports 7/30/90 day views
- [ ] Config rollback triggers when any stage success rate drops >10% relative over 5 runs
- [ ] Rollback restores last known-good `daemon-config.json` atomically
- [ ] Rollback has 2-hour cooldown to prevent thrashing
- [ ] Rollback audit log records every trigger (reason, before/after config)
- [ ] Daemon poll loop calls rollback check every 5 cycles
- [ ] Config snapshot saved after each successful self-optimize cycle

## Context
- Pipeline: standard
- Branch: feat/per-stage-reliability-dashboard-with-aut-342
- Issue: #342
- Generated: 2026-04-03T18:41:56Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **performance**: Ensure metric lookups and aggregations don't increase daemon spawn latency, and optimize database indices for health queries

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
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-04-03T18:47:10Z
last_iteration_at: 2026-04-03T18:47:10Z
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

