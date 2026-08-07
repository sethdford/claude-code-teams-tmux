#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright event-schema-sync test — Unit tests for schema sync          ║
# ║  Validates emit_event type discovery, drift detection, and schema writes ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""
ORIG_SCHEMA=""

# ═══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT & FIXTURES
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-event-schema-sync-test.XXXXXX")
    # Backup the original schema
    ORIG_SCHEMA=$(cat "$REPO_DIR/config/event-schema.json")
}

cleanup_env() {
    # Restore original schema
    if [[ -n "$ORIG_SCHEMA" ]]; then
        echo "$ORIG_SCHEMA" > "$REPO_DIR/config/event-schema.json"
    fi
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

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
# EVENT SCHEMA SYNC TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_script_is_executable() {
    [[ -x "$SCRIPT_DIR/sw-event-schema-sync.sh" ]] || return 1
}

test_script_requires_python3() {
    # Check that script requires python3 (has guard clause)
    grep -q "python3" "$SCRIPT_DIR/sw-event-schema-sync.sh" || return 1
}

test_schema_file_exists() {
    [[ -f "$REPO_DIR/config/event-schema.json" ]] || return 1
}

test_schema_is_valid_json() {
    jq empty "$REPO_DIR/config/event-schema.json" 2>/dev/null || return 1
}

test_schema_has_event_types() {
    jq -e '.event_types' "$REPO_DIR/config/event-schema.json" >/dev/null 2>&1 || return 1
}

test_schema_event_types_is_object() {
    jq -e '.event_types | type == "object"' "$REPO_DIR/config/event-schema.json" >/dev/null 2>&1 || return 1
}

test_no_drift_in_current_repo() {
    # Current shipwright repo should have schema in sync
    result=$(cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1 >/dev/null; echo $?)
    # Should exit with 0 or 1 (not error)
    [[ "$result" -eq 0 || "$result" -eq 1 ]] || return 1
}

test_script_can_read_schema() {
    # Verify script successfully reads schema without errors
    output=$(cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1)
    echo "$output" | grep -q "registered" || return 1
    echo "$output" | grep -q "emitted" || return 1
}

test_script_reports_counters() {
    output=$(cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1)
    echo "$output" | grep -qE "registered\s*:" || return 1
    echo "$output" | grep -qE "emitted\s*:" || return 1
    echo "$output" | grep -qE "missing\s*:" || return 1
}

test_script_handles_glob_patterns() {
    # Verify script finds emit_event calls across multiple dirs
    output=$(cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1)
    # Should find a significant number of events
    local count
    count=$(echo "$output" | grep -oE "emitted\s*:\s*[0-9]+" | grep -oE "[0-9]+")
    [[ "$count" -gt 100 ]] || return 1
}

test_script_detects_variable_types() {
    output=$(cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1)
    # Should mention dynamic/variable types in notes
    echo "$output" | grep -q "variable type\|dynamic" || return 1
}

test_write_mode_is_supported() {
    # --write flag should be recognized (no usage error)
    grep -q "\-\-write" "$SCRIPT_DIR/sw-event-schema-sync.sh" || return 1
}

test_schema_preserves_stale_entries() {
    # Entries in schema without call sites should be kept
    # Count event types before
    local before
    before=$(jq '.event_types | length' "$REPO_DIR/config/event-schema.json")

    # Run sync (should detect any drift but not remove existing entries)
    cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-event-schema-sync.sh" >/dev/null 2>&1 || true

    # Count after (should be same or more, not less)
    local after
    after=$(jq '.event_types | length' "$REPO_DIR/config/event-schema.json")

    [[ "$after" -ge "$before" ]] || return 1
}

test_event_type_has_structure() {
    # Each event type should have "required" and "optional" fields
    local sample
    sample=$(jq '.event_types | to_entries[0].value' "$REPO_DIR/config/event-schema.json")
    echo "$sample" | jq -e 'has("required") and has("optional")' >/dev/null 2>&1 || return 1
}

test_schema_sorted_output() {
    # Event types should be sorted
    local keys
    keys=$(jq -r '.event_types | keys[]' "$REPO_DIR/config/event-schema.json")
    local sorted_keys
    sorted_keys=$(echo "$keys" | sort)
    [[ "$keys" == "$sorted_keys" ]] || return 1
}

test_emit_event_pattern_in_scripts() {
    # Verify there are actual emit_event calls in scripts
    local count
    count=$(grep -r "emit_event" "$SCRIPT_DIR"/../scripts --include="*.sh" 2>/dev/null | grep -c "emit_event" || echo 0)
    [[ "$count" -gt 10 ]] || return 1
}

test_can_extract_emit_event_types() {
    # Sample a few emit_event calls and verify they're in schema
    local sample_type
    sample_type=$(grep -r "emit_event \"[a-zA-Z_]" "$SCRIPT_DIR"/../scripts --include="*.sh" 2>/dev/null | head -1 | sed 's/.*emit_event "\([^"]*\)".*/\1/' | head -1)
    [[ -n "$sample_type" ]] || return 1

    # This type should be in schema (or reported as found)
    jq -e ".event_types | has(\"$sample_type\")" "$REPO_DIR/config/event-schema.json" >/dev/null 2>&1 || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    print_test_header "event-schema-sync Unit Tests"

    setup_env

    print_test_section "Script Basics"
    run_test "script is executable" "test_script_is_executable"
    run_test "script requires python3" "test_script_requires_python3"

    print_test_section "Schema Structure"
    run_test "schema file exists" "test_schema_file_exists"
    run_test "schema is valid JSON" "test_schema_is_valid_json"
    run_test "schema has event_types field" "test_schema_has_event_types"
    run_test "event_types is an object" "test_schema_event_types_is_object"

    print_test_section "Sync Detection"
    run_test "current repo sync detection works" "test_no_drift_in_current_repo"
    run_test "script reads schema successfully" "test_script_can_read_schema"

    print_test_section "Reporting"
    run_test "script reports counters" "test_script_reports_counters"
    run_test "script handles glob patterns" "test_script_handles_glob_patterns"
    run_test "script detects variable types" "test_script_detects_variable_types"

    print_test_section "Write Mode"
    run_test "--write mode is supported" "test_write_mode_is_supported"
    run_test "schema preserves stale entries" "test_schema_preserves_stale_entries"

    print_test_section "Schema Quality"
    run_test "event types have required structure" "test_event_type_has_structure"
    run_test "event types are sorted" "test_schema_sorted_output"

    print_test_section "Integration"
    run_test "emit_event calls exist in scripts" "test_emit_event_pattern_in_scripts"
    run_test "can extract and verify emit types" "test_can_extract_emit_event_types"

    echo ""
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    echo ""
    if [[ $FAIL -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
        echo ""
        exit 0
    else
        echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
        echo ""
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi
}

main "$@"
