# Design: Build Loop Incremental State Checkpointing with Fine-Grained Recovery

## Context

The build loop (`scripts/sw-loop.sh`) orchestrates autonomous Claude Code iterations through a 5-step pipeline per iteration: Claude run, auto-commit, test gate, audit, and quality gates. When a session exhausts its context window or crashes, `run_loop_with_restarts()` (line 2440) triggers a session restart -- but **unconditionally resets `ITERATION=0`** (line 2484) and clears all iteration state (lines 2485-2494). The existing checkpoint system (`scripts/sw-checkpoint.sh`) saves a single `build-checkpoint.json` per stage, used only for prompt composition hints -- not for skipping already-completed work.

**Root cause of progress loss**: The restart flow treats checkpoints as advisory context, not as resumable state. A crash at post-test in iteration 7 restarts from iteration 0, re-running all 7 iterations of Claude invocations and test executions. This wastes tokens, time, and often leads to divergent solutions because the fresh session re-solves problems differently.

**Constraints from the codebase**:
- All scripts must be Bash 3.2 compatible (no `declare -A`, no `readarray`)
- Atomic writes required (`tmp` + `mv`, never direct `echo > file`)
- JSON via `jq --arg` for proper escaping, never string interpolation
- Existing checkpoint infrastructure in `sw-checkpoint.sh` must remain backward-compatible
- Multi-agent mode uses separate worktrees (each agent has its own `.claude/pipeline-artifacts/`)
- The loop harness orchestrates at the iteration level; it has no visibility into individual Claude tool calls

## Decision

**Step-based sub-iteration checkpointing**: Save checkpoint state at 5 step boundaries within each loop iteration, and on restart, skip already-completed steps by comparing the current step number against the restored checkpoint's step number.

### Checkpoint Schema

Each sub-iteration checkpoint is a JSON file at `.claude/pipeline-artifacts/checkpoints/build-<iteration>-<step>-checkpoint.json`:

```json
{
  "iteration": 7,
  "step": "post-test",
  "step_num": 3,
  "timestamp": "2026-04-03T12:34:56Z",
  "git_sha": "abc1234",
  "test_passed": "true",
  "test_output_tail": "...",
  "modified_files": "src/auth.ts,src/middleware.ts",
  "total_commits": 12,
  "agent_num": 1
}
```

### Step Ordering (Numeric for Comparison)

```
STEP_POST_CLAUDE=1   # After Claude invocation + stuckness recording
STEP_POST_COMMIT=2   # After auto-commit + velocity tracking
STEP_POST_TEST=3     # After test gate + error summary
STEP_POST_AUDIT=4    # After audit agent + verification gap handling
STEP_POST_QUALITY=5  # After quality gates + convergence detection
```

### Resume Semantics

On restart, `resume_state()` in `loop-restart.sh` finds the latest sub-iteration checkpoint via filename parsing (highest iteration, then highest step number). The loop sets `RESUME_FROM_STEP_NUM` and skips steps where `CURRENT_STEP <= RESTORED_STEP_NUM` for the first iteration only. Subsequent iterations run all steps.

### Git SHA Validation

Before restoring, validate that the checkpoint's `git_sha` is an ancestor of `HEAD`:
```bash
git merge-base --is-ancestor "$ckpt_sha" HEAD
```
If not (e.g., after `git reset --hard`), skip the sub-iteration checkpoint and fall back to full-iteration resume. This prevents silent state/code divergence.

### Retention Policy

Keep sub-iteration checkpoints for the last 3 iterations only. `sub_checkpoint_clean 3` runs at the end of each completed iteration. At 5 checkpoints/iteration, this bounds storage to 15 files maximum.

## Component Diagram

