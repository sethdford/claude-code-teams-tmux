#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Unit tests for lib/loop-display.sh                                      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "loop-display-test"

# ─── Stubs ───────────────────────────────────────────────────────────────────
now_epoch() { date +%s; }
format_duration() { echo "${1}s"; }
write_loop_tokens() { :; }

# Colors
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
PURPLE='\033[38;2;124;58;237m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# Globals
VERSION="3.2.4"
GOAL="Build the thing"
MODEL="opus"
MAX_ITERATIONS=20
TEST_CMD="npm test"
AGENTS=1
SKIP_PERMISSIONS=false
AUDIT_ENABLED=false
AUDIT_AGENT_ENABLED=false
QUALITY_GATES_ENABLED=false
DOD_FILE=""
AUTO_EXTEND=true
EXTENSION_SIZE=5
MAX_EXTENSIONS=3
CIRCUIT_BREAKER_THRESHOLD=3
MIN_PROGRESS_LINES=5
STATUS="running"
ITERATION=5
TEST_PASSED="true"
LOOP_INPUT_TOKENS=1000
LOOP_OUTPUT_TOKENS=500
TOTAL_COMMITS=3
EXTENSION_COUNT=0
START_EPOCH=$(date +%s)
STATE_FILE="/tmp/test-state.md"
LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"

source "$SCRIPT_DIR/lib/loop-display.sh"

print_test_header "Loop Display Module Tests"

# ─── Module Guard ────────────────────────────────────────────────────────────
print_test_section "Module Guard"

if [[ "${_LOOP_DISPLAY_SH_LOADED:-}" == "1" ]]; then
    assert_pass "Module guard variable set"
else
    assert_fail "Module guard variable set"
fi

# ─── show_help ───────────────────────────────────────────────────────────────
print_test_section "show_help"

output=$(show_help 2>&1 | sed $'s/\033\[[0-9;]*m//g')
assert_contains "Help shows USAGE" "$output" "USAGE"
assert_contains "Help shows OPTIONS" "$output" "OPTIONS"
assert_contains "Help shows --max-iterations" "$output" "--max-iterations"
assert_contains "Help shows --test-cmd" "$output" "--test-cmd"
assert_contains "Help shows --model" "$output" "--model"
assert_contains "Help shows --agents" "$output" "--agents"
assert_contains "Help shows --resume" "$output" "--resume"
assert_contains "Help shows --effort" "$output" "--effort"
assert_contains "Help shows --audit" "$output" "--audit"
assert_contains "Help shows EXAMPLES" "$output" "EXAMPLES"

# ─── show_banner ─────────────────────────────────────────────────────────────
print_test_section "show_banner"

output=$(show_banner 2>&1 | sed $'s/\033\[[0-9;]*m//g')
assert_contains "Banner shows goal" "$output" "Build the thing"
assert_contains "Banner shows model" "$output" "opus"
assert_contains "Banner shows version" "$output" "3.2.4"

# ─── show_summary ────────────────────────────────────────────────────────────
print_test_section "show_summary"

STATUS="complete"
output=$(show_summary 2>&1 | sed $'s/\033\[[0-9;]*m//g')
assert_contains "Summary shows goal" "$output" "Build the thing"
assert_contains "Summary shows status" "$output" "COMPLETE"
assert_contains "Summary shows iterations" "$output" "5/20"
assert_contains "Summary shows commits" "$output" "3"

print_test_results
