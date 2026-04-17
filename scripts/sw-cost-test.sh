#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost test — Validate token usage & cost intelligence         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
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

    # Mock sqlite3
    cat > "$TEST_TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo ""
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/sqlite3"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Cost Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0" "exit code: $rc"
fi
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help shows COMMANDS" "$output" "COMMANDS"
assert_contains "help mentions show" "$output" "show"
assert_contains "help mentions budget" "$output" "budget"
assert_contains "help mentions calculate" "$output" "calculate"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep '^VERSION=' "$SCRIPT_DIR/sw-cost.sh" | head -1)
if [[ -n "$version_line" ]]; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: cost dir creation ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  state management${RESET}"

# Running 'show' should create cost files
bash "$SCRIPT_DIR/sw-cost.sh" show >/dev/null 2>&1 || true
if [[ -f "$HOME/.shipwright/costs.json" ]]; then
    assert_pass "costs.json created on first use"
else
    assert_fail "costs.json created on first use"
fi
if [[ -f "$HOME/.shipwright/budget.json" ]]; then
    assert_pass "budget.json created on first use"
else
    assert_fail "budget.json created on first use"
fi

# ─── Test 4: costs.json has valid structure ─────────────────────────────────
cost_valid=$(jq -e '.entries' "$HOME/.shipwright/costs.json" >/dev/null 2>&1&& echo "yes" || echo "no")
assert_eq "costs.json has entries array" "yes" "$cost_valid"

# ─── Test 5: budget.json has valid structure ────────────────────────────────
budget_valid=$(jq -e '.daily_budget_usd' "$HOME/.shipwright/budget.json" >/dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "budget.json has daily_budget_usd" "yes" "$budget_valid"

# ─── Test 6: budget set command ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  budget commands${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" budget set 50.00 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "budget set exits 0"
else
    assert_fail "budget set exits 0" "exit code: $rc"
fi

# Verify budget was written
budget_val=$(jq -r '.daily_budget_usd' "$HOME/.shipwright/budget.json" 2>/dev/null || echo "")
assert_eq "budget set to 50" "50.00" "$budget_val"

# ─── Test 7: budget show command ────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-cost.sh" budget show 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "budget show exits 0"
else
    assert_fail "budget show exits 0" "exit code: $rc"
fi

# ─── Test 8: unknown command exits non-zero ─────────────────────────────────
echo ""
echo -e "${DIM}  error handling${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 9: calculate command ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  calculate${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" calculate 50000 10000 opus 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "calculate exits 0"
else
    assert_fail "calculate exits 0" "exit code: $rc"
fi

# ─── Test 10: set -euo pipefail ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test: context efficiency section in dashboard ─────────────────────────
echo ""
echo -e "${DIM}  context efficiency in cost dashboard${RESET}"

if grep -q 'CONTEXT EFFICIENCY' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Cost dashboard has CONTEXT EFFICIENCY section"
else
    assert_fail "Cost dashboard has CONTEXT EFFICIENCY section"
fi

if grep -q 'loop.context_efficiency' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Cost dashboard reads loop.context_efficiency events"
else
    assert_fail "Cost dashboard reads loop.context_efficiency events"
fi

if grep -q 'Avg budget used' "$SCRIPT_DIR/sw-cost.sh" && grep -q 'Chars discarded' "$SCRIPT_DIR/sw-cost.sh"; then
    assert_pass "Context efficiency reports utilization and waste"
else
    assert_fail "Context efficiency reports utilization and waste"
fi

# Functional test: write mock events and verify dashboard parses them
mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
cat > "$TEST_TEMP_DIR/home/.shipwright/events.jsonl" <<'EVTEOF'
{"ts":"2026-02-27T10:00:00Z","type":"loop.context_efficiency","iteration":"1","raw_prompt_chars":"200000","trimmed_prompt_chars":"180000","trim_ratio":"10.0","budget_utilization":"100.0","budget_chars":"180000","job_id":"test-1"}
{"ts":"2026-02-27T10:01:00Z","type":"loop.context_efficiency","iteration":"2","raw_prompt_chars":"150000","trimmed_prompt_chars":"150000","trim_ratio":"0.0","budget_utilization":"83.3","budget_chars":"180000","job_id":"test-1"}
EVTEOF

# Also need cost data for the dashboard to run
cat > "$TEST_TEMP_DIR/home/.shipwright/costs.json" <<'COSTEOF'
{"entries":[{"ts":"2026-02-27T10:00:00Z","ts_epoch":1772125200,"input_tokens":50000,"output_tokens":10000,"cost_usd":1.50,"model":"opus","stage":"build","issue":"1"}],"summary":{}}
COSTEOF
cat > "$TEST_TEMP_DIR/home/.shipwright/budget.json" <<'BUDEOF'
{"daily_budget_usd":0,"enabled":false}
BUDEOF

dash_output=$(env HOME="$TEST_TEMP_DIR/home" PATH="$TEST_TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPT_DIR/sw-cost.sh" show --period 30 2>&1) || true

if echo "$dash_output" | grep -q "CONTEXT EFFICIENCY"; then
    assert_pass "Dashboard renders CONTEXT EFFICIENCY with event data"
else
    assert_fail "Dashboard renders CONTEXT EFFICIENCY with event data" "output: $(echo "$dash_output" | tail -5)"
fi

if echo "$dash_output" | grep -q "Avg budget used"; then
    assert_pass "Dashboard shows avg budget utilization"
else
    assert_fail "Dashboard shows avg budget utilization"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# COST ATTRIBUTION DASHBOARD (v3.4.0)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  cost attribution dashboard${RESET}"

# Seed a rich ledger for the attribution tests
now_epoch_val=$(date +%s)
recent1=$((now_epoch_val - 3600))
recent2=$((now_epoch_val - 7200))
recent3=$((now_epoch_val - 10800))
cat > "$HOME/.shipwright/costs.json" <<EOF
{"entries":[
{"input_tokens":10000,"output_tokens":2000,"model":"opus","stage":"build","issue":"389","repo":"shipwright","cost_usd":0.30,"ts":"2026-04-17T10:00:00Z","ts_epoch":${recent1}},
{"input_tokens":5000,"output_tokens":500,"model":"haiku","stage":"intake","issue":"389","repo":"shipwright","cost_usd":0.01,"ts":"2026-04-17T10:01:00Z","ts_epoch":${recent2}},
{"input_tokens":20000,"output_tokens":5000,"model":"opus","stage":"review","issue":"389","repo":"shipwright","cost_usd":0.68,"ts":"2026-04-17T10:02:00Z","ts_epoch":${recent3}},
{"input_tokens":3000,"output_tokens":1000,"model":"sonnet","stage":"test","issue":"400","repo":"shipwright","cost_usd":0.02,"ts":"2026-04-17T10:03:00Z","ts_epoch":${recent1}},
{"input_tokens":1000,"output_tokens":100,"model":"sonnet","stage":"build","issue":"","cost_usd":0.005,"ts":"2026-04-17T10:04:00Z","ts_epoch":${recent2}}
],"summary":{}}
EOF

# Test: breakdown --by stage exits 0
output=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --by stage 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "breakdown --by stage exits 0"
else
    assert_fail "breakdown --by stage exits 0" "rc=$rc"
fi
assert_contains "breakdown shows stage header" "$output" "stage"

# Test: breakdown --by invalid dimension exits 1
output=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --by foo 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 1 ]]; then
    assert_pass "invalid dimension exits 1"
