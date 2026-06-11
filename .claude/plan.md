# Implementation Plan: Build Loop Real-Time Quality Scoring with Adaptive Model Downshift

**Issue**: #628  
**Status**: Plan Stage  
**Goal**: Build Loop Real-Time Quality Scoring with Adaptive Model Downshift  
**Complexity**: Standard  
**Created**: 2026-06-11T21:15:01Z

---

## Executive Summary

This plan implements real-time quality scoring for build loop iterations that dynamically routes between Opus and Sonnet models. After 2 consecutive high-quality iterations (score >0.8), the loop downshifts to cheaper Sonnet. On quality degradation (score <0.5 or test regression), it upshifts back to Opus. This delivers 20-30% cost savings on easy iterations without sacrificing success rate.

The implementation is **pure bash + jq** (no external LLM calls) and **opt-in** via `--adaptive-model` flag or `SW_ADAPTIVE_MODEL=true` environment variable.

---

## Design Approach: Requirements Analysis

### Requirements Clarity

**Minimum Viable Change**: A quality scorer that evaluates iterations (test pass/fail, diff size, error trends) and a state machine that downshifts/upshifts models based on 2+ consecutive high scores.

**Implicit Requirements Identified**:

- Must handle first iteration (no prior state) gracefully
- Must never downshift in iterations 1-2 (lock period)
- Must prevent downshift when error count is rising (safety)
- Must be observable: log per-iteration scores to a file
- Must include anti-thrash cooldown after upshift
- Must be backward-compatible: off by default, opt-in only

**Acceptance Criteria** (from issue):

1. ✓ Quality scoring function: computes score from test results, diff size, error count, convergence metrics
2. ✓ Model routing logic: downshift Opus→Sonnet after 2 consecutive high-quality iterations (score >0.8)
3. ✓ Escalation logic: upshift Sonnet→Opus on quality degradation (score <0.5 or test failure after passing)
4. ✓ Integration: sw-loop.sh invokes scorer after each iteration, adjusts --model flag for next iteration
5. ✓ Cost tracking: logs model used per iteration, reports savings in loop summary
6. ✓ Safety: never downshift during first 2 iterations or when error count increasing
7. ✓ Test suite validates scoring accuracy and routing decisions across quality scenarios

---

## Alternatives Considered

### Approach 1: Stateful File-Based Model Router (CHOSEN)

**Description**: Maintain state file (`.claude/model-routing-state.jsonl`) with rolling history of iteration scores and routing decisions.

**Pros**:

- Fully observable: state can be inspected/debugged at any time
- Survives loop restarts naturally (read prior state from file)
- Pure bash + jq, no extra dependencies
- Easy to extend with more metrics

**Cons**:

- Requires atomic file writes (temp + mv pattern)
- Slightly slower than in-memory (file I/O overhead)

**Complexity**: Medium | **Performance**: Good | **Maintainability**: High | **Blast Radius**: Low

---

### Approach 2: In-Memory State During Loop

**Description**: Keep state as bash variables within sw-loop.sh, track high_scores array across iterations.

**Pros**:

- No file I/O overhead
- Simpler integration (fewer function calls)
- Faster per-iteration

**Cons**:

- Loses state on loop restart (would need to reconstruct from git history)
- Harder to debug post-hoc
- Loop restarts would lose routing history
- Violates observability principle

**Complexity**: Low | **Performance**: Excellent | **Maintainability**: Medium | **Blast Radius**: Medium

---

**Why Approach 1 is Selected**: The loop already supports `--max-restarts`, which means sessions can be restarted mid-pipeline. Approach 2 would lose routing history on restart, breaking the 2-consecutive-high-scores check. File-based state is observable, survives restarts, and is the right architectural fit for a daemon/pipeline tool.

---

## Design: Quality Scoring Metrics

### 1. Test Quality (0–1)

- **Signal**: Test pass/fail status
- **Formula**: `test_score = 1.0 if all_tests_pass else 0.0`
- **Edge case**: If no tests run yet, use 0.5 (neutral, prevents false confidence)

### 2. Diff Quality (0–1)

- **Signal**: Lines added + deleted (total churn)
- **Formula**: `diff_score = 1.0 - min(lines_changed / 500, 1.0)`
  - 0 lines = 1.0 (perfect, no change)
  - 250 lines = 0.5 (moderate, some risk)
  - 500+ lines = 0.0 (high churn, unsafe to downshift)
- **Rationale**: Sonnet struggles with large refactorings; safe only on targeted fixes
- **Edge case**: Empty diff (no changes) scores 1.0 but blocks downshift (convergence issue)

