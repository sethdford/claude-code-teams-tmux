#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/pipeline-stall-detection test — Unit tests               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: pipeline-stall-detection Tests"

setup_test_env "sw-lib-pipeline-stall-detection-test"
trap cleanup_test_env EXIT

mock_git
mock_gh
mock_claude

# Source the lib
export PROJECT_ROOT="$TEST_TEMP_DIR/project"
mkdir -p "$PROJECT_ROOT/.claude/pipeline-artifacts"
mkdir -p "$PROJECT_ROOT/.claude/loop-logs"

# Provide emit_event stub
emit_event() { :; }
export -f emit_event

# Provide memory_capture_failure stub
MEMORY_CAPTURE_CALLED=""
MEMORY_CAPTURE_STAGE=""
MEMORY_CAPTURE_MSG=""
memory_capture_failure() {
    MEMORY_CAPTURE_CALLED="true"
    MEMORY_CAPTURE_STAGE="${1:-}"
    MEMORY_CAPTURE_MSG="${2:-}"
}
export -f memory_capture_failure

_PIPELINE_STALL_DETECTION_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-stall-detection.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# stall_compute_score
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stall_compute_score"

# Missing tracking file returns 0
result=$(stall_compute_score "/nonexistent/file" "/nonexistent/errors" 5 20)
assert_eq "Missing tracking file returns 0" "0" "$result"

# Empty tracking file returns 0
tracking="$TEST_TEMP_DIR/tracking.txt"
touch "$tracking"
result=$(stall_compute_score "$tracking" "/nonexistent" 5 20)
assert_eq "Empty tracking file returns 0" "0" "$result"

# Early iteration (< 4) always returns 0
echo "abc|def|1" > "$tracking"
echo "abc|def|1" >> "$tracking"
echo "abc|def|1" >> "$tracking"
result=$(stall_compute_score "$tracking" "/nonexistent" 2 20)
assert_eq "Iteration < 4 returns 0" "0" "$result"

# 3 identical diff hashes trigger signal 1 (weight 30)
echo "samehash|err1|1" > "$tracking"
echo "samehash|err2|1" >> "$tracking"
echo "samehash|err3|1" >> "$tracking"
result=$(stall_compute_score "$tracking" "/nonexistent" 5 20)
if [[ "$result" -ge 30 ]]; then
    assert_pass "3 identical diffs scores >= 30 (got $result)"
else
    assert_fail "3 identical diffs scores >= 30" "got $result"
fi

# 5 identical error hashes trigger signal 2 (weight 30)
echo "d1|sameerr|1" > "$tracking"
echo "d2|sameerr|1" >> "$tracking"
echo "d3|sameerr|1" >> "$tracking"
echo "d4|sameerr|1" >> "$tracking"
echo "d5|sameerr|1" >> "$tracking"
result=$(stall_compute_score "$tracking" "/nonexistent" 8 20)
if [[ "$result" -ge 30 ]]; then
    assert_pass "5 identical errors scores >= 30 (got $result)"
else
    assert_fail "5 identical errors scores >= 30" "got $result"
fi

# Both signals: 3 identical diffs + 5 identical errors = score >= 60
echo "samehash|sameerr|1" > "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
result=$(stall_compute_score "$tracking" "/nonexistent" 8 20)
if [[ "$result" -ge 60 ]]; then
    assert_pass "Both signals score >= 60 (got $result)"
else
    assert_fail "Both signals score >= 60" "got $result"
fi

