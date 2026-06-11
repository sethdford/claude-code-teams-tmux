#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tmux-role-color test — Validate role → color mapping        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tmux-role-color-test.XXXXXX")

    # Copy the script under test
    cp "$SCRIPT_DIR/sw-tmux-role-color.sh" "$TEST_TEMP_DIR/"

    # Create mock helpers directory
    mkdir -p "$TEST_TEMP_DIR/lib"
    [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_TEMP_DIR/lib/"

    # Create mock tmux binary
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'TMUXMOCK'
#!/usr/bin/env bash
# Mock tmux: reads MOCK_PANE_TITLE and logs set commands
echo "tmux $*" >> "${MOCK_TMUX_LOG:-/dev/null}"

case "$1" in
    display-message)
        # Return the mocked pane title
        if [[ "${2:-}" == "-p" && "${3:-}" == "#{pane_title}" ]]; then
            echo "${MOCK_PANE_TITLE:-}"
        fi
        ;;
    set)
        # Just log the set command (don't actually set)
        ;;
esac
TMUXMOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    # Set up test environment
    export SCRIPT_DIR="$TEST_TEMP_DIR"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export MOCK_TMUX_LOG="$TEST_TEMP_DIR/tmux.log"
}

cleanup_test_env() {
    [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

# ─── Test cases ────────────────────────────────────────────────────────────

test_role_leader() {
    local desc="Role 'leader' maps to cyan (#00d4ff)"
    export MOCK_PANE_TITLE="team-leader"
    local output
    output=$("$TEST_TEMP_DIR/sw-tmux-role-color.sh" 2>/dev/null || echo "")
    if grep -q "fg=#00d4ff" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #00d4ff in tmux set command"
    fi
    > "$MOCK_TMUX_LOG"
}

test_role_builder() {
    local desc="Role 'builder' maps to blue (#0066ff)"
    export MOCK_PANE_TITLE="agent-builder"
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#0066ff" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #0066ff in tmux set command"
    fi
    > "$MOCK_TMUX_LOG"
}

test_role_reviewer() {
    local desc="Role 'reviewer' maps to orange (#f97316)"
    export MOCK_PANE_TITLE="pr-reviewer"
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#f97316" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #f97316 in tmux set command"
    fi
    > "$MOCK_TMUX_LOG"
}

test_role_tester() {
    local desc="Role 'tester' maps to yellow (#facc15)"
    export MOCK_PANE_TITLE="qa-tester"
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#facc15" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #facc15 in tmux set command"
    fi
    > "$MOCK_TMUX_LOG"
}

test_role_security() {
    local desc="Role 'security' maps to red (#ef4444)"
    export MOCK_PANE_TITLE="threat-hunter"
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#ef4444" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #ef4444 in tmux set command"
    fi
    > "$MOCK_TMUX_LOG"
}

test_role_docs() {
    local desc="Role 'docs' maps to violet (#a78bfa)"
    export MOCK_PANE_TITLE="doc-writer"
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#a78bfa" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #a78bfa in tmux set command"
    fi
    > "$MOCK_TMUX_LOG"
}

test_role_optimizer() {
    local desc="Role 'optimizer' maps to green (#4ade80)"
    export MOCK_PANE_TITLE="performance-optimizer"
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#4ade80" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #4ade80 in tmux set command"
    fi
    > "$MOCK_TMUX_LOG"
}

test_role_researcher() {
    local desc="Role 'researcher' maps to purple (#7c3aed)"
    export MOCK_PANE_TITLE="intelligence-researcher"
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#7c3aed" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #7c3aed in tmux set command"
    fi
    > "$MOCK_TMUX_LOG"
}

test_role_unknown_fallback() {
    local desc="Unknown role falls back to default cyan (#00d4ff)"
    export MOCK_PANE_TITLE="unknown-role"
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#00d4ff" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #00d4ff fallback for unknown role"
    fi
    > "$MOCK_TMUX_LOG"
}

test_empty_title() {
    local desc="Empty pane title defaults to cyan (#00d4ff)"
    export MOCK_PANE_TITLE=""
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#00d4ff" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #00d4ff default for empty title"
    fi
    > "$MOCK_TMUX_LOG"
}

test_case_insensitivity() {
    local desc="Role matching is case-insensitive (LEADER -> #00d4ff)"
    export MOCK_PANE_TITLE="TEAM-LEADER"
    "$TEST_TEMP_DIR/sw-tmux-role-color.sh" &>/dev/null || true
    if grep -q "fg=#00d4ff" "$MOCK_TMUX_LOG" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "Expected #00d4ff for case-insensitive match"
    fi
    > "$MOCK_TMUX_LOG"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "sw-tmux-role-color"

setup_test_env
trap cleanup_test_env EXIT

test_role_leader
test_role_builder
test_role_reviewer
test_role_tester
test_role_security
test_role_docs
test_role_optimizer
test_role_researcher
test_role_unknown_fallback
test_empty_title
test_case_insensitivity

print_test_results
exit "$((FAIL > 0 ? 1 : 0))"
