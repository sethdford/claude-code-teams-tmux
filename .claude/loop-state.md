---
goal: "Meta-Feature Detection Gate with Mandatory Decomposition Requirement

## Plan Summary


Now I have a complete picture of the codebase. Here's the implementation plan:

---

# Implementation Plan: Meta-Feature Detection Gate with Mandatory Decomposition

## Brainstorming: Design Refinement

### Requirements Clarity
**Minimum viable change**: Add a `detect_meta_feature()` function to the pipeline detection library that checks file paths against `scripts/`, `dashboard/`, `lib/`, `templates/`, `.claude/`. Wire it into `stage_intake()` to block with a helpful error when a meta-feature is detected without prior decomposition. Add `--create-subtasks` flag to `shipwright decompose`.

**Implicit requirements**: 
- The detection must work both with `--issue` (GitHub issue body analysis) and `--goal` (keyword/path analysis)
- Must integrate with existing daemon `auto` mode (daemon should auto-decompose, not just block)
- Must respect `NO_GITHUB` for testing

**Acceptance criteria**: Defined in the issue — 6 concrete criteria.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Meta-Feature Detection Gate with Mandatory Decomposition Requirement
## Context
## Decision
### Detection: Weighted scoring, not binary keyword matching
### Gate: Block at intake with actionable error
### Bypass paths (critical for avoiding deadlocks)
### CLI enhancement
## Alternatives Considered
## Component Diagram
## Interface Contracts
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 85,
      "summary": "Project structure conventions essential for build stage: source_dir=src/, test_pattern=*.test.js, test_runner=vitest. Directly guides where to write implementation and test files."
    },
    {
      "file": "failures.json",
      "relevance": 62,
      "summary": "Known test failures and root causes. sw-feedback-test.sh JSON output issue and classification logic gaps could surface during implementation and testing phases."
    },
    {
      "file": "patterns.json",
      "relevance": 24,
      "summary": "Confirms nodejs project type. Older than primary patterns.json (2026-02-21). Redundant with more detailed entry above."
    },
    {
      "file": "global.json",
      "relevance": 8,
      "summary": "Cross-repo learnings structure. Currently empty but could surface relevant patterns if populated from previous runs."
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Baselines for performance metrics. Empty; not actionable for build stage implementation."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Meta-Feature Detection Gate with Mandatory Decomposition Requirement — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Meta-Feature Detection Gate with Mandatory Decomposition Requirement

## Implementation Checklist
- [ ] Task 1: Add `detect_meta_feature()` function to `scripts/lib/pipeline-detection.sh`
- [ ] Task 2: Add `check_meta_feature_decomposition()` function to `scripts/lib/pipeline-detection.sh`
- [ ] Task 3: Wire meta-feature gate into `stage_intake()` in `scripts/lib/pipeline-stages-intake.sh`
- [ ] Task 4: Add `--issue N --create-subtasks` CLI flag to `scripts/sw-decompose.sh`
- [ ] Task 5: Add unit tests for `detect_meta_feature()` to `scripts/sw-lib-pipeline-detection-test.sh`
- [ ] Task 6: Add unit tests for `check_meta_feature_decomposition()` to `scripts/sw-lib-pipeline-detection-test.sh`
- [ ] Task 7: Create `scripts/sw-meta-feature-test.sh` E2E test suite
- [ ] Task 8: Register new test in `package.json` scripts
- [ ] Task 9: Run full test suite and fix any regressions
- [ ] `detect_meta_feature()` correctly identifies issues targeting `scripts/`, `dashboard/`, `lib/`, `templates/`, `.claude/`
- [ ] Pipeline blocks at intake when meta-feature detected without decomposition
- [ ] Error message includes exact `shipwright decompose --issue N --create-subtasks` command
- [ ] Issues with "subtask" or "decomposed" labels bypass the gate
- [ ] `shipwright decompose --issue N --create-subtasks` creates 2-3 GitHub subtask issues
- [ ] All new tests pass
- [ ] All existing tests pass (no regressions)
- [ ] `NO_GITHUB=true` mode works for all new code paths

## Context
- Pipeline: standard
- Branch: feat/meta-feature-detection-gate-with-mandato-250
- Issue: #250
- Generated: 2026-03-11T02:10:21Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-11T02:16:25Z
last_iteration_at: 2026-03-11T02:16:25Z
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

