#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright-file-suggest-test.sh — Test Suite for File Suggestions       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "shipwright-file-suggest-test.sh"

# ─── Setup & teardown ───────────────────────────────────────────────────────
setup_test_env "shipwright-file-suggest"

# Create a minimal fixture git repo
setup_fixture_git_repo() {
    local repo="$TEST_TEMP_DIR/fixture-repo"
    mkdir -p "$repo/.claude/agents" "$repo/schemas" "$repo/.claude/pipeline-artifacts"

    # Initialize git
    cd "$repo"
    git init >/dev/null 2>&1
    git config user.email "test@test.com"
    git config user.name "Test User"

    # Create core config files
    touch "$repo/.claude/pipeline-state.md"
    touch "$repo/.claude/daemon-config.json"
    touch "$repo/.claude/fleet-config.json"
    touch "$repo/.claude/loop-state.md"
    touch "$repo/.claude/managed-mcp.json"
    touch "$repo/.claude/settings.json"
    touch "$repo/.claude/CLAUDE.md"
    touch "$repo/CLAUDE.md"
    touch "$repo/CHANGELOG.md"

    # Create agent definitions
    touch "$repo/.claude/agents/builder.md"
    touch "$repo/.claude/agents/reviewer.md"

    # Create schemas
    touch "$repo/schemas/event-schema.json"
    touch "$repo/schemas/pipeline-schema.json"

    # Create pipeline artifacts
    touch "$repo/.claude/pipeline-artifacts/plan.md"
    touch "$repo/.claude/pipeline-artifacts/design.md"
    touch "$repo/.claude/pipeline-artifacts/composed-pipeline.json"

    # Create loop logs
    mkdir -p "$repo/.claude/loop-logs"
    touch "$repo/.claude/loop-logs/iteration-001.log"
    touch "$repo/.claude/loop-logs/iteration-002.log"
    touch "$repo/.claude/loop-logs/iteration-003.log"

    # Stage and commit
    git add . >/dev/null 2>&1
    git commit -m "initial" >/dev/null 2>&1

    echo "$repo"
}

# ─── Test: script runs without error ──────────────────────────────────────
test_script_runs() {
    local repo; repo=$(setup_fixture_git_repo)
    cd "$repo"

    bash "$SCRIPT_DIR/shipwright-file-suggest.sh" >/dev/null 2>&1
    assert_pass "script runs without error"
}

# ─── Test: suggests pipeline state file ──────────────────────────────────
test_suggests_pipeline_state() {
    local repo; repo=$(setup_fixture_git_repo)
    cd "$repo"

    local output; output=$(bash "$SCRIPT_DIR/shipwright-file-suggest.sh" 2>&1)

    if echo "$output" | grep -q ".claude/pipeline-state.md"; then
        assert_pass "suggests pipeline-state.md"
    else
        assert_fail "suggests pipeline-state.md"
    fi
}

# ─── Test: suggests daemon config ──────────────────────────────────────
test_suggests_daemon_config() {
    local repo; repo=$(setup_fixture_git_repo)
    cd "$repo"

    local output; output=$(bash "$SCRIPT_DIR/shipwright-file-suggest.sh" 2>&1)

    if echo "$output" | grep -q ".claude/daemon-config.json"; then
        assert_pass "suggests daemon-config.json"
    else
        assert_fail "suggests daemon-config.json"
    fi
}

# ─── Test: suggests agent definitions ──────────────────────────────────
test_suggests_agent_defs() {
    local repo; repo=$(setup_fixture_git_repo)
    cd "$repo"

    local output; output=$(bash "$SCRIPT_DIR/shipwright-file-suggest.sh" 2>&1)

    if echo "$output" | grep -q ".claude/agents/.*\.md"; then
        assert_pass "suggests agent definition files"
    else
        assert_fail "suggests agent definition files"
    fi
}

