#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright retry-cascade test — cost-aware model retry cascade unit tests ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "retry-cascade: Cost-Aware Model Retry Cascade"

setup_test_env "sw-retry-cascade-test"
trap cleanup_test_env EXIT

# Isolate cascade state + config into the temp dir.
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export RETRY_CASCADE_ATTEMPTS_FILE="$ARTIFACTS_DIR/cascade-attempts.tsv"
export RETRY_CASCADE_PATTERNS_FILE="$SCRIPT_DIR/../config/failure-patterns.json"
export DAEMON_CONFIG="$TEST_TEMP_DIR/daemon-config.json"
export COST_FILE="$TEST_TEMP_DIR/costs.json"
mkdir -p "$ARTIFACTS_DIR"
echo '{}' > "$DAEMON_CONFIG"

# Load compat (for _smart_int / _smart_float) then the module under test.
_COMPAT_LOADED=""
source "$SCRIPT_DIR/lib/compat.sh"
source "$SCRIPT_DIR/lib/retry-cascade.sh"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_enabled — default off, config-driven"
# ═══════════════════════════════════════════════════════════════════════════════

if cascade_enabled; then assert_fail "disabled by default"; else assert_pass "disabled by default"; fi

echo '{"retry_cascade":{"enabled":true}}' > "$DAEMON_CONFIG"
if cascade_enabled; then assert_pass "enabled when config true"; else assert_fail "enabled when config true"; fi
echo '{}' > "$DAEMON_CONFIG"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_model_order — default and override"
# ═══════════════════════════════════════════════════════════════════════════════

assert_eq "default order haiku sonnet opus" "haiku sonnet opus" "$(cascade_model_order)"

echo '{"retry_cascade":{"model_order":["sonnet","opus"]}}' > "$DAEMON_CONFIG"
assert_eq "global model_order override" "sonnet opus" "$(cascade_model_order)"

echo '{"retry_cascade":{"model_order":["sonnet","opus"],"per_stage_overrides":{"build":{"model_order":["haiku","opus"]}}}}' > "$DAEMON_CONFIG"
assert_eq "per-stage override wins" "haiku opus" "$(cascade_model_order build)"
assert_eq "non-overridden stage uses global" "sonnet opus" "$(cascade_model_order review)"
echo '{}' > "$DAEMON_CONFIG"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_models_after — only models strictly after current"
# ═══════════════════════════════════════════════════════════════════════════════

assert_eq "after haiku -> sonnet opus" "sonnet opus" "$(cascade_models_after build haiku)"
assert_eq "after sonnet -> opus" "opus" "$(cascade_models_after build sonnet)"
assert_eq "after opus -> empty (never retries downward)" "" "$(cascade_models_after build opus)"
assert_eq "normalizes claude-opus-4-6 -> empty" "" "$(cascade_models_after build claude-opus-4-6)"
assert_eq "normalizes claude-haiku alias" "sonnet opus" "$(cascade_models_after build claude-haiku-4-5)"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_classify_failure — retryable vs non-retryable"
# ═══════════════════════════════════════════════════════════════════════════════

assert_eq "permission denied -> non-retryable" "non-retryable" \
    "$(cascade_classify_failure 'Error: Permission denied opening file' 1)"
assert_eq "file not found -> non-retryable" "non-retryable" \
    "$(cascade_classify_failure 'ENOENT: no such file or directory' 1)"
assert_eq "assertion failure -> non-retryable" "non-retryable" \
    "$(cascade_classify_failure 'AssertionError: Expected 4 but got 5' 1)"
assert_eq "rate limit -> retryable" "retryable" \
    "$(cascade_classify_failure 'HTTP 429 Too Many Requests' 1)"
assert_eq "timeout -> retryable" "retryable" \
    "$(cascade_classify_failure 'request timed out after 60s (ETIMEDOUT)' 1)"
assert_eq "truncation -> retryable" "retryable" \
    "$(cascade_classify_failure 'response truncated: max_tokens reached' 1)"
assert_eq "unknown (file exists, no match) -> non-retryable (budget-safe)" "non-retryable" \
    "$(cascade_classify_failure 'some totally unrecognized banana message' 1)"

# non_retryable wins ties over retryable
assert_eq "non-retryable wins over co-occurring retryable" "non-retryable" \
    "$(cascade_classify_failure 'timeout... then Permission denied' 1)"

# Missing patterns file -> defaults to retryable
saved_patterns="$RETRY_CASCADE_PATTERNS_FILE"
RETRY_CASCADE_PATTERNS_FILE="$TEST_TEMP_DIR/nope.json"
assert_eq "missing patterns file -> retryable" "retryable" \
    "$(cascade_classify_failure 'anything' 1 2>/dev/null)"
RETRY_CASCADE_PATTERNS_FILE="$saved_patterns"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_record_attempt + circuit breaker"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
echo '{"retry_cascade":{"circuit_breaker_threshold":3}}' > "$DAEMON_CONFIG"

if cascade_circuit_open build sonnet; then assert_fail "circuit closed initially"; else assert_pass "circuit closed initially"; fi

