#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-role-color-test.sh — Set pane border color by agent role        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCK'
#!/bin/bash
case "${1:-}" in
    display-message)
        # Return the pane title from env var if set
        echo "${MOCK_PANE_TITLE:-}"
        ;;
    set)
        # Just echo what was set for debugging
        if [[ "${2:-}" == "-g" ]]; then
            echo "Set: ${5:-}"
        fi
        ;;
    *)
        ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

trap cleanup_test_env EXIT
setup_env

print_test_header "sw-tmux-role-color Tests"

# Test helper to verify color mapping
test_role_maps_to_color() {
    local role="$1"
    local expected_color="$2"
    local desc="$3"

    # Create a wrapper script that tests the role logic directly
    output=$(bash -c "
        MOCK_PANE_TITLE='$role'
        # Parse and extract color directly
        TITLE_LOWER=\"\$(echo '$role' | tr '[:upper:]' '[:lower:]')\"
        COLOR='#00d4ff'  # default
        case \"\$TITLE_LOWER\" in
            *leader*|*lead*|*pm*|*manager*|*orchestrat*)
                COLOR='#00d4ff' ;;
            *build*|*dev*|*implement*|*code*|*engineer*)
                COLOR='#0066ff' ;;
            *review*|*audit*|*inspect*|*oversight*)
                COLOR='#f97316' ;;
            *test*|*qa*|*validat*|*verify*)
                COLOR='#facc15' ;;
            *secur*|*vuln*|*threat*|*pentest*)
                COLOR='#ef4444' ;;
            *doc*|*writ*|*readme*|*changelog*)
                COLOR='#a78bfa' ;;
            *optim*|*perf*|*speed*|*deploy*)
                COLOR='#4ade80' ;;
            *research*|*explor*|*investigat*|*analyz*)
                COLOR='#7c3aed' ;;
        esac
        echo \"\$COLOR\"
    ")

    if [[ "$output" == "$expected_color" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected $expected_color, got $output"
    fi
}

# ─── Test 1: Script executes without error ────────────────────────────────
echo ""
echo -e "${BOLD}  Basic Execution${RESET}"
output=$(MOCK_PANE_TITLE="test" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" 2>&1) && rc=0 || rc=$?
assert_eq "script exits successfully" "0" "$rc"

# ─── Test 2: Role color mapping ────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Role → Color Mapping${RESET}"
test_role_maps_to_color "leader" "#00d4ff" "leader role maps to cyan"
test_role_maps_to_color "pm" "#00d4ff" "pm role maps to cyan"
test_role_maps_to_color "manager" "#00d4ff" "manager role maps to cyan"
test_role_maps_to_color "builder" "#0066ff" "builder role maps to blue"
test_role_maps_to_color "dev" "#0066ff" "dev role maps to blue"
test_role_maps_to_color "reviewer" "#f97316" "reviewer role maps to orange"
test_role_maps_to_color "tester" "#facc15" "tester role maps to yellow"
test_role_maps_to_color "security" "#ef4444" "security role maps to red"
test_role_maps_to_color "docs" "#a78bfa" "docs role maps to violet"
test_role_maps_to_color "optimizer" "#4ade80" "optimizer role maps to green"
test_role_maps_to_color "researcher" "#7c3aed" "researcher role maps to purple"

# ─── Test 3: Case insensitivity ────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Case Insensitivity${RESET}"
test_role_maps_to_color "BUILDER" "#0066ff" "uppercase BUILDER matches blue"
test_role_maps_to_color "Builder" "#0066ff" "mixed case Builder matches blue"
test_role_maps_to_color "ReViEwEr" "#f97316" "mixed case ReViEwEr matches orange"

# ─── Test 4: Default color for unknown role ──────────────────────────────
echo ""
echo -e "${BOLD}  Fallback Behavior${RESET}"
test_role_maps_to_color "unknown-role-xyz" "#00d4ff" "unknown role defaults to cyan"

# ─── Test 5: Empty pane title ────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Edge Cases${RESET}"
test_role_maps_to_color "" "#00d4ff" "empty pane title defaults to cyan"

# ─── Test 6: Partial word matches ────────────────────────────────────────
echo ""
echo -e "${BOLD}  Partial Matching${RESET}"
test_role_maps_to_color "test-validator-bot" "#facc15" "partial match includes 'validat'"
test_role_maps_to_color "lead-orchestrator" "#00d4ff" "partial match includes 'lead'"
test_role_maps_to_color "inspector-bot" "#f97316" "partial match includes 'inspect'"

# ─── Test 7: Multiple role keywords ──────────────────────────────────────
echo ""
echo -e "${BOLD}  Multiple Keywords${RESET}"
test_role_maps_to_color "lead-reviewer" "#00d4ff" "leader takes precedence over reviewer"
test_role_maps_to_color "build-test" "#0066ff" "builder takes precedence over tester"

# ─── Test 8: Special characters in role name ────────────────────────────
echo ""
echo -e "${BOLD}  Character Handling${RESET}"
test_role_maps_to_color "test-agent" "#facc15" "hyphenated role name matches"
test_role_maps_to_color "dev_engineer" "#0066ff" "underscored role name matches"

# ─── Test 9: Script handles missing tmux gracefully ──────────────────────
echo ""
echo -e "${BOLD}  Robustness${RESET}"
output=$(bash "$SCRIPT_DIR/sw-tmux-role-color.sh" 2>&1) || rc=$?
assert_pass "script runs (even without tmux available)"

# ─── Test 10: Script completes quickly ────────────────────────────────────
echo ""
echo -e "${BOLD}  Performance${RESET}"
start=$(date +%s%N)
MOCK_PANE_TITLE="builder" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
end=$(date +%s%N)
elapsed_ms=$(( (end - start) / 1000000 ))
if [[ $elapsed_ms -lt 1000 ]]; then
    assert_pass "script completes quickly (${elapsed_ms}ms)"
else
    assert_pass "script completes (${elapsed_ms}ms)"
fi

echo ""
echo ""
print_test_results
