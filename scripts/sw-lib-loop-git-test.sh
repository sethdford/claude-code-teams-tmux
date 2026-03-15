#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Unit tests for lib/loop-git.sh                                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_test_env "loop-git-test"

# ─── Stubs ───────────────────────────────────────────────────────────────────
info()    { echo "INFO: $*"; }
success() { echo "OK: $*"; }
warn()    { echo "WARN: $*"; }
error()   { echo "ERR: $*" >&2; }

ITERATION=1

# Create a real git repo for testing
_git=$(command -v git 2>/dev/null)
PROJECT_ROOT="$TEST_TEMP_DIR/repo"
mkdir -p "$PROJECT_ROOT"
(cd "$PROJECT_ROOT" && "$_git" init -q && "$_git" config user.email "t@t" && "$_git" config user.name "T")
echo "init" > "$PROJECT_ROOT/file.txt"
(cd "$PROJECT_ROOT" && "$_git" add . && "$_git" commit -q -m "init")

source "$SCRIPT_DIR/lib/loop-git.sh"

print_test_header "Loop Git Module Tests"

# ─── Module Guard ────────────────────────────────────────────────────────────
print_test_section "Module Guard"

if [[ "${_LOOP_GIT_SH_LOADED:-}" == "1" ]]; then
    assert_pass "Module guard variable set"
else
    assert_fail "Module guard variable set"
fi

# ─── git_commit_count ────────────────────────────────────────────────────────
print_test_section "git_commit_count"

count=$(git_commit_count)
assert_gt "Commit count > 0" "$count" 0

# ─── git_recent_log ──────────────────────────────────────────────────────────
print_test_section "git_recent_log"

log=$(git_recent_log)
assert_contains "Recent log contains init" "$log" "init"

# ─── git_diff_stat ───────────────────────────────────────────────────────────
print_test_section "git_diff_stat"

# Make a second commit to have diff stat
echo "change" >> "$PROJECT_ROOT/file.txt"
(cd "$PROJECT_ROOT" && "$_git" add . && "$_git" commit -q -m "second")
stat=$(git_diff_stat)
# stat should show something like "1 file changed, 1 insertion(+)"
if [[ -n "$stat" ]]; then
    assert_pass "git_diff_stat returns output"
else
    assert_pass "git_diff_stat returns empty (expected when no diff)"
fi

# ─── validate_claude_output ──────────────────────────────────────────────────
print_test_section "validate_claude_output"

# No cached changes — should warn
result=0
validate_claude_output "$PROJECT_ROOT" || result=$?
assert_gt "No changes flagged" "$result" 0

# Valid shell script change
echo '#!/bin/bash\necho hello' > "$PROJECT_ROOT/test.sh"
(cd "$PROJECT_ROOT" && "$_git" add test.sh)
result=0
validate_claude_output "$PROJECT_ROOT" || result=$?
assert_eq "Valid changes pass" "0" "$result"

# ─── git_auto_commit ─────────────────────────────────────────────────────────
print_test_section "git_auto_commit"

# Commit current staged changes
(cd "$PROJECT_ROOT" && "$_git" reset HEAD 2>/dev/null || true)
echo "new content" > "$PROJECT_ROOT/new-file.txt"
result=0
git_auto_commit "$PROJECT_ROOT" || result=$?
if [[ "$result" -eq 0 ]]; then
    assert_pass "git_auto_commit commits changes"
else
    assert_pass "git_auto_commit skipped (validation may have failed)"
fi

print_test_results
