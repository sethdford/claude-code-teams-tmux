#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  conflict-queue unit tests                                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-conflict-queue-test.XXXXXX")
    export DAEMON_DIR="$TEST_DIR/.shipwright"
    export LOCK_FILE="$DAEMON_DIR/file-locks.json"
    export HEARTBEAT_DIR="$DAEMON_DIR/heartbeats"
    export CONFLICT_QUEUE_FILE="$DAEMON_DIR/conflict-queue.json"
    mkdir -p "$DAEMON_DIR"
    unset _FILE_LOCKS_LOADED _CONFLICT_QUEUE_LOADED
    source "$SCRIPT_DIR/lib/file-locks.sh"
    source "$SCRIPT_DIR/lib/conflict-queue.sh"
}

cleanup_env() {
    [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}
trap cleanup_env EXIT

reset_test() {
    rm -rf "$DAEMON_DIR"
    mkdir -p "$DAEMON_DIR"
}

setup_env

echo "═══ conflict-queue unit tests ═══"

# Test 1: enqueue writes a valid entry
reset_test
queue_enqueue 100 "owner/repo" "Fix thing" 12345 99 "a.sh" "b.sh"
depth=$(queue_depth)
assert_eq "enqueue_depth" "1" "$depth"
issue=$(jq -r '.[0].issue' "$CONFLICT_QUEUE_FILE")
assert_eq "enqueue_issue_stored" "100" "$issue"
files=$(jq -r '.[0].files | join(",")' "$CONFLICT_QUEUE_FILE")
assert_eq "enqueue_files_stored" "a.sh,b.sh" "$files"
blocked=$(jq -r '.[0].blocked_by_issue' "$CONFLICT_QUEUE_FILE")
assert_eq "enqueue_blocked_by" "99" "$blocked"

# Test 2: queue_list returns all entries as JSON array
reset_test
queue_enqueue 101 "o/r" "t1" 1 5 "x.sh"
queue_enqueue 102 "o/r" "t2" 1 5 "y.sh"
count=$(queue_list | jq 'length')
assert_eq "list_count" "2" "$count"

# Test 3: queue_pop_ready skips entries still blocked, returns ready entry
reset_test
# Acquire lock on a.sh so issue 103 (wants a.sh) stays blocked;
# issue 104 (wants b.sh, unblocked) should pop.
lock_acquire_files 77777 99 "a.sh" >/dev/null
queue_enqueue 103 "o/r" "blocked" 77777 99 "a.sh"
queue_enqueue 104 "o/r" "ready" 77777 99 "b.sh"
popped=$(queue_pop_ready)
ready_issue=$(echo "$popped" | jq -r '.issue')
assert_eq "pop_ready_issue" "104" "$ready_issue"
remaining=$(queue_depth)
assert_eq "pop_ready_depth_after" "1" "$remaining"
lock_release_files 77777

# Test 4: queue_pop_ready with all-ready pops FIFO head
reset_test
queue_enqueue 105 "o/r" "first" 0 0 "p.sh"
queue_enqueue 106 "o/r" "second" 0 0 "q.sh"
popped=$(queue_pop_ready)
first_out=$(echo "$popped" | jq -r '.issue')
assert_eq "fifo_order" "105" "$first_out"

# Test 5: queue_pop_ready on empty queue returns empty, exit 0
reset_test
out=$(queue_pop_ready || echo "error")
if [[ -z "$out" ]]; then
    assert_pass "pop_empty_returns_empty"
else
    assert_fail "pop_empty_returns_empty" "got: $out"
fi

# Test 6: queue_remove_issue removes by issue number
reset_test
queue_enqueue 107 "o/r" "t" 0 0 "f.sh"
queue_enqueue 108 "o/r" "t" 0 0 "g.sh"
queue_remove_issue 107
depth=$(queue_depth)
assert_eq "remove_depth" "1" "$depth"
remaining_issue=$(jq -r '.[0].issue' "$CONFLICT_QUEUE_FILE")
assert_eq "remove_keeps_other" "108" "$remaining_issue"

# Test 7: queue_clear empties the queue
reset_test
queue_enqueue 109 "o/r" "t" 0 0 "h.sh"
queue_clear
depth=$(queue_depth)
assert_eq "clear_depth" "0" "$depth"

# Test 8: enqueue emits an event
reset_test
EVENTS="$DAEMON_DIR/events.jsonl"
queue_enqueue 110 "o/r" "t" 1 2 "e.sh"
if [[ -f "$EVENTS" ]] && grep -q "daemon.conflict_enqueued" "$EVENTS"; then
    assert_pass "event_emitted_on_enqueue"
else
    assert_fail "event_emitted_on_enqueue" "events: $(cat "$EVENTS" 2>/dev/null || echo none)"
fi

print_test_results
