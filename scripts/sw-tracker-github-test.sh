#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tracker-github-test.sh — Test GitHub provider functions               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-tracker-github Provider Test Suite"

setup_test_env "sw-tracker-github-test"
trap cleanup_test_env EXIT

# Helper: run a test and track pass/fail
run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# Copy provider script and dependencies
mkdir -p "$TEST_TEMP_DIR/scripts/lib"
cp "$SCRIPT_DIR/sw-tracker-github.sh" "$TEST_TEMP_DIR/scripts/"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_TEMP_DIR/scripts/lib/"

# Create mock gh binary
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/gh" <<'GH_MOCK'
#!/usr/bin/env bash
# Mock gh — returns responses based on command and env vars

# Log all calls for debugging
echo "gh $@" >> "${MOCK_GH_LOG:-/dev/null}"

case "${1:-}" in
    issue)
        case "${2:-}" in
            list)
                # Return mock issue list
                if [[ -n "${MOCK_GH_FAIL:-}" ]]; then
                    exit 1
                fi
                echo '[{"number":123,"title":"Test Issue","labels":[{"name":"shipwright"}],"state":"open"}]'
                exit 0
                ;;
            view)
                # Return mock issue details
                if [[ -n "${MOCK_GH_FAIL:-}" ]]; then
                    exit 1
                fi
                local issue_id="${3:-}"
                echo '{"number":'${issue_id}',"title":"Test Issue","body":"Issue body text","labels":[{"name":"shipwright"}],"state":"open"}'
                exit 0
                ;;
            edit)
                # No output for edit commands
                [[ -n "${MOCK_GH_FAIL:-}" ]] && exit 1 || exit 0
                ;;
            comment)
                # Return success
                [[ -n "${MOCK_GH_FAIL:-}" ]] && exit 1 || exit 0
                ;;
            close)
                # Return success
                [[ -n "${MOCK_GH_FAIL:-}" ]] && exit 1 || exit 0
                ;;
            create)
                # Return issue creation response
                if [[ -n "${MOCK_GH_FAIL:-}" ]]; then
                    exit 1
                fi
                echo "Created issue sethdford/shipwright#456"
                exit 0
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
GH_MOCK
chmod +x "$TEST_TEMP_DIR/bin/gh"

# Source the provider script
export SCRIPT_DIR="$TEST_TEMP_DIR/scripts"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
export HOME="$TEST_TEMP_DIR"
source "$TEST_TEMP_DIR/scripts/sw-tracker-github.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "provider_discover_issues()"

# Test: Returns JSON array with correct schema
test_discover_issues_returns_json() {
    local result
    result=$(provider_discover_issues "shipwright" "open" 50)
    if echo "$result" | jq -e '.[0].id and .[0].title and .[0].labels and .[0].state' >/dev/null 2>&1; then
        return 0
    fi
    echo "Result: $result"
    return 1
}

# Test: Respects label filter
test_discover_issues_label_filter() {
    local result
    result=$(provider_discover_issues "test-label" "open" 10)
    # Mock gh should have been called with --label test-label
    if [[ -f "${MOCK_GH_LOG:-/dev/null}" ]]; then
        grep -q "test-label" "${MOCK_GH_LOG:-/dev/null}" && return 0
    fi
    return 1
}

# Test: Returns empty array on gh failure
test_discover_issues_gh_failure() {
    local result
    result=$(
        MOCK_GH_FAIL=1 \
        provider_discover_issues "test" "open" 50
    )
    [[ "$result" == "[]" ]] && return 0 || { echo "Expected [], got $result"; return 1; }
}

# Test: NO_GITHUB guard returns 0
test_discover_issues_no_github_guard() {
    local result
    result=$(
        NO_GITHUB=1 \
        provider_discover_issues "test" "open" 50
    )
    [[ $? -eq 0 ]] && return 0 || return 1
}

print_test_section "provider_get_issue()"

# Test: Returns normalized issue JSON
test_get_issue_returns_json() {
    local result
    result=$(provider_get_issue "123")
    if echo "$result" | jq -e '.id and .title and .body and .labels and .state' >/dev/null 2>&1; then
        return 0
    fi
    echo "Result: $result"
    return 1
}

# Test: Returns error (exit code 1) on missing issue_id
test_get_issue_missing_id() {
    provider_get_issue "" 2>/dev/null && return 1 || return 0
}

# Test: NO_GITHUB guard returns 0
test_get_issue_no_github_guard() {
    NO_GITHUB=1 provider_get_issue "123" >/dev/null 2>&1
    [[ $? -eq 0 ]] && return 0 || return 1
}

print_test_section "provider_get_issue_body()"

# Test: Returns text body
test_get_issue_body_returns_text() {
    local result
    result=$(provider_get_issue_body "123")
    [[ -n "$result" ]] && return 0 || return 1
}

# Test: Missing issue_id returns error
test_get_issue_body_missing_id() {
    provider_get_issue_body "" 2>/dev/null && return 1 || return 0
}

print_test_section "provider_add_label()"

# Test: Calls gh with correct arguments
test_add_label_calls_gh() {
    local log_file="$TEST_TEMP_DIR/mock-gh.log"
    mkdir -p "$(dirname "$log_file")"
    MOCK_GH_LOG="$log_file" provider_add_label "123" "test-label"
    grep -q "edit.*123.*--add-label.*test-label" "$log_file" 2>/dev/null && return 0
    return 1
}

