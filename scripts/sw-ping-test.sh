#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-ping-test.sh — Ping Command Test Suite                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_exit_code() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected exit code: $expected"
        echo "    Actual exit code:   $actual"
    fi
}

# ─── Test: ping command outputs "pong" ──────────────────────────────────────
test_ping_output() {
    local output
    output=$("$SCRIPT_DIR/sw-ping.sh")
    assert_equals "pong" "$output" "ping command outputs 'pong'"
}

# ─── Test: ping command exits with 0 ────────────────────────────────────────
test_ping_exit_code() {
    "$SCRIPT_DIR/sw-ping.sh" > /dev/null 2>&1
    assert_exit_code 0 $? "ping command exits with code 0"
}

# ─── Test: ping --help shows help text ──────────────────────────────────────
test_ping_help() {
    local output
    output=$("$SCRIPT_DIR/sw-ping.sh" --help)
    if [[ "$output" =~ "USAGE" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m ping --help displays help text"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m ping --help displays help text"
    fi
}

# ─── Test: ping -h shows help text ──────────────────────────────────────────
test_ping_short_help() {
    local output
    output=$("$SCRIPT_DIR/sw-ping.sh" -h)
    if [[ "$output" =~ "USAGE" ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m ping -h displays help text"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m ping -h displays help text"
    fi
}

# ─── Test: ping --version shows version ─────────────────────────────────────
test_ping_version() {
    local output
    output=$("$SCRIPT_DIR/sw-ping.sh" --version)
    if [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        ((PASS++))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m ping --version displays version"
    else
        ((FAIL++))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m ping --version displays version"
    fi
}

# ─── Test: ping with invalid option exits non-zero ──────────────────────────
test_ping_invalid_option() {
    "$SCRIPT_DIR/sw-ping.sh" --invalid > /dev/null 2>&1 || local exit_code=$?
    assert_exit_code 1 "${exit_code:-1}" "ping with invalid option exits with code 1"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-ping-test.sh"
test_ping_output
test_ping_exit_code
test_ping_help
test_ping_short_help
test_ping_version
test_ping_invalid_option

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
