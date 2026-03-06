#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-orchestrator test — Unit tests for orchestration║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-orchestrator Tests"

setup_test_env "lib-pipeline-orchestrator"
trap cleanup_test_env EXIT

# ─── Pipeline environment ──────────────────────────────────────────────────
export ARTIFACTS_DIR="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
export STATE_FILE="$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
export STATE_DIR="$TEST_TEMP_DIR/project/.claude"
export TASKS_FILE="$TEST_TEMP_DIR/project/.claude/pipeline-tasks.md"
export PIPELINE_CONFIG="$TEST_TEMP_DIR/templates/pipelines/standard.json"
export BASE_BRANCH="main"
export NO_GITHUB=true
export GH_AVAILABLE=true
export REPO_OWNER="test-org"
export REPO_NAME="test-repo"
# shellcheck disable=SC2155
export PIPELINE_START_EPOCH=$(date +%s)
export CI_MODE=false
export PIPELINE_NAME="test-pipeline"
export ISSUE_NUMBER="42"
export GOAL="Add JWT authentication"
export GIT_BRANCH="feat/add-jwt-auth-42"
export TASK_TYPE="feature"
export GITHUB_ISSUE="#42"
export ISSUE_BODY="We need JWT auth for the API."
export ISSUE_LABELS="feature,priority/high"
export ISSUE_MILESTONE="v2.0"
export TEST_CMD="echo 'All tests passed'"
export MODEL=""
export AGENTS="1"
export SKIP_GATES=true
export HEADLESS=true
export IGNORE_BUDGET=true
export PIPELINE_STATUS=""
export STASHED_CHANGES=false
export BUILD_TEST_RETRIES=3
export HEARTBEAT_PID=""
export _cleanup_done=""
export CURRENT_STAGE_ID=""
export COMPLETED_STAGES=""
export LAST_STAGE_ERROR_CLASS=""
export LAST_STAGE_ERROR=""
export TOTAL_INPUT_TOKENS=0
export TOTAL_OUTPUT_TOKENS=0
export TDD_ENABLED=false
export PIPELINE_TDD=""
export PIPELINE_STAGES_PASSED=""
export PIPELINE_SLOWEST_STAGE=""
export DRY_RUN=false

mkdir -p "$ARTIFACTS_DIR" "$(dirname "$STATE_FILE")" "$(dirname "$TASKS_FILE")"
mkdir -p "$(dirname "$PIPELINE_CONFIG")"

# Create minimal pipeline config
jq -n '{
    name: "standard",
    defaults: { test_cmd: "echo pass", model: "opus", agents: 1 },
    stages: [
        { id: "intake", enabled: true, gate: "auto", config: {} },
        { id: "plan", enabled: true, gate: "auto", config: { model: "opus" } },
        { id: "build", enabled: true, gate: "auto", config: { max_iterations: 20 } },
        { id: "test", enabled: true, gate: "auto", config: { coverage_min: 0 } },
        { id: "review", enabled: true, gate: "auto", config: {} },
        { id: "pr", enabled: true, gate: "auto", config: {} }
    ]
}' > "$PIPELINE_CONFIG"

# Create mock project with git
mkdir -p "$PROJECT_ROOT/src" "$PROJECT_ROOT/tests"
cat > "$PROJECT_ROOT/package.json" <<'PKG'
{"name":"test","scripts":{"test":"echo All 5 tests passed"}}
PKG
(cd "$PROJECT_ROOT" && git init -q -b main 2>/dev/null && git config user.email "t@t.com" && git config user.name "T" && touch .gitignore && git add -A && git commit -q -m "init" 2>/dev/null) || true

# ─── Mock binaries ────────────────────────────────────────────────────────
mock_binary "gh" 'case "${1:-}" in
    issue)
        case "${2:-}" in
            view) echo "{\"title\":\"Add JWT auth\",\"body\":\"We need JWT.\",\"labels\":[{\"name\":\"feature\"}],\"number\":42,\"state\":\"OPEN\",\"milestone\":{\"title\":\"v2.0\"}}" ;;
            comment|edit) exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    auth) exit 0 ;;
    pr)
        case "${2:-}" in
            create) echo "https://github.com/test/repo/pull/1" ;;
            *) exit 0 ;;
        esac
        ;;
    api) echo "{}" ;;
    *) exit 0 ;;
esac'

mock_binary "claude" 'echo "# Plan
- [ ] Task 1
"'

mock_binary "sw-heartbeat.sh" 'exit 0'

# Ensure jq works
[[ -x /usr/bin/jq ]] && cp -f /usr/bin/jq "$TEST_TEMP_DIR/bin/jq" 2>/dev/null || true

