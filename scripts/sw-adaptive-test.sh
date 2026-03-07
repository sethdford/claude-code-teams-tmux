#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright adaptive test — Validate data-driven pipeline tuning         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-adaptive-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Create empty events file
    touch "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "Shipwright Adaptive Tests"

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help shows SUBCOMMANDS" "$output" "SUBCOMMANDS"
assert_contains "help mentions get" "$output" "get"
assert_contains "help mentions train" "$output" "train"
assert_contains "help mentions profile" "$output" "profile"

# ─── Test 2: version command ────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" version 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "version exits 0"
else
    assert_fail "version exits 0" "exit code: $rc"
fi
assert_contains "version output contains version string" "$output" "sw-adaptive"

# ─── Test 3: unknown command exits non-zero ─────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 4: get with default value ─────────────────────────────────────────
echo ""
echo -e "${DIM}  get command${RESET}"

# With no events data, get should return the default value
output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" get timeout --default 300 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "get timeout with default exits 0"
else
    assert_fail "get timeout with default exits 0" "exit code: $rc"
fi

# ─── Test 5: profile command ────────────────────────────────────────────────
echo ""
echo -e "${DIM}  profile command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" profile 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "profile exits 0"
else
    assert_fail "profile exits 0" "exit code: $rc"
fi

# ─── Test 6: reset command ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  reset command${RESET}"