# Test: Missing args returns error
test_add_label_missing_args() {
    provider_add_label "" "label" 2>/dev/null && return 1 || return 0
}

print_test_section "provider_remove_label()"

# Test: Calls gh with correct arguments
test_remove_label_calls_gh() {
    local log_file="$TEST_TEMP_DIR/mock-gh.log"
    mkdir -p "$(dirname "$log_file")"
    MOCK_GH_LOG="$log_file" provider_remove_label "123" "test-label"
    grep -q "edit.*123.*--remove-label.*test-label" "$log_file" 2>/dev/null && return 0
    return 1
}

# Test: Missing args returns error
test_remove_label_missing_args() {
    provider_remove_label "123" "" 2>/dev/null && return 1 || return 0
}

print_test_section "provider_comment()"

# Test: Creates comment on issue
test_comment_creates_comment() {
    local result
    result=$(provider_comment "123" "Test comment")
    [[ $? -eq 0 ]] && return 0 || return 1
}

# Test: Empty body returns error
test_comment_empty_body() {
    provider_comment "123" "" 2>/dev/null && return 1 || return 0
}

print_test_section "provider_close_issue()"

# Test: Closes issue
test_close_issue_closes() {
    provider_close_issue "123"
    [[ $? -eq 0 ]] && return 0 || return 1
}

# Test: Missing issue_id returns error
test_close_issue_missing_id() {
    provider_close_issue "" 2>/dev/null && return 1 || return 0
}

print_test_section "provider_create_issue()"

# Test: Creates issue and extracts number
test_create_issue_extracts_number() {
    local result
    result=$(provider_create_issue "Test Title" "Test Body")
    if echo "$result" | jq -e '.id == 456 and .title' >/dev/null 2>&1; then
        return 0
    fi
    echo "Result: $result"
    return 1
}

# Test: Handles comma-separated labels
test_create_issue_comma_labels() {
    local log_file="$TEST_TEMP_DIR/mock-gh.log"
    mkdir -p "$(dirname "$log_file")"
    MOCK_GH_LOG="$log_file" provider_create_issue "Title" "Body" "label1,label2"
    if grep -q -- "--label.*label1" "$log_file" 2>/dev/null && grep -q -- "--label.*label2" "$log_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Test: Handles space-separated labels
test_create_issue_space_labels() {
    local log_file="$TEST_TEMP_DIR/mock-gh.log"
    mkdir -p "$(dirname "$log_file")"
    MOCK_GH_LOG="$log_file" provider_create_issue "Title" "Body" "label1 label2"
    if grep -q -- "--label.*label1" "$log_file" 2>/dev/null && grep -q -- "--label.*label2" "$log_file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Test: Missing title returns error
test_create_issue_missing_title() {
    provider_create_issue "" "Body" 2>/dev/null && return 1 || return 0
}

print_test_section "provider_notify()"

# Test: Logs event
test_provider_notify_logs() {
    local log_file="$HOME/.shipwright/events.jsonl"
    mkdir -p "$(dirname "$log_file")"
    provider_notify "test_event" "123" "detail"
    if [[ -f "$log_file" ]]; then
        grep -q "tracker.notify" "$log_file" && return 0
    fi
    return 1
}

# Test: NO_GITHUB doesn't prevent notify
test_provider_notify_no_github() {
    NO_GITHUB=1 provider_notify "test" "123" "detail"
    [[ $? -eq 0 ]] && return 0 || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

run_test "discover_issues: returns JSON array" test_discover_issues_returns_json
run_test "discover_issues: respects label filter" test_discover_issues_label_filter
run_test "discover_issues: gh failure returns []" test_discover_issues_gh_failure
run_test "discover_issues: NO_GITHUB guard" test_discover_issues_no_github_guard

run_test "get_issue: returns normalized JSON" test_get_issue_returns_json
run_test "get_issue: missing ID exits 1" test_get_issue_missing_id
run_test "get_issue: NO_GITHUB guard" test_get_issue_no_github_guard

run_test "get_issue_body: returns text" test_get_issue_body_returns_text
run_test "get_issue_body: missing ID exits 1" test_get_issue_body_missing_id

run_test "add_label: calls gh correctly" test_add_label_calls_gh
run_test "add_label: missing args exits 1" test_add_label_missing_args

run_test "remove_label: calls gh correctly" test_remove_label_calls_gh
run_test "remove_label: missing args exits 1" test_remove_label_missing_args

run_test "comment: creates comment" test_comment_creates_comment
run_test "comment: empty body exits 1" test_comment_empty_body

run_test "close_issue: closes issue" test_close_issue_closes
run_test "close_issue: missing ID exits 1" test_close_issue_missing_id

run_test "create_issue: extracts number" test_create_issue_extracts_number
run_test "create_issue: comma-separated labels" test_create_issue_comma_labels
run_test "create_issue: space-separated labels" test_create_issue_space_labels
run_test "create_issue: missing title exits 1" test_create_issue_missing_title

run_test "provider_notify: logs event" test_provider_notify_logs
run_test "provider_notify: NO_GITHUB guard" test_provider_notify_no_github

print_test_results

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
