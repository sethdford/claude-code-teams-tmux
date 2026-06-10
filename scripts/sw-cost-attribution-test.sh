#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost-attribution test — Per-pipeline cost attribution          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_env EXIT

echo ""
print_test_header "Shipwright Cost Attribution Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# ─── Setup: isolated cost file + artifacts dir, then source the lib ─────────
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.shipwright"
export COST_FILE="$HOME/.shipwright/costs.json"
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export NO_COLOR=1

# Seed a costs.json with entries for two pipelines (#613 and #700).
cat > "$COST_FILE" <<'JSON'
{
  "entries": [
    {"input_tokens": 1000, "output_tokens": 200, "model": "haiku",  "stage": "intake", "issue": "613", "cost_usd": 0.0005, "ts_epoch": 100},
    {"input_tokens": 5000, "output_tokens": 3000, "model": "opus",  "stage": "build",  "issue": "613", "cost_usd": 0.30,   "ts_epoch": 110},
    {"input_tokens": 2000, "output_tokens": 1000, "model": "sonnet","stage": "build",  "issue": "613", "cost_usd": 0.021,  "ts_epoch": 120},
    {"input_tokens": 1500, "output_tokens": 800,  "model": "sonnet","stage": "review", "issue": "613", "cost_usd": 0.0165, "ts_epoch": 130},
    {"input_tokens": 800,  "output_tokens": 400,  "model": "opus",  "stage": "build",  "issue": "700", "cost_usd": 0.042,  "ts_epoch": 140}
  ],
  "summary": {}
}
JSON

# shellcheck source=lib/cost-attribution.sh
source "$SCRIPT_DIR/lib/cost-attribution.sh"

# ─── Test 1: aggregate produces valid JSON for a known issue ────────────────
echo -e "  ${CYAN}aggregate${RESET}"
agg=$(cost_attribution_aggregate "613")
assert_pass_if_json() { if echo "$1" | jq empty 2>/dev/null; then assert_pass "$2"; else assert_fail "$2" "invalid JSON: $1"; fi; }
assert_pass_if_json "$agg" "aggregate emits valid JSON"
assert_json_key "issue is normalized to 613" "$agg" ".issue" "613"
assert_json_key "schema_version present" "$agg" ".schema_version" "1"
assert_json_key "call_count counts 4 entries for #613" "$agg" ".call_count" "4"

# ─── Test 2: total cost sums only matching issue ────────────────────────────
total=$(echo "$agg" | jq -r '.total_cost_usd')
# 0.0005 + 0.30 + 0.021 + 0.0165 = 0.338
assert_eq "total_cost_usd sums #613 entries only" "0.338" "$total"

# ─── Test 3: leading '#' on issue is matched ────────────────────────────────
agg_hash=$(cost_attribution_aggregate "#613")
assert_json_key "#613 matches same entries" "$agg_hash" ".call_count" "4"

# ─── Test 4: stage breakdown ────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}stage breakdown${RESET}"
build_cost=$(echo "$agg" | jq -r '.stages.build.cost_usd')
assert_eq "build stage sums two entries (0.30+0.021)" "0.321" "$build_cost"
build_calls=$(echo "$agg" | jq -r '.stages.build.calls')
assert_eq "build stage records 2 calls" "2" "$build_calls"
intake_in=$(echo "$agg" | jq -r '.stages.intake.input_tokens')
assert_eq "intake stage input tokens" "1000" "$intake_in"

# ─── Test 5: model distribution ─────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}model distribution${RESET}"
opus_cost=$(echo "$agg" | jq -r '.models.opus.cost_usd')
assert_eq "opus model cost for #613" "0.3" "$opus_cost"
# opus pct = 0.30 / 0.338 * 100 = 88.8%
opus_pct=$(echo "$agg" | jq -r '.models.opus.pct')
assert_eq "opus pct computed" "88.8" "$opus_pct"
sonnet_calls=$(echo "$agg" | jq -r '.models.sonnet.calls')
assert_eq "sonnet model has 2 calls" "2" "$sonnet_calls"

