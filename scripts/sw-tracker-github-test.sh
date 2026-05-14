#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tracker-github-test.sh — Validate provider_* functions in            ║
# ║  sw-tracker-github.sh (issue list/get/create/comment/close/labels).      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/sw-tracker-github.sh"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""
GH_CALLS=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tracker-github-test.XXXXXX")
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/home/.shipwright"
    GH_CALLS="$TEMP_DIR/gh-calls.log"
    : > "$GH_CALLS"

    # Link real jq (provider functions pipe through jq)
    ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq" 2>/dev/null || true

    cat > "$TEMP_DIR/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALLS_FILE:-/dev/null}"
case "${1:-}" in
    issue)
        case "${2:-}" in
            list)
                echo '[{"number":42,"title":"Fix bug","labels":[{"name":"bug"}],"state":"OPEN"},{"number":43,"title":"Add feature","labels":[{"name":"enhancement"}],"state":"OPEN"}]'
                ;;
            view)
                # If --jq is in args, just emit body text
                for a in "$@"; do
                    if [[ "$a" == "--jq" ]]; then
                        echo "Plain body text"
                        exit 0
                    fi
                done
                echo '{"number":42,"title":"Fix bug","body":"Description here","labels":[{"name":"bug"}],"state":"OPEN"}'
                ;;
            create)
                echo "Created issue owner/repo#99"
                ;;
            comment|edit|close)
                exit 0
                ;;
            *)
                echo "{}"
                ;;
        esac
        ;;
    *)
        echo "{}"
        ;;
esac
exit 0
GH_EOF
    chmod +x "$TEMP_DIR/bin/gh"

    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export GH_CALLS_FILE="$GH_CALLS"
    unset NO_GITHUB
}

cleanup_env() {
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))
    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    : > "$GH_CALLS"
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

# ─── Tests ───────────────────────────────────────────────────────────────────

test_sources_cleanly() {
    ( source "$SCRIPT_UNDER_TEST" ) 2>/dev/null
}

test_exports_all_provider_functions() {
    (
        source "$SCRIPT_UNDER_TEST"
        type provider_discover_issues >/dev/null 2>&1 || exit 1
        type provider_get_issue >/dev/null 2>&1 || exit 1
        type provider_get_issue_body >/dev/null 2>&1 || exit 1
        type provider_add_label >/dev/null 2>&1 || exit 1
        type provider_remove_label >/dev/null 2>&1 || exit 1
        type provider_comment >/dev/null 2>&1 || exit 1
        type provider_close_issue >/dev/null 2>&1 || exit 1
        type provider_create_issue >/dev/null 2>&1 || exit 1
        type provider_notify >/dev/null 2>&1 || exit 1
    )
}

test_discover_calls_gh_issue_list() {
    ( source "$SCRIPT_UNDER_TEST" && provider_discover_issues "bug" "open" 25 >/dev/null 2>&1 ) || true
    grep -q "issue list" "$GH_CALLS" || return 1
    grep -q -- "--state open" "$GH_CALLS" || return 1
    grep -q -- "--limit 25" "$GH_CALLS" || return 1
    grep -q -- "--label bug" "$GH_CALLS" || return 1
    grep -q "number,title,labels,state" "$GH_CALLS" || return 1
}

test_discover_omits_label_when_empty() {
    ( source "$SCRIPT_UNDER_TEST" && provider_discover_issues "" "closed" 10 >/dev/null 2>&1 ) || true
    grep -q "issue list" "$GH_CALLS" || return 1
    grep -q -- "--state closed" "$GH_CALLS" || return 1
    grep -q -- "--label" "$GH_CALLS" && return 1
    return 0
}

test_discover_returns_normalized_json() {
    local result
    result=$( ( source "$SCRIPT_UNDER_TEST" && provider_discover_issues "" "open" 5 ) 2>/dev/null ) || true
    echo "$result" | jq -e 'length == 2' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.[0].id == 42' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.[0].title == "Fix bug"' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.[0].labels | type == "array"' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.[0].labels[0] == "bug"' >/dev/null 2>&1 || return 1
}

