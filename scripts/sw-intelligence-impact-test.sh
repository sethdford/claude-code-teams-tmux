#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-intelligence-impact-test — Unit + integration tests for the           ║
# ║  Intelligence Feature Impact Analyzer & A/B Test Framework                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

IMPACT="$SCRIPT_DIR/sw-intelligence-impact.sh"

print_test_header "Intelligence Feature Impact Analyzer"

setup_test_env "sw-intelligence-impact"
STORE="$TEST_TEMP_DIR/home/.shipwright/intelligence-impact.json"
export SW_IMPACT_FILE="$STORE"

# Helper: record a run (returns the command's exit code).
_rec() { bash "$IMPACT" record "$@"; }

# Seed a cohort: _seed <variant> <count> <successes> <cost> <duration> <iterations> <features>
_seed() {
    local variant="$1" count="$2" succ="$3" cost="$4" dur="$5" iters="$6" feats="$7" i
    for i in $(seq 1 "$count"); do
        local s="true"; [[ $i -gt $succ ]] && s="false"
        _rec --variant "$variant" --issue "$i" --success "$s" \
             --duration "$dur" --cost "$cost" --iterations "$iters" \
             --features "$feats" >/dev/null 2>&1
    done
}

# ─── record: validation & persistence ────────────────────────────────────────
print_test_section "record — input validation"

out=$(_rec --variant intel_on --issue 1 --success true --duration 100 --cost 2.0 --iterations 3 --json 2>/dev/null)
assert_json_key "valid record returns ok=true" "$out" ".ok" "true"
assert_file_exists "store created on first record" "$STORE"

ec=0; _rec --variant bogus --issue 2 --success true --json >/dev/null 2>&1 || ec=$?
assert_exit_code "bad --variant rejected" 2 "$ec"

ec=0; _rec --variant intel_on --issue 2 --success maybe --json >/dev/null 2>&1 || ec=$?
assert_exit_code "bad --success rejected" 2 "$ec"

ec=0; _rec --variant intel_on --issue 2 --success true --duration "abc" --json >/dev/null 2>&1 || ec=$?
assert_exit_code "non-numeric --duration rejected" 2 "$ec"

ec=0; _rec --variant intel_on --issue 2 --success true --iterations 1.5 --json >/dev/null 2>&1 || ec=$?
assert_exit_code "non-integer --iterations rejected" 2 "$ec"

# Bad input must not corrupt the store.
assert_pass_if_json() { if jq -e . "$STORE" >/dev/null 2>&1; then assert_pass "$1"; else assert_fail "$1"; fi; }
assert_pass_if_json "store remains valid JSON after rejected writes"

count=$(jq '.experiments|length' "$STORE")
assert_eq "only the one valid record was appended" "1" "$count"

# ─── analyze: no data ────────────────────────────────────────────────────────
print_test_section "analyze — empty store"

rm -f "$STORE"
ec=0; out=$(bash "$IMPACT" analyze --json 2>/dev/null) || ec=$?
assert_exit_code "analyze on empty store exits 3" 3 "$ec"
assert_json_key "empty-store error code is NO_DATA" "$out" ".error.code" "NO_DATA"

# ─── analyze: cohort statistics ──────────────────────────────────────────────
print_test_section "analyze — cohort statistics"

rm -f "$STORE"
# intel_on: 18/20 success; intel_off: 10/20 success.
_seed intel_on  20 18 2.6 300 4 "prediction,adversarial,convergence"
_seed intel_off 20 10 2.4 280 5 ""

out=$(bash "$IMPACT" analyze --json 2>/dev/null)
assert_json_key "total_runs is 40" "$out" ".total_runs" "40"
assert_json_key "intel_on n is 20" "$out" ".cohorts.intel_on.n" "20"
assert_json_key "intel_off n is 20" "$out" ".cohorts.intel_off.n" "20"
assert_json_key "intel_on success_rate 0.9" "$out" ".cohorts.intel_on.success_rate" "0.9"
assert_json_key "intel_off success_rate 0.5" "$out" ".cohorts.intel_off.success_rate" "0.5"

# prediction feature appears only in intel_on (helpful) → KEEP
pred=$(jq -c '.features[]|select(.feature=="prediction")' <<<"$out")
assert_json_key "prediction recommendation is KEEP" "$pred" ".recommendation" "KEEP"
assert_json_key "prediction is significant (n>=20 both)" "$pred" ".significant" "true"

# report-only feature has no flag
conv=$(jq -c '.features[]|select(.feature=="convergence")' <<<"$out")
assert_json_key "convergence has empty flag (report-only)" "$conv" ".flag" ""

# ─── report: monthly window ──────────────────────────────────────────────────
print_test_section "report — monthly window + caching"

