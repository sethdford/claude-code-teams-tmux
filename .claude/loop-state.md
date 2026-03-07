---
goal: "Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

## Plan Summary
The implementation plan has been written to `.claude/pipeline-artifacts/plan.md` (216 lines).

## Summary

The adaptive timeout engine is **~80% built**. The remaining work connects the existing P95 analysis engine to actual stage execution enforcement. Here's what needs to happen:

**4 files to modify, 8 tasks:**

1. **`scripts/lib/daemon-adaptive.sh`** — Add `adaptive_timeouts.stage_timeouts` lookup to `resolve_stage_timeout()` (priority level 3.5, between config overrides and legacy adaptive calculation)

2. **`scripts/sw-adaptive-timeout.sh`** — Handle `--auto` flag in `cmd_apply()` (daemon patrol already calls `apply --auto`)

3. **`scripts/sw-pipeline.sh`** — Source `lib/stage-duration-metrics.sh` + `lib/daemon-adaptive.sh`, then wrap stage execution in `run_stage_with_retry()` with background process timeout enforcement

4. **`scripts/sw-adaptive-timeout-test.sh`** — Add 3 new tests for `--auto` flag, unified resolution, and manual override precedence

**Key design decision:** Background process with poll loop (not `timeout` command) because stage functions call dozens of sourced helpers that would be lost in a `bash -c` subshell. Background subshells inherit the full parent environment.
, and `sw-adaptive-timeout.sh` (`--auto` flag).

**Acceptance criteria:**
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning
## Context
## Decision
### Approach: Background process with poll loop for timeout enforcement; unified resolution chain for P95 lookup
### Component Diagram
### Data Flow
### Interface Contracts
### Error Boundaries
## Alternatives Considered
## Implementation Plan
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 60,
      "summary": "Project setup with Node.js/vitest/CommonJS conventions. Essential for understanding test harness and build environment for the timeout engine implementation."
    },
    {
      "file": "failures.json",
      "relevance": 35,
      "summary": "Test failure patterns in the codebase showing common issues (heartbeat detection, sed invocations). Informs error handling and edge case coverage for timeout stage."
    },
    {
      "file": "metrics.json",
      "relevance": 25,
      "summary": "Currently empty baselines structure. Relevant for P95-based auto-tuning since this is where collected duration metrics would be stored and retrieved."
    },
    {
      "file": "patterns.json",
      "relevance": 20,
      "summary": "Duplicate project type entry (nodejs, 2026-02-21). Less detailed than first patterns.json; redundant confirmation of project type."
    },
    {
      "file": "decisions.json",
      "relevance": 10,
      "summary": "Empty decisions log. Not currently relevant; would become useful when recording design choices for timeout tuning algorithm."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

## Implementation Checklist
- [ ] Task 1: Add `adaptive_timeouts.stage_timeouts` lookup to `resolve_stage_timeout()` in `scripts/lib/daemon-adaptive.sh` (insert between priority levels 3 and 4, around line 225)
- [ ] Task 2: Add `--auto` flag handling to `cmd_apply()` in `scripts/sw-adaptive-timeout.sh` (add case `--auto) shift ;;`)
- [ ] Task 3: Source `lib/stage-duration-metrics.sh` and `lib/daemon-adaptive.sh` in `scripts/sw-pipeline.sh` (near other library sources)
- [ ] Task 4: Add timeout enforcement to `run_stage_with_retry()` in `scripts/sw-pipeline.sh` — resolve timeout, run stage in background with time limit, record timeout events
- [ ] Task 5: Add test cases to `scripts/sw-adaptive-timeout-test.sh` — `--auto` flag, unified resolution, manual override precedence
- [ ] Task 6: Run `scripts/sw-adaptive-timeout-test.sh` and verify all tests pass
- [ ] Task 7: Run `scripts/sw-pipeline-test.sh` and verify no regressions
- [ ] Task 8: Run full test suite (`npm test`) and fix any failures
- [ ] `resolve_stage_timeout()` returns P95-tuned values from `adaptive_timeouts.stage_timeouts` in daemon-config.json
- [ ] Pipeline stages are enforced with timeouts when `resolve_stage_timeout` is available and returns >0
- [ ] Timeout events are recorded via `record_timeout_event()` for feedback into P95 calculations
- [ ] `sw adaptive-timeout apply --auto` runs without error (daemon patrol integration)
- [ ] Manual overrides always take precedence over P95-tuned values
- [ ] All existing tests in `sw-adaptive-timeout-test.sh` pass (37 tests)
- [ ] All existing tests in `sw-pipeline-test.sh` pass
- [ ] New tests cover: `--auto` flag, unified resolution, manual override precedence
- [ ] Full test suite (`npm test`) passes with no regressions

## Context
- Pipeline: autonomous
- Branch: ci/issue-212
- Issue: none
- Generated: 2026-03-07T22:42:52Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-07T22:48:59Z
last_iteration_at: 2026-03-07T22:48:59Z
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