else
    assert_fail "invalid dimension exits 1" "rc=$rc"
fi
assert_contains "invalid dimension error message" "$output" "INVALID_DIMENSION"

# Test: breakdown --json emits valid attribution JSON
output=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --json --refresh 2>&1)
if echo "$output" | jq -e '.version == 1' >/dev/null 2>&1; then
    assert_pass "attribution JSON has version=1"
else
    assert_fail "attribution JSON has version=1" "$(echo "$output" | tail -3)"
fi

if echo "$output" | jq -e '.by_stage and .by_issue and .by_repo and .by_model' >/dev/null 2>&1; then
    assert_pass "attribution JSON has all 4 dimensions"
else
    assert_fail "attribution JSON has all 4 dimensions"
fi

if echo "$output" | jq -e '.trend_30d | type == "array"' >/dev/null 2>&1; then
    assert_pass "attribution JSON has trend_30d array"
else
    assert_fail "attribution JSON has trend_30d array"
fi

# Test: sum invariant — grouped stage sum equals raw total
raw_sum=$(jq '[.entries[].cost_usd] | add' "$HOME/.shipwright/costs.json")
grouped_sum=$(echo "$output" | jq '[.by_stage[].cost_usd] | add')
# Use awk for floating compare (4dp tolerance)
if awk -v r="$raw_sum" -v g="$grouped_sum" 'BEGIN { exit !( (r-g < 0.01) && (g-r < 0.01) )}'; then
    assert_pass "breakdown grouping sum equals raw total"
else
    assert_fail "breakdown grouping sum equals raw total" "raw=$raw_sum grouped=$grouped_sum"
fi

# Test: legacy entry with no repo groups as 'unknown' or valid string
legacy_group=$(echo "$output" | jq -r '.by_repo[] | .key' | head -1)
if [[ -n "$legacy_group" ]]; then
    assert_pass "by_repo handles entries (including legacy without repo)"
else
    assert_fail "by_repo handles legacy entries"
fi

# Test: attribution file is valid JSON (atomic write)
if jq empty "$HOME/.shipwright/cost-attribution.json" 2>/dev/null; then
    assert_pass "cost-attribution.json is valid JSON"
else
    assert_fail "cost-attribution.json is valid JSON"
fi

# Test: recommendations are advisory
output=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --recommend 2>&1)
if [[ $? -eq 0 ]] || true; then
    if echo "$output" | grep -q "advisory\|recommendations\|no recommendations"; then
        assert_pass "recommendations flagged as advisory"
    else
        assert_fail "recommendations flagged as advisory" "$(echo "$output" | tail -3)"
    fi
