# Implementation Plan: Test Failure Recovery Loop with Smart Iteration Budget Management

**Goal**: Implement intelligent test failure recovery and adaptive iteration budget management to:
1. Detect test failures and re-enter build/test cycle with enhanced error context
2. Adapt iteration limits based on issue complexity, failure patterns, and context exhaustion
3. Track failure patterns across iterations for intelligent decision-making

**Complexity Level**: Medium-High (8/10)
**Estimated Scope**: 10-15 focused tasks
**Integration Points**: 4 major locations (library, sw-loop.sh, loop-iteration.sh, tests)
**Estimated Effort**: 40-50 hours

---

## Problem Statement & Analysis

The build loop (`sw-loop.sh`) currently:
- ✅ Detects test failures via `TEST_PASSED` flag
- ✅ Extracts generic error lines via `write_error_summary()`
- ✅ Has basic iteration limits (MAX_ITERATIONS, auto-extend)
- ✅ Has apply_adaptive_budget() for intelligent budgeting
- ❌ **Does NOT** comprehensively test the recovery mechanism
- ❌ **Does NOT** have smart budget based on failure severity and patterns
- ❌ **Does NOT** distinguish context exhaustion from code errors
- ❌ **Does NOT** track per-test failure signatures
- ❌ **Does NOT** escalate budget for high-impact failures

This means:
1. When tests fail, recovery is haphazard — no structured error context injected
2. Iteration budget is static per complexity level, doesn't adapt to actual failure patterns
3. If same test fails 3x, loop doesn't recognize pattern or escalate
4. No distinction: "I'm stuck in infinite loop" vs "Context window full" vs "Different bugs each iteration"

**Root Cause**: Test failure recovery exists but lacks:
- Per-test failure tracking (specific vs generic)
- Failure severity detection (assertion vs syntax vs timeout)
- Adaptive budget escalation (increase budget on repeated failures)
- Context exhaustion detection (token counting)

---

## Design Alternatives Considered

### Alternative 1: Extend `diagnose_failure()` to track test names
**Pros**:
- Builds on existing error classification logic
- Minimal new infrastructure

**Cons**:
- `diagnose_failure()` is already complex (100+ lines)
- Violates Single Responsibility Principle (error classification + test tracking)
- Diagnosis happens *after* test failure but *before* next iteration — awkward for injection
- Would require refactoring existing function

**Blast Radius**: Medium — changes core diagnostic path

---

### Alternative 2: Add test name tracking to `detect_stuckness()`
**Pros**:
- Stuckness detection already has 7 signals; adding an 8th is natural
- Could leverage existing signal infrastructure

**Cons**:
- Stuckness fires *after* iteration completes — too late for same-iteration injection
- Stuckness triggers session restart at count 3 — not a clean "early abort" message
- Mixes stuckness detection (generic loop health) with test-specific logic
- Test tracking is a separate concern

**Blast Radius**: Medium-High — alters convergence/stuckness logic

---

### Alternative 3 (Chosen): New `lib/loop-test-failure-tracker.sh` module ✓
**Pros**:
- ✅ Clean separation of concerns
- ✅ Testable in isolation with ~20 unit tests
- ✅ Minimal changes to existing code (3 integration points)
- ✅ Follows existing pattern of `lib/loop-*.sh` modules
- ✅ Non-breaking if module missing (`type ... >/dev/null` guards)
- ✅ Easy to disable/experiment with

**Cons**:
- New file to maintain

**Blast Radius**: **Low** — surgical integration points, additive changes

**Trade-offs**: Simplicity (40% of complexity) vs. Separation of Concerns (worth the extra module)

---

## Task Decomposition with Explicit Dependencies

### Phase 1: Core Module Implementation

