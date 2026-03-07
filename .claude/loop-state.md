---
goal: "Pipeline Stall and Deadlock Detection with Auto-Abort

## Plan Summary
# Implementation Plan: Pipeline Stall and Deadlock Detection with Auto-Abort

## Brainstorming: Design Decisions

### Requirements Clarity

**Minimum viable change**: A new library `lib/pipeline-stall-detection.sh` that enhances the existing `detect_stuckness()` in `loop-convergence.sh` with stronger deadlock patterns and auto-abort capability, plus a new `stall_deadlock` failure class in daemon retry logic that prevents re-stuck pipelines.

**Implicit requirements**:
- Must not false-positive on legitimate long-think iterations (e.g., large refactors with few commits)
- Must integrate with existing vitals health scoring (not duplicate it)
- Must save abort diagnostics to memory for future prevention
- Dashboard needs stall statistics (existing event system supports this)

**Acceptance criteria** (from issue):
1. Monitor iterations for: files changed, test pass count deltas, unique vs repeated errors
2. Detect deadlock: 3+ iterations zero file changes, or 5+ iterations identical error signatures
3. Auto-abort with diagnostics: what was stuck, what was attempted, suggested recovery
4. Save abort reason to memory system
5. Integrate with daemon retry to avoid re-stuck pipelines
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions

[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Project conventions (vitest, npm, src/ structure, *.test.js pattern) directly needed for build stage"
    },
    {
      "file": "failures.json",
      "relevance": 72,
      "summary": "Test failures from sw-daemon.sh (classify_failure not wired into retry logic) and sw-cleanup.sh are relevant to pipeline stall detection feature"
    },
    {
      "file": "patterns.json",
      "relevance": 15,
      "summary": "Minimal project_type detection metadata, largely redundant with more detailed first patterns.json entry"
    },
    {
      "file": "metrics.json",
      "relevance": 8,
      "summary": "Empty baselines object provides no actionable data for build stage"
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "No recorded decisions available"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pipeline Stall and Deadlock Detection with Auto-Abort — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Pipeline Stall and Deadlock Detection with Auto-Abort

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-stall-detection.sh` with core detection functions (stall_compute_score, stall_should_abort, stall_build_diagnostics, stall_check_and_abort, stall_save_to_memory, stall_get_statistics)
- [ ] Task 2: Integrate stall detection into `scripts/lib/loop-convergence.sh` — call stall_check_and_abort after stuckness detection
- [ ] Task 3: Add stall_abort status handling to `scripts/sw-loop.sh` — source lib, handle STATUS="stall_abort", show diagnostics in summary
- [ ] Task 4: Add stall_deadlock failure class to `scripts/lib/daemon-failure.sh` — classify, retry strategy (max 1), escalation with different approach
- [ ] Task 5: Add `memory_capture_stall()` to `scripts/sw-memory.sh` — store stall diagnostics for future prevention
- [ ] Task 6: Add stall_risk metric to `scripts/sw-pipeline-vitals.sh` — fifth health signal, influence verdict
- [ ] Task 7: Add stall statistics to `dashboard/server.ts` — parse stall events, include in pipeline status
- [ ] Task 8: Create test suite `scripts/sw-lib-pipeline-stall-detection-test.sh` — comprehensive unit tests
- [ ] Task 9: Register test in `package.json` and run full suite to verify
- [ ] `stall_compute_score()` correctly identifies zero-change (3+) and error-loop (5+) patterns
- [ ] Auto-abort triggers only when score >= 70 AND tests are NOT passing
- [ ] Abort produces JSON diagnostics with stall_type, iterations_stuck, repeated_error, suggested_recovery
- [ ] Diagnostics saved to memory system via `memory_capture_stall()`
- [ ] Daemon classifies stall aborts as `stall_deadlock` with max 1 retry
- [ ] Pipeline vitals include stall_risk in health score
- [ ] Dashboard receives stall statistics via existing event/WebSocket system
- [ ] All tests pass (new test suite + no regressions in existing suites)
- [ ] No false positives: tests-passing state never triggers abort

## Context
- Pipeline: standard
- Branch: feat/pipeline-stall-and-deadlock-detection-wi-198
- Issue: #198
- Generated: 2026-03-07T00:50:21Z

## Skill Guidance (infrastructure issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **systematic-debugging**: Issue explicitly mentions prior failure; avoid blind retry—investigate what prior attempt missed (false positives? missed patterns?).
- **performance**: Stall detection runs every iteration; if overhead is high, it paradoxically causes real stalls; design must be lightweight.
- **pipeline-stall-detection**: Specialized patterns for file change tracking, error signature hashing, and safe abort procedures specific to this use case.

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

## Pipeline Stall Detection Patterns

### What Makes a Build Stuck

Distinguish between:
- **Slow but healthy**: Making progress (file changes, new errors explored, test count improving)
- **Stuck deadlock**: Repeating the same state with no forward motion

### Progress Indicators

#### 1. File Change Delta
```
track: set of files modified in iteration N
stall_signal: if file_delta[i] == {} for 3+ consecutive iterations
risk: generated files, cache directories — must filter
```

#### 2. Error Signature Hashing
```
hash_error(msg):
  - strip timestamps, line numbers, dynamic values
  - compare error_hash[i] across iterations
deadlock_signal: if error_hash[i] == error_hash[i-1] == error_hash[i-2] for 5+ iterations
risk: similar but different errors (e.g., "timeout at line 42" vs "timeout at line 50")
```

#### 3. Test Result Delta
```
track: pass_count, fail_count, error_set per iteration
stall_signal: if pass_count[i] == pass_count[i-1] AND fail_set[i] == fail_set[i-1] for N iterations
```

### Safe Abort Procedure

1. **Preserve state**: Don't discard progress.md or recent commits
2. **Capture diagnostics**: What iteration? What errors? What file changes were attempted?
3. **Save to memory**: Append to memory system with stall pattern and context
4. **Signal daemon**: Mark job with `stall_detected` reason (not a code error)
5. **Suggest recovery**: Output actionable next steps (manual intervention? test isolation?)

### Integration with Daemon Retry

When daemon sees `stall_detected`:
- Increment `max_restarts` for retry (fresh session may unstick)
- Inject memory context into next attempt
- Log stall pattern for aggregate analysis
- If stalls persist across restarts → escalate to human

### False Positive Prevention

- **Whitelist safe iterations**: Some tests legitimately produce no file changes (e.g., type checking)
- **Time-based grace period**: Don't abort in first 2 iterations (setup/analysis phase)
- **Error uniqueness**: Count *unique* errors, not raw count
- **Diff accuracy**: Use `git diff --name-only` to avoid counting generated files

### Dashboard Representation

- Show iteration timeline with file change bars
- Highlight error signature patterns
- Display stall detection threshold (e.g., "3 of 3 iterations, 0 file changes")
- Show previous stalls from memory system


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
started_at: 2026-03-07T01:38:35Z
last_iteration_at: 2026-03-07T01:38:35Z
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
### Iteration 1 (2026-03-07T01:08:32Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":606374,"duration_api_ms":499599,"num_turns":72,"resu

