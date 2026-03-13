#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-capability-test.sh — Capability Registry Test Suite                  ║
# ║  Validates DB CRUD, pre-flight gate logic, cold-start, conservative mode ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
YELLOW='\033[38;2;250;204;21m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()

# ─── Test Runner ─────────────────────────────────────────────────────
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

# ═══════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════

TEST_TEMP_DIR=""

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-capability-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/project/.claude"

    export HOME="$TEST_TEMP_DIR/home"
    export DB_DIR="$TEST_TEMP_DIR/home/.shipwright"
    export DB_FILE="$DB_DIR/shipwright.db"

    # Initialize a minimal git repo for repo_hash
    (cd "$TEST_TEMP_DIR/project" && git init -q && git remote add origin "https://github.com/test/capability-test.git" 2>/dev/null || true)

    # Source sw-db.sh and init schema
    _SW_DB_LOADED=""
    source "$SCRIPT_DIR/sw-db.sh"
    init_schema
    _db_exec "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (${SCHEMA_VERSION}, '$(now_iso)', '$(now_iso)');"

    # Source capability registry
    _MODULE_CAPABILITY_REGISTRY_LOADED=""
    source "$SCRIPT_DIR/lib/capability-registry.sh"
}

cleanup_env() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "${TEST_TEMP_DIR:-}" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# Helper: get test repo hash
test_repo_hash() {
    echo -n "https://github.com/test/capability-test.git" | shasum -a 256 | cut -c1-12
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS: DB CRUD
# ═══════════════════════════════════════════════════════════════════════════

test_db_upsert_creates_new_entry() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    db_capability_upsert "$rh" "bug" "" 1
    local result
    result=$(db_capability_query "$rh" "bug")
    local total
    total=$(echo "$result" | jq '.[0].total_runs' 2>/dev/null)
    [[ "$total" -eq 1 ]]
}

test_db_upsert_increments_on_conflict() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    db_capability_upsert "$rh" "refactor" "" 1
    db_capability_upsert "$rh" "refactor" "" 1
    db_capability_upsert "$rh" "refactor" "" 0

    local result
    result=$(db_capability_query "$rh" "refactor")
    local total succ fail
    total=$(echo "$result" | jq '.[0].total_runs' 2>/dev/null)
    succ=$(echo "$result" | jq '.[0].success_count' 2>/dev/null)
    fail=$(echo "$result" | jq '.[0].failure_count' 2>/dev/null)

    [[ "$total" -eq 3 ]] && [[ "$succ" -eq 2 ]] && [[ "$fail" -eq 1 ]]
}

test_db_upsert_computes_success_rate() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    # 3 success, 1 failure = 75%
    db_capability_upsert "$rh" "testing" "" 1
    db_capability_upsert "$rh" "testing" "" 1
    db_capability_upsert "$rh" "testing" "" 1
    db_capability_upsert "$rh" "testing" "" 0

    local result rate
    result=$(db_capability_query "$rh" "testing")
    rate=$(echo "$result" | jq '.[0].success_rate' 2>/dev/null)

    # 0.75
    local is_correct
    is_correct=$(awk "BEGIN { print ($rate >= 0.74 && $rate <= 0.76) ? 1 : 0 }")
    [[ "$is_correct" -eq 1 ]]
}

test_db_upsert_updates_confidence_level() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    # Add 10 runs to reach 'medium'
    local i=0
    while [[ "$i" -lt 10 ]]; do
        db_capability_upsert "$rh" "docs" "" 1
        i=$((i + 1))
    done

    local result conf
    result=$(db_capability_query "$rh" "docs")
    conf=$(echo "$result" | jq -r '.[0].confidence_level' 2>/dev/null)
    [[ "$conf" == "medium" ]]
}

test_db_query_empty_returns_empty_array() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    local result
    result=$(db_capability_query "$rh" "nonexistent")
    [[ "$result" == "[]" ]]
}

