#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-adaptive-model-test.sh — Test Suite for Adaptive Model Selection       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Test Infrastructure ──────────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "✓ $1"
    ((TESTS_PASSED++)) || true
}
fail() {
    echo "✗ $1"
    ((TESTS_FAILED++)) || true
}
# ─── Load Module ──────────────────────────────────────────────────────────────
test_1() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    if [[ -f "$history_path" ]] && [[ "$(cat "$history_path")" == "[]" ]]; then
        pass "adaptive_model_init creates history file"
    else
        fail "adaptive_model_init creates history file"
    fi

    rm -rf "$tmpdir"
}
test_2() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 0 "pass" 0 50 "opus")
    if [[  "$result" == "opus"  ]]; then
        pass "first iteration returns current model unchanged"
    else
        fail "first iteration returns current model unchanged (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_3() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 1 "fail" 2 30 "haiku")
    if [[  "$result" == "sonnet"  ]]; then
        pass "escalate haiku to sonnet on repeated error"
    else
        fail "escalate haiku to sonnet on repeated error (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_4() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 2 "fail" 1 25 "sonnet")
    if [[  "$result" == "opus"  ]]; then
        pass "escalate sonnet to opus on low convergence"
    else
        fail "escalate sonnet to opus on low convergence (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_5() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 3 "pass" 0 80 "opus")
    if [[  "$result" == "sonnet"  ]]; then
        pass "downgrade opus to sonnet on high convergence"
    else
        fail "downgrade opus to sonnet on high convergence (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_6() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 4 "pass" 0 85 "sonnet")
    if [[  "$result" == "haiku"  ]]; then
        pass "downgrade sonnet to haiku on high convergence"
    else
        fail "downgrade sonnet to haiku on high convergence (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_7() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 5 "pass" 0 90 "haiku")
    if [[  "$result" == "haiku"  ]]; then
        pass "haiku stays at haiku when passing and converging"
    else
        fail "haiku stays at haiku when passing and converging (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_8() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 6 "fail" 3 20 "opus")
    if [[  "$result" == "opus"  ]]; then
        pass "opus stays at opus when failing with repeated error"
    else
        fail "opus stays at opus when failing with repeated error (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_9() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 0 "opus" "pass" 0 50 "first_iteration" false false
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    if grep -q '"model".*"opus"' "$history_path"; then
        pass "record writes to history file"
    else
        fail "record writes to history file"
    fi
    rm -rf "$tmpdir"
}
test_10() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 1 "sonnet" "fail" 1 40 "escalation_test" true false
    adaptive_model_record 2 "opus" "pass" 0 75 "downgrade_test" false true
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    count=$(grep -c '"model"' "$history_path" || echo "0")
    if [[  "$count" -eq 2  ]]; then
        pass "multiple records accumulate in history"
    else
        fail "multiple records accumulate in history (got $count records)"
    fi
    rm -rf "$tmpdir"
}
test_11() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    cat > "$history_path" <<'EOF'
[
  {"iteration": 0, "model": "haiku", "test_result": "pass", "escalated": false, "downgraded": false},
  {"iteration": 1, "model": "sonnet", "test_result": "pass", "escalated": true, "downgraded": false},
  {"iteration": 2, "model": "opus", "test_result": "pass", "escalated": true, "downgraded": false}
]
EOF

    prefs_file="${HOME}/.shipwright/optimization/model-preferences.json"
    mkdir -p "$(dirname "$prefs_file")"
    cat > "$prefs_file" <<'EOF'
{
  "version": "1.0",
  "stage_priors": {},
  "learned_escalations": {},
  "learned_downgrades": {},
  "last_updated": ""
}
EOF

    adaptive_model_learn

    if command -v jq >/dev/null 2>&1; then
        if jq empty "$prefs_file" 2>/dev/null && jq -e '.learned_escalations.success_rate >= 0' "$prefs_file" >/dev/null 2>&1; then
            pass "adaptive_model_learn writes valid JSON"
        else
            fail "adaptive_model_learn writes valid JSON"
        fi
    else
        pass "adaptive_model_learn writes valid JSON (jq not available, skipping validation)"
    fi
    rm -rf "$tmpdir"
}
test_12() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    cat > "$history_path" <<'EOF'
[
  {"iteration": 0, "model": "haiku", "test_result": "pass", "reason": "first_iteration"},
  {"iteration": 1, "model": "sonnet", "test_result": "pass", "reason": "escalation", "escalated": true},
  {"iteration": 2, "model": "opus", "test_result": "fail", "reason": "no_change"}
]
EOF

    if adaptive_model_report >/dev/null 2>&1; then
        pass "adaptive_model_report runs without error"
    else
        fail "adaptive_model_report runs without error"
    fi
    rm -rf "$tmpdir"
}
test_13() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    if adaptive_model_learn 2>/dev/null; then
        pass "learn handles missing history gracefully"
    else
        fail "learn handles missing history gracefully"
    fi
    rm -rf "$tmpdir"
}
test_14() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    if adaptive_model_report 2>/dev/null | grep -q "No adaptive model history"; then
        pass "report handles missing history gracefully"
    else
        fail "report handles missing history gracefully"
    fi
    rm -rf "$tmpdir"
}
test_15() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 5 "pass" 0 50 "sonnet")
    if [[  "$result" == "sonnet"  ]]; then
        pass "stable conditions return current model unchanged"
    else
        fail "stable conditions return current model unchanged (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_16() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 0 "opus" "pass" 0 50 "test" false false
    adaptive_model_record 1 "opus" "fail" 1 40 "test" false false
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    if grep -q '"test_result".*"pass"' "$history_path"; then
        pass "record accepts valid test results"
    else
        fail "record accepts valid test results"
    fi
    rm -rf "$tmpdir"
}
test_17() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 3 "fail" 0 0 "haiku")
    if [[  "$result" == "sonnet"  ]]; then
        pass "escalate on very low convergence"
    else
        fail "escalate on very low convergence (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_18() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 0 "opus" "fail" 3 20 "test_failure_with_reason" true false
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"

    if command -v jq >/dev/null 2>&1; then
        if grep -q '"reason".*"test_failure_with_reason"' "$history_path"; then
            pass "record preserves adaptation reason"
        else
            fail "record preserves adaptation reason"
        fi
    else
        pass "record preserves adaptation reason (jq not available, skipping)"
    fi
    rm -rf "$tmpdir"
}
test_19() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 2 "fail" 1 30 "haiku")
    if [[  "$result" == "haiku"  ]]; then
        pass "no escalation when error_count < threshold"
    else
        fail "no escalation when error_count < threshold (got $result)"
    fi
    rm -rf "$tmpdir"
}
test_20() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_select "build" 0 "pass" 0 50 "opus" > /dev/null
    adaptive_model_select "build" 1 "fail" 2 30 "opus" > /dev/null
    adaptive_model_learn 2>/dev/null

    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    prefs="${HOME}/.shipwright/optimization/model-preferences.json"
    if [[  -f "$history_path" && -f "$prefs"  ]]; then
        pass "full integration: select -> record -> learn"
    else
        fail "full integration: select -> record -> learn"
    fi
    rm -rf "$tmpdir"
}

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Tests 21-32: Per-Iteration Loop Model Selection (lib/loop-model-selection.sh) ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

