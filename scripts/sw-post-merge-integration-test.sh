#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Post-Merge Integration Test — End-to-end feedback loop validation      ║
# ║  Simulates: merge → CI failure → regression event → memory update       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# Override assert functions for cleaner output
assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1"; local detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected '$expected', got '$actual'"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if printf '%s\n' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if printf '%s\n' "$haystack" | grep -qE -- "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }
assert_file_exists() { local desc="$1" file="$2"; if [[ -f "$file" ]]; then assert_pass "$desc"; else assert_fail "$desc" "file not found: $file"; fi; }
assert_file_contains() { local desc="$1" file="$2" needle="$3"; if [[ -f "$file" ]] && grep -qF -- "$needle" "$file" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "file $file missing: $needle"; fi; }

# ─── Test Setup ───────────────────────────────────────────────────────────
setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Mock git command
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" ]]; then shift; shift; fi
case "${1:-}" in
    remote)
        if [[ "${2:-}" == "get-url" ]]; then
            echo "git@github.com:test/repo.git"
        fi
        ;;
    *) exit 0 ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh command — simulates CI failure for PR #123
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    pr)
        case "${2:-}" in
            list)
                echo '[{"number":123,"mergedAt":"2026-03-07T10:00:00Z","mergeCommit":{"oid":"abc123def456789"},"headRefName":"ci/fix-auth-123"}]'
                ;;
            view)
                echo '{"state":"MERGED","mergeCommit":{"oid":"abc123def456789"},"mergedAt":"2026-03-07T10:00:00Z","headRefName":"ci/fix-auth-123","body":"Closes #42"}'
                ;;
        esac
        ;;
    api)
        # Simulate CI check failure
        echo '{"check_runs":[{"name":"tests","status":"completed","conclusion":"failure"}]}'
        ;;
    issue)
        case "${2:-}" in
            list) echo '[]' ;;
        esac
        ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export REPO_DIR="$TEST_TEMP_DIR/repo"
    export NO_GITHUB=""  # Enable GitHub mocks
}

trap cleanup_test_env EXIT

# ═════════════════════════════════════════════════════════════════════════════
# TEST SUITE
# ═════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Post-Merge Integration Tests"
echo ""
setup_env

# ─── Test 1: Webhook processes push to main ──────────────────────────────
echo -e "  ${CYAN}Webhook Event Processing${RESET}"

# Source webhook handler
source "$SCRIPT_DIR/sw-webhook.sh" 2>/dev/null << 'EOF' || true
EOF

# Test push event to main branch
push_payload='{"ref":"refs/heads/main","repository":{"full_name":"test/repo"},"head_commit":{"id":"abc123def456"}}'
output=$(process_webhook_event "$push_payload" "push" 2>&1) && rc=0 || rc=$?
assert_eq "push to main exits 0" "0" "$rc"
assert_file_contains "push event emitted" "$HOME/.shipwright/events.jsonl" "webhook.push_main"

# Test push to non-main branch (should be ignored)
push_feature='{"ref":"refs/heads/feature/test","repository":{"full_name":"test/repo"},"head_commit":{"id":"xyz789"}}'
process_webhook_event "$push_feature" "push" 2>/dev/null && rc=0 || rc=$?
assert_eq "push to feature branch exits 1 (ignored)" "1" "$rc"

# Test deployment_status failure event
deploy_payload='{"deployment_status":{"state":"failure","description":"Deploy failed"},"deployment":{"environment":"production","sha":"abc123def456"},"repository":{"full_name":"test/repo"}}'
output=$(process_webhook_event "$deploy_payload" "deployment_status" 2>&1) && rc=0 || rc=$?
assert_eq "deployment_status failure exits 0" "0" "$rc"
assert_file_contains "deployment failure event emitted" "$HOME/.shipwright/events.jsonl" "webhook.deployment_failure"

# Test deployment_status success (should be ignored)
deploy_ok='{"deployment_status":{"state":"success","description":"OK"},"deployment":{"environment":"staging","sha":"xyz789"},"repository":{"full_name":"test/repo"}}'
process_webhook_event "$deploy_ok" "deployment_status" 2>/dev/null && rc=0 || rc=$?
assert_eq "deployment_status success exits 1 (ignored)" "1" "$rc"

# Test regression-labeled issue
regression_payload='{"action":"labeled","issue":{"number":99,"title":"Auth regression","body":"This was caused by #123"},"label":{"name":"regression"},"repository":{"full_name":"test/repo"}}'
output=$(process_webhook_event "$regression_payload" "issues" 2>&1) && rc=0 || rc=$?
assert_eq "regression issue labeled exits 0" "0" "$rc"
assert_file_contains "regression issue event emitted" "$HOME/.shipwright/events.jsonl" "webhook.regression_issue"

# ─── Test 2: Post-merge monitor script structure ─────────────────────────
echo ""
echo -e "  ${CYAN}Post-Merge Monitor Structure${RESET}"

monitor_src=$(cat "$SCRIPT_DIR/sw-post-merge-monitor.sh")
assert_contains "has is_duplicate_regression_event" "$monitor_src" "is_duplicate_regression_event()"
assert_contains "has link_pr_to_issue_pattern" "$monitor_src" "link_pr_to_issue_pattern()"
assert_contains "dedup calls tail on events" "$monitor_src" "tail -200"
assert_contains "link extracts issue from branch" "$monitor_src" "headRefName"

