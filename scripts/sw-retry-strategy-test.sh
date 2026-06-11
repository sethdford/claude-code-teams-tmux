#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-retry-strategy-test.sh — Intelligent Retry Strategy Engine Tests     ║
# ║  Unit + integration + E2E for scripts/lib/retry-strategy.sh              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"; echo "    Actual:   $actual"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" description="${3:-}"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"; echo "    Actual: $haystack"
    fi
}

assert_file_exists() {
    local path="$1" description="${2:-}"
    if [[ -f "$path" ]]; then
        PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    File not found: $path"
    fi
}

assert_json_field() {
    local json="$1" field="$2" expected="$3" description="${4:-}"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "<jq-error>")
    assert_equals "$expected" "$actual" "$description"
}

# ─── Setup ──────────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/retry-strategy-test-XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/retry-strategy-test-$$")
mkdir -p "$TMPDIR_TEST" 2>/dev/null || true
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export RETRY_METRICS_FILE="$TMPDIR_TEST/retry-metrics.jsonl"
export RETRY_STRATEGY_CONFIG="$TMPDIR_TEST/daemon-config.json"
export EVENTS_FILE="$TMPDIR_TEST/events.jsonl"
export RETRY_MODEL_LADDER="sonnet,opus"
export RETRY_MIN_CONFIDENCE_INT=30

# Load helpers for real emit_event (writes to EVENTS_FILE), then source the
# module standalone (verifies the self-contained fallback path — no auto-recovery).
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/retry-strategy.sh"

echo ""
echo "━━━ Unit: retry_category_of (4-category mapping) ━━━"

test_category_mapping() {
    assert_equals "recoverable-transient"  "$(retry_category_of network_error)"      "network_error → transient"
    assert_equals "recoverable-transient"  "$(retry_category_of api_error)"          "api_error → transient"
    assert_equals "recoverable-transient"  "$(retry_category_of timeout)"            "timeout → transient"
    assert_equals "recoverable-transient"  "$(retry_category_of lock_error)"         "lock_error → transient"
    assert_equals "context-exhausted"      "$(retry_category_of context_exhaustion)" "context_exhaustion → context-exhausted"
    assert_equals "unrecoverable"          "$(retry_category_of auth_error)"         "auth_error → unrecoverable"
    assert_equals "unrecoverable"          "$(retry_category_of permission_error)"   "permission_error → unrecoverable"
    assert_equals "unrecoverable"          "$(retry_category_of invalid_issue)"      "invalid_issue → unrecoverable"
    assert_equals "recoverable-escalation" "$(retry_category_of type_error)"         "type_error → escalation"
    assert_equals "recoverable-escalation" "$(retry_category_of build_failure)"      "build_failure → escalation"
    assert_equals "recoverable-escalation" "$(retry_category_of test_assertion)"     "test_assertion → escalation"
    assert_equals "recoverable-escalation" "$(retry_category_of unknown)"            "unknown → escalation (conservative)"
}
test_category_mapping

echo ""
echo "━━━ Unit: retry_classify (fine-grained) ━━━"

test_classify() {
    assert_equals "network_error"      "$(retry_classify 'ECONNREFUSED connection refused')"           "classifies network error"
    assert_equals "network_error"      "$(retry_classify 'rate limit 429 overloaded')"                 "classifies rate limit as network/transient"
    assert_equals "permission_error"   "$(retry_classify 'not logged in: unauthorized 401')"           "classifies auth/permission error"
    assert_equals "context_exhaustion" "$(retry_classify 'context window exceeded')"                    "classifies context window exhaustion"
    assert_equals "context_exhaustion" "$(retry_classify 'max iterations reached without completing')"  "classifies iteration exhaustion"
    assert_equals "syntax_error"       "$(retry_classify 'SyntaxError: Unexpected token }')"            "classifies syntax error"
    assert_equals "unknown"            "$(retry_classify 'something totally unrecognizable zzzzz')"     "unrecognized → unknown"
    assert_equals "unknown"            "$(retry_classify '')"                                           "empty → unknown"
}
test_classify

echo ""
echo "━━━ Unit: retry_compute_confidence (bounds + format) ━━━"