# Full deadlock: all 4 signals = score >= 70
error_log="$TEST_TEMP_DIR/error-log.jsonl"
echo '{"error":"same error msg"}' > "$error_log"
echo '{"error":"same error msg"}' >> "$error_log"
echo '{"error":"same error msg"}' >> "$error_log"
echo '{"error":"same error msg"}' >> "$error_log"
echo '{"error":"same error msg"}' >> "$error_log"
echo '{"error":"same error msg"}' >> "$error_log"
echo '{"error":"same error msg"}' >> "$error_log"
echo '{"error":"same error msg"}' >> "$error_log"
# ABAB diff pattern for signal 4
echo "hashA|sameerr|1" > "$tracking"
echo "hashB|sameerr|1" >> "$tracking"
echo "hashA|sameerr|1" >> "$tracking"
echo "hashB|sameerr|1" >> "$tracking"
echo "hashA|sameerr|1" >> "$tracking"
result=$(stall_compute_score "$tracking" "$error_log" 10 20)
if [[ "$result" -ge 70 ]]; then
    assert_pass "Full deadlock scores >= 70 (got $result)"
else
    assert_fail "Full deadlock scores >= 70" "got $result"
fi

# Healthy: all different hashes = score 0
echo "hash1|err1|0" > "$tracking"
echo "hash2|err2|0" >> "$tracking"
echo "hash3|err3|0" >> "$tracking"
echo "hash4|err4|0" >> "$tracking"
echo "hash5|err5|0" >> "$tracking"
result=$(stall_compute_score "$tracking" "/nonexistent" 8 20)
assert_eq "Healthy iterations score 0" "0" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# stall_should_abort
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stall_should_abort"

# Never abort when tests pass
rc=0; stall_should_abort 100 "true" "false" || rc=$?
assert_eq "Tests passing: never abort (score=100)" "1" "$rc"

rc=0; stall_should_abort 80 "true" "false" || rc=$?
assert_eq "Tests passing: never abort (score=80)" "1" "$rc"

# Never abort when score < 70
rc=0; stall_should_abort 69 "false" "false" || rc=$?
assert_eq "Score 69: don't abort" "1" "$rc"

rc=0; stall_should_abort 50 "false" "false" || rc=$?
assert_eq "Score 50: don't abort" "1" "$rc"

rc=0; stall_should_abort 0 "false" "false" || rc=$?
assert_eq "Score 0: don't abort" "1" "$rc"

# Abort when score >= 70 and tests NOT passing
rc=0; stall_should_abort 70 "false" "false" || rc=$?
assert_eq "Score 70, tests failing: abort" "0" "$rc"

rc=0; stall_should_abort 100 "false" "false" || rc=$?
assert_eq "Score 100, tests failing: abort" "0" "$rc"

# Invalid score: don't abort
rc=0; stall_should_abort "notanumber" "false" "false" || rc=$?
assert_eq "Invalid score: don't abort" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
# stall_build_diagnostics
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stall_build_diagnostics"

# Zero-changes scenario
echo "samehash|none|1" > "$tracking"
echo "samehash|none|1" >> "$tracking"
echo "samehash|none|1" >> "$tracking"
echo "samehash|none|1" >> "$tracking"
diag=$(stall_build_diagnostics "$tracking" "/nonexistent" "$TEST_TEMP_DIR/logs" 8)
stall_type=$(echo "$diag" | jq -r '.stall_type' 2>/dev/null)
assert_eq "Zero-changes detected" "zero_changes" "$stall_type"

# Verify JSON structure
iter_stuck=$(echo "$diag" | jq -r '.iterations_stuck' 2>/dev/null)
if [[ "$iter_stuck" -ge 1 ]]; then
    assert_pass "iterations_stuck is set (got $iter_stuck)"
else
    assert_fail "iterations_stuck should be >= 1" "got $iter_stuck"
fi

recovery=$(echo "$diag" | jq -r '.suggested_recovery | length' 2>/dev/null)
if [[ "$recovery" -ge 1 ]]; then
    assert_pass "suggested_recovery has entries"
else
    assert_fail "suggested_recovery should have entries" "got $recovery"
fi

# Error loop scenario
echo "d1|sameerr|1" > "$tracking"
echo "d2|sameerr|1" >> "$tracking"
echo "d3|sameerr|1" >> "$tracking"
echo "d4|sameerr|1" >> "$tracking"
echo "d5|sameerr|1" >> "$tracking"
echo "d6|sameerr|1" >> "$tracking"
diag=$(stall_build_diagnostics "$tracking" "/nonexistent" "$TEST_TEMP_DIR/logs" 10)
stall_type=$(echo "$diag" | jq -r '.stall_type' 2>/dev/null)
assert_eq "Error loop detected" "error_loop" "$stall_type"

