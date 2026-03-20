#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-preflight-scope-test.sh — Pre-Flight Scope Validator Test Suite      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_exit_code() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected exit code: $expected"
        echo "    Actual exit code:   $actual"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if echo "$haystack" | grep -q "$needle"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Could not find: $needle"
    fi
}

assert_gt() {
    local actual="$1" threshold="$2" description="${3:-}"
    if [[ "$actual" -gt "$threshold" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    $actual is not > $threshold"
    fi
}

# ─── Setup ─────────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create mock artifacts dir
ARTIFACTS_DIR="$TMPDIR_TEST/artifacts"
mkdir -p "$ARTIFACTS_DIR"
STATE_DIR="$TMPDIR_TEST"
STATE_FILE="$TMPDIR_TEST/pipeline-state.md"
EVENTS_FILE="$TMPDIR_TEST/events.jsonl"
NO_GITHUB=true
export ARTIFACTS_DIR STATE_DIR STATE_FILE EVENTS_FILE NO_GITHUB

# Mock config functions with default limits
_config_get() {
    local key="$1" fallback="${2:-}"
    case "$key" in
        preflight_scope.enabled) echo "${_TEST_ENABLED:-true}" ;;
        *) echo "$fallback" ;;
    esac
}
_config_get_int() {
    local key="$1" fallback="${2:-0}"
    case "$key" in
        preflight_scope.max_files_changed)    echo "${_TEST_MAX_FILES:-15}" ;;
        preflight_scope.max_complexity_score)  echo "${_TEST_MAX_COMPLEXITY:-8}" ;;
        preflight_scope.max_body_lines)        echo "${_TEST_MAX_BODY_LINES:-500}" ;;
        *) echo "$fallback" ;;
    esac
}
_config_get_bool() {
    local key="$1" fallback="${2:-true}"
    [[ "${fallback}" == "true" ]]
}
export -f _config_get _config_get_int _config_get_bool

# Helpers stubs
info()    { echo "$*"; }
warn()    { echo "$*"; }
error()   { echo "$*" >&2; }
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
emit_event() {
    local type="$1"; shift
    echo "{\"type\":\"$type\"}" >> "$EVENTS_FILE"
}
export -f info warn error now_iso emit_event

# Source the module under test (reset guard)
unset _MODULE_PREFLIGHT_SCOPE_LOADED
source "$SCRIPT_DIR/lib/preflight-scope.sh"

# ─── Tests: File Count Estimation ──────────────────────────────────────────
echo "sw-preflight-scope-test.sh"
echo ""
echo "File Count Estimation"

test_file_count_empty_body() {
    local result
    result=$(preflight_estimate_file_count "")
    assert_equals "0" "$result" "empty body returns 0 files"
}

test_file_count_with_paths() {
    local body="Modify these files:
- src/auth/login.ts
- src/auth/register.ts
- scripts/sw-daemon.sh
- config/policy.json"
    local result
    result=$(preflight_estimate_file_count "$body")
    assert_gt "$result" 2 "body with file paths detects multiple files"
}

test_file_count_explicit_reference() {
    local body="This change will modify 25 files across the codebase."
    local result
    result=$(preflight_estimate_file_count "$body")
    assert_gt "$result" 20 "explicit 'modify 25 files' detected"
}

test_file_count_long_body_fallback() {
    local body=""
    local i
    for i in $(seq 1 350); do
        body="${body}This is line $i of a very long issue body without file paths.
"
    done
    local result
    result=$(preflight_estimate_file_count "$body")
    assert_gt "$result" 5 "long body with no paths falls back to estimated 10"
}

# ─── Tests: Complexity Estimation ──────────────────────────────────────────
echo ""
echo "Complexity Estimation"

test_complexity_empty_body() {
    unset INTELLIGENCE_COMPLEXITY
    local result
    result=$(preflight_estimate_complexity "" "")
    assert_equals "1" "$result" "empty body returns complexity 1"
}

test_complexity_short_body() {
    unset INTELLIGENCE_COMPLEXITY
    local body="Fix a typo in the README"
    local result
    result=$(preflight_estimate_complexity "$body" "")
    assert_equals "2" "$result" "short body returns low complexity"
}

test_complexity_medium_body() {
    unset INTELLIGENCE_COMPLEXITY
    local body=""
    local i
    for i in $(seq 1 150); do
        body="${body}Line $i of a medium-sized issue body.
"
    done
    local result
    result=$(preflight_estimate_complexity "$body" "")
    assert_equals "3" "$result" "150-line body returns complexity 3"
}

test_complexity_with_keywords() {
    unset INTELLIGENCE_COMPLEXITY
    local body="We need a major rewrite of the auth module.
This is a breaking change that requires migration.
The refactor across all services is necessary."
    local result
    result=$(preflight_estimate_complexity "$body" "")
    assert_gt "$result" 4 "body with complexity keywords gets boosted"
}

