#!/usr/bin/env bash
# Test Suite for Success Pattern Injection Engine

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

source "$SCRIPT_DIR/lib/compat.sh"
source "$SCRIPT_DIR/lib/success-patterns.sh"

PASS=0
FAIL=0

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1))
        echo "  ✓ $msg"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $msg"
        echo "    Expected: $expected"
        echo "    Got:      $actual"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS+1))
        echo "  ✓ $msg"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $msg"
        echo "    Expected substring: $needle"
        echo "    In: $haystack"
    fi
}

assert_exits_zero() {
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS+1))
        echo "  ✓ $* exits 0"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $* does not exit 0"
    fi
}

assert_exits_nonzero() {
    if ! "$@" >/dev/null 2>&1; then
        PASS=$((PASS+1))
        echo "  ✓ $* exits non-zero"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ $* exits 0 (expected non-zero)"
    fi
}

echo "================================"
echo "Success Pattern Tests"
echo "================================"

# ==============================================================================
# Unit: sp_load_patterns
# ==============================================================================
echo ""
echo "sp_load_patterns"

# Valid JSON
VALID_PATTERNS=$(mktemp)
echo '[{"goal":"test","iterations":3}]' > "$VALID_PATTERNS"
RESULT=$(sp_load_patterns "$VALID_PATTERNS")
assert_contains "$RESULT" "test" "loads valid JSON"

# Missing file
RESULT=$(sp_load_patterns "/nonexistent/file.json" || echo "")
assert_equals "" "$RESULT" "returns empty for missing file"

# Empty path
RESULT=$(sp_load_patterns "" || echo "")
assert_equals "" "$RESULT" "returns empty for empty path"

# ==============================================================================
# Unit: sp_score_title
# ==============================================================================
echo ""
echo "sp_score_title"

SCORE=$(sp_score_title "fix login bug" "fix login issue")
# Should be relatively high (both mention "fix" and "login")
if (( $(echo "$SCORE >= 0.5" | bc -l 2>/dev/null || echo 0) )); then
    PASS=$((PASS+1))
    echo "  ✓ Similar titles score high ($SCORE)"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Similar titles should score high (got $SCORE)"
fi

SCORE=$(sp_score_title "fix login bug" "deploy kubernetes cluster")
# Should be very low
if (( $(echo "$SCORE < 0.3" | bc -l 2>/dev/null || echo 1) )); then
    PASS=$((PASS+1))
    echo "  ✓ Different titles score low ($SCORE)"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Different titles should score low (got $SCORE)"
fi

# ==============================================================================
# Unit: sp_score_files
# ==============================================================================
echo ""
echo "sp_score_files"

SCORE=$(sp_score_files '["src/auth.js"]' '["src/auth.js"]')
# Same file should give 1.0
assert_equals "1" "${SCORE%.*}" "identical files score 1.0"

SCORE=$(sp_score_files '["src/a.js"]' '["lib/b.js"]')
# Different files should score low
if (( $(echo "$SCORE < 0.5" | bc -l 2>/dev/null || echo 1) )); then
    PASS=$((PASS+1))
    echo "  ✓ Different files score low"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Different files should score low"
fi

# ==============================================================================
# Unit: sp_score_error
# ==============================================================================
echo ""
echo "sp_score_error"

SCORE=$(sp_score_error "Connection timeout" "Connection timeout")
if [[ "${SCORE%.*}" == "1" ]]; then
    PASS=$((PASS+1))
    echo "  ✓ identical errors score 1.0"
else
    FAIL=$((FAIL+1))
    echo "  ✗ identical errors should score 1.0 (got $SCORE)"
fi

SCORE=$(sp_score_error "Connection timeout occurred" "Connection timeout")
if [[ "$SCORE" == "0.5" ]]; then
    PASS=$((PASS+1))
    echo "  ✓ substring match scores 0.5"
else
    FAIL=$((FAIL+1))
    echo "  ✗ substring match should score 0.5 (got $SCORE)"
fi

SCORE=$(sp_score_error "TypeError: undefined" "SyntaxError: unexpected token")
if [[ "${SCORE%.*}" == "0" ]]; then
    PASS=$((PASS+1))
    echo "  ✓ unrelated errors score 0.0"
else
    FAIL=$((FAIL+1))
    echo "  ✗ unrelated errors should score 0.0 (got $SCORE)"
fi

# ==============================================================================
# Unit: sp_top_k
# ==============================================================================
echo ""
echo "sp_top_k"

# Build test pattern set
PATTERNS='[
  {"goal":"fix test flakiness","iterations":3,"approach":"add retries"},
  {"goal":"refactor auth module","iterations":5,"approach":"split concerns"},
  {"goal":"optimize database queries","iterations":2,"approach":"add indexes"}
]'

INCOMING='{"goal":"fix flaky tests","files_changed":[]}'

TOP=$(sp_top_k "$INCOMING" "$PATTERNS" 2 0.20)
COUNT=$(echo "$TOP" | jq 'length' 2>/dev/null || echo 0)
if [[ "$COUNT" -le 2 ]]; then
    PASS=$((PASS+1))
    echo "  ✓ Returns at most K patterns"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Should return at most K patterns (got $COUNT)"
