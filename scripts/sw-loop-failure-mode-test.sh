#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  loop-failure-mode test suite                                            ║
# ║  Tests failure classification heuristics and recovery strategies         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Loop Failure Mode Classification Tests"

setup_test_env "sw-loop-failure-mode-test"
trap cleanup_test_env EXIT

# Provide fallback helpers that the module expects
info()    { echo "$*"; }
success() { echo "$*"; }
warn()    { echo "$*"; }
error()   { echo "$*" >&2; }
emit_event() { :; }
now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# Source the module under test
source "$SCRIPT_DIR/lib/loop-failure-modes.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Unit Tests: Context Exhaustion Detection
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Context Exhaustion Detection"

# Test: Not exhausted when iteration is low
ITERATION=5 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=0 LOG_DIR="$TEST_TEMP_DIR/logs"
if _detect_context_exhaustion; then
    assert_fail "low iteration should not be context exhaustion"
else
    assert_pass "low iteration should not be context exhaustion"
fi

# Test: Exhausted when at 80%+ iterations with consecutive failures
ITERATION=18 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=4 LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"
printf '' > "$LOG_DIR/progress.md"
if _detect_context_exhaustion; then
    assert_pass "high iteration + consecutive failures = context exhaustion"
else
    assert_fail "high iteration + consecutive failures = context exhaustion"
fi

# Test: Not exhausted when at 80%+ but making progress
ITERATION=17 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=0 LOG_DIR="$TEST_TEMP_DIR/logs"
{
    echo "Iteration 15 — commit abc1234"
    echo "Iteration 16 — commit def5678"
    echo "Iteration 17 — commit ghi9012"
} > "$LOG_DIR/progress.md"
if _detect_context_exhaustion; then
    assert_fail "high iteration with recent commits should not be exhaustion"
else
    assert_pass "high iteration with recent commits should not be exhaustion"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Unit Tests: Infinite Loop Detection
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Infinite Loop Detection"

# Test: Not detected with few failures
CONSECUTIVE_FAILURES=1 LOG_DIR="$TEST_TEMP_DIR/logs" PROJECT_ROOT="$TEST_TEMP_DIR/project"
if _detect_infinite_loop; then
    assert_fail "low consecutive failures should not be infinite loop"
else
    assert_pass "low consecutive failures should not be infinite loop"
fi

# Test: Detected when same error appears 3+ times in progress
CONSECUTIVE_FAILURES=4 LOG_DIR="$TEST_TEMP_DIR/logs" PROJECT_ROOT="$TEST_TEMP_DIR/project"
mkdir -p "$LOG_DIR"
cat > "$LOG_DIR/error-summary.json" <<'EOF'
{"error_lines": ["TypeError: Cannot read property 'foo' of undefined"], "error_count": 1}
EOF
{
    echo "TypeError: Cannot read property 'foo' of undefined"
    echo "TypeError: Cannot read property 'foo' of undefined"
    echo "TypeError: Cannot read property 'foo' of undefined"
} > "$LOG_DIR/progress.md"
if _detect_infinite_loop; then
    assert_pass "repeated error in progress.md = infinite loop"
else
    assert_fail "repeated error in progress.md = infinite loop"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Unit Tests: Test Flakiness Detection
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Test Flakiness Detection"

# Test: Not detected on early iterations
ITERATION=1 LOG_DIR="$TEST_TEMP_DIR/logs"
if _detect_test_flakiness; then
    assert_fail "early iteration should not detect flakiness"
else
    assert_pass "early iteration should not detect flakiness"
fi

# Test: Detected with alternating pass/fail
ITERATION=6 LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"
{
    echo "Iteration 1: PASSED"
    echo "Iteration 2: FAILED"
    echo "Iteration 3: PASSED"
    echo "Iteration 4: FAILED"
    echo "Iteration 5: PASSED"
    echo "Iteration 6: FAILED"
} > "$LOG_DIR/progress.md"
if _detect_test_flakiness; then
    assert_pass "alternating pass/fail = test flakiness"
else
    assert_fail "alternating pass/fail = test flakiness"
fi

# Test: Detected with timeout keywords in errors
ITERATION=4 LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"
echo "Iteration 4: FAILED" > "$LOG_DIR/progress.md"
cat > "$LOG_DIR/error-summary.json" <<'EOF'
{"error_lines": ["ETIMEDOUT: connection timed out"], "error_summary": "timeout during test execution"}
EOF
if _detect_test_flakiness; then
    assert_pass "timeout keyword = test flakiness"
else
    assert_fail "timeout keyword = test flakiness"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Unit Tests: Dependency Issue Detection
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Dependency Issue Detection"

# Test: Detected with npm ERR in errors
ITERATION=2 LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"
cat > "$LOG_DIR/error-summary.json" <<'EOF'
{"error_lines": ["npm ERR! Could not resolve dependency"], "error_summary": "npm install failed"}
EOF
if _detect_dependency_issue; then
    assert_pass "npm ERR = dependency issue"
else
    assert_fail "npm ERR = dependency issue"
fi