# Deadlock scenario (same diffs + same errors)
echo "samehash|sameerr|1" > "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
diag=$(stall_build_diagnostics "$tracking" "/nonexistent" "$TEST_TEMP_DIR/logs" 8)
stall_type=$(echo "$diag" | jq -r '.stall_type' 2>/dev/null)
assert_eq "Deadlock detected" "deadlock" "$stall_type"

# Missing tracking file
diag=$(stall_build_diagnostics "/nonexistent" "/nonexistent" "$TEST_TEMP_DIR/logs" 5)
stall_type=$(echo "$diag" | jq -r '.stall_type' 2>/dev/null)
assert_eq "Missing file returns unknown" "unknown" "$stall_type"

# ═══════════════════════════════════════════════════════════════════════════════
# stall_check_and_abort (orchestrator)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stall_check_and_abort"

# Should NOT abort: healthy iterations
echo "hash1|err1|0" > "$tracking"
echo "hash2|err2|0" >> "$tracking"
echo "hash3|err3|0" >> "$tracking"
echo "hash4|err4|0" >> "$tracking"
echo "hash5|err5|0" >> "$tracking"
log_dir="$TEST_TEMP_DIR/logs"
mkdir -p "$log_dir"
rc=0; stall_check_and_abort "$tracking" "/nonexistent" "$log_dir" 8 20 "false" "false" || rc=$?
assert_eq "Healthy: don't abort" "1" "$rc"

# Should NOT abort: tests passing even with deadlock signals
echo "samehash|sameerr|1" > "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
rc=0; stall_check_and_abort "$tracking" "/nonexistent" "$log_dir" 8 20 "true" "false" || rc=$?
assert_eq "Tests passing: don't abort even with high score" "1" "$rc"

# Should NOT abort: early iteration
echo "samehash|sameerr|1" > "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
rc=0; stall_check_and_abort "$tracking" "/nonexistent" "$log_dir" 2 20 "false" "false" || rc=$?
assert_eq "Early iteration: don't abort" "1" "$rc"

# SHOULD abort: high score + tests failing + iteration >= 4
echo "samehash|sameerr|1" > "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
MEMORY_CAPTURE_CALLED=""
rc=0; stall_check_and_abort "$tracking" "$error_log" "$log_dir" 8 20 "false" "false" || rc=$?
assert_eq "Deadlock + tests failing: abort" "0" "$rc"

# Verify diagnostics file was written
assert_file_exists "Diagnostics file written on abort" "$log_dir/stall-diagnostics.json"

# Verify diagnostics JSON is valid
diag_json=$(cat "$log_dir/stall-diagnostics.json" 2>/dev/null)
stall_type=$(echo "$diag_json" | jq -r '.stall_type' 2>/dev/null)
if [[ "$stall_type" != "null" && -n "$stall_type" ]]; then
    assert_pass "Diagnostics has stall_type: $stall_type"
else
    assert_fail "Diagnostics missing stall_type"
fi

# Verify memory was called
assert_eq "Memory capture called on abort" "true" "$MEMORY_CAPTURE_CALLED"
assert_eq "Memory stage is stall_deadlock" "stall_deadlock" "$MEMORY_CAPTURE_STAGE"

# ═══════════════════════════════════════════════════════════════════════════════
# stall_save_to_memory
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stall_save_to_memory"

MEMORY_CAPTURE_CALLED=""
MEMORY_CAPTURE_STAGE=""
MEMORY_CAPTURE_MSG=""
stall_save_to_memory '{"stall_type":"error_loop","iterations_stuck":5,"stall_score":80}'
assert_eq "Memory called with diagnostics" "true" "$MEMORY_CAPTURE_CALLED"
assert_eq "Stage is stall_deadlock" "stall_deadlock" "$MEMORY_CAPTURE_STAGE"
assert_contains "Message has stall type" "$MEMORY_CAPTURE_MSG" "error_loop"

