# Design: Build Loop Goal Achievement Verification Checkpoint System

## Context

The Shipwright build loop (`scripts/sw-loop.sh`, 2530 lines) runs Claude iteratively toward a goal with a default cap of 20 iterations. The loop already has several completion mechanisms:

1. **LOOP_COMPLETE signal** — Claude outputs this string; `guard_completion()` (line 1354) validates it against quality gates, audit agent, tests, and a holistic assessment before accepting.
2. **Convergence detection** — `lib/loop-convergence.sh` scores iteration velocity and detects convergence (stop), divergence (abort), or oscillation (warn).
3. **Circuit breaker** — Stops after N consecutive low-progress iterations.
4. **Auto-extension** — `check_max_iterations()` extends the iteration cap when work is incomplete but progressing.

**Problem**: The agent frequently exhausts all iterations without outputting `LOOP_COMPLETE`, even when the goal was achieved several iterations earlier. The agent has no structured prompt asking it to self-assess completion. This wastes tokens, increases cost, and causes avoidable `context_exhaustion` failures that trigger session restarts.

**Constraints**:
- All scripts must be Bash 3.2 compatible (no associative arrays, no `readarray`, no `${var,,}`).
- Checkpoint logic must not bypass the existing `guard_completion()` quality gates — this is a critical safety invariant.
- The loop already carries significant prompt context (~200K char budget with progressive trimming in `manage_context_window()`). Checkpoint prompt overhead must be bounded.
- Configuration follows the `_config_get_int()` / `daemon-config.json` pattern with env var overrides.
- Per-agent log isolation must be maintained for multi-agent mode.

## Decision

### Architecture: Checkpoint as a Prompt Section, Not a Separate Signal

The checkpoint system injects a self-assessment section into `compose_prompt()` at checkpoint iterations (default: every 3). If the agent responds with `GOAL_ACHIEVED`, the loop treats this equivalently to `LOOP_COMPLETE` and routes through the existing `guard_completion()` gate — preserving all quality validation.

This is **not** a new exit path. It is a prompt-engineering intervention that increases the probability of Claude outputting `LOOP_COMPLETE` when the goal is genuinely complete.

**Critical design decision**: The original implementation plan proposed a separate exit path (Task 6) that would bypass `guard_completion()` when `GOAL_ACHIEVED` is detected. This is rejected. `GOAL_ACHIEVED` must be treated as semantically equivalent to `LOOP_COMPLETE` and pass through the same multi-gate validation pipeline: quality gates, audit agent, test verification, and holistic project assessment. Without this, an agent could declare success while tests are failing.

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        sw-loop.sh (main loop)                          │
│                                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │ run_single_agent_loop()    [line 2105 while-loop]                │  │
│  │                                                                   │  │
│  │  ITERATION++                                                      │  │
│  │    │                                                              │  │
│  │    ▼                                                              │  │
│  │  compose_prompt()  ◄─── lib/loop-iteration.sh                    │  │
│  │    │                          │                                    │  │
│  │    │                 ┌────────┴────────────┐                      │  │
│  │    │                 │ lib/loop-checkpoint.sh │  ◄── NEW MODULE   │  │
│  │    │                 │                        │                    │  │
│  │    │                 │ should_checkpoint()     │                    │  │
│  │    │                 │ build_checkpoint_section()│                  │  │
│  │    │                 └────────┬────────────┘                      │  │
│  │    │                          │ returns prompt section             │  │
│  │    ▼                          ▼                                    │  │
│  │  run_claude_iteration() ──► Claude CLI                           │  │
│  │    │                                                              │  │
│  │    ▼                                                              │  │
│  │  guard_completion()  ◄─── checks LOOP_COMPLETE *and* GOAL_ACHIEVED│  │
│  │    │                         │                                    │  │
│  │    ├── quality gates ────────┤                                    │  │
│  │    ├── audit agent ──────────┤                                    │  │
│  │    ├── test gate ────────────┤                                    │  │
│  │    └── holistic gate ────────┘                                    │  │
│  │    │                                                              │  │
│  │    ▼                                                              │  │
│  │  (accept or reject completion)                                    │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                        │
│  Configuration:                                                        │
│    daemon-config.json  ──►  loop.goal_check_interval (default: 3)    │
│    CLI flag            ──►  --goal-check-interval N                   │
│    env var             ──►  SW_GOAL_CHECK_INTERVAL                    │
│                                                                        │
│  Events emitted:                                                       │
│    loop.goal_checkpoint  (iteration=N, verdict=achieved|in_progress) │
└─────────────────────────────────────────────────────────────────────────┘
```

### Interface Contracts

```typescript
// lib/loop-checkpoint.sh — new module following lib/loop-convergence.sh pattern
// Module guard: [[ -n "${_LOOP_CHECKPOINT_LOADED:-}" ]] && return 0