test_get_issue_calls_gh_view() {
    ( source "$SCRIPT_UNDER_TEST" && provider_get_issue "42" >/dev/null 2>&1 ) || true
    grep -q "issue view 42" "$GH_CALLS"
}

test_get_issue_returns_normalized_json() {
    local result
    result=$( ( source "$SCRIPT_UNDER_TEST" && provider_get_issue "42" ) 2>/dev/null ) || true
    echo "$result" | jq -e '.id == 42' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.title == "Fix bug"' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.body == "Description here"' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.labels[0] == "bug"' >/dev/null 2>&1 || return 1
}

test_get_issue_empty_id_returns_1() {
    local rc=0
    ( source "$SCRIPT_UNDER_TEST" && provider_get_issue "" >/dev/null 2>&1 ) || rc=$?
    [[ "$rc" -ne 0 ]]
}

test_get_issue_body_uses_jq_flag() {
    local out
    out=$( ( source "$SCRIPT_UNDER_TEST" && provider_get_issue_body "42" ) 2>/dev/null ) || true
    grep -q -- "--jq" "$GH_CALLS" || return 1
    [[ "$out" == *"Plain body text"* ]] || return 1
}

test_add_label_calls_gh_edit() {
    ( source "$SCRIPT_UNDER_TEST" && provider_add_label "42" "bug" >/dev/null 2>&1 ) || true
    grep -q "issue edit 42" "$GH_CALLS" || return 1
    grep -q -- "--add-label bug" "$GH_CALLS" || return 1
}

test_remove_label_calls_gh_edit() {
    ( source "$SCRIPT_UNDER_TEST" && provider_remove_label "42" "stale" >/dev/null 2>&1 ) || true
    grep -q "issue edit 42" "$GH_CALLS" || return 1
    grep -q -- "--remove-label stale" "$GH_CALLS" || return 1
}

test_add_label_missing_args_returns_1() {
    local rc=0
    ( source "$SCRIPT_UNDER_TEST" && provider_add_label "" "bug" >/dev/null 2>&1 ) || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    rc=0
    ( source "$SCRIPT_UNDER_TEST" && provider_add_label "42" "" >/dev/null 2>&1 ) || rc=$?
    [[ "$rc" -ne 0 ]]
}

test_comment_calls_gh_comment() {
    ( source "$SCRIPT_UNDER_TEST" && provider_comment "42" "Looking good" >/dev/null 2>&1 ) || true
    grep -q "issue comment 42" "$GH_CALLS" || return 1
    grep -q -- "--body Looking good" "$GH_CALLS"
}

test_comment_missing_args_returns_1() {
    local rc=0
    ( source "$SCRIPT_UNDER_TEST" && provider_comment "" "x" >/dev/null 2>&1 ) || rc=$?
    [[ "$rc" -ne 0 ]] || return 1
    rc=0
    ( source "$SCRIPT_UNDER_TEST" && provider_comment "42" "" >/dev/null 2>&1 ) || rc=$?
    [[ "$rc" -ne 0 ]]
}

test_close_issue_calls_gh_close() {
    ( source "$SCRIPT_UNDER_TEST" && provider_close_issue "42" >/dev/null 2>&1 ) || true
    grep -q "issue close 42" "$GH_CALLS"
}

test_close_missing_id_returns_1() {
    local rc=0
    ( source "$SCRIPT_UNDER_TEST" && provider_close_issue "" >/dev/null 2>&1 ) || rc=$?
    [[ "$rc" -ne 0 ]]
}

test_create_issue_calls_gh_create() {
    ( source "$SCRIPT_UNDER_TEST" && provider_create_issue "Title" "Body" "a,b" >/dev/null 2>&1 ) || true
    grep -q "issue create" "$GH_CALLS" || return 1
    grep -q -- "--title Title" "$GH_CALLS" || return 1
    grep -q -- "--body Body" "$GH_CALLS" || return 1
    grep -q -- "--label a" "$GH_CALLS" || return 1
    grep -q -- "--label b" "$GH_CALLS" || return 1
}

