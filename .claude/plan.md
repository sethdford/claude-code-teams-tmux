# Implementation Plan: Pipeline Cost-Performance Dynamic Optimizer with Burst Mode

## Brainstorming & Design Decisions

### Requirements Clarity

**Minimum viable change**: Add a scoring function to the build loop that evaluates progress trajectory, and when conditions are met, temporarily override `CLAUDE_MODEL` to a more expensive model for the next iteration. Log decisions to `costs.json`. Show a badge in terminal output.

**Implicit requirements**:

- Must not break existing model routing (`select_adaptive_model`, `SW_MODEL` override)
- Must respect existing budget gates (`check_budget_gate`)
- Must be idempotent — burst state resets cleanly between iterations
- Must work in both single-agent and multi-agent loop modes

**Acceptance criteria** (from issue):

1. Cost-performance scoring function analyzing progress rate, iterations remaining, budget remaining
2. Burst mode triggers when: `progress_score > 70`, `iterations_remaining < 3`, `budget_remaining > 2x estimated_cost_to_complete`
3. Model upgrade via `$ANTHROPIC_MODEL` override for next iteration
4. Fallback: revert to original model if burst iteration fails
5. Cost tracking: log burst decisions to `costs.json`
6. Dashboard indicator: "BURST MODE" badge when active

### Alternatives Considered

**Approach A: Inline in sw-loop.sh main loop** (CHOSEN)

- Add scoring + burst logic directly in the iteration loop between `check_budget_gate` and the Claude invocation
- Pros: minimal files changed, close to existing iteration tracking, easy to test
- Cons: adds ~80 lines to an already large file
- Blast radius: only `sw-loop.sh` main loop

**Approach B: Separate module `scripts/lib/loop-burst.sh`**

- Extract burst mode into its own sourced module (like `loop-convergence.sh`)
- Pros: cleaner separation, easier to test in isolation, follows existing pattern
- Cons: one more file to maintain, but matches the existing `lib/` pattern
- Blast radius: new file + small integration point in sw-loop.sh

**Decision: Approach B** — follows the existing pattern of `scripts/lib/loop-convergence.sh` for convergence detection. The burst module will be sourced by `sw-loop.sh` and called at the right point in the iteration loop. This keeps `sw-loop.sh` from growing further and makes the burst logic independently testable.

### Risk Analysis

| Risk                                                  | Impact | Mitigation                                                                                                        |
| ----------------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------- |
| Burst mode triggers too aggressively, burning budget  | High   | Conservative defaults (progress_score > 70 requires positive test trend + commits); budget gate runs BEFORE burst |
| Model override doesn't take effect                    | Medium | Use `CLAUDE_MODEL` env var which Claude CLI respects; test with mock                                              |
| Burst iteration fails, stuck on expensive model       | Medium | Explicit revert logic at top of each iteration; `BURST_ACTIVE` flag reset on failure                              |
| Existing `select_adaptive_model` conflicts with burst | Medium | Burst overrides happen AFTER adaptive selection, taking priority only when conditions met                         |
| Cost estimation inaccurate                            | Low    | Use conservative multiplier (2x) and actual `LOOP_COST_MILLICENTS` data                                           |

### Dependency Analysis

**Depends on:**

- `scripts/lib/loop-convergence.sh` — velocity tracking (`VELOCITY_HISTORY`, `compute_velocity_avg`)
- `scripts/sw-cost.sh` — `cost_remaining_budget()`, `cost_record()`, cost entry format
- `scripts/sw-loop.sh` — iteration variables (`ITERATION`, `MAX_ITERATIONS`, `MODEL`, `TEST_PASSED`, `LOOP_COST_MILLICENTS`)

**Depended on by:** Nothing (new feature, additive)

**No circular dependency risks.**

## Architecture

### Component Diagram

```
sw-loop.sh (main loop)
    |
    |-- sources --> lib/loop-burst.sh (NEW)
    |                   |
    |                   |-- reads: ITERATION, MAX_ITERATIONS, TEST_PASSED,
    |                   |          VELOCITY_HISTORY, LOOP_COST_MILLICENTS, MODEL
    |                   |
    |                   |-- calls: cost_remaining_budget() from sw-cost.sh
    |                   |-- calls: compute_velocity_avg() from lib/loop-convergence.sh
    |                   |-- calls: emit_event() for event logging
    |                   |
    |                   |-- sets: BURST_ACTIVE, BURST_ORIGINAL_MODEL, CLAUDE_MODEL
    |                   |
    |                   |-- writes: burst decisions to costs.json via cost_record()
    |
    |-- sources --> lib/loop-convergence.sh (existing, unchanged)
    |
    |-- sources --> sw-cost.sh (existing, unchanged)
```

