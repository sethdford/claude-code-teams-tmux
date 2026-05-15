---
goal: "Cross-Pipeline A/B Testing Framework for Intelligence Feature Validation

## Plan Summary
# Plan: Cross-Pipeline A/B Testing Framework for Intelligence Feature Validation

## Problem & Scope

`scripts/sw-memory.sh` already contains an A/B framework (`memory_ab_assign_group`, `memory_ab_record_assignment`, `memory_ab_record_result`, `cmd_memory_ab_report`) — but it only tests *one* feature (memory injection) and emits memory-specific events. The goal is to **generalize** that framework so any intelligence flag (`adversarial_enabled`, `simulation_enabled`, `architecture_enabled`, `composer_enabled`, `prediction_enabled`, `memory_injection`) can be evaluated as a named experiment, with results aggregated, compared, and reported per-feature.

### Minimum Viable Change

A new shared library `scripts/lib/ab-test.sh` providing experiment-agnostic primitives, plus a thin CLI wrapper `scripts/sw-abtest.sh` exposing `assign`, `record`, `report`, `list`, `status`. Existing `memory_ab_*` functions become thin wrappers that delegate (backwards compatible). Daemon/pipeline call sites gain a single `ab_assign <experiment>` hook that gates whether a feature flag is applied for that pipeline run.

## Alternatives Considered

| Approach | Complexity | Blast Radius | Verdict |
|---|---|---|---|
| **A. Shared lib + per-experiment JSONL** (chosen) | Medium | Low — additive lib + new CLI; existing memory A/B kept via shim | ✅ Reuses existing patterns, isolates each experiment's data |
| **B. Replace memory_ab_* in place; rewrite call sites** | Medium-High | Medium — touches sw-memory.sh, sw-daemon.sh, tests | ❌ Higher regression risk for already-shipped memory experiment |
| **C. Single combined results file with `experiment` column** | Low | Low | ❌ Loses per-experiment isolation; report queries become slower as data grows; harder to GC one experiment |

Chosen: **A**. Backward-compatible shim preserves existing memory A/B behavior; new experiments get clean per-file storage at `~/.shipwright/abtest/<experiment>.jsonl`.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Cross-Pipeline A/B Testing Framework for Intelligence Feature Validation
## Context
## Decision
## Alternatives Considered
## Implementation Plan
### Files to create
### Files to modify
### Dependencies
### Risk areas
## Component Diagram
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Cross-Pipeline A/B Testing Framework for Intelligence Feature Validation

### Goals
- Cross-Pipeline A/B Testing Framework for Intelligence Feature Validation

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json (second entry with test failures)",
      "relevance": 95,
      "summary": "Contains critical intelligence feature validation issues: classify_failure retry logic not wired, sw-feedback.sh regression detection JSON output validation, and /tmp/claude mktemp infrastructure problems—directly applicable to A/B testing framework build/test phase"
    },
    {
      "file": "patterns.json (first entry with project conventions)",
      "relevance": 85,
      "summary": "Captures Node.js project conventions (vitest test runner, CommonJS imports, src/ source dir)—essential context for building and validating the framework code correctly"
    },
    {
      "file": "success-patterns.json (first entry with bug fix approach)",
      "relevance": 70,
      "summary": "Demonstrates successful multi-iteration bug fix strategy using loop approach (3 iterations, npm test strategy)—directly relevant methodology for building and validating features"
    },
    {
      "file": "issues.json",
      "relevance": 60,
      "summary": "Shows successful timeout bug fix using semaphore pattern in daemon code—relevant for reliability patterns in A/B testing framework infrastructure"
    },
    {
      "file": "failures.json (third entry with ENOENT errors)",
      "relevance": 55,
      "summary": "Missing npm install dependency issues—foundational setup problem relevant to build stage preparation and test infrastructure"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Cross-Pipeline A/B Testing Framework for Intelligence Feature Validation — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cross-Pipeline A/B Testing Framework for Intelligence Feature Validation

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/ab-test.sh` with primitives + concurrency-safe append
- [ ] Task 2: Create `scripts/sw-abtest.sh` CLI wrapper
- [ ] Task 3: Create `scripts/sw-abtest-test.sh` test suite (≥15 assertions, mock RANDOM seeded, concurrency test)
- [ ] Task 4: Refactor `memory_ab_*` in `sw-memory.sh` to delegate to `lib/ab-test.sh`; dual-write legacy path
- [ ] Task 5: Add `abtest`/`ab` subcommand to `scripts/sw` router
- [ ] Task 6: Add `intelligence.experiments[]` schema + parse logic in `sw-daemon.sh` config init
- [ ] Task 7: Wire `ab_assign` + `SW_AB_*` env exports at pipeline spawn
- [ ] Task 8: Add `SW_AB_*` override guards in adversarial / architecture / simulation / composer / predictive entry points
- [ ] Task 9: Wire `ab_record_result` at pipeline completion path
- [ ] Task 10: Register new test in `package.json`; run `npm test`; fix regressions
- [ ] Task 11: Run `shipwright docs sync` + add `abtest` row to CLAUDE.md command table
- [ ] Task 12: Manual smoke: configure 2 experiments, run 6 mock pipelines, verify `sw abtest report adversarial` shows ~3/3 split with non-zero metrics
- [ ] `scripts/lib/ab-test.sh` exists, sourceable, all functions documented
- [ ] `sw abtest --help` lists 5 subcommands
- [ ] `sw abtest report memory` produces identical statistics to `sw memory ab-report` (parity)
- [ ] At least one new experiment (e.g., `adversarial`) wired end-to-end and verified by mock pipeline
- [ ] `npm test` passes with new `sw-abtest-test.sh` suite registered (≥15 PASS, 0 FAIL)
- [ ] `sw-memory-test.sh` continues to pass without modification
- [ ] Existing `intelligence.ab_test_ratio` config key still honored (back-compat)
- [ ] `.claude/CLAUDE.md` AUTO sections regenerated and include new files

## Context
- Pipeline: autonomous
- Branch: ci/issue-486
- Issue: none
- Generated: 2026-05-15T13:15:52Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-05-15T13:31:30Z
last_iteration_at: 2026-05-15T13:31:30Z
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

