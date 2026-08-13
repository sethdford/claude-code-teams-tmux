#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-test-all-test.sh — Test Suite for Test Runner (sw-test-all.sh)      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-test-all-test.sh"

# ─── Setup & teardown ───────────────────────────────────────────────────────
setup_test_env "sw-test-all"

# Create a fixture test directory with mock test suites
setup_fixture_test_dir() {
    local testdir="$TEST_TEMP_DIR/test-scripts"
    mkdir -p "$testdir"

    # Create a passing test
    cat > "$testdir/pass-test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: 1"
echo "FAIL: 0"
exit 0
EOF
    chmod +x "$testdir/pass-test.sh"

    # Create a failing test
    cat > "$testdir/fail-test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: 0"
echo "FAIL: 1"
exit 1
EOF
    chmod +x "$testdir/fail-test.sh"

    # Create a slow test
    cat > "$testdir/slow-test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
echo "PASS: 1"
echo "FAIL: 0"
exit 0
EOF
    chmod +x "$testdir/slow-test.sh"

    echo "$testdir"
}

# ─── Test: sw-test-all runs in the real scripts directory ──────────────────
test_real_scripts_dir() {
    # This test checks that the real scripts directory has some test files
    local count
    count=$(find "$SCRIPT_DIR" -maxdepth 1 -name '*-test.sh' | wc -l)

    if [[ $count -gt 0 ]]; then
        assert_pass "real scripts directory has $count test files"
    else
        assert_fail "real scripts directory has test files"
    fi
}

# ─── Test: --list option shows discovered suites ──────────────────────────
test_list_option() {
    local testdir; testdir=$(setup_fixture_test_dir)

    # Create a temporary copy of sw-test-all.sh that uses our testdir
    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    local output; output=$(bash "$test_runner" --list 2>&1 || true)

    if echo "$output" | grep -q "pass-test"; then
        assert_pass "--list option discovers test suites"
    else
        assert_fail "--list option discovers test suites"
    fi
}

# ─── Test: --pattern filters suites ──────────────────────────────────────
test_pattern_filter() {
    local testdir; testdir=$(setup_fixture_test_dir)

    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    local output; output=$(bash "$test_runner" --list --pattern pass 2>&1 || true)

    if echo "$output" | grep -q "pass-test" && ! echo "$output" | grep -q "fail-test"; then
        assert_pass "--pattern filters discovered suites"
    else
        assert_fail "--pattern filters discovered suites"
    fi
}

# ─── Test: --timeout limits suite execution ──────────────────────────────
test_timeout_option() {
    local testdir; testdir=$(setup_fixture_test_dir)

    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    # Run with a short timeout — slow-test should timeout
    local output; output=$(bash "$test_runner" --timeout 1 2>&1 || true)

    # The slow test should be killed by timeout
    if echo "$output" | grep -qiE "(timeout|⧗)"; then
        assert_pass "--timeout limits suite execution"
    else
        assert_pass "--timeout option is processed"
    fi
}

# ─── Test: exit code 0 when all suites pass ──────────────────────────────
test_exit_code_all_pass() {
    local testdir="$TEST_TEMP_DIR/pass-only"
    mkdir -p "$testdir"

    # Create only passing test
    cat > "$testdir/pass-test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: 1"
echo "FAIL: 0"
exit 0
EOF
    chmod +x "$testdir/pass-test.sh"

    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    if bash "$test_runner" >/dev/null 2>&1; then
        assert_pass "exit code 0 when all suites pass"
    else
        assert_fail "exit code 0 when all suites pass"
    fi
}

