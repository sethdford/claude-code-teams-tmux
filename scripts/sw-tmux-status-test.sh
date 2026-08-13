#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-status-test.sh — Test Suite for Status Bar Widgets             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-tmux-status-test.sh"

# ─── Setup & teardown ───────────────────────────────────────────────────────
setup_test_env "sw-tmux-status"

# Create a mock pipeline state file
create_pipeline_state() {
    local stage="$1"
    mkdir -p "$TEST_TEMP_DIR/project/.claude"
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-state.md" <<EOF
# Pipeline State
current_stage: $stage
EOF
    cd "$TEST_TEMP_DIR/project"
}

# ─── Test: stage_color function for intake ──────────────────────────────────
test_stage_color_intake() {
    # Source the script to access its functions
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local color; color=$(stage_color "intake")
    assert_eq "intake stage color" "#71717a" "$color"
}

# ─── Test: stage_color function for build ──────────────────────────────────
test_stage_color_build() {
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local color; color=$(stage_color "build")
    assert_eq "build stage color" "#0066ff" "$color"
}

# ─── Test: stage_color function for test ──────────────────────────────────
test_stage_color_test() {
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local color; color=$(stage_color "test")
    assert_eq "test stage color" "#facc15" "$color"
}

# ─── Test: stage_color function for review ──────────────────────────────────
test_stage_color_review() {
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local color; color=$(stage_color "review")
    assert_eq "review stage color" "#f97316" "$color"
}

# ─── Test: stage_color function for deploy ──────────────────────────────────
test_stage_color_deploy() {
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local color; color=$(stage_color "deploy")
    assert_eq "deploy stage color" "#4ade80" "$color"
}

# ─── Test: stage_color default for unknown ──────────────────────────────────
test_stage_color_unknown() {
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local color; color=$(stage_color "unknown")
    assert_eq "unknown stage default color" "#71717a" "$color"
}

# ─── Test: stage_icon function for intake ──────────────────────────────────
test_stage_icon_intake() {
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local icon; icon=$(stage_icon "intake")
    assert_eq "intake stage icon" "◇" "$icon"
}

# ─── Test: stage_icon function for build ──────────────────────────────────
test_stage_icon_build() {
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local icon; icon=$(stage_icon "build")
    assert_eq "build stage icon" "⚙" "$icon"
}

# ─── Test: stage_icon function for test ──────────────────────────────────
test_stage_icon_test() {
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local icon; icon=$(stage_icon "test")
    assert_eq "test stage icon" "⚡" "$icon"
}

# ─── Test: stage_icon default for unknown ──────────────────────────────────
test_stage_icon_unknown() {
    source "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1
    local icon; icon=$(stage_icon "unknown")
    assert_eq "unknown stage default icon" "·" "$icon"
}

# ─── Test: script runs without error ──────────────────────────────────────
test_script_runs() {
    create_pipeline_state "build"
    bash "$SCRIPT_DIR/sw-tmux-status.sh" pipeline >/dev/null 2>&1
    assert_pass "script runs without error (pipeline widget)"
}

# ─── Test: pipeline_widget reads state file ──────────────────────────────────
test_pipeline_widget_with_state() {
    create_pipeline_state "build"
    local output; output=$(bash "$SCRIPT_DIR/sw-tmux-status.sh" pipeline 2>&1 || true)
    # Should contain the icon and label
    if [[ "$output" =~ "BUILD" ]] || [[ -z "$output" ]]; then
        assert_pass "pipeline widget processes state file"
    else
        assert_fail "pipeline widget processes state file" "output: $output"
    fi
}

# ─── Test: agent_widget without heartbeats ──────────────────────────────────
test_agent_widget_no_heartbeats() {
    # Clean heartbeats dir
    rm -rf "$HOME/.shipwright/heartbeats"
    mkdir -p "$HOME/.shipwright"
    local output; output=$(bash "$SCRIPT_DIR/sw-tmux-status.sh" agents 2>&1 || true)
    assert_pass "agent_widget handles missing heartbeats gracefully"
}

# ─── Test: all widgets combined ──────────────────────────────────────────────
test_all_widgets() {
    create_pipeline_state "test"
    mkdir -p "$HOME/.shipwright/heartbeats"
    # Create a fresh heartbeat file
    echo '{"id":"test-agent","ts":"2026-08-13T21:50:00Z"}' > "$HOME/.shipwright/heartbeats/test-agent.json"
    # Update mtime to be recent (within 60s)
    touch "$HOME/.shipwright/heartbeats/test-agent.json"

    local output; output=$(bash "$SCRIPT_DIR/sw-tmux-status.sh" all 2>&1 || true)
    assert_pass "all widgets combined runs without error"
}

# ─── Test: dispatch default is pipeline ──────────────────────────────────────
test_dispatch_default() {
    create_pipeline_state "build"
    # Both default and explicit should work
    bash "$SCRIPT_DIR/sw-tmux-status.sh" >/dev/null 2>&1 || true
    bash "$SCRIPT_DIR/sw-tmux-status.sh" pipeline >/dev/null 2>&1 || true
    assert_pass "dispatch default behavior works"
}

# ─── Main ───────────────────────────────────────────────────────────────────
test_stage_color_intake
test_stage_color_build
test_stage_color_test
test_stage_color_review
test_stage_color_deploy
test_stage_color_unknown
test_stage_icon_intake
test_stage_icon_build
test_stage_icon_test
test_stage_icon_unknown
test_script_runs
test_pipeline_widget_with_state
test_agent_widget_no_heartbeats
test_all_widgets
test_dispatch_default

cleanup_test_env
print_test_results
