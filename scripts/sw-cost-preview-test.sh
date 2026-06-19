#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-cost-preview-test.sh — Cost Impact Preview & Budget-Aware Selector     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Cost Preview & Budget-Aware Selector Tests"

setup_test_env "sw-cost-preview-test"
trap cleanup_test_env EXIT

# Source sw-cost.sh (CLI body guarded — sourcing only loads functions)
source "$SCRIPT_DIR/sw-cost.sh"

COST_SH="$SCRIPT_DIR/sw-cost.sh"

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "Library loading & token map"
# ═══════════════════════════════════════════════════════════════════════════

assert_eq "library loaded guard set" "1" "${_CP_LIB_LOADED:-}"
assert_eq "_cp_stage_tokens build" "100000" "$(_cp_stage_tokens build)"
assert_eq "_cp_stage_tokens unknown defaults 5000" "5000" "$(_cp_stage_tokens does_not_exist)"
assert_eq "_cp_stage_tokens intake" "5000" "$(_cp_stage_tokens intake)"

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "_cp_stage_model resolution"
# ═══════════════════════════════════════════════════════════════════════════

STD_FILE="$SCRIPT_DIR/../templates/pipelines/standard.json"
# plan stage has explicit config.model in standard.json
assert_eq "stage model from config" "opus" "$(_cp_stage_model "$STD_FILE" plan)"
# intake stage has empty config -> falls back to defaults.model
assert_eq "stage model falls back to default" "opus" "$(_cp_stage_model "$STD_FILE" intake)"

# Synthetic template exercising fallback chain
SYN="$TEST_TEMP_DIR/syn.json"
cat > "$SYN" <<'JSON'
{"defaults":{"model":"sonnet"},"stages":[
  {"id":"build","enabled":true,"config":{"model":"haiku"}},
  {"id":"test","enabled":true,"config":{}}
]}
JSON
assert_eq "explicit stage model wins" "haiku" "$(_cp_stage_model "$SYN" build)"
assert_eq "default model when stage empty" "sonnet" "$(_cp_stage_model "$SYN" test)"

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "cp_estimate_template"
# ═══════════════════════════════════════════════════════════════════════════

std_cost=$(cp_estimate_template standard 50)
assert_contains_regex "standard cost is numeric" "$std_cost" '^[0-9]+\.[0-9]+$'
if awk -v c="$std_cost" 'BEGIN { exit !(c > 0) }'; then assert_pass "standard cost > 0"; else assert_fail "standard cost > 0" "got $std_cost"; fi

fast_cost=$(cp_estimate_template fast 50)
# fast template enables fewer stages than standard -> should cost less
if awk -v f="$fast_cost" -v s="$std_cost" 'BEGIN { exit !(f < s) }'; then
    assert_pass "fast template cheaper than standard"
else
    assert_fail "fast template cheaper than standard" "fast=$fast_cost std=$std_cost"
fi

# Higher complexity scales cost up
hi_cost=$(cp_estimate_template standard 100)
if awk -v h="$hi_cost" -v s="$std_cost" 'BEGIN { exit !(h > s) }'; then
    assert_pass "higher complexity costs more"
else
    assert_fail "higher complexity costs more" "hi=$hi_cost std=$std_cost"
fi

# Missing template errors
if cp_estimate_template no_such_template 50 >/dev/null 2>&1; then
    assert_fail "missing template returns error" "expected non-zero exit"
else
    assert_pass "missing template returns error"
fi

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "cp_preview_one output"
# ═══════════════════════════════════════════════════════════════════════════

human=$(cp_preview_one standard 50 0 2>&1)
assert_contains "preview shows a stage" "$human" "build"
assert_contains "preview shows Total" "$human" "Total"

json=$(cp_preview_one standard 50 1 2>/dev/null)
echo "$json" | jq -e . >/dev/null 2>&1 && assert_pass "preview one JSON is valid" || assert_fail "preview one JSON is valid" "invalid json"
assert_eq "json template field" "standard" "$(echo "$json" | jq -r '.template')"
assert_gt "json has stages" "$(echo "$json" | jq '.stages | length')" "0"

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "cp_preview_all output"
# ═══════════════════════════════════════════════════════════════════════════

