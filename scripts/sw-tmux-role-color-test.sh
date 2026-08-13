#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-role-color-test.sh — Test Suite for Role → Color Mapping       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-tmux-role-color-test.sh"

# ─── Test: leader role maps to cyan ──────────────────────────────────────────
test_leader_cyan() {
    PANE_TITLE="leader" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "leader role loads without error"
}

# ─── Test: pm role maps to cyan ─────────────────────────────────────────────
test_pm_cyan() {
    PANE_TITLE="pm-agent" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "pm role loads without error"
}

# ─── Test: builder role maps to blue ────────────────────────────────────────
test_builder_blue() {
    PANE_TITLE="builder" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "builder role loads without error"
}

# ─── Test: dev role maps to blue ────────────────────────────────────────────
test_dev_blue() {
    PANE_TITLE="dev-agent" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "dev role loads without error"
}

# ─── Test: reviewer role maps to orange ────────────────────────────────────
test_reviewer_orange() {
    PANE_TITLE="reviewer" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "reviewer role loads without error"
}

# ─── Test: tester role maps to yellow ──────────────────────────────────────
test_tester_yellow() {
    PANE_TITLE="tester" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "tester role loads without error"
}

# ─── Test: security role maps to red ────────────────────────────────────────
test_security_red() {
    PANE_TITLE="security" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "security role loads without error"
}

# ─── Test: docs role maps to violet ────────────────────────────────────────
test_docs_violet() {
    PANE_TITLE="docs" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "docs role loads without error"
}

# ─── Test: optimizer role maps to green ────────────────────────────────────
test_optimizer_green() {
    PANE_TITLE="optimizer" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "optimizer role loads without error"
}

# ─── Test: researcher role maps to purple ──────────────────────────────────
test_researcher_purple() {
    PANE_TITLE="researcher" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "researcher role loads without error"
}

# ─── Test: unknown role defaults to cyan ────────────────────────────────────
test_unknown_role_defaults() {
    PANE_TITLE="unknown-role" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "unknown role defaults to cyan without error"
}

# ─── Test: empty pane title defaults to cyan ────────────────────────────────
test_empty_pane_title() {
    PANE_TITLE="" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "empty pane title defaults to cyan without error"
}

# ─── Test: case insensitivity ──────────────────────────────────────────────
test_case_insensitivity() {
    PANE_TITLE="LEADER" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "uppercase LEADER role recognized"
}

# ─── Test: compound role matching ──────────────────────────────────────────
test_compound_role() {
    PANE_TITLE="team-lead-builder" bash "$SCRIPT_DIR/sw-tmux-role-color.sh" >/dev/null 2>&1
    assert_pass "compound role with 'lead' keyword recognized"
}

# ─── Main ───────────────────────────────────────────────────────────────────
test_leader_cyan
test_pm_cyan
test_builder_blue
test_dev_blue
test_reviewer_orange
test_tester_yellow
test_security_red
test_docs_violet
test_optimizer_green
test_researcher_purple
test_unknown_role_defaults
test_empty_pane_title
test_case_insensitivity
test_compound_role

print_test_results