cascade_record_attempt build sonnet 0.10
cascade_record_attempt build sonnet 0.10
if cascade_circuit_open build sonnet; then assert_fail "closed at 2 < threshold 3"; else assert_pass "closed at 2 < threshold 3"; fi

cascade_record_attempt build sonnet 0.10
if cascade_circuit_open build sonnet; then assert_pass "tripped at 3 >= threshold 3"; else assert_fail "tripped at 3 >= threshold 3"; fi

# Circuit is per stage:model — opus on same stage still closed
if cascade_circuit_open build opus; then assert_fail "opus circuit independent"; else assert_pass "opus circuit independent"; fi
echo '{}' > "$DAEMON_CONFIG"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_stage_spent — sums ledger by stage"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
cascade_record_attempt build sonnet 0.10
cascade_record_attempt build opus 0.50
cascade_record_attempt review sonnet 0.20
spent_build=$(cascade_stage_spent build)
if awk -v v="$spent_build" 'BEGIN{exit !(v > 0.59 && v < 0.61)}'; then
    assert_pass "build spent ~= 0.60 (got $spent_build)"
else
    assert_fail "build spent ~= 0.60" "got $spent_build"
fi
spent_review=$(cascade_stage_spent review)
if awk -v v="$spent_review" 'BEGIN{exit !(v > 0.19 && v < 0.21)}'; then
    assert_pass "review spent ~= 0.20 (got $spent_review)"
else
    assert_fail "review spent ~= 0.20" "got $spent_review"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_budget_ok — per-stage cap enforcement"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
echo '{"retry_cascade":{"max_cascade_cost_per_stage_usd":1.0}}' > "$DAEMON_CONFIG"

# Nothing spent; cheap estimate fits under 1.0 cap.
if cascade_budget_ok build opus 0.50; then assert_pass "0.50 est under 1.0 cap ok"; else assert_fail "0.50 est under 1.0 cap ok"; fi

# Spend 0.80, then a 0.50 estimate would project 1.30 > 1.0 cap -> blocked.
cascade_record_attempt build sonnet 0.80
if cascade_budget_ok build opus 0.50; then assert_fail "0.80+0.50 over 1.0 cap blocked"; else assert_pass "0.80+0.50 over 1.0 cap blocked"; fi

# A tiny estimate still fits: 0.80 + 0.10 = 0.90 < 1.0
if cascade_budget_ok build opus 0.10; then assert_pass "0.80+0.10 under 1.0 cap ok"; else assert_fail "0.80+0.10 under 1.0 cap ok"; fi
echo '{}' > "$DAEMON_CONFIG"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_budget_ok — global remaining budget guard"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
echo '{"retry_cascade":{"max_cascade_cost_per_stage_usd":100.0}}' > "$DAEMON_CONFIG"

# Stub a global remaining budget of 0.05 — an estimate above it must block
# even when the per-stage cap is generous.
cost_remaining_budget() { echo "0.05"; }
if cascade_budget_ok build opus 0.50; then assert_fail "global remaining 0.05 blocks 0.50 est"; else assert_pass "global remaining 0.05 blocks 0.50 est"; fi
if cascade_budget_ok build haiku 0.02; then assert_pass "global remaining 0.05 allows 0.02 est"; else assert_fail "global remaining 0.05 allows 0.02 est"; fi

# Unlimited budget never blocks on the global check.
cost_remaining_budget() { echo "unlimited"; }
if cascade_budget_ok build opus 0.50; then assert_pass "unlimited global budget ok"; else assert_fail "unlimited global budget ok"; fi
unset -f cost_remaining_budget
echo '{}' > "$DAEMON_CONFIG"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_estimate_cost — historical then fallback"
# ═══════════════════════════════════════════════════════════════════════════════

# No cost file -> per-model fallback constants.
rm -f "$COST_FILE"
est_opus=$(cascade_estimate_cost build opus)
if awk -v v="$est_opus" 'BEGIN{exit !(v > 0.49 && v < 0.51)}'; then
    assert_pass "opus fallback ~= 0.50 (got $est_opus)"
else
    assert_fail "opus fallback ~= 0.50" "got $est_opus"
fi
est_haiku=$(cascade_estimate_cost build haiku)
if awk -v v="$est_haiku" 'BEGIN{exit !(v > 0.01 && v < 0.03)}'; then
    assert_pass "haiku fallback ~= 0.02 (got $est_haiku)"
else
    assert_fail "haiku fallback ~= 0.02" "got $est_haiku"
fi

# Historical average from cost file wins over the fallback.
cat > "$COST_FILE" <<'JSON'
{"entries":[
  {"stage":"build","model":"opus","cost_usd":0.20},
  {"stage":"build","model":"opus","cost_usd":0.40}
]}
JSON
est_hist=$(cascade_estimate_cost build opus)
if awk -v v="$est_hist" 'BEGIN{exit !(v > 0.29 && v < 0.31)}'; then
    assert_pass "historical avg ~= 0.30 (got $est_hist)"
else
    assert_fail "historical avg ~= 0.30" "got $est_hist"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "bash 3.2 compatibility — no associative arrays / bc"