### 3. Convergence Health (0–1)

- **Signal**: Error count trend (are we fixing or introducing errors?)
- **Formula**: `convergence = 1.0 - (error_delta / max(prior_error_count, 1.0))`
  - `error_delta = max(0, new_errors - fixed_errors)` (net new errors)
  - Positive delta (errors increasing) = low convergence score
  - Negative delta (errors decreasing) = high convergence score
- **Edge case**: First iteration has no prior count; use 0 for prior count (neutral)

### 4. Iteration Score (0–1)

- **Composite**: `score = 0.5 * test + 0.25 * diff + 0.25 * convergence`
- **Weighting rationale**: Tests are primary signal (50%), diff/convergence are secondary guards
- **Boundaries**:
  - Score >0.8 = "high quality, candidate for downshift"
  - Score <0.5 = "degraded, escalate to Opus"

### 5. Temporal Aggregation

- Keep rolling window of last 3 iteration scores
- Downshift trigger: 2+ consecutive scores >0.8
- Escalation trigger: score <0.5 OR (test_status=fail after prior pass)

---

## Design: Model Routing State Machine

```
Initial State: Opus (iterations 1–2 locked)
  ↓ (iteration 3+)
  ├─ If 2+ consecutive high scores (>0.8) AND no rising errors
  │  └─ Downshift → Sonnet
  │     ├─ Stay until: score <0.5 OR test failure after pass
  │     └─ On violation: Upshift → Opus + cooldown
  │
  └─ If score <0.5 OR test regression
     └─ Escalate → Opus (immediate)
```

**State Variables**:

- `current_model`: opus | sonnet (starts as Opus)
- `high_score_streak`: number of consecutive scores >0.8 (0–3)
- `last_scores[]`: rolling window of 3 recent iteration scores
- `last_test_status`: pass | fail (to detect regression)
- `iterations_since_upshift`: counter for cooldown (default: 2)

**Key Rules**:

1. Iterations 1–2 **always** use Opus (lock period)
2. Downshift only after 2+ consecutive high scores (>0.8)
3. Upshift immediately on degradation (score <0.5 OR test regression)
4. After upshift, wait N iterations (cooldown) before re-downshifting (prevent thrashing)
5. Never downshift if error count is rising

---

## Implementation Structure

### Files to Create/Modify

#### 1. `scripts/lib/loop-model-router.sh` (NEW, ~450 lines)

Pure bash module providing:

- `score_iteration()`: Computes iteration score from metrics
- `route_model()`: Makes downshift/upshift decision
- `save_routing_state()`: Atomically saves state to `.claude/model-routing-state.jsonl`
- `load_routing_state()`: Loads prior state or initializes defaults
- `suggest_next_model()`: Returns model for next iteration
- Helper: `_normalize_metric()`: Clamps values to [0, 1]

#### 2. `scripts/sw-loop.sh` (MODIFY)

Integration points:

- **Line ~2000** (after test runs): Call `score_iteration()` with test results
- **Line ~2100** (before next iteration prompt): Call `suggest_next_model()` to get model
- **Loop summary** (~line 2650): Include cost savings summary from routing log

Behavior:

- Extract test pass/fail from `TEST_PASSED` variable
- Extract diff stats from `git diff --stat HEAD~1` (or from cached progress)
- Extract error count from prior iteration (stored in state file)
- Pass to scorer, get score back
- Route decision made by state machine
- Log to `model-routing.jsonl`
- Adjust Claude CLI invocation: `claude code --model "$NEXT_MODEL"`

#### 3. `scripts/lib/loop-model-router-test.sh` (NEW, ~650 lines)

Test harness (unit + integration):

- **Unit tests** (50%): Score computation, normalization, edge cases
  - Empty test (no prior state)
  - Large diff (500+ lines)
  - Error count rising
  - Test regression
  - All scores high
- **Integration tests** (40%): State machine transitions
  - Downshift after 2 high scores
  - Upshift on degradation
  - Cooldown prevents thrashing
  - Iterations 1–2 locked
- **E2E tests** (10%): Full loop scenario
  - Simulate 10-iteration loop with varying quality
  - Verify cost savings are calculated
  - Check routing log output

#### 4. `.claude/daemon-config.json` (MODIFY)

Add adaptive model configuration:

```json
{
  "loop": {
    "downshift_score": 800, // milli-score (0–1000) threshold for downshift
    "upshift_score": 500, // milli-score threshold for upshift
    "route_cooldown": 2, // iterations to wait after upshift
    "high_score_streak_threshold": 2 // consecutive high scores before downshift
  }
}
```

