#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   sw-intent-analysis-test.sh — Test suite for intent analysis module
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/lib/intent-analysis.sh"

VERSION="3.3.0"

# ─── Test Counters ──────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Test utilities
test_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    success "$1"
}

test_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    error "$1"
}

test_skip() {
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    warn "$1"
}

assert_file_exists() {
    local file="$1"
    local msg="${2:-File should exist: $file}"
    [[ -f "$file" ]] || { test_fail "$msg"; return 1; }
}

assert_json_valid() {
    local file="$1"
    local msg="${2:-JSON should be valid: $file}"
    jq empty "$file" 2>/dev/null || { test_fail "$msg"; return 1; }
}

assert_contains() {
    local file="$1"
    local pattern="$2"
    local msg="${3:-File should contain pattern}"
    grep -q "$pattern" "$file" || { test_fail "$msg"; return 1; }
}

# ─── Setup ──────────────────────────────────────────────────────
TEMP_DIR=$(mktemp -d)
MOCK_BIN_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR" "$MOCK_BIN_DIR"' EXIT

# ─── Mock `claude` ──────────────────────────────────────────────
# analyze_intent shells out to the real CLI whenever one is on PATH. Left
# unmocked, this suite made three live, billed API calls whose latency blew the
# runner's per-suite timeout and whose output varied run to run — it passed only
# on machines with no `claude` installed, by silently taking the fallback path.
# The mock pins the real CLI's envelope shape so the unwrap logic is what gets
# exercised.
MOCK_CLAUDE_PAYLOAD="$MOCK_BIN_DIR/payload.json"
cat > "$MOCK_CLAUDE_PAYLOAD" <<'EOF'
{
  "version": 1,
  "goal": "Mocked goal",
  "generated_at": "2026-01-01T00:00:00Z",
  "who_benefits": "users",
  "what_changes": "the thing changes",
  "why_matters": "because",
  "how_know_worked": "tests pass",
  "out_of_scope": "everything else",
  "criteria": [
    { "id": "ac-1", "description": "Does the thing", "type": "functional", "verifiable": true },
    { "id": "ac-2", "description": "Stays fast", "type": "nonfunctional", "verifiable": true }
  ]
}
EOF

cat > "$MOCK_BIN_DIR/claude" <<'EOF'
#!/usr/bin/env bash
# Emit the same result envelope as `claude --print --output-format json`:
# the model's text lives in .result as a JSON *string*, not as an object.
payload=$(cat "${MOCK_CLAUDE_PAYLOAD:?}")
jq -n --arg r "$payload" '{type: "result", subtype: "success", is_error: false, result: $r, total_cost_usd: 0}'
EOF
chmod +x "$MOCK_BIN_DIR/claude"
export MOCK_CLAUDE_PAYLOAD
export PATH="$MOCK_BIN_DIR:$PATH"

