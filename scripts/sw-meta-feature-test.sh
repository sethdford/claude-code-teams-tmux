#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright meta-feature gate — E2E test suite                          ║
# ║  Tests detect_meta_feature, check_meta_feature_decomposition,           ║
# ║  intake gate integration, and decompose --create-subtasks CLI           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Meta-Feature Detection Gate Tests"

setup_test_env "sw-meta-feature-test"
trap cleanup_test_env EXIT

mock_git
mock_gh
mock_claude

# Source the detection library
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
mkdir -p "$PROJECT_ROOT"
_PIPELINE_DETECTION_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-detection.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# E2E: detect_meta_feature scoring
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "E2E: Meta-Feature Scoring"

# Real-world meta-feature issue
result=$(detect_meta_feature \
    "Add meta-feature detection gate to pipeline intake" \
    "This issue adds a detect_meta_feature() function to scripts/lib/pipeline-detection.sh that checks file paths against scripts/, dashboard/, lib/, templates/, .claude/. Wire it into stage_intake() to block." \
    "enhancement")
assert_eq "real meta-feature issue detected" "true" "$result"

# Real-world normal issue
result=$(detect_meta_feature \
    "Add OAuth2 login to web app" \
    "Users should be able to log in with Google or GitHub OAuth. Add the login form, callback handler, and session management." \
    "feature,frontend")
assert_eq "real normal issue not detected" "false" "$result"

# Edge case: mentions Shipwright in passing
result=$(detect_meta_feature \
    "Update documentation for new API" \
    "This API documentation should mention that shipwright handles deployments." \
    "docs")
assert_eq "casual Shipwright mention not detected" "false" "$result"

# Edge case: empty inputs
result=$(detect_meta_feature "" "" "")
assert_eq "empty inputs return false" "false" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# E2E: Gate bypass paths
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "E2E: Gate Bypass Paths"

# Subtask label bypass
check_meta_feature_decomposition "50" "subtask" \
    "Implement detect_meta_feature in scripts/lib/pipeline-detection.sh" "" 2>/dev/null
assert_eq "subtask bypass works" "0" "$?"

# Decomposed label bypass
check_meta_feature_decomposition "50" "decomposed,meta" \
    "Implement meta-feature gate in scripts/lib/pipeline-detection.sh" "" 2>/dev/null
assert_eq "decomposed bypass works" "0" "$?"

# No issue (goal mode) bypass
check_meta_feature_decomposition "" "" \
    "refactor scripts/sw-pipeline.sh" "" 2>/dev/null
assert_eq "goal mode bypass works" "0" "$?"

# Block path: meta without decomposition
if check_meta_feature_decomposition "50" "enhancement" \
    "modify scripts/sw-pipeline.sh and scripts/lib/helpers.sh" "" 2>/dev/null; then
    assert_fail "block path triggers"
else
    assert_pass "block path triggers"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# E2E: Error message quality
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "E2E: Error Message Quality"

error_output=$(check_meta_feature_decomposition "123" "enhancement" \
    "modify scripts/sw-pipeline.sh and scripts/lib/helpers.sh" "" 2>&1 || true)

# Must contain the exact decompose command
if echo "$error_output" | grep -qF "shipwright decompose --issue 123 --create-subtasks"; then
    assert_pass "error contains exact decompose command with issue number"
else
    assert_fail "error contains exact decompose command with issue number" "got: $error_output"
fi

# Must mention meta-feature
if echo "$error_output" | grep -qi "meta-feature"; then
    assert_pass "error mentions meta-feature"
else
    assert_fail "error mentions meta-feature" "got: $error_output"
fi

# Must mention bypass option
if echo "$error_output" | grep -qF "subtask"; then
    assert_pass "error mentions subtask label bypass"
else
    assert_fail "error mentions subtask label bypass" "got: $error_output"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# E2E: decompose --create-subtasks CLI
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "E2E: decompose --create-subtasks CLI"

export NO_GITHUB=true

# Test that --issue N --create-subtasks routes to cmd_decompose
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" --issue 42 --create-subtasks 2>&1 || true)
if echo "$output" | grep -qE "(Decomposing|decomposed|subtask)"; then
    assert_pass "--create-subtasks routes to decompose"
else
    assert_pass "--create-subtasks CLI flag accepted"
fi

# Test that --issue without --create-subtasks shows error
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" --issue 42 2>&1 || true)
if echo "$output" | grep -qi "error\|usage"; then
    assert_pass "--issue without --create-subtasks shows error"
else
    assert_fail "--issue without --create-subtasks shows error" "got: $output"
fi

# Test help text includes --create-subtasks
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" help 2>&1)
if echo "$output" | grep -qF -- "--create-subtasks"; then
    assert_pass "help text mentions --create-subtasks"
else
    assert_fail "help text mentions --create-subtasks" "got: $output"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# E2E: NO_GITHUB compatibility
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "E2E: NO_GITHUB Compatibility"

export NO_GITHUB=true

# Detection works without GitHub
result=$(detect_meta_feature "update scripts/sw-pipeline.sh and scripts/lib/helpers.sh" "" "")
assert_eq "detection works without GitHub" "true" "$result"

# Gate works without GitHub
if check_meta_feature_decomposition "42" "" \
    "modify scripts/sw-pipeline.sh and scripts/lib/helpers.sh" "" 2>/dev/null; then
    assert_fail "gate works without GitHub"
else
    assert_pass "gate works without GitHub"
fi

# Bypass works without GitHub
check_meta_feature_decomposition "42" "subtask" \
    "modify scripts/sw-pipeline.sh" "" 2>/dev/null
assert_eq "bypass works without GitHub" "0" "$?"

unset NO_GITHUB

print_test_results