### Interface Contracts

```bash
# Compute a 0-100 progress score based on test trajectory, velocity, and commits
# Input: reads global vars (TEST_PASSED, VELOCITY_HISTORY, ITERATION, TOTAL_COMMITS)
# Output: integer 0-100 to stdout
# Errors: returns 0 on any failure (safe default = no burst)
burst_compute_progress_score() -> integer (0-100)

# Evaluate whether burst mode should activate this iteration
# Input: reads globals + calls cost_remaining_budget()
# Output: sets BURST_ACTIVE=true/false, BURST_ORIGINAL_MODEL, overrides CLAUDE_MODEL
# Side effects: emits event, logs decision
# Errors: on any failure, BURST_ACTIVE=false (safe default)
burst_evaluate() -> void (sets globals)

# Revert model after burst iteration (called at top of next iteration)
# Input: BURST_ACTIVE, BURST_ORIGINAL_MODEL, TEST_PASSED
# Output: restores MODEL and CLAUDE_MODEL if burst failed
# Side effects: emits event, logs outcome
burst_check_revert() -> void (sets globals)

# Log burst decision to costs.json for learning
# Input: decision type, model, score, outcome
# Side effects: appends to ~/.shipwright/costs.json burst_decisions array
burst_log_decision(type, model, score, reason) -> void
```

### Data Flow

```
Iteration Start
    --> burst_check_revert() [revert if previous burst failed]
    --> check_budget_gate()
    --> burst_evaluate()
        --> burst_compute_progress_score()
            reads: TEST_PASSED history, velocity avg, commit count
            returns: score 0-100
        --> check: score > 70?
        --> check: iterations_remaining < 3?
        --> check: budget > 2x estimated_cost?
        --> if all pass: set BURST_ACTIVE=true, override CLAUDE_MODEL
    --> Claude invocation (uses CLAUDE_MODEL)
    --> accumulate_loop_tokens()
    --> track_iteration_velocity()
    --> run_test_gate()
    --> [next iteration: burst_check_revert evaluates outcome]
```

### Error Boundaries

- `burst_compute_progress_score`: catches all errors, returns 0 (no burst)
- `burst_evaluate`: catches all errors, sets `BURST_ACTIVE=false` (no burst)
- `burst_check_revert`: catches all errors, forces revert to original model
- `burst_log_decision`: fire-and-forget, errors suppressed with `|| true`

## Files to Modify

| File                        | Action     | Purpose                                                      |
| --------------------------- | ---------- | ------------------------------------------------------------ |
| `scripts/lib/loop-burst.sh` | **CREATE** | Burst mode scoring, evaluation, revert, logging              |
| `scripts/sw-loop.sh`        | **MODIFY** | Source burst module, integrate calls at iteration boundaries |
| `scripts/sw-loop-test.sh`   | **MODIFY** | Add burst mode unit tests                                    |
| `scripts/sw-tmux-status.sh` | **MODIFY** | Add BURST MODE badge to status bar widget                    |

## Implementation Steps

### Step 1: Create `scripts/lib/loop-burst.sh`

New module with module guard pattern (matching `loop-convergence.sh`):

1. **`burst_compute_progress_score()`** — Scores 0-100:
   - +30 points if `TEST_PASSED == "true"` (tests currently passing)
   - +20 points if test trend is improving (was failing, now passing)
   - +25 points if `velocity_avg > 10` (meaningful code changes per iteration)
   - +15 points if `TOTAL_COMMITS > 0` (agent is making commits)
   - +10 points if `CONSECUTIVE_FAILURES == 0` (no stagnation)
   - Uses only existing global variables — no new state needed