**Task 1: Create `lib/loop-test-failure-tracker.sh` with test name extraction**
- **Dependency**: None
- **Time**: ~1 hour
- **Deliverable**: `tft_extract_test_names()` function
- **Details**:
  - Parse Jest format: `FAIL  src/auth.test.js` or `✕ login should validate credentials`
  - Parse Pytest format: `FAILED tests/test_auth.py::test_login`
  - Parse Go test format: `--- FAIL: TestLogin` or `FAIL\tpkg/auth`
  - Parse Vitest format: `FAIL  src/auth.test.ts > login > validates credentials`
  - Parse generic format: `FAIL:` or `✗` followed by identifier
  - Output: Max 20 newline-separated test identifiers
  - Handle empty/malformed output gracefully (return empty string)

**Task 2: Implement state management functions**
- **Dependency**: Task 1
- **Time**: ~45 minutes
- **Deliverables**:
  - `tft_record_iteration(iteration, test_output)` — atomic JSON writes to `$LOG_DIR/test-failure-tracking.json`
  - `tft_check_repeated_failures(threshold)` — detect 3+ consecutive failures
  - `tft_compose_context_section()` — generate markdown section for injection
  - `tft_reset()` — clear state on session restart
- **Details**:
  - State format:
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
  - Atomic writes: tmp file + `mv` (not direct echo)
  - Graceful degradation: warn on corruption, reset to empty state
  - "Consecutive" = streak ends at current iteration (iterations list must have no gaps within threshold)
  - `TFT_ABORT_REASON` variable for human-readable message
  - `TFT_REPEATED_TESTS` variable with comma-separated test names

**Task 3: Create comprehensive test suite `sw-loop-test-failure-tracker-test.sh`**
- **Dependency**: Task 1, Task 2
- **Time**: ~1.5 hours
- **Deliverables**: ≥20 test cases
- **Test Categories**:
  - **Parser Tests (6 tests)**: Jest, Pytest, Go test, Vitest, generic, empty output
  - **State Management Tests (4 tests)**: create, read, update, corrupt recovery
  - **Consecutive Detection Tests (3 tests)**: exact threshold (3), below (2), above (5)
  - **Non-consecutive Tests (2 tests)**: gaps break streak, non-adjacent failures
  - **Grace Period Tests (2 tests)**: no abort in iter 1-2 even if failure
  - **Edge Cases (3 tests)**: >20 tests truncation, special chars, unicode test names

---

### Phase 2: Loop Integration

**Task 4: Source module and integrate into `sw-loop.sh`** ⇐ Blocks Task 5
- **Dependency**: Task 2, Task 3 (tests passing)
- **Time**: ~15 minutes
- **Deliverables**:
  - Source line at ~line 40 with other lib modules
  - ```bash
    [[ -f "$SCRIPT_DIR/lib/loop-test-failure-tracker.sh" ]] && source "$SCRIPT_DIR/lib/loop-test-failure-tracker.sh" 2>/dev/null || true
    ```

**Task 5: Record test failures after test gate** ⇐ Depends on Task 4
- **Dependency**: Task 4
- **Time**: ~15 minutes
- **Location**: After `write_error_summary` at ~line 2237
- **Code**:
  ```bash
  # Track individual test failures for smart abort
  if type tft_record_iteration >/dev/null 2>&1; then
      local test_output_for_tracking=""
      [[ "${TEST_PASSED:-}" == "false" ]] && test_output_for_tracking="${TEST_OUTPUT:-}"
      tft_record_iteration "$ITERATION" "$test_output_for_tracking" 2>/dev/null || true
  fi
  ```

**Task 6: Add abort check in main loop** ⇐ Depends on Task 4, Task 5
- **Dependency**: Task 4
- **Time**: ~20 minutes
- **Location**: After `check_circuit_breaker` at ~line 2109 (before ITERATION increment)
- **Code**:
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

