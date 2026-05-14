#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-role-color-test.sh — Validate pane border color by agent role   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/sw-tmux-role-color.sh"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tmux-role-color-test.XXXXXX")
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/home/.shipwright"

    # Mock tmux: emits configured PANE_TITLE for display-message,
    # logs `set` calls so we can assert which color was applied.
    cat > "$TEMP_DIR/bin/tmux" <<'TMUX_EOF'
#!/usr/bin/env bash
LOG="${TMUX_LOG:-/dev/null}"
echo "$@" >> "$LOG"
case "${1:-}" in
    display-message)
        # Emit the configured pane title (default empty)
        echo "${MOCK_PANE_TITLE:-}"
        ;;
    set)
        # Log just the value of pane-active-border-style
        for arg in "$@"; do
            case "$arg" in
                fg=*|*fg=*) echo "STYLE: $arg" >> "$LOG" ;;
            esac
        done
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
TMUX_EOF
    chmod +x "$TEMP_DIR/bin/tmux"

    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export TMUX_LOG="$TEMP_DIR/tmux.log"
}

cleanup_env() {
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))
    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    : > "$TMUX_LOG"
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

# Run the script with MOCK_PANE_TITLE set, return color applied.
run_with_title() {
    local title="$1"
    MOCK_PANE_TITLE="$title" bash "$SCRIPT_UNDER_TEST" 2>/dev/null || true
    grep -oE 'fg=#[0-9a-f]{6}' "$TMUX_LOG" | head -1 | cut -d= -f2
}

assert_color() {
    local title="$1" expected="$2"
    local got
    got=$(run_with_title "$title")
    [[ "$got" == "$expected" ]] || { echo "  title='$title' expected=$expected got=$got" >&2; return 1; }
}

# ─── Tests ───────────────────────────────────────────────────────────────────

test_leader_to_cyan()       { assert_color "team-leader"     "#00d4ff"; }
test_pm_to_cyan()           { assert_color "claude-pm"       "#00d4ff"; }
test_builder_to_blue()      { assert_color "builder-1"       "#0066ff"; }
test_dev_to_blue()          { assert_color "dev-agent"       "#0066ff"; }
test_reviewer_to_orange()   { assert_color "reviewer-1"      "#f97316"; }
test_audit_to_orange()      { assert_color "audit-bot"       "#f97316"; }
test_tester_to_yellow()     { assert_color "tester"          "#facc15"; }
test_qa_to_yellow()         { assert_color "qa-team"         "#facc15"; }
test_security_to_red()      { assert_color "security-team"   "#ef4444"; }
test_docs_to_violet()       { assert_color "docs-writer"     "#a78bfa"; }
test_optimizer_to_green()   { assert_color "optimizer"       "#4ade80"; }
test_deploy_to_green()      { assert_color "deploy-agent"    "#4ade80"; }
test_research_to_purple()   { assert_color "researcher"      "#7c3aed"; }
test_unknown_to_cyan()      { assert_color "random-thing"    "#00d4ff"; }
test_empty_title_default()  { assert_color ""                "#00d4ff"; }

test_case_insensitive() {
    # uppercase should still match
    local got
    got=$(run_with_title "BUILDER-CAPS")
    [[ "$got" == "#0066ff" ]]
}

test_sets_bg_color() {
    MOCK_PANE_TITLE="builder" bash "$SCRIPT_UNDER_TEST" 2>/dev/null || true
    grep -q "bg=#1a1a2e" "$TMUX_LOG"
}

test_tmux_set_invoked() {
    MOCK_PANE_TITLE="reviewer" bash "$SCRIPT_UNDER_TEST" 2>/dev/null || true
    grep -q "pane-active-border-style" "$TMUX_LOG"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    echo -e "${CYAN}━━━ sw-tmux-role-color tests ━━━${RESET}"
    setup_env

    run_test "leader title → cyan"            test_leader_to_cyan
    run_test "pm title → cyan"                test_pm_to_cyan
    run_test "builder title → blue"           test_builder_to_blue
    run_test "dev title → blue"               test_dev_to_blue
    run_test "reviewer title → orange"        test_reviewer_to_orange
    run_test "audit title → orange"           test_audit_to_orange
    run_test "tester title → yellow"          test_tester_to_yellow
    run_test "qa title → yellow"              test_qa_to_yellow
    run_test "security title → red"           test_security_to_red
    run_test "docs title → violet"            test_docs_to_violet
    run_test "optimizer title → green"        test_optimizer_to_green
    run_test "deploy title → green"           test_deploy_to_green
    run_test "research title → purple"        test_research_to_purple
    run_test "unknown title → default cyan"   test_unknown_to_cyan
    run_test "empty title → default cyan"     test_empty_title_default
    run_test "case-insensitive match"         test_case_insensitive
    run_test "background color applied"       test_sets_bg_color
    run_test "tmux set invoked correctly"     test_tmux_set_invoked

    echo
    echo -e "${CYAN}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}PASS${RESET}: $PASS / $TOTAL"
    if [[ $FAIL -gt 0 ]]; then
        echo -e "  ${RED}FAIL${RESET}: $FAIL"
        for f in "${FAILURES[@]}"; do echo -e "    ${RED}✗${RESET} $f"; done
        exit 1
    fi
    exit 0
}

main "$@"
