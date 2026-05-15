#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline-limits test — Global timeout & cost circuit breaker  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/work/.claude/pipeline-artifacts"
    export HOME="$TEST_TEMP_DIR/home"
    export ARTIFACTS_DIR="$TEST_TEMP_DIR/work/.claude/pipeline-artifacts"
    export COST_FILE="$HOME/.shipwright/costs.json"
    echo '{"entries":[],"summary":{}}' > "$COST_FILE"
    # Reset the limits module so we can re-source per test
    unset _MODULE_PIPELINE_LIMITS_LOADED || true
    unset PIPELINE_LIMITS_TIMEOUT_S PIPELINE_LIMITS_MAX_CENTS \
          PIPELINE_LIMITS_START_EPOCH PIPELINE_LIMITS_RUN_ID || true
    unset SW_GLOBAL_TIMEOUT_SECONDS SW_MAX_COST_USD || true
    unset ISSUE_NUMBER || true
    export ISSUE_NUMBER=""
}

reload_lib() {
    unset _MODULE_PIPELINE_LIMITS_LOADED || true
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/pipeline-limits.sh"
}

trap cleanup_test_env EXIT

print_test_header "Pipeline Limits Tests"

setup_env
reload_lib

# ─── Test 1: limits_init defaults ────────────────────────────────────────────
print_test_section "init / defaults"
limits_init
assert_eq "default timeout = 14400s"      "14400" "$PIPELINE_LIMITS_TIMEOUT_S"
assert_eq "default max cost = 5000 cents" "5000"  "$PIPELINE_LIMITS_MAX_CENTS"

# ─── Test 2: env overrides ───────────────────────────────────────────────────
print_test_section "init / env overrides"
SW_GLOBAL_TIMEOUT_SECONDS=42 SW_MAX_COST_USD=0.25 limits_init
assert_eq "env timeout override"  "42" "$PIPELINE_LIMITS_TIMEOUT_S"
assert_eq "env cost override"     "25" "$PIPELINE_LIMITS_MAX_CENTS"
unset SW_GLOBAL_TIMEOUT_SECONDS SW_MAX_COST_USD

# ─── Test 3: usd_to_cents conversion ─────────────────────────────────────────
print_test_section "usd_to_cents"
assert_eq "0.01 USD → 1 cent"   "1"    "$(limits_usd_to_cents 0.01)"
assert_eq "50 USD → 5000 cents" "5000" "$(limits_usd_to_cents 50)"
assert_eq "50.0 USD → 5000"     "5000" "$(limits_usd_to_cents 50.0)"
assert_eq "garbage → 0"         "0"    "$(limits_usd_to_cents abc)"

# ─── Test 4: cost read happy path ───────────────────────────────────────────
print_test_section "cost read"
ISSUE_NUMBER="" PIPELINE_START_EPOCH=0 limits_init
cat > "$COST_FILE" <<JSON
{"entries":[
  {"input_tokens":1,"output_tokens":1,"model":"sonnet","stage":"build","issue":"","cost_usd":0.30,"ts":"now","ts_epoch":100},
  {"input_tokens":1,"output_tokens":1,"model":"sonnet","stage":"test", "issue":"","cost_usd":0.20,"ts":"now","ts_epoch":200}
],"summary":{}}
JSON
cents=$(limits_pipeline_cost_cents)
assert_eq "summed cost = 50 cents" "50" "$cents"

# ─── Test 5: cost read missing file is fail-open ─────────────────────────────
rm -f "$COST_FILE"
cents=$(limits_pipeline_cost_cents)
assert_eq "missing cost file → 0" "0" "$cents"
echo '{"entries":[]}' > "$COST_FILE"

# ─── Test 6: cost read corrupt file is fail-open ─────────────────────────────
echo "not json" > "$COST_FILE"
cents=$(limits_pipeline_cost_cents)
assert_eq "corrupt cost file → 0" "0" "$cents"
echo '{"entries":[]}' > "$COST_FILE"

