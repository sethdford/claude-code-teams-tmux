#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/memory-* test — Unit tests for the extracted modules     ║
# ║  Covers lib/memory-discovery.sh and lib/memory-cost.sh                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

DISCOVERY_LIB="$SCRIPT_DIR/lib/memory-discovery.sh"
COST_LIB="$SCRIPT_DIR/lib/memory-cost.sh"
MEMORY_SCRIPT="$SCRIPT_DIR/sw-memory.sh"

print_test_header "Lib: memory-discovery / memory-cost Tests"

setup_test_env "sw-lib-memory-modules-test"
trap cleanup_test_env EXIT

export REPO_DIR="$TEST_TEMP_DIR/project"
export NO_GITHUB=true
mock_git

# Run a snippet with sw-memory.sh sourced. $1 inside the snippet is the script path.
in_memory_env() { bash -c "$1" _ "$MEMORY_SCRIPT"; }

# ─── Structure ──────────────────────────────────────────────────────────────
print_test_section "Module structure"

assert_file_exists "lib/memory-discovery.sh exists" "$DISCOVERY_LIB"
assert_file_exists "lib/memory-cost.sh exists" "$COST_LIB"

bash -n "$DISCOVERY_LIB" 2>/dev/null \
    && assert_pass "memory-discovery.sh parses" \
    || assert_fail "memory-discovery.sh parses" "syntax error"
bash -n "$COST_LIB" 2>/dev/null \
    && assert_pass "memory-cost.sh parses" \
    || assert_fail "memory-cost.sh parses" "syntax error"

# Both libs carry a module guard so double-sourcing is a no-op.
assert_contains "memory-discovery has a module guard" "$(cat "$DISCOVERY_LIB")" "_MEMDISC_LOADED"
assert_contains "memory-cost has a module guard" "$(cat "$COST_LIB")" "_MEMCOST_LOADED"

# ─── Wiring: sw-memory.sh must source both ──────────────────────────────────
print_test_section "Wiring into sw-memory.sh"

memory_src="$(cat "$MEMORY_SCRIPT")"
assert_contains "sw-memory.sh sources memory-discovery.sh" "$memory_src" 'lib/memory-discovery.sh"'
assert_contains "sw-memory.sh sources memory-cost.sh" "$memory_src" 'lib/memory-cost.sh"'

# The point of the split: the monolith stays under the size budget.
memory_lines=$(wc -l < "$MEMORY_SCRIPT" | tr -d ' ')
if [[ "$memory_lines" -lt 1500 ]]; then
    assert_pass "sw-memory.sh is under the 1500-line budget ($memory_lines lines)"
else
    assert_fail "sw-memory.sh is under the 1500-line budget" "got $memory_lines lines"
fi

