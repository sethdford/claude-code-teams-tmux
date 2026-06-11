#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright platform-hygiene test — Platform Hygiene Agent Unit Tests    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-platform-hygiene-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    export HOME="$TEST_TEMP_DIR/home"
}

cleanup_test_env() {
    [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

# ─── Test cases ────────────────────────────────────────────────────────

test_help_command() {
    local desc="help subcommand exits 0 and shows usage"
    if bash "$SCRIPT_DIR/sw-platform-hygiene.sh" help 2>/dev/null | grep -q "USAGE\|SUBCOMMANDS"; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
}

test_version_flag() {
    local desc="--version flag outputs version"
    local output
    output=$(bash "$SCRIPT_DIR/sw-platform-hygiene.sh" --version 2>/dev/null)
    if echo "$output" | grep -q "3.3.0"; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Got: $output"
    fi
}

test_scan_tests_executable() {
    local desc="scan-tests subcommand executes without error"
    if bash "$SCRIPT_DIR/sw-platform-hygiene.sh" scan-tests 2>/dev/null | grep -q "Total executable"; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
}

test_has_no_github_guard() {
    local desc="Script guards GitHub calls with NO_GITHUB check"
    if grep -q '\[[ ]*"$NO_GITHUB"' "$SCRIPT_DIR/sw-platform-hygiene.sh"; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
}

test_has_atomic_writes() {
    local desc="Script uses atomic writes for JSON files"
    if grep -q "mktemp.*tmp\|mv.*tmp" "$SCRIPT_DIR/sw-platform-hygiene.sh"; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
}

test_script_has_main_dispatch() {
    local desc="Script has main dispatch for subcommands"
    if grep -q "case \"\${1:-auto}\"" "$SCRIPT_DIR/sw-platform-hygiene.sh"; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
}

test_script_has_sourced_check() {
    local desc="Script has is_sourced_only classifier"
    if grep -q "is_sourced_only()" "$SCRIPT_DIR/sw-platform-hygiene.sh"; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
}

test_script_has_emit_event() {
    local desc="Script emits events for observability"
    if grep -q "emit_event" "$SCRIPT_DIR/sw-platform-hygiene.sh"; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
}

test_script_is_bash_3_2_safe() {
    local desc="Script uses bash 3.2 safe patterns (no associative arrays)"
    if grep -q "set -euo pipefail" "$SCRIPT_DIR/sw-platform-hygiene.sh" && \
       ! grep -q "declare -A\|readarray" "$SCRIPT_DIR/sw-platform-hygiene.sh"; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "sw-platform-hygiene"

setup_test_env
trap cleanup_test_env EXIT

test_help_command
test_version_flag
test_scan_tests_executable
test_has_no_github_guard
test_has_atomic_writes
test_script_has_main_dispatch
test_script_has_sourced_check
test_script_has_emit_event
test_script_is_bash_3_2_safe

print_test_results
exit "$((FAIL > 0 ? 1 : 0))"
