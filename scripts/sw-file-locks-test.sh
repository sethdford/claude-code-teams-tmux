#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright file-locks test — Unit tests for file-level lock registry    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-file-locks-test.XXXXXX")
    export DAEMON_DIR="$TEST_DIR/.shipwright"
    export LOCK_FILE="$DAEMON_DIR/file-locks.json"
    export HEARTBEAT_DIR="$DAEMON_DIR/heartbeats"
    export FILE_LOCK_STALE_SECONDS=1
    mkdir -p "$DAEMON_DIR"
    # Force reload of module between tests
    unset _FILE_LOCKS_LOADED
    source "$SCRIPT_DIR/lib/file-locks.sh"
}

cleanup_env() {
    [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}
trap cleanup_env EXIT

reset_test() {
    rm -rf "$DAEMON_DIR"
    mkdir -p "$DAEMON_DIR"
}

# ═══ Tests ═══════════════════════════════════════════════════════════════════

setup_env

echo "═══ file-locks unit tests ═══"

# Test 1: acquire single file lock
reset_test
if lock_acquire_files 1001 42 "src/foo.sh" >/dev/null; then
    files=$(jq -r '.pipelines["1001"].files | join(",")' "$LOCK_FILE")
    assert_eq "acquire_single_file: stores file under pid" "src/foo.sh" "$files"
else
    assert_fail "acquire_single_file: acquisition should succeed"
fi

# Test 2: files stored in sorted order (deadlock prevention)
reset_test
lock_acquire_files 1002 43 "z.sh" "a.sh" "m.sh" >/dev/null
order=$(jq -r '.pipelines["1002"].files | join(",")' "$LOCK_FILE")
assert_eq "sort_order: files stored alphabetically" "a.sh,m.sh,z.sh" "$order"

# Test 3: conflict detection returns non-zero
reset_test
lock_acquire_files 1003 44 "shared.sh" >/dev/null
if lock_check_conflict "shared.sh" >/dev/null; then
    assert_fail "conflict_detection: should return 1 when file is locked"
else
    assert_pass "conflict_detection: returns non-zero for locked file"
fi

# Test 4: no conflict for unlocked file
reset_test
lock_acquire_files 1004 45 "a.sh" >/dev/null
if lock_check_conflict "b.sh" >/dev/null; then
    assert_pass "no_conflict: returns 0 for unlocked file"
else
    assert_fail "no_conflict: should return 0 for unlocked file"
fi

# Test 5: second pipeline blocked by first
reset_test
lock_acquire_files 1005 46 "shared.sh" >/dev/null
if lock_acquire_files 1006 47 "shared.sh" >/dev/null 2>&1; then
    assert_fail "second_pipeline_blocked: acquisition should fail"
else
    assert_pass "second_pipeline_blocked: second acquisition fails"
fi
# Verify conflicts_avoided metric incremented
avoided=$(jq -r '.metrics.conflicts_avoided' "$LOCK_FILE")
assert_eq "metric_conflicts_avoided: incremented on conflict" "1" "$avoided"

# Test 6: release clears state
reset_test
lock_acquire_files 1007 48 "foo.sh" "bar.sh" >/dev/null
lock_release_files 1007
present=$(jq -r '.pipelines["1007"] // "gone"' "$LOCK_FILE")
assert_eq "release: removes pipeline entry" "gone" "$present"
released=$(jq -r '.metrics.locks_released' "$LOCK_FILE")
assert_eq "metric_locks_released: incremented on release" "1" "$released"

# Test 7: release is idempotent
reset_test
lock_release_files 9999  # no-op on missing pid
assert_pass "release_idempotent: missing pid does not error"

# Test 8: heartbeat file created on acquire
reset_test
lock_acquire_files 1008 49 "x.sh" >/dev/null
if [[ -f "$HEARTBEAT_DIR/pipeline-1008.json" ]]; then
    assert_pass "heartbeat_created: heartbeat file exists after acquire"
else
    assert_fail "heartbeat_created: heartbeat file missing"
fi
lock_release_files 1008
if [[ ! -f "$HEARTBEAT_DIR/pipeline-1008.json" ]]; then
    assert_pass "heartbeat_removed: heartbeat file removed after release"
else
    assert_fail "heartbeat_removed: heartbeat file should be gone"
fi

# Test 9: lock_list returns all pipelines
reset_test
lock_acquire_files 1009 50 "a.sh" >/dev/null
lock_acquire_files 1010 51 "b.sh" >/dev/null
count=$(lock_list | jq 'keys | length')
assert_eq "lock_list: returns all pipelines" "2" "$count"

# Test 10: same pid re-locking its own file does not conflict
reset_test
lock_acquire_files 1011 52 "foo.sh" >/dev/null
# Re-acquire a *new* set of files for the same pid — should succeed
if lock_acquire_files 1011 52 "foo.sh" "bar.sh" >/dev/null 2>&1; then
    assert_pass "same_pid_no_conflict: same pid does not self-conflict"
else
    assert_fail "same_pid_no_conflict: same pid should not conflict with self"
fi

# Test 11: stale lock cleanup removes entries for dead pids
reset_test
# Use a pid that will not exist (very high number, not our own)
DEAD_PID=99991
lock_acquire_files "$DEAD_PID" 53 "stale.sh" >/dev/null
# Backdate heartbeat in lock file so cleanup actually triggers
jq --arg pid "$DEAD_PID" '.pipelines[$pid].heartbeat = "2020-01-01T00:00:00Z"' "$LOCK_FILE" > "$LOCK_FILE.tmp"
mv "$LOCK_FILE.tmp" "$LOCK_FILE"
cleaned=$(lock_cleanup_stale)
assert_eq "stale_cleanup: removes dead pid" "1" "$cleaned"
present=$(jq -r --arg pid "$DEAD_PID" '.pipelines[$pid] // "gone"' "$LOCK_FILE")
assert_eq "stale_cleanup: entry is gone" "gone" "$present"

# Test 12: alive pid is NOT cleaned even with stale heartbeat
reset_test
MY_PID=$$
lock_acquire_files "$MY_PID" 54 "alive.sh" >/dev/null
# Backdate heartbeat
jq --arg pid "$MY_PID" '.pipelines[$pid].heartbeat = "2020-01-01T00:00:00Z"' "$LOCK_FILE" > "$LOCK_FILE.tmp"
mv "$LOCK_FILE.tmp" "$LOCK_FILE"
cleaned=$(lock_cleanup_stale)
assert_eq "stale_cleanup: alive pid not cleaned" "0" "$cleaned"
lock_release_files "$MY_PID"

# Test 13: conflict detail includes owner information
reset_test
lock_acquire_files 1012 55 "detail.sh" >/dev/null
conflict_json=$(lock_check_conflict "detail.sh" || true)
owner=$(echo "$conflict_json" | jq -r '.owner_pid')
assert_eq "conflict_detail: owner_pid matches" "1012" "$owner"
issue=$(echo "$conflict_json" | jq -r '.owner_issue')
assert_eq "conflict_detail: owner_issue matches" "55" "$issue"

# Test 14: metrics initialized properly
reset_test
lock_metrics >/dev/null
m=$(lock_metrics | jq -r '.locks_acquired')
assert_eq "metrics_init: locks_acquired starts at 0" "0" "$m"

# Test 15: events emitted to events.jsonl
reset_test
EVENTS="$DAEMON_DIR/events.jsonl"
lock_acquire_files 1013 56 "ev.sh" >/dev/null
lock_release_files 1013
if [[ -f "$EVENTS" ]] && grep -q "daemon.lock_acquired" "$EVENTS" && grep -q "daemon.lock_released" "$EVENTS"; then
    assert_pass "events_emitted: acquire/release events written"
else
    assert_fail "events_emitted: missing expected events" "$(cat "$EVENTS" 2>/dev/null || echo none)"
fi

# ═══ Integration tests: lock_acquire_or_queue + conflict-queue ═════════════

# Load sibling modules required by the wrapper.
unset _CONFLICT_PREDICTOR_LOADED _CONFLICT_QUEUE_LOADED
export CONFLICT_QUEUE_FILE="$DAEMON_DIR/conflict-queue.json"
source "$SCRIPT_DIR/lib/conflict-predictor.sh"
source "$SCRIPT_DIR/lib/conflict-queue.sh"

# Test 16: kill switch bypasses the gate (returns 0, no locks)
reset_test
SW_FILE_LOCKS_ENABLED=0 lock_acquire_or_queue 2001 60 "r" "t" "b" >/dev/null
assert_pass "kill_switch: SW_FILE_LOCKS_ENABLED=0 returns 0 without locking"

# Test 17: two conflicting pipelines — second is enqueued
reset_test
# Make a fake tracked-file universe for the predictor.
_PREDICTOR_TRACKED_CACHE="scripts/lib/foo.sh"$'\n'"scripts/lib/bar.sh"
export _PREDICTOR_TRACKED_CACHE
title1="Update scripts/lib/foo.sh module"
title2="Tweak scripts/lib/foo.sh for fix"
lock_acquire_or_queue 2002 70 "r/x" "$title1" "" >/dev/null
rc=0
lock_acquire_or_queue 2003 71 "r/x" "$title2" "" >/dev/null || rc=$?
assert_eq "gate: second conflicting pipeline returns rc=2 (queued)" "2" "$rc"
depth=$(queue_depth)
assert_eq "gate: queue depth is 1 after conflict" "1" "$depth"

# Test 18: release drains queue — popped entry matches enqueued issue
lock_release_files 2002
popped=$(queue_pop_ready || true)
popped_issue=$(echo "$popped" | jq -r '.issue // 0' 2>/dev/null || echo "0")
assert_eq "drain: pop_ready returns the blocked issue (#71)" "71" "$popped_issue"
final_depth=$(queue_depth)
assert_eq "drain: queue empty after pop" "0" "$final_depth"

# Test 19: prometheus metrics export has required counters
reset_test
lock_acquire_files 2004 72 "x.sh" >/dev/null
metrics=$(lock_export_metrics_prometheus)
echo "$metrics" | grep -q "shipwright_locks_acquired 1" \
    && assert_pass "prometheus: locks_acquired gauge present" \
    || assert_fail "prometheus: locks_acquired missing" "$metrics"

# Test 20: empty prediction → gate returns 0 (no locks, no queue)
reset_test
unset _PREDICTOR_TRACKED_CACHE
export _PREDICTOR_TRACKED_CACHE=""
lock_acquire_or_queue 2005 73 "r" "no file references here" "" >/dev/null
acquired=$(lock_metrics | jq -r '.locks_acquired')
assert_eq "empty_prediction: no locks acquired when no files predicted" "0" "$acquired"

print_test_results
