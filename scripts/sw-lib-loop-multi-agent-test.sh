#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Unit tests for lib/loop-multi-agent.sh                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "loop-multi-agent-test"

# ─── Stubs ───────────────────────────────────────────────────────────────────
info()    { echo "INFO: $*"; }
success() { echo "OK: $*"; }
warn()    { echo "WARN: $*"; }
error()   { echo "ERR: $*" >&2; }
emit_event() { :; }
write_state() { :; }
now_epoch() { date +%s; }
file_mtime() { date +%s; }
_config_get_int() { echo "${2:-0}"; }
compose_prompt() { echo "Base prompt for testing"; }
build_claude_flags() { echo "--model sonnet"; }
sed_i() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

# Colors
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
PURPLE='\033[38;2;124;58;237m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# Globals
AGENTS=2
AGENT_ROLES="builder,tester"
LOG_DIR="$TEST_TEMP_DIR/logs"
GOAL="Test multi-agent goal"
TEST_CMD="true"
MAX_ITERATIONS=5
SKIP_PERMISSIONS=true
STATUS="running"

# Create a real git repo
_git=$(command -v git 2>/dev/null)
PROJECT_ROOT="$TEST_TEMP_DIR/repo"
WORKTREE_DIR="$PROJECT_ROOT/.worktrees"
mkdir -p "$PROJECT_ROOT" "$LOG_DIR"
(cd "$PROJECT_ROOT" && "$_git" init -q && "$_git" config user.email "t@t" && "$_git" config user.name "T")
echo "init" > "$PROJECT_ROOT/file.txt"
(cd "$PROJECT_ROOT" && "$_git" add . && "$_git" commit -q -m "init")

source "$SCRIPT_DIR/lib/loop-multi-agent.sh"

print_test_header "Loop Multi-Agent Module Tests"

# ─── Module Guard ────────────────────────────────────────────────────────────
print_test_section "Module Guard"

if [[ "${_LOOP_MULTI_AGENT_SH_LOADED:-}" == "1" ]]; then
    assert_pass "Module guard variable set"
else
    assert_fail "Module guard variable set"
fi

# ─── compose_worker_prompt ───────────────────────────────────────────────────
print_test_section "compose_worker_prompt"

output=$(compose_worker_prompt 1 2 2>&1)
assert_contains "Worker prompt has base prompt" "$output" "Base prompt"
assert_contains "Worker prompt has agent identity" "$output" "Agent 1 of 2"
assert_contains "Worker prompt has builder role" "$output" "builder"

output=$(compose_worker_prompt 2 2 2>&1)
assert_contains "Agent 2 has tester role" "$output" "tester"

# No roles
AGENT_ROLES=""
output=$(compose_worker_prompt 1 2 2>&1)
assert_contains "No roles still has identity" "$output" "Agent 1 of 2"
AGENT_ROLES="builder,tester"

# ─── setup_worktrees ────────────────────────────────────────────────────────
print_test_section "setup_worktrees"

result=0
setup_worktrees 2>/dev/null || result=$?
assert_eq "Worktree setup succeeds" "0" "$result"

for i in 1 2; do
    if [[ -d "$WORKTREE_DIR/agent-${i}" ]]; then
        assert_pass "Worktree agent-${i} created"
    else
        assert_fail "Worktree agent-${i} created"
    fi
done

# ─── cleanup_worktrees ──────────────────────────────────────────────────────
print_test_section "cleanup_worktrees"

cleanup_worktrees 2>/dev/null
for i in 1 2; do
    if [[ ! -d "$WORKTREE_DIR/agent-${i}" ]]; then
        assert_pass "Worktree agent-${i} cleaned up"
    else
        assert_fail "Worktree agent-${i} cleaned up"
    fi
done

# ─── generate_worker_script ──────────────────────────────────────────────────
print_test_section "generate_worker_script"

# Re-create worktrees for script generation
setup_worktrees 2>/dev/null || true

worker_path=$(generate_worker_script 1 2 2>/dev/null)
if [[ -f "$worker_path" ]]; then
    assert_pass "Worker script file created"
    if [[ -x "$worker_path" ]]; then
        assert_pass "Worker script is executable"
    else
        assert_fail "Worker script is executable"
    fi
    # Check placeholder replacement
    if ! grep -q '__AGENT_NUM__' "$worker_path"; then
        assert_pass "Placeholders replaced"
    else
        assert_fail "Placeholders replaced"
    fi
else
    assert_fail "Worker script file created" "path: $worker_path"
fi

# ─── cleanup_multi_agent ────────────────────────────────────────────────────
print_test_section "cleanup_multi_agent"

# Create mock completion markers
touch "$LOG_DIR/.agent-1-complete"
touch "$LOG_DIR/.agent-2-complete"
MULTI_WINDOW_NAME=""
cleanup_multi_agent 2>/dev/null
if [[ ! -f "$LOG_DIR/.agent-1-complete" ]]; then
    assert_pass "Completion markers cleaned up"
else
    assert_fail "Completion markers cleaned up"
fi

# Clean up worktrees
cleanup_worktrees 2>/dev/null || true

print_test_results
