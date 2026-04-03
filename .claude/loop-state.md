---
goal: "Build Loop Incremental State Checkpointing with Fine-Grained Recovery

## Plan Summary
The implementation plan has been written to `.claude/pipeline-artifacts/plan.md`. Here's a summary:

## Plan Summary

**Approach**: Step-based sub-iteration checkpointing (Alternative B) — add checkpoint saves at 5 step boundaries within each loop iteration, and on restart, skip already-completed steps.

**Why this approach**: The loop already has distinct steps (Claude run → auto-commit → test gate → audit → quality gates). Adding checkpoints between these steps captures 80%+ of the value with minimal blast radius (4-5 new calls in existing flow). Alternatives (hook-based per-file-edit or git-commit-based) were rejected due to high complexity or inability to capture non-file state.

**Files**: 2 new (`scripts/lib/loop-checkpoint.sh`, test suite), 5 modified (`sw-checkpoint.sh`, `sw-loop.sh`, `loop-restart.sh`, `session-restart.sh`, `loop-iteration.sh`)

**12 tasks** with clear dependency chain, **11 test cases** covering unit/integration scenarios, and **3 failure modes** analyzed (disk pressure, multi-agent races, stale checkpoints after git reset).

**Key insight**: The root cause of progress loss is that `run_loop_with_restarts` resets `ITERATION=0` unconditionally (line 2484) and context checkpoints only inform prompt composition, not step-skipping. The fix changes from "restart everything with hints" to "resume from last verified state."
ks run inside the Claude session, not in sw-loop.sh. The loop harness has no visibility into individual tool calls. Would require architectural changes to the hook system to feed state back to the loop. High complexity, high blast radius.
- *Verdict*: Rejected — the loop harness orchestrates at the iteration level, not the tool-call level. Per-file-edit granularity isn't achievable without major architectural changes.

**Alternative B: Step-based sub-iteration checkpointing (CHOSEN)**
- The loop already has distinct steps within each iteration: Claude run -> auto-commit -> test gate -> error summary -> audit -> quality gates -> convergence
- Add checkpoint saves after each meaningful step, using `build-<iteration>-<step>.json` naming
- On restart, find the latest checkpoint and skip already-completed steps
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions

[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json (first entry)",
      "relevance": 92,
      "summary": "Captures multi-iteration build loop patterns with state persistence (.claude/loop-state.md), recovery from failed iterations, and checkpoint-like behavior across 3+ iterations. Directly applicable to incremental state checkpointing implementation."
    },
    {
      "file": "failures.json (first entry)",
      "relevance": 78,
      "summary": "Documents state detection and recovery challenges (stale heartbeat files, dry-run mode, summary output), directly relevant to fine-grained recovery mechanisms and state validation in checkpoint systems."
    },
    {
      "file": "patterns.json (first entry)",
      "relevance": 65,
      "summary": "Project conventions including test strategy (vitest, npm test), source structure (src/), and import style provide foundational context for implementing build stage features like checkpointing."
    },
    {
      "file": "failures.json (second entry)",
      "relevance": 48,
      "summary": "Variable initialization and undefined reference errors in build stage demonstrate common pitfalls that could affect checkpoint state management and recovery logic."
    },
    {
      "file": "success-patterns.json (second entry)",
      "relevance": 42,
      "summary": "Shows bug-fix iteration pattern with npm test strategy and 3-iteration complexity, though sparse details. Demonstrates iteration-based recovery approach applicable to checkpoint recovery phases."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Build Loop Incremental State Checkpointing with Fine-Grained Recovery — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Build Loop Incremental State Checkpointing with Fine-Grained Recovery

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/loop-checkpoint.sh` with sub-iteration checkpoint functions (save, find_latest, restore, clean, step_name/step_num)
- [ ] Task 2: Extend `scripts/sw-checkpoint.sh` with `--step` flag on save, `list-steps` subcommand, and `clean-old` subcommand
- [ ] Task 3: Add 5 checkpoint save calls to `scripts/sw-loop.sh` at step boundaries (post-claude, post-commit, post-test, post-audit, post-quality)
- [ ] Task 4: Add step-skip logic to `scripts/sw-loop.sh` for resuming mid-iteration
- [ ] Task 5: Enhance `scripts/lib/loop-restart.sh` resume_state() to detect and restore sub-iteration checkpoints
- [ ] Task 6: Add checkpoint info to restart briefing in `scripts/lib/session-restart.sh`
- [ ] Task 7: Add sub-iteration checkpoint context to `compose_prompt()` in `scripts/lib/loop-iteration.sh`
- [ ] Task 8: Preserve sub-iteration checkpoints during session restart archival in `scripts/sw-loop.sh`
- [ ] Task 9: Add cleanup call to prune old sub-iteration checkpoints after each iteration
- [ ] Task 10: Write integration test suite `scripts/sw-loop-checkpoint-test.sh` with 11 test cases
- [ ] Task 11: Register test suite in `package.json` scripts section
- [ ] Task 12: Run full test suite to verify no regressions
- [ ] Sub-iteration checkpoints are saved after each of the 5 step boundaries within a loop iteration
- [ ] On resume/restart, the loop restores from the latest sub-iteration checkpoint and skips already-completed steps
- [ ] Restart briefing includes "Restored from checkpoint at iteration N, step M"
- [ ] Old checkpoints are cleaned up (keep last 3 iterations by default)
- [ ] Checkpoint write overhead is <100ms (measured in test)
- [ ] All 11 new test cases pass
- [ ] Existing test suites (`sw-loop-test.sh`, `sw-checkpoint-test.sh`, `sw-session-restart-test.sh`) still pass
- [ ] No regressions in `npm test` full suite

## Context
- Pipeline: standard
- Branch: feat/build-loop-incremental-state-checkpointi-337
- Issue: #337
- Generated: 2026-04-03T18:38:59Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-04-03T18:47:14Z
last_iteration_at: 2026-04-03T18:47:14Z
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

