#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-status-test.sh — Validate pipeline/agent status widgets         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/sw-tmux-status.sh"

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
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tmux-status-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright/heartbeats"
    mkdir -p "$TEMP_DIR/work/.claude"
    export HOME="$TEMP_DIR/home"
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

write_state() {
    local stage="$1"
    cat > "$TEMP_DIR/work/.claude/pipeline-state.md" <<EOF
# Pipeline State
**Current Stage:** ${stage}
EOF
}

run_widget() {
    local mode="$1"
    (cd "$TEMP_DIR/work" && bash "$SCRIPT_UNDER_TEST" "$mode" 2>/dev/null) || true
}

# ─── Tests ───────────────────────────────────────────────────────────────────

test_no_state_file_empty_output() {
    rm -f "$TEMP_DIR/work/.claude/pipeline-state.md"
    local out
    out=$(run_widget pipeline)
    [[ -z "$out" ]]
}

test_build_stage_shows_blue_and_gear() {
    write_state "build"
    local out
    out=$(run_widget pipeline)
    [[ "$out" == *"#0066ff"* ]] || return 1
    [[ "$out" == *"⚙"* ]] || return 1
    [[ "$out" == *"BUILD"* ]] || return 1
}

test_test_stage_yellow() {
    write_state "test"
    local out; out=$(run_widget pipeline)
    [[ "$out" == *"#facc15"* ]] && [[ "$out" == *"TEST"* ]]
}

test_review_stage_orange() {
    write_state "review"
    local out; out=$(run_widget pipeline)
    [[ "$out" == *"#f97316"* ]] && [[ "$out" == *"REVIEW"* ]]
}

test_plan_stage_purple() {
    write_state "plan"
    local out; out=$(run_widget pipeline)
    [[ "$out" == *"#7c3aed"* ]] && [[ "$out" == *"PLAN"* ]]
}

test_pr_stage_cyan() {
    write_state "pr"
    local out; out=$(run_widget pipeline)
    [[ "$out" == *"#00d4ff"* ]] && [[ "$out" == *"PR"* ]]
}

test_deploy_stage_green() {
    write_state "deploy"
    local out; out=$(run_widget pipeline)
    [[ "$out" == *"#4ade80"* ]] && [[ "$out" == *"DEPLOY"* ]]
}

test_intake_stage_muted() {
    write_state "intake"
    local out; out=$(run_widget pipeline)
    [[ "$out" == *"#71717a"* ]] && [[ "$out" == *"INTAKE"* ]]
}

test_compound_quality_stage() {
    write_state "compound_quality"
    local out; out=$(run_widget pipeline)
    [[ "$out" == *"#f97316"* ]] && [[ "$out" == *"COMPOUND_QUALITY"* ]]
}

test_agent_widget_no_heartbeat_dir() {
    rm -rf "$HOME/.shipwright/heartbeats"
    local out; out=$(run_widget agents)
    [[ -z "$out" ]]
}

test_agent_widget_empty_heartbeats() {
    mkdir -p "$HOME/.shipwright/heartbeats"
    rm -f "$HOME/.shipwright/heartbeats/"*.json 2>/dev/null || true
    local out; out=$(run_widget agents)
    [[ -z "$out" ]]
}

test_agent_widget_counts_fresh_heartbeats() {
    mkdir -p "$HOME/.shipwright/heartbeats"
    echo "{}" > "$HOME/.shipwright/heartbeats/a.json"
    echo "{}" > "$HOME/.shipwright/heartbeats/b.json"
    echo "{}" > "$HOME/.shipwright/heartbeats/c.json"
    local out; out=$(run_widget agents)
    [[ "$out" == *"λ3"* ]]
}

test_agent_widget_ignores_stale_heartbeats() {
    mkdir -p "$HOME/.shipwright/heartbeats"
    rm -f "$HOME/.shipwright/heartbeats/"*.json
    echo "{}" > "$HOME/.shipwright/heartbeats/old.json"
    # Set mtime to 5 minutes ago — beyond 60s freshness window
    touch -d "5 minutes ago" "$HOME/.shipwright/heartbeats/old.json" 2>/dev/null \
        || touch -t "$(date -d '5 minutes ago' +%Y%m%d%H%M.%S 2>/dev/null || echo 202001010000)" \
                 "$HOME/.shipwright/heartbeats/old.json" 2>/dev/null || true
    local out; out=$(run_widget agents)
    [[ "$out" != *"λ"* ]]
}

test_all_widget_combines() {
    write_state "build"
    mkdir -p "$HOME/.shipwright/heartbeats"
    rm -f "$HOME/.shipwright/heartbeats/"*.json
    echo "{}" > "$HOME/.shipwright/heartbeats/x.json"
    local out; out=$(run_widget all)
    [[ "$out" == *"λ1"* ]] || return 1
    [[ "$out" == *"BUILD"* ]] || return 1
}

test_unknown_command_empty() {
    local out; out=$(run_widget bogus-mode)
    [[ -z "$out" ]]
}

test_walks_up_to_find_state() {
    write_state "build"
    mkdir -p "$TEMP_DIR/work/deep/nested/dir"
    local out
    out=$(cd "$TEMP_DIR/work/deep/nested/dir" && bash "$SCRIPT_UNDER_TEST" pipeline 2>/dev/null) || true
    [[ "$out" == *"BUILD"* ]]
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    echo -e "${CYAN}━━━ sw-tmux-status tests ━━━${RESET}"
    setup_env

    run_test "no state file → empty output"            test_no_state_file_empty_output
    run_test "build stage → blue + gear icon"          test_build_stage_shows_blue_and_gear
    run_test "test stage → yellow"                     test_test_stage_yellow
    run_test "review stage → orange"                   test_review_stage_orange
    run_test "plan stage → purple"                     test_plan_stage_purple
    run_test "pr stage → cyan"                         test_pr_stage_cyan
    run_test "deploy stage → green"                    test_deploy_stage_green
    run_test "intake stage → muted"                    test_intake_stage_muted
    run_test "compound_quality stage"                  test_compound_quality_stage
    run_test "agent widget: no hb dir → empty"         test_agent_widget_no_heartbeat_dir
    run_test "agent widget: empty hb dir → empty"      test_agent_widget_empty_heartbeats
    run_test "agent widget: counts fresh heartbeats"   test_agent_widget_counts_fresh_heartbeats
    run_test "agent widget: ignores stale heartbeats"  test_agent_widget_ignores_stale_heartbeats
    run_test "all mode: combines both widgets"         test_all_widget_combines
    run_test "unknown command → empty"                 test_unknown_command_empty
    run_test "walks up dirs to find pipeline-state"    test_walks_up_to_find_state

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
