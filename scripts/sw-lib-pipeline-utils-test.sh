#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-utils test — Unit tests for utility functions   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-utils Tests"

setup_test_env "sw-lib-pipeline-utils-test"
trap cleanup_test_env EXIT

# Set up pipeline env
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export ISSUE_NUMBER=""
export NO_GITHUB=true
export EVENTS_FILE="$TEST_TEMP_DIR/events.jsonl"

mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$TEST_TEMP_DIR/.shipwright/optimization"

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
info() { echo -e "▸ $*"; }
success() { echo -e "✓ $*"; }
warn() { echo -e "⚠ $*"; }
error() { echo -e "✗ $*" >&2; }
_config_get_int() { echo "${2:-10}"; }

# Source the library under test
source "$SCRIPT_DIR/lib/pipeline-utils.sh"

# ──────────────────────────────────────────────────────────────────────────────
# 1. format_duration: boundary cases
# ──────────────────────────────────────────────────────────────────────────────
test_format_duration_zero() {
    local result
    result=$(format_duration 0)
    [[ "$result" == "0s" ]] || { echo "Expected '0s' got '$result'"; return 1; }
}

test_format_duration_seconds() {
    local result
    result=$(format_duration 45)
    [[ "$result" == "45s" ]] || { echo "Expected '45s' got '$result'"; return 1; }
}

test_format_duration_minutes() {
    local result
    result=$(format_duration 90)
    [[ "$result" == "1m 30s" ]] || { echo "Expected '1m 30s' got '$result'"; return 1; }
}

