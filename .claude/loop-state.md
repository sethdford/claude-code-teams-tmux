---
goal: "sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library

## Plan Summary
# Implementation Plan: Extract Stage Execution Library from sw-pipeline.sh

## Socratic Design Analysis

### Requirements Clarity

**Minimum viable change:** Extract the `run_pipeline()` function (lines 660-1048, ~390 lines) and its supporting inline functions from `sw-pipeline.sh` into a new `scripts/lib/pipeline-orchestrator.sh` library. This is the largest remaining block of stage execution logic still inline in `sw-pipeline.sh`.

**Implicit requirements:**
- Maintain backward compatibility -- all existing tests must pass
- Follow the established extraction pattern (include guards, default variable declarations, shellcheck source directives)
- The main `sw-pipeline.sh` file should become a thin shell: argument parsing, source loading, and dispatch

**Acceptance criteria:**
1. `sw-pipeline.sh` drops below ~350 lines (currently 1075)
2. All functions that execute pipeline stages live in `scripts/lib/` libraries
3. All 102 existing test suites pass (especially `sw-pipeline-test.sh`)
4. New library has include guard and follows existing patterns

### What Remains Inline in sw-pipeline.sh
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library
## Context
## Decision
### Extracted functions (6):
### What stays in `sw-pipeline.sh` (~350 lines):
### Pattern details:
## Component Diagram
## Interface Contracts
## Data Flow
## Error Boundaries
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 78,
      "summary": "Project structure details (src/, vitest, commonjs) directly inform how to organize extracted stage execution library and test patterns to match repo conventions"
    },
    {
      "file": "patterns.json",
      "relevance": 52,
      "summary": "Confirms nodejs project type and detection timestamp, establishing baseline project metadata for the decomposition task"
    },
    {
      "file": "failures.json",
      "relevance": 28,
      "summary": "Pre-existing test failure in sw-cleanup.sh may be relevant context if build stage needs to handle or avoid similar dry-run detection patterns"
    },
    {
      "file": "metrics.json",
      "relevance": 8,
      "summary": "Empty baselines offer no actionable context for current build stage"
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "No prior architectural decisions captured; build stage will establish new patterns"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-orchestrator.sh` with include guard, variable defaults, and extracted functions (`run_pipeline`, `preflight_checks`, `cleanup_on_exit`, heartbeat helpers, CI helpers)
- [ ] Task 2: Update `scripts/sw-pipeline.sh` to source the new library and remove extracted function bodies
- [ ] Task 3: Verify `sw-pipeline.sh` line count is under 400 lines
- [ ] Task 4: Create `scripts/sw-lib-pipeline-orchestrator-test.sh` with unit tests for all extracted functions
- [ ] Task 5: Register the new test in `package.json`
- [ ] Task 6: Run `sw-pipeline-test.sh` to verify no regression in the E2E pipeline tests
- [ ] Task 7: Run the new unit test suite
- [ ] Task 8: Run full test suite (`npm test`) to verify no cross-suite breakage
- [ ] Task 9: Update the Shared Libraries table in `.claude/CLAUDE.md` to document the new library
- [ ] `scripts/lib/pipeline-orchestrator.sh` exists with include guard and all extracted functions
- [ ] `scripts/sw-pipeline.sh` is under 400 lines (from 1075)
- [ ] `scripts/sw-pipeline.sh` sources the new library in the correct dependency order
- [ ] All functions extracted maintain identical signatures and behavior
- [ ] `sw-pipeline-test.sh` passes (0 failures)
- [ ] New `sw-lib-pipeline-orchestrator-test.sh` passes
- [ ] `npm test` passes (no regressions across 102+ suites)
- [ ] CLAUDE.md Shared Libraries table updated

## Context
- Pipeline: autonomous
- Branch: ci/issue-189
- Issue: none
- Generated: 2026-03-06T07:49:08Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-06T08:22:03Z
last_iteration_at: 2026-03-06T08:22:03Z
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

