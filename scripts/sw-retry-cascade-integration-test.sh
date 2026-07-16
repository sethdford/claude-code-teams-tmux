#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright retry-cascade integration test                                ║
# ║  Exercises the REAL run_stage_with_retry seam (pipeline-execution.sh) to  ║
# ║  prove the cost-aware cascade escalates the model on failure, succeeds    ║
# ║  when a capable model is reached, stops on budget, and never leaks the    ║
# ║  MODEL override into a later stage.                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "retry-cascade integration: run_stage_with_retry"

setup_test_env "sw-retry-cascade-int-test"
trap cleanup_test_env EXIT

# ─── Isolated environment ────────────────────────────────────────────────────
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export RETRY_CASCADE_ATTEMPTS_FILE="$ARTIFACTS_DIR/cascade-attempts.tsv"
export RETRY_CASCADE_PATTERNS_FILE="$SCRIPT_DIR/../config/failure-patterns.json"
export DAEMON_CONFIG="$TEST_TEMP_DIR/daemon-config.json"
export COST_FILE="$TEST_TEMP_DIR/costs.json"
export PIPELINE_CONFIG="$TEST_TEMP_DIR/pipeline-config.json"
export ISSUE_NUMBER=0
mkdir -p "$ARTIFACTS_DIR"
echo '{"stages":[],"defaults":{"model":"haiku"}}' > "$PIPELINE_CONFIG"

# Neutralize slow / external dependencies BEFORE sourcing the module so the
# module's fallbacks don't shadow ours.
sleep() { :; }                          # skip exponential backoff in the loop
classify_error() { echo "infrastructure"; }
emit_event() { :; }
info() { :; }
warn() { :; }
error() { :; }

# Load compat + cascade + the real execution module under test.
_COMPAT_LOADED=""
source "$SCRIPT_DIR/lib/compat.sh"
# pipeline-execution.sh sources retry-cascade.sh itself via SCRIPT_DIR.
source "$SCRIPT_DIR/lib/pipeline-execution.sh"

# pipeline-execution.sh sources helpers.sh, which installs the real
# info/warn/error/emit_event. Re-stub AFTER sourcing to keep test output quiet
# and to guarantee backoff never actually sleeps.
sleep() { :; }
info() { :; }
warn() { :; }
error() { :; }
emit_event() { :; }

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "escalation → success when a capable model is reached"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
echo '{"retry_cascade":{"enabled":true}}' > "$DAEMON_CONFIG"

# Record every model the stage runs under. The stage only "passes" on opus,
# forcing the cascade to walk haiku(initial) → sonnet → opus.
STAGE_MODELS=""
stage_build() {
    STAGE_MODELS="${STAGE_MODELS}${MODEL:-haiku} "
    # Emit a retryable (transient) error so the cascade is allowed to escalate.
    echo "Error: connection reset by peer (ECONNRESET)" > "$ARTIFACTS_DIR/build-results.log"
    # Fail unless we've been escalated to opus.
    [[ "${MODEL:-haiku}" == "opus" ]]
}

MODEL=""
if run_stage_with_retry build; then
    assert_pass "stage succeeds after cascade reaches opus"
else
    assert_fail "stage succeeds after cascade reaches opus"
fi
# Initial attempt uses the caller's model (empty → haiku default recorded),
# then sonnet, then opus.
assert_contains "cascade tried sonnet" "$STAGE_MODELS" "sonnet"
assert_contains "cascade tried opus" "$STAGE_MODELS" "opus"
assert_eq "MODEL restored to original after success" "" "${MODEL}"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "no MODEL leak into a subsequent stage"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
SECOND_MODEL="unset"
stage_review() { SECOND_MODEL="${MODEL:-<empty>}"; return 0; }
MODEL="sonnet"   # caller-provided baseline for this stage
run_stage_with_retry review || true
assert_eq "later stage sees caller MODEL, not a leaked escalation" "sonnet" "$SECOND_MODEL"
assert_eq "MODEL still the caller value after stage" "sonnet" "${MODEL}"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "budget cap stops the cascade (stage ultimately fails)"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
# Cap so low that even the first escalation's estimate exceeds it → rc 14.
echo '{"retry_cascade":{"enabled":true,"max_cascade_cost_per_stage_usd":0.0001}}' > "$DAEMON_CONFIG"
BUDGET_CALLS=0
stage_build() {
    BUDGET_CALLS=$((BUDGET_CALLS + 1))
    echo "Error: request timed out (ETIMEDOUT)" > "$ARTIFACTS_DIR/build-results.log"
    return 1  # always fails; retryable error so only budget can stop the cascade
}
MODEL=""
if run_stage_with_retry build; then
    assert_fail "budget-capped cascade should fail the stage"
else
    assert_pass "budget-capped cascade fails the stage"
fi
# Initial attempt runs once; cascade refuses to escalate (budget) so the stage
# is not retried under a more expensive model.
assert_eq "stage invoked once before budget stop" "1" "$BUDGET_CALLS"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "non-retryable failure fails fast without escalation"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
echo '{"retry_cascade":{"enabled":true}}' > "$DAEMON_CONFIG"
NR_CALLS=0
stage_build() {
    NR_CALLS=$((NR_CALLS + 1))
    echo "AssertionError: expected 1 but got 2" > "$ARTIFACTS_DIR/build-results.log"
    return 1
}
MODEL=""
if run_stage_with_retry build; then
    assert_fail "non-retryable failure should not succeed"
else
    assert_pass "non-retryable failure fails fast"
fi
assert_eq "no escalation retry on non-retryable error" "1" "$NR_CALLS"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "disabled cascade preserves legacy single-attempt behavior"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
echo '{}' > "$DAEMON_CONFIG"   # cascade off
LEGACY_CALLS=0
stage_build() { LEGACY_CALLS=$((LEGACY_CALLS + 1)); return 1; }
MODEL=""
run_stage_with_retry build || true
# retries default to 0 in config → exactly one attempt, no cascade extension.
assert_eq "disabled: single attempt (no cascade retries)" "1" "$LEGACY_CALLS"

print_test_results
