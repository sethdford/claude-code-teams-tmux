#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-abtest-test.sh — A/B testing framework test suite                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
BOLD='\033[1m'
RESET='\033[0m'

# Isolated workspace
TEST_DIR=$(mktemp -d -t sw-abtest-XXXXXX)
export AB_BASE_DIR="$TEST_DIR/abtest"
trap 'rm -rf "$TEST_DIR"' EXIT

pass() { PASS=$((PASS+1)); echo -e "  ${GREEN}${BOLD}✓${RESET} $1"; }
fail() { FAIL=$((FAIL+1)); echo -e "  ${RED}${BOLD}✗${RESET} $1"; [[ -n "${2:-}" ]] && echo "    $2"; }

assert_equals() {
    local expected="$1" actual="$2" desc="$3"
    if [[ "$expected" == "$actual" ]]; then pass "$desc"
    else fail "$desc" "expected='$expected' actual='$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"
    else fail "$desc" "missing substring '$needle' in '$haystack'"
    fi
}

assert_nonzero_exit() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then fail "$desc" "expected non-zero exit"
    else pass "$desc"
    fi
}

# Source the library directly for unit tests
# shellcheck source=lib/helpers.sh
source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=lib/ab-test.sh
source "$SCRIPT_DIR/lib/ab-test.sh"

echo "sw-abtest-test.sh"

# ─── Library: assignment & validation ──────────────────────────────
test_assign_returns_valid_group() {
    local g
    g=$(ab_assign "test-exp" "0.5")
    if [[ "$g" == "control" || "$g" == "treatment" ]]; then
        pass "ab_assign returns control or treatment"
    else
        fail "ab_assign returns control or treatment" "got '$g'"
    fi
}

test_assign_always_control_when_ratio_1() {
    local g
    g=$(ab_assign "test-exp" "1.0")
    assert_equals "control" "$g" "ratio=1.0 always returns control"
}

test_assign_always_treatment_when_ratio_0() {
    local g
    g=$(ab_assign "test-exp" "0")
    assert_equals "treatment" "$g" "ratio=0 always returns treatment"
}

test_assign_invalid_experiment_name_fails() {
    assert_nonzero_exit "ab_assign rejects empty experiment name" ab_assign "" "0.5"
    assert_nonzero_exit "ab_assign rejects names with slashes" ab_assign "bad/name" "0.5"
}

test_results_file_path() {
    local p
    p=$(ab_results_file "myexp")
    assert_equals "$AB_BASE_DIR/myexp.jsonl" "$p" "ab_results_file returns expected path"
}

# ─── Library: result recording ──────────────────────────────────────
test_record_result_creates_file() {
    ab_record_result "exp1" "pipe-1" "control" 3 100 0 success
    local f="$AB_BASE_DIR/exp1.jsonl"
    if [[ -f "$f" ]]; then pass "ab_record_result creates JSONL file"
    else fail "ab_record_result creates JSONL file" "$f missing"
    fi
}

test_record_result_writes_valid_json() {
    ab_record_result "exp1" "pipe-2" "treatment" 5 200 1 success
    local line
    line=$(tail -1 "$AB_BASE_DIR/exp1.jsonl")
    if echo "$line" | jq -e . >/dev/null 2>&1; then pass "result line is valid JSON"
    else fail "result line is valid JSON" "$line"
    fi
    local grp
    grp=$(echo "$line" | jq -r '.group')
    assert_equals "treatment" "$grp" "recorded group field correct"
}

test_record_result_requires_args() {
    assert_nonzero_exit "ab_record_result fails on missing args" ab_record_result "exp1" "" ""
}

# ─── Library: aggregation & status ─────────────────────────────────
test_aggregate_counts() {
    # exp1 now has 1 control + 1 treatment from prior tests
    local agg
    agg=$(ab_aggregate "exp1" "control")
    local c
    c=$(echo "$agg" | jq -r '.count')
    assert_equals "1" "$c" "ab_aggregate counts control rows"
    agg=$(ab_aggregate "exp1" "treatment")
    c=$(echo "$agg" | jq -r '.count')
    assert_equals "1" "$c" "ab_aggregate counts treatment rows"
}

test_status_json() {
    local s
    s=$(ab_status "exp1")
    if echo "$s" | jq -e . >/dev/null 2>&1; then pass "ab_status emits valid JSON"
    else fail "ab_status emits valid JSON" "$s"
    fi
    local cc
    cc=$(echo "$s" | jq -r '.control_count')
    assert_equals "1" "$cc" "ab_status control_count correct"
}