month=$(date -u +%Y-%m)
out=$(bash "$IMPACT" report --month "$month" --json 2>/dev/null)
assert_json_key "report month matches" "$out" ".month" "$month"
assert_json_key "report verdict is significant" "$out" ".verdict" "significant"
cached=$(jq -r '.report.month' "$STORE")
assert_eq "report cached into store" "$month" "$cached"

ec=0; out=$(bash "$IMPACT" report --month 1999-01 --json 2>/dev/null) || ec=$?
assert_exit_code "report for empty month exits 3" 3 "$ec"

ec=0; bash "$IMPACT" report --month bad-format --json >/dev/null 2>&1 || ec=$?
assert_exit_code "report rejects malformed --month" 2 "$ec"

# ─── apply: significance gate ────────────────────────────────────────────────
print_test_section "apply — significance gate"

rm -f "$STORE"
_seed intel_on 5 4 2.0 200 3 "prediction"
mkdir -p "$TEST_TEMP_DIR/.claude"
CONFIG="$TEST_TEMP_DIR/.claude/daemon-config.json"
echo '{"intelligence":{"prediction_enabled":true}}' > "$CONFIG"
export SW_DAEMON_CONFIG="$CONFIG"

ec=0; out=$(bash "$IMPACT" apply --json 2>/dev/null) || ec=$?
assert_exit_code "apply below threshold exits 3" 3 "$ec"
assert_json_key "gate error code INSUFFICIENT_DATA" "$out" ".error.code" "INSUFFICIENT_DATA"
unchanged=$(jq -r '.intelligence.prediction_enabled' "$CONFIG")
assert_eq "config untouched when gated" "true" "$unchanged"

# ─── apply: auto-disable a negative-ROI feature ──────────────────────────────
print_test_section "apply — auto-disable negative-ROI feature"

rm -f "$STORE"
# Runs WITH simulation: bad (5/20, costly). WITHOUT: good (18/20, cheap).
_seed intel_on  20  5 5.0 400 6 "simulation"
_seed intel_off 20 18 2.0 250 3 ""
echo '{"intelligence":{"simulation_enabled":true}}' > "$CONFIG"

out=$(bash "$IMPACT" analyze --json 2>/dev/null)
sim=$(jq -c '.features[]|select(.feature=="simulation")' <<<"$out")
assert_json_key "simulation recommendation is DISABLE" "$sim" ".recommendation" "DISABLE"

# Dry-run makes no change.
out=$(bash "$IMPACT" apply --dry-run --json 2>/dev/null)
assert_json_key "dry-run reports would_disable simulation" "$out" ".would_disable[0].feature" "simulation"
still=$(jq -r '.intelligence.simulation_enabled' "$CONFIG")
assert_eq "dry-run leaves flag true" "true" "$still"

# Real apply flips the flag + writes a note + backup.
out=$(bash "$IMPACT" apply --json 2>/dev/null)
assert_json_key "apply disabled simulation" "$out" ".disabled[0].feature" "simulation"
flag=$(jq -r '.intelligence.simulation_enabled' "$CONFIG")
assert_eq "flag flipped to false" "false" "$flag"
note=$(jq -r '.intelligence.intelligence_impact_notes.simulation.reason' "$CONFIG")
assert_eq "explanatory note written" "negative ROI" "$note"
assert_file_exists "backup written" "${CONFIG}.impact-bak"
assert_pass_if_config() { if jq -e . "$CONFIG" >/dev/null 2>&1; then assert_pass "$1"; else assert_fail "$1"; fi; }
assert_pass_if_config "config remains valid JSON after apply"

# Idempotent re-apply leaves a valid config with flag still false.
bash "$IMPACT" apply --json >/dev/null 2>&1
flag2=$(jq -r '.intelligence.simulation_enabled' "$CONFIG")
assert_eq "re-apply is idempotent (flag stays false)" "false" "$flag2"

# ─── status ──────────────────────────────────────────────────────────────────
print_test_section "status"

out=$(bash "$IMPACT" status --json 2>/dev/null)
assert_json_key "status reports intel_on count" "$out" ".intel_on" "20"
assert_json_key "status reports min_samples" "$out" ".min_samples" "20"

# ─── smoke: record→report round-trip via the real script ─────────────────────
print_test_section "smoke — record→report round-trip"

rm -f "$STORE"
_rec --variant intel_on --issue 99 --success true --duration 120 --cost 1.5 --iterations 2 --features "prediction" >/dev/null 2>&1
rt=$(bash "$IMPACT" report --json 2>/dev/null)
assert_json_key "round-trip report sees 1 run" "$rt" ".total_runs" "1"
assert_json_key "round-trip report is advisory (n<20)" "$rt" ".verdict" "advisory"

cleanup_test_env
print_test_results
