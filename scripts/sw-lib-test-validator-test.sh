#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Test Validator Tests — Unit tests for test command validation            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: test-validator Tests"

setup_test_env "sw-lib-test-validator-test"
trap cleanup_test_env EXIT

mock_git

# Create package.json for Node.js detection
cat > "$TEST_TEMP_DIR/package.json" << 'EOF'
{
  "name": "test-project",
  "version": "1.0.0",
  "scripts": {
    "test": "vitest"
  }
}
EOF

# Source validator (clear guard to re-source)
_SW_TEST_VALIDATOR_LOADED=""
export SW_PREFLIGHT_ENABLED="true"
export VALIDATOR_CACHE_DIR="$TEST_TEMP_DIR/.claude/pipeline-artifacts"
mkdir -p "$VALIDATOR_CACHE_DIR"
export EVENTS_FILE="$TEST_TEMP_DIR/.shipwright/events.jsonl"
mkdir -p "$(dirname "$EVENTS_FILE")"

# Mock emit_event if not available
if ! type emit_event >/dev/null 2>&1; then
    emit_event() {
        local event_type="$1"; shift
        mkdir -p "$(dirname "$EVENTS_FILE")"
        echo "{\"type\":\"$event_type\"}" >> "$EVENTS_FILE"
    }
    export -f emit_event
fi

# Mock error function if not available
if ! type error >/dev/null 2>&1; then
    error() { echo "ERROR: $*" >&2; }
    export -f error
fi

cd "$TEST_TEMP_DIR"
source "$SCRIPT_DIR/lib/test-validator.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: _probe_test_cmd with valid command
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Probe test command"

# Create a mock test command that responds to --help
cat > "$TEST_TEMP_DIR/bin/mock-test" << 'EOF'
#!/bin/bash
if [[ "$1" == "--help" ]]; then
    echo "Usage: mock-test [options]"
    exit 0
fi
exit 1
EOF
chmod +x "$TEST_TEMP_DIR/bin/mock-test"

output=$(_probe_test_cmd "$TEST_TEMP_DIR/bin/mock-test" "help")
assert_contains "probe returns output for valid command" "$output" "Usage"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: _probe_test_cmd with missing command
# ═══════════════════════════════════════════════════════════════════════════════

output=$(_probe_test_cmd "/nonexistent/command" "help")
assert_contains "probe detects missing command" "$output" "No such file or directory"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: classify_test_cmd_failure
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Classify failure types"

failure=$(classify_test_cmd_failure "command not found: npm")
assert_eq "classifies 'command not found'" "command_not_found" "$failure"

failure=$(classify_test_cmd_failure "Cannot find module 'jest'")
assert_eq "classifies 'missing dependencies'" "missing_dependencies" "$failure"

failure=$(classify_test_cmd_failure "Permission denied")
assert_eq "classifies 'permission error'" "permission_error" "$failure"

failure=$(classify_test_cmd_failure "SyntaxError: Unexpected token")
assert_eq "classifies 'syntax error'" "syntax_error" "$failure"

failure=$(classify_test_cmd_failure "Some other runtime error")
assert_eq "classifies 'runtime error'" "runtime_error" "$failure"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: _detect_project_info
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Detect project type"

info=$(_detect_project_info)
assert_contains "detects Node.js project" "$info" "node"
assert_contains "detects npm package manager" "$info" "npm"

# Create a Python project
rm "$TEST_TEMP_DIR/package.json"
cat > "$TEST_TEMP_DIR/requirements.txt" << 'EOF'
pytest==7.0.0
EOF

info=$(_detect_project_info)
assert_contains "detects Python project" "$info" "python"
assert_contains "detects pip package manager" "$info" "pip"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: write_validation_report
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Write validation report"

rm -f "$VALIDATOR_CACHE_DIR/test-validation.json"

write_validation_report "PASS" "npm test"
assert_file_exists "report file created" "$VALIDATOR_CACHE_DIR/test-validation.json"

report=$(cat "$VALIDATOR_CACHE_DIR/test-validation.json")
assert_contains "report contains status" "$report" "PASS"
assert_contains "report contains command" "$report" "npm test"

# Validate JSON structure
if echo "$report" | jq empty 2>/dev/null; then
    assert_pass "report is valid JSON"
else
    assert_fail "report is valid JSON" "report: $report"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: preflight_validate_test_cmd with valid command
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Preflight validation"

# Create package.json again for Node.js validation
cat > "$TEST_TEMP_DIR/package.json" << 'EOF'
{
  "name": "test-project",
  "version": "1.0.0",
  "scripts": {
    "test": "echo 'tests pass'"
  }
}
EOF

# Create a simple test command that works
cat > "$TEST_TEMP_DIR/bin/passing-test" << 'EOF'
#!/bin/bash
if [[ "$1" == "--help" ]]; then
    echo "Help output"
    exit 0
fi
echo "Test results"
exit 0
EOF
chmod +x "$TEST_TEMP_DIR/bin/passing-test"

rm -f "$VALIDATOR_CACHE_DIR/test-validation.json"
if preflight_validate_test_cmd "$TEST_TEMP_DIR/bin/passing-test"; then
    assert_pass "validation succeeds for working command"
else
    assert_fail "validation succeeds for working command" "exit code: $?"
fi

# Check report was written
assert_file_exists "validation report exists" "$VALIDATOR_CACHE_DIR/test-validation.json"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: preflight_validate_test_cmd with invalid command
# ═══════════════════════════════════════════════════════════════════════════════

rm -f "$VALIDATOR_CACHE_DIR/test-validation.json"
exit_code=0
preflight_validate_test_cmd "/nonexistent/test/command" 2>&1 >/dev/null || exit_code=$?
if [[ $exit_code -eq 2 ]]; then
    assert_pass "validation fails with exit code 2"
else
    assert_fail "validation fails with exit code 2" "got exit code $exit_code"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: disable preflight via env var
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Disable preflight"

SW_PREFLIGHT_ENABLED="false"
export SW_PREFLIGHT_ENABLED

if preflight_validate_test_cmd "/nonexistent/command"; then
    assert_pass "preflight disabled via env var returns success"
else
    assert_fail "preflight disabled via env var returns success" "exit code: $?"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results "Lib: test-validator"
