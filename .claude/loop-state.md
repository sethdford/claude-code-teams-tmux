---
goal: "Decompose sw-loop.sh into Modular Components (Execution)

## Plan Summary
# Implementation Plan — Decompose `sw-loop.sh` into Modular Components

## Summary

`scripts/sw-loop.sh` is **2,675 lines** — the largest script in the repo. A prior
decomposition (pattern from #218) already extracted four libs that are sourced today:
`lib/loop-iteration.sh`, `lib/loop-convergence.sh`, `lib/loop-restart.sh`,
`lib/loop-progress.sh`. This issue **completes** that work by:

1. Adding the two missing target libs: `lib/loop-context.sh` and `lib/loop-prompts.sh`.
2. Realigning ownership so each lib matches its charter from the acceptance criteria.
3. Moving the remaining large orchestration helpers out of `sw-loop.sh`.

### Critical pre-existing constraint (drives the whole plan)

`scripts/sw-loop-test.sh` asserts **implementation location**, not just behavior. It pins
specific definitions/strings to `sw-loop.sh`:

| Test line(s)       | Mechanism                                       | Pinned to `sw-loop.sh`                                                                    |
| ------------------ | ----------------------------------------------- | ----------------------------------------------------------------------------------------- |
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Decompose sw-loop.sh into Modular Components
## Context
## Decision
### Chosen Approach: Five Single-Responsibility Libs + Thin Orchestrator
### Data Flow
### Function API Contracts (Bash)
# Input: globals $GOAL, $LOG_DIR, $ITERATION, $MAX_ITERATIONS
# Output: stdout = full prompt string
# Error: returns 0 always (defensive — never aborts loop)
# Input: args $1=role, $2=agent_id; globals $GOAL
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Decompose sw-loop.sh into Modular Components (Execution)

### Goals
- Create lib/loop-context.sh: context window management, memory injection, file tracking
- Create lib/loop-iteration.sh: iteration execution, test running, progress tracking
- Create lib/loop-convergence.sh: convergence detection, extension logic, goal completion
- Create lib/loop-restart.sh: session restart, progress.md generation, error summary
- Create lib/loop-prompts.sh: prompt composition, structured feedback injection
- sw-loop.sh reduced to <500 lines (orchestration only, delegates to libs)
- All existing sw-loop-test.sh tests pass without modification
- Update lib/compat.sh with any new shared utilities extracted during refactor
- No functional changes (refactor only)
- Add inline documentation to each new lib module (purpose, key functions)

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json (second - 0bcf0637b6e487d78af89f8cd979d6f345ceac82a47adf7d679858271d09634a)",
      "relevance": 75,
      "summary": "Shows successful shell script refactoring patterns with 3-4 iterations on complex changes, including modifications to scripts/lib/*.sh and loop-related files. Demonstrates cost (~2.50 USD) and duration (150s) expectations for moderately complex shell script work."
    },
    {
      "file": "failures.json (first with 5 entries)",
      "relevance": 70,
      "summary": "Contains recent test failures in sw-cleanup.sh, sw-feedback.sh, and mktemp directory handling. Understanding these common pitfalls in shell script testing and output formatting is directly applicable when refactoring sw-loop.sh."
    },
    {
      "file": "knowledge.json",
      "relevance": 65,
      "summary": "Captures mktemp directory creation failures and shell script testing issues (sw-cleanup.sh, sw-feedback.sh) with specific fix strategies. These patterns are relevant for avoiding similar issues during sw-loop.sh decomposition and testing."
    },
    {
      "file": "issues.json",
      "relevance": 60,
      "summary": "Documents a successful shell script timeout bug fix using semaphore approach in daemon/dispatch scripts. Demonstrates a successful pattern for fixing complex shell script issues with specific gotchas to check."
    },
    {
      "file": "patterns.json (first - project detection)",
      "relevance": 45,
      "summary": "Establishes project baseline: Node.js project with vitest and commonjs imports. Provides context for understanding the overall project structure and build environment for sw-loop.sh decomposition work."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Decompose sw-loop.sh into Modular Components (Execution) — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Decompose sw-loop.sh into Modular Components (Execution)

## Implementation Checklist
- [ ] Task 1: Capture baseline PASS count from `./scripts/sw-loop-test.sh` + clean `bash -n`.
- [ ] Task 2: Create `lib/loop-prompts.sh` (guard + doc) with `compose_*` + `write_error_summary` + relocated `compose_prompt`.
- [ ] Task 3: Create `lib/loop-context.sh` (guard + doc) with `manage_context_window`, git tracking, new `inject_memory_context()`.
- [ ] Task 4: Add `format_duration()` to `lib/compat.sh`; remove from `sw-loop.sh`.
- [ ] Task 5: Relocate `run_single_agent_loop`, `run_test_gate`, `diagnose_failure`, `run_audit_agent`, and gates to `lib/loop-iteration.sh`.
- [ ] Task 6: Relocate `show_help`, banners, multi-agent + restart helpers, model/budget selectors out of `sw-loop.sh`.
- [ ] Task 7: Remove `manage_context_window`/`compose_prompt` from `loop-iteration.sh`; update its header doc.
- [ ] Task 8: Add `source` lines for the two new libs in `sw-loop.sh`; verify source order before `main()`.
- [ ] Task 9: Confirm test-pinned primitives + CLI flags + token-accounting strings remain in `sw-loop.sh`.
- [ ] Task 10: Apply dual-path grep updates to ~9 location tests (if Decision Point approved).
- [ ] Task 11: `bash -n` + `shellcheck` all touched files; verify Bash 3.2 compatibility.
- [ ] Task 12: Add inline documentation to every new lib module and function.
- [ ] Task 13: Sync `core-scripts` AUTO docs section in `.claude/CLAUDE.md`.
- [ ] Task 14: `wc -l scripts/sw-loop.sh` < 500 (primary path); full `sw-loop-test.sh` passes with no regressions.
- [ ] `lib/loop-context.sh` and `lib/loop-prompts.sh` created, sourced, documented.
- [ ] Ownership matches charter: context-window mgmt in `loop-context`, prompt composition in
- [ ] `lib/compat.sh` gains the shared `format_duration()` util.
- [ ] `scripts/sw-loop.sh` < 500 lines (primary path), containing only orchestration +
- [ ] `./scripts/sw-loop-test.sh` passes; no assertion's intent changed (only dual-path
- [ ] No functional changes — diff shows relocation + wiring + docs only.

## Context
- Pipeline: standard
- Branch: refactor/decompose-sw-loop-sh-into-modular-compon-641
- Issue: #641
- Generated: 2026-06-13T08:14:17Z

## Failure Diagnosis (Iteration 2)
Classification: unknown
Strategy: retry_with_context
Repeat count: 0

## Failure Diagnosis (Iteration 3)
Classification: unknown
Strategy: retry_with_context
Repeat count: 1"
iteration: 3
max_iterations: 20
status: interrupted
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-06-13T08:53:15Z
last_iteration_at: 2026-06-13T08:53:15Z
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
### Iteration 1 (2026-06-13T08:31:16Z)
- All test-pinned functions and literals remain in place
- Proper module guards prevent double-sourcing
- Functions properly integrated with existing composition system

### Iteration 2 (2026-06-13T08:40:39Z)
- `run_single_agent_loop()` - 423 lines
- `run_loop_with_restarts()` - 123 lines
- `diagnose_failure()` - 106 lines