test_list_experiments() {
    ab_record_result "exp2" "p" "control" 1 1 0 success
    local out
    out=$(ab_list | sort | tr '\n' ' ')
    assert_contains "$out" "exp1" "ab_list includes exp1"
    assert_contains "$out" "exp2" "ab_list includes exp2"
}

# ─── Library: report ───────────────────────────────────────────────
test_report_produces_output() {
    # Add a few more records for a meaningful report
    ab_record_result "rep" "p1" "control" 5 500 1 success
    ab_record_result "rep" "p2" "control" 6 600 1 failure
    ab_record_result "rep" "p3" "treatment" 3 300 0 success
    ab_record_result "rep" "p4" "treatment" 4 400 0 success
    local out
    out=$(ab_report "rep" 2>/dev/null)
    assert_contains "$out" "experiment: rep" "report shows experiment name"
    assert_contains "$out" "Sample Sizes" "report shows sample sizes"
    assert_contains "$out" "Avg Iterations" "report shows iteration metric"
}

test_report_missing_experiment_fails() {
    assert_nonzero_exit "report fails on unknown experiment" ab_report "no-such-exp"
}

# ─── CLI wrapper ───────────────────────────────────────────────────
test_cli_help() {
    local out
    out=$("$SCRIPT_DIR/sw-abtest.sh" --help)
    assert_contains "$out" "USAGE" "CLI --help includes USAGE"
    assert_contains "$out" "assign" "CLI --help lists assign"
    assert_contains "$out" "record" "CLI --help lists record"
    assert_contains "$out" "report" "CLI --help lists report"
    assert_contains "$out" "list" "CLI --help lists list"
    assert_contains "$out" "status" "CLI --help lists status"
}

test_cli_version() {
    local out
    out=$("$SCRIPT_DIR/sw-abtest.sh" --version)
    if [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then pass "CLI --version returns semver"
    else fail "CLI --version returns semver" "$out"
    fi
}

test_cli_assign_invocable() {
    local out
    out=$(AB_BASE_DIR="$AB_BASE_DIR" "$SCRIPT_DIR/sw-abtest.sh" assign cli-exp 0.5)
    if [[ "$out" == "control" || "$out" == "treatment" ]]; then
        pass "CLI assign returns valid group"
    else
        fail "CLI assign returns valid group" "got '$out'"
    fi
}

test_cli_record_and_report_roundtrip() {
    AB_BASE_DIR="$AB_BASE_DIR" "$SCRIPT_DIR/sw-abtest.sh" record cli-rt p1 control 3 300 0 success >/dev/null
    AB_BASE_DIR="$AB_BASE_DIR" "$SCRIPT_DIR/sw-abtest.sh" record cli-rt p2 treatment 2 200 0 success >/dev/null
    local out
    out=$(AB_BASE_DIR="$AB_BASE_DIR" "$SCRIPT_DIR/sw-abtest.sh" report cli-rt 2>&1)
    assert_contains "$out" "experiment: cli-rt" "CLI report shows experiment after CLI record"
}

test_cli_unknown_command_fails() {
    assert_nonzero_exit "CLI fails on unknown command" "$SCRIPT_DIR/sw-abtest.sh" unknown-cmd
}

# ─── Concurrency: parallel writes don't truncate ───────────────────
test_concurrent_writes() {
    local exp="concur"
    local pids=() i
    for i in 1 2 3 4 5 6 7 8; do
        ( ab_record_result "$exp" "p-$i" "treatment" "$i" "$((i*10))" 0 success ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    local lines
    lines=$(wc -l < "$AB_BASE_DIR/${exp}.jsonl")
    lines=${lines//[[:space:]]/}
    assert_equals "8" "$lines" "8 concurrent writes produce 8 lines"
    # All lines should be valid JSON
    local invalid=0
    while IFS= read -r line; do
        echo "$line" | jq -e . >/dev/null 2>&1 || invalid=$((invalid+1))
    done < "$AB_BASE_DIR/${exp}.jsonl"
    assert_equals "0" "$invalid" "all concurrent-written lines are valid JSON"
}

# ─── Run ───────────────────────────────────────────────────────────
test_assign_returns_valid_group
test_assign_always_control_when_ratio_1
test_assign_always_treatment_when_ratio_0
test_assign_invalid_experiment_name_fails
test_results_file_path
test_record_result_creates_file
test_record_result_writes_valid_json
test_record_result_requires_args
test_aggregate_counts
test_status_json
test_list_experiments
test_report_produces_output
test_report_missing_experiment_fails
test_cli_help
test_cli_version
test_cli_assign_invocable
test_cli_record_and_report_roundtrip
test_cli_unknown_command_fails
test_concurrent_writes

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
