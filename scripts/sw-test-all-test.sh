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
assert_contains_regex "help output documents --pattern/--timeout/--list" \
    "$output" "(--pattern|--timeout|--list)"

# ─── Test 2: List mode discovers suites ─────────────────────────────────
echo ""
echo -e "${BOLD}  Suite Discovery${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --list 2>&1) || true
count=$(echo "$output" | grep -c "\.sh" || echo 0)
assert_gt "list mode discovers >50 suites (found $count)" "$count" 50

# ─── Test 3: List includes expected test suites ────────────────────────
echo ""
echo -e "${BOLD}  Test Suite Presence${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --list 2>&1) || true

if grep -qF -e "sw-hello-test.sh" <<<"$output"; then
    assert_pass "list includes sw-hello-test.sh"
else
    assert_fail "list includes sw-hello-test.sh"
fi

if grep -qF -e "sw-cleanup-test.sh" <<<"$output"; then
    assert_pass "list includes sw-cleanup-test.sh"
else
    assert_fail "list includes sw-cleanup-test.sh"
fi

# ─── Test 4: Pattern filtering works ────────────────────────────────────
echo ""
echo -e "${BOLD}  Pattern Filtering${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --pattern "hello" --list 2>&1) || true
if grep -qF -e "sw-hello-test.sh" <<<"$output"; then
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
# --list is machine-readable: one bare suite basename per line, nothing else.
stray=$(echo "$output" | grep -vcE '^[A-Za-z0-9._-]+-test\.sh$' || true)
assert_eq "list mode emits only suite basenames" "0" "${stray:-0}"

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
    assert_fail "list completes quickly" "took ${elapsed}s, expected <10s"
fi

# ─── Test 9: Pattern matching is case-sensitive ───────────────────────
echo ""
echo -e "${BOLD}  Pattern Matching${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --pattern "HELLO" --list 2>&1) || true
# Grep patterns are typically case-sensitive
count=$(echo "$output" | grep -c "\.sh" 2>/dev/null) || count=0
count=$(echo "$count" | tr -d ' \n')
count=${count:-0}  # Default to 0 if empty
assert_eq "pattern matching is case-sensitive (HELLO matches nothing)" "0" "$count"

# ─── Test 10: Invalid pattern returns empty list ────────────────────────
echo ""
echo -e "${BOLD}  Edge Cases${RESET}"
output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --pattern "nonexistent-xyz-abc" --list 2>&1) || true
count=$(echo "$output" | grep -c "\.sh" 2>/dev/null) || count=0
count=$(echo "$count" | tr -d ' \n')
count=${count:-0}  # Default to 0 if empty
assert_eq "nonexistent pattern returns no results" "0" "$count"

# ─── Execution contract ─────────────────────────────────────────────────
# Everything above exercises --list/--help only. The runner's actual job is
# running suites and turning their exit codes into an aggregate exit code, so
# these tests build a sandbox of fake suites and run the real thing against it.
echo ""
echo -e "${BOLD}  Execution Contract${RESET}"

SANDBOX="$(mktemp -d)"
# Deliberately no EXIT trap: bash runs EXIT traps in command-substitution
# subshells too, so `output=$(bash "$RUNNER")` would delete the sandbox out
# from under the next assertion. Cleaned up explicitly at the end instead.
cp "$SCRIPT_DIR/sw-test-all.sh" "$SANDBOX/sw-test-all.sh"
RUNNER="$SANDBOX/sw-test-all.sh"

make_suite() {  # make_suite <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$SANDBOX/$1-test.sh"
    chmod +x "$SANDBOX/$1-test.sh"
}

make_suite aa-ok   'exit 0'
output=$(FAIL_LOG_LINES=0 bash "$RUNNER" 2>&1) && rc=0 || rc=$?
assert_exit_code "all-passing run exits 0" "0" "$rc"
assert_contains_regex "summary counts the passing suite" "$output" "1 passed"

make_suite bb-bad  'echo "boom detail"; exit 3'
output=$(FAIL_LOG_LINES=0 bash "$RUNNER" 2>&1) && rc=0 || rc=$?
assert_exit_code "a failing suite makes the run exit 1" "1" "$rc"
assert_contains "failing suite is named in the summary" "$output" "bb-bad-test"
assert_contains_regex "failing suite reports its exit code" "$output" "FAIL:3|exit 3"

# The per-suite logs live in a temp dir that is deleted on exit, so the tail
# echoed into the summary is the only diagnostic CI ever keeps.
output=$(FAIL_LOG_LINES=25 bash "$RUNNER" 2>&1) || true
assert_contains "failing suite's log tail is echoed" "$output" "boom detail"
output=$(FAIL_LOG_LINES=0 bash "$RUNNER" 2>&1) || true
if grep -qF -e "boom detail" <<<"$output"; then
    assert_fail "FAIL_LOG_LINES=0 suppresses the log tail"
else
    assert_pass "FAIL_LOG_LINES=0 suppresses the log tail"
fi

rm -f "$SANDBOX/bb-bad-test.sh"

# A hung suite must be killed and reported as TIMEOUT, not as a pass.
make_suite cc-hang 'sleep 30'
output=$(FAIL_LOG_LINES=0 bash "$RUNNER" --timeout 2 2>&1) && rc=0 || rc=$?
assert_exit_code "a hung suite makes the run exit 1" "1" "$rc"
assert_contains "hung suite is reported as TIMEOUT" "$output" "TIMEOUT"
rm -f "$SANDBOX/cc-hang-test.sh"

# --jobs N must not lose results: every discovered suite gets exactly one row.
for i in 1 2 3 4 5; do make_suite "j$i" 'exit 0'; done
report="$SANDBOX/report.tsv"
SW_TEST_REPORT="$report" bash "$RUNNER" --jobs 4 >/dev/null 2>&1 || true
assert_file_exists "SW_TEST_REPORT is written" "$report"
rows=$(wc -l < "$report" | tr -d ' ')
suites=$(bash "$RUNNER" --list | wc -l | tr -d ' ')
assert_eq "--jobs 4 reports one row per suite" "$suites" "$rows"
for i in 1 2 3 4 5; do rm -f "$SANDBOX/j$i-test.sh"; done

# False-green guard: a worker that dies before appending its row used to leave
# the suite silently absent from the summary while the run still exited 0.
make_suite dd-killer 'kill -KILL $PPID; sleep 5'
output=$(FAIL_LOG_LINES=0 bash "$RUNNER" --jobs 2 --timeout 3 2>&1) && rc=0 || rc=$?
assert_exit_code "a suite with no reported result fails the run" "1" "$rc"
assert_contains "missing result is named in the summary" "$output" "dd-killer-test"
assert_contains "missing result is labelled NO-RESULT" "$output" "NO-RESULT"
rm -f "$SANDBOX/dd-killer-test.sh"

# A suite that leaves a background child behind must not leak it into the run.
STRAY_TAG="sw-stray-$$"
make_suite ee-stray "bash -c 'sleep 25' $STRAY_TAG & exit 0"
bash "$RUNNER" --pattern ee-stray >/dev/null 2>&1 || true
sleep 1
if pgrep -f "$STRAY_TAG" >/dev/null 2>&1; then
    assert_fail "stragglers left by a passing suite are reaped"
    pkill -f "$STRAY_TAG" 2>/dev/null || true
else
    assert_pass "stragglers left by a passing suite are reaped"
fi
rm -f "$SANDBOX/ee-stray-test.sh"

rm -rf "$SANDBOX"

echo ""
echo ""
print_test_results
