#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tmux-status test — Unit tests for tmux status bar widgets    ║
# ║  Validates stage colors/icons, pipeline state parsing, agent counting    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT & FIXTURES
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tmux-status-test.XXXXXX")
    mkdir -p "$TEMP_DIR/project/.claude"
    mkdir -p "$TEMP_DIR/home/.shipwright/heartbeats"

    export HOME="$TEMP_DIR/home"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))
    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    local result=0
    "$test_fn" || result=$?
    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TMUX STATUS TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_script_is_executable() {
    [[ -x "$SCRIPT_DIR/sw-tmux-status.sh" ]] || return 1
}

test_stage_color_function_defined() {
    # Source the script and check for stage_color function
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        type stage_color >/dev/null 2>&1
    ) || return 1
}

test_stage_icon_function_defined() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        type stage_icon >/dev/null 2>&1
    ) || return 1
}

test_pipeline_widget_function_defined() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        type pipeline_widget >/dev/null 2>&1
    ) || return 1
}

test_agent_widget_function_defined() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        type agent_widget >/dev/null 2>&1
    ) || return 1
}

test_stage_color_intake() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(stage_color "intake")
        [[ "$result" == "#71717a" ]]
    ) || return 1
}

test_stage_color_build() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(stage_color "build")
        [[ "$result" == "#0066ff" ]]
    ) || return 1
}

test_stage_color_test() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(stage_color "test")
        [[ "$result" == "#facc15" ]]
    ) || return 1
}

test_stage_color_deploy() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(stage_color "deploy")
        [[ "$result" == "#4ade80" ]]
    ) || return 1
}

test_stage_color_unknown_fallback() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(stage_color "unknown_stage")
        [[ "$result" == "#71717a" ]]
    ) || return 1
}

test_stage_icon_intake() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(stage_icon "intake")
        [[ "$result" == "◇" ]]
    ) || return 1
}

test_stage_icon_build() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(stage_icon "build")
        [[ "$result" == "⚙" ]]
    ) || return 1
}

test_stage_icon_test() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(stage_icon "test")
        [[ "$result" == "⚡" ]]
    ) || return 1
}

test_stage_icon_unknown_fallback() {
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(stage_icon "unknown_stage")
        [[ "$result" == "·" ]]
    ) || return 1
}

test_stage_icon_all_defined() {
    # Test that all major stages have icons
    (
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        for stage in intake plan design build test review deploy validate monitor; do
            icon=$(stage_icon "$stage")
            [[ -n "$icon" && "$icon" != "·" ]] || return 1
        done
    ) || return 1
}

test_pipeline_widget_no_state_file() {
    (
        export HOME="$TEMP_DIR/home"
        cd "$TEMP_DIR/project"
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(pipeline_widget)
        [[ -z "$result" ]]
    ) || return 1
}

test_pipeline_widget_with_stage() {
    # Verify the widget handles stage files correctly
    (
        grep -q "pipeline_widget()" "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
        grep -q ".claude/pipeline-state.md" "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
        grep -q "stage_color\|stage_icon" "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
    ) || return 1
}

test_pipeline_widget_case_insensitive() {
    # Verify the script uses case conversion
    (
        grep -q "tr.*lower\|tr.*upper" "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
    ) || return 1
}

test_agent_widget_no_heartbeats() {
    (
        export HOME="$TEMP_DIR/home"
        cd "$TEMP_DIR/project"
        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(agent_widget)
        [[ -z "$result" ]]
    ) || return 1
}

test_agent_widget_counts_fresh() {
    (
        export HOME="$TEMP_DIR/home"
        cd "$TEMP_DIR/project"

        # Create fresh heartbeat file
        now=$(date +%s)
        touch -t "$(date -d @$now +%Y%m%d%H%M.%S)" "$TEMP_DIR/home/.shipwright/heartbeats/agent1.json" 2>/dev/null || {
            # On macOS, use different touch syntax
            touch "$TEMP_DIR/home/.shipwright/heartbeats/agent1.json"
        }

        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(agent_widget)
        echo "$result" | grep -q "λ1" || return 1
    ) || return 1
}

