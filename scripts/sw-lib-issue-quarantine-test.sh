#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/issue-quarantine test — Unit tests for quarantine system  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: issue-quarantine Tests"

setup_test_env "sw-lib-issue-quarantine-test"
trap cleanup_test_env EXIT

# Source the lib (clear guard to re-source)
_SW_ISSUE_QUARANTINE_LOADED=""
source "$SCRIPT_DIR/lib/issue-quarantine.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_label: Returns the E2E test label
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_label"

label=$(quarantine_label)
assert_eq "quarantine_label returns default 'sw:e2e-test'" "sw:e2e-test" "$label"

# Test with SHIPWRIGHT_LABELS_E2E_TEST env var
export SHIPWRIGHT_LABELS_E2E_TEST="custom:label"
label=$(quarantine_label)
assert_eq "quarantine_label respects SHIPWRIGHT_LABELS_E2E_TEST env var" "custom:label" "$label"
unset SHIPWRIGHT_LABELS_E2E_TEST

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_labels: Returns all quarantine labels (including legacy)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_labels"

labels=$(quarantine_labels)
if echo "$labels" | grep -q "sw:e2e-test"; then
    assert_pass "quarantine_labels includes 'sw:e2e-test'"
else
    assert_fail "quarantine_labels includes 'sw:e2e-test'" "got: $labels"
fi

if echo "$labels" | grep -q "e2e-test"; then
    assert_pass "quarantine_labels includes legacy 'e2e-test'"
else
    assert_fail "quarantine_labels includes legacy 'e2e-test'" "got: $labels"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_filter_json: Filters quarantined issues from JSON array
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_filter_json"

# Test case 1: Filter removes issue with quarantine label
input='[{"number":1,"title":"Real issue","labels":[{"name":"bug"}]},{"number":2,"title":"E2E test issue","labels":[{"name":"sw:e2e-test"}]}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter removes issue with 'sw:e2e-test' label" "1" "$count"

# Test case 2: Filter keeps issue without quarantine label
input='[{"number":1,"title":"Real issue","labels":[{"name":"bug"}]}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter keeps issue without quarantine label" "1" "$count"

# Test case 3: Filter with legacy e2e-test label
input='[{"number":1,"title":"Old E2E test","labels":[{"name":"e2e-test"}]}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter removes issue with legacy 'e2e-test' label" "0" "$count"

# Test case 4: Empty input
input=""
output=$(echo -n "$input" | quarantine_filter_json "test")
assert_eq "Filter handles empty input" "" "$output"

# Test case 5: Issue without labels field
input='[{"number":1,"title":"No labels field"}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter handles missing labels field" "1" "$count"

# Test case 6: Mixed quarantined and non-quarantined
input='[{"number":1,"title":"Real issue","labels":[{"name":"bug"}]},{"number":2,"title":"E2E test","labels":[{"name":"sw:e2e-test"}]},{"number":3,"title":"Another real issue","labels":[{"name":"feature"}]}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter keeps 2 real issues, removes 1 E2E issue" "2" "$count"

# Test case 7: Fail-open on malformed JSON
input='[invalid json'
output=$(echo "$input" | quarantine_filter_json "test" 2>/dev/null || true)
if [[ -n "$output" ]]; then
    assert_pass "Filter fails open on malformed JSON (returns input)"
else
    assert_fail "Filter fails open on malformed JSON"
fi

# Test case 8: Fail-open on jq failure (empty input also covered)
input=""
output=$(echo -n "$input" | quarantine_filter_json "test")
if [[ "$?" -eq 0 ]]; then
    assert_pass "Filter returns exit code 0 on empty input (fail-open)"
else
    assert_fail "Filter returns exit code 0 on empty input (fail-open)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_search_qualifier: Emits server-side search qualifier
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_search_qualifier"

qualifier=$(quarantine_search_qualifier)
if echo "$qualifier" | grep -q 'sw:e2e-test'; then
    assert_pass "quarantine_search_qualifier includes 'sw:e2e-test'"
else
    assert_fail "quarantine_search_qualifier includes 'sw:e2e-test'" "got: $qualifier"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_is_test_issue: Test whether a single issue is quarantined
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_is_test_issue"

# Issue with quarantine label
issue_json='{"number":1,"title":"E2E test","labels":[{"name":"sw:e2e-test"}]}'
if quarantine_is_test_issue "$issue_json"; then
    assert_pass "quarantine_is_test_issue returns 0 for quarantined issue"
else
    assert_fail "quarantine_is_test_issue returns 0 for quarantined issue"
fi

# Issue without quarantine label
issue_json='{"number":1,"title":"Real issue","labels":[{"name":"bug"}]}'
if quarantine_is_test_issue "$issue_json"; then
    assert_fail "quarantine_is_test_issue returns 1 for non-quarantined issue"
else
    assert_pass "quarantine_is_test_issue returns 1 for non-quarantined issue"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Integration: wiring verification
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration & Wiring"

# Verify quarantine_label is idempotent
label1=$(quarantine_label)
label2=$(quarantine_label)
assert_eq "quarantine_label is idempotent" "$label1" "$label2"

# Verify all functions exist
for fn in quarantine_label quarantine_labels quarantine_filter_json quarantine_search_qualifier quarantine_is_test_issue; do
    if declare -f "$fn" >/dev/null 2>&1; then
        assert_pass "Function '$fn' exists and is callable"
    else
        assert_fail "Function '$fn' exists and is callable"
    fi
done

print_test_results