# ───────────────────────────────────────────────────────────────
# Test: analyze_intent generates valid JSON
# ───────────────────────────────────────────────────────────────
test_analyze_intent_generates_json() {
    local title="Fix auth module authentication flow"
    local body="Currently users cannot log in via OAuth. We need to implement OAuth provider integration."
    local labels="bug,auth"

    if analyze_intent "$title" "$body" "$labels" "$TEMP_DIR"; then
        if assert_file_exists "$TEMP_DIR/acceptance-criteria.json" "Should generate acceptance-criteria.json"; then
            if assert_json_valid "$TEMP_DIR/acceptance-criteria.json"; then
                test_pass "analyze_intent generates valid JSON"
                return 0
            fi
        fi
    fi
    test_fail "analyze_intent should generate valid JSON"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: acceptance criteria has required fields
# ───────────────────────────────────────────────────────────────
test_acceptance_criteria_schema() {
    local title="Add user profile API endpoint"
    local body="Users need a way to fetch their profile information"
    local labels="feature,api"

    analyze_intent "$title" "$body" "$labels" "$TEMP_DIR" || true

    if [[ ! -f "$TEMP_DIR/acceptance-criteria.json" ]]; then
        test_fail "acceptance-criteria.json not found"
        return 1
    fi

    # Check required top-level fields
    local version goal criteria
    version=$(jq -r '.version // empty' "$TEMP_DIR/acceptance-criteria.json" 2>/dev/null || true)
    goal=$(jq -r '.goal // empty' "$TEMP_DIR/acceptance-criteria.json" 2>/dev/null || true)
    criteria=$(jq -r '.criteria[]? // empty' "$TEMP_DIR/acceptance-criteria.json" 2>/dev/null | wc -l | tr -d ' ')

    [[ -n "$version" && -n "$goal" && "$criteria" -gt 0 ]] || {
        test_fail "Schema missing required fields (version, goal, criteria)"
        return 1
    }

    test_pass "Acceptance criteria has required schema fields"
    return 0
}

# ───────────────────────────────────────────────────────────────
# Test: criteria items have id, description, type, verifiable
# ───────────────────────────────────────────────────────────────
test_criteria_fields() {
    local title="Implement caching layer"
    local body="Add Redis caching to reduce database load"

    analyze_intent "$title" "$body" "" "$TEMP_DIR" || true

    if [[ ! -f "$TEMP_DIR/acceptance-criteria.json" ]]; then
        test_fail "acceptance-criteria.json not found"
        return 1
    fi

    # Check that all criteria have required fields
    local invalid_count
    invalid_count=$(jq '[.criteria[]? | select(.id == null or .description == null or .type == null or .verifiable == null)] | length' "$TEMP_DIR/acceptance-criteria.json" 2>/dev/null || echo "0")

    if [[ "$invalid_count" -eq 0 ]]; then
        test_pass "All criteria items have required fields"
        return 0
    fi

    test_fail "Criteria items missing required fields (count: $invalid_count)"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: failure mode validation accepts adequate plans
# ───────────────────────────────────────────────────────────────
test_failure_modes_validation_pass() {
    local plan_file="$TEMP_DIR/valid-plan.md"

    cat > "$plan_file" <<'EOF'
# Implementation Plan

## Files to Modify
- src/auth.js
- tests/auth.test.js

## Implementation Steps
1. Add authentication middleware
2. Implement JWT validation
3. Add refresh token logic

## Failure Mode Analysis

### Runtime Failures
1. Database connection unavailable: Application will retry with exponential backoff on connection pool timeout
2. Redis cache miss: System falls back to database query
3. External service timeout: Return error to client after 30s timeout

### Concurrency Risks
1. Race condition on token refresh: Use distributed lock on Redis with TTL
2. Duplicate token generation: Ensure idempotent token generation with nonce validation
3. Stale session state: Invalidate local cache on logout

### Scale Risks
1. High concurrency: Token generation becomes bottleneck; implement async queue for validations
2. Memory pressure: Limit in-memory cache size with LRU eviction
3. Database overload: Cache tokens for 5 minutes

### Rollback Story
- Revert commit: Auth routes will error until deployment rolls back
- Feature flag: Wrap new OAuth flow in feature flag to disable safely
- Data migration: No schema changes, backward-compatible

## Task Checklist
- [ ] Implement OAuth client initialization
- [ ] Add token validation middleware
- [ ] Write integration tests
EOF

    if validate_failure_modes "$plan_file"; then
        test_pass "Failure mode validation accepts adequate plans"
        return 0
    fi

    test_fail "Should accept plan with 3+ concrete failure modes"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: failure mode validation rejects missing section
# ───────────────────────────────────────────────────────────────
test_failure_modes_validation_missing_section() {
    local plan_file="$TEMP_DIR/missing-fma-plan.md"

    cat > "$plan_file" <<'EOF'
# Implementation Plan

## Files to Modify
- src/api.js

## Implementation Steps
1. Create endpoint
2. Add error handling
3. Write tests

## Task Checklist
- [ ] Implement API route
- [ ] Add tests
EOF

    if ! validate_failure_modes "$plan_file"; then
        test_pass "Failure mode validation rejects plans without failure mode section"
        return 0
    fi

    test_fail "Should reject plan without failure mode analysis section"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: failure mode validation rejects too few items
# ───────────────────────────────────────────────────────────────
test_failure_modes_validation_too_few() {
    local plan_file="$TEMP_DIR/shallow-fma-plan.md"

    cat > "$plan_file" <<'EOF'
# Implementation Plan

## Implementation Steps
1. Do the thing

## Failure Mode Analysis
This plan should handle errors gracefully.

## Task Checklist
- [ ] Implement feature
EOF

    if ! validate_failure_modes "$plan_file"; then
        test_pass "Failure mode validation rejects plans with <3 failure modes"
        return 0
    fi

    test_fail "Should reject plan with fewer than 3 failure modes"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: failure mode validation rejects generic analysis
# ───────────────────────────────────────────────────────────────
test_failure_modes_validation_generic() {
    local plan_file="$TEMP_DIR/generic-fma-plan.md"

    cat > "$plan_file" <<'EOF'
# Implementation Plan

## Failure Mode Analysis

1. Something might fail
2. Other things could break
3. More things might go wrong

This needs to be handled gracefully.
EOF

    if ! validate_failure_modes "$plan_file"; then
        test_pass "Failure mode validation rejects generic/non-specific analysis"
        return 0
    fi

    test_fail "Should reject plan with generic failure modes (no project specificity)"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: format_acceptance_criteria_for_prompt produces readable text
# ───────────────────────────────────────────────────────────────
test_format_criteria_for_prompt() {
    local title="Add logging to auth module"
    local body="Need to track auth failures for debugging"

    analyze_intent "$title" "$body" "" "$TEMP_DIR" || true

    if [[ ! -f "$TEMP_DIR/acceptance-criteria.json" ]]; then
        test_fail "acceptance-criteria.json not found"
        return 1
    fi

    local formatted
    formatted=$(format_acceptance_criteria_for_prompt "$TEMP_DIR" 2>/dev/null || true)

    if [[ -n "$formatted" ]] && grep -q -e "Definition of Success" <<<"$formatted"; then
        if grep -q -e "Acceptance Criteria" <<<"$formatted"; then
            test_pass "format_acceptance_criteria_for_prompt produces readable output"
            return 0
        fi
    fi

    test_fail "Format function should produce readable markdown"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: load_acceptance_criteria returns valid JSON
# ───────────────────────────────────────────────────────────────
test_load_acceptance_criteria() {
    local title="Test issue"
    local body="Test body"

    analyze_intent "$title" "$body" "" "$TEMP_DIR" || true

    local loaded
    loaded=$(load_acceptance_criteria "$TEMP_DIR" 2>/dev/null || true)

    if [[ -n "$loaded" && "$loaded" != "{}" ]]; then
        if jq empty <<< "$loaded" 2>/dev/null; then
            test_pass "load_acceptance_criteria returns valid JSON"
            return 0
        fi
    fi

    test_fail "load_acceptance_criteria should return valid JSON"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: analyze_intent works without Claude (fallback)
# ───────────────────────────────────────────────────────────────
test_analyze_intent_fallback() {
    local test_dir="$TEMP_DIR/fallback-test"
    mkdir -p "$test_dir"

    # Temporarily make Claude unavailable
    local old_path="$PATH"
    export PATH="/usr/bin:/bin"  # Reduced PATH without Claude

    local title="Fallback test"
    local body="Should still generate criteria without Claude"

    if analyze_intent "$title" "$body" "" "$test_dir" 2>/dev/null; then
        if [[ -f "$test_dir/acceptance-criteria.json" ]]; then
            if jq empty "$test_dir/acceptance-criteria.json" 2>/dev/null; then
                test_pass "analyze_intent falls back to defaults when Claude unavailable"
                export PATH="$old_path"
                return 0
            fi
        fi
    fi

    export PATH="$old_path"
    test_fail "Should generate default criteria without Claude"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: inject_failure_mode_analysis adds requirement to prompt
# ───────────────────────────────────────────────────────────────
test_inject_failure_mode_analysis() {
    local prompt="Initial plan prompt"

    local injected
    injected=$(inject_failure_mode_analysis "$prompt" "" 2>/dev/null || echo "$prompt")

    if [[ "$injected" != "$prompt" ]]; then
        if grep -q -e "Mandatory Failure Mode Analysis" <<<"$injected"; then
            if grep -q -e "at least 3 concrete failure modes" <<<"$injected"; then
                test_pass "inject_failure_mode_analysis adds requirement to prompt"
                return 0
            fi
        fi
    fi

    test_fail "inject_failure_mode_analysis should add failure mode requirement"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: get_failure_mode_validation_status returns correct status
# ───────────────────────────────────────────────────────────────
test_failure_mode_validation_status() {
    local valid_plan="$TEMP_DIR/status-valid.md"
    local missing_plan="$TEMP_DIR/status-missing.md"

    # Valid plan
    cat > "$valid_plan" <<'EOF'
## Failure Mode Analysis
1. Connection timeout: Retry with exponential backoff
2. Race condition: Use distributed locks
3. Database overload: Implement caching layer
EOF

    # Missing plan
    echo "No failure analysis here" > "$missing_plan"

    local valid_status
    valid_status=$(get_failure_mode_validation_status "$valid_plan" 2>/dev/null || true)

    local missing_status
    missing_status=$(get_failure_mode_validation_status "$missing_plan" 2>/dev/null || true)

    if [[ "$valid_status" == "valid" && "$missing_status" == "missing_section" ]]; then
        test_pass "get_failure_mode_validation_status returns correct status"
        return 0
    fi

    test_fail "Status function should return 'valid' or 'missing_section'"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: the Claude result envelope is unwrapped, not written through
# ───────────────────────────────────────────────────────────────
test_analyze_intent_unwraps_envelope() {
    local test_dir="$TEMP_DIR/envelope-test"
    mkdir -p "$test_dir"

    analyze_intent "Envelope test" "body" "" "$test_dir" || true

    local file="$test_dir/acceptance-criteria.json"
    if [[ ! -f "$file" ]]; then
        test_fail "acceptance-criteria.json not found"
        return 1
    fi

    # The envelope's own keys must NOT survive into the criteria file.
    if jq -e 'has("total_cost_usd") or (has("result") and (.result | type) == "string")' \
        "$file" >/dev/null 2>&1; then
        test_fail "Envelope was written through instead of unwrapped"
        return 1
    fi

    local goal criteria_count
    goal=$(jq -r '.goal // empty' "$file" 2>/dev/null || true)
    criteria_count=$(jq '.criteria | length' "$file" 2>/dev/null || echo 0)

    if [[ "$goal" == "Mocked goal" && "$criteria_count" -eq 2 ]]; then
        test_pass "analyze_intent unwraps the Claude result envelope"
        return 0
    fi

    test_fail "Unwrapped payload should carry the model's goal and criteria"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: fenced JSON from the model is still parsed
# ───────────────────────────────────────────────────────────────
test_analyze_intent_strips_code_fences() {
    local test_dir="$TEMP_DIR/fenced-test"
    mkdir -p "$test_dir"

    local original="$MOCK_CLAUDE_PAYLOAD"
    local fenced="$MOCK_BIN_DIR/fenced-payload.json"
    {
        echo '```json'
        cat "$original"
        echo '```'
    } > "$fenced"
    MOCK_CLAUDE_PAYLOAD="$fenced" analyze_intent "Fenced test" "body" "" "$test_dir" || true

    local goal
    goal=$(jq -r '.goal // empty' "$test_dir/acceptance-criteria.json" 2>/dev/null || true)

    if [[ "$goal" == "Mocked goal" ]]; then
        test_pass "analyze_intent strips markdown fences around the payload"
        return 0
    fi

    test_fail "Fenced payload should still yield the model's goal, got '$goal'"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Test: a well-formed envelope carrying prose falls back to defaults
# ───────────────────────────────────────────────────────────────
test_analyze_intent_rejects_non_schema_payload() {
    local test_dir="$TEMP_DIR/prose-test"
    mkdir -p "$test_dir"

    local prose="$MOCK_BIN_DIR/prose-payload.json"
    echo "I cannot help with that request." > "$prose"

    MOCK_CLAUDE_PAYLOAD="$prose" analyze_intent "Prose test" "body" "" "$test_dir" || true

    local file="$test_dir/acceptance-criteria.json"
    local goal criteria_count
    goal=$(jq -r '.goal // empty' "$file" 2>/dev/null || true)
    criteria_count=$(jq '.criteria | length' "$file" 2>/dev/null || echo 0)

    if [[ "$goal" == "Prose test" && "$criteria_count" -gt 0 ]]; then
        test_pass "analyze_intent falls back to defaults on non-schema output"
        return 0
    fi

    test_fail "Non-schema model output should fall back to default criteria"
    return 1
}

# ───────────────────────────────────────────────────────────────
# Main test runner
# ───────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║        Intent Analysis Module Test Suite v${VERSION}        ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    test_analyze_intent_generates_json
    test_acceptance_criteria_schema
    test_criteria_fields
    test_failure_modes_validation_pass
    test_failure_modes_validation_missing_section
    test_failure_modes_validation_too_few
    test_failure_modes_validation_generic
    test_format_criteria_for_prompt
    test_load_acceptance_criteria
    test_analyze_intent_fallback
    test_analyze_intent_unwraps_envelope
    test_analyze_intent_strips_code_fences
    test_analyze_intent_rejects_non_schema_payload
    test_inject_failure_mode_analysis
    test_failure_mode_validation_status

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║ Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed, ${TESTS_SKIPPED} skipped ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    [[ "$TESTS_FAILED" -eq 0 ]] && exit 0 || exit 1
}

main "$@"