# ─── Test: suggests schemas ──────────────────────────────────────────────
test_suggests_schemas() {
    local repo; repo=$(setup_fixture_git_repo)
    cd "$repo"

    local output; output=$(bash "$SCRIPT_DIR/shipwright-file-suggest.sh" 2>&1)

    if echo "$output" | grep -q "schemas/.*\.json"; then
        assert_pass "suggests schema files"
    else
        assert_fail "suggests schema files"
    fi
}

# ─── Test: suggests pipeline artifacts ──────────────────────────────────
test_suggests_pipeline_artifacts() {
    local repo; repo=$(setup_fixture_git_repo)
    cd "$repo"

    local output; output=$(bash "$SCRIPT_DIR/shipwright-file-suggest.sh" 2>&1)

    if echo "$output" | grep -qE ".claude/pipeline-artifacts/(plan|design|composed)"; then
        assert_pass "suggests pipeline artifact files"
    else
        assert_fail "suggests pipeline artifact files"
    fi
}

# ─── Test: suggests recent loop logs ──────────────────────────────────
test_suggests_loop_logs() {
    local repo; repo=$(setup_fixture_git_repo)
    cd "$repo"

    local output; output=$(bash "$SCRIPT_DIR/shipwright-file-suggest.sh" 2>&1)

    if echo "$output" | grep -q ".claude/loop-logs/iteration-"; then
        assert_pass "suggests recent loop log files"
    else
        assert_fail "suggests recent loop log files"
    fi
}

# ─── Test: handles missing directories gracefully ──────────────────────────
test_handles_missing_dirs() {
    local repo="$TEST_TEMP_DIR/minimal-repo"
    mkdir -p "$repo"
    cd "$repo"
    git init >/dev/null 2>&1
    git config user.email "test@test.com"
    git config user.name "Test User"

    # Create minimal setup
    touch "$repo/CLAUDE.md"
    git add . >/dev/null 2>&1
    git commit -m "initial" >/dev/null 2>&1

    bash "$SCRIPT_DIR/shipwright-file-suggest.sh" >/dev/null 2>&1
    assert_pass "handles missing optional directories gracefully"
}

# ─── Test: excludes non-existent files ──────────────────────────────────
test_excludes_missing_files() {
    local repo; repo=$(setup_fixture_git_repo)
    cd "$repo"

    # Remove a file
    rm "$repo/.claude/fleet-config.json"

    local output; output=$(bash "$SCRIPT_DIR/shipwright-file-suggest.sh" 2>&1)

    if ! echo "$output" | grep -q ".claude/fleet-config.json"; then
        assert_pass "excludes non-existent files"
    else
        assert_fail "excludes non-existent files"
    fi
}

# ─── Test: handles non-git directories ──────────────────────────────────
test_handles_non_git() {
    local repo="$TEST_TEMP_DIR/non-git"
    mkdir -p "$repo"
    cd "$repo"

    # No git repo
    touch "$repo/CLAUDE.md"

    # Should fallback to '.'
    bash "$SCRIPT_DIR/shipwright-file-suggest.sh" >/dev/null 2>&1
    assert_pass "handles non-git directories (fallback to '.')"
}

# ─── Test: outputs one file per line ──────────────────────────────────
test_output_format() {
    local repo; repo=$(setup_fixture_git_repo)
    cd "$repo"

    local output; output=$(bash "$SCRIPT_DIR/shipwright-file-suggest.sh" 2>&1)
    local count; count=$(echo "$output" | wc -l | tr -d ' ')

    if [[ $count -gt 0 ]]; then
        assert_pass "outputs one file per line (got $count lines)"
    else
        assert_fail "outputs one file per line"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
test_script_runs
test_suggests_pipeline_state
test_suggests_daemon_config
test_suggests_agent_defs
test_suggests_schemas
test_suggests_pipeline_artifacts
test_suggests_loop_logs
test_handles_missing_dirs
test_excludes_missing_files
test_handles_non_git
test_output_format

cleanup_test_env
print_test_results
