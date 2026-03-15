#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Unit tests for lib/loop-quality.sh                                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "loop-quality-test"

# ─── Stubs ───────────────────────────────────────────────────────────────────
info()    { echo "INFO: $*"; }
success() { echo "OK: $*"; }
warn()    { echo "WARN: $*"; }
error()   { echo "ERR: $*" >&2; }
emit_event() { :; }
select_audit_model() { echo "haiku"; }

# Colors
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
PURPLE='\033[38;2;124;58;237m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# Create a real git repo for quality gate tests
_git=$(command -v git 2>/dev/null)
PROJECT_ROOT="$TEST_TEMP_DIR/repo"
mkdir -p "$PROJECT_ROOT"
(cd "$PROJECT_ROOT" && "$_git" init -q && "$_git" config user.email "t@t" && "$_git" config user.name "T")
echo "init" > "$PROJECT_ROOT/file.txt"
(cd "$PROJECT_ROOT" && "$_git" add . && "$_git" commit -q -m "init")
echo "change" >> "$PROJECT_ROOT/file.txt"
(cd "$PROJECT_ROOT" && "$_git" add . && "$_git" commit -q -m "change")

# Globals
LOG_DIR="$TEST_TEMP_DIR/logs"
ITERATION=1
GOAL="Test goal"
SKIP_PERMISSIONS=true
TEST_CMD="true"
TEST_PASSED="true"
TEST_OUTPUT=""
AUDIT_ENABLED=false
AUDIT_AGENT_ENABLED=false
QUALITY_GATES_ENABLED=false
DOD_FILE=""
AUDIT_RESULT=""
COMPLETION_REJECTED=false
QUALITY_GATE_PASSED=true
LOOP_START_COMMIT=""

mkdir -p "$LOG_DIR"

source "$SCRIPT_DIR/lib/loop-quality.sh"

print_test_header "Loop Quality Module Tests"

# ─── Module Guard ────────────────────────────────────────────────────────────
print_test_section "Module Guard"

if [[ "${_LOOP_QUALITY_SH_LOADED:-}" == "1" ]]; then
    assert_pass "Module guard variable set"
else
    assert_fail "Module guard variable set"
fi

# ─── run_quality_gates ───────────────────────────────────────────────────────
print_test_section "run_quality_gates"

# Disabled quality gates
QUALITY_GATES_ENABLED=false
run_quality_gates
assert_eq "Disabled gates pass" "true" "$QUALITY_GATE_PASSED"

# Enabled gates, tests passing, clean repo
QUALITY_GATES_ENABLED=true
TEST_PASSED="true"
run_quality_gates 2>&1 >/dev/null
assert_eq "All gates pass with clean state" "true" "$QUALITY_GATE_PASSED"

# Tests failing
TEST_PASSED="false"
run_quality_gates 2>&1 >/dev/null
assert_eq "Gate fails when tests fail" "false" "$QUALITY_GATE_PASSED"
TEST_PASSED="true"

# ─── guard_completion ────────────────────────────────────────────────────────
print_test_section "guard_completion"

# No LOOP_COMPLETE in log
echo "still working" > "$LOG_DIR/iteration-${ITERATION}.log"
result=0
guard_completion || result=$?
assert_eq "No LOOP_COMPLETE returns 1" "1" "$result"

# LOOP_COMPLETE with passing gates
echo "LOOP_COMPLETE" > "$LOG_DIR/iteration-${ITERATION}.log"
QUALITY_GATE_PASSED=true
AUDIT_AGENT_ENABLED=false
TEST_PASSED="true"
result=0
guard_completion 2>&1 >/dev/null || result=$?
assert_eq "LOOP_COMPLETE accepted when gates pass" "0" "$result"

# LOOP_COMPLETE with failing tests
echo "LOOP_COMPLETE" > "$LOG_DIR/iteration-${ITERATION}.log"
TEST_PASSED="false"
result=0
guard_completion 2>&1 >/dev/null || result=$?
assert_eq "LOOP_COMPLETE rejected when tests fail" "1" "$result"
assert_eq "COMPLETION_REJECTED set" "true" "$COMPLETION_REJECTED"
TEST_PASSED="true"
COMPLETION_REJECTED=false

# ─── compose_audit_section ───────────────────────────────────────────────────
print_test_section "compose_audit_section"

AUDIT_ENABLED=false
output=$(compose_audit_section 2>&1)
assert_eq "Disabled audit produces no output" "" "$output"

AUDIT_ENABLED=true
output=$(compose_audit_section 2>&1)
assert_contains "Audit section has checklist" "$output" "Self-Audit Checklist"
assert_contains "Audit section mentions LOOP_COMPLETE" "$output" "LOOP_COMPLETE"

# ─── compose_audit_feedback_section ──────────────────────────────────────────
print_test_section "compose_audit_feedback_section"

AUDIT_RESULT=""
output=$(compose_audit_feedback_section 2>&1)
assert_eq "No feedback when no result" "" "$output"

AUDIT_RESULT="pass"
output=$(compose_audit_feedback_section 2>&1)
assert_eq "No feedback when passed" "" "$output"

AUDIT_RESULT="Found issues: missing tests"
output=$(compose_audit_feedback_section 2>&1)
assert_contains "Feedback includes audit result" "$output" "Found issues"

# ─── compose_rejection_notice_section ────────────────────────────────────────
print_test_section "compose_rejection_notice_section"

COMPLETION_REJECTED=false
output=$(compose_rejection_notice_section 2>&1)
assert_eq "No notice when not rejected" "" "$output"

COMPLETION_REJECTED=true
# Call directly (not in subshell) so variable reset propagates
compose_rejection_notice_section > "$TEST_TEMP_DIR/rejection-output.txt" 2>&1
output=$(cat "$TEST_TEMP_DIR/rejection-output.txt")
assert_contains "Notice mentions rejection" "$output" "Completion Rejected"
# compose_rejection_notice_section resets the flag
assert_eq "Flag reset after notice" "false" "$COMPLETION_REJECTED"

print_test_results