test_complexity_intelligence_override() {
    INTELLIGENCE_COMPLEXITY=6
    local result
    result=$(preflight_estimate_complexity "short body" "")
    assert_equals "6" "$result" "INTELLIGENCE_COMPLEXITY overrides heuristic"
    unset INTELLIGENCE_COMPLEXITY
}

test_complexity_label_boost() {
    unset INTELLIGENCE_COMPLEXITY
    local body="Some medium issue"
    local result
    result=$(preflight_estimate_complexity "$body" "epic,enhancement")
    assert_gt "$result" 2 "epic label boosts complexity"
}

test_complexity_label_reduction() {
    unset INTELLIGENCE_COMPLEXITY
    local body="Fix docs"
    local result
    result=$(preflight_estimate_complexity "$body" "docs,typo")
    assert_equals "1" "$result" "docs/typo labels reduce complexity (clamped to 1)"
}

# ─── Tests: Scope Validation ──────────────────────────────────────────────
echo ""
echo "Scope Validation"

test_validate_passes_normal_issue() {
    _TEST_MAX_FILES=15
    _TEST_MAX_COMPLEXITY=8
    _TEST_MAX_BODY_LINES=500
    _TEST_ENABLED=true
    unset INTELLIGENCE_COMPLEXITY
    local body="Fix a bug in src/auth.ts by updating the token refresh logic."
    local rc=0
    preflight_scope_validate "42" "$body" "bug" || rc=$?
    assert_exit_code 0 "$rc" "normal issue passes scope validation"
}

test_validate_rejects_too_many_files() {
    _TEST_MAX_FILES=3
    _TEST_MAX_COMPLEXITY=10
    _TEST_MAX_BODY_LINES=5000
    _TEST_ENABLED=true
    unset INTELLIGENCE_COMPLEXITY
    local body="Modify these files:
- src/a.ts
- src/b.ts
- src/c.ts
- src/d.ts
- src/e.ts"
    local rc=0
    preflight_scope_validate "42" "$body" "" 2>/dev/null || rc=$?
    assert_exit_code 1 "$rc" "issue with too many files is rejected"
}

test_validate_rejects_high_complexity() {
    _TEST_MAX_FILES=100
    _TEST_MAX_COMPLEXITY=3
    _TEST_MAX_BODY_LINES=5000
    _TEST_ENABLED=true
    INTELLIGENCE_COMPLEXITY=9
    local body="Complex issue"
    local rc=0
    preflight_scope_validate "42" "$body" "" 2>/dev/null || rc=$?
    assert_exit_code 1 "$rc" "high complexity issue is rejected"
    unset INTELLIGENCE_COMPLEXITY
}

test_validate_rejects_too_long_body() {
    _TEST_MAX_FILES=100
    _TEST_MAX_COMPLEXITY=10
    _TEST_MAX_BODY_LINES=10
    _TEST_ENABLED=true
    unset INTELLIGENCE_COMPLEXITY
    local body=""
    local i
    for i in $(seq 1 20); do
        body="${body}Line $i of long body.
"
    done
    local rc=0
    preflight_scope_validate "42" "$body" "" 2>/dev/null || rc=$?
    assert_exit_code 1 "$rc" "body exceeding line limit is rejected"
}

test_validate_disabled_passes_everything() {
    _TEST_ENABLED=false
    INTELLIGENCE_COMPLEXITY=10
    local body=""
    local i
    for i in $(seq 1 1000); do
        body="${body}Line $i
"
    done
    local rc=0
    preflight_scope_validate "42" "$body" "epic" || rc=$?
    assert_exit_code 0 "$rc" "disabled scope check passes everything"
    unset INTELLIGENCE_COMPLEXITY
    _TEST_ENABLED=true
}

test_validate_zero_limit_disables_check() {
    _TEST_MAX_FILES=0
    _TEST_MAX_COMPLEXITY=0
    _TEST_MAX_BODY_LINES=0
    _TEST_ENABLED=true
    INTELLIGENCE_COMPLEXITY=10
    local body="Modify across 100 files. Rewrite everything.
src/a.ts src/b.ts src/c.ts src/d.ts src/e.ts"
    local rc=0
    preflight_scope_validate "42" "$body" "epic" || rc=$?
    assert_exit_code 0 "$rc" "all limits set to 0 disables all checks"
    unset INTELLIGENCE_COMPLEXITY
}

test_validate_empty_body_passes() {
    _TEST_MAX_FILES=15
    _TEST_MAX_COMPLEXITY=8
    _TEST_MAX_BODY_LINES=500
    _TEST_ENABLED=true
    local rc=0
    preflight_scope_validate "42" "" "" || rc=$?
    assert_exit_code 0 "$rc" "empty body passes validation"
}

# ─── Tests: Rejection Artifacts ───────────────────────────────────────────
echo ""
echo "Rejection Artifacts"

