#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-tmux-status-test.sh — Test status bar widgets for tmux               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-tmux-status Test Suite"

setup_test_env "sw-tmux-status-test"
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

# Copy script under test and dependencies
mkdir -p "$TEST_TEMP_DIR/scripts/lib"
mkdir -p "$TEST_TEMP_DIR/.claude"
mkdir -p "$TEST_TEMP_DIR/.shipwright/heartbeats"
cp "$SCRIPT_DIR/sw-tmux-status.sh" "$TEST_TEMP_DIR/scripts/"
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && cp "$SCRIPT_DIR/lib/compat.sh" "$TEST_TEMP_DIR/scripts/lib/"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && cp "$SCRIPT_DIR/lib/helpers.sh" "$TEST_TEMP_DIR/scripts/lib/"

# Create mock binaries for stat/date
mkdir -p "$TEST_TEMP_DIR/bin"
cat > "$TEST_TEMP_DIR/bin/stat" <<'STAT_MOCK'
#!/usr/bin/env bash
# Mock stat for file modification time
if [[ "${1:-}" == "-c" && "${2:-}" == "%Y" ]]; then
    # Return MOCK_STAT_TIME if set (for testing age calculations)
    [[ -n "${MOCK_STAT_TIME:-}" ]] && echo "$MOCK_STAT_TIME" || echo "$(($(date +%s) - 30))"
fi
exit 0
STAT_MOCK
chmod +x "$TEST_TEMP_DIR/bin/stat"

# Create test state file
cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
# Pipeline State

**Current Stage:** build

## Progress
- [x] intake
- [x] plan
- [ ] design
EOF

# Create mock heartbeat files (fresh and stale)
for i in {1..3}; do
    echo '{"job_id":"test-'$i'","ts":"2026-03-15T12:00:00Z"}' > "$TEST_TEMP_DIR/.shipwright/heartbeats/agent-$i.json"
    # Use touch to set mtime to 30 seconds ago (fresh)
    touch -t "$(date -d '30 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null || date -v-30S +%Y%m%d%H%M.%S)" "$TEST_TEMP_DIR/.shipwright/heartbeats/agent-$i.json" 2>/dev/null || true
done

# Create stale heartbeat files (120 seconds ago)
for i in {4..5}; do
    echo '{"job_id":"test-'$i'","ts":"2026-03-15T11:58:00Z"}' > "$TEST_TEMP_DIR/.shipwright/heartbeats/agent-stale-$i.json"
    touch -t "$(date -d '120 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null || date -v-120S +%Y%m%d%H%M.%S)" "$TEST_TEMP_DIR/.shipwright/heartbeats/agent-stale-$i.json" 2>/dev/null || true
done

# Source the script under test
export SCRIPT_DIR="$TEST_TEMP_DIR/scripts"
export HOME="$TEST_TEMP_DIR"
export PATH="$TEST_TEMP_DIR/bin:$PATH"
source "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Stage Color Mapping"

# Test: stage_color function for each stage
test_stage_color_intake() {
    local result
    result=$(stage_color "intake")
    [[ "$result" == "#71717a" ]] && return 0 || { echo "Expected #71717a, got $result"; return 1; }
}

test_stage_color_plan() {
    local result
    result=$(stage_color "plan")
    [[ "$result" == "#7c3aed" ]] && return 0 || { echo "Expected #7c3aed, got $result"; return 1; }
}

test_stage_color_build() {
    local result
    result=$(stage_color "build")
    [[ "$result" == "#0066ff" ]] && return 0 || { echo "Expected #0066ff, got $result"; return 1; }
}

test_stage_color_test() {
    local result
    result=$(stage_color "test")
    [[ "$result" == "#facc15" ]] && return 0 || { echo "Expected #facc15, got $result"; return 1; }
}

test_stage_color_deploy() {
    local result
    result=$(stage_color "deploy")
    [[ "$result" == "#4ade80" ]] && return 0 || { echo "Expected #4ade80, got $result"; return 1; }
}

test_stage_color_unknown() {
    local result
    result=$(stage_color "unknown-stage-xyz")
    [[ "$result" == "#71717a" ]] && return 0 || { echo "Expected #71717a fallback, got $result"; return 1; }
}

print_test_section "Stage Icon Mapping"

# Test: stage_icon function for each stage
test_stage_icon_intake() {
    local result
    result=$(stage_icon "intake")
    [[ "$result" == "◇" ]] && return 0 || { echo "Expected ◇, got $result"; return 1; }
}

test_stage_icon_build() {
    local result
    result=$(stage_icon "build")
    [[ "$result" == "⚙" ]] && return 0 || { echo "Expected ⚙, got $result"; return 1; }
}

test_stage_icon_test() {
    local result
    result=$(stage_icon "test")
    [[ "$result" == "⚡" ]] && return 0 || { echo "Expected ⚡, got $result"; return 1; }
}

test_stage_icon_unknown() {
    local result
    result=$(stage_icon "unknown-stage-xyz")
    [[ "$result" == "·" ]] && return 0 || { echo "Expected · fallback, got $result"; return 1; }
}

print_test_section "Pipeline Widget"

# Test: pipeline_widget extracts stage from state file
test_pipeline_widget_extracts_stage() {
    local output
    output=$(pipeline_widget)
    # Should output tmux format string with BUILD stage
    if [[ "$output" =~ "BUILD" ]] && [[ "$output" =~ "#0066ff" ]]; then
        return 0
    fi
    echo "Expected pipeline widget with BUILD stage, got: $output"
    return 1
}