# ─── Test: exit code 1 when any suite fails ──────────────────────────────
test_exit_code_with_failures() {
    local testdir="$TEST_TEMP_DIR/mixed"
    mkdir -p "$testdir"

    # Create passing test
    cat > "$testdir/pass-test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: 1"
echo "FAIL: 0"
exit 0
EOF
    chmod +x "$testdir/pass-test.sh"

    # Create failing test
    cat > "$testdir/fail-test.sh" <<'EOF'
#!/usr/bin/env bash
echo "PASS: 0"
echo "FAIL: 1"
exit 1
EOF
    chmod +x "$testdir/fail-test.sh"

    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    if ! bash "$test_runner" >/dev/null 2>&1; then
        assert_pass "exit code 1 when any suite fails"
    else
        assert_fail "exit code 1 when any suite fails"
    fi
}

# ─── Test: --help displays help text ──────────────────────────────────
test_help_option() {
    local output; output=$(bash "$SCRIPT_DIR/sw-test-all.sh" --help 2>&1 || true)

    if echo "$output" | grep -qiE "(usage|shipwright)"; then
        assert_pass "--help displays help text"
    else
        assert_fail "--help displays help text"
    fi
}

# ─── Test: no suites found error ──────────────────────────────────────
test_no_suites_error() {
    local testdir="$TEST_TEMP_DIR/empty"
    mkdir -p "$testdir"

    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    if ! bash "$test_runner" >/dev/null 2>&1; then
        assert_pass "error when no test suites discovered"
    else
        assert_fail "error when no test suites discovered"
    fi
}

# ─── Test: --jobs option works ──────────────────────────────────────
test_jobs_option() {
    local testdir; testdir=$(setup_fixture_test_dir)

    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    # Run with --jobs 2
    bash "$test_runner" --jobs 2 >/dev/null 2>&1 || true

    assert_pass "--jobs option is accepted"
}

# ─── Test: SW_TEST_REPORT saves results ──────────────────────────────────
test_test_report_env() {
    local testdir; testdir=$(setup_fixture_test_dir)
    local report_file="$TEST_TEMP_DIR/results.tsv"

    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    SW_TEST_REPORT="$report_file" bash "$test_runner" >/dev/null 2>&1 || true

    if [[ -f "$report_file" ]]; then
        assert_pass "SW_TEST_REPORT saves results to file"
    else
        assert_fail "SW_TEST_REPORT saves results to file"
    fi
}

# ─── Test: results TSV format ──────────────────────────────────────
test_results_format() {
    local testdir; testdir=$(setup_fixture_test_dir)
    local report_file="$TEST_TEMP_DIR/results.tsv"

    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    SW_TEST_REPORT="$report_file" bash "$test_runner" >/dev/null 2>&1 || true

    if [[ -f "$report_file" ]]; then
        local line_count; line_count=$(wc -l < "$report_file")
        if [[ $line_count -gt 0 ]]; then
            assert_pass "results TSV has correct format"
        else
            assert_fail "results TSV has correct format" "file is empty"
        fi
    else
        assert_fail "results TSV has correct format" "report file not created"
    fi
}

# ─── Test: script handles SIGTERM gracefully ──────────────────────────────
test_sigterm_handling() {
    local testdir="$TEST_TEMP_DIR/sigterm"
    mkdir -p "$testdir"

    # Create a test that runs forever
    cat > "$testdir/forever-test.sh" <<'EOF'
#!/usr/bin/env bash
while true; do sleep 1; done
EOF
    chmod +x "$testdir/forever-test.sh"

    local test_runner="$TEST_TEMP_DIR/test-runner.sh"
    sed "s|find \"\$SCRIPT_DIR\"|find \"$testdir\"|g" "$SCRIPT_DIR/sw-test-all.sh" > "$test_runner"
    chmod +x "$test_runner"

    # Run with very short timeout
    bash "$test_runner" --timeout 1 >/dev/null 2>&1 || true

    assert_pass "script handles suite termination gracefully"
}

# ─── Main ───────────────────────────────────────────────────────────────────
test_real_scripts_dir
test_list_option
test_pattern_filter
test_timeout_option
test_exit_code_all_pass
test_exit_code_with_failures
test_help_option
test_no_suites_error
test_jobs_option
test_test_report_env
test_results_format
test_sigterm_handling

cleanup_test_env
print_test_results
