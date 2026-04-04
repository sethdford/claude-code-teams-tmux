#!/usr/bin/env bash
# sw-stage-profiler-test.sh — Test Suite for Stage Duration Profiler
# Tests percentile computation, regression detection, bottleneck analysis,
# budget violations, trends, export, widget, and CLI subcommands.

set -euo pipefail

# ─── Test Harness Setup ──────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

# Mock environment
export HOME="$TEST_DIR"
export PROFILER_HISTORY_FILE="$TEST_DIR/.shipwright/optimization/stage-durations.jsonl"
export PROFILER_DB_FILE="$TEST_DIR/.shipwright/shipwright.db"
export PROFILER_EVENTS_FILE="$TEST_DIR/.shipwright/events.jsonl"

# Helpers
PASS=0
FAIL=0
TEST_NAME=""

info() { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
error() { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
warn() { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
emit_event() { :; }  # Mock

if ! command -v jq >/dev/null 2>&1; then
    error "jq is required but not installed"
    exit 1
fi

# Source the library under test
# shellcheck source=lib/stage-profiler.sh
source "$SCRIPT_DIR/lib/stage-profiler.sh"

# ─── Test Utilities ────────────────────────────────────────────────────────

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Assertion failed}"
    if [[ "$expected" == "$actual" ]]; then
        success "$TEST_NAME: $msg"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: $msg (expected: $expected, got: $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_empty() {
    local actual="$1"
    local msg="${2:-Value should not be empty}"
    if [[ -n "$actual" ]]; then
        success "$TEST_NAME: $msg"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: $msg (got empty)"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_valid() {
    local json="$1"
    local msg="${2:-Valid JSON}"
    if echo "$json" | jq '.' >/dev/null 2>&1; then
        success "$TEST_NAME: $msg"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: $msg (invalid JSON: $json)"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Exit code check}"
    if [[ "$expected" == "$actual" ]]; then
        success "$TEST_NAME: $msg"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: $msg (expected exit $expected, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_in_range() {
    local value="$1"
    local min="$2"
    local max="$3"
    local msg="${4:-Value in range}"
    if [[ "$value" -ge "$min" && "$value" -le "$max" ]]; then
        success "$TEST_NAME: $msg ($value in [$min, $max])"
        PASS=$((PASS + 1))
    else
        error "$TEST_NAME: $msg (expected $value in [$min, $max])"
        FAIL=$((FAIL + 1))
    fi
}

# Helper to populate JSONL history with N entries for a stage
populate_history() {
    local stage="$1" count="$2"
    shift 2
    # Remaining args are durations; if fewer than count, cycle through them
    local durations=("$@")
    local dur_count=${#durations[@]}

    mkdir -p "$(dirname "$PROFILER_HISTORY_FILE")"
    for i in $(seq 1 "$count"); do
        local idx=$(( (i - 1) % dur_count ))
        local dur="${durations[$idx]}"
        local ts
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        printf '{"stage":"%s","duration_s":%d,"timestamp":"%s"}\n' "$stage" "$dur" "$ts" >> "$PROFILER_HISTORY_FILE"
    done
}

reset_history() {
    rm -f "$PROFILER_HISTORY_FILE" "$PROFILER_EVENTS_FILE"
    mkdir -p "$(dirname "$PROFILER_HISTORY_FILE")"
    touch "$PROFILER_HISTORY_FILE"
}

# ─── Tests ──────────────────────────────────────────────────────────────────

# Test 1: Initialization creates files
test_init() {
    TEST_NAME="test_init"
    rm -rf "$TEST_DIR/.shipwright"
    profiler_init
    local exists=0
    [[ -f "$PROFILER_HISTORY_FILE" ]] && exists=1
    assert_equals "1" "$exists" "History file created"
}

# Test 2: Percentile computation — P50
test_percentile_p50() {
    TEST_NAME="test_percentile_p50"
    local result
    result=$(printf '%s\n' 10 20 30 40 50 60 70 80 90 100 | _profiler_percentile 0.50)
    assert_in_range "$result" 50 60 "P50 of 10..100"
}

# Test 3: Percentile computation — P95
test_percentile_p95() {
    TEST_NAME="test_percentile_p95"
    local result
    result=$(printf '%s\n' 10 20 30 40 50 60 70 80 90 100 | _profiler_percentile 0.95)
    assert_in_range "$result" 90 100 "P95 of 10..100"
}

# Test 4: Percentile with single value
test_percentile_single() {
    TEST_NAME="test_percentile_single"
    local result
    result=$(printf '%s\n' 42 | _profiler_percentile 0.95)
    assert_equals "42" "$result" "P95 of single value"
}

# Test 5: Stats with no data
test_stats_no_data() {
    TEST_NAME="test_stats_no_data"
    reset_history
    local result
    result=$(profiler_compute_stats "build")
    local samples
    samples=$(echo "$result" | jq -r '.samples' 2>/dev/null)
    assert_equals "0" "$samples" "Zero samples when no data"
}

# Test 6: Stats with data
test_stats_with_data() {
    TEST_NAME="test_stats_with_data"
    reset_history
    populate_history "build" 10 100 120 130 140 150 160 170 180 190 200
    local result
    result=$(profiler_compute_stats "build")
    assert_json_valid "$result" "Stats output is valid JSON"

    local samples
    samples=$(echo "$result" | jq -r '.samples' 2>/dev/null)
    assert_equals "10" "$samples" "Correct sample count"

    local p50
    p50=$(echo "$result" | jq -r '.p50' 2>/dev/null)
    assert_in_range "$p50" 140 160 "P50 in expected range"

    local p95
    p95=$(echo "$result" | jq -r '.p95' 2>/dev/null)
    assert_in_range "$p95" 180 200 "P95 in expected range"
}

# Test 7: Regression detection — no regression
test_regression_none() {
    TEST_NAME="test_regression_none"
    reset_history
    populate_history "test" 10 50 55 60 65 70 55 60 65 50 55
    local result=""
    result=$(profiler_check_regression "test" 75 2>/dev/null) || true
    assert_equals "" "$result" "No regression at 75s (within threshold)"
}

# Test 8: Regression detection — regression found
test_regression_found() {
    TEST_NAME="test_regression_found"
    reset_history
    populate_history "test" 10 50 55 60 65 70 55 60 65 50 55
    local result=""
    local rc=0
    result=$(profiler_check_regression "test" 200 2>/dev/null) || rc=$?
    # Should detect regression (200s >> P95 of ~70s)
    if [[ -n "$result" ]]; then
        assert_json_valid "$result" "Regression output is valid JSON"
        local regression
        regression=$(echo "$result" | jq -r '.regression' 2>/dev/null)
        assert_equals "true" "$regression" "Regression flag is true"
    else
        error "$TEST_NAME: Expected regression but got none"
        FAIL=$((FAIL + 1))
    fi
}

# Test 9: Regression detection — not enough samples
test_regression_insufficient_samples() {
    TEST_NAME="test_regression_insufficient_samples"
    reset_history
    populate_history "plan" 3 100 120 130
    local result=""
    result=$(profiler_check_regression "plan" 500 2>/dev/null) || true
    assert_equals "" "$result" "No regression with <5 samples"
}

# Test 10: Regression minimum delta enforcement
test_regression_min_delta() {
    TEST_NAME="test_regression_min_delta"
    reset_history
    # Very small durations — even 30% over P95 would be <5s delta
    populate_history "intake" 10 2 3 2 3 2 3 2 3 2 3
    local result=""
    result=$(profiler_check_regression "intake" 4 2>/dev/null) || true
    assert_equals "" "$result" "No regression when delta < 5s"
}

# Test 11: Bottleneck analysis
test_bottlenecks() {
    TEST_NAME="test_bottlenecks"
    reset_history
    populate_history "build" 10 500 520 540 510 530 500 520 510 530 540
    populate_history "test" 10 100 110 120 105 115 100 110 105 115 120
    populate_history "intake" 10 10 12 11 10 12 11 10 12 11 10

    local result
    result=$(profiler_bottlenecks 90 3)
    assert_json_valid "$result" "Bottlenecks output is valid JSON"

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null)
    assert_equals "3" "$count" "Returns 3 bottlenecks"

    # Build should be #1 (highest mean)
    local top_stage
    top_stage=$(echo "$result" | jq -r '.[0].stage' 2>/dev/null)
    assert_equals "build" "$top_stage" "Build is top bottleneck"
}

# Test 12: Bottleneck with no data
test_bottlenecks_empty() {
    TEST_NAME="test_bottlenecks_empty"
    reset_history
    local result
    result=$(profiler_bottlenecks 7 5)
    assert_equals "[]" "$result" "Empty bottlenecks when no data"
}

# Test 13: Budget analysis — no violations
test_budget_no_violations() {
    TEST_NAME="test_budget_no_violations"
    reset_history
    # Build timeout is 1800s, populate with durations well below
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local result
    result=$(profiler_budget)
    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null)
    assert_equals "0" "$count" "No budget violations"
}

# Test 14: Budget analysis — violation found
test_budget_violation() {
    TEST_NAME="test_budget_violation"
    reset_history
    # Intake timeout is 60s, populate with durations exceeding it
    populate_history "intake" 10 70 80 90 100 110 70 80 90 100 110
    local result
    result=$(profiler_budget)
    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null)
    assert_equals "1" "$count" "One budget violation"

    local violated_stage
    violated_stage=$(echo "$result" | jq -r '.[0].stage' 2>/dev/null)
    assert_equals "intake" "$violated_stage" "Intake is the violating stage"
}

# Test 15: Trends output
test_trends() {
    TEST_NAME="test_trends"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local result
    result=$(profiler_trends "build" "7,14,30")
    assert_json_valid "$result" "Trends output is valid JSON"

    local stage
    stage=$(echo "$result" | jq -r '.stage' 2>/dev/null)
    assert_equals "build" "$stage" "Correct stage in trends"

    local window_count
    window_count=$(echo "$result" | jq '.windows | length' 2>/dev/null)
    assert_equals "3" "$window_count" "Three time windows"
}

# Test 16: Export adaptive format
test_export_adaptive() {
    TEST_NAME="test_export_adaptive"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    populate_history "test" 10 50 55 60 65 70 50 55 60 65 70
    local result
    result=$(profiler_export_adaptive)
    assert_json_valid "$result" "Export output is valid JSON"

    local has_build
    has_build=$(echo "$result" | jq 'has("build")' 2>/dev/null)
    assert_equals "true" "$has_build" "Export contains build stage"

    local has_test
    has_test=$(echo "$result" | jq 'has("test")' 2>/dev/null)
    assert_equals "true" "$has_test" "Export contains test stage"
}

# Test 17: Widget output
test_widget() {
    TEST_NAME="test_widget"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local result
    result=$(profiler_widget)
    assert_json_valid "$result" "Widget output is valid JSON"

    local widget_type
    widget_type=$(echo "$result" | jq -r '.type' 2>/dev/null)
    assert_equals "stage-profiler" "$widget_type" "Widget type is stage-profiler"
}

# Test 18: Report JSON format
test_report_json() {
    TEST_NAME="test_report_json"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local result
    result=$(profiler_report "json")
    assert_json_valid "$result" "Report JSON is valid"

    local has_profiles
    has_profiles=$(echo "$result" | jq 'has("profiles")' 2>/dev/null)
    assert_equals "true" "$has_profiles" "Report has profiles section"

    local has_bottlenecks
    has_bottlenecks=$(echo "$result" | jq 'has("bottlenecks")' 2>/dev/null)
    assert_equals "true" "$has_bottlenecks" "Report has bottlenecks section"

    local has_budget
    has_budget=$(echo "$result" | jq 'has("budget_violations")' 2>/dev/null)
    assert_equals "true" "$has_budget" "Report has budget_violations section"
}

# Test 19: Report text format doesn't crash
test_report_text() {
    TEST_NAME="test_report_text"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local output
    output=$(profiler_report "text" 2>&1) || true
    assert_not_empty "$output" "Text report produces output"
}

# Test 20: Profiler analyze stage — no regression
test_analyze_no_regression() {
    TEST_NAME="test_analyze_no_regression"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local output
    output=$(profiler_analyze_stage "build" 150 "success" 2>&1) || true
    # Should not warn about regression
    local has_regression=0
    echo "$output" | grep -q "regression" && has_regression=1
    assert_equals "0" "$has_regression" "No regression warning"
}

# Test 21: Profiler analyze stage — regression detected
test_analyze_regression() {
    TEST_NAME="test_analyze_regression"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local output
    output=$(profiler_analyze_stage "build" 500 "success" 2>&1) || true
    local has_regression=0
    echo "$output" | grep -qi "regression" && has_regression=1
    assert_equals "1" "$has_regression" "Regression warning emitted"
}

# Test 22: Profiler analyze stage — skips failures
test_analyze_skips_failure() {
    TEST_NAME="test_analyze_skips_failure"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local output
    output=$(profiler_analyze_stage "build" 500 "failure" 2>&1) || true
    local has_regression=0
    echo "$output" | grep -qi "regression" && has_regression=1
    assert_equals "0" "$has_regression" "No regression for failed stages"
}

# Test 23: Reset clears history
test_reset() {
    TEST_NAME="test_reset"
    reset_history
    populate_history "build" 5 100 120 130 140 150
    profiler_reset
    local line_count
    line_count=$(wc -l < "$PROFILER_HISTORY_FILE" | xargs)
    assert_equals "0" "$line_count" "History cleared after reset"
}

# Test 24: Sample count function
test_sample_count() {
    TEST_NAME="test_sample_count"
    reset_history
    populate_history "build" 7 100 120 130 140 150 160 170
    local count
    count=$(_profiler_sample_count "build")
    assert_equals "7" "$count" "Correct sample count"
}

# Test 25: Sample count with no data
test_sample_count_empty() {
    TEST_NAME="test_sample_count_empty"
    reset_history
    local count
    count=$(_profiler_sample_count "nonexistent")
    assert_equals "0" "$count" "Zero samples for unknown stage"
}

# Test 26: CLI help subcommand
test_cli_help() {
    TEST_NAME="test_cli_help"
    local output
    output=$(bash "$SCRIPT_DIR/sw-stage-profiler.sh" help 2>&1) || true
    local has_usage=0
    echo "$output" | grep -q "Usage:" && has_usage=1
    assert_equals "1" "$has_usage" "Help shows usage"
}

# Test 27: CLI profile subcommand
test_cli_profile() {
    TEST_NAME="test_cli_profile"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local output
    output=$(bash "$SCRIPT_DIR/sw-stage-profiler.sh" profile build 2>&1) || true
    assert_json_valid "$output" "CLI profile outputs valid JSON"
}

# Test 28: CLI report --json
test_cli_report_json() {
    TEST_NAME="test_cli_report_json"
    reset_history
    populate_history "build" 10 100 120 130 140 150 100 120 130 140 150
    local output
    output=$(bash "$SCRIPT_DIR/sw-stage-profiler.sh" report --json 2>&1) || true
    # Filter out info/success/warn lines to get just JSON
    local json_line
    json_line=$(echo "$output" | grep '^{' | head -1)
    assert_json_valid "$json_line" "CLI report --json outputs valid JSON"
}

# Test 29: Events.jsonl fallback
test_events_fallback() {
    TEST_NAME="test_events_fallback"
    reset_history
    # Clear JSONL history, populate events.jsonl instead
    > "$PROFILER_HISTORY_FILE"
    mkdir -p "$(dirname "$PROFILER_EVENTS_FILE")"
    for dur in 100 120 130 140 150 160 170 180 190 200; do
        printf '{"ts":"2026-04-01T00:00:00Z","type":"stage.completed","stage":"review","duration_s":%d}\n' "$dur" >> "$PROFILER_EVENTS_FILE"
    done

    local result
    result=$(profiler_compute_stats "review")
    local samples
    samples=$(echo "$result" | jq -r '.samples' 2>/dev/null)
    assert_equals "10" "$samples" "Events.jsonl fallback provides data"
}

# Test 30: Stage timeout defaults
test_stage_timeouts() {
    TEST_NAME="test_stage_timeouts"
    local build_timeout
    build_timeout=$(_profiler_stage_timeout "build")
    assert_equals "1800" "$build_timeout" "Build timeout is 1800s"

    local intake_timeout
    intake_timeout=$(_profiler_stage_timeout "intake")
    assert_equals "60" "$intake_timeout" "Intake timeout is 60s"
}

# ─── Run All Tests ─────────────────────────────────────────────────────────

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  Stage Duration Profiler — Test Suite                         ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

test_init
test_percentile_p50
test_percentile_p95
test_percentile_single
test_stats_no_data
test_stats_with_data
test_regression_none
test_regression_found
test_regression_insufficient_samples
test_regression_min_delta
test_bottlenecks
test_bottlenecks_empty
test_budget_no_violations
test_budget_violation
test_trends
test_export_adaptive
test_widget
test_report_json
test_report_text
test_analyze_no_regression
test_analyze_regression
test_analyze_skips_failure
test_reset
test_sample_count
test_sample_count_empty
test_cli_help
test_cli_profile
test_cli_report_json
test_events_fallback
test_stage_timeouts

# ─── Summary ──────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════"
printf "  Results: %d passed, %d failed (total: %d)\n" "$PASS" "$FAIL" "$((PASS + FAIL))"
echo "════════════════════════════════════════════════════════════════"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