2. **`burst_evaluate()`** — Decision logic:
   - Compute `progress_score` via scoring function
   - Compute `iterations_remaining = MAX_ITERATIONS - ITERATION`
   - Get `budget_remaining` from `cost_remaining_budget()`
   - Estimate cost-to-complete: `avg_cost_per_iteration * iterations_remaining` (from `LOOP_COST_MILLICENTS / ITERATION`)
   - Gate: `progress_score > 70 AND iterations_remaining < 3 AND budget_remaining > 2 * estimated_cost_to_complete`
   - On activate: save `BURST_ORIGINAL_MODEL=$MODEL`, set `MODEL=opus`, export `CLAUDE_MODEL=claude-opus-4-6`
   - Print burst mode banner, emit event, log decision

3. **`burst_check_revert()`** — Called at start of each iteration:
   - If `BURST_ACTIVE == true` from previous iteration:
     - If `TEST_PASSED == "true"`: burst succeeded, log success, keep model (or revert — burst is one-shot)
     - If `TEST_PASSED != "true"`: burst failed, revert `MODEL=$BURST_ORIGINAL_MODEL`, log failure
   - Always reset `BURST_ACTIVE=false` after evaluation (burst is per-iteration)

4. **`burst_log_decision()`** — Append to costs.json:
   - Add entry under `.burst_decisions[]` with: `{type, model_from, model_to, progress_score, iterations_remaining, budget_remaining, outcome, ts}`
   - Uses atomic write pattern (tmp + mv) with flock

### Step 2: Integrate into `scripts/sw-loop.sh`

1. **Source the module** (near line 55, alongside loop-convergence.sh source):

   ```bash
   source "$SCRIPT_DIR/lib/loop-burst.sh" 2>/dev/null || true
   ```

2. **Add burst state variables** (near line 92, after token tracking):

   ```bash
   BURST_ACTIVE=false
   BURST_ORIGINAL_MODEL=""
   BURST_PREVIOUS_TEST=""
   ```

3. **Add `burst_check_revert()` call** at top of iteration loop (after line 2056, before `check_circuit_breaker`):

   ```bash
   # Check if previous burst iteration needs revert
   if type burst_check_revert >/dev/null 2>&1; then
       burst_check_revert
   fi
   ```

4. **Add `burst_evaluate()` call** after `check_budget_gate` and before incrementing iteration (between lines 2068-2069):

   ```bash
   # Evaluate burst mode opportunity
   if type burst_evaluate >/dev/null 2>&1; then
       burst_evaluate
   fi
   ```

5. **Track previous test state** for trend detection (after `run_test_gate`, ~line 2187):

   ```bash
   BURST_PREVIOUS_TEST="${TEST_PASSED:-}"
   ```

6. **Add burst badge to iteration header** (in the iteration echo, ~line 2069):
   ```bash
   local burst_badge=""
   [[ "$BURST_ACTIVE" == "true" ]] && burst_badge=" ${YELLOW}[BURST]${RESET}"
   echo -e "\n${CYAN}${BOLD}Iteration ${ITERATION}/${MAX_ITERATIONS}${RESET}${burst_badge}"
   ```

### Step 3: Add tmux status badge

In `scripts/sw-tmux-status.sh`, add BURST MODE indicator when `BURST_ACTIVE` is set in loop state or events.

### Step 4: Write tests in `scripts/sw-loop-test.sh`

Add test cases:

- `test_burst_progress_score_all_positive`: all signals positive → score > 70
- `test_burst_progress_score_no_tests`: no test passing → score < 70
- `test_burst_evaluate_triggers`: mock conditions met → BURST_ACTIVE=true
- `test_burst_evaluate_low_score`: progress too low → no burst
- `test_burst_evaluate_budget_insufficient`: budget too low → no burst
- `test_burst_evaluate_iterations_remaining_high`: too many iterations left → no burst
- `test_burst_revert_on_failure`: TEST_PASSED=false after burst → model reverted
- `test_burst_revert_on_success`: TEST_PASSED=true after burst → logged as success
- `test_burst_log_decision_format`: verify JSON structure in costs.json

## Task Checklist