/**
 * Determine whether a checkpoint should run at this iteration.
 * Pure function — no side effects.
 * @returns exit code 0 (should checkpoint) or 1 (skip)
 */
function should_checkpoint(
  iteration: number,        // current ITERATION (1-based)
  interval: number,         // GOAL_CHECK_INTERVAL (>= 1)
  min_iteration: number     // don't checkpoint before this (default: 2)
): ExitCode;  // 0 = yes, 1 = no

/**
 * Build the checkpoint prompt section to append to compose_prompt().
 * Outputs to stdout. Returns empty string if checkpoint not triggered.
 * Compact: ~300 chars to stay within context budget.
 */
function build_checkpoint_section(
  iteration: number,
  max_iterations: number,
  goal: string,             // $GOAL (may include appended diagnosis context)
  original_goal: string,    // $ORIGINAL_GOAL (clean, as user specified)
  test_status: string,      // "passing" | "failing" | "not_run"
  files_changed: number
): string;  // stdout

/**
 * Initialize checkpoint config from daemon-config.json / env / CLI.
 * Sets GOAL_CHECK_INTERVAL and GOAL_CHECK_ENABLED globals.
 * Called once during loop init, after CLI parsing.
 */
function init_goal_checkpoint(): void;  // sets globals

// ─── Configuration Schema ───────────────────────────────────────────────
// daemon-config.json extension (under existing "loop" key):
{
  "loop": {
    "goal_check_interval": 3,      // Check every N iterations (>= 1)
    "goal_check_enabled": true,    // Can disable globally
    // existing keys preserved:
    "max_restarts": 0,
    "claude_timeout": 1800,
    "sleep_between_iterations": 2
  }
}

// ─── Signal Contract ────────────────────────────────────────────────────
// Agent output: "GOAL_ACHIEVED" (exact literal string, case-sensitive)
// Detection: guard_completion() grep extended to match both signals:
//   grep -qE "LOOP_COMPLETE|GOAL_ACHIEVED" "$log_file"
// Validation: identical gate pipeline for both signals
// Event: emit_event "loop.goal_checkpoint" "iteration=$I" "verdict=achieved"

// ─── Error Contract ─────────────────────────────────────────────────────
// goal_check_interval <= 0 or non-integer → warn(), default to 3
// Config file missing → default to interval=3, enabled=true
// Module source failure → functions undefined, type checks prevent calls
// Checkpoint prompt exceeds budget → trimmed by manage_context_window()
```

### Data Flow

```
1. Loop init (sw-loop.sh ~line 700):
   source lib/loop-checkpoint.sh
   init_goal_checkpoint()  →  sets GOAL_CHECK_INTERVAL, GOAL_CHECK_ENABLED

2. Each iteration (line 2122+):
   ITERATION++

3. Prompt composition (lib/loop-iteration.sh:compose_prompt):
   ... existing sections ...
   if GOAL_CHECK_ENABLED && should_checkpoint(ITERATION, GOAL_CHECK_INTERVAL, 2):
       checkpoint_text = build_checkpoint_section(ITERATION, MAX_ITERATIONS,
                           GOAL, ORIGINAL_GOAL, test_status, files_changed)
       append checkpoint_text to prompt
   ... existing heredoc continues ...

4. Claude execution (line 2187):
   run_claude_iteration  →  response written to $LOG_DIR/iteration-${ITERATION}.log

5. Completion check (line 2359):
   guard_completion()  →  grep for LOOP_COMPLETE *or* GOAL_ACHIEVED
   if found: run quality gates → audit → tests → holistic assessment
   emit_event "loop.goal_checkpoint" with verdict
   if all gates pass: STATUS="complete", return 0
   if gates reject: COMPLETION_REJECTED=true, return 1, continue looping