# ─── Test 6: empty / unknown issue yields zeroed object ─────────────────────
echo ""
echo -e "  ${CYAN}empty cases${RESET}"
empty=$(cost_attribution_aggregate "99999")
assert_json_key "unknown issue total is 0" "$empty" ".total_cost_usd" "0"
assert_json_key "unknown issue call_count is 0" "$empty" ".call_count" "0"
assert_eq "unknown issue stages empty" "{}" "$(echo "$empty" | jq -c '.stages')"

# ─── Test 7: missing cost file yields zeroed object (no crash) ──────────────
missing=$(COST_FILE="$TEST_TEMP_DIR/nonexistent.json" cost_attribution_aggregate "613")
assert_json_key "missing cost file total is 0" "$missing" ".total_cost_usd" "0"

# ─── Test 8: aggregate requires an issue ────────────────────────────────────
rc=0; cost_attribution_aggregate "" >/dev/null 2>&1 || rc=$?
assert_eq "aggregate with no issue exits 1" "1" "$rc"

# ─── Test 9: write_cost_artifact creates artifact atomically ────────────────
echo ""
echo -e "  ${CYAN}artifact writer${RESET}"
rc=0; write_cost_artifact "613" "$ARTIFACTS_DIR" || rc=$?
assert_eq "write_cost_artifact exits 0" "0" "$rc"
assert_file_exists "cost.json artifact created" "$ARTIFACTS_DIR/cost.json"
artifact_total=$(jq -r '.total_cost_usd' "$ARTIFACTS_DIR/cost.json")
assert_eq "artifact total matches aggregate" "0.338" "$artifact_total"
# No leftover temp files from atomic write
leftover=$(find "$ARTIFACTS_DIR" -name 'cost.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no leftover temp files" "0" "$leftover"

# ─── Test 10: write_cost_artifact requires issue ────────────────────────────
rc=0; write_cost_artifact "" "$ARTIFACTS_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "write_cost_artifact with no issue exits 1" "1" "$rc"

# ─── Test 11: model family normalization (full model ids) ───────────────────
echo ""
echo -e "  ${CYAN}model normalization${RESET}"
cat > "$COST_FILE" <<'JSON'
{
  "entries": [
    {"input_tokens": 100, "output_tokens": 50, "model": "claude-opus-4-8",   "stage": "build", "issue": "42", "cost_usd": 0.10, "ts_epoch": 1},
    {"input_tokens": 100, "output_tokens": 50, "model": "claude-sonnet-4-6", "stage": "build", "issue": "42", "cost_usd": 0.05, "ts_epoch": 2}
  ],
  "summary": {}
}
JSON
agg2=$(cost_attribution_aggregate "42")
assert_eq "claude-opus-4-8 normalized to opus" "0.1" "$(echo "$agg2" | jq -r '.models.opus.cost_usd')"
assert_eq "claude-sonnet-4-6 normalized to sonnet" "0.05" "$(echo "$agg2" | jq -r '.models.sonnet.cost_usd')"

# ─── Test 12: budget forecasting ────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}budget forecast${RESET}"
# Two pipelines: #42 total 0.15. avg = 0.15. remaining 1.50 -> 10 pipelines.
forecast=$(cost_attribution_forecast "1.50")
assert_pass_if_json "$forecast" "forecast emits valid JSON"
assert_json_key "forecast counts 1 completed pipeline" "$forecast" ".pipelines_completed" "1"
assert_json_key "forecast avg pipeline cost" "$forecast" ".avg_pipeline_cost_usd" "0.15"
assert_json_key "forecast pipelines remaining = floor(1.5/0.15)" "$forecast" ".pipelines_remaining" "10"

# ─── Test 13: forecast handles 'unlimited' / non-numeric budget ─────────────
forecast_unl=$(cost_attribution_forecast "unlimited")
assert_json_key "unlimited budget coerced to 0" "$forecast_unl" ".remaining_budget_usd" "0"

# ─── Test 14: forecast with no history ──────────────────────────────────────
forecast_none=$(COST_FILE="$TEST_TEMP_DIR/nope.json" cost_attribution_forecast "5.00")
assert_json_key "no-history forecast completed count 0" "$forecast_none" ".pipelines_completed" "0"
assert_eq "no-history pipelines_remaining is null" "null" "$(echo "$forecast_none" | jq -r '.pipelines_remaining')"

echo ""
echo ""
print_test_results
