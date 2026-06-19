#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline watch test — Real-Time Pipeline Progress Stream         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_env EXIT

# Minimal globals the watch lib expects from the pipeline harness.
now_epoch() { date +%s; }
now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then printf "%dm %ds" $((secs/60)) $((secs%60))
    else printf "%ds" "$secs"; fi
}
# Cross-platform date helper (mirror compat.sh)
date_to_epoch() {
    local datestr="$1" fmt="%Y-%m-%dT%H:%M:%SZ"
    date -u -d "$datestr" +%s 2>/dev/null && return
    date -u -j -f "$fmt" "$datestr" +%s 2>/dev/null || echo "0"
}
# setup_dirs stub — point at the test fixture.
setup_dirs() {
    STATE_DIR="$TEST_TEMP_DIR/.claude"
    STATE_FILE="$STATE_DIR/pipeline-state.md"
    ARTIFACTS_DIR="$STATE_DIR/pipeline-artifacts"
    LOG_DIR="$STATE_DIR/loop-logs"
}
error() { echo "ERROR: $*" >&2; }

source "$SCRIPT_DIR/lib/pipeline-watch.sh"

# ─── Fixture builders ──────────────────────────────────────────────────────
write_state_fixture() {
    local status="$1" stage="$2" progress="$3" started="${4:-}" updated="${5:-}"
    [[ -z "$started" ]] && started="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -z "$updated" ]] && updated="$(now_iso)"
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
---
pipeline: standard
goal: "Real-Time Pipeline Progress Stream"
status: $status
issue: "#659"
branch: "feat/watch-659"
current_stage: $stage
current_stage_description: "Building"
stage_progress: "$progress"
started_at: $started
updated_at: $updated
elapsed: 10m 0s
pr_number:
progress_comment_id:
stages:
  intake: complete
  build: $([ "$stage" = build ] && echo running || echo pending)
---

## Log
EOF
}

print_test_header "Shipwright Pipeline Watch Tests"
mkdir -p "$TEST_TEMP_DIR/.claude"
setup_dirs
export EVENTS_FILE="$TEST_TEMP_DIR/events.jsonl"

# ─── Frontmatter field reader ──────────────────────────────────────────────
print_test_section "Field reader"
write_state_fixture "running" "build" "intake:complete plan:complete build:running test:pending"
assert_eq "reads status field" "running" "$(_watch_read_state_field status)"
assert_eq "reads current_stage (not _description)" "build" "$(_watch_read_state_field current_stage)"
assert_eq "reads goal field (quotes stripped)" "Real-Time Pipeline Progress Stream" "$(_watch_read_state_field goal)"
assert_eq "reads issue field" "#659" "$(_watch_read_state_field issue)"
assert_eq "missing field returns empty" "" "$(_watch_read_state_field nonexistent_field)"

# ─── Stage bar ─────────────────────────────────────────────────────────────
print_test_section "Stage bar"
bar=$(_watch_render_stage_bar "intake:complete plan:complete build:running test:pending")
assert_contains "bar shows percentage" "$bar" "50%"
assert_contains "bar shows stage count" "$bar" "(2/4 stages)"
empty_bar=$(_watch_render_stage_bar "")
assert_contains "empty progress handled" "$empty_bar" "no stages"

# ─── Elapsed / activity ────────────────────────────────────────────────────
print_test_section "Elapsed & activity"
five_min_ago="$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
if [[ -n "$five_min_ago" ]]; then
    elapsed=$(_watch_elapsed "$five_min_ago")
    assert_contains "elapsed formatted as minutes" "$elapsed" "m "
fi
assert_eq "empty start gives dash" "—" "$(_watch_elapsed "")"
assert_eq "empty updated gives unknown" "unknown" "$(_watch_last_activity "")"

# ─── ETA ───────────────────────────────────────────────────────────────────
print_test_section "Completion estimate"
start10="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
if [[ -n "$start10" ]]; then
    eta=$(_watch_estimate_completion "a:complete b:complete c:pending d:pending" "$start10")
    assert_contains "eta is advisory" "$eta" "est."
fi
no_eta=$(_watch_estimate_completion "a:pending b:pending" "$start10")
assert_eq "no eta when zero complete" "" "$no_eta"
done_eta=$(_watch_estimate_completion "a:complete b:complete" "$start10")
assert_eq "no eta when all complete" "" "$done_eta"

# ─── Build panel ───────────────────────────────────────────────────────────
print_test_section "Build panel"
mkdir -p "$LOG_DIR"
cat > "$LOG_DIR/progress.md" <<'EOF'
# Session Progress (Auto-Generated)

## Goal
test goal

## Status
- Iteration: 3/20
- Session restart: 0/0
- Tests passing: false
- Status: running

## Recent Commits
abc1234 feat: add watch
def5678 fix: bug

## Changed Files
scripts/lib/pipeline-watch.sh
EOF
panel=$(_watch_build_panel)
assert_contains "build panel shows iteration" "$panel" "3/20"
assert_contains "build panel shows failing tests" "$panel" "failing"
assert_contains "build panel shows commits" "$panel" "abc1234"

# ─── Activity from events ──────────────────────────────────────────────────
print_test_section "Activity stream"
cat > "$EVENTS_FILE" <<'EOF'
{"ts":"2026-06-19T01:35:07Z","type":"vitals.snapshot"}
{"ts":"2026-06-19T01:36:10Z","type":"loop.iteration_start"}
EOF
if command -v jq >/dev/null 2>&1; then
    act=$(_watch_activity 5)
    assert_contains "activity shows event type" "$act" "loop.iteration_start"
fi

# ─── Main loop (one-shot) ──────────────────────────────────────────────────
print_test_section "Main loop one-shot"
write_state_fixture "running" "build" "intake:complete build:running test:pending"
out=$(SW_WATCH_ONCE=1 pipeline_watch 2>&1) && rc=0 || rc=$?
assert_eq "one-shot exits 0" "0" "$rc"
assert_contains "frame shows header" "$out" "Pipeline Watch"
assert_contains "frame shows goal" "$out" "Real-Time Pipeline Progress Stream"
assert_contains "frame shows build panel" "$out" "Build"

# Terminal state — clean exit with summary
write_state_fixture "complete" "monitor" "intake:complete build:complete test:complete"
out=$(SW_WATCH_ONCE=1 pipeline_watch 2>&1) && rc=0 || rc=$?
assert_eq "complete exits 0" "0" "$rc"
assert_contains "complete shows summary" "$out" "Pipeline complete"

write_state_fixture "failed" "build" "intake:complete build:failed"
out=$(SW_WATCH_ONCE=1 pipeline_watch 2>&1) && rc=0 || rc=$?
assert_contains "failed shows summary" "$out" "Pipeline failed"

# Missing state file — error path
rm -f "$STATE_FILE"
out=$(SW_WATCH_ONCE=1 pipeline_watch 2>&1) && rc=0 || rc=$?
assert_eq "missing state exits 1" "1" "$rc"
assert_contains "missing state warns" "$out" "No active pipeline"

# ─── CLI dispatch + help ───────────────────────────────────────────────────
print_test_section "CLI integration"
help_out=$(bash "$SCRIPT_DIR/sw-pipeline.sh" help 2>&1) || true
assert_contains "help lists watch command" "$help_out" "watch"

print_test_results
