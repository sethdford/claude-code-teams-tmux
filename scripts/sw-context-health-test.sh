#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright context-health test — Real-time context health monitor tests ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# Source dependencies (health sources budget internally)
source "$SCRIPT_DIR/lib/compat.sh"
source "$SCRIPT_DIR/lib/context-budget.sh"
source "$SCRIPT_DIR/lib/context-health.sh"

ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"

setup_each() {
    rm -rf "$ARTIFACTS_DIR"
    mkdir -p "$ARTIFACTS_DIR"
    # Initialize budget (800K default)
    context_budget_init 800000 "$ARTIFACTS_DIR" >/dev/null 2>&1 || true
    unset CONTEXT_HEALTH_CRITICAL
    unset SW_LOOP_CONTEXT_ALERT_THRESHOLD
    unset SW_LOOP_CONTEXT_COMPRESS_THRESHOLD
    unset SW_LOOP_CONTEXT_RESTART_THRESHOLD
    # Stub emit_event (captures calls)
    EMIT_LOG="$TEST_TEMP_DIR/emit.log"
    : > "$EMIT_LOG"
    emit_event() { printf '%s\n' "$*" >> "$EMIT_LOG"; }
    export -f emit_event 2>/dev/null || true
}

print_test_header "context-health monitor (issue #399)"

# ─── classify ────────────────────────────────────────────────────────────────
setup_each
out=$(context_health_classify 10 60 80 90)
[[ "$out" == $'green\tcontinue' ]] && assert_pass "classify green at 10%" \
    || assert_fail "classify green at 10%" "got: $out"

out=$(context_health_classify 65 60 80 90)
[[ "$out" == $'yellow\talert' ]] && assert_pass "classify yellow at 65%" \
    || assert_fail "classify yellow" "got: $out"

out=$(context_health_classify 82 60 80 90)
[[ "$out" == $'red\tcompress' ]] && assert_pass "classify red at 82%" \
    || assert_fail "classify red" "got: $out"

out=$(context_health_classify 95 60 80 90)
[[ "$out" == $'critical\trestart_session' ]] && assert_pass "classify critical at 95%" \
    || assert_fail "classify critical" "got: $out"

# Boundary: exactly at threshold
out=$(context_health_classify 90 60 80 90)
[[ "$out" == $'critical\trestart_session' ]] && assert_pass "boundary 90% → critical" \
    || assert_fail "boundary 90%" "got: $out"

# Non-numeric input → green
out=$(context_health_classify "xyz" 60 80 90)
[[ "$out" == $'green\tcontinue' ]] && assert_pass "non-numeric util → green" \
    || assert_fail "non-numeric util" "got: $out"

# ─── thresholds config ───────────────────────────────────────────────────────
setup_each
export SW_LOOP_CONTEXT_ALERT_THRESHOLD=50
export SW_LOOP_CONTEXT_COMPRESS_THRESHOLD=70
export SW_LOOP_CONTEXT_RESTART_THRESHOLD=85
t=$(context_health_thresholds)
[[ "$t" == "50 70 85" ]] && assert_pass "thresholds from env override" \
    || assert_fail "thresholds env override" "got: $t"

setup_each
t=$(context_health_thresholds)
[[ "$t" == "60 80 90" ]] && assert_pass "default thresholds 60/80/90" \
    || assert_fail "default thresholds" "got: $t"

# ─── tick: green path ────────────────────────────────────────────────────────
setup_each
small_prompt="hello world"
json=$(context_health_tick "$small_prompt" "$ARTIFACTS_DIR" 1)
echo "$json" | grep -q '"status":"green"' && assert_pass "tick green for small prompt" \
    || assert_fail "tick green" "got: $json"
[[ -f "$ARTIFACTS_DIR/context-health.json" ]] && assert_pass "snapshot written to disk" \
    || assert_fail "snapshot file missing"
snap_status=$(jq -r '.status' "$ARTIFACTS_DIR/context-health.json" 2>/dev/null)
[[ "$snap_status" == "green" ]] && assert_pass "snapshot status=green" \
    || assert_fail "snapshot status" "got: $snap_status"

# ─── tick: critical path ─────────────────────────────────────────────────────
setup_each
# Force critical: tiny budget makes any prompt huge relative to capacity
context_budget_init 1000 "$ARTIFACTS_DIR" >/dev/null 2>&1
big_prompt=$(printf 'x%.0s' {1..5000})
json=$(context_health_tick "$big_prompt" "$ARTIFACTS_DIR" 3)
echo "$json" | grep -q '"status":"critical"' && assert_pass "tick critical on oversized prompt" \
    || assert_fail "tick critical" "got: $json"

# should_restart returns 0 on critical
if context_health_should_restart "$json"; then
    assert_pass "should_restart=true on critical"
else
    assert_fail "should_restart on critical"
fi

# ─── event emission on non-green ─────────────────────────────────────────────
grep -q "context_health" "$EMIT_LOG" && assert_pass "context_health event emitted on critical" \
    || assert_fail "event not emitted" "log: $(cat "$EMIT_LOG")"

# ─── transition detection ────────────────────────────────────────────────────
setup_each
# First tick: green
context_health_tick "hi" "$ARTIFACTS_DIR" 1 >/dev/null
# Second tick with tiny budget → red/critical
context_budget_init 500 "$ARTIFACTS_DIR" >/dev/null 2>&1
big=$(printf 'y%.0s' {1..2000})
json2=$(context_health_tick "$big" "$ARTIFACTS_DIR" 2)
echo "$json2" | grep -q '"transition":true' && assert_pass "transition flagged on status change" \
    || assert_fail "transition detection" "got: $json2"

# ─── should_restart returns 1 for green ──────────────────────────────────────
setup_each
green_json='{"status":"green","action":"continue"}'
if context_health_should_restart "$green_json"; then
    assert_fail "should_restart green"
else
    assert_pass "should_restart=false on green"
fi

# ─── graceful degradation: missing estimator ─────────────────────────────────
setup_each
# Save and remove the function
_saved_estimate=$(declare -f context_budget_estimate)
unset -f context_budget_estimate
json=$(context_health_tick "anything" "$ARTIFACTS_DIR" 1 2>/dev/null)
echo "$json" | grep -q '"status":"unknown"' && assert_pass "graceful degradation without estimator" \
    || assert_fail "degradation" "got: $json"
# Restore
eval "$_saved_estimate"

# ─── snapshot atomicity: concurrent writes don't corrupt ─────────────────────
setup_each
for i in 1 2 3; do
    context_health_tick "sample $i" "$ARTIFACTS_DIR" "$i" >/dev/null &
done
wait
# Final file must be valid JSON
if jq -e '.status' "$ARTIFACTS_DIR/context-health.json" >/dev/null 2>&1; then
    assert_pass "concurrent snapshot writes remain valid JSON"
else
    assert_fail "concurrent writes corrupted snapshot"
fi

# ─── idempotence: no transition on repeated same-status tick ─────────────────
setup_each
context_health_tick "a" "$ARTIFACTS_DIR" 1 >/dev/null
json=$(context_health_tick "b" "$ARTIFACTS_DIR" 2)
echo "$json" | grep -q '"transition":false' && assert_pass "no transition between same-status ticks" \
    || assert_fail "idempotence" "got: $json"

print_test_results