test_create_issue_returns_json_with_id() {
    local out
    out=$( ( source "$SCRIPT_UNDER_TEST" && provider_create_issue "Title" "Body" "" ) 2>/dev/null ) || true
    echo "$out" | jq -e '.id == 99' >/dev/null 2>&1 || return 1
    echo "$out" | jq -e '.title == "Title"' >/dev/null 2>&1
}

test_create_issue_missing_title_returns_1() {
    local rc=0
    ( source "$SCRIPT_UNDER_TEST" && provider_create_issue "" "body" "" >/dev/null 2>&1 ) || rc=$?
    [[ "$rc" -ne 0 ]]
}

test_no_github_blocks_all_calls() {
    : > "$GH_CALLS"
    (
        export NO_GITHUB=1
        source "$SCRIPT_UNDER_TEST"
        provider_discover_issues "" "open" 5 >/dev/null 2>&1 || true
        provider_get_issue "42" >/dev/null 2>&1 || true
        provider_add_label "42" "x" >/dev/null 2>&1 || true
        provider_remove_label "42" "x" >/dev/null 2>&1 || true
        provider_comment "42" "x" >/dev/null 2>&1 || true
        provider_close_issue "42" >/dev/null 2>&1 || true
        provider_create_issue "t" "b" "" >/dev/null 2>&1 || true
        provider_get_issue_body "42" >/dev/null 2>&1 || true
    )
    # Mock gh should never have been called
    [[ ! -s "$GH_CALLS" ]]
}

test_notify_logs_event() {
    rm -f "$HOME/.shipwright/events.jsonl"
    ( source "$SCRIPT_UNDER_TEST" && provider_notify "test_event" "42" "extra" )
    [[ -f "$HOME/.shipwright/events.jsonl" ]] || return 1
    grep -q "tracker.notify" "$HOME/.shipwright/events.jsonl" || return 1
    grep -q '"provider":"github"' "$HOME/.shipwright/events.jsonl" || return 1
    grep -q '"issue":42\|"issue":"42"' "$HOME/.shipwright/events.jsonl"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    echo -e "${CYAN}━━━ sw-tracker-github tests ━━━${RESET}"
    setup_env

    run_test "sources cleanly without errors"          test_sources_cleanly
    run_test "exports all provider_* functions"        test_exports_all_provider_functions
    run_test "discover calls gh issue list"            test_discover_calls_gh_issue_list
    run_test "discover omits label when empty"         test_discover_omits_label_when_empty
    run_test "discover returns normalized JSON"        test_discover_returns_normalized_json
    run_test "get_issue calls gh issue view"           test_get_issue_calls_gh_view
    run_test "get_issue returns normalized JSON"       test_get_issue_returns_normalized_json
    run_test "get_issue empty id returns 1"            test_get_issue_empty_id_returns_1
    run_test "get_issue_body uses --jq flag"           test_get_issue_body_uses_jq_flag
    run_test "add_label calls gh edit --add-label"     test_add_label_calls_gh_edit
    run_test "remove_label calls gh edit --remove..."  test_remove_label_calls_gh_edit
    run_test "add_label missing args returns 1"        test_add_label_missing_args_returns_1
    run_test "comment calls gh issue comment"          test_comment_calls_gh_comment
    run_test "comment missing args returns 1"          test_comment_missing_args_returns_1
    run_test "close_issue calls gh issue close"        test_close_issue_calls_gh_close
    run_test "close_issue empty id returns 1"          test_close_missing_id_returns_1
    run_test "create_issue calls gh with all flags"    test_create_issue_calls_gh_create
    run_test "create_issue returns {id,title} JSON"    test_create_issue_returns_json_with_id
    run_test "create_issue missing title returns 1"    test_create_issue_missing_title_returns_1
    run_test "NO_GITHUB=1 blocks every call"           test_no_github_blocks_all_calls
    run_test "provider_notify emits event to jsonl"    test_notify_logs_event

    echo
    echo -e "${CYAN}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}PASS${RESET}: $PASS / $TOTAL"
    if [[ $FAIL -gt 0 ]]; then
        echo -e "  ${RED}FAIL${RESET}: $FAIL"
        for f in "${FAILURES[@]}"; do echo -e "    ${RED}✗${RESET} $f"; done
        exit 1
    fi
    exit 0
}

main "$@"