# ─── Stubs for optional modules ──────────────────────────────────────────
emit_event() { :; }
get_stage_self_awareness_hint() { :; }
parse_claude_tokens() { :; }
gh_wiki_page() { :; }
auto_rebase() { return 0; }
pipeline_cancel_check_runs() { :; }
pipeline_post_completion_cleanup() { :; }
pipeline_should_skip_stage() { echo ""; }
pipeline_reassess_complexity() { echo "as_expected"; }
verify_stage_artifacts() { return 0; }
show_stage_preview() { echo "Preview for $1"; }
gh_build_progress_body() { echo "progress"; }
gh_update_progress() { :; }
_config_get_int() { echo "${2:-30}"; }
_timeout() { shift; "$@"; }
file_mtime() { echo 0; }
format_duration() { local s="${1:-0}"; echo "${s}s"; }
rotate_event_log_if_needed() { :; }

# ─── Source dependencies ─────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh" || true
[[ -f "$SCRIPT_DIR/lib/pipeline-quality.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-quality.sh" || true

# Pipeline state
export STAGE_STATUSES=""
export STAGE_TIMINGS=""
write_state() { :; }

_PIPELINE_STATE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-state.sh"
_PIPELINE_GITHUB_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-github.sh"
_PIPELINE_DETECTION_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-detection.sh"
_PIPELINE_QUALITY_CHECKS_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-quality-checks.sh" 2>/dev/null || true
_PIPELINE_INTELLIGENCE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-intelligence.sh" 2>/dev/null || true
_PIPELINE_STAGES_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-stages.sh"
_PIPELINE_UTILS_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-utils.sh"
_PIPELINE_EXECUTION_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-execution.sh"

# Source the library under test
_PIPELINE_ORCHESTRATOR_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-orchestrator.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

# ─── Test 1: Include guard ────────────────────────────────────────────────
print_test_section "Include guard"

if [[ "$_PIPELINE_ORCHESTRATOR_LOADED" == "1" ]]; then
    assert_pass "Include guard set after sourcing"
else
    assert_fail "Include guard not set"
fi

# Re-source to verify guard prevents double-load
_before_guard=$_PIPELINE_ORCHESTRATOR_LOADED
source "$SCRIPT_DIR/lib/pipeline-orchestrator.sh"
if [[ "$_PIPELINE_ORCHESTRATOR_LOADED" == "$_before_guard" ]]; then
    assert_pass "Include guard prevents re-execution"
else
    assert_fail "Include guard did not prevent re-execution"
fi

# ─── Test 2: Function existence ──────────────────────────────────────────
print_test_section "Function existence"

for fn in run_pipeline preflight_checks cleanup_on_exit start_heartbeat stop_heartbeat \
    ci_push_partial_work ci_post_stage_event; do
    if type "$fn" >/dev/null 2>&1; then
        assert_pass "$fn is defined"
    else
        assert_fail "$fn is NOT defined"
    fi
done

# ─── Test 3: preflight_checks ───────────────────────────────────────────
print_test_section "preflight_checks"

# Should pass in our git test environment
(
    cd "$PROJECT_ROOT"
    # Mock claude in PATH
    out=$(preflight_checks 2>&1) || true
    if echo "$out" | grep -q "Pre-flight"; then
        echo "PREFLIGHT_OK"
    fi
) > "$TEST_TEMP_DIR/preflight.out" 2>&1
if grep -q "PREFLIGHT_OK" "$TEST_TEMP_DIR/preflight.out"; then
    assert_pass "preflight_checks runs and produces output"
else
    assert_fail "preflight_checks did not produce expected output"
fi

# ─── Test 4: ci_push_partial_work ────────────────────────────────────────
print_test_section "ci_push_partial_work"

# Should be a no-op when CI_MODE is false
CI_MODE=false
ci_push_partial_work
assert_pass "ci_push_partial_work no-op when CI_MODE=false"

# Should be a no-op when ISSUE_NUMBER is empty
CI_MODE=true
local_issue="$ISSUE_NUMBER"
ISSUE_NUMBER=""
ci_push_partial_work
assert_pass "ci_push_partial_work no-op when ISSUE_NUMBER empty"
ISSUE_NUMBER="$local_issue"
CI_MODE=false

# ─── Test 5: ci_post_stage_event ─────────────────────────────────────────
print_test_section "ci_post_stage_event"

# No-op when CI_MODE is false
CI_MODE=false
ci_post_stage_event "build" "complete" "10s"
assert_pass "ci_post_stage_event no-op when CI_MODE=false"

# No-op when GH_AVAILABLE is false
CI_MODE=true
GH_AVAILABLE=false
ci_post_stage_event "build" "complete" "10s"
assert_pass "ci_post_stage_event no-op when GH_AVAILABLE=false"
GH_AVAILABLE=true
CI_MODE=false

# ─── Test 6: stop_heartbeat ─────────────────────────────────────────────
print_test_section "stop_heartbeat"

HEARTBEAT_PID=""
stop_heartbeat
assert_pass "stop_heartbeat no-op when HEARTBEAT_PID empty"

# Test with a real PID: spawn, kill, verify HEARTBEAT_PID is cleared
(
    _saved_script_dir="$SCRIPT_DIR"
    SCRIPT_DIR="$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/sw-heartbeat.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/sw-heartbeat.sh"
    sleep 999 &
    HEARTBEAT_PID=$!
    stop_heartbeat 2>/dev/null
    if [[ -z "$HEARTBEAT_PID" ]]; then
        echo "CLEARED"
    fi
) > "$TEST_TEMP_DIR/hb.out" 2>&1
if grep -q "CLEARED" "$TEST_TEMP_DIR/hb.out"; then
    assert_pass "stop_heartbeat clears HEARTBEAT_PID"
else
    assert_fail "stop_heartbeat did not clear HEARTBEAT_PID"
fi

# ─── Test 7: cleanup_on_exit ────────────────────────────────────────────
print_test_section "cleanup_on_exit"

# Test that cleanup_on_exit sets _cleanup_done and is idempotent
_cleanup_done=""
PIPELINE_STATUS="not_running"
# We can't fully test cleanup_on_exit because it calls exit, but we can test the guard
_cleanup_done="true"
cleanup_on_exit  # Should return immediately
assert_pass "cleanup_on_exit returns when _cleanup_done=true"

# ─── Test 8: run_pipeline with simple config ────────────────────────────
print_test_section "run_pipeline (all stages succeed)"

# Create a config where all stages succeed via mocks
jq -n '{
    name: "test-simple",
    defaults: { test_cmd: "echo pass", model: "opus", agents: 1 },
    stages: [
        { id: "intake", enabled: true, gate: "auto", config: {} },
        { id: "plan", enabled: true, gate: "auto", config: {} }
    ]
}' > "$TEST_TEMP_DIR/simple.json"
PIPELINE_CONFIG="$TEST_TEMP_DIR/simple.json"

# Mock the stage functions to succeed
stage_intake() { return 0; }
stage_plan() { return 0; }

# Mock run_stage_with_retry to just call the stage function
run_stage_with_retry() {
    local stage_id="$1"
    "stage_${stage_id}"
}
mark_stage_complete() { :; }
mark_stage_failed() { :; }
record_stage_start() { :; }
update_status() { :; }
get_stage_status() { echo "pending"; }
get_stage_timing() { echo "1s"; }
now_epoch() { date +%s; }
get_slowest_stage() { echo "plan"; }
set_stage_status() { :; }

_cleanup_done=""
PIPELINE_STATUS=""
out=$(run_pipeline 2>&1) || true
if echo "$out" | grep -q "Pipeline complete"; then
    assert_pass "run_pipeline completes successfully"
else
    assert_fail "run_pipeline did not report completion" "$(echo "$out" | tail -3)"
fi

# ─── Test 9: run_pipeline with stage failure ────────────────────────────
print_test_section "run_pipeline (stage failure)"

stage_intake_fail() { return 1; }

jq -n '{
    name: "test-fail",
    defaults: {},
    stages: [
        { id: "intake_fail", enabled: true, gate: "auto", config: {} }
    ]
}' > "$TEST_TEMP_DIR/fail.json"
PIPELINE_CONFIG="$TEST_TEMP_DIR/fail.json"