test_confidence() {
    assert_equals "0.70" "$(retry_compute_confidence network_error 0 1 4)"  "base known category = 0.70"
    assert_equals "0.30" "$(retry_compute_confidence unknown 0 1 4)"        "unknown base = 0.30"
    assert_equals "0.90" "$(retry_compute_confidence type_error 80 1 4)"    "memory match (>50%) adds 0.20"
    assert_equals "0.50" "$(retry_compute_confidence type_error 0 3 3)"     "at max attempts subtracts 0.20"
    assert_equals "0.10" "$(retry_compute_confidence unknown 0 3 3)"        "unknown at max clamps low"
    # Always formatted as 0.NN and within [0.05, 0.99]
    assert_contains "0." "$(retry_compute_confidence network_error 90 1 4)" "confidence formatted as 0.NN"
}
test_confidence

echo ""
echo "━━━ Unit: retry_escalation_target (ladder progression) ━━━"

test_escalation_ladder() {
    assert_equals "sonnet"          "$(retry_escalation_target haiku 1 4)"   "haiku (off-ladder) → sonnet (top)"
    assert_equals "opus"            "$(retry_escalation_target sonnet 1 4)"  "sonnet → opus"
    assert_equals "session-restart" "$(retry_escalation_target opus 1 4)"    "opus → session-restart"
    assert_equals "human"           "$(retry_escalation_target session-restart 1 4)" "session-restart → human (terminal)"
    assert_equals "human"           "$(retry_escalation_target human 9 9)"   "human stays human (bounded)"
}
test_escalation_ladder

echo ""
echo "━━━ Unit: retry_decide (decision JSON + actions) ━━━"

test_decide_actions() {
    local d
    d=$(retry_decide "ECONNREFUSED network down" 1 4 opus)
    echo "$d" | jq -e . >/dev/null 2>&1 && { PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m transient decision is valid JSON"; } || { FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m transient decision is valid JSON"; }
    assert_json_field "$d" ".category" "recoverable-transient" "transient → category"
    assert_json_field "$d" ".action"   "immediate"            "transient → immediate action"

    d=$(retry_decide "not logged in unauthorized 401" 1 3 opus)
    assert_json_field "$d" ".category" "unrecoverable" "auth → unrecoverable"
    assert_json_field "$d" ".action"   "skip"          "auth → skip"
    assert_json_field "$d" ".escalationTarget" "human" "auth → escalate to human"

    d=$(retry_decide "context window exceeded" 1 3 opus)
    assert_json_field "$d" ".category" "context-exhausted" "context → context-exhausted"
    assert_json_field "$d" ".action"   "session-restart"   "context → session-restart"

    # Empty error edge: skip, low confidence (no wasted cycle).
    d=$(retry_decide "" 1 3 opus)
    assert_json_field "$d" ".action"     "skip"   "empty error → skip"
    assert_json_field "$d" ".confidence" "0.30"   "empty error → 0.30 confidence"

    # Max-attempts edge on an escalation category → degrades to skip (no model bump).
    d=$(retry_decide "build compile error unresolved" 3 3 opus)
    assert_json_field "$d" ".action" "skip" "escalation at max attempts → skip"

    # Action enum is always one of the four allowed values.
    d=$(retry_decide "TypeError is not assignable" 1 4 sonnet)
    local act
    act=$(echo "$d" | jq -r .action)
    case "$act" in
        immediate|model-escalation|session-restart|skip) PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m action in allowed enum ($act)" ;;
        *) FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m action in allowed enum (got: $act)" ;;
    esac

    # Confidence always within [0.05, 0.99].
    local conf
    conf=$(echo "$d" | jq -r .confidence)
    if awk -v c="$conf" 'BEGIN{exit !(c>=0.05 && c<=0.99)}'; then
        PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m confidence within [0.05,0.99] ($conf)"
    else
        FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m confidence within [0.05,0.99] ($conf)"
    fi
}
test_decide_actions

echo ""
echo "━━━ Integration: retry.decision event emission ━━━"

test_event_emission() {
    : > "$EVENTS_FILE"
    retry_decide "ECONNREFUSED network down" 1 4 opus >/dev/null
    assert_file_exists "$EVENTS_FILE" "events file written"
    assert_contains "retry.decision" "$(cat "$EVENTS_FILE")" "retry.decision event emitted"
}
test_event_emission

echo ""
echo "━━━ Integration: retry_record_outcome + retry_metrics ━━━"

