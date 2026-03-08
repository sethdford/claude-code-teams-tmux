# Plan: Test Failure Recovery Loop with Smart Iteration Budget Management

## Root Cause Hypothesis

The build loop (`sw-loop.sh`) currently retries after test failures with diagnosis injection and memory-based fix lookup, but it has no mechanism to:

1. **Extract specific test names** from test output — it only extracts generic error lines via `write_error_summary()` (grep for error/fail patterns in last 30 lines)
2. **Track which tests fail across iterations** — `diagnoses.txt` tracks error *category* (e.g., "test_assertion"), not individual test names
3. **Abort early on repeated test failures** — the circuit breaker and stuckness detector use generic signals (diff hash, error hash, exit codes), not test-specific tracking
4. **Inject previously-failed test names** into the next iteration prompt — `compose_prompt()` includes generic error lines but not structured "these specific tests keep failing" context

The existing `detect_stuckness()` in `lib/loop-convergence.sh` catches *generic* repetition (same error hash 3x), but this is too coarse — it doesn't distinguish between "test A fixed but test B broke" and "test A keeps failing." The `diagnose_failure()` function escalates strategy after 2 repeats of the same *category*, but two different assertion failures both classify as "test_assertion" even if they're in completely different tests.

## Evidence Gathered

- **`write_error_summary()`** (sw-loop.sh:1051-1112): Extracts last 30 lines matching error patterns, writes to `error-summary.json`. No test name extraction.
- **`diagnose_failure()`** (sw-loop.sh:837-939): Pattern-based classification into 8 categories. Tracks repeat count per category in `diagnoses.txt`. Escalates at 2+ repeats.
- **`compose_prompt()`** (lib/loop-iteration.sh:82-401): Injects `error-summary.json` lines into prompt. No "previously failed tests" section.
- **`detect_stuckness()`** (lib/loop-convergence.sh:170-337): 7-signal detector. Signal 3 (error hash repetition) is the closest to what we need, but it hashes the entire error log, not individual test names.
- **`erract_classify()`** (lib/error-actionability.sh:280-300): Classifies errors into types but doesn't extract test names.
- **`testopt_*` functions** (lib/test-optimizer.sh): Test discovery and history, but focused on test *files*, not individual test names from failure output.
- **Skill guidance** (scripts/skills/generated/intelligent-test-failure-recovery.md): Detailed design for test name extraction patterns for Jest, Pytest, Go test, npm test.

## Fix Strategy

Create a new library module `lib/loop-test-failure-tracker.sh` that:
1. Parses test output to extract individual test names (multi-framework)
2. Tracks failed tests per iteration in a JSON state file
3. Detects 3+ consecutive failures of the same test
4. Provides context injection for the next iteration prompt
5. Triggers early abort when repeated failures are detected

Integrate into the existing loop at 3 points:
- After `run_test_gate()` → call tracker to record failures
- In `compose_prompt()` → inject "Previously failed tests" section
- Before iteration starts → check for abort condition

This approach is minimally invasive — a new module with 3 integration points in existing code, plus a new test suite.

## Alternatives Considered

### Alternative 1: Extend `diagnose_failure()` to track test names
- **Pro**: No new file, extends existing pattern
- **Con**: `diagnose_failure()` is already complex (100 lines), mixing test tracking with error classification violates SRP. Also, diagnosis happens *after* test failure but *before* the next iteration — the tracking window is awkward.
- **Blast radius**: Medium — changing a core function risks regression

### Alternative 2: Add test name tracking to `detect_stuckness()`
- **Pro**: Stuckness already has 7 signals; adding an 8th is natural
- **Con**: Stuckness detection fires *after* the iteration completes (line ~2366), which is too late for injection into the current iteration's prompt. Also, stuckness triggers session restart (at count 3), not early abort with a specific message.
- **Blast radius**: Medium — altering convergence logic

### Alternative 3 (Chosen): New `lib/loop-test-failure-tracker.sh` module
- **Pro**: Clean separation of concerns, testable in isolation, minimal changes to existing code (3 integration points). Follows the existing pattern of `lib/loop-*.sh` modules.
- **Con**: New file to maintain
- **Blast radius**: Low — new module with surgical integration

## Files to Modify

| File | Action | Purpose |
|------|--------|---------|
| `scripts/lib/loop-test-failure-tracker.sh` | **Create** | New module: test name extraction, failure tracking, abort detection, context injection |
| `scripts/sw-loop.sh` | **Modify** | Source new module, call tracker after test gate, check abort before iteration |
| `scripts/lib/loop-iteration.sh` | **Modify** | Inject "Previously failed tests" section into `compose_prompt()` |
| `scripts/sw-loop-test-failure-tracker-test.sh` | **Create** | Test suite for the new module |