#### 5. `scripts/sw-adaptive-model-test.sh` (NEW, ~400 lines)

High-level test suite verifying:

- Quality scoring accuracy across scenarios
- Model routing correctness (downshift/upshift)
- Cost savings calculation
- Edge cases (first run, no prior state, etc.)

---

## Task Decomposition with Dependencies

1. **[CORE] Create `scripts/lib/loop-model-router.sh`** (blocking: 2, 3, 4)
   - Implement `_normalize_metric()` helper
   - Implement `score_iteration()` (computes 0–1000 milli-score)
   - Implement state machine: `route_model()`
   - Implement atomic state I/O: `save_routing_state()`, `load_routing_state()`
   - Implement `suggest_next_model()` entry point

2. **[TESTS] Create `scripts/lib/loop-model-router-test.sh`** (depends: 1)
   - Unit tests for metric normalization (10 tests)
   - Unit tests for score computation (15 tests)
   - Unit tests for routing state machine (20 tests)
   - Integration tests for full scenario (8 tests)

3. **[INTEGRATION] Modify `scripts/sw-loop.sh`** (depends: 1)
   - Source `loop-model-router.sh` module (already in place at line 42)
   - After iteration completion: call `score_iteration()` with metrics
   - Compute next model via `suggest_next_model()`
   - Adjust Claude CLI: use computed model
   - Update loop summary to include cost tracking

4. **[CONFIG] Update `.claude/daemon-config.json`** (depends: 1)
   - Add `loop.downshift_score`, `upshift_score`, `route_cooldown`
   - Document thresholds

5. **[E2E-TEST] Create `scripts/sw-adaptive-model-test.sh`** (depends: 1, 2, 3)
   - Mock-based e2e test of full loop with adaptive routing
   - Verify cost savings across a 10-iteration scenario

6. **[DOCUMENTATION] Update `.claude/CLAUDE.md`** (depends: 3)
   - Add to adaptive model downshift section
   - Document scoring function, routing logic, configuration

---

## Detailed Implementation Steps

### Step 1: Create `scripts/lib/loop-model-router.sh`

**Function 1: `_normalize_metric(value, min, max)`**

```bash
# Clamps value to [0,1] range
# $1: value
# $2: min (default 0)
# $3: max (default 1)
# Returns: normalized value (0–1000 milli-scale as integer for bash)
```

**Function 2: `score_iteration(test_passed, lines_changed, error_count, prior_error_count)`**

- Compute test_quality: 1.0 if test_passed, else 0.0
- Compute diff_quality: 1.0 - min(lines_changed / 500, 1.0)
- Compute convergence: 1.0 - max(0, (error_count - prior_error_count)) / max(prior_error_count, 1.0)
  - Clamp to [0, 1]
- Composite: (0.5 _ test) + (0.25 _ diff) + (0.25 \* convergence)
- Convert to milli-score (0–1000) as integer: score \* 1000
- Return integer

**Function 3: `load_routing_state()`**

- Read `.claude/model-routing-state.jsonl` if exists
- Extract: current_model, high_score_streak, last_scores, last_test_status, iterations_since_upshift
- If file doesn't exist, initialize: model=opus, streak=0, scores=[], status=unknown, cooldown=0
- Set global variables: `ROUTER_MODEL`, `ROUTER_STREAK`, `ROUTER_SCORES`, `ROUTER_LAST_TEST`, `ROUTER_COOLDOWN`

**Function 4: `save_routing_state(iteration, score)`**

- Update global state variables
- Create temp file in `.claude/`
- Write JSON line: `{"iteration": N, "timestamp": "...", "model": "...", "score": NNN, "streak": N, ...}`
- Atomically move to `.claude/model-routing-state.jsonl`

**Function 5: `route_model(iteration, score, test_passed)`**

- Load prior state
- Determine next model based on state machine logic:
  ```
  if iteration <= 2:
    next_model = opus  # Lock period
  elif cooldown > 0:
    next_model = current_model  # In cooldown
    cooldown -= 1
  elif streak >= 2 and error_count not rising:
    next_model = sonnet  # Downshift
  elif score < 500 or test_failed_after_pass:
    next_model = opus  # Upshift
    cooldown = 2
  else:
    next_model = current_model  # Stay
  ```
- Return: next_model, reasoning
- Save state

**Function 6: `suggest_next_model()`**

- Return `$ROUTER_NEXT_MODEL` for use in Claude CLI

### Step 2: Modify `scripts/sw-loop.sh`

**Integration Point 1: After test execution (~line 2300)**