# ─── Test 7: limits_check passes when under bounds ───────────────────────────
print_test_section "check"
SW_GLOBAL_TIMEOUT_SECONDS=3600 SW_MAX_COST_USD=10.0 limits_init
PIPELINE_LIMITS_START_EPOCH=$(date +%s)
rc=0; limits_check "build" || rc=$?
assert_eq "under bounds → exit 0" "0" "$rc"

# ─── Test 8: limits_check trips on timeout (124) ─────────────────────────────
SW_GLOBAL_TIMEOUT_SECONDS=1 SW_MAX_COST_USD=10.0 limits_init
PIPELINE_LIMITS_START_EPOCH=$(( $(date +%s) - 3600 ))
rc=0; limits_check "design" || rc=$?
assert_eq "timeout breach → exit 124" "124" "$rc"
if [[ -f "$ARTIFACTS_DIR/limits-breach.json" ]]; then
    reason=$(jq -r '.reason' "$ARTIFACTS_DIR/limits-breach.json")
    assert_eq "limits-breach.json reason=timeout" "timeout" "$reason"
else
    assert_fail "limits-breach.json written on timeout"
fi
rm -f "$ARTIFACTS_DIR/limits-breach.json"

# ─── Test 9: limits_check trips on cost (125) ────────────────────────────────
SW_GLOBAL_TIMEOUT_SECONDS=86400 SW_MAX_COST_USD=0.10 limits_init
_now=$(date +%s)
PIPELINE_LIMITS_START_EPOCH=$(( _now - 60 ))
cat > "$COST_FILE" <<JSON
{"entries":[
  {"cost_usd":0.50,"ts_epoch":${_now},"issue":""}
],"summary":{}}
JSON
rc=0; limits_check "build" || rc=$?
assert_eq "cost breach → exit 125" "125" "$rc"
reason=$(jq -r '.reason' "$ARTIFACTS_DIR/limits-breach.json" 2>/dev/null || echo "")
assert_eq "limits-breach.json reason=cost" "cost" "$reason"
rm -f "$ARTIFACTS_DIR/limits-breach.json"

# ─── Test 10: cost limit disabled (0) is no-op ───────────────────────────────
SW_GLOBAL_TIMEOUT_SECONDS=0 SW_MAX_COST_USD=0 limits_init
PIPELINE_LIMITS_START_EPOCH=0
rc=0; limits_check "build" || rc=$?
assert_eq "both disabled → exit 0" "0" "$rc"

# ─── Test 11: limits_abort writes notification & status ──────────────────────
print_test_section "abort"
SW_GLOBAL_TIMEOUT_SECONDS=1 SW_MAX_COST_USD=10.0 limits_init
PIPELINE_LIMITS_START_EPOCH=$(( $(date +%s) - 7200 ))
_outf="$TEST_TEMP_DIR/abort.out"
limits_abort 124 "design" >"$_outf" 2>&1 && rc=0 || rc=$?
out=$(cat "$_outf")
assert_eq "abort returns input code" "124" "$rc"
assert_contains "abort notification mentions timeout" "$out" "timeout"
assert_contains "abort notification mentions resume"  "$out" "resume"
assert_eq "PIPELINE_STATUS set to aborted_timeout" "aborted_timeout" "${PIPELINE_STATUS:-}"

# ─── Test 12: templates carry limits block ───────────────────────────────────
print_test_section "templates"
TEMPLATES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/templates/pipelines"
missing=0
for tpl in "$TEMPLATES_DIR"/*.json; do
    has=$(jq -r '(.limits.global_timeout_seconds // empty) as $t | (.limits.max_cost_usd // empty) as $c | if ($t != "" and $c != "") then "ok" else "missing" end' "$tpl")
    [[ "$has" == "ok" ]] || { missing=$((missing+1)); echo "    missing: $(basename "$tpl")"; }
done
assert_eq "all templates have limits block" "0" "$missing"

print_test_results