**Task 7: Reset state on session restart** ⇐ Depends on Task 4
- **Dependency**: Task 4
- **Time**: ~10 minutes
- **Location**: In restart block at ~line 2074 or in the restart initialization
- **Code**:
  ```bash
  # Reset test failure tracking for fresh session
  type tft_reset >/dev/null 2>&1 && tft_reset || true
  ```

---

### Phase 3: Prompt Composition Integration

**Task 8: Inject failed test context into prompts** ⇐ Depends on Task 2
- **Dependency**: Task 2 (context section function), Task 4 (module sourced)
- **Time**: ~25 minutes
- **Location**: In `compose_prompt()` at ~lib/loop-iteration.sh:118, after error summary section
- **Code**:
  ```bash
  # Previously failed test names (smart abort context)
  local failed_tests_section=""
  if type tft_compose_context_section >/dev/null 2>&1; then
      failed_tests_section="$(tft_compose_context_section 2>/dev/null || true)"
  fi
  ```
  And inject into heredoc:
  ```bash
  ${failed_tests_section:+${failed_tests_section}
  }
  ```

---

### Phase 4: Testing & Verification

**Task 9: Run full test suite and verify no regressions**
- **Dependency**: Task 3, Task 6, Task 8
- **Time**: ~30 minutes
- **Commands**:
  ```bash
  npm test  # All 102+ test suites
  ./scripts/sw-loop-test-failure-tracker-test.sh  # New suite specifically
  ./scripts/sw-loop-test.sh  # Existing loop tests
  ./scripts/sw-convergence-test.sh  # Convergence/stuckness tests
  ```
- **Success Criteria**:
  - ✅ All 20+ new tests pass
  - ✅ No regressions in loop/convergence tests
  - ✅ Exit code 0 from npm test

**Task 10: Integration smoke test in live loop (optional)**
- **Dependency**: Task 9
- **Time**: ~20 minutes (optional)
- **Details**: Run a mini loop with a test that fails 3x, verify abort
  - Create temp repo with flaky test
  - Run: `shipwright loop "fix test" --test-cmd "npm test" --max-iterations 10`
  - Verify loop exits with `STATUS="abort_repeated_test_failure"` at iteration 5 or less

---

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|-----------|
| **False positive abort on flaky test** | Medium | High | Require 3 *consecutive* iterations (not just 3 total). Grace period: no abort in iterations 1-2. Add `--grace-iterations` flag if needed. |
| **Parser misses test names (unusual framework)** | Low | Low | Fallback to generic pattern. Log parse results. Loop continues as before if no names extracted. |
| **JSON state corruption** | Low | Medium | Atomic writes (tmp+mv). Validate JSON on read. Reset to empty state on corruption, log warning. |
| **Context bloat from many failed tests** | Low | Low | Cap at 5 tests in injection. ~200 chars max per section. |
| **Breaking existing convergence logic** | Very Low | High | New module is additive. Existing `detect_stuckness()` unchanged. Guards prevent breakage if module missing (`type ... >/dev/null`). |
| **Memory exhaustion from large state file** | Very Low | Low | Max 20 tests tracked. State file ~500 bytes typical. Annual rotation if ever needed. |
| **Race condition in atomic file writes** | Very Low | Medium | Use `mv` (atomic on same filesystem), not `echo >`. Temp file in same dir as target. |

---

## Definition of Done (Acceptance Criteria)

### Functional Requirements
- [ ] **Test name extraction**: `tft_extract_test_names()` correctly parses Jest, Pytest, Go test, Vitest, and npm test output with ≥90% accuracy
- [ ] **State tracking**: Failed tests tracked per iteration in `test-failure-tracking.json` with atomic writes
- [ ] **Early abort**: Build loop exits with `STATUS="abort_repeated_test_failure"` when same test fails 3+ *consecutive* iterations
- [ ] **Context injection**: "Previously failed tests: [list]" section injected into agent prompt via `compose_prompt()`
- [ ] **Event emission**: `loop.abort_repeated_test_failure` event emitted with test names and abort reason
- [ ] **Grace period**: No abort triggered in first 2 iterations, even if tests fail
- [ ] **Non-consecutive handling**: Failures in iterations 1, 3, 5 do NOT trigger abort (gaps break streak)
- [ ] **Session restart reset**: Tracking state cleared on session restart, fresh start with clean file