test_db_query_all_categories() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    db_capability_upsert "$rh" "bug" "" 1
    db_capability_upsert "$rh" "feature" "" 0

    local result count
    result=$(db_capability_query "$rh")
    count=$(echo "$result" | jq 'length' 2>/dev/null)
    [[ "$count" -eq 2 ]]
}

test_db_overall_rate() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    # 2 success + 1 failure across categories = 66.7%
    db_capability_upsert "$rh" "bug" "" 1
    db_capability_upsert "$rh" "feature" "" 1
    db_capability_upsert "$rh" "refactor" "" 0

    local rate
    rate=$(db_capability_overall_rate "$rh")
    local is_correct
    is_correct=$(awk "BEGIN { print ($rate >= 0.66 && $rate <= 0.68) ? 1 : 0 }")
    [[ "$is_correct" -eq 1 ]]
}

test_db_reset_category() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    db_capability_upsert "$rh" "bug" "" 1
    db_capability_upsert "$rh" "feature" "" 1
    db_capability_reset "$rh" "bug"

    local result count
    result=$(db_capability_query "$rh")
    count=$(echo "$result" | jq 'length' 2>/dev/null)
    [[ "$count" -eq 1 ]]
}

test_db_reset_all() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    db_capability_upsert "$rh" "bug" "" 1
    db_capability_upsert "$rh" "feature" "" 1
    db_capability_reset "$rh"

    local result count
    result=$(db_capability_query "$rh")
    count=$(echo "$result" | jq 'length' 2>/dev/null)
    [[ "$count" -eq 0 ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS: Pre-flight Gate Logic
# ═══════════════════════════════════════════════════════════════════════════

test_gate_passes_on_cold_start() {
    setup_env
    # No data in registry — should pass
    capability_check_task "bug"
}

test_gate_passes_with_insufficient_samples() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    # Add 3 failures (below min_samples=5)
    db_capability_upsert "$rh" "security" "" 0
    db_capability_upsert "$rh" "security" "" 0
    db_capability_upsert "$rh" "security" "" 0

    # Override _capability_repo_hash to return test hash
    _capability_repo_hash() { test_repo_hash; }

    capability_check_task "security"
}

test_gate_rejects_below_threshold() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    # 10 runs, 2 success = 20% < 50%
    local i=0
    while [[ "$i" -lt 8 ]]; do
        db_capability_upsert "$rh" "migration" "" 0
        i=$((i + 1))
    done
    db_capability_upsert "$rh" "migration" "" 1
    db_capability_upsert "$rh" "migration" "" 1

    _capability_repo_hash() { test_repo_hash; }

    local result=0
    capability_check_task "migration" 2>/dev/null || result=$?
    [[ "$result" -eq 1 ]]
}

test_gate_passes_above_threshold() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    # 10 runs, 8 success = 80% > 50%
    local i=0
    while [[ "$i" -lt 8 ]]; do
        db_capability_upsert "$rh" "architecture" "" 1
        i=$((i + 1))
    done
    db_capability_upsert "$rh" "architecture" "" 0
    db_capability_upsert "$rh" "architecture" "" 0

    _capability_repo_hash() { test_repo_hash; }

    capability_check_task "architecture"
}

test_gate_override_bypasses_check() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    # Create failing category
    local i=0
    while [[ "$i" -lt 10 ]]; do
        db_capability_upsert "$rh" "devops" "" 0
        i=$((i + 1))
    done

    _capability_repo_hash() { test_repo_hash; }
    OVERRIDE_CAPABILITY_CHECK=true

    capability_check_task "devops" 2>/dev/null
    local result=$?

    unset OVERRIDE_CAPABILITY_CHECK
    [[ "$result" -eq 0 ]]
}

