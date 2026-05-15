---
goal: "Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start

## Plan Summary
# Plan — Pre-Flight Issue Feasibility Validator

## Goal

Catch doomed pipelines **before** they consume hours/dollars by scoring an issue's feasibility at the very front of the pipeline. If an issue is too vague, contradicts itself, conflicts with architecture rules, or exceeds budget/scope thresholds, abort with a clear, actionable report instead of grinding through 14 stages.

## Brainstorming (Socratic, self-answered)

**Minimum viable change.** A single new library `scripts/lib/pipeline-feasibility.sh` plus an invocation inside `stage_intake` (`scripts/lib/pipeline-stages-intake.sh`) that runs **after** issue metadata and spec are loaded and **before** `stage_plan`. It produces `feasibility.json` and, when score < threshold, returns non-zero with a written `feasibility-report.md` and a posted GitHub comment.

**Acceptance criteria (defined here, not in spec).**
1. New lib `scripts/lib/pipeline-feasibility.sh` exists with `feasibility_score`, `feasibility_report`, `feasibility_gate` functions.
2. `stage_intake` calls `feasibility_gate` after spec generation; on BLOCK it returns 1 and writes `feasibility.json` + `feasibility-report.md` to `$ARTIFACTS_DIR`.
3. Threshold is config-driven via `daemon-config.json` key `feasibility.min_score` (default 40), with env override `SW_FEASIBILITY_MIN_SCORE`. A `feasibility.enabled=false` flag disables the gate.
4. Validator covers ≥6 heuristics: body length / vagueness, missing acceptance criteria, conflicting labels, architecture-rule hints, estimated scope (file-touch count from `spec.affected_files`), historical-failure similarity (memory lookup), and budget feasibility.
5. New test suite `scripts/sw-pipeline-feasibility-test.sh` runs ≥10 cases with mock binaries; registered in `package.json`.
6. `npm test` still passes; doctor passes; `shipwright version check` passes.
7. Doc auto-section (`AUTO:core-scripts`, `AUTO:test-suites`, `AUTO:feature-flags`) refreshed by `shipwright docs sync`.

### Design alternatives
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start
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

## Specification: Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start

### Goals
- Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json",
      "relevance": 95,
      "summary": "Contains recent test failures (sw-cleanup.sh detection, regression JSON output, mktemp /tmp/claude issue, daemon retry logic) directly applicable to build stage debugging and CI test failures"
    },
    {
      "file": "patterns.json",
      "relevance": 90,
      "summary": "Captures project structure: Node.js, vitest test runner, commonjs imports, src/ source directory—essential context for build stage execution and test configuration"
    },
    {
      "file": "failures.json",
      "relevance": 85,
      "summary": "Documents ENOENT error and npm install fix—directly relevant to build stage dependency installation phase"
    },
    {
      "file": "success-patterns.json",
      "relevance": 70,
      "summary": "Shows successful bug fix approach using 3 iterations with complexity 60, affecting test and script files—patterns applicable to current build stage strategy"
    },
    {
      "file": "issues.json",
      "relevance": 40,
      "summary": "Records daemon timeout bug fix using semaphore pattern—provides context for handling timing issues in async operations during build"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Pre-Flight Issue Feasibility Validator — Catch Doomed Pipelines Before They Start

## Implementation Checklist
- [ ] T1 Create `scripts/lib/pipeline-feasibility.sh` skeleton + public stubs (blocks T2–T7)
- [ ] T2 Implement 8 heuristic checks + scoring/clamping (depends on T1)
- [ ] T3 Implement atomic JSON + Markdown report writers (depends on T1)
- [ ] T4 Implement `feasibility_gate` with `emit_event`, GH comment, BLOCK label (depends on T2, T3)
- [ ] T5 Optional LLM second-pass behind `feasibility.llm_enabled` (depends on T4)
- [ ] T6 Source new lib from bootstrap; verify load order (depends on T1)
- [ ] T7 Wire `feasibility_gate` into `stage_intake` as step 10 (depends on T4, T6)
- [ ] T8 Add doctor section validating new lib (depends on T6)
- [ ] T9 Write `sw-pipeline-feasibility-test.sh` with ≥10 cases incl. mocks (depends on T2–T7)
- [ ] T10 Register test suite in `package.json` (depends on T9)
- [ ] T11 Document `feasibility.*` defaults in CLAUDE.md feature-flags AUTO section
- [ ] T12 Run `npm test`; fix regressions
- [ ] T13 Run `shipwright docs sync` + `shipwright doctor` + `shipwright version check`
- [ ] T14 Manual smoke: short goal → BLOCK; well-formed goal → PASS
- [ ] All 8 heuristics implemented and unit-tested.
- [ ] `feasibility_gate` runs exactly once per pipeline (post-spec, pre-plan).
- [ ] BLOCK verdict produces `feasibility-report.md`, GitHub comment (when enabled), `pipeline/infeasible` label, and non-zero return that halts the pipeline cleanly.
- [ ] `feasibility.enabled=false` cleanly bypasses with no overhead.
- [ ] `npm test` green; new suite ≥10 PASSes, 0 FAILs.
- [ ] `shipwright doctor` and `shipwright version check` green.

## Context
- Pipeline: autonomous
- Branch: ci/issue-488
- Issue: none
- Generated: 2026-05-15T13:16:24Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-05-15T13:31:21Z
last_iteration_at: 2026-05-15T13:31:21Z
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

