#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-success-rate-constraints-test.sh                                     ║
# ║  Unit tests for success-rate-constraints.sh                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# Test harness setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR="${TMPDIR:-/tmp}"
TEST_DIR="${TMPDIR}/sw-success-rate-constraints-test-$$"
PASS=0
FAIL=0
TOTAL=0

# Colors for output
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
RESET='\033[0m'

# ─── Setup/Teardown ──────────────────────────────────────────────────────────

setup_test() {
    mkdir -p "$TEST_DIR"
    export HOME="${TEST_DIR}/home"
    mkdir -p "$HOME/.shipwright"
    mkdir -p "$HOME/.claude"

    # Mock daemon-config.json
    cat > "$HOME/.claude/daemon-config.json" 2>/dev/null << 'EOF' || true
{}
EOF
}

teardown_test() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}

# ─── Test Assertion Helpers ──────────────────────────────────────────────────

assert_equals() {
    local expected="$1" actual="$2" test_name="$3"
    ((TOTAL++)) || true

    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✓${RESET} $test_name"
        ((PASS++)) || true
    else
        echo -e "${RED}✗${RESET} $test_name"
        echo "  Expected: $expected"
        echo "  Got:      $actual"
        ((FAIL++)) || true
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" test_name="$3"
    ((TOTAL++)) || true

    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}✓${RESET} $test_name"
        ((PASS++)) || true
    else
        echo -e "${RED}✗${RESET} $test_name"
        echo "  Expected to find: $needle"
        echo "  In: $haystack"
        ((FAIL++)) || true
    fi
}

assert_true() {
    local value="$1" test_name="$2"
    ((TOTAL++)) || true

    if [[ "$value" == "true" ]] || [[ "$value" == "1" ]]; then
        echo -e "${GREEN}✓${RESET} $test_name"
        ((PASS++)) || true
    else
        echo -e "${RED}✗${RESET} $test_name"
        echo "  Expected: true"
        echo "  Got: $value"
        ((FAIL++)) || true
    fi
}