- [ ] Task 1: Create `scripts/lib/loop-burst.sh` with module guard, `burst_compute_progress_score()`, `burst_evaluate()`, `burst_check_revert()`, `burst_log_decision()`
- [ ] Task 2: Add burst state variables to `scripts/sw-loop.sh` defaults section
- [ ] Task 3: Source `lib/loop-burst.sh` in `scripts/sw-loop.sh`
- [ ] Task 4: Integrate `burst_check_revert()` call at iteration start in main loop
- [ ] Task 5: Integrate `burst_evaluate()` call after budget gate in main loop
- [ ] Task 6: Track `BURST_PREVIOUS_TEST` after test gate for trend detection
- [ ] Task 7: Add `[BURST]` badge to iteration header display
- [ ] Task 8: Add burst event emission to iteration start event
- [ ] Task 9: Add BURST MODE badge to `scripts/sw-tmux-status.sh`
- [ ] Task 10: Write unit tests for scoring function in `scripts/sw-loop-test.sh`
- [ ] Task 11: Write unit tests for evaluate/revert/log in `scripts/sw-loop-test.sh`
- [ ] Task 12: Run full test suite and fix any regressions

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests (8 tests)**: All burst functions tested in isolation with mocked globals. Tests verify scoring math, trigger conditions, revert logic, and JSON logging format.
- **Integration tests (2 tests)**: Verify burst module integrates with sw-loop.sh (sources correctly, functions available, no variable conflicts).
- **E2E tests (0 new)**: Existing pipeline tests cover the loop flow; burst is additive and guarded by `type ... >/dev/null`.

### Coverage Targets

- 100% of `burst_compute_progress_score` branches (each scoring component)
- 100% of `burst_evaluate` gate conditions (all 3 must pass, test each failing independently)
- 100% of `burst_check_revert` paths (success, failure, not-active)
- JSON format validation for `burst_log_decision`

### Critical Paths to Test

**Happy path**: progress_score=85, iterations_remaining=2, budget=plenty → burst activates → tests pass → logged as success

**Error cases**:

- Budget returns "unlimited" → should still evaluate (treat as sufficient)
- `cost_remaining_budget` not available → no burst (safe default)
- `LOOP_COST_MILLICENTS=0` on first iteration → cannot estimate cost → no burst

**Edge cases**:

- Exactly at thresholds (score=70, iterations_remaining=3, budget=2x)
- Multi-agent mode (AGENTS > 1) — burst should work per-agent
- `MODEL` already set to opus → burst is a no-op (already on best model)

## Definition of Done

- [ ] `burst_compute_progress_score()` returns 0-100 based on test trend, velocity, commits
- [ ] Burst mode activates when: score > 70, iterations_remaining < 3, budget > 2x cost-to-complete
- [ ] `CLAUDE_MODEL` override injects upgraded model for next Claude invocation
- [ ] Failed burst iteration reverts to original model automatically
- [ ] Burst decisions logged to `~/.shipwright/costs.json` under `burst_decisions`
- [ ] `[BURST]` badge displayed in iteration header when active
- [ ] BURST MODE indicator in tmux status bar
- [ ] All existing tests pass (no regressions)
- [ ] 8+ new unit tests covering scoring, evaluation, revert, and logging
- [ ] Module follows bash 3.2 compatibility, `set -euo pipefail`, atomic writes

## Performance Considerations

**Baseline**: The burst evaluation adds 2-3 shell function calls per iteration. Each call reads only in-memory globals except `cost_remaining_budget()` which does one JSON file read (already cached by the budget gate that runs immediately before).

**Optimization targets**: Burst evaluation must complete in < 50ms (it's pure arithmetic on globals). No new file I/O in the hot path except the one-time cost log on burst activation.

**Profiling strategy**: Not applicable — pure bash arithmetic with no I/O bottlenecks.

**Benchmark plan**: Not applicable — overhead is negligible (microseconds of arithmetic vs. minutes of Claude API calls per iteration).

## API / Endpoint Specification

Not applicable — this is an internal bash module with no external API surface. All interfaces are bash functions called within the same process.

## Skill Output: Architecture Design

### ADR: Burst Mode as Sourced Module

**Context**: The build loop (`sw-loop.sh`) is already 2400+ lines. Adding burst mode inline would increase complexity. The codebase already has `scripts/lib/loop-convergence.sh` as a precedent for extracting loop concerns into sourced modules.

**Decision**: Create `scripts/lib/loop-burst.sh` as a sourced module following the `loop-convergence.sh` pattern (module guard, global variable access, called from main loop).

**Alternatives rejected**:

- Inline in sw-loop.sh: rejected due to file size and testability
- Separate script called via subprocess: rejected because burst needs to modify parent shell variables (`MODEL`, `CLAUDE_MODEL`)

**Consequences**: One more file in `scripts/lib/`, but follows established patterns. Burst logic is independently testable. Main loop changes are minimal (4-5 lines of integration).