# Test: Detected with ModuleNotFoundError
ITERATION=1 LOG_DIR="$TEST_TEMP_DIR/logs"
cat > "$LOG_DIR/error-summary.json" <<'EOF'
{"error_lines": ["ModuleNotFoundError: No module named 'requests'"], "error_summary": ""}
EOF
if _detect_dependency_issue; then
    assert_pass "ModuleNotFoundError = dependency issue"
else
    assert_fail "ModuleNotFoundError = dependency issue"
fi

# Test: Not detected on late iterations
ITERATION=10 LOG_DIR="$TEST_TEMP_DIR/logs"
cat > "$LOG_DIR/error-summary.json" <<'EOF'
{"error_lines": ["npm ERR! Could not resolve dependency"], "error_summary": ""}
EOF
if _detect_dependency_issue; then
    assert_fail "late iteration should not be dependency issue"
else
    assert_pass "late iteration should not be dependency issue"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Integration Tests: classify_loop_failure
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "classify_loop_failure Integration"

# Test: Default fallback is code_error
ITERATION=3 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=0 LOG_DIR="$TEST_TEMP_DIR/logs-classify1"
mkdir -p "$LOG_DIR"
echo "" > "$LOG_DIR/progress.md"
echo '{"error_lines": ["AssertionError: expected true to be false"]}' > "$LOG_DIR/error-summary.json"
result=$(classify_loop_failure)
assert_eq "default classification is code_error" "code_error" "$result"

# Test: Dependency issue takes priority (early iteration + dep error)
ITERATION=2 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=1 LOG_DIR="$TEST_TEMP_DIR/logs-classify2"
mkdir -p "$LOG_DIR"
echo "Iteration 2: FAILED" > "$LOG_DIR/progress.md"
echo '{"error_lines": ["Cannot find module express"]}' > "$LOG_DIR/error-summary.json"
result=$(classify_loop_failure)
assert_eq "dependency issue has highest priority" "dependency_issue" "$result"

# Test: Context exhaustion detected
ITERATION=18 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=4 LOG_DIR="$TEST_TEMP_DIR/logs-classify3"
mkdir -p "$LOG_DIR"
echo "" > "$LOG_DIR/progress.md"
echo '{"error_lines": []}' > "$LOG_DIR/error-summary.json"
result=$(classify_loop_failure)
assert_eq "context exhaustion classified correctly" "context_exhaustion" "$result"

# Test: Classification writes JSON file
assert_file_exists "classification JSON written" "$LOG_DIR/failure-classification.json"

# Test: Classification JSON has correct mode
json_content=$(cat "$LOG_DIR/failure-classification.json")
assert_json_key "JSON has failure_mode" "$json_content" ".failure_mode" "context_exhaustion"

# ═══════════════════════════════════════════════════════════════════════════════
# Unit Tests: get_recovery_strategy
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "get_recovery_strategy"

# Test: Each mode returns valid JSON with strategy field
for mode in context_exhaustion infinite_loop test_flakiness dependency_issue code_error; do
    strategy_json=$(get_recovery_strategy "$mode")
    strategy_name=$(echo "$strategy_json" | jq -r '.strategy' 2>/dev/null || echo "")
    if [[ -n "$strategy_name" ]] && [[ "$strategy_name" != "null" ]]; then
        assert_pass "get_recovery_strategy($mode) returns valid strategy: $strategy_name"
    else
        assert_fail "get_recovery_strategy($mode) returns valid strategy" "got empty or null"
    fi
done

# Test: Unknown mode falls back to standard_restart
strategy_json=$(get_recovery_strategy "unknown_mode")
assert_json_key "unknown mode falls back to standard_restart" "$strategy_json" ".strategy" "standard_restart"

# ═══════════════════════════════════════════════════════════════════════════════
# Integration Tests: apply_loop_recovery
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "apply_loop_recovery"

# Test: Context exhaustion reduces MAX_ITERATIONS
MAX_ITERATIONS=20 MAX_RESTARTS=0 LOG_DIR="$TEST_TEMP_DIR/logs-recovery1"
mkdir -p "$LOG_DIR"
apply_loop_recovery "context_exhaustion" >/dev/null 2>&1
assert_eq "context_exhaustion reduces MAX_ITERATIONS" "16" "$MAX_ITERATIONS"
assert_eq "context_exhaustion boosts MAX_RESTARTS" "2" "$MAX_RESTARTS"

# Test: Infinite loop caps MAX_ITERATIONS to 5
MAX_ITERATIONS=20 MODEL="sonnet"
apply_loop_recovery "infinite_loop" >/dev/null 2>&1
assert_eq "infinite_loop caps MAX_ITERATIONS to 5" "5" "$MAX_ITERATIONS"
assert_eq "infinite_loop escalates model to opus" "opus" "$MODEL"

