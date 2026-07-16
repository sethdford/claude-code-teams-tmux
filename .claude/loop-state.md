---
goal: "Cost-Aware Model Retry Cascade for Failed Stages

## Plan Summary
# Implementation Plan: Cost-Aware Model Retry Cascade for Failed Stages

## Overview

Implement a configurable model retry cascade system that automatically retries failed pipeline stages with progressively more capable (but more expensive) models, while respecting budget constraints and optimizing for cost-efficiency.

## Requirements Clarification

**Minimum Viable Change**: When a pipeline stage fails, automatically retry with a fallback model from a configured cascade sequence (default: haiku → sonnet → opus), tracking costs and budget usage.

**Implicit Requirements**:
- Integration with existing `daemon-config.json` model_routing and cost tracking
- Pre-execution budget validation to prevent overspending
- Failure classification to avoid cascading on non-retryable errors
- Observable via logs and cost dashboard
- Backwards compatible—existing pipelines work unchanged

**Acceptance Criteria**:
1. Stage failures automatically trigger cascade with configurable models
2. Budget is checked BEFORE each retry attempt
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Cost-Aware Model Retry Cascade for Failed Stages
## Context
## Decision
### Component Diagram
### Interface Contracts
### Data Flow
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Cost-Aware Model Retry Cascade for Failed Stages

### Goals
- Cost-Aware Model Retry Cascade for Failed Stages

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "issues.json",
      "relevance": 92,
      "summary": "Contains timeout bug pattern with semaphore solution and backoff gotcha — directly relevant to retry cascade for failed stages"
    },
    {
      "file": "success-patterns.json (test-repo-789)",
      "relevance": 88,
      "summary": "High-complexity timeout fix with 3 iterations (retry escalation), build stage focus, $2.00 cost tracking — shows cost-aware retry behavior"
    },
    {
      "file": "success-patterns.json (test-repo-456)",
      "relevance": 82,
      "summary": "Timeout fix pattern with 2 iterations, medium complexity, build stage only — relevant to retry cascade detection and retry count tracking"
    },
    {
      "file": "success-patterns.json (final - Fix bug)",
      "relevance": 75,
      "summary": "Bug fix with 3 iterations showing retry/escalation behavior, cost tracking ($2.50), demonstrates iteration pattern that informs retry strategy"
    },
    {
      "file": "success-patterns.json (test-repo-stages)",
      "relevance": 68,
      "summary": "Staged fix executing intake→plan→build→test→review pipeline — shows multi-stage execution relevant to cascade stage management"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Cost-Aware Model Retry Cascade for Failed Stages — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cost-Aware Model Retry Cascade for Failed Stages

## Implementation Checklist
- [ ] Retry cascade executes on stage failure (when enabled)
- [ ] Models tried in configured order (default: haiku → sonnet → opus)
- [ ] Stage succeeds if any model in cascade succeeds
- [ ] Stage fails if all models exhausted
- [ ] Budget check occurs BEFORE each retry (prevents overspend)
- [ ] Non-retryable failures fail fast without cascading
- [ ] Cost tracking accurate per-attempt
- [ ] Configuration via daemon-config.json (enable/disable, per-stage override)
- [ ] `retry_cascade.enabled` controls feature on/off
- [ ] `retry_cascade.model_order` customizable
- [ ] `retry_cascade.max_cascade_cost_per_stage_usd` enforced
- [ ] `retry_cascade.per_stage_overrides` work for specific stages
- [ ] `config/failure-patterns.json` defines retryable vs non-retryable
- [ ] Unit tests: cascade model selection (correct order)
- [ ] Unit tests: budget validation (prevents overspend)
- [ ] Unit tests: failure classification (retryable vs non-retryable)
- [ ] Integration tests: end-to-end stage failure → cascade → success
- [ ] Integration tests: budget enforcement stops cascade
- [ ] E2E tests: cost tracking accurate across retries
- [ ] All existing tests still pass (backward compatibility)

## Context
- Pipeline: autonomous
- Branch: ci/issue-772
- Issue: none
- Generated: 2026-07-16T04:04:13Z"
iteration: 1
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-07-16T04:15:14Z
last_iteration_at: 2026-07-16T04:15:14Z
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
### Iteration 1 (2026-07-16T04:15:14Z)
- `_smart_float` in `compat.sh` — float-safe config reader for the dollar cap
- `scripts/sw-retry-cascade-test.sh` — **40 unit tests, all passing**, registered in `package.json`
Feature is **off by default**; existing pipelines are byte-identical. The pre-existing `file_mtime` compat-test failure 

