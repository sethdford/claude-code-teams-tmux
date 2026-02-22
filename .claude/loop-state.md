---
goal: "Cost-per-issue tracking and optimization dashboard

## Plan Summary
The plan file write was blocked. Let me present the plan directly.

## Implementation Plan: Cost-per-issue tracking and optimization dashboard

### Architecture Analysis

**Existing infrastructure:**
- `sw-cost.sh` already has `cost_record()` with an optional `issue` parameter (5th arg) at line 133
- `sw-pipeline.sh` already passes `ISSUE_NUMBER` to `cost_record()` at line 2588
- `cost_dashboard()` has a basic `--by-issue` flag but only shows raw entry counts from `costs.json`
- `cost_record_outcome()` records pipeline outcomes but without issue attribution

**Gap:** No dedicated per-issue aggregated storage with outcome/duration data, no stats (median, p95), no `per-issue` subcommand, no tests for per-issue features.

### Files to Modify

| File | Action | Purpose |
|------|--------|---------|
| `scripts/sw-cost.sh` | Modify | Add per-issue storage, recording, and display functions; add `per-issue` subcommand |
| `scripts/sw-pipeline.sh` | Modify | Call `cost_record_per_issue()` at pipeline completion (near line 2588) |
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Cost-per-issue tracking and optimization dashboard
## Context
## Decision
### Data Model
### Data Flow
### Statistical Computation
### Error Handling
### CLI Output
## Alternatives Considered
## Implementation Plan
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {"file": "patterns.json", "relevance": 72, "summary": "Project conventions (Node.js, vitest, commonjs) directly inform how to structure the cost tracking dashboard implementation"},
    {"file": "patterns.json", "relevance": 65, "summary": "Bootstrap-detected nodejs project type confirms runtime environment for the build"},
    {"file": "metrics.json", "relevance": 40, "summary": "Empty baselines relevant as cost-per-issue tracking will establish new metric baselines"},
    {"file": "failures.json", "relevance": 20, "summary": "No prior failures to avoid, but relevant as a reference for clean-slate build"},
    {"file": "decisions.json", "relevance": 15, "summary": "No prior architectural decisions recorded that could guide dashboard design choices"}
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Cost-per-issue tracking and optimization dashboard — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cost-per-issue tracking and optimization dashboard

## Implementation Checklist
- [ ] Task 1: Add `PER_ISSUE_FILE` constant and `_ensure_per_issue_file()` helper
- [ ] Task 2: Implement `cost_record_per_issue()` with upsert logic and atomic writes
- [ ] Task 3: Implement `cost_show_per_issue()` with summary stats (median, p95, most expensive)
- [ ] Task 4: Add `--json` output mode to `cost_show_per_issue()`
- [ ] Task 5: Add `per-issue` subcommand to CLI router
- [ ] Task 6: Update `show_help()` with new command documentation
- [ ] Task 7: Wire `cost_record_per_issue()` into `sw-pipeline.sh` finalize section
- [ ] Task 8: Create `sw-cost-per-issue-test.sh` with 10+ test cases
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Run tests and verify all pass

## Context
- Pipeline: standard
- Branch: feat/cost-per-issue-tracking-and-optimization-139
- Issue: #139
- Generated: 2026-02-22T07:34:00Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-02-22T07:36:50Z
last_iteration_at: 2026-02-22T07:36:50Z
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

