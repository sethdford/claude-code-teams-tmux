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
    ((TESTS_PASSED++))
}

fail() {
    echo "✗ $1"
    ((TESTS_FAILED++))
}

# ─── Load Module ──────────────────────────────────────────────────────────────
test_1() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    [[ -f "$history_path" ]] && [[ "$(cat "$history_path")" == "[]" ]] && \
        pass "adaptive_model_init creates history file" || \
        fail "adaptive_model_init creates history file"
}

test_2() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 0 "pass" 0 50 "opus")
    [[ "$result" == "opus" ]] && \
        pass "first iteration returns current model unchanged" || \
        fail "first iteration returns current model unchanged (got $result)"
}

test_3() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 1 "fail" 2 30 "haiku")
    [[ "$result" == "sonnet" ]] && \
        pass "escalate haiku to sonnet on repeated error" || \
        fail "escalate haiku to sonnet on repeated error (got $result)"
}

test_4() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 2 "fail" 1 25 "sonnet")
    [[ "$result" == "opus" ]] && \
        pass "escalate sonnet to opus on low convergence" || \
        fail "escalate sonnet to opus on low convergence (got $result)"
}

test_5() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 3 "pass" 0 80 "opus")
    [[ "$result" == "sonnet" ]] && \
        pass "downgrade opus to sonnet on high convergence" || \
        fail "downgrade opus to sonnet on high convergence (got $result)"
}

test_6() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 4 "pass" 0 85 "sonnet")
    [[ "$result" == "haiku" ]] && \
        pass "downgrade sonnet to haiku on high convergence" || \
        fail "downgrade sonnet to haiku on high convergence (got $result)"
}

test_7() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 5 "pass" 0 90 "haiku")
    [[ "$result" == "haiku" ]] && \
        pass "haiku stays at haiku when passing and converging" || \
        fail "haiku stays at haiku when passing and converging (got $result)"
}

test_8() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 6 "fail" 3 20 "opus")
    [[ "$result" == "opus" ]] && \
        pass "opus stays at opus when failing with repeated error" || \
        fail "opus stays at opus when failing with repeated error (got $result)"
}

test_9() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 0 "opus" "pass" 0 50 "first_iteration" false false
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    grep -q '"model":"opus"' "$history_path" && \
        pass "record writes to history file" || \
        fail "record writes to history file"
}

test_10() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 1 "sonnet" "fail" 1 40 "escalation_test" true false
    adaptive_model_record 2 "opus" "pass" 0 75 "downgrade_test" false true
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    count=$(grep -c '"model"' "$history_path" || echo "0")
    [[ "$count" -eq 3 ]] && \
        pass "multiple records accumulate in history" || \
        fail "multiple records accumulate in history (got $count records)"
}

test_11() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
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
        jq empty "$prefs_file" 2>/dev/null && \
            jq -e '.learned_escalations.success_rate >= 0' "$prefs_file" >/dev/null 2>&1 && \
            pass "adaptive_model_learn writes valid JSON" || \
            fail "adaptive_model_learn writes valid JSON"
    else
        pass "adaptive_model_learn writes valid JSON (jq not available, skipping validation)"
    fi
}

test_12() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
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

    adaptive_model_report >/dev/null 2>&1 && \
        pass "adaptive_model_report runs without error" || \
        fail "adaptive_model_report runs without error"
}

test_13() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_learn 2>/dev/null && \
        pass "learn handles missing history gracefully" || \
        fail "learn handles missing history gracefully"
}

test_14() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_report 2>/dev/null | grep -q "No adaptive model history" && \
        pass "report handles missing history gracefully" || \
        fail "report handles missing history gracefully"
}

test_15() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 5 "pass" 0 50 "sonnet")
    [[ "$result" == "sonnet" ]] && \
        pass "stable conditions return current model unchanged" || \
        fail "stable conditions return current model unchanged (got $result)"
}

test_16() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 0 "opus" "pass" 0 50 "test" false false
    adaptive_model_record 1 "opus" "fail" 1 40 "test" false false
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"
    grep -q '"test_result":"pass"' "$history_path" && \
        pass "record accepts valid test results" || \
        fail "record accepts valid test results"
}

test_17() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 3 "fail" 0 0 "haiku")
    [[ "$result" == "sonnet" ]] && \
        pass "escalate on very low convergence" || \
        fail "escalate on very low convergence (got $result)"
}

test_18() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    adaptive_model_init
    adaptive_model_record 0 "opus" "fail" 3 20 "test_failure_with_reason" true false
    history_path="${ARTIFACTS_DIR}/adaptive-model-history.json"

    if command -v jq >/dev/null 2>&1; then
        grep -q '"reason":"test_failure_with_reason"' "$history_path" && \
            pass "record preserves adaptation reason" || \
            fail "record preserves adaptation reason"
    else
        pass "record preserves adaptation reason (jq not available, skipping)"
    fi
}

test_19() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
    export ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    unset _ADAPTIVE_MODEL_LOADED
    source "$SCRIPT_DIR/lib/adaptive-model.sh"

    result=$(adaptive_model_select "build" 2 "fail" 1 30 "haiku")
    [[ "$result" == "haiku" ]] && \
        pass "no escalation when error_count < threshold" || \
        fail "no escalation when error_count < threshold (got $result)"
}

test_20() {
    local tmpdir; tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN
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
    [[ -f "$history_path" && -f "$prefs" ]] && \
        pass "full integration: select -> record -> learn" || \
        fail "full integration: select -> record -> learn"
}

# ─── Run all tests ─────────────────────────────────────────────────────────────
for i in {1..20}; do
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