### Quality Requirements
- [ ] **Test coverage**: ≥20 test cases covering happy path, error cases, edge cases
  - Jest/Pytest/Go/Vitest parser tests (6)
  - State management tests (4)
  - Consecutive detection tests (3)
  - Non-consecutive tests (2)
  - Grace period tests (2)
  - Edge case tests (3)
- [ ] **No regressions**: Existing test suites pass
  - `sw-loop-test.sh` — all cases pass
  - `sw-convergence-test.sh` — all cases pass
  - Full `npm test` — exit 0
- [ ] **Error handling**: Graceful degradation on malformed input, JSON corruption, missing files
- [ ] **Performance**: No measurable slowdown in loop iterations (<50ms overhead per iteration)
- [ ] **Code quality**:
  - Bash 3.2 compatible (no associative arrays, `readarray`, etc.)
  - Follows Shipwright shell standards (`set -euo pipefail`, atomic writes, `emit_event`)
  - Documented with inline comments for complex logic
  - No shell injection vulnerabilities (proper quoting, `jq --arg` for JSON)

### Integration Requirements
- [ ] **Module sourcing**: New module sourced in `sw-loop.sh` with proper guards
- [ ] **Test gate integration**: Failure tracking called after `write_error_summary()`
- [ ] **Abort integration**: Check happens before iteration increment (allows proper STATE/progress save)
- [ ] **Prompt injection**: Context section appears in composed prompt for next iteration
- [ ] **Event tracking**: Event emitted with proper format (iteration, test names, reason)
- [ ] **Session state**: Reset function called on session restart

---

## Implementation Steps (Detailed)

### Step 1: Create `scripts/lib/loop-test-failure-tracker.sh` (Core Module)