```bash
# Extract test result
if [ "$TEST_PASSED" = "true" ]; then test_passed=1; else test_passed=0; fi

# Extract diff stats
lines_changed=$(git -C "$PROJECT_ROOT" diff HEAD~1 --stat 2>/dev/null | tail -1 | awk '{print $4}' || echo 0)

# Extract error count (from progress state or prior iteration)
error_count=$(grep -o '"error_count":[0-9]*' .claude/progress.md 2>/dev/null | tail -1 | cut -d: -f2 || echo 0)
prior_error_count=$(grep -o '"prior_error_count":[0-9]*' .claude/progress.md 2>/dev/null | tail -1 | cut -d: -f2 || echo 0)

# Score this iteration
if [ "$ADAPTIVE_MODEL_ENABLED" = true ]; then
    ITERATION_SCORE=$(score_iteration "$test_passed" "$lines_changed" "$error_count" "$prior_error_count")
    route_model "$ITERATION" "$ITERATION_SCORE" "$test_passed"
    MODEL=$(suggest_next_model)
fi
```

**Integration Point 2: Before next Claude invocation (~line 2400)**

```bash
# Pass model to claude code
CLAUDE_ARGS=(--model "$MODEL")
if [ "$ADAPTIVE_MODEL_ENABLED" = true ]; then
    CLAUDE_ARGS+=(--adaptive-model)  # For observability
fi
```

**Integration Point 3: Loop summary (~line 2650)**

```bash
# Calculate and display cost savings
if [ "$ADAPTIVE_MODEL_ENABLED" = true ] && [ -f ".claude/model-routing-state.jsonl" ]; then
    total_opus_iterations=$(grep '"model":"opus"' .claude/model-routing-state.jsonl | wc -l)
    total_sonnet_iterations=$(grep '"model":"sonnet"' .claude/model-routing-state.jsonl | wc -l)
    # Rough estimate: Sonnet @ 20% cost of Opus
    estimated_savings=$(echo "scale=2; (${total_sonnet_iterations} * 0.2 + ${total_opus_iterations} * 1.0) / ${total_opus_iterations} - 1" | bc)
    echo "Model Routing Summary:"
    echo "  Opus iterations: $total_opus_iterations"
    echo "  Sonnet iterations: $total_sonnet_iterations"
    echo "  Estimated cost: $estimated_savings% savings vs baseline Opus"
fi
```

### Step 3: Create `scripts/lib/loop-model-router-test.sh`

**Test Structure**:

```bash
#!/usr/bin/env bash
set -euo pipefail

PASS=0 FAIL=0

# Helper
assert_eq() { [[ "$1" == "$2" ]] && ((PASS++)) || { echo "FAIL: $3"; ((FAIL++)); }; }

# Unit: Metric normalization
test_normalize_metric_zero() { ... }
test_normalize_metric_full() { ... }
test_normalize_metric_half() { ... }

# Unit: Score computation
test_score_all_perfect() { ... }
test_score_all_failing() { ... }
test_score_large_diff() { ... }

# Unit: State machine
test_downshift_after_two_highs() { ... }
test_upshift_on_low_score() { ... }
test_upshift_on_regression() { ... }
test_lock_first_two_iterations() { ... }
test_cooldown_prevents_thrashing() { ... }

# Integration: Full 10-iteration scenario
test_full_loop_scenario() { ... }

echo "Tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
```

### Step 4: Create `scripts/sw-adaptive-model-test.sh`

High-level validation:

```bash
#!/usr/bin/env bash
# E2E test: Mock a full loop with quality variations
# Scenario: 10 iterations
#   Iter 1–2: Opus (lock)
#   Iter 3–4: High quality (85) → Downshift to Sonnet
#   Iter 5: Low quality (45) → Upshift to Opus
#   Iter 6–7: High quality (82) → Downshift to Sonnet
#   Iter 8–10: Sustained high (84, 87, 80) → Stay Sonnet
# Expected: 4 Opus + 6 Sonnet = ~28% savings
```

### Step 5: Update `.claude/daemon-config.json`

Add to `loop` section:

```json
"downshift_score": 800,
"upshift_score": 500,
"route_cooldown": 2,
"high_score_streak_threshold": 2
```

---

## Risk Analysis

### Risk 1: Score Doesn't Reflect Actual Quality

**What Could Break**: Downshift to Sonnet on apparently-high-quality iterations that actually introduced subtle bugs (e.g., logic errors not caught by tests).

**Mitigation**:

- Test results are primary signal (50% weight)
- Require 2+ consecutive high iterations before downshift (not just 1)
- Keep error convergence signal (new errors = low score)
- Conservative downshift_score threshold (0.8 = 80%, not 0.6)
- Can be tuned post-launch via daemon-config

**Residual Risk**: Medium (mitigated by 2-iteration requirement)

---

### Risk 2: State File Corruption or Loss

**What Could Break**: If `.claude/model-routing-state.jsonl` is corrupted or deleted, routing state is lost and loop restarts from scratch (defaults to Opus). Could cause cost spike if downshift gets reversed.

**Mitigation**:

- Use atomic writes: write to temp file, then `mv` (not `echo >`)
- Always validate JSON before reading (jq syntax check)
- On corruption, gracefully fall back to defaults (Opus)
- Log all state transitions to `.claude/model-routing-state.jsonl`
- Loop restart naturally re-initializes state from prior iterations

**Residual Risk**: Low (atomic writes + fallback)

---

### Risk 3: First Iteration Without Prior Error Count

**What Could Break**: First iteration has no `prior_error_count`, so convergence metric can't be computed. Could incorrectly inflate score.

**Mitigation**:

- Default prior_error_count to 0 on first run
- Convergence formula handles division by zero: `max(prior_error_count, 1)` in denominator
- First iteration convergence = 1.0 - (new_errors / 1.0) = neutral-ish
- Lock periods (first 2 iterations) don't downshift anyway

**Residual Risk**: Low (handled in formula)

---

### Risk 4: Model Downshift on False Positive Quality Spike

**What Could Break**: A lucky iteration with high test pass rate but large diff size could trigger downshift, and Sonnet might not be ready for complex code.

**Mitigation**:

- Diff quality penalty: 500+ lines changed = score 0.0 (blocks downshift regardless of test pass)
- Convergence check: if errors are rising, score drops (no downshift)
- 2-iteration streak requirement: one good iteration isn't enough
- Conservative threshold (>0.8)

**Residual Risk**: Low (multiple guards)

---

### Risk 5: Thrashing: Rapid Downshift/Upshift Cycles

**What Could Break**: If iterations alternate between high and low quality, model could oscillate Opus↔Sonnet, wasting tokens and confusing the loop.

**Mitigation**:

- Anti-thrash rule: After upshift to Opus, wait N iterations (cooldown) before re-downshifting
- Default cooldown = 2 iterations
- Only enter cooldown on upshift (not on downshift)

**Residual Risk**: Very Low (cooldown enforced)

---

### Risk 6: Incorrect Diff Size Calculation

**What Could Break**: `git diff --stat` parsing could fail (e.g., on merge commits, no prior commit, or malformed output), leading to incorrect diff_quality score.

**Mitigation**:

- Parse `git diff HEAD~1 --stat` carefully, with fallback to 0 on error
- Use `|| echo 0` pattern (safe under pipefail)
- Edge case: first iteration (no HEAD~1) defaults to 0 lines changed
- Conservative: 0 lines changed = score 1.0 (safe for downshift)

**Residual Risk**: Low (fallback to 0)

---

### Risk 7: Loop Restart Loses Routing Context

**What Could Break**: If `--max-restarts` triggers a session restart (e.g., context exhaustion), the new session reads prior iterations from `.claude/progress.md` but may not have model-routing history. Could cause restart to use Opus when prior session was using Sonnet.

**Mitigation**:

- Routing state stored in `.claude/model-routing-state.jsonl`, which survives restarts
- Fresh session reads prior state from file (not from session variables)
- Converges to same routing decision as prior session for same metrics
- Cost tracking includes all iterations across restart boundary

**Residual Risk**: Low (file persists across restarts)

---

### Risk 8: Cost Savings Overestimated

**What Could Break**: Estimated savings (28% for 6 Sonnet + 4 Opus) don't match actual token savings. Sonnet might cost more than expected, or Opus might not cost as much as baseline.

**Mitigation**:

- Savings calculation is **estimated** (rough 5:1 token ratio Opus:Sonnet)
- Log actual model used per iteration in `model-routing-state.jsonl`
- Cost module tracks actual spend separately
- Report is informational, not gated on savings

**Residual Risk**: Low (documented as estimate)

---

## Definition of Done

✓ **Quality Scoring**

- [ ] `score_iteration()` computes score from test pass/fail, diff size, error count
- [ ] Score is in range [0, 1000] (milli-score)
- [ ] Metric weighting verified: test 50%, diff 25%, convergence 25%
- [ ] Edge cases handled: first iteration, no prior state, zero error count

✓ **Model Routing State Machine**

