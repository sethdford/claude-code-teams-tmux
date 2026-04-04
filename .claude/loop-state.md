---
goal: "Intelligence Layer Full-Stack Integration and Orchestration Engine

## Plan Summary
Here is the complete implementation plan for the Intelligence Layer Full-Stack Integration.

## Summary

**Problem:** 5 intelligence modules exist but operate independently — there's no orchestration layer that connects them. The composed pipeline written by the composer is never applied to `PIPELINE_CONFIG`.

**Solution:** 4 targeted changes across 4 files:

### Files to Modify
1. **`scripts/sw-intelligence.sh`** — Add `intelligence_orchestrate_pipeline_start()` (sequences all 5 modules, writes `intelligence-report.json`) and `intelligence_apply_composed_pipeline()` (swaps `PIPELINE_CONFIG` to the composed pipeline if valid)
2. **`scripts/lib/pipeline-commands.sh`** — Call the orchestrator at line ~727, after the predictions block and before `start_heartbeat` (reuses `INTELLIGENCE_ANALYSIS` already in scope to avoid double calls)
3. **`scripts/lib/pipeline-execution.sh`** — Call `intelligence_apply_composed_pipeline` between lines 531-533 and re-read `build_enabled`/`use_self_healing` from the swapped config
4. **`scripts/sw-intelligence-test.sh`** — Add 4 test functions (full flow, idempotency, no-claude fallback, composed pipeline applied)

### Key Design Decisions
- **Sequential execution** required: each stage feeds the next (score → compose → predict → route → vitals)
- **Fail-open everywhere**: every call site is `|| true`; pipeline never blocked by intelligence failures
- **Reuses `INTELLIGENCE_ANALYSIS`** already exported by `generate_reasoning_trace` to avoid double Claude calls
- **Idempotency** via `run_id` check in `intelligence-report.json`
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Intelligence Layer Full-Stack Integration and Orchestration Engine
## Context
## Decision
### Approach: Sequential Orchestrator with Config Swap
### Component Diagram
### Data Flow
### Interface Contracts
### Error Boundaries
### Sequencing Rationale
### Idempotency
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json",
      "relevance": 95,
      "summary": "First entry shows successful patterns from previous builds including intelligence-cache.json and loop-state.md modifications (core to intelligence layer), 3 iterations with npm test strategy, standard template, and cost/duration data directly applicable to this build stage"
    },
    {
      "file": "patterns.json",
      "relevance": 90,
      "summary": "First entry defines actual project structure: Node.js, vitest test runner, npm package manager, CommonJS imports, src/ source directory — essential configuration for building and testing the intelligence layer"
    },
    {
      "file": "failures.json",
      "relevance": 80,
      "summary": "Second entry captures common JavaScript build failures ('cannot read property undefined', 'referenceerror not defined') with effectiveness rates (100% and 66%), providing proven mitigation strategies for the build stage"
    },
    {
      "file": "failures.json",
      "relevance": 75,
      "summary": "Third entry shows npm install missing dependency issue (95% effectiveness rate) — critical prerequisite that blocks builds, likely to be encountered when building this Node.js project"
    },
    {
      "file": "patterns.json",
      "relevance": 70,
      "summary": "Third entry confirms nodejs project type detected at bootstrap, validating that Node.js toolchain and conventions apply to this build"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Intelligence Layer Full-Stack Integration and Orchestration Engine — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Intelligence Layer Full-Stack Integration and Orchestration Engine

## Implementation Checklist
- [ ] Task 1: Add `intelligence_orchestrate()` function to `sw-intelligence.sh` (~200 lines) -- Core orchestration: score -> compose -> predict -> route -> monitor with shared context enrichment
- [ ] Task 2: Add `_orchestrate_read_report()` helper to `sw-intelligence.sh` -- Small utility for reading report fields
- [ ] Task 3: Modify `pipeline_start()` in `pipeline-commands.sh` to call orchestrator -- Replace/augment `generate_reasoning_trace()` with orchestrator call
- [ ] Task 4: Add per-stage model routing in `pipeline-execution.sh` -- Read `intelligence-report.json` during stage iteration for model selection
- [ ] Task 5: Create `sw-intelligence-orchestrator-test.sh` with 12 tests -- Full test coverage of orchestration sequence, degradation, data flow
- [ ] Task 6: Register test in `package.json` -- Add to npm test suite
- [ ] Task 7: Run full test suite (`npm test`) and fix any regressions -- Verify existing tests still pass
- [ ] Task 8: Validate with `sw-pipeline-test.sh` -- E2E pipeline test to confirm orchestrator integrates correctly

## Context
- Pipeline: standard
- Branch: feat/intelligence-layer-full-stack-integratio-339
- Issue: #339
- Generated: 2026-04-03T18:48:31Z

## Skill Guidance (backend issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **systematic-debugging**: Previous attempt at this stage FAILED—investigate what the failure was before repeating; don't re-implement the same orchestration pattern.
- **performance**: Orchestrator runs on every pipeline start; adding 30s overhead would block thousands of runs; must measure and optimize latency per module.

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


## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 30
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-04T01:37:03Z
last_iteration_at: 2026-04-04T01:37:03Z
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
### Iteration 1 (2026-04-04T01:19:51Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":451807,"duration_api_ms":369537,"num_turns":50,"resu