output=$(bash "$SCRIPT_DIR/sw-adaptive.sh" reset 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "reset exits 0"
else
    assert_fail "reset exits 0" "exit code: $rc"
fi

# ─── Test 7: source guard pattern ───────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-adaptive.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SCRIPT_DIR/sw-adaptive.sh"; then
    assert_pass "Has source guard pattern"
else
    assert_fail "Has source guard pattern"
fi

# ─── Test 8: percentile, mean, median statistical functions ───────────────────
echo ""
echo -e "${DIM}  statistical functions${RESET}"
if grep -qE '^percentile\(\)|^mean\(\)|^median\(\)' "$SCRIPT_DIR/sw-adaptive.sh"; then
    assert_pass "percentile, mean, median functions defined in source"
else
    assert_fail "percentile, mean, median functions defined in source"
fi
m=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
mean "[1, 2, 3, 4, 5]"
' 2>/dev/null)
if [[ -n "$m" && "$m" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    assert_pass "mean returns numeric value (avg of 1-5 is 3)"
else
    assert_fail "mean returns numeric value" "got: $m"
fi
# percentile/median use jq --arg for p; test via get_timeout which uses them internally

# ─── Test 9: get_timeout with and without event data ──────────────────────────
echo ""
echo -e "${DIM}  get_timeout / get_iterations / get_model${RESET}"
timeout_def=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
get_timeout "build" "." "1800"
' 2>/dev/null)
if [[ -n "$timeout_def" && "$timeout_def" =~ ^[0-9]+$ ]]; then
    assert_pass "get_timeout returns number (default with no events)"
else
    assert_fail "get_timeout returns number" "got: $timeout_def"
fi
iter_val=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
get_iterations 5 "build" "10"
' 2>/dev/null)
if [[ -n "$iter_val" && "$iter_val" =~ ^[0-9]+$ ]]; then
    assert_pass "get_iterations returns number"
else
    assert_fail "get_iterations returns number" "got: $iter_val"
fi
model_val=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
get_model "build" "opus"
' 2>/dev/null)
if [[ -n "$model_val" && "$model_val" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    assert_pass "get_model returns valid model name"
else
    assert_fail "get_model returns valid model name" "got: $model_val"
fi

# ─── Test 10: train subcommand with mock events data ──────────────────────────
echo ""
echo -e "${DIM}  train subcommand${RESET}"
# Add mock events matching pipeline schema (stage.completed, pipeline.completed, model.outcome)
for i in 1 2 3 4 5; do
    echo "{\"ts\":\"2024-01-0${i}T12:00:00Z\",\"type\":\"stage.completed\",\"stage\":\"build\",\"duration_s\":$((i * 120)),\"issue\":1}"
done >> "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
for i in 1 2 3 4 5; do
    echo "{\"ts\":\"2024-01-0${i}T12:05:00Z\",\"type\":\"pipeline.completed\",\"issue\":1,\"result\":\"success\",\"duration_s\":600,\"self_heal_count\":$((i-1)),\"iterations\":$i}"
done >> "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
for i in 1 2 3 4 5; do
    echo "{\"ts\":\"2024-01-0${i}T12:06:00Z\",\"type\":\"model.outcome\",\"stage\":\"build\",\"model\":\"opus\",\"success\":true,\"issue\":1}"
done >> "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
train_out=$(bash "$SCRIPT_DIR/sw-adaptive.sh" train --repo "$SCRIPT_DIR" 2>&1) || true
if [[ "$train_out" == *"trained"* ]] || [[ "$train_out" == *"Models"* ]] || [[ "$train_out" == *"Training"* ]] || [[ -f "$TEST_TEMP_DIR/home/.shipwright/adaptive-models.json" ]]; then
    assert_pass "train subcommand runs with mock events"
else
    assert_fail "train subcommand runs with mock events" "out: ${train_out:0:100}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# ADAPTIVE TIMEOUT ENGINE TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  Adaptive Timeout Engine${RESET}"

# ─── Test 11: _stage_default_timeout returns known defaults ──────────────────
default_build=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
_stage_default_timeout "build"
' 2>/dev/null)
if [[ "$default_build" == "1800" ]]; then
    assert_pass "_stage_default_timeout returns 1800 for build"
else
    assert_fail "_stage_default_timeout returns 1800 for build" "got: $default_build"
fi

default_test=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
_stage_default_timeout "test"
' 2>/dev/null)
if [[ "$default_test" == "900" ]]; then
    assert_pass "_stage_default_timeout returns 900 for test"
else
    assert_fail "_stage_default_timeout returns 900 for test" "got: $default_test"
fi

# ─── Test 12: aggregate_stage_durations with no data ─────────────────────────
agg_empty=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
aggregate_stage_durations "build" "" 30
' 2>/dev/null)
agg_samples=$(echo "$agg_empty" | jq '.samples' 2>/dev/null || echo "err")
if [[ "$agg_samples" == "0" ]]; then
    assert_pass "aggregate_stage_durations returns 0 samples when no data"
else
    assert_fail "aggregate_stage_durations returns 0 samples" "got: $agg_samples"
fi
agg_conf=$(echo "$agg_empty" | jq -r '.confidence' 2>/dev/null || echo "err")
if [[ "$agg_conf" == "low" ]]; then
    assert_pass "aggregate_stage_durations returns low confidence with no data"
else
    assert_fail "aggregate_stage_durations returns low confidence" "got: $agg_conf"
fi

# ─── Test 13: calculate_adaptive_timeout returns default with low confidence ──
calc_default=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
calculate_adaptive_timeout "build" "" "1.2"
' 2>/dev/null)
if [[ "$calc_default" == "1800" ]]; then
    assert_pass "calculate_adaptive_timeout returns default with no data"
else
    assert_fail "calculate_adaptive_timeout returns default" "got: $calc_default"
fi

# ─── Test 14: aggregate_stage_durations with JSONL event data ────────────────
# Add 15 stage.completed events for build stage (above MIN_CONFIDENCE_SAMPLES=10)
echo ""
echo -e "${DIM}  Adaptive timeout with event data${RESET}"
for i in $(seq 1 15); do
    echo "{\"ts\":\"2026-03-0${i}T12:00:00Z\",\"ts_epoch\":$(date +%s),\"type\":\"stage.completed\",\"stage\":\"build\",\"duration_s\":$((60 + i * 10))}"
done >> "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

agg_data=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
aggregate_stage_durations "build" "" 30
' 2>/dev/null)
agg_data_samples=$(echo "$agg_data" | jq '.samples' 2>/dev/null || echo "0")
if [[ "$agg_data_samples" -ge 10 ]]; then
    assert_pass "aggregate_stage_durations finds events ($agg_data_samples samples)"
else
    assert_fail "aggregate_stage_durations finds events" "got: $agg_data_samples samples"
fi

agg_data_p95=$(echo "$agg_data" | jq '.p95' 2>/dev/null || echo "0")
if [[ -n "$agg_data_p95" ]] && [[ "$agg_data_p95" != "0" ]] && [[ "$agg_data_p95" != "null" ]]; then
    assert_pass "aggregate_stage_durations computes non-zero P95 ($agg_data_p95)"
else
    assert_fail "aggregate_stage_durations computes non-zero P95" "got: $agg_data_p95"
fi

# ─── Test 15: calculate_adaptive_timeout with sufficient data ────────────────
calc_adaptive=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
calculate_adaptive_timeout "build" "" "1.2"
' 2>/dev/null)
if [[ "$calc_adaptive" =~ ^[0-9]+$ ]] && [[ "$calc_adaptive" -ge 60 ]] && [[ "$calc_adaptive" -le 7200 ]]; then
    assert_pass "calculate_adaptive_timeout returns bounded value ($calc_adaptive)"
else
    assert_fail "calculate_adaptive_timeout returns bounded value" "got: $calc_adaptive"
fi

# ─── Test 16: should_adjust_timeouts returns 0 when never adjusted ───────────
echo ""
echo -e "${DIM}  Timeout adjustment trigger${RESET}"
adj_rc=0
ADAPTIVE_THRESHOLDS_ENABLED=true \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c 'source "'"$SCRIPT_DIR"'/sw-adaptive.sh" 2>/dev/null; should_adjust_timeouts' 2>/dev/null || adj_rc=$?
if [[ "$adj_rc" -eq 0 ]]; then
    assert_pass "should_adjust_timeouts returns 0 when never adjusted"
else
    assert_fail "should_adjust_timeouts returns 0 when never adjusted" "rc=$adj_rc"
fi

# ─── Test 17: should_adjust_timeouts returns 1 when recently adjusted ────────
echo '{"last_adjustment_epoch":'"$(date +%s)"'}' > "$TEST_TEMP_DIR/home/.shipwright/adaptive-state.json"
adj_rc2=0
ADAPTIVE_THRESHOLDS_ENABLED=true \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c 'source "'"$SCRIPT_DIR"'/sw-adaptive.sh" 2>/dev/null; should_adjust_timeouts' 2>/dev/null || adj_rc2=$?
if [[ "$adj_rc2" -eq 1 ]]; then
    assert_pass "should_adjust_timeouts returns 1 when recently adjusted"
else
    assert_fail "should_adjust_timeouts returns 1 when recently adjusted" "rc=$adj_rc2"
fi

# ─── Test 18: trigger_timeout_adjustment writes state files ──────────────────
ADAPTIVE_THRESHOLDS_ENABLED=true \
    HOME="$TEST_TEMP_DIR/home" \
    bash -c 'source "'"$SCRIPT_DIR"'/sw-adaptive.sh" 2>/dev/null; trigger_timeout_adjustment' 2>/dev/null || true
if [[ -f "$TEST_TEMP_DIR/home/.shipwright/optimization/stage-durations.json" ]]; then
    assert_pass "trigger_timeout_adjustment creates stage-durations.json"
else
    assert_fail "trigger_timeout_adjustment creates stage-durations.json"
fi
if [[ -f "$TEST_TEMP_DIR/home/.shipwright/timeout-tuning-state.json" ]]; then
    assert_pass "trigger_timeout_adjustment creates timeout-tuning-state.json"
else
    assert_fail "trigger_timeout_adjustment creates timeout-tuning-state.json"
fi

# Validate stage-durations.json has stages key
dur_stages=$(jq -r '.stages | keys | length' "$TEST_TEMP_DIR/home/.shipwright/optimization/stage-durations.json" 2>/dev/null || echo "0")
if [[ "$dur_stages" -gt 0 ]]; then
    assert_pass "stage-durations.json contains stage entries ($dur_stages stages)"
else
    assert_fail "stage-durations.json contains stage entries" "got: $dur_stages"
fi

# ─── Test 19: show timeouts subcommand ───────────────────────────────────────
echo ""
echo -e "${DIM}  show timeouts subcommand${RESET}"
show_out=$(bash "$SCRIPT_DIR/sw-adaptive.sh" show timeouts 2>&1) || true
if [[ "$show_out" == *"Stage"* ]] && [[ "$show_out" == *"Timeout"* ]] && [[ "$show_out" == *"build"* ]]; then
    assert_pass "show timeouts displays formatted table"
else
    assert_fail "show timeouts displays formatted table" "out: ${show_out:0:100}"
fi

# ─── Test 20: resolve_stage_timeout override chain ───────────────────────────
echo ""
echo -e "${DIM}  resolve_stage_timeout override chain${RESET}"

# Test env var override (level 2)
env_timeout=$(cd "$SCRIPT_DIR" && HOME="$TEST_TEMP_DIR/home" SW_BUILD_TIMEOUT=999 bash -c '
SCRIPT_DIR="'"$SCRIPT_DIR"'"
source "$SCRIPT_DIR/lib/daemon-adaptive.sh" 2>/dev/null || true
# Source the function if available
if type resolve_stage_timeout >/dev/null 2>&1; then
    resolve_stage_timeout "build"
else
    echo "fn_missing"
fi
' 2>/dev/null)
if [[ "$env_timeout" == "999" ]]; then
    assert_pass "resolve_stage_timeout honors SW_BUILD_TIMEOUT env var"
elif [[ "$env_timeout" == "fn_missing" ]]; then
    assert_fail "resolve_stage_timeout honors env var" "function not found"
else
    assert_fail "resolve_stage_timeout honors env var" "got: $env_timeout"
fi

# Test CLI override (level 1)
cli_timeout=$(cd "$SCRIPT_DIR" && HOME="$TEST_TEMP_DIR/home" STAGE_TIMEOUT_OVERRIDE=500 SW_BUILD_TIMEOUT=999 bash -c '
SCRIPT_DIR="'"$SCRIPT_DIR"'"
source "$SCRIPT_DIR/lib/daemon-adaptive.sh" 2>/dev/null || true
if type resolve_stage_timeout >/dev/null 2>&1; then
    resolve_stage_timeout "build"
else
    echo "fn_missing"
fi
' 2>/dev/null)
if [[ "$cli_timeout" == "500" ]]; then
    assert_pass "resolve_stage_timeout CLI override beats env var"
else
    assert_fail "resolve_stage_timeout CLI override beats env var" "got: $cli_timeout"
fi

# Test default fallback (level 5)
default_timeout=$(cd "$SCRIPT_DIR" && HOME="$TEST_TEMP_DIR/home" ADAPTIVE_THRESHOLDS_ENABLED=false bash -c '
SCRIPT_DIR="'"$SCRIPT_DIR"'"
source "$SCRIPT_DIR/lib/daemon-adaptive.sh" 2>/dev/null || true
if type resolve_stage_timeout >/dev/null 2>&1; then
    resolve_stage_timeout "build"
else
    echo "fn_missing"
fi
' 2>/dev/null)
if [[ "$default_timeout" == "1800" ]]; then
    assert_pass "resolve_stage_timeout falls back to default (1800)"
else
    assert_fail "resolve_stage_timeout falls back to default" "got: $default_timeout"
fi

# ─── Test 21: bounds clamping (MIN_TIMEOUT / MAX_TIMEOUT) ───────────────────
echo ""
echo -e "${DIM}  Bounds clamping${RESET}"
clamp_result=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/sw-adaptive.sh" 2>/dev/null
# Test that calculate_adaptive_timeout returns within bounds
result=$(calculate_adaptive_timeout "intake" "" "1.2")
if [[ "$result" -ge 60 ]] && [[ "$result" -le 7200 ]]; then
    echo "bounded"
else
    echo "out_of_bounds:$result"
fi
' 2>/dev/null)
if [[ "$clamp_result" == "bounded" ]]; then
    assert_pass "calculate_adaptive_timeout respects MIN/MAX bounds"
else
    assert_fail "calculate_adaptive_timeout respects bounds" "got: $clamp_result"
fi

# ─── Test 22: adjust subcommand forces recalculation ─────────────────────────
echo ""
echo -e "${DIM}  adjust subcommand${RESET}"
adjust_out=$(bash "$SCRIPT_DIR/sw-adaptive.sh" adjust 2>&1) || true
if [[ -f "$TEST_TEMP_DIR/home/.shipwright/optimization/stage-durations.json" ]]; then
    assert_pass "adjust subcommand creates stage-durations.json"
else
    assert_fail "adjust subcommand creates stage-durations.json"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
