#!/usr/bin/env bash
# ╔��══════════════════════════════════════════════════════════════════════════╗
# ║  sw-preflight-cost-test.sh — Pre-Flight Cost Estimator Test Suite       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_exit_code() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected exit code: $expected"
        echo "    Actual exit code:   $actual"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" description="${3:-}"
    if echo "$haystack" | grep -qF "$needle"; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    Actual: $(echo "$haystack" | head -3)"
    fi
}

assert_json_field() {
    local json="$1" field="$2" expected="$3" description="${4:-}"
    local actual=""
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "PARSE_ERROR")
    if [[ "$expected" == "$actual" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Field: $field"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

# ─── Setup test environment ─────────────────────────────────────────────────
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/preflight-cost-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

# Create mock project structure
mkdir -p "$TEST_DIR/config"
mkdir -p "$TEST_DIR/.claude"
mkdir -p "$TEST_DIR/.shipwright/memory"

# Create policy.json with cost_policy enabled
cat > "$TEST_DIR/config/policy.json" << 'POLICY'
{
  "$schema": "https://shipwright.dev/schemas/policy-v1.json",
  "version": "2",
  "cost_policy": {
    "enabled": true,
    "max_cost_usd": 25.0,
    "min_success_probability": 30,
    "warn_cost_usd": 15.0,
    "warn_success_probability": 50,
    "interactive_prompt": true,
    "log_predictions": true
  }
}
POLICY

# Create disabled policy for testing disabled state
cat > "$TEST_DIR/config/policy-disabled.json" << 'POLICY'
{
  "$schema": "https://shipwright.dev/schemas/policy-v1.json",
  "version": "2",
  "cost_policy": {
    "enabled": false
  }
}
POLICY

# Create policy without cost_policy block
cat > "$TEST_DIR/config/policy-missing.json" << 'POLICY'
{
  "$schema": "https://shipwright.dev/schemas/policy-v1.json",
  "version": "2"
}
POLICY

# Mock intelligence cache
cat > "$TEST_DIR/.claude/intelligence-cache.json" << 'CACHE'
{
  "file_count": 50,
  "test_coverage": 75
}
CACHE

# Override PROJECT_ROOT and predictions file for isolation
export PROJECT_ROOT="$TEST_DIR"
export HOME="$TEST_DIR"
_PREFLIGHT_PREDICTIONS_FILE="$TEST_DIR/.shipwright/cost-predictions.jsonl"

# Source the module (reset guard first)
unset _MODULE_PREFLIGHT_COST_LOADED 2>/dev/null || true
source "$SCRIPT_DIR/lib/preflight-cost.sh"

# Override the predictions file after sourcing
_PREFLIGHT_PREDICTIONS_FILE="$TEST_DIR/.shipwright/cost-predictions.jsonl"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  Pre-Flight Cost Estimator Test Suite                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Section 1: preflight_cost_init ──────────────────────────────"

test_init_enabled() {
    unset _MODULE_PREFLIGHT_COST_LOADED
    source "$SCRIPT_DIR/lib/preflight-cost.sh"
    _PREFLIGHT_PREDICTIONS_FILE="$TEST_DIR/.shipwright/cost-predictions.jsonl"
    PROJECT_ROOT="$TEST_DIR"
    preflight_cost_init
    assert_equals "true" "$PREFLIGHT_COST_ENABLED" "init with enabled policy sets ENABLED=true"
}

test_init_disabled() {
    unset _MODULE_PREFLIGHT_COST_LOADED
    source "$SCRIPT_DIR/lib/preflight-cost.sh"
    _PREFLIGHT_PREDICTIONS_FILE="$TEST_DIR/.shipwright/cost-predictions.jsonl"
    # Use disabled policy
    local save_root="$PROJECT_ROOT"
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/pf-disabled.XXXXXX")
    mkdir -p "$tmp_dir/config"
    cp "$TEST_DIR/config/policy-disabled.json" "$tmp_dir/config/policy.json"
    PROJECT_ROOT="$tmp_dir"
    preflight_cost_init
    assert_equals "false" "$PREFLIGHT_COST_ENABLED" "init with disabled policy sets ENABLED=false"
    PROJECT_ROOT="$save_root"
    rm -rf "$tmp_dir"
}

test_init_missing_block() {
    unset _MODULE_PREFLIGHT_COST_LOADED
    source "$SCRIPT_DIR/lib/preflight-cost.sh"
    _PREFLIGHT_PREDICTIONS_FILE="$TEST_DIR/.shipwright/cost-predictions.jsonl"
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/pf-missing.XXXXXX")
    mkdir -p "$tmp_dir/config"
    cp "$TEST_DIR/config/policy-missing.json" "$tmp_dir/config/policy.json"
    PROJECT_ROOT="$tmp_dir"
    preflight_cost_init
    assert_equals "false" "$PREFLIGHT_COST_ENABLED" "init with missing cost_policy sets ENABLED=false"
    PROJECT_ROOT="$TEST_DIR"
    rm -rf "$tmp_dir"
}

test_init_no_policy_file() {
    unset _MODULE_PREFLIGHT_COST_LOADED
    source "$SCRIPT_DIR/lib/preflight-cost.sh"
    _PREFLIGHT_PREDICTIONS_FILE="$TEST_DIR/.shipwright/cost-predictions.jsonl"
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/pf-nofile.XXXXXX")
    PROJECT_ROOT="$tmp_dir"
    preflight_cost_init
    assert_equals "false" "$PREFLIGHT_COST_ENABLED" "init with no policy file sets ENABLED=false"
    PROJECT_ROOT="$TEST_DIR"
    rm -rf "$tmp_dir"
}

test_init_enabled
test_init_disabled
test_init_missing_block
test_init_no_policy_file

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Section 2: preflight_cost_estimate (heuristic) ──────────────"

# Re-init in enabled state
PROJECT_ROOT="$TEST_DIR"
preflight_cost_init

test_estimate_simple_issue() {
    local issue_json='{"title":"Fix typo in README","body":"There is a typo on line 42 of the README. The word \"teh\" should be \"the\". This is a very simple one-line fix that should be straightforward to implement.","labels":["bug"],"number":100}'
    local result=""
    result=$(preflight_cost_estimate "$issue_json")
    local rc=$?
    assert_exit_code 0 "$rc" "estimate succeeds for simple issue"
    assert_json_field "$result" '.model_used' "heuristic" "uses heuristic model"
    assert_json_field "$result" '.recommended_template' "fast" "recommends fast template for simple issue"

    local iters=""
    iters=$(echo "$result" | jq -r '.estimated_iterations' 2>/dev/null || echo "0")
    local iters_ok="false"
    if [[ "$iters" -ge 1 && "$iters" -le 3 ]]; then iters_ok="true"; fi
    assert_equals "true" "$iters_ok" "simple issue estimates 1-3 iterations (got: $iters)"

    local success=""
    success=$(echo "$result" | jq -r '.success_probability' 2>/dev/null || echo "0")
    local success_ok="false"
    if [[ "$success" -ge 60 ]]; then success_ok="true"; fi
    assert_equals "true" "$success_ok" "simple issue has high success probability (got: ${success}%)"
}

test_estimate_complex_issue() {
    local issue_json='{"title":"Implement distributed caching layer with Redis cluster support and automatic failover for the microservices architecture","body":"Short","labels":["feature","complex","backend","frontend","database"],"number":200}'
    local result=""
    result=$(preflight_cost_estimate "$issue_json")
    local rc=$?
    assert_exit_code 0 "$rc" "estimate succeeds for complex issue"
    assert_json_field "$result" '.model_used' "heuristic" "uses heuristic model"

    local iters=""
    iters=$(echo "$result" | jq -r '.estimated_iterations' 2>/dev/null || echo "0")
    local iters_ok="false"
    if [[ "$iters" -ge 3 ]]; then iters_ok="true"; fi
    assert_equals "true" "$iters_ok" "complex issue estimates 3+ iterations (got: $iters)"

    local success=""
    success=$(echo "$result" | jq -r '.success_probability' 2>/dev/null || echo "100")
    local success_ok="false"
    if [[ "$success" -le 80 ]]; then success_ok="true"; fi
    assert_equals "true" "$success_ok" "complex issue has lower success probability (got: ${success}%)"

    local signals=""
    signals=$(echo "$result" | jq -r '.signals_triggered | length' 2>/dev/null || echo "0")
    local signals_ok="false"
    if [[ "$signals" -ge 2 ]]; then signals_ok="true"; fi
    assert_equals "true" "$signals_ok" "complex issue triggers 2+ signals (got: $signals)"
}

test_estimate_empty_json() {
    local rc=0
    preflight_cost_estimate "" > /dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "estimate returns 1 for empty input"
}

test_estimate_when_disabled() {
    PREFLIGHT_COST_ENABLED="false"
    local rc=0
    preflight_cost_estimate '{"title":"test","body":"test","labels":[],"number":1}' > /dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "estimate returns 1 when disabled"
    PREFLIGHT_COST_ENABLED="true"
}

test_estimate_valid_json_output() {
    local issue_json='{"title":"Add login page","body":"Implement a login page with email and password fields. Include validation and error handling for incorrect credentials.","labels":["feature"],"number":300}'
    local result=""
    result=$(preflight_cost_estimate "$issue_json")
    # Verify all required fields exist
    assert_json_field "$result" '.estimated_cost_usd | type' "number" "estimated_cost_usd is a number"
    assert_json_field "$result" '.estimated_iterations | type' "number" "estimated_iterations is a number"
    assert_json_field "$result" '.success_probability | type' "number" "success_probability is a number"
    assert_json_field "$result" '.confidence | type' "number" "confidence is a number"
    assert_json_field "$result" '.signals_triggered | type' "array" "signals_triggered is an array"
    assert_json_field "$result" '.recommended_template | type' "string" "recommended_template is a string"
    assert_json_field "$result" '.model_used | type' "string" "model_used is a string"
}

test_estimate_simple_issue
test_estimate_complex_issue
test_estimate_empty_json
test_estimate_when_disabled
test_estimate_valid_json_output

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Section 3: preflight_cost_gate ──────────────────────────────"

test_gate_proceed() {
    local estimate='{"estimated_cost_usd":5.0,"success_probability":80}'
    local reason=""
    reason=$(preflight_cost_gate "$estimate" 2>/dev/null) || true
    local rc=0
    preflight_cost_gate "$estimate" > /dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "gate returns 0 (proceed) for acceptable estimate"
}

test_gate_blocked_cost() {
    local estimate='{"estimated_cost_usd":30.0,"success_probability":80}'
    local rc=0
    local reason=""
    reason=$(preflight_cost_gate "$estimate" 2>/dev/null) || rc=$?
    assert_exit_code 1 "$rc" "gate returns 1 (blocked) when cost exceeds max"
    assert_contains "exceeds maximum" "$reason" "blocked reason mentions cost exceeds maximum"
}

test_gate_blocked_success() {
    local estimate='{"estimated_cost_usd":5.0,"success_probability":20}'
    local rc=0
    local reason=""
    reason=$(preflight_cost_gate "$estimate" 2>/dev/null) || rc=$?
    assert_exit_code 1 "$rc" "gate returns 1 (blocked) when success below minimum"
    assert_contains "below minimum" "$reason" "blocked reason mentions below minimum"
}

test_gate_warn_cost() {
    local estimate='{"estimated_cost_usd":18.0,"success_probability":80}'
    local rc=0
    local reason=""
    reason=$(preflight_cost_gate "$estimate" 2>/dev/null) || rc=$?
    assert_exit_code 2 "$rc" "gate returns 2 (warn) when cost approaches limit"
    assert_contains "approaching limit" "$reason" "warn reason mentions approaching limit"
}

test_gate_warn_success() {
    local estimate='{"estimated_cost_usd":5.0,"success_probability":45}'
    local rc=0
    local reason=""
    reason=$(preflight_cost_gate "$estimate" 2>/dev/null) || rc=$?
    assert_exit_code 2 "$rc" "gate returns 2 (warn) when success is low"
    assert_contains "low" "$reason" "warn reason mentions low success"
}

test_gate_disabled() {
    PREFLIGHT_COST_ENABLED="false"
    local estimate='{"estimated_cost_usd":999.0,"success_probability":1}'
    local rc=0
    preflight_cost_gate "$estimate" > /dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "gate returns 0 when disabled (even extreme values)"
    PREFLIGHT_COST_ENABLED="true"
}

test_gate_empty_estimate() {
    local rc=0
    preflight_cost_gate "" > /dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "gate returns 0 for empty estimate (safe default)"
}

test_gate_proceed
test_gate_blocked_cost
test_gate_blocked_success
test_gate_warn_cost
test_gate_warn_success
test_gate_disabled
test_gate_empty_estimate

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Section 4: preflight_cost_prompt ────────────────────────────"

test_prompt_non_tty() {
    local estimate='{"estimated_cost_usd":5.0,"success_probability":80,"estimated_iterations":2,"confidence":60,"recommended_template":"standard","model_used":"heuristic"}'
    # When stdin is not a TTY (piped), should auto-approve
    local rc=0
    echo "" | preflight_cost_prompt "$estimate" > /dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "prompt returns 0 (approve) when stdin is not TTY"
}

test_prompt_empty_estimate() {
    local rc=0
    preflight_cost_prompt "" > /dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "prompt returns 0 for empty estimate"
}

test_prompt_interactive_disabled() {
    local saved="$_PREFLIGHT_COST_INTERACTIVE"
    _PREFLIGHT_COST_INTERACTIVE="false"
    local estimate='{"estimated_cost_usd":5.0,"success_probability":80,"estimated_iterations":2,"confidence":60,"recommended_template":"standard","model_used":"heuristic"}'
    local rc=0
    preflight_cost_prompt "$estimate" > /dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "prompt returns 0 when interactive_prompt is false"
    _PREFLIGHT_COST_INTERACTIVE="$saved"
}

test_prompt_non_tty
test_prompt_empty_estimate
test_prompt_interactive_disabled

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Section 5: preflight_cost_log_outcome ───────────────────────"

test_log_outcome() {
    # Clear predictions file
    rm -f "$_PREFLIGHT_PREDICTIONS_FILE"
    _PREFLIGHT_COST_LOG="true"
    preflight_cost_log_outcome "42" "3.50" "2" "success"
    local line_count=0
    if [[ -f "$_PREFLIGHT_PREDICTIONS_FILE" ]]; then
        line_count=$(wc -l < "$_PREFLIGHT_PREDICTIONS_FILE" | tr -d ' ')
    fi
    assert_equals "1" "$line_count" "log_outcome writes one JSONL line"

    local last_line=""
    last_line=$(tail -1 "$_PREFLIGHT_PREDICTIONS_FILE")
    assert_json_field "$last_line" '.type' "outcome" "logged entry has type=outcome"
    assert_json_field "$last_line" '.issue_number' "42" "logged entry has correct issue number"
    assert_json_field "$last_line" '.status' "success" "logged entry has correct status"
    assert_json_field "$last_line" '.actual_cost_usd' "3.5" "logged entry has correct actual cost"
}

test_log_outcome_disabled() {
    rm -f "$_PREFLIGHT_PREDICTIONS_FILE"
    _PREFLIGHT_COST_LOG="false"
    preflight_cost_log_outcome "42" "3.50" "2" "success"
    local exists="false"
    [[ -f "$_PREFLIGHT_PREDICTIONS_FILE" ]] && exists="true"
    assert_equals "false" "$exists" "log_outcome does not write when logging disabled"
    _PREFLIGHT_COST_LOG="true"
}

test_log_outcome_empty_issue() {
    rm -f "$_PREFLIGHT_PREDICTIONS_FILE"
    _PREFLIGHT_COST_LOG="true"
    preflight_cost_log_outcome "" "3.50" "2" "success"
    local exists="false"
    [[ -f "$_PREFLIGHT_PREDICTIONS_FILE" ]] && exists="true"
    assert_equals "false" "$exists" "log_outcome does not write for empty issue number"
}

test_log_outcome
test_log_outcome_disabled
test_log_outcome_empty_issue

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Section 6: Prediction logging from estimate ─────────────────"

test_estimate_logs_prediction() {
    rm -f "$_PREFLIGHT_PREDICTIONS_FILE"
    _PREFLIGHT_COST_LOG="true"
    PREFLIGHT_COST_ENABLED="true"
    local issue_json='{"title":"Add feature X","body":"Implement feature X with full test coverage and documentation updates for the team. Ensure backward compatibility.","labels":["feature"],"number":500}'
    preflight_cost_estimate "$issue_json" > /dev/null
    local line_count=0
    if [[ -f "$_PREFLIGHT_PREDICTIONS_FILE" ]]; then
        line_count=$(wc -l < "$_PREFLIGHT_PREDICTIONS_FILE" | tr -d ' ')
    fi
    assert_equals "1" "$line_count" "estimate logs a prediction to JSONL"

    local first_line=""
    first_line=$(head -1 "$_PREFLIGHT_PREDICTIONS_FILE")
    assert_json_field "$first_line" '.type' "prediction" "logged prediction has type=prediction"
    assert_json_field "$first_line" '.issue_number' "500" "logged prediction has correct issue number"
}

test_estimate_logs_prediction

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Section 7: Integration — 3-issue scenario ───────────────────"

test_three_issue_scenario() {
    rm -f "$_PREFLIGHT_PREDICTIONS_FILE"
    PREFLIGHT_COST_ENABLED="true"
    _PREFLIGHT_COST_LOG="true"

    # Issue 1: Simple fix
    local simple='{"title":"Fix typo","body":"Change \"teh\" to \"the\" on line 5 of the README file. This is just a single character fix.","labels":["bug"],"number":1}'
    local est1=""
    est1=$(preflight_cost_estimate "$simple")
    local cost1="" iters1="" success1=""
    cost1=$(echo "$est1" | jq -r '.estimated_cost_usd' 2>/dev/null)
    iters1=$(echo "$est1" | jq -r '.estimated_iterations' 2>/dev/null)
    success1=$(echo "$est1" | jq -r '.success_probability' 2>/dev/null)

    # Issue 2: Medium feature
    local medium='{"title":"Add user profile page","body":"Create a new user profile page that displays user information including name, email, avatar, and recent activity. Include proper error handling and loading states. Add unit tests.","labels":["feature","frontend"],"number":2}'
    local est2=""
    est2=$(preflight_cost_estimate "$medium")
    local cost2="" iters2="" success2=""
    cost2=$(echo "$est2" | jq -r '.estimated_cost_usd' 2>/dev/null)
    iters2=$(echo "$est2" | jq -r '.estimated_iterations' 2>/dev/null)
    success2=$(echo "$est2" | jq -r '.success_probability' 2>/dev/null)

    # Issue 3: Complex epic
    local complex='{"title":"Implement distributed caching with Redis cluster and automatic failover mechanisms across all microservices","body":"Short","labels":["feature","complex","epic","backend","infra","database"],"number":3}'
    local est3=""
    est3=$(preflight_cost_estimate "$complex")
    local cost3="" iters3="" success3=""
    cost3=$(echo "$est3" | jq -r '.estimated_cost_usd' 2>/dev/null)
    iters3=$(echo "$est3" | jq -r '.estimated_iterations' 2>/dev/null)
    success3=$(echo "$est3" | jq -r '.success_probability' 2>/dev/null)

    # Verify ordering: simple < medium < complex (cost)
    local cost_order="false"
    if awk -v a="$cost1" -v b="$cost3" 'BEGIN { exit !(a < b) }' 2>/dev/null; then
        cost_order="true"
    fi
    assert_equals "true" "$cost_order" "simple issue costs less than complex (simple=\$${cost1}, complex=\$${cost3})"

    # Verify ordering: simple < medium < complex (iterations)
    local iter_order="false"
    if [[ "$iters1" -le "$iters3" ]]; then iter_order="true"; fi
    assert_equals "true" "$iter_order" "simple issue has fewer iterations than complex (simple=${iters1}, complex=${iters3})"

    # Verify ordering: simple > medium > complex (success probability)
    local success_order="false"
    if [[ "$success1" -ge "$success3" ]]; then success_order="true"; fi
    assert_equals "true" "$success_order" "simple issue has higher success probability (simple=${success1}%, complex=${success3}%)"

    # Gate checks
    local gate_rc=0
    preflight_cost_gate "$est1" > /dev/null 2>&1 || gate_rc=$?
    assert_exit_code 0 "$gate_rc" "simple issue passes gate"

    # Log outcomes
    preflight_cost_log_outcome "1" "2.00" "1" "success"
    preflight_cost_log_outcome "2" "6.00" "3" "success"
    preflight_cost_log_outcome "3" "15.00" "6" "failure"

    # Verify predictions file has all entries
    local total_lines=0
    if [[ -f "$_PREFLIGHT_PREDICTIONS_FILE" ]]; then
        total_lines=$(wc -l < "$_PREFLIGHT_PREDICTIONS_FILE" | tr -d ' ')
    fi
    # 3 predictions + 3 outcomes = 6 lines
    assert_equals "6" "$total_lines" "predictions file has 6 entries (3 predictions + 3 outcomes)"
}

test_three_issue_scenario

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "── Section 8: Edge cases ───────────────────────────────────────"

test_malformed_json_gate() {
    local rc=0
    preflight_cost_gate "not valid json" > /dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "gate returns 0 (proceed) for malformed JSON"
}

test_estimate_iteration_cap() {
    # Issue with maximum signals — should not exceed 8 iterations
    local issue_json='{"title":"Implement distributed caching layer with Redis cluster support and automatic failover for the microservices architecture plus monitoring","body":"Short","labels":["feature","complex","epic","backend","frontend","database","infra","devops"],"number":999}'
    local result=""
    result=$(preflight_cost_estimate "$issue_json")
    local iters=""
    iters=$(echo "$result" | jq -r '.estimated_iterations' 2>/dev/null || echo "0")
    local capped="false"
    if [[ "$iters" -le 8 ]]; then capped="true"; fi
    assert_equals "true" "$capped" "iterations capped at 8 (got: $iters)"
}

test_estimate_min_success() {
    # Even with many signals, success should not drop below 10%
    local issue_json='{"title":"Implement distributed caching layer with Redis cluster support and automatic failover for the microservices architecture plus monitoring","body":"Short","labels":["feature","complex","epic","backend","frontend","database","infra","devops"],"number":998}'
    local result=""
    result=$(preflight_cost_estimate "$issue_json")
    local success=""
    success=$(echo "$result" | jq -r '.success_probability' 2>/dev/null || echo "0")
    local above_min="false"
    if [[ "$success" -ge 10 ]]; then above_min="true"; fi
    assert_equals "true" "$above_min" "success probability never below 10% (got: ${success}%)"
}

test_malformed_json_gate
test_estimate_iteration_cap
test_estimate_min_success

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "────────────────────────────────────────────────────────────────"
echo -e "  Results: \033[38;2;74;222;128m${PASS} passed\033[0m, \033[38;2;248;113;113m${FAIL} failed\033[0m"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