all_json=$(cp_preview_all 50 1 2>/dev/null)
echo "$all_json" | jq -e . >/dev/null 2>&1 && assert_pass "preview all JSON valid" || assert_fail "preview all JSON valid" "invalid"
assert_gt "preview all lists templates" "$(echo "$all_json" | jq '.templates | length')" "1"
# Verify ascending sort by cost
sorted_ok=$(echo "$all_json" | jq -r '[.templates[].total_usd] | . == (sort)')
assert_eq "preview all sorted ascending" "true" "$sorted_ok"

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "cp_select budget-aware"
# ═══════════════════════════════════════════════════════════════════════════

# Unlimited budget -> default 'standard'
cost_remaining_budget() { echo "unlimited"; }
assert_eq "unlimited budget selects default" "standard" "$(cp_select 50 0 2>/dev/null)"

# Generous budget -> most capable template (full) fits
cost_remaining_budget() { echo "1000"; }
sel_generous=$(cp_select 50 0 2>/dev/null)
assert_eq "generous budget selects full" "full" "$sel_generous"

# Tight budget -> downgrades to a cheaper template that fits
cost_remaining_budget() { echo "5"; }
sel_tight=$(cp_select 50 0 2>/dev/null)
assert_contains_regex "tight budget returns a template name" "$sel_tight" '^[a-z-]+$'
tight_cost=$(cp_estimate_template "$sel_tight" 50)
# ceiling = 5 * 90% = 4.5
if awk -v c="$tight_cost" 'BEGIN { exit !(c <= 4.5) }'; then
    assert_pass "tight budget selection fits ceiling"
else
    assert_fail "tight budget selection fits ceiling" "cost=$tight_cost > 4.5"
fi

# Near-zero budget -> nothing fits -> cheapest + warn
cost_remaining_budget() { echo "0.01"; }
sel_zero=$(cp_select 50 0 2>/dev/null)
assert_contains_regex "near-zero budget still returns a template" "$sel_zero" '^[a-z-]+$'

# JSON select output
cost_remaining_budget() { echo "1000"; }
sel_json=$(cp_select 50 1 2>/dev/null)
echo "$sel_json" | jq -e . >/dev/null 2>&1 && assert_pass "select JSON valid" || assert_fail "select JSON valid" "invalid"
assert_eq "select json template" "full" "$(echo "$sel_json" | jq -r '.template')"
assert_contains "select json has reason" "$(echo "$sel_json" | jq -r '.reason')" "budget"

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "CLI dispatch via sw-cost.sh"
# ═══════════════════════════════════════════════════════════════════════════

cli_preview=$(bash "$COST_SH" preview standard 50 2>&1)
assert_contains "CLI preview runs" "$cli_preview" "Total"

cli_json=$(bash "$COST_SH" preview --all 50 --json 2>/dev/null)
echo "$cli_json" | jq -e . >/dev/null 2>&1 && assert_pass "CLI preview --all --json valid" || assert_fail "CLI preview --all --json valid" "invalid"

cli_help=$(bash "$COST_SH" help 2>&1)
assert_contains "help documents preview" "$cli_help" "preview"
assert_contains "help documents select" "$cli_help" "select"
assert_contains "help documents accuracy" "$cli_help" "accuracy"

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "Historical recording & blending"
# ═══════════════════════════════════════════════════════════════════════════

# Isolate the history ledger in a temp file.
export SHIPWRIGHT_COST_HISTORY="$TEST_TEMP_DIR/cost-history.jsonl"
rm -f "$SHIPWRIGHT_COST_HISTORY"

# No history -> blended estimate equals pure static estimate.
static_std=$(cp_estimate_template standard 50)
assert_contains_regex "static estimate numeric (no history)" "$static_std" '^[0-9]+\.[0-9]+$'

# cp_history_median is empty when no actuals recorded.
assert_eq "median empty without history" "" "$(cp_history_median standard 50)"

# Record several actuals well above the static estimate, then median reflects them.
rid1=$(cp_record_actual standard 50 90.0000)
assert_contains_regex "record_actual echoes run_id" "$rid1" '.'
cp_record_actual standard 50 92.0000 >/dev/null
cp_record_actual standard 52 88.0000 >/dev/null   # within ±5 band
cp_record_actual standard 80 5.0000  >/dev/null   # outside band, must be ignored

