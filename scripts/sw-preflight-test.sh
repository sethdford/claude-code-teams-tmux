#!/usr/bin/env bash
# Unit tests for scripts/lib/pipeline-preflight.sh
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "pipeline-preflight tests"

setup_test_env "sw-preflight-test"
trap cleanup_test_env EXIT

info()       { :; }
success()    { :; }
warn()       { :; }
error()      { :; }
emit_event() { :; }

export NO_GITHUB=true
export HOME="$TEST_TEMP_DIR/home"
mkdir -p "$HOME/.shipwright/memory" "$HOME/.shipwright/heartbeats"
export PREFLIGHT_MEMORY_FILE="$HOME/.shipwright/memory/preflight-rejections.jsonl"

mkdir -p "$TEST_TEMP_DIR/repo"
cd "$TEST_TEMP_DIR/repo"
git init -q .
git config user.email "test@example.com"
git config user.name  "Test"
git commit --allow-empty -q -m "init"

_PIPELINE_PREFLIGHT_LOADED=""
# shellcheck source=lib/pipeline-preflight.sh
source "$SCRIPT_DIR/lib/pipeline-preflight.sh"

# ─── Individual checks ─────────────────────────────────────────────────
print_test_section "individual checks"

result=$(_pf_check_git_state)
assert_contains "Clean tree => ok" "$result" "ok	git_state"

echo "x" > dirty.txt
result=$(_pf_check_git_state)
assert_contains "1 dirty file => warn" "$result" "warn	git_state"
rm dirty.txt

for i in $(seq 1 51); do echo x > "f${i}.txt"; done
result=$(_pf_check_git_state)
assert_contains "51 dirty files => block" "$result" "block	git_state"
rm -f f*.txt

result=$(_pf_check_issue_clarity "" "")
assert_contains "Empty issue/goal => warn" "$result" "warn	issue_clarity"

result=$(_pf_check_issue_clarity "" "x")
assert_contains "Tiny goal => block" "$result" "block	issue_clarity"

long_goal="Add JWT authentication to the API server with refresh tokens, rate limiting on the login endpoint, and integration with the existing session middleware"
result=$(_pf_check_issue_clarity "" "$long_goal")
assert_contains "Long goal => ok" "$result" "ok	issue_clarity"

result=$(_pf_check_dependencies)
assert_contains "git+jq present => ok" "$result" "ok	dependencies"

echo "not json {" > package.json
result=$(_pf_check_dependencies)
assert_contains "Invalid package.json => block" "$result" "block	dependencies"
rm package.json

echo '{"scripts":{"test":"npm run vitest"}}' > package.json
result=$(_pf_check_test_command)
assert_contains "Valid test script => ok" "$result" "ok	test_command"

# jq validates the JSON file itself; we trust npm to parse the test script.
# Per audit feedback, we no longer hand-roll a quote-counting heuristic.
echo '{"scripts":{"test":"echo \"unbalanced"}}' > package.json
result=$(_pf_check_test_command)
assert_contains "Valid JSON => ok (no hand-rolled quote heuristic)" "$result" "ok	test_command"
rm package.json

result=$(_pf_check_test_command)
assert_contains "No package.json => warn" "$result" "warn	test_command"

result=$(_pf_check_no_conflicts "")
assert_contains "Empty issue => ok" "$result" "ok	no_conflicts"

result=$(_pf_check_no_conflicts "42")
assert_contains "No heartbeats => ok" "$result" "ok	no_conflicts"

echo '{"issue":"42","pid":"999999"}' > "$HOME/.shipwright/heartbeats/old.json"
result=$(_pf_check_no_conflicts "42")
assert_contains "Stale heartbeat ignored" "$result" "ok	no_conflicts"

echo "{\"issue\":\"42\",\"pid\":\"$$\"}" > "$HOME/.shipwright/heartbeats/live.json"
result=$(_pf_check_no_conflicts "42")
assert_contains "Live heartbeat => block" "$result" "block	no_conflicts"
rm -f "$HOME/.shipwright/heartbeats/"*.json

# ─── Aggregator ────────────────────────────────────────────────────────
print_test_section "aggregator"

artifacts="$TEST_TEMP_DIR/artifacts"
mkdir -p "$artifacts"

echo '{"scripts":{"test":"vitest"}}' > package.json
git add package.json && git commit -q -m "add package.json"
goal="Add OAuth2 device flow to login endpoint, with refresh tokens, scope checks, and CSRF protection on the callback URL"
if preflight_validate "" "$goal" "$artifacts"; then
    assert_pass "PASS path exits 0"
else
    assert_fail "Expected PASS but got non-zero exit"
fi
verdict=$(jq -r '.verdict' "$artifacts/preflight.json")
assert_eq "Verdict is PASS" "$verdict" "PASS"
if [[ -f "$artifacts/preflight-report.md" ]]; then
    assert_pass "Markdown report written"
else
    assert_fail "No markdown report"
fi

if preflight_validate "" "fix" "$artifacts" 2>/dev/null; then
    assert_fail "Expected BLOCK exit 1"
else
    assert_pass "BLOCK returns non-zero"
fi
verdict=$(jq -r '.verdict' "$artifacts/preflight.json")
assert_eq "Vague goal verdict=BLOCK" "$verdict" "BLOCK"

if [[ -s "$PREFLIGHT_MEMORY_FILE" ]]; then
    assert_pass "Rejection appended to memory"
else
    assert_fail "Rejection not logged"
fi

if SW_PREFLIGHT_FORCE=true preflight_validate "" "fix" "$artifacts"; then
    assert_pass "Forced run exits 0"
else
    assert_fail "Forced run should exit 0"
fi
verdict=$(jq -r '.verdict' "$artifacts/preflight.json")
assert_eq "Forced verdict=WARN" "$verdict" "WARN"
forced=$(jq -r '.forced' "$artifacts/preflight.json")
assert_eq "Forced flag=true" "$forced" "true"

if SW_PREFLIGHT_ENABLED=false preflight_validate "" "fix" "$artifacts"; then
    assert_pass "Disabled validator exits 0"
else
    assert_fail "Disabled validator should exit 0"
fi

rm -f "$PREFLIGHT_MEMORY_FILE"
preflight_log_rejection "99" "BLOCK" '[{"name":"x","status":"block","message":"m","fix":"f"}]'
line_count=$(wc -l < "$PREFLIGHT_MEMORY_FILE" | tr -d ' ')
assert_eq "One rejection line logged" "$line_count" "1"
if jq -e '.issue == "99" and .verdict == "BLOCK"' "$PREFLIGHT_MEMORY_FILE" >/dev/null; then
    assert_pass "Rejection JSON well-formed"
else
    assert_fail "Rejection JSON malformed"
fi

rm -f package.json

print_test_results