# Test: pipeline_widget missing state file
test_pipeline_widget_missing_state_file() {
    local output
    rm -f "$TEST_TEMP_DIR/.claude/pipeline-state.md"
    output=$(pipeline_widget) || true
    # Should return empty string
    [[ -z "$output" ]] && return 0 || { echo "Expected empty output for missing state file, got: $output"; return 1; }
}

# Test: pipeline_widget outputs tmux format
test_pipeline_widget_tmux_format() {
    # Recreate state file
    cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
**Current Stage:** deploy
EOF
    local output
    output=$(pipeline_widget)
    # Should contain tmux color codes and format
    if [[ "$output" =~ "#\\[" ]]; then
        return 0
    fi
    echo "Expected tmux format string, got: $output"
    return 1
}

print_test_section "Agent Widget"

# Test: agent_widget counts fresh heartbeats
test_agent_widget_counts_fresh_heartbeats() {
    local output
    output=$(agent_widget)
    # Should show λ3 for 3 fresh heartbeats
    if [[ "$output" =~ "λ3" ]]; then
        return 0
    fi
    echo "Expected agent widget with λ3, got: $output"
    return 1
}

# Test: agent_widget ignores stale heartbeats
test_agent_widget_ignores_stale() {
    local output
    output=$(agent_widget)
    # Should NOT count the 2 stale heartbeats
    if [[ ! "$output" =~ "λ5" ]] && [[ "$output" =~ "λ3" ]]; then
        return 0
    fi
    echo "Expected to ignore stale heartbeats, got: $output"
    return 1
}

# Test: agent_widget with no heartbeats
test_agent_widget_no_heartbeats() {
    rm -rf "$TEST_TEMP_DIR/.shipwright/heartbeats"
    mkdir -p "$TEST_TEMP_DIR/.shipwright/heartbeats"
    local output
    output=$(agent_widget) || true
    # Should return empty string
    [[ -z "$output" ]] && return 0 || { echo "Expected empty output for no heartbeats, got: $output"; return 1; }
}

print_test_section "Widget Dispatch"

# Test: dispatch "pipeline" argument
test_dispatch_pipeline_argument() {
    # Recreate state file
    mkdir -p "$TEST_TEMP_DIR/.claude"
    cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
**Current Stage:** build
EOF
    local output
    output=$(
        HOME="$TEST_TEMP_DIR" \
        bash -c 'source '"$TEST_TEMP_DIR/scripts/sw-tmux-status.sh"'; pipeline_widget'
    ) || true
    if [[ -n "$output" ]]; then
        return 0
    fi
    echo "Expected non-empty output for pipeline dispatch, got: $output"
    return 1
}

# Test: dispatch "all" argument combines both
test_dispatch_all_argument() {
    local output
    output=$(
        HOME="$TEST_TEMP_DIR" \
        bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" all 2>&1
    ) || true
    # Should contain both pipeline and agent info (or just pipeline if no agents)
    [[ -n "$output" ]] && return 0 || { echo "Expected non-empty output for all dispatch, got: $output"; return 1; }
}

# Test: dispatch with no arguments defaults to pipeline
test_dispatch_no_argument_defaults_pipeline() {
    mkdir -p "$TEST_TEMP_DIR/.claude"
    cat > "$TEST_TEMP_DIR/.claude/pipeline-state.md" <<'EOF'
**Current Stage:** build
EOF
    local output
    output=$(
        HOME="$TEST_TEMP_DIR" \
        bash "$TEST_TEMP_DIR/scripts/sw-tmux-status.sh" 2>&1
    ) || true
    [[ -n "$output" ]] && return 0 || { echo "Expected non-empty output for default dispatch, got: $output"; return 1; }
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

run_test "stage_color: intake → #71717a" test_stage_color_intake
run_test "stage_color: plan → #7c3aed" test_stage_color_plan
run_test "stage_color: build → #0066ff" test_stage_color_build
run_test "stage_color: test → #facc15" test_stage_color_test
run_test "stage_color: deploy → #4ade80" test_stage_color_deploy
run_test "stage_color: unknown → fallback" test_stage_color_unknown

run_test "stage_icon: intake → ◇" test_stage_icon_intake
run_test "stage_icon: build → ⚙" test_stage_icon_build
run_test "stage_icon: test → ⚡" test_stage_icon_test
run_test "stage_icon: unknown → fallback" test_stage_icon_unknown

run_test "pipeline_widget: extracts stage" test_pipeline_widget_extracts_stage
run_test "pipeline_widget: missing state file" test_pipeline_widget_missing_state_file
run_test "pipeline_widget: tmux format" test_pipeline_widget_tmux_format

run_test "agent_widget: counts fresh heartbeats" test_agent_widget_counts_fresh_heartbeats
run_test "agent_widget: ignores stale heartbeats" test_agent_widget_ignores_stale
run_test "agent_widget: no heartbeats" test_agent_widget_no_heartbeats

run_test "dispatch: pipeline argument" test_dispatch_pipeline_argument
run_test "dispatch: all argument" test_dispatch_all_argument
run_test "dispatch: no argument defaults to pipeline" test_dispatch_no_argument_defaults_pipeline

print_test_results

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
