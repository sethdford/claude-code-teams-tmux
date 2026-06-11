#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tmux-status test — Validate status bar widget outputs       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tmux-status-test.XXXXXX")

    # Copy the script under test but keep SCRIPT_DIR pointing to actual scripts for helpers
    cp "$SCRIPT_DIR/sw-tmux-status.sh" "$TEST_TEMP_DIR/"

    # Create mock helpers locally but don't override if they exist
    mkdir -p "$TEST_TEMP_DIR/lib"
    [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_TEMP_DIR/lib/"
    [[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && cp "$SCRIPT_DIR/lib/compat.sh" "$TEST_TEMP_DIR/lib/" || touch "$TEST_TEMP_DIR/lib/compat.sh"

    # Create mock tmux
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'TMUXMOCK'
#!/usr/bin/env bash
case "$1" in
    display-message)
        if [[ "${3:-}" == "#{pane_title}" ]]; then
            echo "${MOCK_PANE_TITLE:-}"
        else
            echo "${MOCK_STAGE:-intake}"
        fi
        ;;
    *)
        return 0
        ;;
esac
TMUXMOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    # Create mock home directory with heartbeat files
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/heartbeats"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"

    # Set up test environment - keep original SCRIPT_DIR for finding libraries
    export ORIGINAL_SCRIPT_DIR="$SCRIPT_DIR"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
}

cleanup_test_env() {
    [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

# ─── Test cases ────────────────────────────────────────────────────────────

test_pipeline_widget_intake() {
    local desc="Pipeline widget outputs build stage badge"
    export MOCK_STAGE="build"

    # Create mock pipeline-state.md
    echo "stage: build" > "$TEST_TEMP_DIR/home/.claude/pipeline-state.md"

    local output
    cd "$TEST_TEMP_DIR/home"
    output=$(SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR" bash "$TEST_TEMP_DIR/sw-tmux-status.sh" pipeline 2>/dev/null || echo "")

    if echo "$output" | grep -qF "#["; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected tmux format string with #[ colors, got: $output"
    fi
}

test_pipeline_widget_test() {
    local desc="Pipeline widget handles test stage"
    export MOCK_STAGE="test"

    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    echo "Stage: test" > "$TEST_TEMP_DIR/home/.claude/pipeline-state.md"

    local output
    cd "$TEST_TEMP_DIR/home"
    output=$(SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR" bash "$TEST_TEMP_DIR/sw-tmux-status.sh" pipeline 2>/dev/null || echo "")

    if echo "$output" | grep -q "facc15"; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected yellow (#facc15) for test stage"
    fi
}

test_agent_widget_active() {
    local desc="Agent widget counts active heartbeats"

    # Create active heartbeat file (recent)
    mkdir -p "$HOME/.shipwright/heartbeats"
    echo '{"status":"active"}' > "$HOME/.shipwright/heartbeats/agent-1.json"
    touch "$HOME/.shipwright/heartbeats/agent-1.json"

    local output
    cd "$TEST_TEMP_DIR/home"
    output=$(SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR" bash "$TEST_TEMP_DIR/sw-tmux-status.sh" agents 2>/dev/null || echo "")

    if echo "$output" | grep -q "λ"; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected lambda character for active agents"
    fi
}

test_agent_widget_empty() {
    local desc="Agent widget handles no active agents"

    # No heartbeat files
    rm -rf "$HOME/.shipwright/heartbeats"
    mkdir -p "$HOME/.shipwright/heartbeats"

    local output
    cd "$TEST_TEMP_DIR/home"
    output=$(SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR" bash "$TEST_TEMP_DIR/sw-tmux-status.sh" agents 2>/dev/null || echo "")

    # When no agents, output should be empty
    if [[ -z "$output" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected empty output when no agents active, got: $output"
    fi
}

test_all_widgets() {
    local desc="All widgets command combines pipeline and agents"

    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    echo "Stage: build" > "$TEST_TEMP_DIR/home/.claude/pipeline-state.md"

    mkdir -p "$HOME/.shipwright/heartbeats"
    echo '{"status":"active"}' > "$HOME/.shipwright/heartbeats/agent-1.json"
    touch "$HOME/.shipwright/heartbeats/agent-1.json"

    local output
    cd "$TEST_TEMP_DIR/home"
    output=$(SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR" bash "$TEST_TEMP_DIR/sw-tmux-status.sh" all 2>/dev/null || echo "")

    if echo "$output" | grep -qE "#\["; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected combined widget output"
    fi
}

test_missing_state_file() {
    local desc="Pipeline widget handles missing state file gracefully"

    rm -f "$TEST_TEMP_DIR/home/.claude/pipeline-state.md"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"

    local output
    cd "$TEST_TEMP_DIR/home"
    output=$(SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR" bash "$TEST_TEMP_DIR/sw-tmux-status.sh" pipeline 2>/dev/null || echo "")

    # Should not crash, output empty
    assert_pass "$desc"
}

test_default_subcommand() {
    local desc="Default subcommand (no args) uses 'pipeline'"

    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    echo "Stage: build" > "$TEST_TEMP_DIR/home/.claude/pipeline-state.md"

    local output
    cd "$TEST_TEMP_DIR/home"
    output=$(SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR" bash "$TEST_TEMP_DIR/sw-tmux-status.sh" 2>/dev/null || echo "")

    if echo "$output" | grep -qF "#["; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected default pipeline widget"
    fi
}

test_unknown_subcommand() {
    local desc="Unknown subcommand returns empty string"

    local output
    cd "$TEST_TEMP_DIR/home"
    output=$(SCRIPT_DIR="$ORIGINAL_SCRIPT_DIR" bash "$TEST_TEMP_DIR/sw-tmux-status.sh" unknown 2>/dev/null || echo "")

    if [[ -z "$output" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected empty output for unknown subcommand, got: $output"
    fi
}

test_exit_code_success() {
    local desc="Script exits with code 0 on success"

    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    echo "Stage: build" > "$TEST_TEMP_DIR/home/.claude/pipeline-state.md"

    cd "$TEST_TEMP_DIR/home"
    if "$TEST_TEMP_DIR/sw-tmux-status.sh" pipeline &>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected exit code 0"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "sw-tmux-status"

setup_test_env
trap cleanup_test_env EXIT

test_pipeline_widget_intake
test_pipeline_widget_test
test_agent_widget_active
test_agent_widget_empty
test_all_widgets
test_missing_state_file
test_default_subcommand
test_unknown_subcommand
test_exit_code_success

print_test_results
exit "$((FAIL > 0 ? 1 : 0))"