```
                    ┌─────────────────────────────────────────────┐
                    │         sw-loop.sh (Orchestrator)           │
                    │  run_single_agent_loop() / run_loop_with_   │
                    │  restarts()                                  │
                    │                                              │
                    │  Step boundaries:                            │
                    │  [1]Claude -> [2]Commit -> [3]Test ->       │
                    │  [4]Audit -> [5]Quality                     │
                    └────┬──────────┬──────────┬──────────────────┘
                         │          │          │
              save/skip  │   resume │   brief  │
                         v          │          v
    ┌────────────────────────┐  │  ┌──────────────────────────┐
    │  lib/loop-checkpoint.sh│  │  │  lib/session-restart.sh  │
    │  (NEW -- Checkpoint Lib│  │  │  (Restart Briefing)      │
    │                        │  │  │                          │
    │  sub_checkpoint_save() │  │  │  restart_capture_state() │
    │  sub_checkpoint_find_  │  │  │  restart_generate_       │
    │    latest()            │  │  │    briefing()            │
    │  sub_checkpoint_       │  │  │                          │
    │    restore()           │  │  │  Adds: "Restored from    │
    │  sub_checkpoint_clean()│  │  │   iter N, step M" section│
    └─────────┬──────────────┘  │  └──────────────────────────┘
              │                 │
              │ file I/O        │ restore
              v                 v
    ┌─────────────────────────────────────────┐
    │  .claude/pipeline-artifacts/checkpoints/ │
    │                                          │
    │  build-7-post-test-checkpoint.json       │
    │  build-7-post-commit-checkpoint.json     │
    │  build-7-post-claude-checkpoint.json     │
    │  build-6-post-quality-checkpoint.json    │
    │  build-checkpoint.json (existing)        │
    │  build-claude-context.json (existing)    │
    └─────────────────────────────────────────┘
              ^                 ^
              │ read            │ restore context
              │                 │
    ┌─────────┴────────┐  ┌────┴──────────────────┐
    │ sw-checkpoint.sh  │  │ lib/loop-restart.sh   │
    │ (Extended)        │  │ (Enhanced resume)     │
    │                   │  │                       │
    │ + list-steps cmd  │  │ resume_state() now    │
    │ + --step flag     │  │ checks sub-iteration  │
    │ + clean-old cmd   │  │ checkpoints first     │
    └──────────────────┘  └───────────────────────┘
              ^
              │ prompt context
    ┌─────────┴────────────────┐
    │ lib/loop-iteration.sh    │
    │                          │
    │ compose_prompt() adds    │
    │ "Steps completed: ..."   │
    │ to resume section        │
    └──────────────────────────┘
```

**Dependency direction**: `sw-loop.sh` (outer) depends on all inner libraries. Libraries depend only on the filesystem (checkpoint directory) and `jq`. No circular dependencies.

## Interface Contracts

### `scripts/lib/loop-checkpoint.sh` (NEW)

```typescript
// Step constants (bash: STEP_POST_CLAUDE=1, etc.)
type StepName = "post-claude" | "post-commit" | "post-test" | "post-audit" | "post-quality";
type StepNum = 1 | 2 | 3 | 4 | 5;

interface SubCheckpoint {
  iteration: number;         // Loop iteration (1-based)
  step: StepName;            // Human-readable step name
  step_num: StepNum;         // Numeric for ordering/comparison
  timestamp: string;         // ISO 8601 UTC
  git_sha: string;           // HEAD at checkpoint time
  test_passed?: string;      // "true" | "false" | "unknown"
  test_output_tail?: string; // Last 50 lines of test output
  modified_files?: string;   // Comma-separated file paths
  total_commits?: number;    // Running commit counter
  agent_num?: number;        // For multi-agent disambiguation
  [key: string]: unknown;    // Step-specific data (audit_result, etc.)
}

// Save a sub-iteration checkpoint. Atomic write (tmp + mv).
// Returns 0 on success. Logs warning and returns 0 on write failure (non-fatal).
function sub_checkpoint_save(
  iteration: number, step_name: StepName, data_json: string
): 0;

// Find the most recent sub-iteration checkpoint file path.
// Returns file path on stdout. Returns 1 if no checkpoints found.
function sub_checkpoint_find_latest(): string | Error;

// Restore state from a checkpoint file. Exports RESTORED_ITERATION,
// RESTORED_STEP, RESTORED_STEP_NUM to the calling shell.
// Validates git SHA ancestry; returns 1 if checkpoint is stale.
function sub_checkpoint_restore(checkpoint_file: string): 0 | 1;

// Remove checkpoints older than `keep_iterations` back from current max.
// Default: keep=3. Returns 0 always.
function sub_checkpoint_clean(keep_iterations?: number): 0;

// Map step number to name and vice versa.
function sub_checkpoint_step_name(step_num: StepNum): StepName;
function sub_checkpoint_step_num(step_name: StepName): StepNum;

// Human-readable list of steps completed before `step_name`.
// E.g., "post-test" -> "Claude run, auto-commit, test execution"
function sub_checkpoint_completed_steps(step_name: StepName): string;
```