```

### Error Boundaries

| Error | Component | Behavior |
|-------|-----------|----------|
| `goal_check_interval` is 0, negative, or non-integer | `init_goal_checkpoint()` | `warn()`, fall back to default 3 |
| Config file missing or malformed JSON | `_config_get_int()` (existing) | Returns default; pattern already handles this |
| Checkpoint section causes context overflow | `manage_context_window()` (existing) | Progressive trimming at priority 1 (trim before DORA baselines) |
| Agent outputs "GOAL_ACHIEVED" in narrative (not as signal) | `guard_completion()` gates | False positive caught by: tests must pass + audit + holistic gate |
| Multi-agent: two agents checkpoint simultaneously | Per-agent `$LOG_DIR` isolation (existing) | Each agent's log dir is separate; `GOAL_CHECK_*` vars are in-process globals, no file-level collision |
| Module source fails (`lib/loop-checkpoint.sh` missing) | `type should_checkpoint >/dev/null 2>&1` | Functions undefined → checkpoint skipped silently |

## Alternatives Considered

### 1. Separate Exit Path Bypassing guard_completion() (from original plan)
**Approach**: When `GOAL_ACHIEVED` is detected in the log, immediately set `GOAL_REACHED=true`, append `LOOP_COMPLETE` to the log file, touch the agent-complete marker, and break — bypassing the quality gate pipeline.
- **Pros**: Simpler code; fewer lines changed; faster exit.
- **Cons**: **Critical safety flaw**. `guard_completion()` exists to prevent premature exits. It validates quality gates (line 1367), audit agent (line 1372), test status (line 1377), and runs a holistic assessment (line 1384). Bypassing these means an agent could declare "GOAL_ACHIEVED" while tests are red, audit is failing, or the holistic gate disagrees. This defeats the purpose of the guarded completion system introduced specifically to prevent false completions.
- **Decision**: **Rejected**. GOAL_ACHIEVED must route through the same validation as LOOP_COMPLETE. The one-line change to `guard_completion()`'s grep pattern achieves this safely.

### 2. Separate Claude Call for Checkpoint Verification
**Approach**: Spawn a second Claude CLI invocation at checkpoint iterations, dedicated to goal evaluation.
- **Pros**: Clean separation; checkpoint reasoning doesn't interfere with implementation work.
- **Cons**: Doubles cost per checkpoint (~$0.05-0.15/call). Adds 30-60s latency. The holistic gate (`run_holistic_gate()`, line 1402) already performs a separate LLM evaluation as the final completion check. A pre-completion LLM call is redundant.
- **Decision**: Rejected. The existing holistic gate covers this.

### 3. Agent Self-Checkpointing (No Forced Intervals)
**Approach**: Rely on the agent to output LOOP_COMPLETE when it believes the goal is done, without any prompt injection.
- **Pros**: No prompt overhead; agent autonomy.
- **Cons**: This is the status quo, and it's the problem we're solving. Agents exhibit strong continuation bias and rarely self-assess completion. They keep iterating even after the goal is met.
- **Decision**: Rejected. Explicit checkpoint prompts are the necessary intervention.

### 4. Test-Only Detection (Auto-Complete on Green Tests)
**Approach**: Automatically trigger completion when tests pass for N consecutive iterations.
- **Pros**: Fully objective; no LLM judgment.
- **Cons**: Tests passing != goal achieved. "Refactor auth to use JWT" may have passing tests before any refactoring starts (existing tests still pass). Many loops run without `--test-cmd`. This conflates test status with goal status.
- **Decision**: Rejected. Tests are necessary but not sufficient.

### 5. Dynamic Checkpoint Interval Based on Iteration Progress
**Approach**: Check every 2 iterations for the first 10, then every 5 after that.
- **Pros**: More checkpoints early; fewer later when the agent is working on hard problems.
- **Cons**: Adds configuration complexity. Harder to reason about. ~300 chars per checkpoint is negligible overhead — the cost savings from dynamic intervals don't justify the complexity.
- **Decision**: Rejected for MVP. Fixed interval (default 3) is sufficient.

## Implementation Plan

### Files to create
- `scripts/lib/loop-checkpoint.sh` — New module following `lib/loop-convergence.sh` pattern: module guard, pure functions (`should_checkpoint`, `build_checkpoint_section`, `init_goal_checkpoint`), no side effects beyond stdout and global variable assignment.

### Files to modify
- `scripts/sw-loop.sh`:
  - Line ~120: Add state variables `GOAL_CHECK_ENABLED=false`, `GOAL_CHECK_INTERVAL=3`
  - Line ~300: Add `--goal-check-interval` CLI flag to parser and `show_help()`
  - Line ~700: Source `lib/loop-checkpoint.sh`, call `init_goal_checkpoint`
  - Line 1358 (`guard_completion()`): Change grep from `"LOOP_COMPLETE"` to `"LOOP_COMPLETE\|GOAL_ACHIEVED"` (one line)
  - Line ~2395: Add `emit_event "loop.goal_checkpoint"` alongside existing iteration_complete event when checkpoint was active
- `scripts/lib/loop-iteration.sh`:
  - Line ~330 (`compose_prompt()`): After cumulative progress section, before heredoc at line 341, call `build_checkpoint_section()` if `should_checkpoint()` returns 0; append result to prompt
- `.claude/daemon-config.json`: Add `"loop"` key with `goal_check_interval` and `goal_check_enabled`
- `scripts/sw-loop-test.sh`: Add checkpoint-specific unit tests
- `.claude/CLAUDE.md`: Update "Build Loop Capabilities" section

### Dependencies
- None new. Uses existing `_config_get_int()`, `emit_event()`, `guard_completion()`, `compose_prompt()`, `manage_context_window()`.

### Risk areas

1. **guard_completion() modification** (`sw-loop.sh:1354-1400`): Most safety-critical function in the loop. The change is a one-line grep pattern extension. Must verify that GOAL_ACHIEVED responses still flow through all gates (quality, audit, test, holistic). Test with: GOAL_ACHIEVED present but tests failing → must reject.

2. **compose_prompt() heredoc** (`lib/loop-iteration.sh:341`): The checkpoint section must be built outside the heredoc and interpolated as a variable (matching the pattern used for `restart_section`, `resume_section`, `cumulative_section`). Direct function calls inside heredocs are fragile.

3. **Signal ambiguity**: "GOAL_ACHIEVED" could appear in Claude's narrative. Mitigated by: (a) the existing quality gate pipeline catches false positives, and (b) the checkpoint prompt instructs the agent to output the signal only when 100% confident. Same risk profile as the existing LOOP_COMPLETE signal.

4. **Backward compatibility**: Loops invoked without `daemon-config.json` or with old configs missing the `loop` key must default to enabled with interval=3. The `_config_get_int` pattern returns defaults for missing keys. Loops with `goal_check_enabled: false` must not inject any checkpoint prompt sections.

## Validation Criteria

- [ ] `should_checkpoint(3, 3, 2)` returns 0; `should_checkpoint(4, 3, 2)` returns 1; `should_checkpoint(6, 3, 2)` returns 0
- [ ] `should_checkpoint(1, 3, 2)` returns 1 (below min_iteration)
- [ ] `should_checkpoint(2, 2, 2)` returns 0 (iteration 2 is a multiple of 2 and >= min_iteration)
- [ ] GOAL_ACHIEVED in log triggers `guard_completion()` — quality gates, audit, tests, and holistic gate all execute
- [ ] GOAL_ACHIEVED rejected when `TEST_PASSED == "false"` (guard_completion returns 1)
- [ ] GOAL_ACHIEVED accepted when all gates pass (same as LOOP_COMPLETE acceptance path)
- [ ] Config defaults work without daemon-config.json: interval=3, enabled=true
- [ ] `goal_check_interval: 0` falls back to 3 with `warn()` message
- [ ] `goal_check_interval: "abc"` falls back to 3 with `warn()` message
- [ ] `--goal-check-interval 5` CLI flag overrides daemon-config.json value
- [ ] `SW_GOAL_CHECK_INTERVAL=2` env var overrides default
- [ ] Checkpoint prompt section includes `$ORIGINAL_GOAL` (not the appended-diagnosis version)
- [ ] Checkpoint prompt section is under 500 chars
- [ ] `manage_context_window()` can trim checkpoint section when context budget exceeded
- [ ] `loop.goal_checkpoint` event emitted with `iteration=N` and `verdict=achieved|in_progress`
- [ ] All existing `sw-loop-test.sh` and `sw-convergence-test.sh` tests pass (no regression)
- [ ] Multi-agent mode: checkpoint state isolated per agent process
- [ ] `loop.goal_check_enabled: false` suppresses all checkpoint injection
- [ ] Module guard prevents double-sourcing of `lib/loop-checkpoint.sh`
