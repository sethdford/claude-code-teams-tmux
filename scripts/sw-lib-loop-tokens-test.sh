#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Unit tests for lib/loop-tokens.sh                                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "loop-tokens-test"

# ─── Source module under test ────────────────────────────────────────────────
# Provide fallback stubs for functions the module depends on
info()    { echo "INFO: $*"; }
success() { echo "OK: $*"; }
warn()    { echo "WARN: $*"; }
error()   { echo "ERR: $*" >&2; }
emit_event() { :; }
_config_get_int() { echo "${2:-0}"; }
intelligence_recommend_model() { echo ""; }
intelligence_estimate_iterations() { echo ""; }

# Globals the module uses
LOOP_INPUT_TOKENS=0
LOOP_OUTPUT_TOKENS=0
LOOP_COST_MILLICENTS=0
MODEL="sonnet"
SW_MODEL="opus"
MAX_ITERATIONS=20
MAX_ITERATIONS_EXPLICIT=false
EXTENSION_SIZE=5
MAX_EXTENSIONS=3
CIRCUIT_BREAKER_THRESHOLD=3
ITERATION=1
LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"

source "$SCRIPT_DIR/lib/loop-tokens.sh"

print_test_header "Loop Tokens Module Tests"

# ─── Module Guard ────────────────────────────────────────────────────────────
print_test_section "Module Guard"

if [[ "${_LOOP_TOKENS_SH_LOADED:-}" == "1" ]]; then
    assert_pass "Module guard variable set"
else
    assert_fail "Module guard variable set"
fi

# ─── format_duration ─────────────────────────────────────────────────────────
print_test_section "format_duration"

result=$(format_duration 0)
assert_eq "0 seconds" "0s" "$result"

result=$(format_duration 45)
assert_eq "45 seconds" "45s" "$result"

result=$(format_duration 90)
assert_eq "1m 30s" "1m 30s" "$result"

result=$(format_duration 3661)
assert_eq "61m 1s" "61m 1s" "$result"

# ─── select_audit_model ──────────────────────────────────────────────────────
print_test_section "select_audit_model"

result=$(select_audit_model)
assert_eq "Default audit model is haiku" "haiku" "$result"

# With high success rate, still haiku
mkdir -p "$HOME/.shipwright/optimization"
echo '{"haiku_success_rate": 95}' > "$HOME/.shipwright/optimization/audit-tuning.json"
result=$(select_audit_model)
assert_eq "High success rate returns haiku" "haiku" "$result"

# With low success rate, use sonnet
echo '{"haiku_success_rate": 80}' > "$HOME/.shipwright/optimization/audit-tuning.json"
result=$(select_audit_model)
assert_eq "Low success rate returns sonnet" "sonnet" "$result"

# ─── _extract_text_from_json ─────────────────────────────────────────────────
print_test_section "_extract_text_from_json"

# Empty file
touch "$TEST_TEMP_DIR/empty.json"
_extract_text_from_json "$TEST_TEMP_DIR/empty.json" "$TEST_TEMP_DIR/out1.log" ""
assert_contains "Empty file produces fallback" "$(cat "$TEST_TEMP_DIR/out1.log")" "no output"

# Valid JSON array
echo '[{"type":"result","result":"Hello world","usage":{"input_tokens":100}}]' > "$TEST_TEMP_DIR/valid.json"
_extract_text_from_json "$TEST_TEMP_DIR/valid.json" "$TEST_TEMP_DIR/out2.log" ""
assert_contains "Extracts .result from JSON" "$(cat "$TEST_TEMP_DIR/out2.log")" "Hello world"

# Plain text passthrough
echo "Plain text output" > "$TEST_TEMP_DIR/text.json"
_extract_text_from_json "$TEST_TEMP_DIR/text.json" "$TEST_TEMP_DIR/out3.log" ""
assert_contains "Plain text passes through" "$(cat "$TEST_TEMP_DIR/out3.log")" "Plain text"

# ─── accumulate_loop_tokens ──────────────────────────────────────────────────
print_test_section "accumulate_loop_tokens"

LOOP_INPUT_TOKENS=0
LOOP_OUTPUT_TOKENS=0
echo '[{"type":"result","result":"test","usage":{"input_tokens":500,"output_tokens":200,"cache_read_input_tokens":100,"cache_creation_input_tokens":50},"total_cost_usd":0.05}]' \
    > "$TEST_TEMP_DIR/tokens.json"
accumulate_loop_tokens "$TEST_TEMP_DIR/tokens.json"
assert_gt "Input tokens accumulated" "$LOOP_INPUT_TOKENS" 0
assert_gt "Output tokens accumulated" "$LOOP_OUTPUT_TOKENS" 0

# ─── write_loop_tokens ──────────────────────────────────────────────────────
print_test_section "write_loop_tokens"

LOOP_INPUT_TOKENS=1000
LOOP_OUTPUT_TOKENS=500
LOOP_COST_MILLICENTS=5000
ITERATION=3
write_loop_tokens
assert_file_exists "Token file created" "$LOG_DIR/loop-tokens.json"
if command -v jq >/dev/null 2>&1; then
    in_tok=$(jq -r '.input_tokens' "$LOG_DIR/loop-tokens.json")
    assert_eq "Input tokens in JSON" "1000" "$in_tok"
    out_tok=$(jq -r '.output_tokens' "$LOG_DIR/loop-tokens.json")
    assert_eq "Output tokens in JSON" "500" "$out_tok"
fi

# ─── check_budget_gate ───────────────────────────────────────────────────────
print_test_section "check_budget_gate"

# No sw-cost.sh available — should pass
SCRIPT_DIR_SAVE="$SCRIPT_DIR"
SCRIPT_DIR="$TEST_TEMP_DIR"
result=0
check_budget_gate || result=$?
assert_eq "No cost script passes" "0" "$result"
SCRIPT_DIR="$SCRIPT_DIR_SAVE"

print_test_results