### `scripts/sw-checkpoint.sh` (Extended)

```typescript
// New subcommand: list sub-iteration checkpoints
// Usage: sw-checkpoint.sh list-steps --stage build [--iteration N]
function cmd_list_steps(stage: string, iteration?: number): void;

// Extended save: --step flag adds step to filename
// Usage: sw-checkpoint.sh save --stage build --iteration 5 --step post-test
// Filename: build-5-post-test-checkpoint.json (with --step)
//           build-checkpoint.json (without --step, existing behavior)
function cmd_save(
  stage: string, iteration?: number, step?: StepName
): void;

// New subcommand: remove old sub-iteration checkpoints
// Usage: sw-checkpoint.sh clean-old --stage build --keep 3
function cmd_clean_old(stage: string, keep: number): void;
```

### `scripts/lib/loop-restart.sh` (Enhanced)

```typescript
// Enhanced resume_state(): after existing checkpoint_restore_context call,
// checks for sub-iteration checkpoints. If found and git SHA is valid,
// exports RESUME_FROM_STEP and RESUME_FROM_STEP_NUM.
// Fallback: if no sub-checkpoints or stale SHA, existing behavior unchanged.
function resume_state(): void;
// New exports when sub-checkpoint found:
//   RESUME_FROM_STEP: StepName
//   RESUME_FROM_STEP_NUM: StepNum
```

### Error Contracts

| Function | Error condition | Behavior |
|---|---|---|
| `sub_checkpoint_save` | Disk full / write failure | Logs warning, returns 0 (non-fatal). Loop continues without checkpoint. |
| `sub_checkpoint_find_latest` | No checkpoint files exist | Returns 1. Caller falls back to full-iteration resume. |
| `sub_checkpoint_restore` | Corrupted JSON | Logs warning, returns 1. Caller falls back to previous checkpoint. |
| `sub_checkpoint_restore` | Stale git SHA (not ancestor of HEAD) | Logs warning, returns 1. Caller falls back to full-iteration resume. |
| `sub_checkpoint_clean` | Checkpoint dir missing | Returns 0 (no-op). |

## Data Flow

### Save Path (per iteration step)

```
sw-loop.sh:run_single_agent_loop()
  |
  +-- [Step 1: Claude run completes]  (~line 2192)
  |   +-- sub_checkpoint_save(ITERATION, "post-claude", json)
  |       +-- jq builds JSON -> write to tmp file -> mv to
  |          checkpoints/build-{iter}-post-claude-checkpoint.json
  |
  +-- [Step 2: Auto-commit completes]  (~line 2226)
  |   +-- sub_checkpoint_save(ITERATION, "post-commit", json)
  |
  +-- [Step 3: Test gate completes]  (~line 2247)
  |   +-- sub_checkpoint_save(ITERATION, "post-test", json)
  |
  +-- [Step 4: Audit completes]  (~line 2315)
  |   +-- sub_checkpoint_save(ITERATION, "post-audit", json)
  |
  +-- [Step 5: Quality gates + convergence]  (~line 2357)
  |   +-- sub_checkpoint_save(ITERATION, "post-quality", json)
  |
  +-- [End of iteration]
      +-- sub_checkpoint_clean(3)  // Prune iterations > 3 back
```

### Restore Path (on restart)