test_21() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"

    loop_model_init "default"
    if [[ "$LOOP_MODEL_STRATEGY" == "default" ]]; then
        pass "loop_model_init sets default strategy"
    else
        fail "loop_model_init sets default strategy (got: $LOOP_MODEL_STRATEGY)"
    fi
    rm -rf "$tmpdir"
}

test_22() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"

    loop_model_init "aggressive"
    if [[ "$LOOP_MODEL_STRATEGY" == "aggressive" ]]; then
        pass "loop_model_init accepts aggressive strategy"
    else
        fail "loop_model_init accepts aggressive strategy (got: $LOOP_MODEL_STRATEGY)"
    fi

    # Invalid strategy should fall back to default
    loop_model_init "invalid_strategy"
    if [[ "$LOOP_MODEL_STRATEGY" == "default" ]]; then
        pass "loop_model_init falls back to default on invalid"
    else
        fail "loop_model_init falls back to default on invalid (got: $LOOP_MODEL_STRATEGY)"
    fi
    rm -rf "$tmpdir"
}

test_23() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"

    # Default strategy with 20 iterations:
    # 1-2 → haiku, 3-16 → sonnet, 17-20 → opus
    local m1 m2 m3 m10 m16 m17 m20
    m1=$(loop_model_for_position 1 20 "default")
    m2=$(loop_model_for_position 2 20 "default")
    m3=$(loop_model_for_position 3 20 "default")
    m10=$(loop_model_for_position 10 20 "default")
    m16=$(loop_model_for_position 16 20 "default")
    m17=$(loop_model_for_position 17 20 "default")
    m20=$(loop_model_for_position 20 20 "default")

    if [[ "$m1" == "haiku" && "$m2" == "haiku" ]]; then
        pass "default routing: iter 1-2 → haiku"
    else
        fail "default routing: iter 1-2 → haiku (got: $m1, $m2)"
    fi
    if [[ "$m3" == "sonnet" && "$m10" == "sonnet" && "$m16" == "sonnet" ]]; then
        pass "default routing: iter 3-16 → sonnet"
    else
        fail "default routing: iter 3-16 → sonnet (got: $m3, $m10, $m16)"
    fi
    if [[ "$m17" == "opus" && "$m20" == "opus" ]]; then
        pass "default routing: iter 17-20 → opus"
    else
        fail "default routing: iter 17-20 → opus (got: $m17, $m20)"
    fi
    rm -rf "$tmpdir"
}

