---
goal: "Strategic Agent Success Rate Feedback Loop - Constrain Complexity When Success Rate is Low

## Plan Summary
# Plan: Strategic Agent Success Rate Feedback Loop

## Summary

When the system's rolling pipeline success rate is low, automatically constrain the complexity of work attempted — cap iterations, prefer simpler templates, and defer high-complexity issues — until the success rate recovers. This prevents the system from repeatedly failing on hard work while burning budget and time.

---

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A library module that computes rolling success rate from existing outcome data, plus integration points in the daemon spawn path and pipeline composer that use it to constrain complexity.

**Implicit requirements**:
- Must degrade gracefully when no outcome data exists (assume 100% = no constraints)
- Must work alongside existing adaptive thresholds system (daemon-adaptive.sh)
- Must not block ALL issues — always allow sufficiently simple work through
- Must be configurable via daemon-config.json
- Must emit events for observability
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Strategic Agent Success Rate Feedback Loop
## Context
## Decision
## Alternatives Considered
### 1. Extend `daemon-adaptive.sh` (Inline Approach)
### 2. Inline Checks in Each Consumer (Minimal Approach)
### 3. External Scoring Service (Heavy Approach)
## Component Diagram
## Interface Contracts
### Public Functions (Bash signatures)
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains captured test failures and root causes (sw-cleanup.sh dry-run issues, sw-feedback-test.sh regression detection, mktemp errors). Directly relevant for understanding where success rates drop and what complexity constraints should be enforced."
    },
    {
      "file": "patterns.json (first)",
      "relevance": 45,
      "summary": "Documents project conventions (vitest test runner, commonjs imports, src/ structure). Relevant for understanding the build environment and how to run tests to measure success rates."
    },
    {
      "file": "patterns.json (second)",
      "relevance": 35,
      "summary": "Confirms project type as Node.js from bootstrap detection. Minimal but relevant for confirming build environment assumptions."
    },
    {
      "file": "decisions.json",
      "relevance": 10,
      "summary": "Empty—no prior decisions captured. Not currently relevant."
    },
    {
      "file": "global.json",
      "relevance": 5,
      "summary": "Empty common patterns and cross-repo learnings. Not currently relevant."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Strategic Agent Success Rate Feedback Loop - Constrain Complexity When Success Rate is Low — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Strategic Agent Success Rate Feedback Loop - Constrain Complexity When Success Rate is Low

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/success-rate-constraints.sh` with config loading, `compute_rolling_success_rate()`, `get_constraint_level()` with hysteresis
- [ ] Task 2: Implement `should_defer_issue()`, `get_iteration_cap()`, `constrain_template()` in the same file
- [ ] Task 3: Integrate complexity gate and template constraint into `scripts/lib/daemon-dispatch.sh` before pipeline spawn
- [ ] Task 4: Integrate iteration cap into `scripts/sw-pipeline-composer.sh` in `composer_estimate_iterations()`
- [ ] Task 5: Source the new module in `scripts/sw-daemon.sh`
- [ ] Task 6: Create test suite `scripts/sw-success-rate-constraints-test.sh` with 17 test cases
- [ ] Task 7: Register test suite in `package.json`
- [ ] Task 8: Run full test suite to verify no regressions
- [ ] Rolling success rate is computed from last N pipeline.completed events
- [ ] When success rate < 40%, high-complexity issues (>4) are deferred, iterations capped at 10, templates downgraded aggressively
- [ ] When success rate < 60%, moderate-complexity issues (>7) are deferred, iterations capped at 15, templates downgraded conservatively
- [ ] When success rate recovers above 70%, all constraints relax
- [ ] Issues with complexity <= 3 always proceed regardless of success rate
- [ ] Hysteresis prevents rapid constraint oscillation
- [ ] All constraint decisions emit events for observability
- [ ] Feature is off by default (`success_rate_constraints.enabled: false`)
- [ ] 17-test suite passes covering all logic paths
- [ ] Existing test suites pass without regression
- [ ] All bash 3.2 compatibility rules followed (no associative arrays, no readarray, etc.)
- [ ] Atomic file writes for daemon-tuning.json updates

## Context
- Pipeline: autonomous
- Branch: ci/issue-249
- Issue: none
- Generated: 2026-03-11T01:26:38Z

## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0"
iteration: 2
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-03-11T01:45:29Z
last_iteration_at: 2026-03-11T01:45:29Z
consecutive_failures: 0
total_commits: 2
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log
### Iteration 1 (2026-03-11T01:37:55Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":239654,"duration_api_ms":229417,"num_turns":49,"resu

### Iteration 2 (2026-03-11T01:45:29Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":241353,"duration_api_ms":196166,"num_turns":58,"resu

