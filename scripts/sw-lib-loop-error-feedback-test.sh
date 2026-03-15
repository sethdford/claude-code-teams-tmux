#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Unit tests for lib/loop-error-feedback.sh                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "loop-error-feedback-test"

# ─── Stubs ───────────────────────────────────────────────────────────────────
info()    { echo "INFO: $*"; }
success() { echo "OK: $*"; }
warn()    { echo "WARN: $*"; }
error()   { echo "ERR: $*" >&2; }
emit_event() { :; }
audit_emit() { :; }
detect_created_test_files() { :; }
_config_get_int() { echo "${2:-0}"; }

# Globals
LOG_DIR="$TEST_TEMP_DIR/logs"
ITERATION=1
TEST_CMD="npm test"
FAST_TEST_CMD=""
FAST_TEST_INTERVAL=5
MAX_ITERATIONS=20
TEST_PASSED=""
TEST_OUTPUT=""
TEST_LOG_FILE=""
ADDITIONAL_TEST_CMDS=()
LOOP_START_COMMIT=""

mkdir -p "$LOG_DIR"

source "$SCRIPT_DIR/lib/loop-error-feedback.sh"

print_test_header "Loop Error Feedback Module Tests"

# ─── Module Guard ────────────────────────────────────────────────────────────
print_test_section "Module Guard"

if [[ "${_LOOP_ERROR_FEEDBACK_SH_LOADED:-}" == "1" ]]; then
    assert_pass "Module guard variable set"
else
    assert_fail "Module guard variable set"
fi

# ─── diagnose_failure ────────────────────────────────────────────────────────
print_test_section "diagnose_failure"

result=$(diagnose_failure "Error: Cannot find module 'lodash'" "file.js" 1)
assert_contains "Detects missing import" "$result" "missing_import"

result=$(diagnose_failure "SyntaxError: Unexpected token )" "app.ts" 2)
assert_contains "Detects syntax error" "$result" "syntax_error"

result=$(diagnose_failure "TypeError: undefined is not a function" "main.py" 3)
assert_contains "Detects type error" "$result" "type_error"

result=$(diagnose_failure "AssertionError: expected 1 to equal 2" "test.js" 4)
assert_contains "Detects test assertion" "$result" "test_assertion"

result=$(diagnose_failure "some random error message" "file.go" 5)
assert_contains "Unknown error classified" "$result" "unknown"

# Test escalation on repeated diagnoses
echo "test_assertion" >> "$LOG_DIR/diagnoses.txt"
echo "test_assertion" >> "$LOG_DIR/diagnoses.txt"
result=$(diagnose_failure "AssertionError: expected true" "test.js" 6)
assert_contains "Escalates on repeat" "$result" "alternative_approach"

# ─── run_test_gate ───────────────────────────────────────────────────────────
print_test_section "run_test_gate"

# No test command
TEST_CMD=""
ADDITIONAL_TEST_CMDS=()
run_test_gate
assert_eq "No test cmd returns empty passed" "" "${TEST_PASSED}"

# Passing test
TEST_CMD="true"
run_test_gate
assert_eq "Passing test sets TEST_PASSED=true" "true" "${TEST_PASSED}"

# Failing test
TEST_CMD="false"
run_test_gate
assert_eq "Failing test sets TEST_PASSED=false" "false" "${TEST_PASSED}"

# ─── write_error_summary ────────────────────────────────────────────────────
print_test_section "write_error_summary"

# Success case — no error file
TEST_PASSED="true"
echo "All good" > "$LOG_DIR/iteration-${ITERATION}.log"
write_error_summary
assert_file_not_exists "No error file on success" "$LOG_DIR/error-summary.json"

# Failure case — writes error summary
TEST_PASSED="false"
echo "ERROR: something broke" > "$LOG_DIR/tests-iter-${ITERATION}.log"
write_error_summary
assert_file_exists "Error file on failure" "$LOG_DIR/error-summary.json"

print_test_results