# Empty diagnostics: no-op
MEMORY_CAPTURE_CALLED=""
stall_save_to_memory ""
if [[ "$MEMORY_CAPTURE_CALLED" != "true" ]]; then
    assert_pass "Empty diagnostics: memory not called"
else
    assert_fail "Empty diagnostics should skip memory capture"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# stall_get_statistics
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "stall_get_statistics"

# No events file
rm -f "$HOME/.shipwright/events.jsonl"
stats=$(stall_get_statistics)
total=$(echo "$stats" | jq -r '.total_stalls' 2>/dev/null)
assert_eq "No events: total_stalls=0" "0" "$total"

# With stall events
mkdir -p "$HOME/.shipwright"
cat > "$HOME/.shipwright/events.jsonl" <<'JSONL'
{"ts":"2026-01-01T00:00:00Z","type":"stall.detect","score":"40","iteration":"5"}
{"ts":"2026-01-01T00:01:00Z","type":"stall.detect","score":"70","iteration":"8"}
{"ts":"2026-01-01T00:02:00Z","type":"stall.abort","score":"80","iteration":"10","stall_type":"error_loop"}
JSONL
stats=$(stall_get_statistics)
total_stalls=$(echo "$stats" | jq -r '.total_stalls' 2>/dev/null)
total_aborts=$(echo "$stats" | jq -r '.total_aborts' 2>/dev/null)
assert_eq "Stall events counted" "2" "$total_stalls"
assert_eq "Abort events counted" "1" "$total_aborts"

# ═══════════════════════════════════════════════════════════════════════════════
# Edge cases
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Edge cases"

# Score cap at 100
echo "samehash|sameerr|1" > "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
result=$(stall_compute_score "$tracking" "$error_log" 10 20)
if [[ "$result" -le 100 ]]; then
    assert_pass "Score capped at 100 (got $result)"
else
    assert_fail "Score should be <= 100" "got $result"
fi

# 'none' errors don't count as repeated errors
echo "d1|none|0" > "$tracking"
echo "d2|none|0" >> "$tracking"
echo "d3|none|0" >> "$tracking"
echo "d4|none|0" >> "$tracking"
echo "d5|none|0" >> "$tracking"
result=$(stall_compute_score "$tracking" "/nonexistent" 8 20)
assert_eq "None errors don't trigger signal 2" "0" "$result"

# ABAB pattern (circular diffs)
echo "hashA|err1|1" > "$tracking"
echo "hashB|err2|1" >> "$tracking"
echo "hashA|err3|1" >> "$tracking"
echo "hashB|err4|1" >> "$tracking"
result=$(stall_compute_score "$tracking" "/nonexistent" 8 20)
if [[ "$result" -ge 20 ]]; then
    assert_pass "ABAB pattern detected (got $result)"
else
    assert_fail "ABAB pattern should score >= 20" "got $result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# False positive prevention
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "False positive prevention"

# Tests passing = never abort, even with max stall score
echo "samehash|sameerr|1" > "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
rc=0; stall_should_abort 100 "true" "true" || rc=$?
assert_eq "Tests+quality passing: NEVER abort" "1" "$rc"

# Iteration 3 (boundary): should not abort
echo "samehash|sameerr|1" > "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
echo "samehash|sameerr|1" >> "$tracking"
rc=0; stall_check_and_abort "$tracking" "$error_log" "$log_dir" 3 20 "false" "false" || rc=$?
assert_eq "Iteration 3 boundary: don't abort" "1" "$rc"

# Iteration 4 (boundary): CAN abort if signals are strong enough
rc=0; stall_check_and_abort "$tracking" "$error_log" "$log_dir" 4 20 "false" "false" || rc=$?
assert_eq "Iteration 4 boundary: can abort if deadlocked" "0" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_results