```
run_loop_with_restarts()         [line 2440]
  | resets ITERATION=0            [line 2484]
  | sets SESSION_RESTART=true
  |
  +-- run_single_agent_loop()
      |
      +-- resume_state()                    [loop-restart.sh:102]
          |
          +-- checkpoint_restore_context()  [existing: prompt hints]
          |
          +-- sub_checkpoint_find_latest()  [NEW: step-level restore]
              |
              +-- Scan checkpoints/build-*-*-checkpoint.json
              |   Sort by iteration (desc), then step_num (desc)
              |   Return highest
              |
              +-- sub_checkpoint_restore(latest_file)
                  |
                  +-- Validate: git merge-base --is-ancestor $sha HEAD
                  |   +-- Valid   -> export RESUME_FROM_STEP, RESUME_FROM_STEP_NUM
                  |   |              set ITERATION = checkpoint iteration
                  |   +-- Invalid -> return 1 (fall back to full-iteration)
                  |
                  +-- [In iteration loop, first iteration only:]
                      if CURRENT_STEP <= RESTORED_STEP_NUM:
                          skip step (already completed)
                      else:
                          run step normally
                      After first resumed iteration:
                          clear RESUME_FROM_STEP (run all steps normally)
```

### Briefing Injection Path

```
session-restart.sh:restart_generate_briefing()
  |
  +-- if sub_checkpoint_find_latest():
      append to briefing:
        "## Recovery Point
         Restored from iteration 7, step post-test.
         Completed: Claude run, auto-commit, test execution.
         Resume from: audit and quality gates."

loop-iteration.sh:compose_prompt()
  |
  +-- if RESUME_FROM_STEP is set:
      append to resume_section:
        "Steps already completed: [list]. Do NOT repeat."
```

## Error Boundaries

### Layer 1: Checkpoint Write (loop-checkpoint.sh)

