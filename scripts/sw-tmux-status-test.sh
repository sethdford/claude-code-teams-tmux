#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
TEMP_DIR=""

cleanup() { [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

run_test() {
    local name="$1" fn="$2"
    TOTAL=$((TOTAL + 1))
    if $fn; then
        PASS=$((PASS + 1))
        echo -e "${GREEN}✓${RESET} $name"
    else
        FAIL=$((FAIL + 1))
        echo -e "${RED}✗${RESET} $name"
    fi
}

test_script_exists() {
    [[ -f "$SCRIPT_DIR/sw-tmux-status.sh" ]] && [[ -x "$SCRIPT_DIR/sw-tmux-status.sh" ]]
}

test_script_has_stage_color() {
    grep -q "stage_color()" "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_script_has_stage_icon() {
    grep -q "stage_icon()" "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_script_has_pipeline_widget() {
    grep -q "pipeline_widget()" "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_script_has_agent_widget() {
    grep -q "agent_widget()" "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_color_mappings_exist() {
    grep -q "intake.*#71717a" "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_icon_mappings_exist() {
    grep -q "intake.*◇" "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_pipeline_state_check() {
    grep -q '\.claude/pipeline-state\.md' "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_heartbeat_check() {
    grep -q 'heartbeats' "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_dispatch_modes() {
    grep -q 'pipeline)' "$SCRIPT_DIR/sw-tmux-status.sh" && \
    grep -q 'agents)' "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_set_safety() {
    grep -q "set -euo pipefail" "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_runs_without_error() {
    TEMP_DIR=$(mktemp -d)
    export HOME="$TEMP_DIR"
    bash "$SCRIPT_DIR/sw-tmux-status.sh" pipeline >/dev/null 2>&1 || return 1
    true
}

test_agent_mode_runs() {
    TEMP_DIR=$(mktemp -d)
    export HOME="$TEMP_DIR"
    bash "$SCRIPT_DIR/sw-tmux-status.sh" agents >/dev/null 2>&1 || return 1
    true
}

test_all_mode_runs() {
    TEMP_DIR=$(mktemp -d)
    export HOME="$TEMP_DIR"
    bash "$SCRIPT_DIR/sw-tmux-status.sh" all >/dev/null 2>&1 || return 1
    true
}

test_stage_color_values() {
    grep -q "#0066ff" "$SCRIPT_DIR/sw-tmux-status.sh" && \
    grep -q "#7c3aed" "$SCRIPT_DIR/sw-tmux-status.sh" && \
    grep -q "#00d4ff" "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_mtime_check() {
    grep -q "mtime\|file_mtime" "$SCRIPT_DIR/sw-tmux-status.sh"
}

test_helpers_sourced() {
    grep -q "source.*helpers.sh\|source.*compat.sh" "$SCRIPT_DIR/sw-tmux-status.sh"
}

echo -e "${BOLD}${CYAN}sw-tmux-status test suite${RESET}\n"

run_test "script exists and executable" test_script_exists
run_test "stage_color function defined" test_script_has_stage_color
run_test "stage_icon function defined" test_script_has_stage_icon
run_test "pipeline_widget function defined" test_script_has_pipeline_widget
run_test "agent_widget function defined" test_script_has_agent_widget
run_test "color mappings defined" test_color_mappings_exist
run_test "icon mappings defined" test_icon_mappings_exist
run_test "pipeline state checked" test_pipeline_state_check
run_test "heartbeat directory checked" test_heartbeat_check
run_test "dispatch modes implemented" test_dispatch_modes
run_test "safety flags set" test_set_safety
run_test "pipeline mode runs" test_runs_without_error
run_test "agents mode runs" test_agent_mode_runs
run_test "all mode runs" test_all_mode_runs
run_test "stage color values defined" test_stage_color_values
run_test "mtime handling implemented" test_mtime_check
run_test "helper functions sourced" test_helpers_sourced

echo ""
print_test_results "PASS: $PASS" "FAIL: $FAIL"
exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 1)
