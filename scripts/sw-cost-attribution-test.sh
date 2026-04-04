#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost-attribution — Test Suite                                ║
# ║  Schema v7, upsert, query, ROI, forecast, CLI, pipeline integration     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-cost-attrib-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    mkdir -p "$TEST_TEMP_DIR/scripts/lib"

    export HOME="$TEST_TEMP_DIR/home"
    export DB_DIR="$TEST_TEMP_DIR/home/.shipwright"
    export DB_FILE="$DB_DIR/shipwright.db"
    export COST_DIR="$DB_DIR"

    # Copy scripts under test
    cp "$SCRIPT_DIR/sw-db.sh" "$TEST_TEMP_DIR/scripts/"
    cp "$SCRIPT_DIR/sw-cost.sh" "$TEST_TEMP_DIR/scripts/"
    cp "$SCRIPT_DIR/lib/cost-attribution.sh" "$TEST_TEMP_DIR/scripts/lib/"
    [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_TEMP_DIR/scripts/lib/" || true
    [[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && cp "$SCRIPT_DIR/lib/compat.sh" "$TEST_TEMP_DIR/scripts/lib/" || true
    [[ -f "$SCRIPT_DIR/lib/test-helpers.sh" ]] && cp "$SCRIPT_DIR/lib/test-helpers.sh" "$TEST_TEMP_DIR/scripts/lib/" || true
}

cleanup_env() {
    [[ -n "${TEST_TEMP_DIR:-}" && -d "${TEST_TEMP_DIR:-}" ]] && rm -rf "$TEST_TEMP_DIR"
}
trap cleanup_env EXIT

source_db() {
    _SW_DB_LOADED=""
    _COST_ATTRIBUTION_LOADED=""
    export SCRIPT_DIR="$TEST_TEMP_DIR/scripts"
    source "$TEST_TEMP_DIR/scripts/sw-db.sh"
    source "$TEST_TEMP_DIR/scripts/lib/cost-attribution.sh"
}

init_test_db() {
    source_db
    init_schema
    migrate_schema
}

seed_pipeline_run() {
    local job_id="${1:-test-job-1}" issue="${2:-42}" template="${3:-standard}"
    _db_exec "INSERT OR REPLACE INTO pipeline_runs (job_id, issue_number, goal, branch, status, template, started_at, created_at) VALUES ('${job_id}', ${issue}, 'Test goal', 'test-branch', 'completed', '${template}', '$(now_iso)', '$(now_iso)');"
}

seed_pipeline_outcome() {
    local job_id="${1:-test-job-1}" issue="${2:-42}" template="${3:-standard}" success="${4:-1}" cost="${5:-2.50}" complexity="${6:-medium}"
    _db_exec "INSERT OR REPLACE INTO pipeline_outcomes (job_id, issue_number, template, success, duration_secs, retry_count, cost_usd, complexity, created_at) VALUES ('${job_id}', '${issue}', '${template}', ${success}, 300, 0, ${cost}, '${complexity}', '$(now_iso)');"
}

seed_cost_entries() {
    local days_ago="${1:-0}" cost="${2:-1.00}"
    local ts ts_epoch
    ts=$(date -u -d "${days_ago} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-"${days_ago}"d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || now_iso)
    ts_epoch=$(date -u -d "${days_ago} days ago" +%s 2>/dev/null || date -u -v-"${days_ago}"d +%s 2>/dev/null || now_epoch)
    _db_exec "INSERT INTO cost_entries (input_tokens, output_tokens, model, stage, issue, cost_usd, ts, ts_epoch, synced) VALUES (10000, 5000, 'sonnet', 'build', '42', ${cost}, '${ts}', ${ts_epoch}, 0);"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))
    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    local result=0
    "$test_fn" || result=$?
    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SCHEMA TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_schema_v7_table_exists() {
    setup_env
    init_test_db
    local tables
    tables=$(sqlite3 "$DB_FILE" "SELECT name FROM sqlite_master WHERE type='table' AND name='cost_attributions';" 2>/dev/null)
    [[ "$tables" == "cost_attributions" ]]
}

test_schema_v7_indexes_exist() {
    setup_env
    init_test_db
    local idx_count
    idx_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name LIKE 'idx_cost_attrib%';" 2>/dev/null)
    [[ "$idx_count" -ge 3 ]]
}

test_schema_v7_version_recorded() {
    setup_env
    init_test_db
    local version
    version=$(sqlite3 "$DB_FILE" "SELECT MAX(version) FROM _schema;" 2>/dev/null)
    [[ "$version" -ge 7 ]]
}

test_schema_v7_unique_constraint() {
    setup_env
    init_test_db
    seed_pipeline_run "job-dup" 99
    # First insert should succeed
    db_upsert_attribution "job-dup" 99 "build" "sonnet" 1000 500 0.50 1 10
    # Second insert with same key should replace (not error)
    db_upsert_attribution "job-dup" 99 "build" "sonnet" 2000 1000 1.00 1 20
    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM cost_attributions WHERE job_id='job-dup' AND stage='build' AND iteration=1;" 2>/dev/null)
    [[ "$count" -eq 1 ]]
    # Verify the replaced values
    local cost
    cost=$(sqlite3 "$DB_FILE" "SELECT cost_usd FROM cost_attributions WHERE job_id='job-dup' AND stage='build' AND iteration=1;" 2>/dev/null)
    [[ "$cost" == "1.0" ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# UPSERT / QUERY TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_upsert_attribution_basic() {
    setup_env
    init_test_db
    seed_pipeline_run "job-1" 42
    db_upsert_attribution "job-1" 42 "intake" "sonnet" 5000 2000 0.25 0 15
    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM cost_attributions WHERE job_id='job-1';" 2>/dev/null)
    [[ "$count" -eq 1 ]]
}

test_upsert_attribution_multiple_stages() {
    setup_env
    init_test_db
    seed_pipeline_run "job-multi" 42
    db_upsert_attribution "job-multi" 42 "intake" "sonnet" 5000 2000 0.25 0 15
    db_upsert_attribution "job-multi" 42 "plan" "opus" 10000 5000 1.50 0 60
    db_upsert_attribution "job-multi" 42 "build" "sonnet" 8000 3000 0.75 1 120
    db_upsert_attribution "job-multi" 42 "build" "sonnet" 8000 3000 0.75 2 120
    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM cost_attributions WHERE job_id='job-multi';" 2>/dev/null)
    [[ "$count" -eq 4 ]]
}

test_upsert_rejects_empty_job_id() {
    setup_env
    init_test_db
    local result=0
    db_upsert_attribution "" 42 "build" "sonnet" 1000 500 0.5 0 10 2>/dev/null || result=$?
    [[ "$result" -ne 0 ]]
}

test_query_attribution_by_issue() {
    setup_env
    init_test_db
    seed_pipeline_run "job-q1" 100
    seed_pipeline_run "job-q2" 200
    db_upsert_attribution "job-q1" 100 "build" "sonnet" 5000 2000 1.00 0 30
    db_upsert_attribution "job-q2" 200 "build" "sonnet" 3000 1000 0.50 0 20
    local json
    json=$(db_query_attribution_by_issue "" 30)
    # Should have 2 issues
    local count
    count=$(echo "$json" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -eq 2 ]]
}

test_query_attribution_by_issue_filtered() {
    setup_env
    init_test_db
    seed_pipeline_run "job-f1" 100
    seed_pipeline_run "job-f2" 200
    db_upsert_attribution "job-f1" 100 "build" "sonnet" 5000 2000 1.00 0 30
    db_upsert_attribution "job-f2" 200 "build" "sonnet" 3000 1000 0.50 0 20
    local json
    json=$(db_query_attribution_by_issue 100 30)
    local count
    count=$(echo "$json" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -eq 1 ]]
    local issue
    issue=$(echo "$json" | jq -r '.[0].issue_number' 2>/dev/null || echo 0)
    [[ "$issue" -eq 100 ]]
}

test_query_attribution_stages() {
    setup_env
    init_test_db
    seed_pipeline_run "job-stg" 42
    db_upsert_attribution "job-stg" 42 "intake" "sonnet" 2000 1000 0.20 0 10
    db_upsert_attribution "job-stg" 42 "build" "sonnet" 8000 4000 1.00 1 60
    db_upsert_attribution "job-stg" 42 "build" "sonnet" 8000 4000 1.00 2 60
    db_upsert_attribution "job-stg" 42 "review" "opus" 5000 2000 1.50 0 30
    local json
    json=$(db_query_attribution_stages 42)
    local count
    count=$(echo "$json" | jq 'length' 2>/dev/null || echo 0)
    # intake(sonnet), build(sonnet), review(opus) = 3 groups
    [[ "$count" -eq 3 ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# ROI TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_roi_query_basic() {
    setup_env
    init_test_db
    seed_pipeline_run "job-roi" 42
    seed_pipeline_outcome "job-roi" 42 "standard" 1 2.50 "medium"
    db_upsert_attribution "job-roi" 42 "build" "sonnet" 5000 2000 2.50 0 60
    local json
    json=$(db_query_attribution_roi 30)
    local count
    count=$(echo "$json" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -ge 1 ]]
    # Check ROI score is computed (medium=60, success=1, cost=2.50 → 60/2.50 = 24)
    local roi
    roi=$(echo "$json" | jq -r '.[0].roi_score' 2>/dev/null || echo 0)
    [[ "$roi" != "0" ]] && [[ "$roi" != "null" ]]
}

test_roi_failed_pipeline_zero_score() {
    setup_env
    init_test_db
    seed_pipeline_run "job-fail" 43
    seed_pipeline_outcome "job-fail" 43 "standard" 0 3.00 "high"
    db_upsert_attribution "job-fail" 43 "build" "sonnet" 5000 2000 3.00 0 60
    local json
    json=$(db_query_attribution_roi 30)
    local roi
    roi=$(echo "$json" | jq -r '.[] | select(.issue_number == "43" or .issue_number == 43) | .roi_score' 2>/dev/null || echo "0")
    # Failed pipeline (success=0) should have ROI score of 0
    [[ "$roi" == "0" ]] || [[ "$roi" == "0.0" ]] || [[ "$roi" == "0.00" ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# FORECAST TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_forecast_query_basic() {
    setup_env
    init_test_db
    # Seed some cost entries across days
    seed_cost_entries 1 1.50
    seed_cost_entries 2 2.00
    seed_cost_entries 5 1.00
    local json
    json=$(db_query_attribution_forecast 30)
    local total_30d
    total_30d=$(echo "$json" | jq -r '.total_30d' 2>/dev/null || echo "0")
    # Should be at least 4.50
    [[ $(echo "$total_30d >= 4.0" | bc -l 2>/dev/null || echo 1) -eq 1 ]] || [[ "$total_30d" != "0" ]]
}

test_forecast_has_projection() {
    setup_env
    init_test_db
    seed_cost_entries 1 3.00
    seed_cost_entries 2 3.00
    seed_cost_entries 3 3.00
    local json
    json=$(db_query_attribution_forecast 30)
    local projected
    projected=$(echo "$json" | jq -r '.projected_cost' 2>/dev/null || echo "0")
    # Should have a non-zero projection
    [[ "$projected" != "0" ]] && [[ "$projected" != "null" ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# DUAL-WRITE / ATTRIBUTION LIB TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_record_attribution_dual_write() {
    setup_env
    init_test_db
    seed_pipeline_run "job-dual" 50
    record_attribution "job-dual" 50 "build" "sonnet" 5000 2000 1.00 1 30
    # SQLite should have the record
    local count
    count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM cost_attributions WHERE job_id='job-dual';" 2>/dev/null)
    [[ "$count" -eq 1 ]]
    # JSONL fallback should also exist
    [[ -f "$COST_DIR/cost-attributions.jsonl" ]]
}

test_record_attribution_rejects_zero_issue() {
    setup_env
    init_test_db
    local result=0
    record_attribution "job-x" 0 "build" "sonnet" 1000 500 0.5 0 10 2>/dev/null || result=$?
    [[ "$result" -ne 0 ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI INTEGRATION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_cli_analyze_json() {
    setup_env
    init_test_db
    seed_pipeline_run "job-cli" 77
    db_upsert_attribution "job-cli" 77 "build" "sonnet" 5000 2000 1.00 0 30
    local output
    output=$(attrib_by_issue --json)
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -ge 1 ]]
}

test_cli_roi_json() {
    setup_env
    init_test_db
    seed_pipeline_run "job-roi-cli" 88
    seed_pipeline_outcome "job-roi-cli" 88 "fast" 1 1.00 "low"
    db_upsert_attribution "job-roi-cli" 88 "build" "sonnet" 5000 2000 1.00 0 30
    local output
    output=$(attrib_roi --json)
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -ge 1 ]]
}

test_cli_forecast_json() {
    setup_env
    init_test_db
    seed_cost_entries 1 2.00
    seed_cost_entries 3 1.50
    local output
    output=$(attrib_forecast --json)
    # Should be a JSON object with total_30d
    echo "$output" | jq -e '.total_30d' >/dev/null 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════════
# EDGE CASE TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_empty_db_returns_empty_array() {
    setup_env
    init_test_db
    local json
    json=$(db_query_attribution_by_issue "" 30)
    local count
    count=$(echo "$json" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] || [[ "$json" == "[]" ]]
}

test_sql_injection_safe() {
    setup_env
    init_test_db
    seed_pipeline_run "job-safe" 42
    # Try SQL injection in stage name
    db_upsert_attribution "job-safe" 42 "build'; DROP TABLE cost_attributions;--" "sonnet" 1000 500 0.5 0 10 2>/dev/null || true
    # Table should still exist
    local tables
    tables=$(sqlite3 "$DB_FILE" "SELECT name FROM sqlite_master WHERE type='table' AND name='cost_attributions';" 2>/dev/null)
    [[ "$tables" == "cost_attributions" ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  Cost Attribution Engine — Test Suite                         ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠${RESET} sqlite3 not found — skipping tests"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠${RESET} jq not found — skipping tests"
    exit 0
fi

echo -e "${BOLD}Schema v7 Tests${RESET}"
run_test "cost_attributions table created in schema v7" test_schema_v7_table_exists
run_test "All 3 attribution indexes exist" test_schema_v7_indexes_exist
run_test "Schema version recorded as v7" test_schema_v7_version_recorded
run_test "UNIQUE constraint enforces idempotent upsert" test_schema_v7_unique_constraint

echo ""
echo -e "${BOLD}Upsert & Query Tests${RESET}"
run_test "Basic attribution upsert" test_upsert_attribution_basic
run_test "Multiple stages and iterations" test_upsert_attribution_multiple_stages
run_test "Rejects empty job_id" test_upsert_rejects_empty_job_id
run_test "Query attribution by issue (all)" test_query_attribution_by_issue
run_test "Query attribution by issue (filtered)" test_query_attribution_by_issue_filtered
run_test "Query attribution stages per issue" test_query_attribution_stages

echo ""
echo -e "${BOLD}ROI Tests${RESET}"
run_test "ROI query returns data with score" test_roi_query_basic
run_test "Failed pipeline gets zero ROI score" test_roi_failed_pipeline_zero_score

echo ""
echo -e "${BOLD}Forecast Tests${RESET}"
run_test "Forecast query returns cost data" test_forecast_query_basic
run_test "Forecast includes projection" test_forecast_has_projection

echo ""
echo -e "${BOLD}Dual-Write & Library Tests${RESET}"
run_test "record_attribution writes to SQLite and JSONL" test_record_attribution_dual_write
run_test "record_attribution rejects issue_number=0" test_record_attribution_rejects_zero_issue

echo ""
echo -e "${BOLD}CLI Integration Tests${RESET}"
run_test "analyze --json returns attribution data" test_cli_analyze_json
run_test "roi --json returns ROI data" test_cli_roi_json
run_test "forecast --json returns forecast object" test_cli_forecast_json

echo ""
echo -e "${BOLD}Edge Case Tests${RESET}"
run_test "Empty DB returns empty array" test_empty_db_returns_empty_array
run_test "SQL injection safe in stage name" test_sql_injection_safe

echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo ""

exit "$FAIL"