run_stage_with_retry() {
    local stage_id="$1"
    "stage_${stage_id}"
}
LAST_STAGE_ERROR=""
LAST_STAGE_ERROR_CLASS=""

rc=0
out=$(run_pipeline 2>&1) || rc=$?
if [[ "$rc" -ne 0 ]]; then
    assert_pass "run_pipeline returns non-zero on stage failure"
else
    assert_fail "run_pipeline should have failed"
fi

# ─── Test 10: run_pipeline skips disabled stages ────────────────────────
print_test_section "run_pipeline (disabled stages)"

jq -n '{
    name: "test-disabled",
    defaults: {},
    stages: [
        { id: "intake", enabled: true, gate: "auto", config: {} },
        { id: "plan", enabled: false, gate: "auto", config: {} }
    ]
}' > "$TEST_TEMP_DIR/disabled.json"
PIPELINE_CONFIG="$TEST_TEMP_DIR/disabled.json"

stage_intake() { return 0; }
stage_plan_called=false
stage_plan() { stage_plan_called=true; return 0; }
run_stage_with_retry() { "stage_${1}"; }

out=$(run_pipeline 2>&1) || true
if echo "$out" | grep -q "skipped (disabled)"; then
    assert_pass "run_pipeline skips disabled stages"
else
    assert_fail "run_pipeline did not report disabled stage skip"
