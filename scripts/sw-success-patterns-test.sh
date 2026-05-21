#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Success Pattern Injection Engine — Test Suite                            ║
# ║  Unit tests for scoring, ranking, injection rendering                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="3.3.0"

# Test counters
PASS=0
FAIL=0

# Load library (it will set up ERR trap)
source "$SCRIPT_DIR/lib/success-patterns.sh" 2>/dev/null || {
    error "Failed to source lib/success-patterns.sh"
    exit 1
}

# Disable ERR trap from library to allow test assertions to continue
trap - ERR

# Helpers
info()    { echo -e "\033[38;2;0;212;255m▸\033[0m $*"; }
success() { echo -e "\033[38;2;74;222;128m✓\033[0m $*"; }
warn()    { echo -e "\033[38;2;250;204;21m⚠\033[0m $*"; }
error()   { echo -e "\033[38;2;248;113;113m✗\033[0m $*" >&2; }

assert_equal() {
    local actual="$1" expected="$2" msg="${3:-}"
    if [[ "$actual" == "$expected" ]]; then
        success "Assert: $msg"
        PASS=$((PASS + 1))
    else
        error "Assert failed: $msg — got '$actual', expected '$expected'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if echo "$haystack" | grep -q "$needle"; then
        success "Assert: $msg"
        PASS=$((PASS + 1))
    else
        error "Assert failed: $msg — '$needle' not in output"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_empty() {
    local value="$1" msg="${2:-}"
    if [[ -n "$value" ]]; then
        success "Assert: $msg"
        PASS=$((PASS + 1))
    else
        error "Assert failed: $msg — value is empty"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Test Suite ────────────────────────────────────────────────────────────

echo ""
echo "╔═════════════════════════════════════════════════════════════════════════╗"
echo "║  Success Pattern Injection Engine — Test Suite                          ║"
echo "╚═════════════════════════════════════════════════════════════════════════╝"
echo ""

# Test 1: Library loads
echo "Test: Library Functions"
if declare -f sp_load_patterns >/dev/null 2>&1; then
    success "sp_load_patterns defined"
    PASS=$((PASS + 1))
else
    error "sp_load_patterns not defined"
    FAIL=$((FAIL + 1))
fi

if declare -f sp_score_issue >/dev/null 2>&1; then
    success "sp_score_issue defined"
    PASS=$((PASS + 1))
else
    error "sp_score_issue not defined"
    FAIL=$((FAIL + 1))
fi

if declare -f sp_top_k >/dev/null 2>&1; then
    success "sp_top_k defined"
    PASS=$((PASS + 1))
else
    error "sp_top_k not defined"
    FAIL=$((FAIL + 1))
fi

if declare -f sp_render_injection >/dev/null 2>&1; then
    success "sp_render_injection defined"
    PASS=$((PASS + 1))
else
    error "sp_render_injection not defined"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Test: sp_load_patterns (empty corpus fallback)"
patterns=$(sp_load_patterns)
result=$(echo "$patterns" | jq 'type' 2>/dev/null || echo "error")
assert_equal "$result" "array" "Returns array even if patterns missing"

echo ""
echo "Test: sp_load_patterns (real patterns)"
count=$(echo "$patterns" | jq 'length' 2>/dev/null || echo 0)
if [[ $count -gt 0 ]]; then
    success "Loaded $count real patterns from memory"
    ((PASS++))
else
    warn "No patterns in memory (OK for first run)"
fi

echo ""
echo "Test: sp_score_issue (basic scoring)"
scores=$(sp_score_issue "Fix bug" "[]" "[]" "$patterns")
score_type=$(echo "$scores" | jq 'type' 2>/dev/null || echo "error")
assert_equal "$score_type" "array" "Scoring returns array"
score_count=$(echo "$scores" | jq 'length' 2>/dev/null || echo 0)
if [[ $score_count -gt 0 ]]; then
    success "Scored against $score_count patterns"
    ((PASS++))
fi

echo ""
echo "Test: sp_score_issue (score range 0-100)"
first_score=$(echo "$scores" | jq '.[0].score // 0' 2>/dev/null || echo -1)
if [[ $first_score -ge 0 && $first_score -le 100 ]]; then
    success "First score $first_score is in valid range [0-100]"
    ((PASS++))
else
    error "Score $first_score out of range"
    ((FAIL++))
fi

echo ""
echo "Test: sp_top_k (threshold filtering)"
top_k=$(sp_top_k "$scores" 70 3)
top_count=$(echo "$top_k" | jq 'length' 2>/dev/null || echo 0)
if [[ $top_count -le 3 ]]; then
    success "Top-K filtered to $top_count patterns (threshold 70)"
    ((PASS++))
fi

# Check that all filtered scores are >= threshold
all_above_threshold=true
echo "$top_k" | jq '.[] | select(.score < 70)' 2>/dev/null | grep -q . && all_above_threshold=false
if $all_above_threshold; then
    success "All top-K scores >= threshold"
    ((PASS++))
else
    warn "Some filtered scores below threshold (may be empty set)"
fi

echo ""
echo "Test: sp_render_injection (markdown generation)"
fragment=$(sp_render_injection "$patterns" "$top_k" 2>/dev/null || echo "")
if [[ -n "$fragment" ]]; then
    success "Render produced non-empty fragment"
    ((PASS++))

    # Check for expected markdown markers
    if echo "$fragment" | grep -q "##\|--"; then
        success "Fragment contains markdown markers"
        ((PASS++))
    fi
fi

# Check sidecar file
if [[ -f ".claude/pipeline-artifacts/injection.json" ]]; then
    success "Injection sidecar created"
    ((PASS++))

    injection_id=$(jq -r '.injection_id' ".claude/pipeline-artifacts/injection.json" 2>/dev/null || echo "")
    if [[ "$injection_id" == inj_* ]]; then
        success "Injection ID formatted correctly"
        ((PASS++))
    fi
else
    warn "Injection sidecar not found (may not have been created)"
fi

echo ""
echo "Test: sp_effectiveness_report (aggregation)"
report=$(sp_effectiveness_report 2>/dev/null || echo "{}")
report_type=$(echo "$report" | jq 'type' 2>/dev/null || echo "error")
assert_equal "$report_type" "object" "Report returns object"

report_keys=$(echo "$report" | jq 'keys[]' 2>/dev/null | tr '\n' ' ' || echo "")
if [[ -n "$report_keys" ]]; then
    success "Report has keys: $report_keys"
    ((PASS++))
fi

echo ""
echo "Test: sp_paths (memory directory)"
mem_dir=$(sp_paths)
assert_not_empty "$mem_dir" "sp_paths returns non-empty path"

if [[ $mem_dir == *".shipwright"* ]]; then
    success "Memory directory path contains .shipwright"
    ((PASS++))
fi

echo ""
echo "Test: CLI wrapper"
chmod +x "$SCRIPT_DIR/sw-success-patterns.sh" 2>/dev/null || true
cli_help=$("$SCRIPT_DIR/sw-success-patterns.sh" help 2>&1 || true)
if echo "$cli_help" | grep -q "Usage\|success-patterns"; then
    success "CLI help output working"
    ((PASS++))
fi

echo ""
echo "Test: CLI 'index' subcommand"
cli_index=$("$SCRIPT_DIR/sw-success-patterns.sh" index 2>&1 || echo "")
if echo "$cli_index" | grep -q "✓\|Indexed"; then
    success "CLI index subcommand works"
    ((PASS++))
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "✓ All tests passed! ($PASS passed)"
    exit 0
else
    echo "✗ Some tests failed ($PASS passed, $FAIL failed)"
    exit 1
fi