File structure:
```bash
#!/usr/bin/env bash
# VERSION=1.0.0
# Test failure name extraction and tracking for smart loop abort

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Global variables
TFT_STATE_FILE=""
TFT_ABORT_REASON=""
TFT_REPEATED_TESTS=""

# Function 1: tft_extract_test_names(test_output) → stdout
# Parse test output and extract individual test names
# Supports: Jest, Pytest, Go test, Vitest, generic
# Returns: max 20 newline-separated test identifiers
tft_extract_test_names() {
    local output="$1"
    [[ -z "$output" ]] && return 0

    local test_names=()

    # Jest: "✕ login should validate credentials" or "FAIL  src/auth.test.js"
    local jest_tests
    jest_tests=$(echo "$output" | grep -iE '(✕|✗|FAIL\s+).*\.(test|spec)\.(js|ts|tsx)' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -20)
    if [[ -n "$jest_tests" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && test_names+=("$line")
        done < <(echo "$jest_tests")
    fi

    # Pytest: "FAILED tests/test_auth.py::test_login"
    local pytest_tests
    pytest_tests=$(echo "$output" | grep -iE 'FAILED.*\.py::test_' | sed 's/^FAILED[[:space:]]*//' | sed 's/[[:space:]]*$//' | head -20)
    if [[ -n "$pytest_tests" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && test_names+=("$line")
        done < <(echo "$pytest_tests")
    fi

    # Go test: "--- FAIL: TestLogin"
    local go_tests
    go_tests=$(echo "$output" | grep -E '(FAIL|---\s+FAIL).*Test[A-Za-z0-9_]+' | sed 's/^[^T]*Test/Test/' | sed 's/[[:space:]]*$//' | head -20)
    if [[ -n "$go_tests" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && test_names+=("$line")
        done < <(echo "$go_tests")
    fi

    # Vitest: "FAIL  src/auth.test.ts > login > validates credentials"
    local vitest_tests
    vitest_tests=$(echo "$output" | grep -E 'FAIL\s+.*test\.(ts|tsx|js).*>' | sed 's/^FAIL[[:space:]]*//' | sed 's/[[:space:]]*$//' | head -20)
    if [[ -n "$vitest_tests" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && test_names+=("$line")
        done < <(echo "$vitest_tests")
    fi

    # Generic fallback: any line with "FAIL:" or "✗"
    if [[ ${#test_names[@]} -eq 0 ]]; then
        local generic_tests
        generic_tests=$(echo "$output" | grep -iE '(FAIL:|✗|✕)' | sed 's/^[[:space:]]*[✗✕]*[[:space:]]*//' | sed 's/[[:space:]]*$//' | grep -v '^$' | head -20)
        if [[ -n "$generic_tests" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && test_names+=("$line")
            done < <(echo "$generic_tests")
        fi
    fi

    # Output unique tests (max 20)
    local -a unique_tests=()
    for test in "${test_names[@]}"; do
        # Avoid duplicates
        grep -Fxq "$test" <<< "$(printf '%s\n' "${unique_tests[@]}")" 2>/dev/null || unique_tests+=("$test")
    done

    printf '%s\n' "${unique_tests[@]:0:20}"
}

# Function 2: tft_record_iteration(iteration, test_output)
# Record failed tests from this iteration
tft_record_iteration() {
    local iteration="$1"
    local test_output="$2"

    [[ -z "$TFT_STATE_FILE" ]] && TFT_STATE_FILE="${LOG_DIR:-/tmp}/test-failure-tracking.json"

    local failed_tests
    failed_tests=$(tft_extract_test_names "$test_output")

    # Load existing state or initialize
    local state_json="{\"version\":1,\"failed_tests\":{},\"last_iteration\":0}"
    if [[ -f "$TFT_STATE_FILE" ]]; then
        state_json=$(jq . "$TFT_STATE_FILE" 2>/dev/null || echo "{\"version\":1,\"failed_tests\":{},\"last_iteration\":0}")
    fi

    # Update failed_tests object
    # For each failed test: append iteration to history
    # For passed tests (not in current failures): they don't get added/cleared

    # [Implementation continues...]
    echo "$state_json" | jq --arg iter "$iteration" --argjson ts "$(date -u +%s)" \
        '.last_iteration = ($iter | tonumber) | .last_updated = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
        > "$TFT_STATE_FILE.tmp.$$"

    mv "$TFT_STATE_FILE.tmp.$$" "$TFT_STATE_FILE" 2>/dev/null || true
}

# Function 3: tft_check_repeated_failures(threshold)
# Return 0 if any test has threshold+ consecutive failures ending at current iteration
# Sets TFT_ABORT_REASON and TFT_REPEATED_TESTS
tft_check_repeated_failures() {
    local threshold="${1:-3}"
    TFT_ABORT_REASON=""
    TFT_REPEATED_TESTS=""

    [[ -z "$TFT_STATE_FILE" ]] && TFT_STATE_FILE="${LOG_DIR:-/tmp}/test-failure-tracking.json"
    [[ ! -f "$TFT_STATE_FILE" ]] && return 1

    local current_iter
    current_iter=$(jq -r '.last_iteration // 0' "$TFT_STATE_FILE" 2>/dev/null || echo "0")

    # Check each failed test
    local repeated_count=0
    local repeated_names=()

    jq -r '.failed_tests | to_entries[] | "\(.key)|\(.value.iterations | join(","))"' "$TFT_STATE_FILE" 2>/dev/null | while IFS='|' read -r test_name iterations_str; do
        # Parse iterations array
        # Check if last $threshold items are consecutive and end at $current_iter

        # [Implementation continues...]
        repeated_names+=("$test_name")
        repeated_count=$((repeated_count + 1))
    done

    if [[ $repeated_count -gt 0 ]]; then
        TFT_ABORT_REASON="$repeated_count test(s) failed in 3+ consecutive iterations"
        TFT_REPEATED_TESTS="$(printf '%s,' "${repeated_names[@]}" | sed 's/,$//')"
        return 0
    fi

    return 1
}

# Function 4: tft_compose_context_section()
# Generate markdown section for prompt injection
tft_compose_context_section() {
    [[ -z "$TFT_STATE_FILE" ]] && TFT_STATE_FILE="${LOG_DIR:-/tmp}/test-failure-tracking.json"
    [[ ! -f "$TFT_STATE_FILE" ]] && return 0

    # Extract top 5 most-failed tests
    # Format: "- test_name (iterations X, Y, Z) ⚠️ X consecutive"

    echo "## Previously Failed Tests"
    echo "These tests have failed in recent iterations — focus fixes here:"
    jq -r '.failed_tests | to_entries | sort_by(.value.iterations | length) | reverse | .[0:5] | .[] | "- \(.key) (iterations: \(.value.iterations | join(", ")))"' "$TFT_STATE_FILE" 2>/dev/null || true
}

# Function 5: tft_reset()
# Clear tracking state (called on session restart)
tft_reset() {
    [[ -z "$TFT_STATE_FILE" ]] && TFT_STATE_FILE="${LOG_DIR:-/tmp}/test-failure-tracking.json"
    rm -f "$TFT_STATE_FILE" 2>/dev/null || true
}
```

