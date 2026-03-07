#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Adaptive Stage Timeout Engine — Validate P95 auto-tuning and apply      ║
# ║  Tests P95 duration-based auto-tuning, recommendations, and apply logic  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-adaptive-timeout-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/project/.claude"

    # Link real jq and sqlite3
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    if command -v sqlite3 &>/dev/null; then
        ln -sf "$(command -v sqlite3)" "$TEST_TEMP_DIR/bin/sqlite3"
    fi
    if command -v bc &>/dev/null; then
        ln -sf "$(command -v bc)" "$TEST_TEMP_DIR/bin/bc"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Create empty events file
    touch "$TEST_TEMP_DIR/home/.shipwright/events.jsonl"

    # Create minimal daemon-config.json
    echo '{}' > "$TEST_TEMP_DIR/project/.claude/daemon-config.json"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    export REPO_DIR="$TEST_TEMP_DIR/project"
}

trap cleanup_test_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "Adaptive Stage Timeout Engine Tests"

setup_env

# ─── Test 1: help command ────────────────────────────────────────────────────
echo -e "${DIM}  CLI basics${RESET}"

output=$(bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows USAGE" "$output" "USAGE"
assert_contains "help shows SUBCOMMANDS" "$output" "SUBCOMMANDS"
assert_contains "help mentions analyze" "$output" "analyze"
assert_contains "help mentions apply" "$output" "apply"
assert_contains "help mentions show" "$output" "show"
assert_contains "help mentions history" "$output" "history"

# ─── Test 2: version command ────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" version 2>&1) && rc=0 || rc=$?
assert_eq "version exits 0" "0" "$rc"
assert_contains "version output" "$output" "sw-adaptive-timeout"

# ─── Test 3: unknown command exits non-zero ─────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" nonexistent 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "Unknown command exits non-zero"
else
    assert_fail "Unknown command exits non-zero"
fi

# ─── Test 4: script safety ──────────────────────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-adaptive-timeout.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

if grep -q 'BASH_SOURCE\[0\].*==.*\$0' "$SCRIPT_DIR/sw-adaptive-timeout.sh"; then
    assert_pass "Has source guard pattern"
else
    assert_fail "Has source guard pattern"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LIBRARY: stage-duration-metrics.sh
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  stage-duration-metrics.sh library${RESET}"

# ─── Test 5: Library loads without error ─────────────────────────────────────
lib_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/stage-duration-metrics.sh" 2>/dev/null
echo "loaded"
' 2>/dev/null)
assert_eq "stage-duration-metrics.sh loads" "loaded" "$lib_out"

# ─── Test 6: record_stage_duration with valid input ─────────────────────────
rec_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
emit_event() { true; }
db_save_stage_duration() { echo "saved:$1:$2:$3:$4:$5"; }
source "$SCRIPT_DIR/lib/stage-duration-metrics.sh" 2>/dev/null
REPO_DIR="/tmp/test"
record_stage_duration "build" "120" "complete" "12345" "job1"
' 2>/dev/null)
assert_contains "record_stage_duration calls db_save" "$rec_out" "saved:job1:build:120:complete:12345"

# ─── Test 7: record_stage_duration rejects >24h durations ───────────────────
rec_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
emit_event() { echo "event:$1"; }
db_save_stage_duration() { echo "should_not_save"; }
source "$SCRIPT_DIR/lib/stage-duration-metrics.sh" 2>/dev/null
record_stage_duration "build" "90000" "complete" "12345"
' 2>/dev/null)
if echo "$rec_out" | grep -qF "should_not_save"; then
    assert_fail "record_stage_duration rejects >24h"
else
    assert_pass "record_stage_duration rejects >24h"
fi

# ─── Test 8: record_stage_duration skips invalid ────────────────────────────
rec_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
emit_event() { true; }
db_save_stage_duration() { echo "should_not_save"; }
source "$SCRIPT_DIR/lib/stage-duration-metrics.sh" 2>/dev/null
record_stage_duration "build" "abc" "complete" "12345"
' 2>/dev/null)
if echo "$rec_out" | grep -qF "should_not_save"; then
    assert_fail "record_stage_duration skips invalid duration"
else
    assert_pass "record_stage_duration skips invalid duration"
fi

# ─── Test 9: record_timeout_event calls record_stage_duration ────────────────
rec_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
emit_event() { echo "event:$1:$*"; }
db_save_stage_duration() { echo "saved:$2:$4"; }
source "$SCRIPT_DIR/lib/stage-duration-metrics.sh" 2>/dev/null
REPO_DIR="/tmp/test"
record_timeout_event "build" "12345" "1800" "1900"
' 2>/dev/null)
assert_contains "record_timeout_event records timeout" "$rec_out" "saved:build:timeout"
assert_contains "record_timeout_event emits event" "$rec_out" "event:timeout.detected"

# ═══════════════════════════════════════════════════════════════════════════════
# LIBRARY: timeout-recommendation-engine.sh
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  timeout-recommendation-engine.sh library${RESET}"

# ─── Test 10: Library loads without error ────────────────────────────────────
lib_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
echo "loaded"
' 2>/dev/null)
assert_eq "timeout-recommendation-engine.sh loads" "loaded" "$lib_out"

# ─── Test 11: _calc_percentile with known data ──────────────────────────────
p95=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
_calc_percentile "[10, 20, 30, 40, 50, 60, 70, 80, 90, 100]" 95
' 2>/dev/null)
if [[ -n "$p95" && "$p95" != "0" ]]; then
    assert_pass "P95 of [10..100] returns non-zero value ($p95)"
else
    assert_fail "P95 of [10..100] returns non-zero value" "got: $p95"
fi

# ─── Test 12: _calc_percentile P50 is median ────────────────────────────────
p50=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
_calc_percentile "[10, 20, 30, 40, 50]" 50
' 2>/dev/null)
# For 5 elements, P50 index = 0.5 * 4 = 2, so floor(2) = idx 2, value = (30+40)/2 = 35 or 30
if [[ -n "$p50" ]] && [[ "${p50%%.*}" -ge 20 ]] && [[ "${p50%%.*}" -le 40 ]]; then
    assert_pass "P50 of [10..50] is around median ($p50)"
else
    assert_fail "P50 of [10..50] is around median" "got: $p50"
fi

# ─── Test 13: _calc_percentile empty array ───────────────────────────────────
p_empty=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
_calc_percentile "[]" 95
' 2>/dev/null)
assert_eq "P95 of empty array returns 0" "0" "$p_empty"

# ─── Test 14: _calc_percentile single element ───────────────────────────────
p_single=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
_calc_percentile "[42]" 95
' 2>/dev/null)
assert_eq "P95 of [42] returns 42" "42" "$p_single"

# ─── Test 15: _calc_percentile all same value ────────────────────────────────
p_same=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
_calc_percentile "[100, 100, 100, 100, 100]" 95
' 2>/dev/null)
assert_eq "P95 of [100,100,100,100,100] returns 100" "100" "$p_same"

# ─── Test 16: get_stage_duration_stats with no data ──────────────────────────
stats_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
db_query_stage_durations() { echo "[]"; }
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
get_stage_duration_stats "build" "" 30
' 2>/dev/null)
count=$(echo "$stats_out" | jq '.count' 2>/dev/null || echo "err")
assert_eq "get_stage_duration_stats returns count=0 with no data" "0" "$count"

# ─── Test 17: get_stage_duration_stats with data ─────────────────────────────
stats_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
db_query_stage_durations() { echo "[60, 90, 120, 150, 180, 200, 220, 240, 260, 300]"; }
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
get_stage_duration_stats "build" "" 30
' 2>/dev/null)
count=$(echo "$stats_out" | jq '.count' 2>/dev/null || echo "err")
assert_eq "get_stage_duration_stats returns count=10" "10" "$count"
p95_val=$(echo "$stats_out" | jq '.p95' 2>/dev/null || echo "0")
if [[ -n "$p95_val" ]] && [[ "${p95_val%%.*}" -gt 0 ]]; then
    assert_pass "get_stage_duration_stats P95 is non-zero ($p95_val)"
else
    assert_fail "get_stage_duration_stats P95 is non-zero" "got: $p95_val"
fi

# ─── Test 18: calculate_recommended_timeout with insufficient data ───────────
echo ""
echo -e "${DIM}  recommendation engine${RESET}"

rec_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
db_query_stage_durations() { echo "[60, 90, 120]"; }
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
calculate_recommended_timeout "build" ""
' 2>/dev/null)
rec_timeout=$(echo "$rec_out" | jq '.recommended_timeout' 2>/dev/null || echo "err")
assert_eq "recommend returns 0 with <10 samples" "0" "$rec_timeout"
rationale=$(echo "$rec_out" | jq -r '.rationale' 2>/dev/null || echo "")
assert_contains "rationale mentions insufficient data" "$rationale" "insufficient_data"

# ─── Test 19: calculate_recommended_timeout with sufficient data ──────────────
rec_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
db_query_stage_durations() { echo "[60, 90, 120, 150, 180, 200, 220, 240, 260, 300, 330, 360]"; }
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
calculate_recommended_timeout "build" "" "1.2" "60" "7200"
' 2>/dev/null)
rec_timeout=$(echo "$rec_out" | jq '.recommended_timeout' 2>/dev/null || echo "0")
if [[ "$rec_timeout" -gt 0 ]]; then
    assert_pass "recommend returns >0 with 12 samples (got ${rec_timeout}s)"
else
    assert_fail "recommend returns >0 with 12 samples" "got: $rec_timeout"
fi
# Should be P95 * 1.2, which is roughly 346 * 1.2 = 415
if [[ "$rec_timeout" -ge 60 ]] && [[ "$rec_timeout" -le 7200 ]]; then
    assert_pass "recommend respects min/max bounds"
else
    assert_fail "recommend respects min/max bounds" "got: $rec_timeout"
fi

# ─── Test 20: calculate_recommended_timeout min clamp ─────────────────────────
rec_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
db_query_stage_durations() { echo "[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]"; }
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
calculate_recommended_timeout "build" "" "1.2" "300" "7200"
' 2>/dev/null)
rec_timeout=$(echo "$rec_out" | jq '.recommended_timeout' 2>/dev/null || echo "0")
assert_eq "recommend clamps to min_timeout=300" "300" "$rec_timeout"

# ─── Test 21: calculate_recommended_timeout anomaly detection ─────────────────
rec_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
db_query_stage_durations() { echo "[100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 5000]"; }
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
calculate_recommended_timeout "build" "" "1.2" "60" "7200"
' 2>/dev/null)
rationale=$(echo "$rec_out" | jq -r '.rationale' 2>/dev/null || echo "")
assert_contains "anomaly flagged in rationale" "$rationale" "ANOMALY"

# ═══════════════════════════════════════════════════════════════════════════════
# CLI INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  CLI integration${RESET}"

# ─── Test 22: show command runs without error ─────────────────────────────────
output=$(DAEMON_CONFIG="$TEST_TEMP_DIR/project/.claude/daemon-config.json" REPO_DIR="$TEST_TEMP_DIR/project" \
    bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" show 2>&1) && rc=0 || rc=$?
assert_eq "show exits 0" "0" "$rc"
assert_contains "show displays stage names" "$output" "build"
assert_contains "show displays header" "$output" "Stage"

# ─── Test 23: show --json outputs valid JSON ──────────────────────────────────
output=$(DAEMON_CONFIG="$TEST_TEMP_DIR/project/.claude/daemon-config.json" REPO_DIR="$TEST_TEMP_DIR/project" \
    bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" show --json 2>&1) && rc=0 || rc=$?
if echo "$output" | jq . >/dev/null 2>&1; then
    assert_pass "show --json outputs valid JSON"
else
    assert_fail "show --json outputs valid JSON" "output: ${output:0:100}"
fi

# ─── Test 24: analyze command runs ────────────────────────────────────────────
output=$(DAEMON_CONFIG="$TEST_TEMP_DIR/project/.claude/daemon-config.json" REPO_DIR="$TEST_TEMP_DIR/project" \
    bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" analyze 2>&1) && rc=0 || rc=$?
assert_eq "analyze exits 0" "0" "$rc"
assert_contains "analyze shows stage info" "$output" "Analyzed"

# ─── Test 25: analyze --json outputs valid JSON ──────────────────────────────
output=$(DAEMON_CONFIG="$TEST_TEMP_DIR/project/.claude/daemon-config.json" REPO_DIR="$TEST_TEMP_DIR/project" \
    bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" analyze --json 2>&1) && rc=0 || rc=$?
if echo "$output" | jq . >/dev/null 2>&1; then
    assert_pass "analyze --json outputs valid JSON"
else
    assert_fail "analyze --json outputs valid JSON" "output: ${output:0:100}"
fi

# ─── Test 26: apply --dry-run ────────────────────────────────────────────────
output=$(DAEMON_CONFIG="$TEST_TEMP_DIR/project/.claude/daemon-config.json" REPO_DIR="$TEST_TEMP_DIR/project" \
    bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" apply --dry-run 2>&1) && rc=0 || rc=$?
assert_eq "apply --dry-run exits 0" "0" "$rc"
assert_contains "apply --dry-run mentions dry run" "$output" "ry run"

# ─── Test 27: status command ─────────────────────────────────────────────────
output=$(DAEMON_CONFIG="$TEST_TEMP_DIR/project/.claude/daemon-config.json" REPO_DIR="$TEST_TEMP_DIR/project" \
    bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" status 2>&1) && rc=0 || rc=$?
assert_eq "status exits 0" "0" "$rc"
assert_contains "status shows enabled" "$output" "Enabled"

# ─── Test 28: history command with no data ───────────────────────────────────
output=$(DAEMON_CONFIG="$TEST_TEMP_DIR/project/.claude/daemon-config.json" REPO_DIR="$TEST_TEMP_DIR/project" \
    bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" history 2>&1) && rc=0 || rc=$?
assert_eq "history exits 0" "0" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIG INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  config integration${RESET}"

# ─── Test 29: apply creates adaptive_timeouts section ─────────────────────────
echo '{"max_parallel": 2}' > "$TEST_TEMP_DIR/project/.claude/daemon-config.json"
output=$(DAEMON_CONFIG="$TEST_TEMP_DIR/project/.claude/daemon-config.json" REPO_DIR="$TEST_TEMP_DIR/project" \
    bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" apply 2>&1) && rc=0 || rc=$?
has_section=$(jq 'has("adaptive_timeouts")' "$TEST_TEMP_DIR/project/.claude/daemon-config.json" 2>/dev/null || echo "false")
assert_eq "apply creates adaptive_timeouts section" "true" "$has_section"

# ─── Test 30: config preserves existing keys ──────────────────────────────────
max_par=$(jq '.max_parallel' "$TEST_TEMP_DIR/project/.claude/daemon-config.json" 2>/dev/null || echo "0")
assert_eq "apply preserves existing keys" "2" "$max_par"

# ─── Test 31: manual_overrides respected ──────────────────────────────────────
echo '{"adaptive_timeouts": {"enabled": true, "manual_overrides": {"build": 999}, "stage_timeouts": {}}}' > "$TEST_TEMP_DIR/project/.claude/daemon-config.json"
output=$(DAEMON_CONFIG="$TEST_TEMP_DIR/project/.claude/daemon-config.json" REPO_DIR="$TEST_TEMP_DIR/project" \
    bash "$SCRIPT_DIR/sw-adaptive-timeout.sh" show --json 2>&1) && rc=0 || rc=$?
build_source=$(echo "$output" | jq -r '.build.source' 2>/dev/null || echo "unknown")
assert_eq "manual override shows source=manual" "manual" "$build_source"
build_timeout=$(echo "$output" | jq '.build.timeout' 2>/dev/null || echo "0")
assert_eq "manual override uses configured value" "999" "$build_timeout"

# ═══════════════════════════════════════════════════════════════════════════════
# GENERATE ADJUSTMENT REPORT
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  adjustment report${RESET}"

# ─── Test 32: generate_adjustment_report filters by threshold ─────────────────
report_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
# Mock: return enough samples with P95 ~= 500 -> recommend 600 vs default 1800 for build (big change)
db_query_stage_durations() {
    local s="$1"
    if [[ "$s" == "build" ]]; then
        echo "[300, 350, 400, 420, 440, 460, 480, 490, 495, 500, 510, 520]"
    else
        echo "[]"
    fi
}
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
generate_adjustment_report "" ""
' 2>/dev/null)
adj_count=$(echo "$report_out" | jq 'length' 2>/dev/null || echo "0")
if [[ "$adj_count" -gt 0 ]]; then
    assert_pass "adjustment report includes build stage ($adj_count adjustments)"
else
    assert_fail "adjustment report includes build stage" "got 0 adjustments"
fi

# Check that change_percent is significant
if [[ "$adj_count" -gt 0 ]]; then
    first_stage=$(echo "$report_out" | jq -r '.[0].stage_type' 2>/dev/null || echo "")
    assert_eq "first adjustment is build" "build" "$first_stage"
fi

# ─── Test 33: apply with manual override skips stage ──────────────────────────
apply_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
db_query_stage_durations() {
    local s="$1"
    if [[ "$s" == "build" ]]; then
        echo "[300, 350, 400, 420, 440, 460, 480, 490, 495, 500, 510, 520]"
    else
        echo "[]"
    fi
}
_db_exec() { true; }
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
echo "{\"adaptive_timeouts\": {\"manual_overrides\": {\"build\": 999}, \"stage_timeouts\": {\"build\": 1800}}}" > /tmp/sw-test-config-$$.json
apply_timeout_recommendations "" "/tmp/sw-test-config-$$.json" "true"
rm -f /tmp/sw-test-config-$$.json
' 2>/dev/null)
stages_updated=$(echo "$apply_out" | jq '.stages_updated' 2>/dev/null || echo "err")
assert_eq "apply with manual override: 0 stages updated" "0" "$stages_updated"
skipped=$(echo "$apply_out" | jq '[.adjustments[] | select(.skipped == true)] | length' 2>/dev/null || echo "0")
if [[ "$skipped" -gt 0 ]]; then
    assert_pass "manual override marked as skipped"
else
    assert_fail "manual override marked as skipped"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# DB SCHEMA (v8 migration)
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  DB schema v8${RESET}"

# ─── Test 34: timeout_recommendations table exists after migration ────────────
if command -v sqlite3 >/dev/null 2>&1; then
    db_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" DB_FILE="$TEST_TEMP_DIR/home/.shipwright/shipwright.db" bash -c '
    source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null
    migrate_schema 2>/dev/null || true
    sqlite3 "$DB_FILE" ".tables" 2>/dev/null
    ' 2>/dev/null)
    assert_contains "timeout_recommendations table exists" "$db_out" "timeout_recommendations"
    assert_contains "timeout_adjustments table exists" "$db_out" "timeout_adjustments"
else
    assert_pass "DB tests skipped (no sqlite3)"
    assert_pass "DB tests skipped (no sqlite3)"
fi

# ─── Test 35: db_save_timeout_adjustment works ────────────────────────────────
if command -v sqlite3 >/dev/null 2>&1; then
    adj_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" DB_FILE="$TEST_TEMP_DIR/home/.shipwright/shipwright.db" bash -c '
    source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null
    migrate_schema 2>/dev/null || true
    db_save_timeout_adjustment "hash123" "build" 1800 600 "auto_p95" 2>/dev/null && echo "ok" || echo "fail"
    ' 2>/dev/null)
    assert_contains "db_save_timeout_adjustment succeeds" "$adj_out" "ok"

    # Query back
    query_out=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" DB_FILE="$TEST_TEMP_DIR/home/.shipwright/shipwright.db" bash -c '
    source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null
    migrate_schema 2>/dev/null || true
    sqlite3 "$DB_FILE" "SELECT stage_type, old_timeout, new_timeout FROM timeout_adjustments WHERE repo_hash='"'"'hash123'"'"';" 2>/dev/null
    ' 2>/dev/null)
    assert_contains "timeout_adjustment saved correctly" "$query_out" "build|1800|600"
else
    assert_pass "DB save test skipped (no sqlite3)"
    assert_pass "DB query test skipped (no sqlite3)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PERFORMANCE: Percentile with large dataset
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  performance${RESET}"

# ─── Test 36: Percentile calc with 1000+ values ──────────────────────────────
perf_start=$(date +%s%N 2>/dev/null || date +%s)
p95_large=$(cd "$SCRIPT_DIR" && SCRIPT_DIR="$SCRIPT_DIR" HOME="$TEST_TEMP_DIR/home" bash -c '
source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" 2>/dev/null
# Generate 1000 values
arr=$(jq -n "[range(1; 1001)]")
_calc_percentile "$arr" 95
' 2>/dev/null)
perf_end=$(date +%s%N 2>/dev/null || date +%s)
if [[ -n "$p95_large" ]] && [[ "${p95_large%%.*}" -gt 900 ]]; then
    assert_pass "P95 of 1..1000 returns ~950 (got ${p95_large%%.*})"
else
    assert_fail "P95 of 1..1000 returns ~950" "got: $p95_large"
fi

# Check timing (should be <5 seconds)
if [[ "${perf_end}" =~ ^[0-9]+$ ]] && [[ "${perf_start}" =~ ^[0-9]+$ ]]; then
    if [[ ${#perf_end} -gt 10 ]]; then
        # nanoseconds
        elapsed_ms=$(( (perf_end - perf_start) / 1000000 ))
    else
        elapsed_ms=$(( (perf_end - perf_start) * 1000 ))
    fi
    if [[ "$elapsed_ms" -lt 5000 ]]; then
        assert_pass "P95 of 1000 values computed in <5s (${elapsed_ms}ms)"
    else
        assert_fail "P95 of 1000 values computed in <5s" "took ${elapsed_ms}ms"
    fi
else
    assert_pass "Performance timing skipped (no nanosecond clock)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# CLI ROUTER
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  CLI router${RESET}"

# ─── Test 37: CLI router has adaptive-timeout entry ───────────────────────────
if grep -q 'adaptive-timeout' "$SCRIPT_DIR/sw"; then
    assert_pass "CLI router has adaptive-timeout entry"
else
    assert_fail "CLI router has adaptive-timeout entry"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
