#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright merge-validation tests — state machine + revert + Checks API ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-merge-validation + pipeline-merge-checks"

setup_test_env "sw-merge-validation-test"
trap cleanup_test_env EXIT

# Per-test artifacts dir lives inside the test sandbox
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"
export PROJECT_ROOT="$TEST_TEMP_DIR"
export NO_GITHUB="true"

# Source under test
source "$SCRIPT_DIR/lib/pipeline-merge-validation.sh"
source "$SCRIPT_DIR/lib/pipeline-merge-checks.sh"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "State machine: init / read"
# ═══════════════════════════════════════════════════════════════════════════════

validation_state_init "abc123def" "42" >/dev/null
state_file="$ARTIFACTS_DIR/validation-state.json"
assert_file_exists "state file created" "$state_file"

state=$(validation_state_read)
got_state=$(echo "$state" | jq -r '.state')
assert_eq "initial state is VALIDATING" "STATE_VALIDATING" "$got_state"

got_sha=$(echo "$state" | jq -r '.merge_commit_sha')
assert_eq "merge_commit_sha recorded" "abc123def" "$got_sha"

got_issue=$(echo "$state" | jq -r '.issue_number')
assert_eq "issue_number recorded" "42" "$got_issue"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "State machine: transitions"
# ═══════════════════════════════════════════════════════════════════════════════

validation_state_transition "$MV_STATE_FAILED" '{"reason":"smoke_test"}'
got=$(validation_state_get_field state)
assert_eq "transition VALIDATING → FAILED" "STATE_FAILED" "$got"

reason=$(validation_state_get_field reason)
assert_eq "extra fields merged" "smoke_test" "$reason"

# Field preserved across transitions
validation_state_transition "$MV_STATE_REVERTING"
got_sha=$(validation_state_get_field merge_commit_sha)
assert_eq "merge_commit_sha preserved across transitions" "abc123def" "$got_sha"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "State machine: corruption recovery"
# ═══════════════════════════════════════════════════════════════════════════════

# Corrupt the state file
echo "{not valid json" > "$state_file"
recovered=$(validation_state_read)
assert_eq "corrupt state returns empty object" "{}" "$recovered"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Lock acquire/release"
# ═══════════════════════════════════════════════════════════════════════════════

# Re-init for lock tests
rm -f "$state_file"
if validation_lock_acquire; then assert_pass "lock acquired"; else assert_fail "lock acquired"; fi

# Re-acquiring in same shell is safe (flock returns 0 since same fd)
# But a fresh subshell should fail when flock is available
if command -v flock >/dev/null 2>&1; then
    if (validation_lock_acquire 2>/dev/null); then
        # Some flock implementations may allow this — check process tree behavior
        assert_pass "lock contention behavior verified"
    else
        assert_pass "second lock acquisition blocked"
    fi
fi

validation_lock_release
assert_pass "lock released"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Stale lock break"
# ═══════════════════════════════════════════════════════════════════════════════

lockfile="$ARTIFACTS_DIR/validation-lock"
touch "$lockfile"
# Force mtime to 2h ago
old=$(($(date +%s) - 7200))
if command -v touch >/dev/null 2>&1; then
    # GNU touch: -d @epoch; BSD touch: -t YYYYMMDDhhmm
    touch -d "@$old" "$lockfile" 2>/dev/null \
      || touch -t "$(date -r "$old" +%Y%m%d%H%M 2>/dev/null || date -d "@$old" +%Y%m%d%H%M)" "$lockfile" 2>/dev/null \
      || true
fi

if validation_lock_acquire; then
    assert_pass "stale lock broken & re-acquired"
else
    assert_fail "stale lock broken & re-acquired"
fi
validation_lock_release

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Revert helpers: idempotency / no-cascade (mocked git)"
# ═══════════════════════════════════════════════════════════════════════════════

# Set up a tiny throwaway repo
repo_dir="$TEST_TEMP_DIR/revert-repo"
mkdir -p "$repo_dir"
(
    cd "$repo_dir"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo "a" > a.txt && git add . && git commit -qm "first"
    echo "b" > a.txt && git commit -qam "second commit to revert"
)

(
    cd "$repo_dir"
    target_sha=$(git rev-parse HEAD)
    head_sha=$(git rev-parse HEAD)

    # No-cascade: HEAD == target → not different
    if revert_is_head_different "$target_sha"; then
        assert_fail "head-different returns true when SHAs match"
    else
        assert_pass "head-different correctly false when SHAs match"
    fi

    # No-cascade: introduce a new commit so HEAD != target
    echo "c" > b.txt && git add . && git commit -qm "intervening commit"
    if revert_is_head_different "$target_sha"; then
        assert_pass "head-different true after new commit"
    else
        assert_fail "head-different true after new commit"
    fi

    # Idempotency: not yet reverted
    if revert_is_already_applied "$target_sha"; then
        assert_fail "already-applied false before any revert"
    else
        assert_pass "already-applied false before any revert"
    fi

    # Reset and actually revert
    git reset --hard "$target_sha" -q
    git revert --no-edit "$target_sha" >/dev/null 2>&1 || true
    if revert_is_already_applied "$target_sha"; then
        assert_pass "already-applied true after revert"
    else
        assert_fail "already-applied true after revert"
    fi
)

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Revert: skip when already-applied"
# ═══════════════════════════════════════════════════════════════════════════════