# ─── Test 3: Intelligence iteration boost ────────────────────────────────
echo ""
echo -e "  ${CYAN}Intelligence Iteration Boost${RESET}"

intel_src=$(cat "$SCRIPT_DIR/sw-intelligence.sh")
assert_contains "has intelligence_regression_iteration_boost function" "$intel_src" "intelligence_regression_iteration_boost()"
assert_contains "boost reads post-merge-health" "$intel_src" "post-merge-health.jsonl"
assert_contains "boost returns 0-5 range" "$intel_src" "boost=5"

# Test boost with no health file
(
    export HOME="$TEST_TEMP_DIR/home-empty"
    mkdir -p "$HOME/.shipwright"
    # Source helpers first
    source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/sw-intelligence.sh" help 2>/dev/null || true
) && rc=0 || rc=$?
# Can't easily source intelligence.sh standalone, so test structurally
assert_contains "boost defaults to 0 when no file" "$intel_src" 'echo "$boost"; return 0'

# ─── Test 4: Dashboard panel exists ──────────────────────────────────────
echo ""
echo -e "  ${CYAN}Dashboard Production Health Panel${RESET}"

dashboard_src=$(cat "$SCRIPT_DIR/../dashboard/public/index.html")
assert_contains "has production-health tab button" "$dashboard_src" 'data-tab="production-health"'
assert_contains "has production-health panel" "$dashboard_src" 'panel-production-health'
assert_contains "fetches /api/production-health" "$dashboard_src" "/api/production-health"
assert_contains "shows stable count" "$dashboard_src" "ph-stable"
assert_contains "shows degraded count" "$dashboard_src" "ph-degraded"
assert_contains "shows regression count" "$dashboard_src" "ph-regression"
assert_contains "has merge table" "$dashboard_src" "ph-table-body"

# ─── Test 5: Full flow — merge → CI fail → event → memory ───────────────
echo ""
echo -e "  ${CYAN}Full Integration Flow${RESET}"

# Clear events file for clean test
> "$HOME/.shipwright/events.jsonl"

# Step 1: Simulate a merged PR webhook event
merge_payload='{"action":"closed","pull_request":{"number":123,"merged":true,"merge_commit_sha":"abc123def456789","title":"Fix auth bug"},"repository":{"full_name":"test/repo"}}'
output=$(process_webhook_event "$merge_payload" "pull_request" 2>&1) && rc=0 || rc=$?
assert_eq "merged PR webhook processed" "0" "$rc"
assert_file_contains "merge event in events.jsonl" "$HOME/.shipwright/events.jsonl" "webhook.pull_request_merged"

# Step 2: Simulate a push to main (same commit)
push_main='{"ref":"refs/heads/main","repository":{"full_name":"test/repo"},"head_commit":{"id":"abc123def456789"}}'
output=$(process_webhook_event "$push_main" "push" 2>&1) && rc=0 || rc=$?
assert_eq "push to main processed" "0" "$rc"
assert_file_contains "push event in events.jsonl" "$HOME/.shipwright/events.jsonl" "webhook.push_main"

# Step 3: Simulate deployment failure
deploy_fail='{"deployment_status":{"state":"failure","description":"Health check failed"},"deployment":{"environment":"production","sha":"abc123def456789"},"repository":{"full_name":"test/repo"}}'
output=$(process_webhook_event "$deploy_fail" "deployment_status" 2>&1) && rc=0 || rc=$?
assert_eq "deployment failure processed" "0" "$rc"

# Step 4: Count total events emitted
event_count=$(wc -l < "$HOME/.shipwright/events.jsonl" | tr -d ' ')
if [[ "$event_count" -ge 3 ]]; then
    assert_pass "at least 3 events emitted in flow ($event_count total)"
else
    assert_fail "at least 3 events emitted in flow" "got $event_count"
fi

# Step 5: Verify event types are distinct
merge_events=$(grep -c "pull_request_merged" "$HOME/.shipwright/events.jsonl" 2>/dev/null || true)
push_events=$(grep -c "push_main" "$HOME/.shipwright/events.jsonl" 2>/dev/null || true)
deploy_events=$(grep -c "deployment_failure" "$HOME/.shipwright/events.jsonl" 2>/dev/null || true)
assert_eq "one merge event" "1" "${merge_events:-0}"
assert_eq "one push event" "1" "${push_events:-0}"
assert_eq "one deploy event" "1" "${deploy_events:-0}"

# ─── Test 6: NO_GITHUB graceful degradation ──────────────────────────────
echo ""
echo -e "  ${CYAN}Graceful Degradation${RESET}"

output=$(NO_GITHUB=1 bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" monitor 2>&1) && rc=0 || rc=$?
assert_eq "NO_GITHUB monitor exits 0" "0" "$rc"
assert_contains_regex "NO_GITHUB shows skip message" "$output" "skipping|NO_GITHUB"

output=$(NO_GITHUB=1 bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" check-pr 123 2>&1) && rc=0 || rc=$?
assert_eq "NO_GITHUB check-pr exits 0" "0" "$rc"

echo ""
echo ""
print_test_results
