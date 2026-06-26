---
goal: "Project-Type Auto-Detection & Optimal Template Selector

## Plan Summary
# Implementation Plan: Project-Type Auto-Detection & Optimal Template Selector

## Summary & Key Finding

A fully-featured detection engine **already exists and is unit-tested** but is **dead code in production** — `scripts/lib/project-detect.sh` (~650 lines) is sourced only by its own test (`scripts/sw-project-detect-test.sh`), never by the daemon, pipeline, or CLI. It already provides:

- `project_detect_type(root)` — language/framework/package-manager/test-runner (8 languages, 20+ frameworks)
- `project_recommend_template(root)` — returns `{template, confidence, reason}` (fast/standard/full/deployed)
- `project_detect_all(root)` — cached full report → `.claude/project-detection.json` (1h TTL)

Meanwhile `select_pipeline_template()` in `scripts/lib/daemon-triage.sh:217` runs a sophisticated multi-factor decision tree (DORA, branch protection, labels, quality memory, Thompson sampling) but its **final fallback is a blind issue-score→template map** (`scripts/lib/daemon-triage.sh:438-446`) that ignores the actual project type. A 5-file Bash microservice and a 500-file deployed monolith get the same template for the same score.

**Therefore the MVP is integration, not reinvention:** expose the existing detector via a CLI command, and feed its template recommendation into the selector's fallback as a project-aware default. This minimizes blast radius (the detector is already proven by 434 lines of tests) and delivers the user-visible value (correct template per project type).

### Requirements Clarity (Socratic, self-answered)

- **Minimum viable change:** Wire `project_recommend_template()` into the `select_pipeline_template()` fallback, and add a `shipwright detect` CLI command. Detection logic itself needs no changes.
- **Implicit requirements:** Output must be observable (`emit_event`); the new factor must not override stronger explicit signals (labels, branch protection, quality memory); it must degrade to current behavior when detection is unavailable.
- **Acceptance criteria (from `spec.json`):** "All existing tests continue to pass." Augmented below with feature-specific, testable criteria.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Project-Type Auto-Detection & Optimal Template Selector
## Context
## Decision
### Decision Rationale
### Key Design Constraints
## Alternatives Considered
### Alternative A: Unify All Three Detection Paths (Rejected)
### Alternative B: New Claude-Driven Selector (Rejected)
### Alternative C: Extend the Existing Detector In-Place (Not Chosen)
## Component Diagram
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Project-Type Auto-Detection & Optimal Template Selector

### Goals
- Project-Type Auto-Detection & Optimal Template Selector

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 95,
      "summary": "Direct project type detection output for sethdford/shipwright (Node, vitest, npm, javascript) — shows exactly what the auto-detection feature should produce"
    },
    {
      "file": "success-patterns.json (shipwright repo)",
      "relevance": 85,
      "summary": "Success patterns from this exact repo showing bug fixes with 3 iterations, npm test strategy, standard template — demonstrates proven build patterns for this project type"
    },
    {
      "file": "success-patterns.json (test-repo-stages)",
      "relevance": 75,
      "summary": "Shows staged pipeline execution through intake→plan→build→test→review with npm test strategy — demonstrates how build stage fits into template-driven pipeline"
    },
    {
      "file": "knowledge.json",
      "relevance": 70,
      "summary": "Captures failure patterns (mktemp, test output formatting, JSON generation) that build stage needs to avoid — provides learned fixes from prior attempts"
    },
    {
      "file": "metrics.json",
      "relevance": 60,
      "summary": "Baseline build duration (2089s) enables template selector to optimize stage timeouts and iteration limits based on historical performance"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Project-Type Auto-Detection & Optimal Template Selector — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Project-Type Auto-Detection & Optimal Template Selector

## Implementation Checklist
- [ ] Task 1: Read & lock the public contract of `project_recommend_template` / `project_detect_all`
- [ ] Task 2: Create `scripts/sw-detect.sh` (report + `--json` + `--help`/`--version`, subshell path handling)
- [ ] Task 3: Add guarded source of `lib/project-detect.sh` in `daemon-triage.sh`
- [ ] Task 4: Replace blind score fallback with confidence-gated project-aware selection (≥75 → detected template)
- [ ] Task 5: Register `detect)` dispatch case + help line in `scripts/sw`
- [ ] Task 6: Emit `detect.completed` and `daemon.project_template` events
- [ ] Task 7: Write `scripts/sw-detect-test.sh` using `lib/test-helpers.sh`
- [ ] Task 8: Add selector-contract assertions to `sw-project-detect-test.sh`
- [ ] Task 9: Register `sw-detect-test.sh` in `package.json` `"test"` chain
- [ ] Task 10: Update `.claude/CLAUDE.md` command table + templates note
- [ ] Task 11: Verify `VERSION` consistency (`shipwright version check`)
- [ ] Task 12: Run `sw-detect-test.sh` + `sw-project-detect-test.sh`, then `npm test`
- [ ] `shipwright detect` prints a correct human report for this repo (node/vitest/npm)
- [ ] `shipwright detect --json` emits valid JSON parseable by `jq` with stable keys (`type`, `recommended_template.{template,confidence,reason}`)
- [ ] `select_pipeline_template()` uses the project recommendation when confidence ≥ 75, else preserves the existing score map
- [ ] Selector degrades to current behavior when the detection lib/function is absent (no regression)
- [ ] `detect.completed` and `daemon.project_template` events emitted
- [ ] New test suite passes and is registered in `package.json`
- [ ] All existing tests pass (`npm test`) — **spec acceptance criterion**
- [ ] `shipwright version check` passes (VERSION synced)

## Context
- Pipeline: autonomous
- Branch: ci/issue-698
- Issue: none
- Generated: 2026-06-26T01:50:22Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-06-26T01:54:20Z
last_iteration_at: 2026-06-26T01:54:20Z
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