All write failures are **non-fatal**. `sub_checkpoint_save` wraps the atomic write in `|| true`, matching the existing pattern at `sw-loop.sh:2269`. A warning is logged but the loop continues. The worst case is that a crash after a failed write falls back to the previous successful checkpoint (losing at most one step's worth of progress).

### Layer 2: Checkpoint Read/Restore (loop-restart.sh)

Restore failures trigger **graceful fallback**. The chain is:
1. Try sub-iteration checkpoint -- if corrupt/stale/missing, fall back to:
2. Existing `build-claude-context.json` (prompt hints only) -- if missing:
3. Full restart from iteration 0 (current behavior, always works)

Each level catches errors independently (`2>/dev/null || true`). No restore failure can prevent the loop from starting.

### Layer 3: Step-Skip Logic (sw-loop.sh)

Step-skipping only applies to the **first iteration after resume**. If any step-skip logic causes an unexpected state, the next full iteration (running all 5 steps) self-corrects. The design is deliberately conservative: skip completed work, but never skip future work.

### Layer 4: Cleanup (loop-checkpoint.sh)

Cleanup failures are **silent no-ops**. If `sub_checkpoint_clean` can't delete old files (permissions, etc.), checkpoints accumulate but don't affect correctness. The `expire` command in `sw-checkpoint.sh` provides a secondary cleanup mechanism.

## Alternatives Considered

### 1. Hook-Based Per-File-Edit Checkpointing

- **Pros**: Maximum granularity (~20+ checkpoints per iteration). Could recover from a crash mid-Claude-session with minimal lost work.
- **Cons**: Claude tool calls run inside the Claude session, not in `sw-loop.sh`. The loop harness has no visibility into individual `EditFile` or `Write` tool calls. Would require architectural changes to the hook system (`pre-tool-use.sh`, `post-tool-use.sh`) to feed state back to the loop, and hooks currently run in subshells so they can't update loop variables. High complexity, high blast radius.
- **Verdict**: Rejected. The loop orchestrates at the iteration level. Per-tool-call granularity requires fundamentally rearchitecting the session/hook boundary.

### 2. Git-Commit-Based Recovery

- **Pros**: Git is already the source of truth for file changes. Commits are naturally atomic and ordered.
- **Cons**: Would require 5+ commits per iteration (polluting history with `loop: iter 7 post-audit` noise). The auto-commit at step 2 already exists; adding 4 more would create ~100 commits for a 20-iteration run. More critically, git commits cannot capture non-file state: test output, error summaries, convergence scores, audit results. These are essential for meaningful recovery.
- **Verdict**: Rejected. Git captures file state well but can't represent the full agent context needed for step-skipping.

## Implementation Plan

### Files to create
- `scripts/lib/loop-checkpoint.sh` -- Sub-iteration checkpoint library (save, find_latest, restore, clean, step mapping)
- `scripts/sw-loop-checkpoint-test.sh` -- 11-case integration test suite

### Files to modify
- `scripts/sw-checkpoint.sh` -- Add `--step` flag to `cmd_save`, new `list-steps` and `clean-old` subcommands
- `scripts/sw-loop.sh` -- Source new library; add 5 checkpoint saves at step boundaries; add step-skip logic on resume; preserve checkpoints during restart archival; call `sub_checkpoint_clean` after each iteration
- `scripts/lib/loop-restart.sh` -- Enhance `resume_state()` to detect and restore sub-iteration checkpoints with git SHA validation
- `scripts/lib/session-restart.sh` -- Add checkpoint step info to `restart_capture_state()` and `restart_generate_briefing()`
- `scripts/lib/loop-iteration.sh` -- Add sub-iteration checkpoint context to `compose_prompt()` resume section

### Dependencies
- No new external dependencies. Uses existing `jq`, `git`, `mktemp`, `mv`.
- Internal: `lib/loop-checkpoint.sh` depends on `lib/compat.sh` (cross-platform shims) and `lib/helpers.sh` (output functions).

### Risk areas
1. **Step-skip logic in `sw-loop.sh`**: The iteration loop body is ~240 lines (2130-2370) with complex control flow (early returns for convergence/completion, verification gap handling). Inserting step-skip guards requires careful placement to avoid skipping side effects like event emissions or state writes.
2. **Checkpoint filename parsing**: Using `build-<iter>-<step>-checkpoint.json` naming relies on consistent filename structure. A bug in the filename pattern could cause `find_latest` to return the wrong checkpoint. Mitigated by unit tests on the ordering logic.
3. **`resume_state()` ordering**: The sub-iteration restore must run *after* the existing `checkpoint_restore_context` (which sets `RESUMED_FROM_ITERATION`), so it can override with more precise state. If the ordering is inverted, the coarser checkpoint overwrites the finer one.
4. **Multi-agent checkpoint collision**: In `AGENTS > 1` mode, agents share the checkpoint directory within a worktree. Adding `AGENT_NUM` to the filename (`build-7-post-test-agent1-checkpoint.json`) prevents overwrite races but requires the agent number to be available at restore time.

## Validation Criteria

- [ ] Sub-iteration checkpoints are saved at all 5 step boundaries (verified by checking file existence after a test iteration)
- [ ] On resume from a post-test checkpoint at iteration 7, the loop restores `ITERATION=7` and skips steps 1-3 (Claude run, auto-commit, test gate), running only audit and quality gates
- [ ] Restart briefing contains "Restored from checkpoint at iteration N, step M" with correct values
- [ ] After `git reset --hard HEAD~3`, sub-iteration restore falls back to full-iteration resume (git SHA validation rejects stale checkpoint)
- [ ] Corrupted checkpoint JSON (truncated file) is skipped; fallback to previous valid checkpoint succeeds
- [ ] After 5 full iterations, only checkpoints from iterations 3-5 remain (cleanup keeps last 3)
- [ ] Checkpoint write latency is <100ms (measured in test with `date +%s%N` before/after)
- [ ] Existing `--resume` without sub-iteration checkpoints falls back to current behavior (backward compatible)
- [ ] Existing test suites pass: `sw-loop-test.sh`, `sw-checkpoint-test.sh`, `sw-session-restart-test.sh`
- [ ] All 11 new test cases in `sw-loop-checkpoint-test.sh` pass
- [ ] `npm test` full suite shows no regressions