median_std=$(cp_history_median standard 50)
assert_contains_regex "median numeric with history" "$median_std" '^[0-9]+\.[0-9]+$'
# Median should be ~90 (the in-band cluster), not pulled to 5 by out-of-band sample.
if awk -v m="$median_std" 'BEGIN { exit !(m >= 80 && m <= 95) }'; then
    assert_pass "median reflects in-band actuals, ignores out-of-band"
else
    assert_fail "median reflects in-band actuals" "got $median_std"
fi

# Blended estimate now pulled upward from the static value toward history.
blended_std=$(cp_estimate_template standard 50)
if awk -v b="$blended_std" -v s="$static_std" 'BEGIN { exit !(b > s) }'; then
    assert_pass "blended estimate exceeds static when history is higher"
else
    assert_fail "blended estimate exceeds static" "blended=$blended_std static=$static_std"
fi
# But blend is bounded below the raw median (static still has weight).
if awk -v b="$blended_std" -v m="$median_std" 'BEGIN { exit !(b < m) }'; then
    assert_pass "blended estimate stays below raw median (static weighted in)"
else
    assert_fail "blended below raw median" "blended=$blended_std median=$median_std"
fi

# A template with no history still falls back cleanly to static.
fast_static=$(cp_estimate_template fast 50)
assert_contains_regex "untracked template falls back to static" "$fast_static" '^[0-9]+\.[0-9]+$'

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "cp_accuracy reporting"
# ═══════════════════════════════════════════════════════════════════════════

rm -f "$SHIPWRIGHT_COST_HISTORY"

# Empty history -> zero samples, null mape.
acc_empty=$(cp_accuracy 1 2>/dev/null)
echo "$acc_empty" | jq -e . >/dev/null 2>&1 && assert_pass "accuracy JSON valid (empty)" || assert_fail "accuracy JSON valid (empty)" "invalid"
assert_eq "accuracy zero samples when empty" "0" "$(echo "$acc_empty" | jq -r '.samples')"

# Record matched estimate/actual pairs by run_id.
cp_record_estimate standard 50 10.0000 run-a >/dev/null
cp_record_actual   standard 50 12.0000 run-a >/dev/null   # APE = 2/12 ≈ 16.67%
cp_record_estimate fast 50 4.0000 run-b >/dev/null
cp_record_actual   fast 50 4.0000 run-b >/dev/null        # APE = 0%
# An estimate with no actual must be excluded from pairing.
cp_record_estimate full 50 50.0000 run-c >/dev/null

acc=$(cp_accuracy 1 2>/dev/null)
echo "$acc" | jq -e . >/dev/null 2>&1 && assert_pass "accuracy JSON valid" || assert_fail "accuracy JSON valid" "invalid"
assert_eq "accuracy counts only matched pairs" "2" "$(echo "$acc" | jq -r '.samples')"
mape=$(echo "$acc" | jq -r '.mape')
# Overall MAPE = (16.67 + 0)/2 ≈ 8.33
if awk -v m="$mape" 'BEGIN { exit !(m > 8 && m < 9) }'; then
    assert_pass "overall MAPE computed correctly"
else
    assert_fail "overall MAPE correct" "got $mape"
fi
assert_eq "per-template breakdown present" "2" "$(echo "$acc" | jq -r '.templates | length')"

# Human-readable output mentions OVERALL row.
acc_human=$(cp_accuracy 0 2>&1)
assert_contains "accuracy human output has OVERALL" "$acc_human" "OVERALL"

# CLI dispatch for accuracy.
cli_acc=$(SHIPWRIGHT_COST_HISTORY="$SHIPWRIGHT_COST_HISTORY" bash "$COST_SH" accuracy --json 2>/dev/null)
echo "$cli_acc" | jq -e . >/dev/null 2>&1 && assert_pass "CLI accuracy --json valid" || assert_fail "CLI accuracy --json valid" "invalid"

unset SHIPWRIGHT_COST_HISTORY

print_test_results
