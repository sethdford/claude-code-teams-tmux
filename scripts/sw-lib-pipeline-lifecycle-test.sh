#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-lifecycle test — Unit tests for lifecycle fns   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-lifecycle Tests"

setup_test_env "sw-lib-pipeline-lifecycle-test"
trap cleanup_test_env EXIT

# Set up pipeline env
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export STATE_FILE="$TEST_TEMP_DIR/state.md"
export ISSUE_NUMBER=""
export NO_GITHUB=true
export PIPELINE_CONFIG="$TEST_TEMP_DIR/pipeline.json"
export PIPELINE_NAME="test-pipeline"
export PIPELINE_NAME_ARG=""
export PIPELINE_EXIT_CODE=1
export GOAL="Test goal"
export MODEL=""
export CLEANUP_WORKTREE=false
export ORIGINAL_REPO_DIR=""
export WORKTREE_NAME=""
export SKIP_GATES=false
export HEADLESS=false
export REPO_DIR="$TEST_TEMP_DIR"

mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$TEST_TEMP_DIR/templates/pipelines"
mock_git

# Create minimal pipeline config
cat > "$PIPELINE_CONFIG" <<'JSON'
{
    "name": "test",
    "description": "Test pipeline",
    "stages": [
        {"id":"intake","enabled":true,"gate":"auto","config":{}},
        {"id":"build","enabled":true,"gate":"auto","config":{}},
        {"id":"test","enabled":true,"gate":"approve","config":{}}
    ],
    "defaults": {"model":"sonnet"}
}
JSON

# Create a template for list/show tests
cp "$PIPELINE_CONFIG" "$TEST_TEMP_DIR/templates/pipelines/test.json"

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
info() { echo -e "▸ $*"; }
success() { echo -e "✓ $*"; }
warn() { echo -e "⚠ $*"; }
error() { echo -e "✗ $*" >&2; }
setup_dirs() { mkdir -p "$ARTIFACTS_DIR"; }
resume_state() { :; }
write_state() { :; }
gh_init() { :; }
gh_remove_label() { :; }
gh_comment_issue() { :; }
gh_checks_stage_update() { :; }
estimate_pipeline_cost() { echo '{"input_tokens":10000,"output_tokens":5000}'; }
find_pipeline_config() { echo "$PIPELINE_CONFIG"; }
COST_MODEL_RATES='{"sonnet":{"input":3,"output":15}}'
CYAN="" GREEN="" YELLOW="" RED="" BLUE="" PURPLE="" BOLD="" DIM="" RESET=""

# Source the library under test
source "$SCRIPT_DIR/lib/pipeline-lifecycle.sh"

# ──────────────────────────────────────────────────────────────────────────────
# 1. pipeline_status: renders state file
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_status_renders() {
    cat > "$STATE_FILE" <<'STATE'
---
pipeline: test
goal: "Build auth"
status: running
current_stage: build
started_at: 2024-01-01T00:00:00Z
issue: "42"
stages:
  intake: complete
  build: running
  test: pending
---
STATE
    local output
    output=$(pipeline_status 2>&1)
    echo "$output" | grep -q "Build auth" || { echo "Missing goal in status output"; return 1; }
    echo "$output" | grep -q "running" || { echo "Missing status in output"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. pipeline_status: no state file
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_status_empty() {
    rm -f "$STATE_FILE"
    local output
    output=$(pipeline_status 2>&1)
    echo "$output" | grep -q "No active pipeline" || { echo "Should show no active pipeline"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. pipeline_abort: updates state to aborted
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_abort() {
    PIPELINE_STATUS=""
    CURRENT_STAGE=""
    cat > "$STATE_FILE" <<'STATE'
---
pipeline: test
goal: "Test"
status: running
current_stage: build
---
STATE
    pipeline_abort 2>&1 >/dev/null
    [[ "$PIPELINE_STATUS" == "aborted" ]] || { echo "Expected aborted status, got '$PIPELINE_STATUS'"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. pipeline_abort: no-op if already complete
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_abort_complete() {
    cat > "$STATE_FILE" <<'STATE'
---
pipeline: test
goal: "Test"
status: complete
---
STATE
    local output
    output=$(pipeline_abort 2>&1)
    echo "$output" | grep -q "already complete" || { echo "Should indicate already complete"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. pipeline_post_completion_cleanup: removes artifacts
# ──────────────────────────────────────────────────────────────────────────────
test_post_cleanup_removes_artifacts() {
    mkdir -p "$ARTIFACTS_DIR/checkpoints"
    echo '{}' > "$ARTIFACTS_DIR/checkpoints/build-checkpoint.json"
    echo '{}' > "$ARTIFACTS_DIR/classified-findings.json"
    cat > "$STATE_FILE" <<'STATE'
---
status: complete
---
STATE
    pipeline_post_completion_cleanup 2>&1 >/dev/null
    [[ ! -f "$ARTIFACTS_DIR/checkpoints/build-checkpoint.json" ]] || { echo "Checkpoint not cleaned"; return 1; }
    [[ ! -f "$ARTIFACTS_DIR/classified-findings.json" ]] || { echo "Intel artifact not cleaned"; return 1; }
    # State should be reset to idle
    grep -q "status: idle" "$STATE_FILE" || { echo "State not reset to idle"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. pipeline_list: lists templates
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_list() {
    local output
    output=$(pipeline_list 2>&1)
    echo "$output" | grep -q "test" || { echo "Should list test template"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. run_dry_run: validates config
# ──────────────────────────────────────────────────────────────────────────────
test_dry_run_validates() {
    local output
    output=$(run_dry_run 2>&1)
    echo "$output" | grep -q "Pipeline" || { echo "Should show pipeline info"; return 1; }
    echo "$output" | grep -q "validation passed" || { echo "Should pass validation"; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. run_dry_run: fails with missing config
# ──────────────────────────────────────────────────────────────────────────────
test_dry_run_missing_config() {
    local orig_config="$PIPELINE_CONFIG"
    PIPELINE_CONFIG="/nonexistent.json"
    run_dry_run 2>&1 >/dev/null && { PIPELINE_CONFIG="$orig_config"; echo "Should fail with missing config"; return 1; }
    PIPELINE_CONFIG="$orig_config"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. pipeline_cancel_check_runs: no-op when NO_GITHUB
# ──────────────────────────────────────────────────────────────────────────────
test_cancel_check_runs_no_github() {
    NO_GITHUB=true
    pipeline_cancel_check_runs
    # Should not error
}

# ──────────────────────────────────────────────────────────────────────────────
# Run all tests
# ──────────────────────────────────────────────────────────────────────────────
tests=(
    "test_pipeline_status_renders:pipeline_status renders state"
    "test_pipeline_status_empty:pipeline_status shows no active pipeline"
    "test_pipeline_abort:pipeline_abort updates to aborted"
    "test_pipeline_abort_complete:pipeline_abort no-op when complete"
    "test_post_cleanup_removes_artifacts:post_completion_cleanup removes artifacts"
    "test_pipeline_list:pipeline_list shows templates"
    "test_dry_run_validates:run_dry_run validates config"
    "test_dry_run_missing_config:run_dry_run fails with missing config"
    "test_cancel_check_runs_no_github:cancel_check_runs no-op with NO_GITHUB"
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