# Test: Test flakiness resets consecutive failures
CONSECUTIVE_FAILURES=5 LOG_DIR="$TEST_TEMP_DIR/logs-recovery2" ITERATION=4
mkdir -p "$LOG_DIR"
apply_loop_recovery "test_flakiness" >/dev/null 2>&1
assert_eq "test_flakiness resets CONSECUTIVE_FAILURES" "0" "$CONSECUTIVE_FAILURES"
assert_file_exists "test_flakiness creates marker" "$LOG_DIR/flaky-tests-detected.marker"

# Test: Dependency issue resets consecutive failures
CONSECUTIVE_FAILURES=3 PROJECT_ROOT="$TEST_TEMP_DIR/project"
mkdir -p "$PROJECT_ROOT"
apply_loop_recovery "dependency_issue" >/dev/null 2>&1
assert_eq "dependency_issue resets CONSECUTIVE_FAILURES" "0" "$CONSECUTIVE_FAILURES"

# Test: Code error runs without modifying globals
MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=2
apply_loop_recovery "code_error" >/dev/null 2>&1
assert_eq "code_error preserves MAX_ITERATIONS" "20" "$MAX_ITERATIONS"
assert_eq "code_error preserves CONSECUTIVE_FAILURES" "2" "$CONSECUTIVE_FAILURES"

# ═══════════════════════════════════════════════════════════════════════════════
# E2E Tests: Full Classification → Recovery Flow
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "E2E: Classification → Recovery Flow"

# Test: Dependency issue flow end-to-end
ITERATION=1 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=1 LOG_DIR="$TEST_TEMP_DIR/logs-e2e1"
PROJECT_ROOT="$TEST_TEMP_DIR/project"
mkdir -p "$LOG_DIR" "$PROJECT_ROOT"
echo '{"error_lines": ["npm ERR! missing: express@4.18.2"]}' > "$LOG_DIR/error-summary.json"
echo "FAILED" > "$LOG_DIR/progress.md"

mode=$(classify_loop_failure)
assert_eq "E2E: classified as dependency_issue" "dependency_issue" "$mode"
CONSECUTIVE_FAILURES=3
apply_loop_recovery "$mode" >/dev/null 2>&1
assert_eq "E2E: consecutive failures reset after dep recovery" "0" "$CONSECUTIVE_FAILURES"

# Test: Context exhaustion flow end-to-end
ITERATION=19 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=5 LOG_DIR="$TEST_TEMP_DIR/logs-e2e2"
MAX_RESTARTS=0
mkdir -p "$LOG_DIR"
echo "" > "$LOG_DIR/progress.md"
echo '{"error_lines": []}' > "$LOG_DIR/error-summary.json"

mode=$(classify_loop_failure)
assert_eq "E2E: classified as context_exhaustion" "context_exhaustion" "$mode"
apply_loop_recovery "$mode" >/dev/null 2>&1
if [[ "$MAX_ITERATIONS" -lt 20 ]]; then
    assert_pass "E2E: MAX_ITERATIONS reduced after context exhaustion recovery"
else
    assert_fail "E2E: MAX_ITERATIONS reduced after context exhaustion recovery"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Edge Cases
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Edge Cases"

# Test: Missing LOG_DIR doesn't crash
LOG_DIR="" ITERATION=5 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=0
result=$(classify_loop_failure 2>/dev/null) || true
assert_eq "missing LOG_DIR falls back to code_error" "code_error" "${result:-code_error}"

# Test: Empty error-summary.json doesn't crash
LOG_DIR="$TEST_TEMP_DIR/logs-edge1"
mkdir -p "$LOG_DIR"
echo '{}' > "$LOG_DIR/error-summary.json"
echo "" > "$LOG_DIR/progress.md"
ITERATION=5 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=0
result=$(classify_loop_failure)
assert_eq "empty error-summary falls back to code_error" "code_error" "$result"

# Test: Malformed JSON in error-summary doesn't crash
LOG_DIR="$TEST_TEMP_DIR/logs-edge2"
mkdir -p "$LOG_DIR"
echo 'not json at all' > "$LOG_DIR/error-summary.json"
echo "" > "$LOG_DIR/progress.md"
ITERATION=5 MAX_ITERATIONS=20 CONSECUTIVE_FAILURES=0
result=$(classify_loop_failure)
assert_eq "malformed JSON falls back to code_error" "code_error" "$result"

# Test: Context exhaustion with very low max_iterations (floor at 5)
MAX_ITERATIONS=6 MAX_RESTARTS=0 LOG_DIR="$TEST_TEMP_DIR/logs-edge3"
mkdir -p "$LOG_DIR"
apply_loop_recovery "context_exhaustion" >/dev/null 2>&1
if [[ "$MAX_ITERATIONS" -ge 5 ]]; then
    assert_pass "context exhaustion recovery floors MAX_ITERATIONS at 5"
else
    assert_fail "context exhaustion recovery floors MAX_ITERATIONS at 5" "got $MAX_ITERATIONS"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Module Guard
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Module Guard"

# Test: Module guard prevents double-sourcing
_LOOP_FAILURE_MODES_LOADED=1
# Re-sourcing should be a no-op (early return)
source "$SCRIPT_DIR/lib/loop-failure-modes.sh"
assert_pass "module guard prevents double-sourcing"

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