assert_false() {
    local value="$1" test_name="$2"
    ((TOTAL++)) || true

    if [[ "$value" == "false" ]] || [[ "$value" == "0" ]]; then
        echo -e "${GREEN}✓${RESET} $test_name"
        ((PASS++)) || true
    else
        echo -e "${RED}✗${RESET} $test_name"
        echo "  Expected: false"
        echo "  Got: $value"
        ((FAIL++)) || true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SUITE
# ═══════════════════════════════════════════════════════════════════════════════

echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  Success Rate Constraints Test Suite                                 ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo ""

setup_test
source "$SCRIPT_DIR/lib/success-rate-constraints.sh"

# ─── Test 1: Cold start (no events) ──────────────────────────────────────────
echo "▸ Test 1: compute_rolling_success_rate (cold start)"
rate=$(compute_rolling_success_rate "/nonexistent/events.jsonl")
sr=$(echo "$rate" | jq -r '.success_rate')
assert_equals "100" "$sr" "  Returns 100% success rate when no events exist"

# ─── Test 2: Success rate from real events ────────────────────────────────────
echo ""
echo "▸ Test 2: compute_rolling_success_rate (real events)"
events_file="${HOME}/.shipwright/events.jsonl"
mkdir -p "$(dirname "$events_file")"
# Create 10 events: 7 successes, 3 failures (using current time)
now_epoch=$(date +%s)
now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for i in {1..7}; do
    echo "{\"ts\":\"${now_ts}\",\"ts_epoch\":${now_epoch},\"type\":\"pipeline.completed\",\"result\":\"success\",\"complexity\":5}" >> "$events_file"
done
for i in {1..3}; do
    echo "{\"ts\":\"${now_ts}\",\"ts_epoch\":${now_epoch},\"type\":\"pipeline.completed\",\"result\":\"failure\",\"complexity\":5}" >> "$events_file"
done

rate=$(compute_rolling_success_rate "$events_file")
sr=$(echo "$rate" | jq -r '.success_rate')
samples=$(echo "$rate" | jq -r '.samples')
assert_equals "70" "$sr" "  Correctly calculates 70% success rate"
assert_equals "10" "$samples" "  Correctly counts 10 samples"

# ─── Test 3: get_constraint_level with heavy constraints (35% SR) ────────────
echo ""
echo "▸ Test 3: get_constraint_level (35% - heavy constraints)"
level_data=$(get_constraint_level 35)
level=$(echo "$level_data" | jq -r '.level')
should_defer=$(echo "$level_data" | jq -r '.should_defer')
assert_equals "heavy" "$level" "  Returns 'heavy' constraint level for 35% SR"
assert_true "$should_defer" "  should_defer is true"

# ─── Test 4: get_constraint_level with moderate constraints (50% SR) ─────────
echo ""
echo "▸ Test 4: get_constraint_level (50% - moderate constraints)"
level_data=$(get_constraint_level 50)
level=$(echo "$level_data" | jq -r '.level')
assert_equals "none" "$level" "  Returns 'none' constraint level for 50% SR (between thresholds)"

# ─── Test 5: get_constraint_level with recovery (75% SR) ─────────────────────
echo ""
echo "▸ Test 5: get_constraint_level (75% - recovery)"
level_data=$(get_constraint_level 75)
level=$(echo "$level_data" | jq -r '.level')
should_defer=$(echo "$level_data" | jq -r '.should_defer')
assert_equals "none" "$level" "  Returns 'none' for 75% SR (above recovery threshold)"
assert_false "$should_defer" "  should_defer is false"

# ─── Test 6: should_defer_issue with high complexity + heavy constraints ─────
echo ""
echo "▸ Test 6: should_defer_issue (complexity 5, heavy)"
defer=$(should_defer_issue 5 heavy)
should_defer=$(echo "$defer" | jq -r '.should_defer')
assert_true "$should_defer" "  Defers complexity 5 when heavy constraints active"

# ─── Test 7: should_defer_issue with complexity at min threshold ──────────────
echo ""
echo "▸ Test 7: should_defer_issue (complexity 3, heavy - at minimum)"
defer=$(should_defer_issue 3 heavy)
should_defer=$(echo "$defer" | jq -r '.should_defer')
assert_false "$should_defer" "  Does NOT defer complexity 3 (within always-allowed)"

# ─── Test 8: should_defer_issue with complexity below min threshold ───────────
echo ""
echo "▸ Test 8: should_defer_issue (complexity 1, heavy - below minimum)"
defer=$(should_defer_issue 1 heavy)
should_defer=$(echo "$defer" | jq -r '.should_defer')
assert_false "$should_defer" "  Does NOT defer complexity 1 (well below minimum)"

# ─── Test 9: should_defer_issue with moderate constraints ──────────────────────
echo ""
echo "▸ Test 9: should_defer_issue (complexity 8, moderate)"
defer=$(should_defer_issue 8 moderate)
should_defer=$(echo "$defer" | jq -r '.should_defer')
assert_true "$should_defer" "  Defers complexity 8 (> 7) when moderate constraints"

# ─── Test 10: should_defer_issue with moderate + low complexity ────────────────
echo ""
echo "▸ Test 10: should_defer_issue (complexity 6, moderate)"
defer=$(should_defer_issue 6 moderate)
should_defer=$(echo "$defer" | jq -r '.should_defer')
assert_false "$should_defer" "  Does NOT defer complexity 6 (≤ 7) with moderate"

# ─── Test 11: should_defer_issue with no constraints ───────────────────────────
echo ""
echo "▸ Test 11: should_defer_issue (any complexity, none)"
defer=$(should_defer_issue 10 none)
should_defer=$(echo "$defer" | jq -r '.should_defer')
assert_false "$should_defer" "  Never defers when constraint level is 'none'"

# ─── Test 12: get_iteration_cap with heavy constraints ────────────────────────
echo ""
echo "▸ Test 12: get_iteration_cap (heavy)"
cap=$(get_iteration_cap heavy)
assert_equals "10" "$cap" "  Heavy constraints cap iterations at 10"

# ─── Test 13: get_iteration_cap with moderate constraints ──────────────────────
echo ""
echo "▸ Test 13: get_iteration_cap (moderate)"
cap=$(get_iteration_cap moderate)
assert_equals "15" "$cap" "  Moderate constraints cap iterations at 15"

# ─── Test 14: get_iteration_cap with no constraints ──────────────────────────
echo ""
echo "▸ Test 14: get_iteration_cap (none)"
cap=$(get_iteration_cap none)
assert_equals "20" "$cap" "  No constraints use default 20 iterations"

# ─── Test 15: constrain_template downgrade (full → hotfix) ───────────────────
echo ""
echo "▸ Test 15: constrain_template (full → hotfix with heavy)"
template=$(constrain_template full heavy)
assert_equals "hotfix" "$template" "  'full' downgraded to 'hotfix' with heavy constraints"

# ─── Test 16: constrain_template downgrade (standard → fast) ────────────────────
echo ""
echo "▸ Test 16: constrain_template (standard → fast with heavy)"
template=$(constrain_template standard heavy)
assert_equals "fast" "$template" "  'standard' downgraded to 'fast' with heavy constraints"

# ─── Test 17: constrain_template no downgrade (no constraints) ────────────────────
echo ""
echo "▸ Test 17: constrain_template (no downgrade with none)"
template=$(constrain_template full none)
assert_equals "full" "$template" "  'full' not downgraded when no constraints"

# ─── Test 18: save_constraint_state (persistence) ────────────────────────────
echo ""
echo "▸ Test 18: save_constraint_state (state file)"
save_constraint_state heavy
state_file="${HOME}/.shipwright/optimization/daemon-tuning.json"
if [[ -f "$state_file" ]]; then
    saved_level=$(jq -r '.last_constraint_level' "$state_file")
    assert_equals "heavy" "$saved_level" "  State file persists constraint level"
else
    echo -e "${RED}✗${RESET}  State file not created"
    ((FAIL++)) || true
fi
((TOTAL++)) || true

# ─── Test 19: analyze_success_rate_constraints (integration) ─────────────────
echo ""
echo "▸ Test 19: analyze_success_rate_constraints (disabled by default)"
result=$(analyze_success_rate_constraints "$events_file" "/nonexistent/config.json")
enabled=$(echo "$result" | jq -r '.enabled')
assert_false "$enabled" "  Feature is disabled by default (enabled=false)"

# ─── Test 20: Config loading with enabled flag ────────────────────────────────
echo ""
echo "▸ Test 20: Config loading (enabled=true)"
config_file="${HOME}/.claude/daemon-config.json"
mkdir -p "$(dirname "$config_file")"
cat > "$config_file" << 'EOF'
{
  "success_rate_constraints": {
    "enabled": true,
    "window_size": 30,
    "constraint_threshold_low": 40,
    "constraint_threshold_med": 60,
    "recovery_threshold": 70
  }
}
EOF
result=$(analyze_success_rate_constraints "$events_file" "$config_file")
enabled=$(echo "$result" | jq -r '.enabled')
assert_true "$enabled" "  Feature enabled via config"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║  Test Results                                                        ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo ""
echo -e "Total:  ${TOTAL}"
echo -e "Passed: ${GREEN}${PASS}${RESET}"
echo -e "Failed: ${RED}${FAIL}${RESET}"
echo ""

teardown_test

# Exit with appropriate code
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