test_format_duration_hours() {
    local result
    result=$(format_duration 3661)
    [[ "$result" == "1h 1m 1s" ]] || { echo "Expected '1h 1m 1s' got '$result'"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. parse_coverage_from_output: various frameworks + edge cases
# ──────────────────────────────────────────────────────────────────────────────
test_coverage_missing_file() {
    local result
    result=$(parse_coverage_from_output "/nonexistent/file.log")
    [[ -z "$result" ]] || { echo "Expected empty for missing file, got '$result'"; return 1; }
}

test_coverage_jest() {
    echo "Statements : 85.5%" > "$TEST_TEMP_DIR/test.log"
    local result
    result=$(parse_coverage_from_output "$TEST_TEMP_DIR/test.log")
    [[ "$result" == "85.5" ]] || { echo "Expected '85.5' got '$result'"; return 1; }
}

test_coverage_go() {
    echo "coverage: 91.3% of statements" > "$TEST_TEMP_DIR/test.log"
    local result
    result=$(parse_coverage_from_output "$TEST_TEMP_DIR/test.log")
    [[ "$result" == "91.3" ]] || { echo "Expected '91.3' got '$result'"; return 1; }
}

test_coverage_empty_file() {
    : > "$TEST_TEMP_DIR/empty.log"
    local result
    result=$(parse_coverage_from_output "$TEST_TEMP_DIR/empty.log")
    [[ -z "$result" ]] || { echo "Expected empty for empty file, got '$result'"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. classify_error: four categories
# ──────────────────────────────────────────────────────────────────────────────
test_classify_infrastructure() {
    echo "Error: ETIMEDOUT connecting to database" > "$ARTIFACTS_DIR/build-results.log"
    local result
    result=$(HOME="$TEST_TEMP_DIR" classify_error "build")
    [[ "$result" == "infrastructure" ]] || { echo "Expected 'infrastructure' got '$result'"; return 1; }
}

test_classify_configuration() {
    echo "Error: ENOENT: no such file or directory" > "$ARTIFACTS_DIR/build-results.log"
    local result
    result=$(HOME="$TEST_TEMP_DIR" classify_error "build")
    [[ "$result" == "configuration" ]] || { echo "Expected 'configuration' got '$result'"; return 1; }
}

test_classify_logic() {
    echo "AssertionError: expected 5 to equal 3" > "$ARTIFACTS_DIR/test-results.log"
    local result
    result=$(HOME="$TEST_TEMP_DIR" classify_error "test")
    [[ "$result" == "logic" ]] || { echo "Expected 'logic' got '$result'"; return 1; }
}

test_classify_unknown() {
    echo "Something weird happened" > "$ARTIFACTS_DIR/build-results.log"
    local result
    result=$(HOME="$TEST_TEMP_DIR" classify_error "build")
    [[ "$result" == "unknown" ]] || { echo "Expected 'unknown' got '$result'"; return 1; }
}

test_classify_no_log() {
    rm -f "$ARTIFACTS_DIR/missing-results.log" "$ARTIFACTS_DIR/test-results.log"
    local result
    result=$(classify_error "missing")
    [[ "$result" == "unknown" ]] || { echo "Expected 'unknown' got '$result'"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. _pipeline_compact_goal
# ──────────────────────────────────────────────────────────────────────────────
test_compact_goal_basic() {
    local result
    result=$(_pipeline_compact_goal "Build auth module")
    echo "$result" | grep -q "Build auth module" || { echo "Missing goal"; return 1; }
}

test_compact_goal_with_plan_and_design() {
    local plan="$TEST_TEMP_DIR/plan.md"
    local design="$TEST_TEMP_DIR/design.md"
    printf '%s\n' "# Plan" "Step 1" "Step 2" > "$plan"
    printf '%s\n' "# Architecture" "## Database" "## API" > "$design"
    local result
    result=$(_pipeline_compact_goal "Add auth" "$plan" "$design")
    echo "$result" | grep -q "Plan Summary" || { echo "Missing Plan Summary"; return 1; }
    echo "$result" | grep -q "Key Design Decisions" || { echo "Missing Design Decisions"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. rotate_event_log_if_needed
# ──────────────────────────────────────────────────────────────────────────────
test_rotate_skips_missing() {
    EVENTS_FILE="$TEST_TEMP_DIR/nonexistent.jsonl"
    rotate_event_log_if_needed
    # Should not error
}

test_rotate_skips_small() {
    EVENTS_FILE="$TEST_TEMP_DIR/small.jsonl"
    printf '%s\n' '{"type":"test"}' '{"type":"test2"}' > "$EVENTS_FILE"
    local before_lines
    before_lines=$(wc -l < "$EVENTS_FILE")
    rotate_event_log_if_needed
    local after_lines
    after_lines=$(wc -l < "$EVENTS_FILE")
    [[ "$before_lines" == "$after_lines" ]] || { echo "Small file should not be rotated"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. estimate_pipeline_cost
# ──────────────────────────────────────────────────────────────────────────────
test_estimate_cost_no_history() {
    EVENTS_FILE="$TEST_TEMP_DIR/nonexistent-events.jsonl"
    local result
    result=$(estimate_pipeline_cost '[{"id":"build"},{"id":"test"}]')
    echo "$result" | jq -e '.input_tokens > 0' >/dev/null || { echo "Expected positive input tokens"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. parse_claude_tokens
# ──────────────────────────────────────────────────────────────────────────────
test_parse_tokens() {
    TOTAL_INPUT_TOKENS=0
    TOTAL_OUTPUT_TOKENS=0
    echo "input tokens: 5000, output tokens: 2000" > "$TEST_TEMP_DIR/tokens.log"
    parse_claude_tokens "$TEST_TEMP_DIR/tokens.log"
    [[ "$TOTAL_INPUT_TOKENS" -eq 5000 ]] || { echo "Expected 5000 input, got $TOTAL_INPUT_TOKENS"; return 1; }
    [[ "$TOTAL_OUTPUT_TOKENS" -eq 2000 ]] || { echo "Expected 2000 output, got $TOTAL_OUTPUT_TOKENS"; return 1; }
}

test_parse_tokens_accumulates() {
    TOTAL_INPUT_TOKENS=1000
    TOTAL_OUTPUT_TOKENS=500
    echo "input tokens: 3000, output tokens: 1500" > "$TEST_TEMP_DIR/tokens2.log"
    parse_claude_tokens "$TEST_TEMP_DIR/tokens2.log"
    [[ "$TOTAL_INPUT_TOKENS" -eq 4000 ]] || { echo "Expected 4000 input, got $TOTAL_INPUT_TOKENS"; return 1; }
    [[ "$TOTAL_OUTPUT_TOKENS" -eq 2000 ]] || { echo "Expected 2000 output, got $TOTAL_OUTPUT_TOKENS"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. load_composed_pipeline
# ──────────────────────────────────────────────────────────────────────────────
test_load_composed_missing_file() {
    COMPOSED_STAGES=""
    load_composed_pipeline "/nonexistent.json" && { echo "Should fail for missing file"; return 1; }
    return 0
}

test_load_composed_sets_stages() {
    COMPOSED_STAGES=""
    COMPOSED_BUILD_ITERATIONS=""
    local spec="$TEST_TEMP_DIR/composed.json"
    echo '{"stages":[{"id":"intake"},{"id":"build","max_iterations":20},{"id":"test"}]}' > "$spec"
    load_composed_pipeline "$spec" || { echo "load_composed_pipeline should succeed"; return 1; }
    echo "$COMPOSED_STAGES" | grep -q "intake" || { echo "Missing intake in COMPOSED_STAGES"; return 1; }
    echo "$COMPOSED_STAGES" | grep -q "build" || { echo "Missing build in COMPOSED_STAGES"; return 1; }
    [[ "$COMPOSED_BUILD_ITERATIONS" == "20" ]] || { echo "Expected iterations=20 got '$COMPOSED_BUILD_ITERATIONS'"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# Run all tests
# ──────────────────────────────────────────────────────────────────────────────
tests=(
    "test_format_duration_zero:format_duration returns 0s"
    "test_format_duration_seconds:format_duration returns seconds"
    "test_format_duration_minutes:format_duration returns minutes"
    "test_format_duration_hours:format_duration returns hours"
    "test_coverage_missing_file:parse_coverage handles missing file"
    "test_coverage_jest:parse_coverage parses Jest output"
    "test_coverage_go:parse_coverage parses Go output"
    "test_coverage_empty_file:parse_coverage handles empty file"
    "test_classify_infrastructure:classify_error detects infrastructure"
    "test_classify_configuration:classify_error detects configuration"
    "test_classify_logic:classify_error detects logic"
    "test_classify_unknown:classify_error returns unknown"
    "test_classify_no_log:classify_error returns unknown for missing log"
    "test_compact_goal_basic:compact_goal returns goal text"
    "test_compact_goal_with_plan_and_design:compact_goal includes plan and design"
    "test_rotate_skips_missing:rotate_event_log skips missing file"
    "test_rotate_skips_small:rotate_event_log skips small file"
    "test_estimate_cost_no_history:estimate_pipeline_cost returns estimate"
    "test_parse_tokens:parse_claude_tokens extracts tokens"
    "test_parse_tokens_accumulates:parse_claude_tokens accumulates"
    "test_load_composed_missing_file:load_composed_pipeline fails for missing file"
    "test_load_composed_sets_stages:load_composed_pipeline sets COMPOSED_STAGES"
)

for entry in "${tests[@]}"; do
    fn="${entry%%:*}"
    desc="${entry#*:}"
    if $fn; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
done

print_test_results