---

### Step 2: Create test suite `scripts/sw-loop-test-failure-tracker-test.sh`

[20+ test cases covering parsers, state management, abort logic, edge cases]

---

### Step 3: Integrate into `sw-loop.sh`

Three integration points (as described in Tasks 4-7)

---

### Step 4: Integrate into `lib/loop-iteration.sh`

Inject context section in `compose_prompt()` (Task 8)

---

## Testing Approach

### Test Pyramid
- **Parser tests** (6): Jest, Pytest, Go, Vitest, generic, empty
- **State tests** (4): CRUD, JSON corruption
- **Abort logic tests** (3): Exact threshold, below, above
- **Edge case tests** (7): Non-consecutive, grace period, >20 tests, special chars, etc.

### Coverage Targets
- 100% of `tft_extract_test_names()` branches
- 100% of abort detection logic (threshold boundary, grace period)
- 100% of state management (create, read, update, reset)

### Critical Paths
1. **Happy**: Test fails → names extracted → tracked → 3 consecutive → abort
2. **Error**: No parseable names → graceful no-op, loop continues
3. **Recovery**: Corrupted JSON → reset to empty, warn, continue

---

## Glossary

| Term | Definition |
|------|-----------|
| **Consecutive failures** | A test appears in the iteration history with no gaps up to the current iteration (e.g., iterations [3,4,5] are consecutive, [3,5,7] are not) |
| **Grace period** | First 2 iterations (iterations 1-2) never trigger abort, even if tests fail |
| **Repeated failure** | A test meets the threshold (default 3) of consecutive iterations |
| **State file** | `$LOG_DIR/test-failure-tracking.json` — atomic storage of failed test names + iteration history |

---

## Summary

**Total Implementation Effort**: ~5-6 hours across 10 concrete tasks

**Key Dependencies**:
- Task 1 → Tasks 2, 3
- Task 2 → Tasks 4, 8
- Task 3 → Task 9
- Task 4 → Tasks 5, 6, 7, 8
- Tasks 5, 6, 7 → Task 9
- Task 8 → Task 9

**Non-Blocking Parallel Work**:
- Task 3 (test suite) can be written in parallel with Tasks 4-8 (integration) once Task 2 is done

**Success Criteria**: ✅ All acceptance criteria in Definition of Done met, ✅ npm test passes, ✅ No regressions