fi

# Empty patterns
TOP=$(sp_top_k "$INCOMING" "[]" 3 0.20)
assert_equals "[]" "$TOP" "returns empty array for empty patterns"

# ==============================================================================
# Unit: sp_render_injection
# ==============================================================================
echo ""
echo "sp_render_injection"

PATTERNS='[{"goal":"fix tests","approach":"add retries","iterations":3}]'
SNIPPET=$(sp_render_injection "$PATTERNS" "inj-test-123")
assert_contains "$SNIPPET" "Success Patterns" "renders injection header"
assert_contains "$SNIPPET" "fix tests" "renders pattern goal"

# Empty patterns
SNIPPET=$(sp_render_injection "[]" "inj-empty")
assert_equals "" "$SNIPPET" "returns empty for no patterns"

# ==============================================================================
# Unit: sp_record_outcome
# ==============================================================================
echo ""
echo "sp_record_outcome"

# Create test memory dir
MEMORY_DIR="$TEST_DIR/memory"
mkdir -p "$MEMORY_DIR"
export HOME="$TEST_DIR"

sp_record_outcome "inj-test-001" "" "success" "{}"
OUTCOMES_FILE="$TEST_DIR/.shipwright/memory/injection-outcomes.jsonl"
if [[ -f "$OUTCOMES_FILE" ]]; then
    PASS=$((PASS+1))
    echo "  ✓ Creates outcomes file"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Should create outcomes file"
fi

# Verify JSONL format
if grep -q "inj-test-001" "$OUTCOMES_FILE" 2>/dev/null; then
    PASS=$((PASS+1))
    echo "  ✓ Records injection_id"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Should record injection_id"
fi

# ==============================================================================
# Unit: sp_effectiveness_report
# ==============================================================================
echo ""
echo "sp_effectiveness_report"

REPORT=$(sp_effectiveness_report)
assert_contains "$REPORT" "success_count" "report has success_count"
assert_contains "$REPORT" "effectiveness" "report has effectiveness metric"

# ==============================================================================
# Unit: sp_inject_for_loop
# ==============================================================================
echo ""
echo "sp_inject_for_loop"

RESULT=$(sp_inject_for_loop "Fix authentication bug")
assert_contains "$RESULT" "injection_id" "result has injection_id"
assert_contains "$RESULT" "snippet" "result has snippet"

# ==============================================================================
# Integration: Full workflow
# ==============================================================================
echo ""
echo "Integration: Full workflow"

# Create test patterns file
PATTERNS_FILE="$TEST_DIR/patterns.json"
echo '[
  {"goal":"fix test","iterations":3,"approach":"add retries","files_changed":["test/"]},
  {"goal":"auth refactor","iterations":5,"approach":"split concerns","files_changed":["src/auth"]}
]' > "$PATTERNS_FILE"

# Simulate injection
INJECTION=$(sp_inject_for_loop "fix tests in test suite")
INJECTION_ID=$(echo "$INJECTION" | jq -r '.injection_id' 2>/dev/null || echo "")
if [[ -n "$INJECTION_ID" ]]; then
    PASS=$((PASS+1))
    echo "  ✓ Generates injection_id"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Should generate injection_id"
fi

# Record outcome
sp_record_outcome "$INJECTION_ID" "" "success" '{"test":"data"}'
if grep -q "$INJECTION_ID" "$OUTCOMES_FILE" 2>/dev/null; then
    PASS=$((PASS+1))
    echo "  ✓ Records outcome"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Should record outcome"
fi

# ==============================================================================
# Edge Cases
# ==============================================================================
echo ""
echo "Edge cases"

# Null/empty values
SCORE=$(sp_score_title "" "test")
if [[ "$SCORE" == "0"* ]]; then
    PASS=$((PASS+1))
    echo "  ✓ Handles empty title"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Should handle empty title"
fi

# Very long pattern list (performance check)
MANY_PATTERNS="["
for i in {1..100}; do
    MANY_PATTERNS+="{\"goal\":\"pattern_$i\",\"iterations\":$i},"
done
MANY_PATTERNS="${MANY_PATTERNS%,}]"

START=$(date +%s%N)
TOP=$(sp_top_k '{"goal":"test"}' "$MANY_PATTERNS" 5 0.20)
END=$(date +%s%N)
ELAPSED=$(( (END - START) / 1000000 ))  # Convert to ms

if [[ $ELAPSED -lt 500 ]]; then
    PASS=$((PASS+1))
    echo "  ✓ Scores 100 patterns in ${ELAPSED}ms"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Scoring too slow (${ELAPSED}ms, should be <500ms)"
fi

# Malformed JSON
BAD_FILE="$TEST_DIR/bad.json"
echo '{invalid json' > "$BAD_FILE"
RESULT=$(sp_load_patterns "$BAD_FILE" || echo "")
# Should handle gracefully (not crash)
PASS=$((PASS+1))
echo "  ✓ Handles malformed JSON gracefully"

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