# ═══════════════════════════════════════════════════════════════════════════════

# Strip comments before checking so the module's own "no readarray" note in a
# comment does not trip the guard — only real code matters.
if sed 's/#.*//' "$SCRIPT_DIR/lib/retry-cascade.sh" | grep -qE 'declare -A|readarray|mapfile|\$\{[a-zA-Z_]+,,\}|\$\{[a-zA-Z_]+\^\^\}'; then
    assert_fail "retry-cascade.sh uses bash-4-only constructs"
else
    assert_pass "retry-cascade.sh is bash 3.2 compatible"
fi
if grep -qE '(^|[^a-zA-Z_])bc( |$)' "$SCRIPT_DIR/lib/retry-cascade.sh"; then
    assert_fail "retry-cascade.sh uses bc for float math"
else
    assert_pass "retry-cascade.sh uses awk (not bc) for float math"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_smart_float — float config reader"
# ═══════════════════════════════════════════════════════════════════════════════

echo '{"retry_cascade":{"max_cascade_cost_per_stage_usd":2.5}}' > "$DAEMON_CONFIG"
assert_eq "_smart_float reads 2.5" "2.5" "$(_smart_float retry_cascade.max_cascade_cost_per_stage_usd 5.0)"
echo '{}' > "$DAEMON_CONFIG"
assert_eq "_smart_float default when unset" "5.0" "$(_smart_float retry_cascade.max_cascade_cost_per_stage_usd 5.0)"
assert_eq "_smart_float env override" "3.25" "$(SW_RETRY_CASCADE_MAX_CASCADE_COST_PER_STAGE_USD=3.25 _smart_float retry_cascade.max_cascade_cost_per_stage_usd 5.0)"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "cascade_next_model — orchestration seam (decision + codes)"
# ═══════════════════════════════════════════════════════════════════════════════

cascade_reset
echo '{}' > "$DAEMON_CONFIG"

# Disabled by default → rc 10, no model.
out=$(cascade_next_model build 1 "timeout" 1) && rc=0 || rc=$?
assert_eq "disabled returns rc 10" "10" "$rc"
assert_eq "disabled emits no model" "" "$out"

# Enable the cascade for the remaining cases.
echo '{"retry_cascade":{"enabled":true}}' > "$DAEMON_CONFIG"
cascade_reset

# Retryable transient error, first retry (attempt 1) → order[1] = sonnet.
out=$(cascade_next_model build 1 "connection reset" 1) && rc=0 || rc=$?
assert_eq "retryable attempt 1 rc 0" "0" "$rc"
assert_eq "retryable attempt 1 escalates to sonnet" "sonnet" "$out"

# Second retry (attempt 2) → order[2] = opus.
out=$(cascade_next_model build 2 "socket hang up" 1) && rc=0 || rc=$?
assert_eq "retryable attempt 2 escalates to opus" "opus" "$out"

# Beyond the order length → exhausted (rc 12).
out=$(cascade_next_model build 3 "timeout" 1) && rc=0 || rc=$?
assert_eq "order exhausted returns rc 12" "12" "$rc"
assert_eq "order exhausted emits no model" "" "$out"

# Non-retryable failure → rc 11 (fail fast), regardless of attempt.
cascade_reset
out=$(cascade_next_model build 1 "AssertionError: expected 1 but got 2" 1) && rc=0 || rc=$?
assert_eq "non-retryable returns rc 11" "11" "$rc"
assert_eq "non-retryable emits no model" "" "$out"

# Budget cap: a tiny per-stage cap makes the projected cost exceed → rc 14.
cascade_reset
echo '{"retry_cascade":{"enabled":true,"max_cascade_cost_per_stage_usd":0.0001}}' > "$DAEMON_CONFIG"
out=$(cascade_next_model build 1 "timeout" 1) && rc=0 || rc=$?
assert_eq "budget cap returns rc 14" "14" "$rc"
assert_eq "budget cap emits no model" "" "$out"

# Circuit breaker: pre-seed enough sonnet attempts to trip the breaker → rc 13.
cascade_reset
echo '{"retry_cascade":{"enabled":true,"circuit_breaker_threshold":2}}' > "$DAEMON_CONFIG"
cascade_record_attempt build sonnet 0.01
cascade_record_attempt build sonnet 0.01
out=$(cascade_next_model build 1 "timeout" 1) && rc=0 || rc=$?
assert_eq "circuit breaker returns rc 13" "13" "$rc"
assert_eq "circuit breaker emits no model" "" "$out"

# A successful escalation records the attempt in the ledger.
cascade_reset
echo '{"retry_cascade":{"enabled":true}}' > "$DAEMON_CONFIG"
cascade_next_model review 1 "503 Service Unavailable" 1 >/dev/null
if grep -q $'^review\tsonnet\t' "$RETRY_CASCADE_ATTEMPTS_FILE"; then
    assert_pass "escalation records attempt in ledger"
else
    assert_fail "escalation records attempt in ledger"
fi
echo '{}' > "$DAEMON_CONFIG"

print_test_results
