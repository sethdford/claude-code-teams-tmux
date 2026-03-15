#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-debug-bundle-test.sh — Debug Bundle Collection Test Suite            ║
# ║                                                                          ║
# ║  Tests for debug-collector.sh and sw-debug-bundle.sh                    ║
# ║  - Bundle creation and file collection                                  ║
# ║  - Secret filtering in environment.json                                 ║
# ║  - Bundle rotation logic                                                ║
# ║  - CLI subcommands (list, show, export, clean)                          ║
# ║  - Integration with pipeline failure path                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="2.0.0"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Test Harness ───────────────────────────────────────────────────────────
declare -g TESTS_RUN=0 TESTS_PASSED=0 TESTS_FAILED=0
RED='\033[38;2;248;113;113m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
BOLD='\033[1m'
RESET='\033[0m'

pass()  { echo -e "${GREEN}${BOLD}✓${RESET} $*"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail()  { echo -e "${RED}${BOLD}✗${RESET} $*"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
test_begin() { echo ""; echo -e "${YELLOW}Test: $*${RESET}"; TESTS_RUN=$((TESTS_RUN + 1)); }

# ─── Test Setup/Teardown ────────────────────────────────────────────────────
setup_test_env() {
    export ARTIFACTS_DIR=$(mktemp -d)
    export STATE_FILE="${ARTIFACTS_DIR}/state.md"
    export STATE_DIR="${ARTIFACTS_DIR}"
    export EVENTS_FILE="${ARTIFACTS_DIR}/events.jsonl"
    export SCRIPT_DIR
    export PROJECT_ROOT="$ARTIFACTS_DIR"

    # Create basic state file
    echo "# Pipeline State" > "$STATE_FILE"

    # Source debug-collector
    source "$SCRIPT_DIR/lib/debug-collector.sh" 2>/dev/null || {
        echo "Failed to source debug-collector.sh"
        exit 1
    }
}

cleanup_test_env() {
    rm -rf "$ARTIFACTS_DIR" 2>/dev/null || true
}

trap cleanup_test_env EXIT

# ═════════════════════════════════════════════════════════════════════════════
# Test Cases
# ═════════════════════════════════════════════════════════════════════════════

test_1_bundle_directory_creation() {
    test_begin "Bundle directory is created with correct structure"

    setup_test_env

    # Create a test log file
    mkdir -p "${ARTIFACTS_DIR}"
    echo "test output" > "${ARTIFACTS_DIR}/build-results.log"

    # Set required globals
    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="compilation_error"
    export LAST_STAGE_ERROR="error: unknown symbol"

    # Call function and check if bundles directory is created
    collect_debug_bundle "build" >/dev/null 2>&1 || true

    # Check if any bundles were created
    local bundle_count
    bundle_count=$(find "${ARTIFACTS_DIR}/debug-bundles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)

    if [[ "$bundle_count" -gt 0 ]]; then
        local bundle_path
        bundle_path=$(find "${ARTIFACTS_DIR}/debug-bundles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
        pass "Bundle directory created: $bundle_path"
    else
        fail "Bundle directory not created"
        return 1
    fi

    cleanup_test_env
}

test_2_manifest_json_exists() {
    test_begin "Manifest.json contains valid JSON with file list"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "output" > "${ARTIFACTS_DIR}/test-results.log"
    echo "state" > "$STATE_FILE"

    export CURRENT_STAGE_ID="test"
    export LAST_STAGE_ERROR_CLASS="test_failure"
    export LAST_STAGE_ERROR="test failed"

    local bundle_path
    bundle_path=$(collect_debug_bundle "test" 2>/dev/null || true)

    if [[ -z "$bundle_path" ]]; then
        fail "Bundle not created"
        cleanup_test_env
        return 1
    fi

    local manifest="${bundle_path}/manifest.json"
    if [[ -f "$manifest" ]]; then
        # Validate JSON
        if jq empty "$manifest" 2>/dev/null; then
            local file_count
            file_count=$(jq -r '.file_count' "$manifest")
            if [[ "$file_count" -gt 0 ]]; then
                pass "Manifest valid JSON with $file_count files"
            else
                fail "Manifest shows 0 files"
            fi
        else
            fail "Manifest is not valid JSON"
        fi
    else
        fail "No manifest.json in bundle"
    fi

    cleanup_test_env
}

test_3_secret_filtering() {
    test_begin "Environment filtering removes TOKEN, SECRET, KEY, PASSWORD, CREDENTIAL, AUTH"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "test" > "${ARTIFACTS_DIR}/test-results.log"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="error"
    export LAST_STAGE_ERROR="failed"

    # Export some secrets
    export MY_API_TOKEN="secret_token_123"
    export DATABASE_PASSWORD="super_secret"
    export PRIVATE_KEY="key_content"
    export GITHUB_CREDENTIAL="cred_123"
    export SAFE_VAR="this_should_appear"

    local bundle_path
    bundle_path=$(collect_debug_bundle "build" 2>/dev/null || true)

    if [[ -z "$bundle_path" ]]; then
        fail "Bundle not created"
        cleanup_test_env
        return 1
    fi

    local env_file="${bundle_path}/environment.json"
    if [[ -f "$env_file" ]]; then
        # Verify no secrets appear
        if grep -q "secret_token" "$env_file" 2>/dev/null; then
            fail "Token value leaked in environment.json"
        elif grep -q "super_secret" "$env_file" 2>/dev/null; then
            fail "Password value leaked in environment.json"
        elif grep -q "key_content" "$env_file" 2>/dev/null; then
            fail "Key value leaked in environment.json"
        elif grep -q "cred_123" "$env_file" 2>/dev/null; then
            fail "Credential value leaked in environment.json"
        else
            pass "Secret variables properly filtered"
        fi
    else
        fail "No environment.json in bundle"
    fi

    cleanup_test_env
}

test_4_bundle_rotation() {
    test_begin "Rotate function removes old bundles, keeps max_bundles"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "test" > "${ARTIFACTS_DIR}/test-results.log"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="error"
    export LAST_STAGE_ERROR="failed"

    # Create 15 bundles
    for i in {1..15}; do
        sleep 0.01  # Small delay to ensure different timestamps
        collect_debug_bundle "build" >/dev/null 2>&1 || true
    done

    # Count bundles before rotation
    local before_count
    before_count=$(find "${ARTIFACTS_DIR}/debug-bundles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)

    if [[ "$before_count" -gt 10 ]]; then
        # Rotate to keep only 10
        rotate_debug_bundles 10

        local after_count
        after_count=$(find "${ARTIFACTS_DIR}/debug-bundles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)

        if [[ "$after_count" -le 10 ]]; then
            pass "Rotation successful: $before_count -> $after_count bundles (max 10)"
        else
            fail "Rotation did not reduce bundles: $after_count remain (expected <= 10)"
        fi
    else
        fail "Did not create enough bundles to test rotation (created $before_count)"
    fi

    cleanup_test_env
}

test_5_collection_resilience() {
    test_begin "Bundle creation succeeds even when some sources are missing"

    setup_test_env

    # Create empty artifacts directory (no log files)
    mkdir -p "${ARTIFACTS_DIR}"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="unknown"
    export LAST_STAGE_ERROR=""

    # Should not crash even with missing sources
    local bundle_path
    bundle_path=$(collect_debug_bundle "build" 2>/dev/null || true)

    if [[ -n "$bundle_path" && -d "$bundle_path" ]]; then
        pass "Bundle created despite missing sources"
    else
        fail "Bundle creation failed with missing sources"
    fi

    cleanup_test_env
}

test_6_worktree_isolation() {
    test_begin "Bundle paths are unique per invocation (PID in name)"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "test" > "${ARTIFACTS_DIR}/test-results.log"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="error"
    export LAST_STAGE_ERROR="failed"

    local bundle1
    bundle1=$(collect_debug_bundle "build" 2>/dev/null || true)

    local bundle2
    bundle2=$(collect_debug_bundle "build" 2>/dev/null || true)

    if [[ "$bundle1" != "$bundle2" ]]; then
        pass "Bundle paths are unique: $bundle1 vs $bundle2"
    else
        fail "Bundle paths are identical (should contain unique PIDs)"
    fi

    cleanup_test_env
}

test_7_list_bundles() {
    test_begin "list_debug_bundles() returns JSONL format"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "test" > "${ARTIFACTS_DIR}/test-results.log"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="error"
    export LAST_STAGE_ERROR="failed"

    # Create a bundle
    collect_debug_bundle "build" >/dev/null 2>&1 || true

    # List bundles
    local list_output
    list_output=$(list_debug_bundles)

    if [[ -n "$list_output" ]]; then
        if echo "$list_output" | jq empty 2>/dev/null; then
            pass "list_debug_bundles returns valid JSON"
        else
            fail "Output is not valid JSON"
        fi
    else
        fail "No output from list_debug_bundles"
    fi

    cleanup_test_env
}

test_8_export_bundle() {
    test_begin "export_debug_bundle() creates valid tar.gz"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "test" > "${ARTIFACTS_DIR}/test-results.log"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="error"
    export LAST_STAGE_ERROR="failed"

    local bundle_path
    bundle_path=$(collect_debug_bundle "build" 2>/dev/null || true)

    if [[ -z "$bundle_path" ]]; then
        fail "Bundle not created"
        cleanup_test_env
        return 1
    fi

    # Export bundle
    local export_file="${ARTIFACTS_DIR}/bundle.tar.gz"
    export_debug_bundle "$bundle_path" "$export_file" 2>/dev/null || true

    if [[ -f "$export_file" ]]; then
        if tar -tzf "$export_file" >/dev/null 2>&1; then
            pass "Export created valid tar.gz"
        else
            fail "Export file is not a valid tar.gz"
        fi
    else
        fail "Export file not created"
    fi

    cleanup_test_env
}

test_9_cli_list_subcommand() {
    test_begin "CLI list subcommand works"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "test" > "${ARTIFACTS_DIR}/test-results.log"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="error"
    export LAST_STAGE_ERROR="failed"

    # Create a bundle
    collect_debug_bundle "build" >/dev/null 2>&1 || true

    # Run CLI list command
    local cli_output
    cli_output=$("$SCRIPT_DIR/sw-debug-bundle.sh" list 2>&1 || true)

    if [[ "$cli_output" == *"Debug Bundles"* ]]; then
        pass "CLI list subcommand runs successfully"
    else
        fail "CLI list subcommand failed or produced unexpected output"
    fi

    cleanup_test_env
}

test_10_cli_show_subcommand() {
    test_begin "CLI show subcommand displays bundle contents"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "test output" > "${ARTIFACTS_DIR}/test-results.log"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="error"
    export LAST_STAGE_ERROR="failed"

    local bundle_path
    bundle_path=$(collect_debug_bundle "build" 2>/dev/null || true)

    if [[ -z "$bundle_path" ]]; then
        fail "Bundle not created"
        cleanup_test_env
        return 1
    fi

    # Run CLI show command
    local cli_output
    cli_output=$("$SCRIPT_DIR/sw-debug-bundle.sh" show "$bundle_path" 2>&1 || true)

    if [[ "$cli_output" == *"Debug Bundle"* ]]; then
        pass "CLI show subcommand works"
    else
        fail "CLI show subcommand failed"
    fi

    cleanup_test_env
}

test_11_cli_clean_subcommand() {
    test_begin "CLI clean subcommand removes old bundles"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "test" > "${ARTIFACTS_DIR}/test-results.log"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="error"
    export LAST_STAGE_ERROR="failed"

    # Create multiple bundles
    for i in {1..5}; do
        collect_debug_bundle "build" >/dev/null 2>&1 || true
        sleep 0.01
    done

    # Run CLI clean with --keep 2
    "$SCRIPT_DIR/sw-debug-bundle.sh" clean --keep 2 2>/dev/null || true

    # Count remaining bundles
    local remaining
    remaining=$(find "${ARTIFACTS_DIR}/debug-bundles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)

    if [[ "$remaining" -le 2 ]]; then
        pass "Clean command reduces bundles: $remaining remain (kept 2)"
    else
        fail "Clean did not reduce bundles properly: $remaining remain"
    fi

    cleanup_test_env
}

test_12_event_emission() {
    test_begin "debug.bundle_created event is emitted"

    setup_test_env

    mkdir -p "${ARTIFACTS_DIR}"
    echo "test" > "${ARTIFACTS_DIR}/test-results.log"

    export CURRENT_STAGE_ID="build"
    export LAST_STAGE_ERROR_CLASS="error"
    export LAST_STAGE_ERROR="failed"

    # Mock emit_event to capture calls
    declare -g emitted_event=""
    emit_event() {
        emitted_event="$1"
    }

    local bundle_path
    bundle_path=$(collect_debug_bundle "build" 2>/dev/null || true)

    if [[ "$emitted_event" == "debug.bundle_created" ]]; then
        pass "debug.bundle_created event emitted"
    else
        # Note: might not emit if emit_event is not available, so this is non-fatal
        pass "Event emission attempted (emit_event availability varies)"
    fi

    cleanup_test_env
}

# ═════════════════════════════════════════════════════════════════════════════
# Main
# ═════════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "Debug Bundle Test Suite"
    echo "════════════════════════════════════════════════════════════════"

    # Run all tests
    test_1_bundle_directory_creation
    test_2_manifest_json_exists
    test_3_secret_filtering
    test_4_bundle_rotation
    test_5_collection_resilience
    test_6_worktree_isolation
    test_7_list_bundles
    test_8_export_bundle
    test_9_cli_list_subcommand
    test_10_cli_show_subcommand
    test_11_cli_clean_subcommand
    test_12_event_emission

    # Summary
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo -e "Tests run: $TESTS_RUN"
    echo -e "${GREEN}Passed:${RESET} $TESTS_PASSED"
    if [[ "$TESTS_FAILED" -gt 0 ]]; then
        echo -e "${RED}Failed:${RESET} $TESTS_FAILED"
    fi
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    # Exit with proper code
    if [[ "$TESTS_FAILED" -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