test_record_and_metrics() {
    : > "$EVENTS_FILE"
    rm -f "$RETRY_METRICS_FILE"
    retry_record_outcome "model-escalation" "true"  "recoverable-escalation"
    retry_record_outcome "model-escalation" "false" "recoverable-escalation"
    retry_record_outcome "immediate"        "true"  "recoverable-transient"
    assert_file_exists "$RETRY_METRICS_FILE" "metrics JSONL written"
    assert_contains "retry.outcome" "$(cat "$EVENTS_FILE")" "retry.outcome event emitted"

    local m
    m=$(retry_metrics)
    echo "$m" | jq -e . >/dev/null 2>&1 && { PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m metrics output is valid JSON"; } || { FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m metrics output is valid JSON"; }
    assert_json_field "$m" ".total" "3" "metrics counts 3 total outcomes"
    local rate
    rate=$(echo "$m" | jq -r '.strategies[] | select(.strategy=="model-escalation") | .successRate')
    assert_equals "50" "$rate" "model-escalation success rate = 50%"
}
test_record_and_metrics

echo ""
echo "━━━ Integration: delegation to auto-recovery + memory fixture ━━━"

test_delegation_and_memory() {
    # Re-source within a subshell-like fresh context is not possible (module guard),
    # so validate delegation by loading auto-recovery alongside in a child shell.
    local out
    out=$(
        export RETRY_METRICS_FILE="$TMPDIR_TEST/rm2.jsonl" EVENTS_FILE="$TMPDIR_TEST/ev2.jsonl"
        source "$SCRIPT_DIR/lib/auto-recovery.sh"
        source "$SCRIPT_DIR/lib/retry-strategy.sh"
        # auto-recovery's classifier handles "is not assignable" precisely
        retry_classify "Type 'string' is not assignable to type 'number'"
    )
    assert_equals "type_error" "$out" "delegates to recovery_classify_error when loaded"

    # Memory fixture: a known fix with high effectiveness should surface + raise confidence.
    local mem_out
    mem_out=$(
        export RETRY_METRICS_FILE="$TMPDIR_TEST/rm3.jsonl" EVENTS_FILE="$TMPDIR_TEST/ev3.jsonl"
        # Stub memory query to simulate a high-effectiveness historical fix.
        memory_query_fix_for_error() { echo '{"fix":"add explicit type annotations","fix_effectiveness_rate":80,"category":"type_error"}'; }
        export -f memory_query_fix_for_error 2>/dev/null || true
        source "$SCRIPT_DIR/lib/retry-strategy.sh"
        retry_decide "TypeError type mismatch" 1 4 sonnet
    )
    assert_contains "add explicit type annotations" "$mem_out" "memory fix surfaced in decision"
    assert_contains "success rate" "$mem_out" "memory fix annotated with success rate"
}
test_delegation_and_memory

echo ""
echo "━━━ E2E: CLI round-trip ━━━"

test_cli_roundtrip() {
    local out
    out=$(RETRY_METRICS_FILE="$TMPDIR_TEST/cli.jsonl" EVENTS_FILE="$TMPDIR_TEST/cli-ev.jsonl" \
        bash "$SCRIPT_DIR/lib/retry-strategy.sh" decide "ECONNREFUSED" 1 4 opus)
    echo "$out" | jq -e . >/dev/null 2>&1 && { PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m CLI decide emits valid JSON"; } || { FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m CLI decide emits valid JSON"; }

    RETRY_METRICS_FILE="$TMPDIR_TEST/cli.jsonl" EVENTS_FILE="$TMPDIR_TEST/cli-ev.jsonl" \
        bash "$SCRIPT_DIR/lib/retry-strategy.sh" record "immediate" "true" "recoverable-transient"
    local m
    m=$(RETRY_METRICS_FILE="$TMPDIR_TEST/cli.jsonl" bash "$SCRIPT_DIR/lib/retry-strategy.sh" metrics)
    echo "$m" | jq -e . >/dev/null 2>&1 && { PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m CLI metrics emits valid JSON"; } || { FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m CLI metrics emits valid JSON"; }
}
test_cli_roundtrip

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Results: \033[38;2;74;222;128m${PASS} passed\033[0m, \033[38;2;248;113;113m${FAIL} failed\033[0m"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ "$FAIL" -eq 0 ]]
