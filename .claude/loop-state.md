---
goal: "Cost Impact Preview & Budget-Aware Template Selector

## Plan Summary
# Implementation Plan — Cost Impact Preview & Budget-Aware Template Selector

## Summary

Give operators a **forward-looking cost preview** for any pipeline template and an
**automatic budget-aware template selector** that picks the richest pipeline template
whose predicted cost fits the remaining daily budget. Today Shipwright only reports
*historical* spend (`cost show`) and has a human-only estimate table
(`model estimate`) that ignores which stages a template actually enables. This feature
closes the gap between "what will this run cost?" and "what should I run given my budget?".

## Brainstorming / Socratic Reasoning (answered, not asked)

**Minimum viable change.** A cost estimator that (a) reads the *real* stage set and
per-stage model routing from a template JSON, (b) multiplies by the existing pricing
table and a per-stage token model, and (c) compares the result to
`cost_remaining_budget`. Everything else (selector, JSON output) builds on that single
estimator function.

**Implicit requirements.** Must be Bash 3.2 compatible, must degrade gracefully when no
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Cost Impact Preview & Budget-Aware Template Selector
## Context
## Decision
## Alternatives Considered
## Implementation Plan
## Component Diagram
## Interface Contracts
## Error Boundaries
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Cost Impact Preview & Budget-Aware Template Selector

### Goals
- Cost Impact Preview & Budget-Aware Template Selector

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json (project detection)",
      "relevance": 95,
      "summary": "Defines project structure (Node.js, vitest, src/test directories, commonjs). Essential for build stage to understand what files to run, test patterns, and conventions."
    },
    {
      "file": "metrics.json (first entry with baselines)",
      "relevance": 90,
      "summary": "Contains build_duration_s baseline of 2089s (~35 min). Critical for budget-aware template selector to estimate costs and select appropriate pipeline template."
    },
    {
      "file": "success-patterns.json (second entry with bug fix and auth feature)",
      "relevance": 85,
      "summary": "Shows successful builds with 3-4 iterations, $2.50 cost, specific file patterns (.claude/*, scripts/lib/*). Provides cost and iteration benchmarks for current build."
    },
    {
      "file": "failures.json (first entry with test failures)",
      "relevance": 70,
      "summary": "Recent test failures (cleanup.sh output format, template errors). Build stage should watch for these patterns to avoid regressions."
    },
    {
      "file": "knowledge.json (failure patterns with fixes)",
      "relevance": 68,
      "summary": "Captured test failures (mktemp directory issues, cleanup output format) with fix strategies. Helps build stage prevent known test failures."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Cost Impact Preview & Budget-Aware Template Selector — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cost Impact Preview & Budget-Aware Template Selector

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/cost-preview.sh` scaffold (version, source guards, no side effects on source).
- [ ] Task 2: Implement `_cp_stage_tokens` (Bash 3.2 case map, default fallback).
- [ ] Task 3: Implement `_cp_stage_model` (jq with `--arg`, layered fallback).
- [ ] Task 4: Implement `cp_estimate_template` (enabled-stages-only, awk accumulation, missing-template error path).
- [ ] Task 5: Implement `cp_preview_one` with human + `--json` output.
- [ ] Task 6: Implement `cp_preview_all` (sorted ascending by cost, human + JSON, skip-bad-file).
- [ ] Task 7: Implement `cp_select` budget-aware algorithm + `emit_event`.
- [ ] Task 8: Wire `preview`/`select` subcommands and help text into `sw-cost.sh`.
- [ ] Task 9: Refactor `estimate_cost` in `sw-model-router.sh` to reuse token map (output-compatible).
- [ ] Task 10: Write `scripts/sw-cost-preview-test.sh`.
- [ ] Task 11: Register new test in `package.json`.
- [ ] Task 12: Update `.claude/CLAUDE.md` cost command rows.
- [ ] Task 13: Sync `VERSION` and run `npm test`; confirm green.
- [ ] `cost preview <template> [complexity]`, `cost preview --all`, and `cost select` work and are documented in `show_help` + `.claude/CLAUDE.md`.
- [ ] `--json` output for all three is valid (`jq -e .` exits 0).
- [ ] Estimates respect each template's actual `enabled` stages and per-stage model routing.
- [ ] `cp_select` is budget-aware: unlimited → default; tight → most-capable-that-fits; none → cheapest + warn; emits `cost.template_selected`.
- [ ] New `scripts/sw-cost-preview-test.sh` passes and is registered in `package.json`.
- [ ] `sw-cost-test.sh` and `sw-model-router-test.sh` still pass; full `npm test` green.
- [ ] All new/edited scripts are Bash 3.2 compatible, `set -euo pipefail`, atomic writes, `jq --arg`, `VERSION` synced.

## Context
- Pipeline: autonomous
- Branch: ci/issue-670
- Issue: none
- Generated: 2026-06-19T14:13:17Z"
iteration: 0
max_iterations: 20
status: budget_exhausted
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-06-19T14:27:40Z
last_iteration_at: 2026-06-19T14:27:40Z
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