## Implementation Steps

### Step 1: Create `scripts/lib/loop-test-failure-tracker.sh`

New module with these functions:

#### `tft_extract_test_names(test_output)`
Extract individual test names from test output. Handle multiple frameworks:

```bash
# Jest:     "FAIL  src/auth.test.js" or "✕ login should validate credentials"
# Pytest:   "FAILED tests/test_auth.py::test_login"
# Go test:  "--- FAIL: TestLogin" or "FAIL\tpkg/auth"
# Vitest:   "FAIL  src/auth.test.ts > login > validates credentials"
# Generic:  "FAIL:" or "✗" followed by test identifier
```

Output: newline-separated list of test identifiers (max 20).

#### `tft_record_iteration(iteration, test_output)`
- Extract test names from output
- Load existing state from `$LOG_DIR/test-failure-tracking.json`
- For each failed test: append current iteration to its failure history
- For tests that passed (not in current failures): reset their streak
- Write state atomically (tmp + mv)

State format:
```json
{
  "version": 1,
  "failed_tests": {
    "src/auth.test.js::login": {"iterations": [3, 4, 5], "first_seen": 3},
    "tests/api.test.py::test_endpoint": {"iterations": [4, 5], "first_seen": 4}
  },
  "last_iteration": 5,
  "last_updated": "2026-03-08T12:34:56Z"
}
```

#### `tft_check_repeated_failures(threshold)`
- Load state, check each test's iteration history
- A test has "repeated failure" if it has `threshold` (default 3) consecutive iterations in its list ending at the current iteration
- Returns 0 (true) if any test meets threshold, 1 (false) otherwise
- Sets `TFT_ABORT_REASON` with human-readable message
- Sets `TFT_REPEATED_TESTS` with the list of repeated-failure tests

#### `tft_compose_context_section()`
- If there are tracked failures, produce a markdown section:
```
## Previously Failed Tests
These tests have failed in recent iterations — focus fixes here:
- src/auth.test.js::login (failed iterations: 3, 4, 5) ⚠️ 3 consecutive
- tests/api.test.py::test_endpoint (failed iterations: 4, 5)
```
- Max 5 tests to avoid context bloat
- Returns empty string if no tracked failures

#### `tft_reset()`
- Clear tracking state (called on session restart)

### Step 2: Integrate into `scripts/sw-loop.sh`

1. **Source the module** (~line 780, where other lib modules are sourced):
```bash
source "$SCRIPT_DIR/lib/loop-test-failure-tracker.sh" 2>/dev/null || true
```

2. **Record after test gate** (after line 2237 `write_error_summary`):
```bash
# Track individual test failures for smart abort
if [[ "${TEST_PASSED:-}" == "false" ]] && type tft_record_iteration >/dev/null 2>&1; then
    tft_record_iteration "$ITERATION" "${TEST_OUTPUT:-}" 2>/dev/null || true
elif [[ "${TEST_PASSED:-}" == "true" ]] && type tft_record_iteration >/dev/null 2>&1; then
    # Record passing iteration to reset streaks
    tft_record_iteration "$ITERATION" "" 2>/dev/null || true
fi
```

3. **Check abort before iteration** (after line 2109 `check_circuit_breaker`):
```bash
# Smart test failure abort — same test failing 3+ consecutive iterations
if type tft_check_repeated_failures >/dev/null 2>&1; then
    if tft_check_repeated_failures 3; then
        STATUS="abort_repeated_test_failure"
        error "Aborting: repeated test failure — ${TFT_ABORT_REASON:-unknown}"
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.abort_repeated_test_failure" \
                "iteration=$ITERATION" \
                "tests=${TFT_REPEATED_TESTS:-}" \
                "reason=${TFT_ABORT_REASON:-}"
        fi
        write_state
        write_progress
        show_summary
        break
    fi
fi
```

4. **Reset on session restart** (in the restart block, ~line 2484):
```bash
type tft_reset >/dev/null 2>&1 && tft_reset || true
```

### Step 3: Integrate into `scripts/lib/loop-iteration.sh`

In `compose_prompt()`, after the error summary section (~line 118), add:

```bash
# Previously failed test names (smart abort context)
local failed_tests_section=""
if type tft_compose_context_section >/dev/null 2>&1; then
    failed_tests_section="$(tft_compose_context_section 2>/dev/null || true)"
fi
```

And inject into the prompt heredoc (after `${error_summary_section}`):
```
${failed_tests_section:+$failed_tests_section
}
```

### Step 4: Update metrics tracking

In `show_summary()` and the event emission, ensure `STATUS="abort_repeated_test_failure"` is handled:
- The `loop.iteration_complete` event already emits `status=` — the new status value will flow through automatically
- Add the new status to any status-display logic in `show_summary()`