fi

# Test: trend sparkline renders
output=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --trend 2>&1)
if echo "$output" | grep -q "trend"; then
    assert_pass "trend sparkline renders"
else
    assert_fail "trend sparkline renders"
fi

# Test: NO_DATA on empty ledger exits 2
echo '{"entries":[],"summary":{}}' > "$HOME/.shipwright/costs.json"
output=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --by stage 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 2 ]]; then
    assert_pass "empty ledger exits 2 (NO_DATA)"
else
    assert_fail "empty ledger exits 2 (NO_DATA)" "rc=$rc"
fi
assert_contains "NO_DATA error message" "$output" "NO_DATA"

# Test: single entry — no divide-by-zero in outlier detector
cat > "$HOME/.shipwright/costs.json" <<EOF
{"entries":[{"input_tokens":1000,"output_tokens":100,"model":"opus","stage":"build","issue":"1","repo":"r","cost_usd":0.05,"ts":"2026-04-17T10:00:00Z","ts_epoch":${recent1}}],"summary":{}}
EOF
output=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --by stage --outliers 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "single-entry outlier detector does not crash"
else
    assert_fail "single-entry outlier detector does not crash" "rc=$rc out=$(echo "$output" | tail -3)"
fi

# Test: cost_record accepts optional 6th repo arg (backward compat)
echo '{"entries":[],"summary":{}}' > "$HOME/.shipwright/costs.json"
bash "$SCRIPT_DIR/sw-cost.sh" record 1000 100 opus build 777 2>/dev/null || true
legacy_repo=$(jq -r '.entries[0].repo // "MISSING"' "$HOME/.shipwright/costs.json")
if [[ "$legacy_repo" != "MISSING" && -n "$legacy_repo" ]]; then
    assert_pass "cost_record auto-detects repo when omitted"
else
    assert_fail "cost_record auto-detects repo when omitted" "got: $legacy_repo"
fi

bash "$SCRIPT_DIR/sw-cost.sh" record 1000 100 opus build 777 explicit-repo 2>/dev/null || true
explicit_repo=$(jq -r '.entries[1].repo' "$HOME/.shipwright/costs.json")
assert_eq "cost_record accepts explicit repo arg" "explicit-repo" "$explicit_repo"

# Test: cache refresh behavior
echo '{"entries":[{"input_tokens":0,"output_tokens":0,"model":"opus","stage":"build","issue":"1","repo":"r","cost_usd":0.10,"ts":"2026-04-17T10:00:00Z","ts_epoch":'"${recent1}"'}],"summary":{}}' > "$HOME/.shipwright/costs.json"
first=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --json --refresh 2>/dev/null | jq -r '.generated_at')
# Modify ledger, re-run without --refresh → should still show cached
echo '{"entries":[{"input_tokens":0,"output_tokens":0,"model":"opus","stage":"build","issue":"1","repo":"r","cost_usd":0.99,"ts":"2026-04-17T10:00:00Z","ts_epoch":'"${recent1}"'}],"summary":{}}' > "$HOME/.shipwright/costs.json"
cached_total=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --json 2>/dev/null | jq -r '.totals.cost_usd')
# With --refresh, should show new total
refreshed_total=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --json --refresh 2>/dev/null | jq -r '.totals.cost_usd')
if [[ "$cached_total" == "0.1" && "$refreshed_total" == "0.99" ]]; then
    assert_pass "--refresh regenerates rollup; default serves from cache"
else
    assert_fail "--refresh regenerates rollup; default serves from cache" "cached=$cached_total refreshed=$refreshed_total"
fi

# Test: budget-type alert threshold
cat > "$HOME/.shipwright/budget.json" <<'EOF'
{"daily_budget_usd":0,"enabled":false,"issue_type_budgets":{"refactor":1.0}}
EOF
cat > "$HOME/.shipwright/costs.json" <<EOF
{"entries":[
{"input_tokens":0,"output_tokens":0,"model":"opus","stage":"build","issue":"refactor:1","repo":"r","cost_usd":0.90,"ts":"2026-04-17T10:00:00Z","ts_epoch":${recent1}}
],"summary":{}}
EOF
alerts=$(bash "$SCRIPT_DIR/sw-cost.sh" breakdown --json --refresh 2>/dev/null | jq '.budget_alerts | length')
if [[ "${alerts:-0}" -ge 1 ]]; then
    assert_pass "budget-type alert fires at ≥80% cap"
else
    assert_fail "budget-type alert fires at ≥80% cap" "alerts=$alerts"
fi

# Test: VERSION bumped
version_value=$(grep '^VERSION=' "$SCRIPT_DIR/sw-cost.sh" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [[ "$version_value" == "3.4.0" ]]; then
    assert_pass "VERSION bumped to 3.4.0"
else
    assert_fail "VERSION bumped to 3.4.0" "got: $version_value"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