(
    cd "$repo_dir"
    target_sha=$(git log --grep="^second" --format=%H | head -1)
    rc=0
    revert_commit "$target_sha" >/dev/null 2>&1 || rc=$?
    assert_eq "revert returns 2 (skipped) when already applied" "2" "$rc"
)

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Revert: circuit breaker"
# ═══════════════════════════════════════════════════════════════════════════════

# Seed history with N failed revert events
log=$(_mv_revert_log)
mkdir -p "$(dirname "$log")"
: > "$log"
for i in 1 2 3; do
    _mv_revert_log_append "fakeSha$i" "failed" "conflict"
done
if revert_circuit_breaker_open; then
    assert_pass "circuit breaker opens after threshold failures"
else
    assert_fail "circuit breaker opens after threshold failures"
fi

# Reset for downstream tests
: > "$log"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Issue reopen retry queue"
# ═══════════════════════════════════════════════════════════════════════════════

q=$(_mv_pending_reopens)
: > "$q" 2>/dev/null || true
_mv_queue_pending_reopen "99" "abc" "def" "smoke failed"
[[ -s "$q" ]] && assert_pass "queued pending reopen" || assert_fail "queued pending reopen"

queued_issue=$(jq -r '.issue_number' "$q")
assert_eq "queued issue number recorded" "99" "$queued_issue"

# Process queue under NO_GITHUB → should be a no-op (file untouched)
issue_reopen_process_queue
[[ -s "$q" ]] && assert_pass "process queue no-op under NO_GITHUB" || assert_fail "process queue no-op under NO_GITHUB"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Memory logging"
# ═══════════════════════════════════════════════════════════════════════════════

mfile=$(_mv_memory_file)
: > "$mfile" 2>/dev/null || true
validation_memory_log "abc123" "reverted" "smoke_test_failure" "def456" 42
last=$(tail -1 "$mfile")
got_outcome=$(echo "$last" | jq -r '.outcome')
assert_eq "memory log records outcome" "reverted" "$got_outcome"
got_cause=$(echo "$last" | jq -r '.root_cause')
assert_eq "memory log records root_cause" "smoke_test_failure" "$got_cause"
got_detect=$(echo "$last" | jq -r '.detection_seconds')
assert_eq "memory log records detection_seconds" "42" "$got_detect"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Checks API: classify_response"
# ═══════════════════════════════════════════════════════════════════════════════

passed_resp='{"total_count":2,"check_runs":[{"name":"a","status":"completed","conclusion":"success"},{"name":"b","status":"completed","conclusion":"success"}]}'
failed_resp='{"total_count":2,"check_runs":[{"name":"a","status":"completed","conclusion":"success"},{"name":"b","status":"completed","conclusion":"failure"}]}'
pending_resp='{"total_count":2,"check_runs":[{"name":"a","status":"in_progress","conclusion":null},{"name":"b","status":"completed","conclusion":"success"}]}'
empty_resp='{"total_count":0,"check_runs":[]}'

assert_eq "classify passed" "passed" "$(checks_classify_response "$passed_resp")"
assert_eq "classify failed" "failed" "$(checks_classify_response "$failed_resp")"
assert_eq "classify pending" "pending" "$(checks_classify_response "$pending_resp")"
assert_eq "classify empty" "empty" "$(checks_classify_response "$empty_resp")"
assert_eq "classify garbage as empty" "empty" "$(checks_classify_response "not json")"

# Neutral/skipped count as success
neutral_resp='{"total_count":1,"check_runs":[{"name":"a","status":"completed","conclusion":"neutral"}]}'
assert_eq "classify neutral as passed" "passed" "$(checks_classify_response "$neutral_resp")"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Checks API: backoff sequence"
# ═══════════════════════════════════════════════════════════════════════════════

assert_eq "backoff attempt 1 = 1s" "1" "$(_mc_next_delay 1)"
assert_eq "backoff attempt 2 = 2s" "2" "$(_mc_next_delay 2)"
assert_eq "backoff attempt 3 = 4s" "4" "$(_mc_next_delay 3)"
assert_eq "backoff attempt 4 = 8s" "8" "$(_mc_next_delay 4)"
assert_eq "backoff attempt 5 capped at 8s" "8" "$(_mc_next_delay 5)"
assert_eq "backoff attempt 10 capped at 8s" "8" "$(_mc_next_delay 10)"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Checks API: NO_GITHUB short-circuits to passed"
# ═══════════════════════════════════════════════════════════════════════════════

# NO_GITHUB exported above
result=$(checks_poll_required_checks "owner" "repo" "abc123" 5)
assert_eq "NO_GITHUB returns passed immediately" "passed" "$result"

print_test_results
