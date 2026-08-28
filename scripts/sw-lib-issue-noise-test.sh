#!/usr/bin/env bash
# sw-lib-issue-noise-test.sh — Unit tests for issue-noise.sh library
set -u

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test runner setup
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# Source the library under test
source "$SCRIPT_DIR/lib/issue-noise.sh"

# Mock emit_event for tests (not writing to events)
emit_event() {
    :
}

# Mock daemon_log
daemon_log() {
    :
}

# Helper: assert_equals
assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        ((TESTS_PASSED++))
    else
        echo "❌ FAILED: $CURRENT_TEST"
        echo "   Expected: $expected"
        echo "   Actual:   $actual"
        [[ -n "$msg" ]] && echo "   Info: $msg"
        ((TESTS_FAILED++))
    fi
}

# Helper: assert_true (exit code 0)
assert_true() {
    if "$@" >/dev/null 2>&1; then
        ((TESTS_PASSED++))
    else
        echo "❌ FAILED: $CURRENT_TEST (expected exit 0)"
        ((TESTS_FAILED++))
    fi
}

# Helper: assert_false (exit code 1)
assert_false() {
    if ! "$@" >/dev/null 2>&1; then
        ((TESTS_PASSED++))
    else
        echo "❌ FAILED: $CURRENT_TEST (expected exit 1)"
        ((TESTS_FAILED++))
    fi
}

# ── Tests ──

# Test 1: E2E test issue with label is high confidence
CURRENT_TEST="E2E test issue with label is high confidence"
issue_json='{"number":100,"title":"E2E test: foo","labels":[{"name":"e2e-test"}],"body":""}'
confidence=$(noise_issue_confidence "$issue_json")
assert_equals "high" "$confidence"

# Test 2: Automated issue with label is high confidence
CURRENT_TEST="Automated issue with label is high confidence"
issue_json='{"number":101,"title":"Automated fix","labels":[{"name":"automated"}],"body":""}'
confidence=$(noise_issue_confidence "$issue_json")
assert_equals "high" "$confidence"

# Test 3: E2E test issue with title pattern only is title confidence
CURRENT_TEST="E2E test issue with title pattern only is title confidence"
issue_json='{"number":102,"title":"Fix foo [automated]","labels":[],"body":""}'
confidence=$(noise_issue_confidence "$issue_json")
assert_equals "title" "$confidence"

# Test 4: Normal issue is not noise
CURRENT_TEST="Normal issue is not noise"
issue_json='{"number":104,"title":"Add login feature","labels":[{"name":"feature"}],"body":"User wants to login"}'
confidence=$(noise_issue_confidence "$issue_json")
assert_equals "none" "$confidence"

# Test 5: Override label disables noise detection for E2E issues
CURRENT_TEST="Override label (p0) disables noise detection"
issue_json='{"number":105,"title":"E2E test","labels":[{"name":"e2e-test"},{"name":"p0"}],"body":""}'
confidence=$(noise_issue_confidence "$issue_json")
assert_equals "none" "$confidence"

# Test 6: is_noise_issue returns 0 (true) for high confidence
CURRENT_TEST="is_noise_issue returns 0 (true) for high confidence"
issue_json='{"number":108,"title":"E2E test","labels":[{"name":"e2e-test"}],"body":""}'
assert_true is_noise_issue "$issue_json"

# Test 7: is_noise_issue returns 1 (false) for normal issues
CURRENT_TEST="is_noise_issue returns 1 (false) for normal issues"
issue_json='{"number":110,"title":"Add feature","labels":[{"name":"feature"}],"body":""}'
assert_false is_noise_issue "$issue_json"

# Test 8: noise_filter_issues removes high confidence noise
CURRENT_TEST="noise_filter_issues removes high confidence noise"
issues_json='[
  {"number":113,"title":"E2E test","labels":[{"name":"e2e-test"}],"body":""},
  {"number":114,"title":"Add feature","labels":[{"name":"feature"}],"body":""}
]'
filtered=$(echo "$issues_json" | noise_filter_issues '.' 2>/dev/null || echo "[]")
count=$(echo "$filtered" | jq 'length')
assert_equals "1" "$count"

# Test 9: noise_filter_issues preserves normal issues
CURRENT_TEST="noise_filter_issues preserves normal issues"
issues_json='[
  {"number":115,"title":"Add feature","labels":[{"name":"feature"}],"body":""},
  {"number":116,"title":"Fix bug","labels":[{"name":"bug"}],"body":""}
]'
filtered=$(echo "$issues_json" | noise_filter_issues '.' 2>/dev/null || echo "[]")
count=$(echo "$filtered" | jq 'length')
assert_equals "2" "$count"

# Test 10: noise_check_flood returns 0 (flood) when count at threshold
CURRENT_TEST="noise_check_flood returns 0 for flood condition"
assert_true noise_check_flood 5 60  # 5 >= threshold of 5

# Summary
echo ""
echo "════════════════════════════════════════════════════════"
echo "Test Summary: issue-noise.sh"
echo "════════════════════════════════════════════════════════"
echo "✓ Passed: $TESTS_PASSED"
echo "✗ Failed: $TESTS_FAILED"
echo "════════════════════════════════════════════════════════"

exit $TESTS_FAILED