test_rejection_writes_json_artifact() {
    _TEST_MAX_FILES=1
    _TEST_MAX_COMPLEXITY=10
    _TEST_MAX_BODY_LINES=5000
    _TEST_ENABLED=true
    unset INTELLIGENCE_COMPLEXITY
    rm -f "${ARTIFACTS_DIR}/preflight-rejection.json"
    local body="Update src/a.ts and src/b.ts and src/c.ts"
    preflight_scope_validate "99" "$body" "" 2>/dev/null || true
    if [[ -f "${ARTIFACTS_DIR}/preflight-rejection.json" ]]; then
        local result
        result=$(jq -r '.result' "${ARTIFACTS_DIR}/preflight-rejection.json" 2>/dev/null) || result=""
        assert_equals "rejected" "$result" "rejection JSON artifact has result=rejected"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m rejection JSON artifact was not written"
    fi
}

test_rejection_json_has_issue_number() {
    if [[ -f "${ARTIFACTS_DIR}/preflight-rejection.json" ]]; then
        local issue
        issue=$(jq -r '.issue' "${ARTIFACTS_DIR}/preflight-rejection.json" 2>/dev/null) || issue=""
        assert_equals "99" "$issue" "rejection JSON contains correct issue number"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m no rejection JSON to check issue number"
    fi
}

test_rejection_emits_event() {
    > "$EVENTS_FILE"
    _TEST_MAX_FILES=1
    _TEST_MAX_COMPLEXITY=10
    _TEST_MAX_BODY_LINES=5000
    _TEST_ENABLED=true
    unset INTELLIGENCE_COMPLEXITY
    local body="Update src/a.ts and src/b.ts and src/c.ts"
    preflight_scope_validate "50" "$body" "" 2>/dev/null || true
    local event_count=0
    event_count=$(grep -c "preflight_scope_rejected" "$EVENTS_FILE" 2>/dev/null) || event_count=0
    assert_gt "$event_count" 0 "rejection emits preflight_scope_rejected event"
}

test_pass_emits_event() {
    > "$EVENTS_FILE"
    _TEST_MAX_FILES=100
    _TEST_MAX_COMPLEXITY=10
    _TEST_MAX_BODY_LINES=5000
    _TEST_ENABLED=true
    unset INTELLIGENCE_COMPLEXITY
    local body="Small fix"
    preflight_scope_validate "51" "$body" "" 2>/dev/null || true
    local event_count=0
    event_count=$(grep -c "preflight_scope_passed" "$EVENTS_FILE" 2>/dev/null) || event_count=0
    assert_gt "$event_count" 0 "pass emits preflight_scope_passed event"
}

# ─── Tests: Multiple Violations ──────────────────────────────────────────
echo ""
echo "Multiple Violations"

test_multiple_violations_all_reported() {
    _TEST_MAX_FILES=1
    _TEST_MAX_COMPLEXITY=1
    _TEST_MAX_BODY_LINES=5
    _TEST_ENABLED=true
    INTELLIGENCE_COMPLEXITY=9
    rm -f "${ARTIFACTS_DIR}/preflight-rejection.json"
    local body="Update src/a.ts and src/b.ts and src/c.ts
Line 2
Line 3
Line 4
Line 5
Line 6
Line 7"
    preflight_scope_validate "77" "$body" "" 2>/dev/null || true
    if [[ -f "${ARTIFACTS_DIR}/preflight-rejection.json" ]]; then
        local violations
        violations=$(jq -r '.violations' "${ARTIFACTS_DIR}/preflight-rejection.json" 2>/dev/null) || violations=""
        local has_files=0 has_complexity=0 has_body=0
        echo "$violations" | grep -q "files_changed" && has_files=1
        echo "$violations" | grep -q "complexity_score" && has_complexity=1
        echo "$violations" | grep -q "body_lines" && has_body=1
        local total=$((has_files + has_complexity + has_body))
        assert_equals "3" "$total" "all 3 violation types reported in rejection"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m no rejection JSON for multiple violations test"
    fi
    unset INTELLIGENCE_COMPLEXITY
}

# ─── Main ─────────────────────────────────────────────────────────────────
test_file_count_empty_body
test_file_count_with_paths
test_file_count_explicit_reference
test_file_count_long_body_fallback

test_complexity_empty_body
test_complexity_short_body
test_complexity_medium_body
test_complexity_with_keywords
test_complexity_intelligence_override
test_complexity_label_boost
test_complexity_label_reduction

test_validate_passes_normal_issue
test_validate_rejects_too_many_files
test_validate_rejects_high_complexity
test_validate_rejects_too_long_body
test_validate_disabled_passes_everything
test_validate_zero_limit_disables_check
test_validate_empty_body_passes

test_rejection_writes_json_artifact
test_rejection_json_has_issue_number
test_rejection_emits_event
test_pass_emits_event

test_multiple_violations_all_reported

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