# Extraction, not duplication — a moved function must live in exactly one file.
for fn in memory_capture_pipeline memory_capture_pattern memory_get_dora_baseline; do
    hits=$(grep -l "^${fn}() {" "$MEMORY_SCRIPT" "$DISCOVERY_LIB" "$COST_LIB" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "$fn is defined in exactly one file (moved, not copied)" "1" "$hits"
done

# ─── Functions are reachable after sourcing sw-memory.sh ────────────────────
print_test_section "Function availability via sw-memory.sh"

DISCOVERY_FNS="memory_capture_pipeline memory_capture_failure memory_record_fix_outcome
memory_track_fix memory_query_fix_for_error memory_closed_loop_inject
memory_capture_failure_from_log _memory_aggregate_global memory_finalize_pipeline
memory_analyze_failure memory_capture_pattern memory_get_actionable_failures"
COST_FNS="memory_get_dora_baseline memory_get_baseline memory_update_metrics"

for fn in $DISCOVERY_FNS $COST_FNS; do
    if bash -c 'source "$1" >/dev/null 2>&1; type "$2" >/dev/null 2>&1' _ "$MEMORY_SCRIPT" "$fn"; then
        assert_pass "$fn is defined after sourcing sw-memory.sh"
    else
        assert_fail "$fn is defined after sourcing sw-memory.sh" "not found"
    fi
done

# ─── Behavior: memory-discovery ─────────────────────────────────────────────
print_test_section "memory-discovery behavior"

# memory_get_actionable_failures returns [] when there is no failures file yet.
out=$(in_memory_env 'source "$1" >/dev/null 2>&1; memory_get_actionable_failures 3' 2>/dev/null || echo "ERR")
assert_eq "memory_get_actionable_failures returns [] with no failures file" "[]" "$out"

# With failures present it filters on seen_count >= threshold and sorts descending.
out=$(in_memory_env '
    source "$1" >/dev/null 2>&1
    ensure_memory_dir
    mem_dir="$(repo_memory_dir)"
    printf "%s\n" "{\"failures\":[{\"pattern\":\"rare\",\"seen_count\":1},{\"pattern\":\"often\",\"seen_count\":7},{\"pattern\":\"some\",\"seen_count\":3}]}" > "$mem_dir/failures.json"
    memory_get_actionable_failures 3
' 2>/dev/null || echo "[]")
assert_eq "actionable failures filters on seen_count >= threshold" "2" "$(echo "$out" | jq 'length')"
assert_eq "actionable failures sorts by seen_count descending" '"often"' "$(echo "$out" | jq '.[0].pattern')"

# memory_track_fix records a fix without erroring.
if in_memory_env 'source "$1" >/dev/null 2>&1; memory_track_fix "npm ERR missing module" "ran npm ci" >/dev/null 2>&1'; then
    assert_pass "memory_track_fix succeeds"
else
    assert_fail "memory_track_fix succeeds" "non-zero exit"
fi

# memory_query_fix_for_error is quiet when nothing matching has been recorded.
out=$(in_memory_env 'source "$1" >/dev/null 2>&1; memory_query_fix_for_error "nothing ever seen before" 2>/dev/null' || true)
assert_eq "memory_query_fix_for_error returns nothing for an unknown error" "" "$out"

# ─── Behavior: memory-cost ──────────────────────────────────────────────────
print_test_section "memory-cost behavior"

# DORA baseline is valid JSON carrying the four core metrics, even with no events.
out=$(in_memory_env 'source "$1" >/dev/null 2>&1; memory_get_dora_baseline 7 0' 2>/dev/null || echo '{}')
echo "$out" | jq -e . >/dev/null 2>&1 \
    && assert_pass "memory_get_dora_baseline emits valid JSON" \
    || assert_fail "memory_get_dora_baseline emits valid JSON" "got: $out"
for key in deploy_freq cycle_time cfr mttr; do
    if echo "$out" | jq -e "has(\"$key\")" >/dev/null 2>&1; then
        assert_pass "DORA baseline includes $key"
    else
        assert_fail "DORA baseline includes $key" "got: $out"
    fi
done

# memory_update_metrics writes the metric, and memory_get_baseline reads it back.
out=$(in_memory_env '
    source "$1" >/dev/null 2>&1
    memory_update_metrics build_duration_s 42 >/dev/null 2>&1
    memory_get_baseline build_duration_s
' 2>/dev/null || echo "ERR")
assert_contains "memory_update_metrics round-trips through memory_get_baseline" "$out" "42"

# An unknown metric must not blow up the caller.
if in_memory_env 'source "$1" >/dev/null 2>&1; memory_get_baseline no_such_metric >/dev/null 2>&1'; then
    assert_pass "memory_get_baseline exits 0 for an unknown metric"
else
    assert_fail "memory_get_baseline exits 0 for an unknown metric" "non-zero exit"
fi

# ─── Idempotent sourcing ────────────────────────────────────────────────────
print_test_section "Idempotent sourcing"

if bash -c 'source "$1" >/dev/null 2>&1; source "$2" >/dev/null 2>&1; source "$3" >/dev/null 2>&1; type memory_capture_pattern >/dev/null 2>&1' \
        _ "$MEMORY_SCRIPT" "$DISCOVERY_LIB" "$COST_LIB"; then
    assert_pass "re-sourcing the libs after sw-memory.sh is a safe no-op"
else
    assert_fail "re-sourcing the libs after sw-memory.sh is a safe no-op" "guard failed"
fi

print_test_results