### Step 5: Create test suite `scripts/sw-loop-test-failure-tracker-test.sh`

## Task Checklist

- [ ] Task 1: Create `scripts/lib/loop-test-failure-tracker.sh` with `tft_extract_test_names()` supporting Jest, Pytest, Go test, Vitest, and generic formats
- [ ] Task 2: Implement `tft_record_iteration()` with atomic JSON state writes and streak tracking
- [ ] Task 3: Implement `tft_check_repeated_failures()` with configurable threshold (default 3) and abort reason generation
- [ ] Task 4: Implement `tft_compose_context_section()` for prompt injection (max 5 tests)
- [ ] Task 5: Implement `tft_reset()` for session restart cleanup
- [ ] Task 6: Integrate module sourcing and test failure recording into `sw-loop.sh` after test gate
- [ ] Task 7: Integrate abort check into `sw-loop.sh` main loop (before iteration increment)
- [ ] Task 8: Integrate context injection into `compose_prompt()` in `lib/loop-iteration.sh`
- [ ] Task 9: Add session restart reset call in `sw-loop.sh`
- [ ] Task 10: Emit `loop.abort_repeated_test_failure` event with test names and reason
- [ ] Task 11: Create test suite with parser correctness tests (Jest, Pytest, Go test, Vitest, generic, empty output)
- [ ] Task 12: Add integration test: simulate 5 iterations where same test fails 3 consecutive → verify abort
- [ ] Task 13: Add edge case tests: non-consecutive failures (no abort), malformed output (graceful), >20 tests (truncation)
- [ ] Task 14: Register test suite in `package.json`
- [ ] Task 15: Run full test suite to verify no regressions

## Testing Approach

### Test Pyramid Breakdown
- **Unit tests** (12 tests): Parser correctness for each framework, state read/write, consecutive detection, context section generation, reset
- **Integration tests** (4 tests): Multi-iteration simulation with abort, non-abort scenario, mixed frameworks, session restart behavior
- **Edge case tests** (4 tests): Empty output, malformed JSON state recovery, >20 test truncation, non-consecutive pattern

### Coverage Targets
- 100% of `tft_extract_test_names()` branches (each framework pattern + fallback + empty)
- 100% of abort logic paths (consecutive detection, threshold boundary, grace period)
- 100% of state management (create, update, reset, corrupt recovery)

### Critical Paths to Test

**Happy path**: Test fails → names extracted → tracked → 3 consecutive → abort with clear message + event

**Error cases**:
1. Test output contains no parseable test names → graceful no-op, loop continues
2. State file corrupted/missing → reset to empty state, log warning, continue
3. Test passes after 2 consecutive failures → streak reset, no abort

**Edge cases**:
1. Non-consecutive failures (iterations 1, 3, 5) → no abort (gap breaks streak)
2. First 2 iterations → no abort even if same test fails (too early to judge)
3. 25+ failing tests → only track first 20, inject top 5 into context
4. Test name with special characters (colons, spaces, Unicode) → safe handling

## Risk Analysis

| Risk | Impact | Mitigation |
|------|--------|------------|
| False positive abort on flaky test | Wastes a pipeline run | Require 3 *consecutive* iterations (not just 3 total). Don't abort in first 2 iterations. |
| Parser misses test names for unusual framework | Falls back to no tracking, loop continues as before | Generic fallback pattern. Log parse results for debugging. |
| State file corruption | Lose tracking for current session | Atomic writes (tmp+mv). Validate JSON on read, reset if invalid. |
| Context bloat from many failed tests | Reduces agent effectiveness | Cap at 5 tests in injection. Total section is ~200 chars max. |
| Breaking existing convergence/stuckness | Regression in loop termination | New module is additive — existing signals unchanged. `type ... >/dev/null` guards prevent breakage if module missing. |

## Definition of Done

- [ ] `tft_extract_test_names` correctly parses test names from Jest, Pytest, Go test, Vitest, and npm test output
- [ ] Failed tests tracked per iteration in `test-failure-tracking.json` with atomic writes
- [ ] Build loop aborts early with `STATUS="abort_repeated_test_failure"` when same test fails 3+ consecutive iterations
- [ ] "Previously failed tests: [list]" injected into next iteration prompt via `compose_prompt()`
- [ ] Event `loop.abort_repeated_test_failure` emitted with test names and reason
- [ ] Test suite passes with ≥20 test cases covering parser, tracking, abort logic, and edge cases
- [ ] Existing test suites (`sw-loop-test.sh`, `sw-convergence-test.sh`) still pass
- [ ] No abort triggered in first 2 iterations (grace period)
- [ ] Non-consecutive failures do not trigger abort
- [ ] Session restart resets tracking state
