---
goal: "Pipeline Stage Parallel Execution Engine with Dependency DAG Resolver

## Plan Summary
# Plan: Pipeline Stage Parallel Execution Engine with Dependency DAG Resolver

## Goal Summary

The pipeline currently executes stages strictly sequentially via `run_pipeline()`
in `scripts/lib/pipeline-execution.sh:507`, iterating stages in the order they
appear in the template JSON. Many stages have no genuine dependency on one
another (e.g. `security_audit`-style stages do not depend on `design`; doc/lint
stages don't depend on each other) — they're just listed in linear order.

This feature adds a **dependency DAG resolver** that:

1. Reads an optional `depends_on: [stage_id, ...]` field per stage in the
   template JSON.
2. Computes a topological order, detects cycles, and groups stages into
   **waves** of stages whose dependencies are all satisfied.
3. Executes each wave's stages **in parallel** using bash background jobs,
   joining on each wave before advancing.
4. Falls back to the existing sequential path when parallelism is disabled or
   no `depends_on` fields are present — i.e. **zero behavior change by default**.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Pipeline Stage Parallel Execution Engine with Dependency DAG Resolver
## Context
## Decision
## Alternatives Considered
## Component Diagram
## Interface Contracts
## Data Flow
## Error Boundaries
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Pipeline Stage Parallel Execution Engine with Dependency DAG Resolver

### Goals
- Pipeline Stage Parallel Execution Engine with Dependency DAG Resolver

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json (detailed test failures)",
      "relevance": 90,
      "summary": "Contains actual failing test patterns from shipwright codebase including sw-cleanup.sh heartbeat detection, sw-feedback.sh JSON output, mktemp directory creation, and intelligence classification wiring. Directly informs what needs fixing during build stage."
    },
    {
      "file": "patterns.json (project detection)",
      "relevance": 85,
      "summary": "Establishes project as Node.js/vitest/CommonJS with source in src/. Critical for understanding build environment, test patterns (*.test.js), and import conventions for implementing pipeline engine."
    },
    {
      "file": "success-patterns.json (Fix bug pattern)",
      "relevance": 75,
      "summary": "Shows successful shipwright bug fix with 3 iterations, targeting scripts/lib/ files and using loop-based autonomous progress pattern. Demonstrates proven approach for iterative debugging and testing in this codebase."
    },
    {
      "file": "issues.json (daemon timeout bug)",
      "relevance": 65,
      "summary": "Documents a timeout bug in parallel daemon execution fixed with semaphore pattern. Directly relevant to parallel execution engine work; shows concurrency control pattern that may apply to DAG resolver."
    },
    {
      "file": "failures.json (ENOENT npm install)",
      "relevance": 55,
      "summary": "Node.js build-time dependency issue showing npm install is critical prerequisite. Generic but applicable—ensures build environment is properly initialized before compilation."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pipeline Stage Parallel Execution Engine with Dependency DAG Resolver — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Pipeline Stage Parallel Execution Engine with Dependency DAG Resolver

## Implementation Checklist
- [ ] Task 1: Audit shared-state writers; add `flock`/atomic-write where missing.
- [ ] Task 2: Extract `_run_one_stage()` from `run_pipeline()` with zero behavior change.
- [ ] Task 3: Implement `scripts/lib/pipeline-dag.sh` (build, validate, next_wave, mark_done, skip_descendants).
- [ ] Task 4: Implement `scripts/lib/pipeline-parallel.sh` with bounded concurrency, gate-serial guard, and process-group trap.
- [ ] Task 5: Wire `PIPELINE_PARALLEL_ENABLED` branch into `run_pipeline()`.
- [ ] Task 6: Annotate `templates/pipelines/standard.json` with linear-equivalent `depends_on`.
- [ ] Task 7: Write `scripts/sw-pipeline-dag-test.sh` (waves, cycle, unknown dep).
- [ ] Task 8: Write `scripts/sw-pipeline-parallel-test.sh` (concurrency, failure propagation, gate serial).
- [ ] Task 9: Register new test suites in `package.json`.
- [ ] Task 10: Run `./scripts/sw-pipeline-test.sh` flag-off (regression) and flag-on (smoke).
- [ ] Task 11: Update `.claude/CLAUDE.md` env-vars table (manual section, not AUTO).
- [ ] Task 12: Run `npm test` and resolve any breakage.
- [ ] All 102 existing test suites pass with the flag off.
- [ ] All 102 existing test suites plus 2 new suites pass with the flag on
- [ ] A cycle in a template prints a readable error naming the cycle nodes and
- [ ] A failed stage marks descendants `skipped:upstream_failed`; in-wave
- [ ] `shellcheck` clean on the two new libs and their tests.
- [ ] `VERSION` constant at top of every new script.
- [ ] No `declare -A`, `readarray`, `${var,,}`, or `${var^^}` in new code.
- [ ] No `cd` outside subshells in new helpers.

## Context
- Pipeline: autonomous
- Branch: ci/issue-484
- Issue: none
- Generated: 2026-05-15T13:16:14Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-05-15T13:19:26Z
last_iteration_at: 2026-05-15T13:19:26Z
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

