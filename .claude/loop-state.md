---
goal: "Pipeline Dry-Run Mode for Execution Plan Validation

## Plan Summary
# Plan: Pipeline Dry-Run Mode for Execution Plan Validation

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** Enhance the existing `run_dry_run()` function in `pipeline-commands.sh` to provide a comprehensive execution plan preview — per-stage cost breakdown, timeout display, intelligence skip predictions, semantic config validation, budget comparison, and structured JSON output.

**Implicit requirements:**
- Must not alter any real pipeline execution behavior (dry-run is read-only)
- JSON output mode needed for CI/programmatic consumption
- Must integrate with existing adaptive timeout engine and intelligence skip system
- Should follow established dry-run patterns across the codebase (e.g., sw-cleanup.sh, sw-fix.sh)

**Acceptance criteria:**
1. `--dry-run` shows per-stage cost estimates (input tokens, output tokens, model, USD cost)
2. `--dry-run` shows per-stage timeouts (default + adaptive when available)
3. `--dry-run` shows intelligence skip predictions (which stages would be skipped and why)
4. `--dry-run` performs semantic config validation (stage ordering, gate values, id presence)
5. `--dry-run` shows budget status (estimated cost vs remaining daily budget)
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Pipeline Dry-Run Mode for Execution Plan Validation
## Context
## Decision
### Component Diagram
### Data Flow
### Interface Contracts
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains specific dry-run mode failures in sw-cleanup.sh affecting heartbeat detection and output formatting—directly addresses the execution plan validation dry-run context with concrete fixes"
    },
    {
      "file": "patterns.json",
      "relevance": 70,
      "summary": "Project structure with vitest test runner, npm conventions, and source layout essential for understanding build stage dependencies and test execution patterns"
    },
    {
      "file": "patterns.json",
      "relevance": 35,
      "summary": "Generic nodejs project type detection from bootstrap—minimal context but confirms language/runtime for build stage configuration"
    },
    {
      "file": "metrics.json",
      "relevance": 8,
      "summary": "Empty baselines structure—minimal utility for current build stage planning"
    },
    {
      "file": "decisions.json",
      "relevance": 5,
      "summary": "Empty decisions log—no prior architectural choices or context available for dry-run mode implementation"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pipeline Dry-Run Mode for Execution Plan Validation — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Pipeline Dry-Run Mode for Execution Plan Validation

## Implementation Checklist
- [ ] Task 1: Add `DRY_RUN_JSON` flag parsing to `scripts/lib/pipeline-cli.sh` and update help text
- [ ] Task 2: Add `_dry_run_fmt_duration()` helper function to `pipeline-commands.sh`
- [ ] Task 3: Add `_dry_run_stage_token_estimate()` helper function for per-stage token estimates
- [ ] Task 4: Add `_dry_run_model_cost_rate()` and `_dry_run_get_stage_timeout()` helpers
- [ ] Task 5: Enhance stage table with timeout column in `run_dry_run()`
- [ ] Task 6: Add per-stage cost breakdown section to `run_dry_run()`
- [ ] Task 7: Add configuration validation section with semantic checks
- [ ] Task 8: Add intelligence skip predictions section
- [ ] Task 9: Add budget status section reading from `~/.shipwright/budget.json`
- [ ] Task 10: Add summary section replacing simple pass/fail message
- [ ] Task 11: Implement JSON output mode (`--json` flag) using `jq -n`
- [ ] Task 12: Add `test_dry_run_shows_timeouts` test
- [ ] Task 13: Add `test_dry_run_shows_per_stage_cost` test
- [ ] Task 14: Add `test_dry_run_validates_config` test
- [ ] Task 15: Add `test_dry_run_shows_summary` and `test_dry_run_json_output` tests
- [ ] Task 16: Run full test suite and fix any regressions
- [ ] `shipwright pipeline start --goal "test" --dry-run` shows per-stage cost table with token counts and USD
- [ ] `shipwright pipeline start --goal "test" --dry-run` shows per-stage timeout (default + adaptive)
- [ ] `shipwright pipeline start --goal "test" --dry-run` shows intelligence skip predictions
- [ ] `shipwright pipeline start --goal "test" --dry-run` performs semantic config validation (stage ordering, gate values)

## Context
- Pipeline: autonomous
- Branch: ci/issue-239
- Issue: none
- Generated: 2026-03-09T06:23:02Z

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
started_at: 2026-03-09T06:46:12Z
last_iteration_at: 2026-03-09T06:46:12Z
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
### Iteration 1 (2026-03-09T06:42:06Z)
{"type":"result","subtype":"success","is_error":false,"duration_ms":5143,"duration_api_ms":517830,"num_turns":1,"result"

