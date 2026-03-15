#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-role-color-test.sh — Test pane border color assignment by role  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-tmux-role-color Test Suite"

setup_test_env "sw-tmux-role-color-test"
trap cleanup_test_env EXIT

# Helper: run a test and track pass/fail
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

# Copy the script under test
mkdir -p "$TEST_TEMP_DIR/scripts/lib"
cp "$SCRIPT_DIR/sw-tmux-role-color.sh" "$TEST_TEMP_DIR/scripts/"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_TEMP_DIR/scripts/lib/"

# Create mock tmux binary
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/tmux" <<'TMUX_MOCK'
#!/usr/bin/env bash
case "$1" in
    display-message)
        # Returns MOCK_TMUX_PANE_TITLE if set, otherwise empty
        [[ -n "${MOCK_TMUX_PANE_TITLE:-}" ]] && echo "$MOCK_TMUX_PANE_TITLE"
        ;;
    set)
        # Log all set calls - include the full command line
        echo "set $*" >> "${TEST_TEMP_DIR}/tmux-commands.log"
        ;;
    *)
        ;;
esac
exit 0
TMUX_MOCK
chmod +x "$TEST_TEMP_DIR/bin/tmux"

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Role to Color Mapping"

# Helper: Run script and verify color was set correctly
verify_color() {
    local title="$1" expected_color="$2"
    rm -f "$TEST_TEMP_DIR/tmux-commands.log"
    MOCK_TMUX_PANE_TITLE="$title" \
    SCRIPT_DIR="$TEST_TEMP_DIR/scripts" \
    TEST_TEMP_DIR="$TEST_TEMP_DIR" \
    PATH="$TEST_TEMP_DIR/bin:$PATH" \
    bash "$TEST_TEMP_DIR/scripts/sw-tmux-role-color.sh" >/dev/null 2>&1

    if [[ -f "$TEST_TEMP_DIR/tmux-commands.log" ]]; then
        grep -q "$expected_color" "$TEST_TEMP_DIR/tmux-commands.log"
    else
        return 1
    fi
}

# Test: Leader role → cyan
test_leader_role_cyan() {
    verify_color "leader-agent" "#00d4ff"
}

# Test: Builder role → blue
test_builder_role_blue() {
    verify_color "builder-agent" "#0066ff"
}

# Test: Reviewer role → orange
test_reviewer_role_orange() {
    verify_color "reviewer-agent" "#f97316"
}

# Test: Tester role → yellow
test_tester_role_yellow() {
    verify_color "tester-agent" "#facc15"
}

# Test: Security role → red
test_security_role_red() {
    verify_color "security-agent" "#ef4444"
}

# Test: Docs role → violet
test_docs_role_violet() {
    verify_color "docs-agent" "#a78bfa"
}

# Test: Optimizer role → green
test_optimizer_role_green() {
    verify_color "optimizer-agent" "#4ade80"
}

# Test: Researcher role → purple
test_researcher_role_purple() {
    verify_color "researcher-agent" "#7c3aed"
}

# Test: Case-insensitive matching
test_case_insensitive_matching() {
    verify_color "BUILDER-AGENT" "#0066ff"
}

# Test: Unknown role defaults to cyan
test_unknown_role_defaults_to_cyan() {
    verify_color "unknown-role-xyz" "#00d4ff"
}

# Test: Empty title defaults to cyan
test_empty_title_defaults_to_cyan() {
    verify_color "" "#00d4ff"
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

run_test "Leader role → cyan" test_leader_role_cyan
run_test "Builder role → blue" test_builder_role_blue
run_test "Reviewer role → orange" test_reviewer_role_orange
run_test "Tester role → yellow" test_tester_role_yellow
run_test "Security role → red" test_security_role_red
run_test "Docs role → violet" test_docs_role_violet
run_test "Optimizer role → green" test_optimizer_role_green
run_test "Researcher role → purple" test_researcher_role_purple
run_test "Case-insensitive matching" test_case_insensitive_matching
run_test "Unknown role defaults to cyan" test_unknown_role_defaults_to_cyan
run_test "Empty title defaults to cyan" test_empty_title_defaults_to_cyan

print_test_results

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