test_24() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"

    # Aggressive strategy with 20 iterations:
    # 1 → haiku, 2-14 → sonnet, 15-20 → opus
    local m1 m2 m14 m15
    m1=$(loop_model_for_position 1 20 "aggressive")
    m2=$(loop_model_for_position 2 20 "aggressive")
    m14=$(loop_model_for_position 14 20 "aggressive")
    m15=$(loop_model_for_position 15 20 "aggressive")

    if [[ "$m1" == "haiku" && "$m2" == "sonnet" && "$m14" == "sonnet" && "$m15" == "opus" ]]; then
        pass "aggressive routing: haiku→sonnet→opus boundaries"
    else
        fail "aggressive routing (got: $m1, $m2, $m14, $m15)"
    fi
    rm -rf "$tmpdir"
}

test_25() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"

    # Conservative strategy with 20 iterations:
    # 1-3 → haiku, 4-18 → sonnet, 19-20 → opus
    local m1 m3 m4 m18 m19 m20
    m1=$(loop_model_for_position 1 20 "conservative")
    m3=$(loop_model_for_position 3 20 "conservative")
    m4=$(loop_model_for_position 4 20 "conservative")
    m18=$(loop_model_for_position 18 20 "conservative")
    m19=$(loop_model_for_position 19 20 "conservative")
    m20=$(loop_model_for_position 20 20 "conservative")

    if [[ "$m1" == "haiku" && "$m3" == "haiku" && "$m4" == "sonnet" && "$m18" == "sonnet" && "$m19" == "opus" && "$m20" == "opus" ]]; then
        pass "conservative routing: haiku→sonnet→opus boundaries"
    else
        fail "conservative routing (got: $m1, $m3, $m4, $m18, $m19, $m20)"
    fi
    rm -rf "$tmpdir"
}

test_26() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"

    # Short loop (3 iterations) should use sonnet for all
    local m1 m2 m3
    m1=$(loop_model_for_position 1 3 "default")
    m2=$(loop_model_for_position 2 3 "default")
    m3=$(loop_model_for_position 3 3 "default")

    if [[ "$m1" == "sonnet" && "$m2" == "sonnet" && "$m3" == "sonnet" ]]; then
        pass "short loop (<=3 iters) uses sonnet for all"
    else
        fail "short loop (<=3 iters) uses sonnet (got: $m1, $m2, $m3)"
    fi
    rm -rf "$tmpdir"
}

test_27() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"
    loop_model_init

    # Stuck detection: not stuck with insufficient data
    STUCK_WINDOW=()
    if ! loop_model_detect_stuck 50; then
        pass "stuck detection: not stuck with 1 data point"
    else
        fail "stuck detection: should not be stuck with 1 data point"
    fi

    # Fill window with identical scores → stuck
    STUCK_WINDOW=()
    loop_model_detect_stuck 50 || true
    loop_model_detect_stuck 52 || true
    if loop_model_detect_stuck 51; then
        pass "stuck detection: stuck with flat scores (50,52,51)"
    else
        fail "stuck detection: should be stuck with flat scores"
    fi
    rm -rf "$tmpdir"
}

