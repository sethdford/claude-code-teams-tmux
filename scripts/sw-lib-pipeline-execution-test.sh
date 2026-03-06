#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-execution test — Unit tests for execution logic ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-execution Tests"

setup_test_env "sw-lib-pipeline-execution-test"
trap cleanup_test_env EXIT

# Set up pipeline env
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export STATE_FILE="$TEST_TEMP_DIR/state.md"
export ISSUE_NUMBER=""
export NO_GITHUB=true
export PIPELINE_CONFIG="$TEST_TEMP_DIR/pipeline.json"
export BUILD_TEST_RETRIES=2
export SELF_HEAL_COUNT=0
export BASE_BRANCH="main"
export GOAL="Test goal"
export CURRENT_STAGE_ID=""
export LAST_STAGE_ERROR_CLASS=""
export LAST_STAGE_ERROR=""
export SHIPWRIGHT_PIPELINE_ID="test-$$"
export INTELLIGENCE_ANALYSIS="{}"
export INTELLIGENCE_ISSUE_TYPE="backend"

mkdir -p "$ARTIFACTS_DIR"
mock_git

# Create minimal pipeline config
cat > "$PIPELINE_CONFIG" <<'JSON'
{
    "name": "test",
    "stages": [
        {"id":"intake","enabled":true,"gate":"auto","config":{"retries":1}},
        {"id":"build","enabled":true,"gate":"auto","config":{"retries":2}},
        {"id":"test","enabled":true,"gate":"auto","config":{"retries":0}}
    ],
    "defaults": {"model":"sonnet"}
}
JSON

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
info() { echo -e "▸ $*"; }
success() { echo -e "✓ $*"; }
warn() { echo -e "⚠ $*"; }
error() { echo -e "✗ $*" >&2; }
classify_error() { echo "${MOCK_ERROR_CLASS:-unknown}"; }
set_stage_status() { :; }
mark_stage_complete() { :; }
mark_stage_failed() { :; }
update_status() { :; }
record_stage_start() { :; }
get_stage_timing() { echo "1s"; }
write_state() { :; }
gh_comment_issue() { :; }
notify() { :; }
pipeline_adaptive_cycles() { echo "$1"; }

# Source the library under test
source "$SCRIPT_DIR/lib/pipeline-execution.sh"

# ──────────────────────────────────────────────────────────────────────────────
# 1. run_stage_with_retry: success on first attempt
# ──────────────────────────────────────────────────────────────────────────────
test_retry_success() {
    stage_intake() { return 0; }
    run_stage_with_retry "intake" || { echo "Should succeed"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. run_stage_with_retry: exhausts retries
# ──────────────────────────────────────────────────────────────────────────────
test_retry_exhausted() {
    stage_test() { return 1; }
    MOCK_ERROR_CLASS="unknown"
    echo "Some error" > "$ARTIFACTS_DIR/test-results.log"
    run_stage_with_retry "test" && { echo "Should fail after exhausting retries"; return 1; }
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. run_stage_with_retry: configuration error escalates immediately
# ──────────────────────────────────────────────────────────────────────────────
test_retry_config_escalation() {
    local attempt_count=0
    stage_build() { attempt_count=$((attempt_count + 1)); return 1; }
    MOCK_ERROR_CLASS="configuration"
    echo "ENOENT: no such file" > "$ARTIFACTS_DIR/build-results.log"
    run_stage_with_retry "build" && { echo "Should fail"; return 1; }
    # With config error, should only try once (fail, then escalate on first retry)
    [[ "$attempt_count" -le 2 ]] || { echo "Expected <=2 attempts, got $attempt_count"; return 1; }
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. run_stage_with_retry: plan stage skip with existing artifact
# ──────────────────────────────────────────────────────────────────────────────
test_retry_plan_artifact_skip() {
    stage_plan() { return 1; }
    MOCK_ERROR_CLASS="logic"
    echo "Some error" > "$ARTIFACTS_DIR/plan-results.log"
    # Create a valid plan artifact (>10 lines)
    for i in $(seq 1 15); do echo "Line $i of plan"; done > "$ARTIFACTS_DIR/plan.md"
    run_stage_with_retry "plan" || { echo "Should succeed when plan artifact exists"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. auto_rebase: clean rebase
# ──────────────────────────────────────────────────────────────────────────────
test_auto_rebase_up_to_date() {
    # Mock git commands for "already up to date"
    git() {
        case "$1" in
            fetch) return 0 ;;
            rev-list) echo "0" ;;
            *) command git "$@" ;;
        esac
    }
    export -f git
    auto_rebase || { echo "Should succeed when up to date"; return 1; }
    unset -f git
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. self_healing_build_test: passes on first cycle
# ──────────────────────────────────────────────────────────────────────────────
test_self_heal_first_cycle() {
    SELF_HEAL_COUNT=0
    stage_build() { return 0; }
    stage_test() { return 0; }
    self_healing_build_test || { echo "Should pass on first cycle"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. self_healing_build_test: build failure returns 1
# ──────────────────────────────────────────────────────────────────────────────
test_self_heal_build_fail() {
    SELF_HEAL_COUNT=0
    BUILD_TEST_RETRIES=0
    stage_build() { return 1; }
    stage_test() { return 0; }
    MOCK_ERROR_CLASS="logic"
    echo "Build error" > "$ARTIFACTS_DIR/build-results.log"
    self_healing_build_test && { echo "Should fail when build fails"; return 1; }
    BUILD_TEST_RETRIES=2
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Run all tests
# ──────────────────────────────────────────────────────────────────────────────
tests=(
    "test_retry_success:run_stage_with_retry succeeds on first attempt"
    "test_retry_exhausted:run_stage_with_retry exhausts retries"
    "test_retry_config_escalation:run_stage_with_retry escalates config errors"
    "test_retry_plan_artifact_skip:run_stage_with_retry skips retry when plan exists"
    "test_auto_rebase_up_to_date:auto_rebase handles up-to-date"
    "test_self_heal_first_cycle:self_healing passes on first cycle"
    "test_self_heal_build_fail:self_healing fails when build fails"
)

for entry in "${tests[@]}"; do
    fn="${entry%%:*}"
    desc="${entry#*:}"
    if $fn; then
        assert_pass "$desc"
    else
        assert_fail "$desc"
    fi
done

print_test_results