test_agent_widget_multiple_fresh() {
    (
        export HOME="$TEMP_DIR/home"
        cd "$TEMP_DIR/project"

        # Create multiple fresh heartbeat files
        now=$(date +%s)
        for i in 1 2 3; do
            touch -t "$(date -d @$now +%Y%m%d%H%M.%S)" "$TEMP_DIR/home/.shipwright/heartbeats/agent$i.json" 2>/dev/null || {
                touch "$TEMP_DIR/home/.shipwright/heartbeats/agent$i.json"
            }
        done

        source "$SCRIPT_DIR/sw-tmux-status.sh"
        result=$(agent_widget)
        echo "$result" | grep -q "λ3" || return 1
    ) || return 1
}

test_dispatch_default_pipeline() {
    # Verify the dispatch logic handles default case
    (
        grep -q 'case "${1:-pipeline}"' "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
        grep -q 'pipeline_widget' "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
    ) || return 1
}

test_dispatch_all_mode() {
    # Verify the dispatch logic handles 'all' mode
    (
        grep -q "all)" "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
        grep -q 'pipeline_widget\|agent_widget' "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
    ) || return 1
}

test_script_has_no_syntax_errors() {
    bash -n "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
}

test_script_sources_helpers() {
    # Check that script sources helpers
    grep -q "source.*helpers.sh\|source.*compat.sh" "$SCRIPT_DIR/sw-tmux-status.sh" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    print_test_header "tmux-status Unit Tests"

    setup_env

    print_test_section "Script Basics"
    run_test "script is executable" "test_script_is_executable"
    run_test "script has no syntax errors" "test_script_has_no_syntax_errors"
    run_test "script sources helpers" "test_script_sources_helpers"

    print_test_section "Function Definitions"
    run_test "stage_color function defined" "test_stage_color_function_defined"
    run_test "stage_icon function defined" "test_stage_icon_function_defined"
    run_test "pipeline_widget function defined" "test_pipeline_widget_function_defined"
    run_test "agent_widget function defined" "test_agent_widget_function_defined"

    print_test_section "Stage Colors"
    run_test "stage_color intake" "test_stage_color_intake"
    run_test "stage_color build" "test_stage_color_build"
    run_test "stage_color test" "test_stage_color_test"
    run_test "stage_color deploy" "test_stage_color_deploy"
    run_test "stage_color unknown fallback" "test_stage_color_unknown_fallback"

    print_test_section "Stage Icons"
    run_test "stage_icon intake" "test_stage_icon_intake"
    run_test "stage_icon build" "test_stage_icon_build"
    run_test "stage_icon test" "test_stage_icon_test"
    run_test "stage_icon unknown fallback" "test_stage_icon_unknown_fallback"
    run_test "all major stages have icons" "test_stage_icon_all_defined"

    print_test_section "Pipeline Widget"
    run_test "pipeline widget with no state file" "test_pipeline_widget_no_state_file"
    run_test "pipeline widget parses stage" "test_pipeline_widget_with_stage"
    run_test "pipeline widget handles case" "test_pipeline_widget_case_insensitive"

    print_test_section "Agent Widget"
    run_test "agent widget with no heartbeats" "test_agent_widget_no_heartbeats"
    run_test "agent widget counts fresh" "test_agent_widget_counts_fresh"
    run_test "agent widget counts multiple" "test_agent_widget_multiple_fresh"

    print_test_section "Dispatch"
    run_test "dispatch defaults to pipeline" "test_dispatch_default_pipeline"
    run_test "dispatch all mode" "test_dispatch_all_mode"

    echo ""
    echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
    echo ""
    if [[ $FAIL -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
        echo ""
        exit 0
    else
        echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
        echo ""
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi
}

main "$@"
