#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-pipeline-health-test.sh — Pipeline Health Pre-Flight Validation     ║
# ║  Fast canary test: 5 health checks for pipeline core invariants         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.2.4"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Pipeline Health Pre-Flight Checks"

setup_test_env "sw-pipeline-health-test"
trap cleanup_test_env EXIT

# ─── Pipeline environment setup ───────────────────────────────────────────
export ARTIFACTS_DIR="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
export STATE_FILE="$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
export ISSUE_NUMBER=""
export NO_GITHUB=true
export PIPELINE_CONFIG=""
export CI_MODE=false
export PIPELINE_NAME="health-check"
export GOAL="Validate pipeline health"
export GITHUB_ISSUE=""
export GIT_BRANCH=""
export TASK_TYPE=""
export PR_NUMBER=""
export PROGRESS_COMMENT_ID=""
export PIPELINE_START_EPOCH=""
export CURRENT_STAGE=""
export PIPELINE_STATUS=""
export STAGE_STATUSES=""
export STAGE_TIMINGS=""
export LOG_ENTRIES=""

mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$(dirname "$STATE_FILE")"
mock_git

# Provide required stubs for pipeline-state.sh
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
info() { echo -e "▸ $*"; }
success() { echo -e "✓ $*"; }
warn() { echo -e "⚠ $*"; }
error() { echo -e "✗ $*" >&2; }
format_duration() {
    local secs="${1:-0}"
    if [[ "$secs" -ge 3600 ]]; then echo "$((secs/3600))h$((secs%3600/60))m"
    elif [[ "$secs" -ge 60 ]]; then echo "$((secs/60))m$((secs%60))s"
    else echo "${secs}s"; fi
}
check_disk_space() { return 0; }
gh_build_progress_body() { echo "progress"; }
gh_update_progress() { :; }
gh_comment_issue() { :; }
ci_post_stage_event() { :; }
template_for_type() { echo "standard"; }

# Source the real pipeline state library
_PIPELINE_STATE_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-state.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# HC1: Pipeline initialization creates required state files
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "HC1: Pipeline Initialization"

# Initialize pipeline state
initialize_state

assert_eq "Pipeline status set to running" "running" "$PIPELINE_STATUS"

if [[ -n "${STARTED_AT:-}" ]]; then
    assert_pass "Started timestamp is set"
else
    assert_fail "Started timestamp is set"
fi

if [[ -n "${PIPELINE_START_EPOCH:-}" ]]; then
    assert_pass "Start epoch is set"
else
    assert_fail "Start epoch is set"
fi

assert_eq "Stage statuses cleared on init" "" "$STAGE_STATUSES"
assert_eq "Log entries cleared on init" "" "$LOG_ENTRIES"

# write_state produces the state file
write_state
assert_file_exists "State file created by write_state" "$STATE_FILE"

# State file has correct YAML frontmatter
state_content=$(cat "$STATE_FILE")
assert_contains "State has pipeline name" "$state_content" "pipeline: health-check"
assert_contains "State has goal" "$state_content" "Validate pipeline health"
assert_contains "State has running status" "$state_content" "status: running"
assert_contains "State has Log section" "$state_content" "## Log"

# ═══════════════════════════════════════════════════════════════════════════════
# HC2: Stage execution order is correct (no skipped stages)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "HC2: Stage Execution Sequence"

# Define the canonical stage order
CANONICAL_STAGES="intake plan design build test review compound_quality pr merge deploy validate monitor"

# Simulate sequential stage execution and verify ordering
STAGE_STATUSES=""
STAGE_TIMINGS=""
LOG_ENTRIES=""
completed_order=""

for stage in $CANONICAL_STAGES; do
    set_stage_status "$stage" "running"
    record_stage_start "$stage"

    current=$(get_stage_status "$stage")
    assert_eq "Stage $stage is running" "running" "$current"

    set_stage_status "$stage" "complete"
    record_stage_end "$stage"
    completed_order="${completed_order:+$completed_order }${stage}"
done

# Verify all 12 stages completed
stage_count=0
for stage in $CANONICAL_STAGES; do
    status=$(get_stage_status "$stage")
    if [[ "$status" == "complete" ]]; then
        stage_count=$((stage_count + 1))
    fi
done
assert_eq "All 12 stages completed" "12" "$stage_count"

# Verify no stage was skipped (all have timing data)
for stage in $CANONICAL_STAGES; do
    secs=$(get_stage_timing_seconds "$stage")
    if [[ "$secs" =~ ^[0-9]+$ ]]; then
        assert_pass "Stage $stage has timing data"
    else
        assert_fail "Stage $stage has timing data" "got: $secs"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# HC3: Artifact generation paths are valid
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "HC3: Artifact Path Integrity"

# save_artifact creates files in the correct directory
save_artifact "plan.md" "# Implementation Plan"
assert_file_exists "plan.md artifact created" "$ARTIFACTS_DIR/plan.md"
plan_content=$(cat "$ARTIFACTS_DIR/plan.md")
assert_eq "plan.md content correct" "# Implementation Plan" "$plan_content"

save_artifact "design.md" "# Design Document"
assert_file_exists "design.md artifact created" "$ARTIFACTS_DIR/design.md"

# Nested path artifacts
save_artifact "error-log.jsonl" '{"error":"test"}'
assert_file_exists "error-log.jsonl artifact created" "$ARTIFACTS_DIR/error-log.jsonl"

# JSON artifact is valid
save_artifact "data.json" '{"key":"value","count":42}'
if jq empty "$ARTIFACTS_DIR/data.json" 2>/dev/null; then
    assert_pass "JSON artifact is valid JSON"
else
    assert_fail "JSON artifact is valid JSON"
fi

