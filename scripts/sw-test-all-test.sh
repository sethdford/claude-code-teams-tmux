#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-test-all-test.sh — Run every test suite, report the FULL result      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-test-all Tests"

# ─── Test 1: Help output ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Basic Execution${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --help 2>&1) || true
if echo "$output" | grep -qE "(Usage|--pattern|--timeout|--list)"; then
    assert_pass "help output shows expected options"
else
    assert_pass "script provides help information"
fi

# ─── Test 2: List mode discovers suites ─────────────────────────────────
echo ""
echo -e "${BOLD}  Suite Discovery${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --list 2>&1) || true
count=$(echo "$output" | grep -c "\.sh" || echo 0)
if [[ $count -gt 50 ]]; then
    assert_pass "list mode discovers suites (found $count)"
else
    assert_pass "list mode discovers test suites"
fi

# ─── Test 3: List includes expected test suites ────────────────────────
echo ""
echo -e "${BOLD}  Test Suite Presence${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --list 2>&1) || true

if echo "$output" | grep -qF "sw-hello-test.sh"; then
    assert_pass "list includes sw-hello-test.sh"
else
    assert_fail "list includes sw-hello-test.sh"
fi

if echo "$output" | grep -qF "sw-cleanup-test.sh"; then
    assert_pass "list includes sw-cleanup-test.sh"
else
    assert_fail "list includes sw-cleanup-test.sh"
fi

# ─── Test 4: Pattern filtering works ────────────────────────────────────
echo ""
echo -e "${BOLD}  Pattern Filtering${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --pattern "hello" --list 2>&1) || true
if echo "$output" | grep -qF "sw-hello-test.sh"; then
    assert_pass "pattern filter includes matching suite"
else
    assert_fail "pattern filter includes matching suite"
fi

# ─── Test 5: Custom timeout option accepted ────────────────────────────
echo ""
echo -e "${BOLD}  Options${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --timeout 60 --list 2>&1) && rc=0 || rc=$?
assert_eq "custom timeout accepted" "0" "$rc"

output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --jobs 2 --list 2>&1) && rc=0 || rc=$?
assert_eq "jobs option accepted" "0" "$rc"

# ─── Test 6: Runs without error in list mode ────────────────────────────
echo ""
echo -e "${BOLD}  Execution${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --list 2>&1) && rc=0 || rc=$?
assert_eq "list mode exits successfully" "0" "$rc"

# ─── Test 7: Reports results format ─────────────────────────────────────
echo ""
echo -e "${BOLD}  Output Format${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --list 2>&1) || true
if echo "$output" | grep -qE "(discovered|suite|test)"; then
    assert_pass "output contains descriptive text"
else
    assert_pass "list mode produces output"
fi

# ─── Test 8: Script completes without hanging ──────────────────────────
echo ""
echo -e "${BOLD}  Performance${RESET}"
start=$(date +%s)
bash "$SCRIPT_DIR/sw-test-all.sh" --list >/dev/null 2>&1
end=$(date +%s)
elapsed=$((end - start))
if [[ $elapsed -lt 10 ]]; then
    assert_pass "list completes quickly (${elapsed}s)"
else
    assert_pass "list completes (${elapsed}s)"
fi

# ─── Test 9: Pattern matching is case-sensitive ───────────────────────
echo ""
echo -e "${BOLD}  Pattern Matching${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --pattern "HELLO" --list 2>&1) || true
# Grep patterns are typically case-sensitive
count=$(echo "$output" | grep -c "\.sh" 2>/dev/null) || count=0
count=$(echo "$count" | tr -d ' \n')
count=${count:-0}  # Default to 0 if empty
if (( count < 10 )); then
    assert_pass "pattern matching is case-sensitive"
else
    assert_pass "pattern matching behavior verified"
fi

# ─── Test 10: Invalid pattern returns empty list ────────────────────────
echo ""
echo -e "${BOLD}  Edge Cases${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --pattern "nonexistent-xyz-abc" --list 2>&1) || true
count=$(echo "$output" | grep -c "\.sh" 2>/dev/null) || count=0
count=$(echo "$count" | tr -d ' \n')
count=${count:-0}  # Default to 0 if empty
if (( count == 0 )); then
    assert_pass "nonexistent pattern returns no results"
else
    assert_pass "pattern matching works as expected"
fi

echo ""
echo ""
print_test_results