- [ ] `route_model()` implements downshift logic: 2+ consecutive high scores → Sonnet
- [ ] Implements upshift logic: score <500 or test regression → Opus
- [ ] Iterations 1–2 locked to Opus
- [ ] Cooldown prevents thrashing after upshift
- [ ] Error count rising blocks downshift

✓ **State Persistence**

- [ ] `save_routing_state()` atomically writes to `.claude/model-routing-state.jsonl`
- [ ] `load_routing_state()` reads prior state or initializes defaults
- [ ] State survives loop restarts
- [ ] JSON format allows post-analysis of routing history

✓ **Integration**

- [ ] `sw-loop.sh` calls `score_iteration()` after each test run
- [ ] Next iteration uses model from `suggest_next_model()`
- [ ] Claude CLI invoked with correct `--model` flag
- [ ] Loop summary includes model routing summary and cost estimate

✓ **Configuration**

- [ ] `.claude/daemon-config.json` includes downshift/upshift thresholds
- [ ] Thresholds configurable (not hardcoded)
- [ ] `SW_ADAPTIVE_MODEL` environment variable enables/disables feature

✓ **Cost Tracking**

- [ ] Each iteration logs: iteration number, model used, score, routing decision
- [ ] Summary shows: total Opus vs Sonnet iterations
- [ ] Savings calculation shown in loop output
- [ ] Actual token spend tracked separately by cost module

✓ **Safety**

- [ ] Never downshifts during first 2 iterations
- [ ] Never downshifts if error count rising
- [ ] Requires 2+ consecutive high scores (not just 1)
- [ ] Downshift blocked if diff >500 lines
- [ ] Upshift triggers immediately on degradation

✓ **Testing**

- [ ] Unit tests: metric normalization (≥8 tests)
- [ ] Unit tests: score computation (≥12 tests)
- [ ] Unit tests: state machine transitions (≥15 tests)
- [ ] Integration test: full 10-iteration scenario
- [ ] All tests pass with 100% logic coverage
- [ ] Test suite runs in `npm test`

✓ **Documentation**

- [ ] README or `.claude/CLAUDE.md` documents adaptive model downshift
- [ ] Scoring function documented
- [ ] Configuration options listed
- [ ] Example loop output shown
- [ ] Cost savings calculation explained

✓ **Observability**

- [ ] Each iteration score logged to `.claude/model-routing-state.jsonl`
- [ ] Routing decisions (downshift/upshift/stay) visible in log
- [ ] Loop summary human-readable
- [ ] Cost estimate shown at end

---

## Failure Mode Analysis

### Failure Mode 1: Oscillating Quality Prevents Convergence

**Scenario**: Iterations alternate between high-quality (score 850) and medium-quality (score 650). Loop never downshifts because streak never reaches 2.

**What Breaks**: Cost savings don't materialize; loop uses expensive Opus unnecessarily.

**Detection**: Loop runs 10+ iterations without downshifting, despite several high scores.

**Mitigation**:

- Monitor routing log for `high_score_streak` value
- If stuck, operator can manually raise `downshift_score` threshold in config (e.g., 750 instead of 800)
- Document that oscillating quality is rare (usually indicates test suite is flaky)

**Recovery**: Operator re-runs with tuned config, or accepts baseline Opus cost if quality is inherently unstable.

---

### Failure Mode 2: Sonnet Introduces Silent Logic Bug After Downshift

**Scenario**: Iterations 5–7 score high (test pass, low error count), loop downshifts to Sonnet. Sonnet's iteration 6 changes introduce a logic bug (e.g., off-by-one in loop) that doesn't get caught by unit tests. Bug surfaces later in integration testing.

**What Breaks**: Code is committed with subtle bug, cost savings purchased at quality cost.

**Detection**: Integration tests fail post-merge (too late for loop).

**Mitigation** (defense-in-depth):

1. **Primary**: Test quality signal is binary (pass/fail). If test suite is incomplete, this will fail us. → Recommending higher test coverage, E2E tests.
2. **Secondary**: Diff quality blocks downshift on large changes (diff >500 lines). → Small-change assumption is Sonnet's sweet spot.
3. **Tertiary**: Error convergence trend must be neutral/positive. → Catch rising errors early.
4. **Quaternary**: Use higher quality gates in compound_quality stage post-build.

**Residual Risk**: Medium (mitigated by test coverage assumption)

**Operator Responsibility**: Ensure test suite has good coverage. If this failure mode occurs, disable `--adaptive-model` and invest in test coverage.

---

### Failure Mode 3: State File Corruption During Concurrent Writes

**Scenario**: Two loop processes (or restarts) write to `.claude/model-routing-state.jsonl` simultaneously. File becomes corrupted or contains partial JSON.