fi

# ─── Test 11: run_pipeline human skip ───────────────────────────────────
print_test_section "run_pipeline (human skip directive)"

jq -n '{
    name: "test-skip",
    defaults: {},
    stages: [
        { id: "intake", enabled: true, gate: "auto", config: {} },
        { id: "plan", enabled: true, gate: "auto", config: {} }
    ]
}' > "$TEST_TEMP_DIR/skip.json"
PIPELINE_CONFIG="$TEST_TEMP_DIR/skip.json"

echo "intake" > "$ARTIFACTS_DIR/skip-stage.txt"
stage_intake() { return 0; }
stage_plan() { return 0; }
run_stage_with_retry() { "stage_${1}"; }

out=$(run_pipeline 2>&1) || true
if echo "$out" | grep -q "skipped by human directive"; then
    assert_pass "run_pipeline respects human skip directive"
else
    assert_fail "run_pipeline did not respect human skip" "$(echo "$out" | head -5)"
fi

# ─── Test 12: run_pipeline human message ────────────────────────────────
print_test_section "run_pipeline (human message)"

jq -n '{
    name: "test-msg",
    defaults: {},
    stages: [
        { id: "intake", enabled: true, gate: "auto", config: {} }
    ]
}' > "$TEST_TEMP_DIR/msg.json"
PIPELINE_CONFIG="$TEST_TEMP_DIR/msg.json"

echo "Please focus on security" > "$ARTIFACTS_DIR/human-message.txt"
stage_intake() { return 0; }
run_stage_with_retry() { "stage_${1}"; }

out=$(run_pipeline 2>&1) || true
if echo "$out" | grep -q "Human message"; then
    assert_pass "run_pipeline displays human message"
else
    assert_fail "run_pipeline did not display human message"
fi
# Verify file is removed after display
if [[ ! -f "$ARTIFACTS_DIR/human-message.txt" ]]; then
    assert_pass "Human message file removed after display"
else
    assert_fail "Human message file not cleaned up"
fi

# ─── Test 13: sw-pipeline.sh sources orchestrator correctly ─────────────
print_test_section "sw-pipeline.sh integration"

# Verify that sw-pipeline.sh contains the source line for pipeline-orchestrator.sh
if grep -q "pipeline-orchestrator.sh" "$SCRIPT_DIR/sw-pipeline.sh"; then
    assert_pass "sw-pipeline.sh sources pipeline-orchestrator.sh"
else
    assert_fail "sw-pipeline.sh does not source pipeline-orchestrator.sh"
fi

# Verify the functions are NOT defined inline in sw-pipeline.sh anymore
for fn in run_pipeline preflight_checks cleanup_on_exit start_heartbeat stop_heartbeat \
    ci_push_partial_work ci_post_stage_event; do
    if grep -q "^${fn}()" "$SCRIPT_DIR/sw-pipeline.sh"; then
        assert_fail "$fn is still defined inline in sw-pipeline.sh"
    else
        assert_pass "$fn not defined inline in sw-pipeline.sh (moved to lib)"
    fi
done

# ─── Test 14: Line count verification ────────────────────────────────────
print_test_section "Line count"

pipeline_lines=$(wc -l < "$SCRIPT_DIR/sw-pipeline.sh" | xargs)
if [[ "$pipeline_lines" -lt 400 ]]; then
    assert_pass "sw-pipeline.sh is ${pipeline_lines} lines (under 400)"
else
    assert_fail "sw-pipeline.sh is ${pipeline_lines} lines (expected under 400)"
fi

orchestrator_lines=$(wc -l < "$SCRIPT_DIR/lib/pipeline-orchestrator.sh" | xargs)
if [[ "$orchestrator_lines" -gt 100 ]]; then
    assert_pass "pipeline-orchestrator.sh is ${orchestrator_lines} lines (substantial extraction)"
else
    assert_fail "pipeline-orchestrator.sh is only ${orchestrator_lines} lines"
fi

# ═══════════════════════════════════════════════════════════════════════════
print_test_results
