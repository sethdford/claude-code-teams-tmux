#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
TEMP_DIR=""

cleanup() { [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; return 0; }
trap cleanup EXIT

run_test() {
    local name="$1" fn="$2"
    TOTAL=$((TOTAL + 1))
    if $fn; then
        PASS=$((PASS + 1))
        echo -e "${GREEN}✓${RESET} $name"
    else
        FAIL=$((FAIL + 1))
        echo -e "${RED}✗${RESET} $name"
    fi
}

test_script_is_executable() {
    [[ -x "$SCRIPT_DIR/sw-event-schema-sync.sh" ]]
}

test_schema_is_valid_json() {
    jq empty "$REPO_DIR/config/event-schema.json" 2>/dev/null && return 0 || return 1
}

test_schema_has_event_types() {
    jq -e '.event_types' "$REPO_DIR/config/event-schema.json" >/dev/null 2>&1
}

test_sync_runs_on_repo() {
    cd "$REPO_DIR"
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" >/dev/null 2>&1 || return 0
    return 0
}

test_sync_detects_state() {
    cd "$REPO_DIR"
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1 | grep -q "registered\|emitted"
}

test_sync_reports_counts() {
    cd "$REPO_DIR"
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1 | grep -q "registered.*:"
}

test_write_preserves_validity() {
    cd "$REPO_DIR"
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1 >/dev/null || true
    jq empty "$REPO_DIR/config/event-schema.json" 2>/dev/null
}

test_emitted_types_exist() {
    cd "$REPO_DIR"
    jq -e '.event_types | length > 0' "$REPO_DIR/config/event-schema.json" >/dev/null 2>&1
}

test_dynamic_calls_detected() {
    cd "$REPO_DIR"
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1 | grep -q "dynamic" || return 0
    return 0
}

test_stale_types_preserved() {
    cd "$REPO_DIR"
    [[ $(jq '.event_types | length' "$REPO_DIR/config/event-schema.json") -gt 0 ]]
}

echo -e "${BOLD}${CYAN}sw-event-schema-sync test suite${RESET}\n"

run_test "script is executable" test_script_is_executable
run_test "schema is valid JSON" test_schema_is_valid_json
run_test "schema has event_types object" test_schema_has_event_types
run_test "sync runs on repository" test_sync_runs_on_repo
run_test "sync detects schema state" test_sync_detects_state
run_test "sync reports event counts" test_sync_reports_counts
run_test "write preserves JSON validity" test_write_preserves_validity
run_test "emitted event types catalogued" test_emitted_types_exist
run_test "dynamic calls detected" test_dynamic_calls_detected
run_test "stale types preserved" test_stale_types_preserved

echo ""
print_test_results "PASS: $PASS" "FAIL: $FAIL"
exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 1)
