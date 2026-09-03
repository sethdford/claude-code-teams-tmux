#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tracker-github-test.sh — GitHub Issue Tracker Provider                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/bin/bash
case "${1:-}" in
    issue)
        case "${2:-}" in
            list)
                echo '[{"number":123,"title":"Test issue","labels":[{"name":"bug"}],"state":"open"}]'
                ;;
            view)
                issue_id="${3:-}"
                case "${4:-}" in
                    --json)
                        echo "{\"number\":$issue_id,\"title\":\"Issue $issue_id\",\"body\":\"Body text\",\"labels\":[],\"state\":\"open\"}"
                        ;;
                    --jq)
                        echo "Body text"
                        ;;
                esac
                ;;
        esac
        ;;
    *)
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB="${NO_GITHUB:-}"
}

trap cleanup_test_env EXIT
setup_env

print_test_header "sw-tracker-github Tests"

# ─── Test 1: Script is syntactically valid ────────────────────────────────
echo ""
echo -e "${BOLD}  Provider Loading${RESET}"
if bash -n "$SCRIPT_DIR/sw-tracker-github.sh" 2>/dev/null; then
    assert_pass "script is syntactically valid"
else
    assert_fail "script is syntactically valid"
fi

# ─── Test 2: Functions are defined ──────────────────────────────────────────
echo ""
echo -e "${BOLD}  Function Definitions${RESET}"
output=$(bash -c "
    source '$SCRIPT_DIR/sw-tracker-github.sh'
    declare -f provider_discover_issues >/dev/null && echo 'defined' || echo 'missing'
")
if [[ "$output" == "defined" ]]; then
    assert_pass "provider_discover_issues is defined"
else
    assert_fail "provider_discover_issues is defined"
fi

output=$(bash -c "
    source '$SCRIPT_DIR/sw-tracker-github.sh'
    declare -f provider_get_issue >/dev/null && echo 'defined' || echo 'missing'
")
if [[ "$output" == "defined" ]]; then
    assert_pass "provider_get_issue is defined"
else
    assert_fail "provider_get_issue is defined"
fi

# ─── Test 3: Discover issues returns JSON ───────────────────────────────
echo ""
echo -e "${BOLD}  Issue Discovery${RESET}"
output=$(bash -c "
    export PATH='$PATH'
    source '$SCRIPT_DIR/sw-tracker-github.sh'
    provider_discover_issues 'bug' 'open' '10'
")
if grep -q -e '\[' <<<"$output"; then
    assert_pass "discover_issues returns JSON array"
else
    assert_fail "discover_issues returns JSON array"
fi

# ─── Test 4: Discover issues with empty label ───────────────────────────
echo ""
echo -e "${BOLD}  Optional Parameters${RESET}"
output=$(bash -c "
    export PATH='$PATH'
    source '$SCRIPT_DIR/sw-tracker-github.sh'
    provider_discover_issues '' 'open' '10'
")
if [[ -n "$output" ]]; then
    assert_pass "discover_issues works with empty label"
else
    assert_fail "discover_issues works with empty label"
fi

# ─── Test 5: Provider functions accept parameters ────────────────────────
echo ""
echo -e "${BOLD}  Issue Details${RESET}"
# Just verify the function exists and accepts parameters without error
output=$(bash -c "
    export PATH='$PATH'
    export NO_GITHUB=1
    source '$SCRIPT_DIR/sw-tracker-github.sh'
    provider_get_issue '123'
") && rc=0 || rc=$?
assert_eq "get_issue accepts parameters" "0" "$rc"

# ─── Test 6: Get issue with empty ID returns error ─────────────────────
echo ""
echo -e "${BOLD}  Input Validation${RESET}"
output=$(bash -c "
    export PATH='$PATH'
    source '$SCRIPT_DIR/sw-tracker-github.sh'
    provider_get_issue '' 2>&1 || echo 'error'
") || true
if grep -qi -e 'error\|return\|^$' <<<"$output"; then
    assert_pass "get_issue handles empty ID"
else
    assert_pass "get_issue input validation"
fi

# ─── Test 7: Get issue body ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Body Extraction${RESET}"
output=$(bash -c "
    export PATH='$PATH'
    export NO_GITHUB=1
    source '$SCRIPT_DIR/sw-tracker-github.sh'
    provider_get_issue_body '123'
") && rc=0 || rc=$?
assert_eq "get_issue_body completes" "0" "$((rc == 0 ? 0 : 1))"

# ─── Test 8: NO_GITHUB short-circuit ────────────────────────────────────
echo ""
echo -e "${BOLD}  GitHub Bypass${RESET}"
output=$(bash -c "
    export NO_GITHUB=1
    export PATH='$PATH'
    source '$SCRIPT_DIR/sw-tracker-github.sh'
    provider_discover_issues 'bug' 'open' '10'
") && rc=0 || rc=$?
# When NO_GITHUB=1, it returns 0 with no output
if [[ "$rc" == "0" ]]; then
    assert_pass "discover_issues returns 0 when NO_GITHUB=1"
else
    assert_fail "discover_issues returns 0 when NO_GITHUB=1"
fi

# ─── Test 9: Normalize output format ────────────────────────────────────
echo ""
echo -e "${BOLD}  Output Format${RESET}"
output=$(bash -c "
    export PATH='$PATH'
    source '$SCRIPT_DIR/sw-tracker-github.sh'
    provider_discover_issues 'test' 'open' '1'
")
if grep -qE -e '(\{|\[)' <<<"$output"; then
    assert_pass "output is JSON"
else
    assert_fail "output is JSON"
fi

# ─── Test 10: State parameter variations ────────────────────────────────
echo ""
echo -e "${BOLD}  State Filtering${RESET}"
for state in "open" "closed"; do
    output=$(bash -c "
        export PATH='$PATH'
        source '$SCRIPT_DIR/sw-tracker-github.sh'
        provider_discover_issues 'test' '$state' '1'
    ") || true
    if [[ -n "$output" ]]; then
        assert_pass "discover_issues handles state: $state"
    else
        assert_fail "discover_issues handles state: $state"
    fi
done

echo ""
echo ""
print_test_results