test_28() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"
    loop_model_init

    # Not stuck with improving scores
    STUCK_WINDOW=()
    loop_model_detect_stuck 30 || true
    loop_model_detect_stuck 50 || true
    if ! loop_model_detect_stuck 70; then
        pass "stuck detection: not stuck with improving scores"
    else
        fail "stuck detection: should not be stuck with improving scores (30,50,70)"
    fi
    rm -rf "$tmpdir"
}

test_29() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"
    loop_model_init

    # Stuck escalation: sonnet → opus when stuck (iter 3/20 = sonnet tier, escalates to opus)
    STUCK_WINDOW=(50 51)
    local result
    result=$(loop_model_select 3 20 52 "unknown" 0 "sonnet")
    if [[ "$result" == "opus" ]]; then
        pass "stuck escalation: sonnet → opus"
    else
        fail "stuck escalation: sonnet → opus (got: $result)"
    fi
    rm -rf "$tmpdir"
}

test_30() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"
    loop_model_init

    # Error escalation: sonnet → opus with repeated errors and test failure
    STUCK_WINDOW=()
    local result
    result=$(loop_model_select 5 20 40 "false" 4 "sonnet")
    if [[ "$result" == "opus" ]]; then
        pass "error escalation: sonnet → opus on persistent errors"
    else
        fail "error escalation: sonnet → opus (got: $result)"
    fi
    rm -rf "$tmpdir"
}

test_31() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"
    loop_model_init

    # Cost tracking accumulates correctly
    loop_model_track_cost "haiku" 1000 500
    loop_model_track_cost "sonnet" 2000 1000
    loop_model_track_cost "opus" 3000 1500
    loop_model_track_cost "sonnet" 4000 2000

    if [[ "$LOOP_COST_HAIKU_ITERATIONS" -eq 1 && "$LOOP_COST_SONNET_ITERATIONS" -eq 2 && "$LOOP_COST_OPUS_ITERATIONS" -eq 1 ]]; then
        pass "cost tracking: iteration counts per tier"
    else
        fail "cost tracking: iteration counts (h=$LOOP_COST_HAIKU_ITERATIONS s=$LOOP_COST_SONNET_ITERATIONS o=$LOOP_COST_OPUS_ITERATIONS)"
    fi

    if [[ "$LOOP_COST_HAIKU_INPUT" -eq 1000 && "$LOOP_COST_SONNET_INPUT" -eq 6000 && "$LOOP_COST_OPUS_INPUT" -eq 3000 ]]; then
        pass "cost tracking: input tokens per tier"
    else
        fail "cost tracking: input tokens (h=$LOOP_COST_HAIKU_INPUT s=$LOOP_COST_SONNET_INPUT o=$LOOP_COST_OPUS_INPUT)"
    fi

    # Check JSON cost file was written
    if [[ -f "${ARTIFACTS_DIR}/loop-model-costs.json" ]]; then
        pass "cost tracking: JSON cost file written"
    else
        fail "cost tracking: JSON cost file missing"
    fi
    rm -rf "$tmpdir"
}

test_32() {
    local tmpdir; tmpdir=$(mktemp -d)
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _LOOP_MODEL_SELECTION_LOADED
    source "$SCRIPT_DIR/lib/loop-model-selection.sh"
    loop_model_init

    # Summary prints nothing when no data
    local output
    output=$(loop_model_summary 2>&1)
    if [[ -z "$output" ]]; then
        pass "summary: no output when no tracking data"
    else
        fail "summary: should be empty with no data (got: $output)"
    fi

    # Summary prints after tracking
    loop_model_track_cost "haiku" 1000 500
    loop_model_track_cost "sonnet" 2000 1000
    output=$(loop_model_summary 2>&1)
    if echo "$output" | grep -q "Model Usage" && echo "$output" | grep -q "haiku" && echo "$output" | grep -q "sonnet"; then
        pass "summary: prints per-tier breakdown"
    else
        fail "summary: expected Model Usage with haiku and sonnet (got: $output)"
    fi
    rm -rf "$tmpdir"
}

# ─── Run all tests ─────────────────────────────────────────────────────────────
for i in {1..32}; do
    test_$i
done

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────────────────"
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "─────────────────────────────────────────────────────────"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "✓ All tests passed"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
