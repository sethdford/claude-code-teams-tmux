---
goal: "Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

## Plan Summary
Based on my thorough codebase analysis, I'll provide the detailed implementation plan directly. Here's the comprehensive, concrete plan that addresses all validation feedback:

---

# Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

## Executive Summary

This plan builds on existing infrastructure in `sw-adaptive.sh` (percentile calculations) and `daemon-adaptive.sh` (timeout functions) to implement intelligent, data-driven stage timeouts based on P95 duration percentiles from a 30-day rolling window. Auto-adjusts every 7 days.

## Task Decomposition (15 Concrete Tasks)

### Phase 1: Schema & Data Collection (Tasks 1-3)

**Task 1: Add `stage_durations` SQLite table**
- **Input**: Current schema (sw-db.sh:134-200)
- **Output**: New migration `scripts/lib/db-schema-7.sql`
- **Schema**:
  ```sql
  CREATE TABLE IF NOT EXISTS stage_durations (
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions

[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 78,
      "summary": "Detailed project structure (vitest, npm, src/ layout, commonjs imports) essential for building and testing the timeout engine feature"
    },
    {
      "file": "patterns.json",
      "relevance": 42,
      "summary": "Confirms Node.js project type; basic but less detailed than the first patterns entry"
    },
    {
      "file": "failures.json",
      "relevance": 25,
      "summary": "Previous test failures in sw-cleanup.sh and sw-code-review-test.sh; useful context to avoid similar issues during build stage"
    },
    {
      "file": "metrics.json",
      "relevance": 12,
      "summary": "Empty baselines object, but potentially relevant for capturing P95 duration metrics that drive the timeout auto-tuning"
    },
    {
      "file": "decisions.json",
      "relevance": 8,
      "summary": "Empty decisions array; could track design choices for timeout engine, but no prior context available"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning — Resolution: 

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **performance**: Optimize percentile calculations to avoid becoming a bottleneck; evaluate cost-benefit of in-memory vs disk storage; analyze resource usage across millions of pipeline runs.
- **systematic-debugging**: Use this before build to review auto-patrol cycle history and previous timeout attempts to avoid repeating mistakes.

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

## Systematic Debugging: Root Cause Analysis

A previous attempt at this stage FAILED. Do NOT blindly retry the same approach. Follow this 4-phase investigation:

### Phase 1: Evidence Collection
- Read the error output from the previous attempt carefully
- Identify the EXACT line/file where the failure occurred
- Check if the error is a symptom or the root cause
- Look for patterns: is this a known error type?

### Phase 2: Hypothesis Formation
- List 3 possible root causes for this failure
- For each hypothesis, identify what evidence would confirm or deny it
- Rank hypotheses by likelihood

### Phase 3: Root Cause Verification
- Test the most likely hypothesis first
- Read the relevant source code — don't guess
- Check if previous artifacts (plan.md, design.md) are correct or flawed
- If the plan was correct but execution failed, focus on execution
- If the plan was flawed, document what was wrong

### Phase 4: Targeted Fix
- Fix the ROOT CAUSE, not the symptom
- If the previous approach was fundamentally wrong, choose a different approach
- If it was a minor error, make the minimal fix
- Document what went wrong and why the new approach is better

IMPORTANT: If you find existing artifacts from a successful previous stage, USE them — don't regenerate from scratch.

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Root Cause Hypothesis**: List 3 possible root causes ranked by likelihood with specific evidence that would confirm/deny each
2. **Evidence Gathered**: Exact file:line location of failure, error messages, logs, code examination results, artifact validation (plan.md, design.md correctness)
3. **Fix Strategy**: Description of the ROOT CAUSE fix (not the symptom), with rationale for why this approach differs from the previous failed attempt
4. **Verification Plan**: How to verify the fix works (test cases, specific checks, expected behavior confirmation)

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-07T16:25:22Z
last_iteration_at: 2026-03-07T16:25:22Z
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