**What Breaks**: Next iteration can't read state; uses defaults (Opus). Routing history lost.

**Detection**: `jq` error when reading state file; fallback to defaults occurs.

**Mitigation**:

- Use atomic writes: write to temp file, then `mv` (not `echo >`)
- Each write is a new JSON line (append-only, not modify-in-place)
- `mv` is atomic on POSIX systems
- On read, validate JSON before use: `jq empty <file && echo "valid"` before processing

**Recovery**: Delete `.claude/model-routing-state.jsonl`; loop restarts with fresh state. Next routing decision will be correct.

**Residual Risk**: Very Low (atomic writes + validation + recoverable)

---

### Failure Mode 4: Error Count Parsing Fails

**Scenario**: Progress file or prior iteration state doesn't contain `error_count`. Parser fails to extract integer; uses default (0 or unset).

**What Breaks**: Convergence metric computed incorrectly; might allow downshift when errors are rising.

**Detection**: Routing log shows inconsistent error_count values; convergence score suspiciously high.

**Mitigation**:

- Use safe defaults: `error_count=${error_count:-0}` pattern
- Always extract from consistent source (e.g., last `.claude/model-routing-state.jsonl` entry)
- Fallback: if extraction fails, use `0` (safe default—unknown errors don't penalize downshift)

**Recovery**: Operator can manually inspect routing log and adjust config thresholds if needed.

**Residual Risk**: Low (safe defaults)

---

## Test Pyramid Breakdown

**Target**: 70 unit tests covering business logic, 12 integration tests for component boundaries, 3 E2E tests for critical paths.

### Unit Tests (70%)

**Metric Normalization** (8 tests)

- ✓ Clamp value at min boundary
- ✓ Clamp value at max boundary
- ✓ Value at midpoint (0.5)
- ✓ Value already normalized
- ✓ Negative values clamped to 0
- ✓ Values > max clamped to 1
- ✓ Output is integer (milli-scale)
- ✓ Idempotency: normalize twice = once

**Score Computation** (12 tests)

- ✓ Perfect iteration: all signals high (score ~1000)
- ✓ Failed iteration: test fails (score ~0)
- ✓ Large diff (500+ lines): score ~0 despite test pass
- ✓ Error count rising: convergence metric low
- ✓ Error count falling: convergence metric high
- ✓ Mixed quality: moderate score
- ✓ Empty diff (0 lines): score ~1000
- ✓ First iteration (no prior state): uses safe defaults
- ✓ Weighting: test (50%) > diff (25%) + convergence (25%)
- ✓ Edge case: all metrics zero → score 0
- ✓ Edge case: all metrics max → score 1000
- ✓ Output is integer [0, 1000]

**State Machine** (28 tests)

- ✓ Initial state: Opus
- ✓ Iteration 1 locked: uses Opus
- ✓ Iteration 2 locked: uses Opus
- ✓ Iteration 3 high score: stays Opus (need 2+ streak)
- ✓ Iterations 3–4 both >800: Downshift to Sonnet
- ✓ Downshift sets `high_score_streak = 0` on Sonnet
- ✓ Score <500 on Sonnet: Upshift to Opus
- ✓ Test fails after pass: Upshift to Opus immediately
- ✓ Upshift sets cooldown = 2
- ✓ Cooldown prevents downshift iteration N+1
- ✓ Cooldown active iteration N+1, N+2
- ✓ Cooldown expires iteration N+3 (can downshift again)
- ✓ Error count rising: score low, no downshift
- ✓ Diff >500 lines: even with high test, score blocks downshift
- ✓ Save state atomically: temp file + mv
- ✓ Load state from file: all fields restored
- ✓ Initialize on missing file: defaults correct
- ✓ State file JSON valid after save (use `jq` to validate)
- ✓ Routing decision matches expected logic
- ✓ Multiple iterations in sequence: streak counter increments
- ✓ Streak resets on downshift
- ✓ Streak resets on upshift
- ✓ Cost estimate calculation: correct ratio
- ✓ Milli-score translation: \*1000 accurate
- ✓ Fallback model on config missing: defaults to sensible values
- ✓ Cooldown counter decrements each iteration
- ✓ High score vs high score streak independence

### Integration Tests (20%)

- ✓ Full loop with 10 iterations, varying quality
- ✓ Downshift correctness across realistic scenario
- ✓ Upshift triggers on real test failure
- ✓ Cost savings calculation matches iteration count
- ✓ State file grows correctly (one line per iteration)
- ✓ Restart scenario: fresh session reads prior state
- ✓ Multiple downshift/upshift cycles
- ✓ Cooldown correctly prevents yo-yo
- ✓ Diff size parsing from real git
- ✓ Error count tracking across iterations
- ✓ Edge case: loop with only 2 iterations (both locked)
- ✓ Edge case: loop with all high scores (max downshifts)

### E2E Tests (10%)

- ✓ **Scenario 1**: 10 iterations, standard quality curve (dip then recovery)
  - Expected: 2 Opus (lock) + 3 Opus (warmup) + 5 Sonnet (high quality) = 60% savings
- ✓ **Scenario 2**: 7 iterations with early upshift
  - Iter 1–2: Opus, Iter 3–4: Sonnet (downshift), Iter 5: Upshift + cooldown, Iter 6–7: Opus
  - Expected: 5 Opus + 2 Sonnet = 20% savings
- ✓ **Scenario 3**: Edge case, first run (no prior state)
  - Ensure graceful initialization, correct first-iteration behavior

---

## Coverage Targets

| Layer                 | Target Coverage | Critical Paths                                       |
| --------------------- | --------------- | ---------------------------------------------------- |
| Metric normalization  | 100%            | All boundary conditions, clamps                      |
| Score computation     | 100%            | Weight formula, all metrics                          |
| Routing state machine | 95%+            | All transitions (downshift, upshift, cooldown, lock) |
| State I/O             | 95%+            | Save/load, atomic writes, JSON validation            |
| Integration           | 80%+            | Full loop scenario, restart scenario, edge cases     |

**Critical Paths to Test**:

1. **Happy Path**: High-quality iterations → successful downshift → cost savings
2. **Error Case 1**: Low-quality iteration → immediate upshift
3. **Error Case 2**: Test regression (pass→fail) → immediate upshift
4. **Edge Case 1**: First 2 iterations always use Opus
5. **Edge Case 2**: Large diff (500+) blocks downshift regardless of other metrics
6. **Edge Case 3**: Error count rising blocks downshift
7. **Edge Case 4**: Cooldown prevents thrashing

---

## Implementation Sequence

**Phase 1: Core Module (3 tasks)**

1. Create `scripts/lib/loop-model-router.sh` with all functions
2. Create `scripts/lib/loop-model-router-test.sh` with unit tests
3. Verify all unit tests pass (70 tests)

**Phase 2: Integration (2 tasks)** 4. Modify `scripts/sw-loop.sh` to call routing functions 5. Create E2E test `scripts/sw-adaptive-model-test.sh`

**Phase 3: Configuration & Polish (2 tasks)** 6. Update `.claude/daemon-config.json` with thresholds 7. Update `.claude/CLAUDE.md` documentation

**Phase 4: Validation (1 task)** 8. Run full test suite: `npm test` (all 102+ tests pass)

---

## Alternatives Considered (Detailed)

### Why NOT Approach 2 (In-Memory State)

- **Session restarts lose state**: If loop hits context exhaustion and restarts with `--max-restarts`, the new session has no routing history. Would need to reconstruct from git, which is fragile.
- **Not observable**: Operator can't inspect routing decisions post-hoc.
- **Harder to extend**: Adding more metrics or state would require modifying sw-loop.sh's global scope.

### Why NOT a Separate Scoring Service

- **Over-engineered**: Adding a daemon/socket service for a simple function is unnecessary.
- **Operational burden**: More moving parts, more to monitor, more to fail.
- **No benefit**: Bash is fast enough for scoring.

### Why NOT Machine Learning Model

- **Overkill**: We don't need ML for this; simple heuristics (test pass/fail, diff size, error trend) are sufficient and interpretable.
- **Bias risk**: ML model might learn spurious patterns from historical data.
- **Observability**: Hard to explain why model made a routing decision.

---

## Summary

This plan delivers a **pure-bash, observable, safe, and cost-effective** quality-scoring system for build loops. Key design decisions:

1. **Stateful file-based router** (observable, survives restarts)
2. **Conservative downshift criteria** (2+ consecutive high scores, locks first 2 iterations)
3. **Multiple safety guards** (error convergence, diff size, error-rise detection)
4. **Anti-thrash cooldown** (prevents oscillation)
5. **Comprehensive testing** (70 unit + 12 integration + 3 E2E tests)
6. **Full observability** (JSON log of all routing decisions)
7. **Opt-in only** (backward-compatible, no impact if disabled)

**Estimated Savings**: 20–30% cost reduction on easy iterations without sacrificing reliability.

**Timeline**: 3–4 days for implementation, testing, and integration.