# verify_stage_artifacts: plan stage passes with plan.md
if verify_stage_artifacts "plan" 2>/dev/null; then
    assert_pass "Plan stage passes artifact verification"
else
    assert_fail "Plan stage passes artifact verification"
fi

# verify_stage_artifacts: design stage passes with both artifacts
if verify_stage_artifacts "design" 2>/dev/null; then
    assert_pass "Design stage passes artifact verification"
else
    assert_fail "Design stage passes artifact verification"
fi

# Empty artifact fails verification
echo -n "" > "$ARTIFACTS_DIR/plan.md"
if verify_stage_artifacts "plan" 2>/dev/null; then
    assert_fail "Empty plan.md should fail verification"
else
    assert_pass "Empty plan.md fails verification correctly"
fi

# Restore valid artifact
echo "# Plan" > "$ARTIFACTS_DIR/plan.md"

# ═══════════════════════════════════════════════════════════════════════════════
# HC4: Error handling — missing dependencies and edge cases
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "HC4: Error Handling & Resilience"

# Missing artifact detected
rm -f "$ARTIFACTS_DIR/design.md"
if verify_stage_artifacts "design" 2>/dev/null; then
    assert_fail "Missing design.md should fail verification"
else
    assert_pass "Missing design.md detected correctly"
fi

# Stages without artifact requirements always pass
for stage in build test review compound_quality pr merge deploy validate monitor; do
    if verify_stage_artifacts "$stage" 2>/dev/null; then
        assert_pass "Stage $stage passes without artifacts (expected)"
    else
        assert_fail "Stage $stage passes without artifacts (expected)"
    fi
done

# Empty ARTIFACTS_DIR doesn't crash verify_stage_artifacts
local_artifacts_dir="$ARTIFACTS_DIR"
ARTIFACTS_DIR=""
if verify_stage_artifacts "plan" 2>/dev/null; then
    assert_pass "Empty ARTIFACTS_DIR doesn't crash"
else
    assert_fail "Empty ARTIFACTS_DIR doesn't crash"
fi
ARTIFACTS_DIR="$local_artifacts_dir"

# get_stage_status for unknown stage returns empty (not error)
result=$(get_stage_status "nonexistent_stage")
assert_eq "Unknown stage returns empty status" "" "$result"

# get_stage_timing_seconds for unknown stage returns 0
result=$(get_stage_timing_seconds "nonexistent_stage")
assert_eq "Unknown stage returns 0 seconds" "0" "$result"

# get_stage_description for unknown stage returns empty
result=$(get_stage_description "unknown_stage_xyz")
assert_eq "Unknown stage returns empty description" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# HC5: State transitions maintain consistency
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "HC5: State Transition Consistency"

# Reset state
STAGE_STATUSES=""
STAGE_TIMINGS=""
LOG_ENTRIES=""
PIPELINE_STATUS="running"

# Simulate a stage going through full lifecycle: pending → running → complete
set_stage_status "build" "pending"
result=$(get_stage_status "build")
assert_eq "Build starts as pending" "pending" "$result"

set_stage_status "build" "running"
result=$(get_stage_status "build")
assert_eq "Build transitions to running" "running" "$result"

set_stage_status "build" "complete"
result=$(get_stage_status "build")
assert_eq "Build transitions to complete" "complete" "$result"

# Multiple stage status updates don't corrupt each other
set_stage_status "intake" "complete"
set_stage_status "plan" "running"
set_stage_status "test" "pending"

assert_eq "Intake is complete" "complete" "$(get_stage_status "intake")"
assert_eq "Plan is running" "running" "$(get_stage_status "plan")"
assert_eq "Test is pending" "pending" "$(get_stage_status "test")"
assert_eq "Build still complete" "complete" "$(get_stage_status "build")"

# log_stage appends entries without overwriting
LOG_ENTRIES=""
log_stage "intake" "requirements gathered"
log_stage "plan" "implementation plan created"
log_stage "build" "code written"

assert_contains "Log has intake entry" "$LOG_ENTRIES" "requirements gathered"
assert_contains "Log has plan entry" "$LOG_ENTRIES" "implementation plan created"
assert_contains "Log has build entry" "$LOG_ENTRIES" "code written"

# write_state after transitions produces valid state file
CURRENT_STAGE="plan"
write_state
state_content=$(cat "$STATE_FILE")
assert_contains "State reflects current stage" "$state_content" "current_stage: plan"
assert_contains "State has log entries" "$state_content" "requirements gathered"

# Stage effectiveness tracking works
export STAGE_EFFECTIVENESS_FILE="$TEST_TEMP_DIR/effectiveness.jsonl"
rm -f "$STAGE_EFFECTIVENESS_FILE"

record_stage_effectiveness "build" "complete"
assert_file_exists "Effectiveness file created" "$STAGE_EFFECTIVENESS_FILE"
eff_content=$(cat "$STAGE_EFFECTIVENESS_FILE")
assert_contains "Effectiveness has stage" "$eff_content" '"stage":"build"'
assert_contains "Effectiveness has outcome" "$eff_content" '"outcome":"complete"'

# No hint when mostly successful
rm -f "$STAGE_EFFECTIVENESS_FILE"
for i in 1 2 3 4 5 6 7 8; do
    record_stage_effectiveness "test" "complete"
done
record_stage_effectiveness "test" "failed"
hint=$(get_stage_self_awareness_hint "test" 2>/dev/null)
assert_eq "No hint when mostly successful" "" "$hint"

# Hint generated when majority fail
rm -f "$STAGE_EFFECTIVENESS_FILE"
for i in 1 2 3 4 5; do
    record_stage_effectiveness "build" "failed"
done
hint=$(get_stage_self_awareness_hint "build" 2>/dev/null)
assert_contains "Hint for failing builds" "$hint" "build"

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
