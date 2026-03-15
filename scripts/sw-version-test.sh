#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-version-test.sh — Version Flag Test Suite                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Test: sw --version outputs semver pattern ────────────────────────────
test_version_flag_semver() {
    local output
    output=$("$SCRIPT_DIR/sw" --version 2>&1)
    if echo "$output" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
        assert_pass "--version outputs semver pattern"
    else
        assert_fail "--version outputs semver pattern" "output: $output"
    fi
}

# ─── Test: sw --version exits with code 0 ─────────────────────────────────
test_version_flag_exit_code() {
    local exit_code=0
    "$SCRIPT_DIR/sw" --version > /dev/null 2>&1 || exit_code=$?
    assert_eq "--version exits with code 0" "0" "$exit_code"
}

# ─── Test: sw -v produces same output as --version ────────────────────────
test_short_version_flag() {
    local long_output short_output
    long_output=$("$SCRIPT_DIR/sw" --version 2>&1)
    short_output=$("$SCRIPT_DIR/sw" -v 2>&1)
    assert_eq "-v produces same output as --version" "$long_output" "$short_output"
}

# ─── Test: sw --version contains "shipwright" ──────────────────────────────
test_version_contains_shipwright() {
    local output
    output=$("$SCRIPT_DIR/sw" --version 2>&1)
    assert_contains "--version output contains 'shipwright'" "$output" "shipwright"
}

# ─── Test: sw version (subcommand) shows version ──────────────────────────
test_version_subcommand() {
    local output
    output=$("$SCRIPT_DIR/sw" version 2>&1)
    if echo "$output" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
        assert_pass "version subcommand shows version"
    else
        assert_fail "version subcommand shows version" "output: $output"
    fi
}

# ─── Test: sw version show displays version ────────────────────────────────
test_version_show_subcommand() {
    local output
    output=$("$SCRIPT_DIR/sw" version show 2>&1)
    if echo "$output" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
        assert_pass "version show displays version"
    else
        assert_fail "version show displays version" "output: $output"
    fi
}

# ─── Test: sw version check runs without crashing ─────────────────────────
test_version_check() {
    local exit_code=0
    "$SCRIPT_DIR/sw" version check > /dev/null 2>&1 || exit_code=$?
    # version check exits 0 (consistent) or 1 (inconsistent) — both are valid
    if [[ "$exit_code" -le 1 ]]; then
        assert_pass "version check runs without crashing (exit $exit_code)"
    else
        assert_fail "version check runs without crashing" "unexpected exit code: $exit_code"
    fi
}

# ─── Test: sw version bump with no args exits 1 ───────────────────────────
test_version_bump_no_args() {
    local exit_code=0
    "$SCRIPT_DIR/sw" version bump > /dev/null 2>&1 || exit_code=$?
    assert_eq "version bump with no args exits 1" "1" "$exit_code"
}

# ─── Main ───────────────────────────────────────────────────────────────────
print_test_header "sw-version-test.sh — Version Flag Test Suite"
test_version_flag_semver
test_version_flag_exit_code
test_short_version_flag
test_version_contains_shipwright
test_version_subcommand
test_version_show_subcommand
test_version_check
test_version_bump_no_args
print_test_results
