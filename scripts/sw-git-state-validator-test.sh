#!/usr/bin/env bash
# Test suite for git-state-validator.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

# Mock emit_event for testing
emit_event() {
    true
}

# Test framework
test_case() {
    local name="$1"
    echo -n "Testing: $name ... "
}

pass() {
    echo -e "${GREEN}✓ PASS${NC}"
    PASS=$((PASS + 1))
}

fail() {
    local msg="${1:-}"
    echo -e "${RED}✗ FAIL${NC}"
    [[ -n "$msg" ]] && echo "  Error: $msg"
    FAIL=$((FAIL + 1))
}

# ─── Unit Tests ───────────────────────────────────────────────────────────

test_case "manifest file exists"
if [[ -f "$REPO_DIR/.claude/pipeline-artifacts/stage-manifests.json" ]]; then
    pass
else
    fail "manifest file not found"
fi

test_case "manifest is valid JSON"
if jq empty "$REPO_DIR/.claude/pipeline-artifacts/stage-manifests.json" 2>/dev/null; then
    pass
else
    fail "manifest is not valid JSON"
fi

test_case "manifest has all 14 stages"
MANIFEST_FILE="$REPO_DIR/.claude/pipeline-artifacts/stage-manifests.json"
EXPECTED_STAGES=("intake" "plan" "design" "spec_generation" "build" "test" "review" "spec_verification" "compound_quality" "pr" "merge" "deploy" "validate" "monitor")
ACTUAL_COUNT=$(jq '.stages | keys | length' "$MANIFEST_FILE" 2>/dev/null || echo 0)
if [[ "$ACTUAL_COUNT" == "14" ]]; then
    pass
else
    fail "expected 14 stages, got $ACTUAL_COUNT"
fi

test_case "git-state-validator.sh module exists"
if [[ -f "$SCRIPT_DIR/lib/git-state-validator.sh" ]]; then
    pass
else
    fail "git-state-validator.sh not found"
fi

test_case "git-state-validator.sh can be sourced"
if bash -c "source '$SCRIPT_DIR/lib/git-state-validator.sh' && echo ok" >/dev/null 2>&1; then
    pass
else
    fail "git-state-validator.sh cannot be sourced"
fi

test_case "all 14 stages exist in manifest"
all_exist=true
for stage in "${EXPECTED_STAGES[@]}"; do
    before_policy=$(jq -r --arg s "$stage" '.stages[$s].before_policy' "$MANIFEST_FILE" 2>/dev/null || echo "")
    after_policy=$(jq -r --arg s "$stage" '.stages[$s].after_policy' "$MANIFEST_FILE" 2>/dev/null || echo "")
    if [[ -z "$before_policy" ]] || [[ -z "$after_policy" ]]; then
        all_exist=false
        break
    fi
done
if [[ "$all_exist" == "true" ]]; then
    pass
else
    fail "not all stages have policies"
fi

test_case "manifest has escape_hatches section"
if jq -e '.escape_hatches' "$MANIFEST_FILE" >/dev/null 2>&1; then
    pass
else
    fail "escape_hatches section missing from manifest"
fi

test_case "pipeline-execution.sh sources git-state-validator"
if grep -q "git-state-validator" "$SCRIPT_DIR/lib/pipeline-execution.sh" 2>/dev/null; then
    pass
else
    fail "pipeline-execution.sh does not source git-state-validator"
fi

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}✓ All tests passed ($PASS/$((PASS + FAIL)))${NC}"
    exit 0
else
    echo -e "${RED}✗ Tests failed: $FAIL/$((PASS + FAIL))${NC}"
    exit 1
fi
