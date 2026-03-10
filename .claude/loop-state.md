---
goal: "Build Loop Iteration Progress Metrics Dashboard Widget

## Plan Summary
I now have a thorough understanding of the codebase. Here's the implementation plan:

---

# Build Loop Iteration Progress Metrics Dashboard Widget — Implementation Plan

## Product Thinking

### User Stories

1. **Primary**: As a pipeline operator, I want to see real-time build loop progress (iteration count, test status, elapsed time) so that I can detect stuck or degrading builds early without interrupting the running agent.
2. **Secondary**: As a CLI user, I want to run `shipwright loop status` from another terminal so that I can check loop progress without opening the dashboard.

### Acceptance Criteria (Given/When/Then)

- **Given** a build loop is running, **when** an iteration completes, **then** `build_loop_status.json` is written with iteration_number, max_iterations, test_status, files_changed_count, context_usage_percent, time_elapsed.
- **Given** the dashboard is open, **when** build_loop_status.json updates, **then** the widget refreshes within 10 seconds showing current metrics with trend indicators.
- **Given** no loop is running, **when** user runs `shipwright loop status`, **then** it shows "No active build loop" gracefully.

### Edge Cases
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Build Loop Iteration Progress Metrics Dashboard Widget
## Context
## Decision
### Data Flow
### Schema: `build_loop_status.json`
### Error Handling
### New `TEST_PASS_STREAK` Variable
### Write Call Sites in `sw-loop.sh`
## Alternatives Considered
## Implementation Plan
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json",
      "relevance": 90,
      "summary": "Project uses Node.js with vitest test runner, npm package manager, JavaScript, CommonJS imports, and src/ directory structure. Essential for writing and testing the dashboard widget."
    },
    {
      "file": "failures.json",
      "relevance": 40,
      "summary": "Documents test failure patterns in this codebase (mktemp issues, JSON output validation, test assertions). Useful for avoiding common pitfalls when writing tests for the widget."
    },
    {
      "file": "patterns.json (second entry)",
      "relevance": 25,
      "summary": "Generic Node.js project marker from bootstrap detection. Confirms project type but less detailed than the comprehensive patterns entry."
    },
    {
      "file": "global.json",
      "relevance": 5,
      "summary": "Empty cross-repo learnings object. Placeholder for future shared patterns but provides no current actionable data."
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Empty baselines object. Topic is relevant (metrics for dashboard widget) but contains no captured data."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Iteration Progress Metrics Dashboard Widget — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Build Loop Iteration Progress Metrics Dashboard Widget

## Implementation Checklist
- [ ] Task 1: Add `write_build_loop_status()` function to `scripts/lib/loop-progress.sh` with atomic JSON writes
- [ ] Task 2: Add `TEST_PASS_STREAK` counter to `sw-loop.sh` (increment on pass, reset on fail)
- [ ] Task 3: Call `write_build_loop_status` after `write_progress` in the main iteration loop (line ~2384)
- [ ] Task 4: Also call at loop start (initial state) and loop end (final state with status=completed/failed)
- [ ] Task 5: Add `loop_show_status()` function with formatted and `--json` output modes, trend indicators
- [ ] Task 6: Add `status` subcommand dispatch at top of argument parsing in `sw-loop.sh`
- [ ] Task 7: Update `readLogIterations()` in `dashboard/server.ts` to read `build_loop_status.json`
- [ ] Task 8: Add `GET /api/loop-status/:issue` endpoint to dashboard server
- [ ] Task 9: Add build loop metrics widget to pipeline card in `dashboard/src/views/overview.ts`
- [ ] Task 10: Add tests for `write_build_loop_status` and `loop_show_status` to `sw-loop-test.sh`
- [ ] `build_loop_status.json` written atomically after every iteration with all specified fields
- [ ] `shipwright loop status` displays formatted output with trend indicators
- [ ] `shipwright loop status --json` outputs valid, parseable JSON
- [ ] Dashboard pipeline card shows iteration progress, test status, files changed, context usage
- [ ] Dashboard auto-refreshes via existing WebSocket push (no polling needed — already pushes every 2s)
- [ ] All new code follows Bash 3.2 compat rules and project conventions
- [ ] Tests pass: `npm test` green
- [ ] Trend indicators: use existing pattern (consecutive_low_progress for degrading, test_pass_streak for improving)

## Context
- Pipeline: standard
- Branch: feat/build-loop-iteration-progress-metrics-da-247
- Issue: #247
- Generated: 2026-03-10T16:46:21Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-10T16:52:10Z
last_iteration_at: 2026-03-10T16:52:10Z
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