test_gate_passes_empty_category() {
    setup_env
    # Empty category should always pass
    capability_check_task ""
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS: Conservative Mode
# ═══════════════════════════════════════════════════════════════════════════

test_conservative_mode_inactive_on_empty() {
    setup_env
    _capability_repo_hash() { test_repo_hash; }

    local result=0
    capability_is_conservative_mode || result=$?
    [[ "$result" -ne 0 ]]
}

test_conservative_mode_activates_below_threshold() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    # Overall rate: 40% (below 70%)
    local i=0
    while [[ "$i" -lt 6 ]]; do
        db_capability_upsert "$rh" "feature" "" 0
        i=$((i + 1))
    done
    i=0
    while [[ "$i" -lt 4 ]]; do
        db_capability_upsert "$rh" "feature" "" 1
        i=$((i + 1))
    done

    _capability_repo_hash() { test_repo_hash; }

    capability_is_conservative_mode
}

test_conservative_mode_inactive_above_threshold() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    # Overall rate: 90% (above 70%)
    local i=0
    while [[ "$i" -lt 9 ]]; do
        db_capability_upsert "$rh" "bug" "" 1
        i=$((i + 1))
    done
    db_capability_upsert "$rh" "bug" "" 0

    _capability_repo_hash() { test_repo_hash; }

    local result=0
    capability_is_conservative_mode || result=$?
    [[ "$result" -ne 0 ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS: Record Outcome
# ═══════════════════════════════════════════════════════════════════════════

test_record_outcome_updates_registry() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    _capability_repo_hash() { test_repo_hash; }

    capability_record_outcome "testing" "" 1
    capability_record_outcome "testing" "" 0

    local result total
    result=$(db_capability_query "$rh" "testing")
    total=$(echo "$result" | jq '.[0].total_runs' 2>/dev/null)
    [[ "$total" -eq 2 ]]
}

test_record_outcome_with_subcategory() {
    setup_env
    local rh
    rh=$(test_repo_hash)

    _capability_repo_hash() { test_repo_hash; }

    capability_record_outcome "testing" "unit" 1
    capability_record_outcome "testing" "integration" 0

    local result count
    result=$(db_capability_query "$rh" "testing")
    count=$(echo "$result" | jq 'length' 2>/dev/null)
    [[ "$count" -eq 2 ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# INTEGRATION: CLI Command
# ═══════════════════════════════════════════════════════════════════════════

test_cli_show_json_empty() {
    setup_env
    local output
    output=$(cd "$TEST_TEMP_DIR/project" && "$SCRIPT_DIR/sw-capability.sh" show --json 2>/dev/null)
    local count
    count=$(echo "$output" | jq 'length' 2>/dev/null || echo "-1")
    [[ "$count" -eq 0 ]]
}

test_cli_help_displays_usage() {
    setup_env
    local output
    output=$("$SCRIPT_DIR/sw-capability.sh" help 2>/dev/null)
    [[ "$output" =~ "USAGE" ]]
}

test_cli_status_runs() {
    setup_env
    local output
    output=$(cd "$TEST_TEMP_DIR/project" && "$SCRIPT_DIR/sw-capability.sh" status 2>/dev/null)
    [[ "$output" =~ "Overall success rate" || "$output" =~ "Categories tracked" ]]
}

test_cli_configure_shows_thresholds() {
    setup_env
    local output
    output=$(cd "$TEST_TEMP_DIR/project" && "$SCRIPT_DIR/sw-capability.sh" configure 2>/dev/null)
    [[ "$output" =~ "min_success_rate" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# INTEGRATION: Schema Migration
# ═══════════════════════════════════════════════════════════════════════════

test_schema_v7_migration() {
    setup_env

    # Verify table exists
    local tables
    tables=$(sqlite3 "$DB_FILE" ".tables" 2>/dev/null)
    [[ "$tables" =~ "capability_registry" ]]
}

test_schema_version_is_7() {
    setup_env
    local sv
    sv=$(_db_query "SELECT COALESCE(MAX(version), 0) FROM _schema;")
    [[ "$sv" -eq 7 ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# EDGE CASES
# ═══════════════════════════════════════════════════════════════════════════

test_safe_category_check() {
    setup_env
    CAPABILITY_CONSERVATIVE_SAFE_CATEGORIES="docs,bug"

    _capability_is_safe_category "docs" && _capability_is_safe_category "bug"
    local result=0
    _capability_is_safe_category "migration" || result=$?
    [[ "$result" -ne 0 ]]
}

test_threshold_hysteresis_reject_then_readmit() {
    setup_env
    CAPABILITY_HYSTERESIS_MARGIN="0.02"

    # Below threshold - margin → reject
    local result
    result=$(_capability_threshold_check "0.47" "0.50" "pass")
    [[ "$result" == "reject" ]] || return 1

    # Exactly at threshold but previously rejected → still reject (needs threshold + margin)
    result=$(_capability_threshold_check "0.50" "0.50" "reject")
    [[ "$result" == "reject" ]] || return 1

    # Above threshold + margin → pass
    result=$(_capability_threshold_check "0.53" "0.50" "reject")
    [[ "$result" == "pass" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

echo "sw-capability-test.sh"
echo ""

echo -e "${BOLD}DB CRUD Tests${RESET}"
run_test "upsert creates new entry" test_db_upsert_creates_new_entry
run_test "upsert increments on conflict" test_db_upsert_increments_on_conflict
run_test "upsert computes success rate" test_db_upsert_computes_success_rate
run_test "upsert updates confidence level" test_db_upsert_updates_confidence_level
run_test "query empty returns empty array" test_db_query_empty_returns_empty_array
run_test "query all categories" test_db_query_all_categories
run_test "overall rate computation" test_db_overall_rate
run_test "reset specific category" test_db_reset_category
run_test "reset all categories" test_db_reset_all
echo ""

echo -e "${BOLD}Pre-flight Gate Tests${RESET}"
run_test "gate passes on cold start" test_gate_passes_on_cold_start
run_test "gate passes with insufficient samples" test_gate_passes_with_insufficient_samples
run_test "gate rejects below threshold" test_gate_rejects_below_threshold
run_test "gate passes above threshold" test_gate_passes_above_threshold
run_test "gate override bypasses check" test_gate_override_bypasses_check
run_test "gate passes for empty category" test_gate_passes_empty_category
echo ""

echo -e "${BOLD}Conservative Mode Tests${RESET}"
run_test "conservative mode inactive on empty registry" test_conservative_mode_inactive_on_empty
run_test "conservative mode activates below threshold" test_conservative_mode_activates_below_threshold
run_test "conservative mode inactive above threshold" test_conservative_mode_inactive_above_threshold
echo ""

echo -e "${BOLD}Record Outcome Tests${RESET}"
run_test "record outcome updates registry" test_record_outcome_updates_registry
run_test "record outcome with subcategory" test_record_outcome_with_subcategory
echo ""

echo -e "${BOLD}CLI Integration Tests${RESET}"
run_test "CLI show --json returns empty on fresh DB" test_cli_show_json_empty
run_test "CLI help displays usage" test_cli_help_displays_usage
run_test "CLI status runs successfully" test_cli_status_runs
run_test "CLI configure shows thresholds" test_cli_configure_shows_thresholds
echo ""

echo -e "${BOLD}Schema Tests${RESET}"
run_test "schema v7 migration creates table" test_schema_v7_migration
run_test "schema version is 7" test_schema_version_is_7
echo ""

echo -e "${BOLD}Edge Case Tests${RESET}"
run_test "safe category check" test_safe_category_check
run_test "threshold hysteresis: reject then readmit" test_threshold_hysteresis_reject_then_readmit
echo ""

# ─── Summary ─────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  TOTAL: ${TOTAL}  ${GREEN}PASS: ${PASS}${RESET}  ${RED}FAIL: ${FAIL}${RESET}"

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}Failed tests:${RESET}"
    for f in "${FAILURES[@]}"; do
        echo -e "    ${RED}✗${RESET} $f"
    done
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
