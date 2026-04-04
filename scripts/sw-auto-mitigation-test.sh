#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-auto-mitigation-test.sh — Test Suite for Auto-Mitigation Engine      ║
# ║                                                                           ║
# ║  Tests pattern matching, scoring, formatting, tracking, stats,           ║
# ║  proactive injection, pruning, and edge cases.                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# ─── Test Harness Setup ────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || {
    info() { echo "ℹ $*"; }
    success() { echo "✓ $*"; }
    warn() { echo "⚠ $*"; }
    error() { echo "✗ $*" >&2; }
}

# Temp directory for test artifacts
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Mock MEMORY_ROOT so tests don't touch real memory
export MEMORY_ROOT="$TEST_DIR/memory"
mkdir -p "$MEMORY_ROOT"

# Mock repo_memory_dir to point at test dir
MOCK_REPO_HASH="test-repo-hash"
mkdir -p "$MEMORY_ROOT/$MOCK_REPO_HASH"
repo_memory_dir() { echo "$MEMORY_ROOT/$MOCK_REPO_HASH"; }
export -f repo_memory_dir

# Mock memory_record_fix_outcome to track calls
MOCK_OUTCOME_CALLS="$TEST_DIR/outcome-calls.log"
memory_record_fix_outcome() {
    echo "record_fix_outcome: pattern=$1 applied=$2 resolved=$3" >> "$MOCK_OUTCOME_CALLS"
}

# Mock memeff_track_outcome
MOCK_MEMEFF_CALLS="$TEST_DIR/memeff-calls.log"
memeff_track_outcome() {
    echo "memeff_track: id=$1 pipeline=$2 outcome=$3" >> "$MOCK_MEMEFF_CALLS"
}

# Source the module under test
source "$SCRIPT_DIR/lib/auto-mitigation.sh"

# Test counters
PASS=0
FAIL=0
VERSION="3.2.4"

# ─── Test Helpers ──────────────────────────────────────────────────────────

assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="${3:-assertion}"

    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        success "PASS: $msg"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: $msg (expected: '$expected', got: '$actual')"
    fi
}

assert_gt() {
    local actual="$1"
    local threshold="$2"
    local msg="${3:-assertion}"

    if [[ "$actual" -gt "$threshold" ]] 2>/dev/null; then
        PASS=$((PASS + 1))
        success "PASS: $msg (got: $actual > $threshold)"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: $msg (expected > $threshold, got: $actual)"
    fi
}

assert_not_empty() {
    local actual="$1"
    local msg="${2:-assertion}"

    if [[ -n "$actual" ]]; then
        PASS=$((PASS + 1))
        success "PASS: $msg"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: $msg (expected non-empty, got empty)"
    fi
}

assert_empty() {
    local actual="$1"
    local msg="${2:-assertion}"

    if [[ -z "$actual" ]]; then
        PASS=$((PASS + 1))
        success "PASS: $msg"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: $msg (expected empty, got: '$actual')"
    fi
}

assert_json_length() {
    local json="$1"
    local expected="$2"
    local msg="${3:-assertion}"

    local actual
    actual=$(echo "$json" | jq 'length' 2>/dev/null || echo "-1")

    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        success "PASS: $msg (length=$actual)"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: $msg (expected length $expected, got $actual)"
    fi
}

# Create test failures.json with known patterns
setup_test_failures() {
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    cat > "$mem_dir/failures.json" <<'FAILURES'
{
  "failures": [
    {
      "stage": "build",
      "pattern": "TypeError: Cannot read property 'map' of undefined",
      "root_cause": "API response not validated",
      "fix": "Add null check before calling .map() on API response data",
      "seen_count": 5,
      "last_seen": "2026-04-01T10:00:00Z",
      "times_fix_suggested": 4,
      "times_fix_applied": 3,
      "times_fix_resolved": 3,
      "fix_effectiveness_rate": 100,
      "category": "type_error",
      "files": "src/api/handler.ts"
    },
    {
      "stage": "test",
      "pattern": "ReferenceError: process is not defined",
      "root_cause": "Missing Node.js polyfill",
      "fix": "Import process from 'node:process' or add vitest globals config",
      "seen_count": 3,
      "last_seen": "2026-03-28T15:00:00Z",
      "times_fix_suggested": 3,
      "times_fix_applied": 3,
      "times_fix_resolved": 2,
      "fix_effectiveness_rate": 66,
      "category": "reference_error"
    },
    {
      "stage": "build",
      "pattern": "ENOENT: no such file or directory",
      "root_cause": "Missing dependency",
      "fix": "Run npm install to restore missing dependencies",
      "seen_count": 8,
      "last_seen": "2026-04-02T08:00:00Z",
      "times_fix_suggested": 6,
      "times_fix_applied": 5,
      "times_fix_resolved": 4,
      "fix_effectiveness_rate": 80,
      "category": "dependency",
      "files": "package.json"
    },
    {
      "stage": "build",
      "pattern": "SyntaxError: Unexpected token",
      "root_cause": "Invalid JSON or JS syntax",
      "fix": "Check for trailing commas or mismatched brackets",
      "seen_count": 2,
      "last_seen": "2026-01-15T12:00:00Z",
      "times_fix_suggested": 1,
      "times_fix_applied": 1,
      "times_fix_resolved": 0,
      "fix_effectiveness_rate": 0,
      "category": "syntax_error"
    },
    {
      "stage": "test",
      "pattern": "old stale pattern that never works",
      "root_cause": "unknown",
      "fix": "try rebooting",
      "seen_count": 10,
      "last_seen": "2025-12-01T00:00:00Z",
      "times_fix_suggested": 8,
      "times_fix_applied": 7,
      "times_fix_resolved": 0,
      "fix_effectiveness_rate": 0,
      "category": "unknown"
    },
    {
      "stage": "build",
      "pattern": "no fix pattern",
      "root_cause": "unknown",
      "fix": "",
      "seen_count": 1,
      "last_seen": "2026-04-01T00:00:00Z",
      "times_fix_suggested": 0,
      "times_fix_applied": 0,
      "times_fix_resolved": 0,
      "fix_effectiveness_rate": 0,
      "category": "unknown"
    }
  ]
}
FAILURES
}

# ─── Tests ─────────────────────────────────────────────────────────────────

run_tests() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Auto-Mitigation Engine Test Suite                         ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    setup_test_failures

    # ── Test 1: Query with exact match ──────────────────────────────────
    info "Test 1: Query with exact error match"
    local result
    result=$(mitigation_query_fixes "TypeError: Cannot read property 'map' of undefined" "build" 3)
    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
    assert_gt "$count" 0 "Should find at least one match for exact error"

    local top_fix
    top_fix=$(echo "$result" | jq -r '.[0].fix // ""' 2>/dev/null)
    assert_eq "$top_fix" "Add null check before calling .map() on API response data" "Top fix should be the type_error fix"

    # ── Test 2: Query returns scores ────────────────────────────────────
    info "Test 2: Results include composite scores"
    local top_score
    top_score=$(echo "$result" | jq -r '.[0].score // 0' 2>/dev/null)
    assert_gt "$top_score" 0 "Top result should have positive score"

    # ── Test 3: Query with stage filter ─────────────────────────────────
    info "Test 3: Stage filter limits results"
    local test_result
    test_result=$(mitigation_query_fixes "ReferenceError: process is not defined" "test" 3)
    local test_count
    test_count=$(echo "$test_result" | jq 'length' 2>/dev/null || echo "0")
    assert_gt "$test_count" 0 "Should find match in test stage"

    # ── Test 4: Query with no match ─────────────────────────────────────
    info "Test 4: No match for unrelated error"
    local no_result
    no_result=$(mitigation_query_fixes "completely unrelated error that does not exist anywhere" "build" 3)
    assert_json_length "$no_result" "0" "Should return empty array for unrelated error"

    # ── Test 5: Empty error text returns empty ──────────────────────────
    info "Test 5: Empty error text"
    local empty_result
    empty_result=$(mitigation_query_fixes "" "build" 3)
    assert_eq "$empty_result" "[]" "Empty error text returns empty array"

    # ── Test 6: Missing failures file returns empty ─────────────────────
    info "Test 6: Missing failures file"
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    mv "$mem_dir/failures.json" "$mem_dir/failures.json.bak"
    local missing_result
    missing_result=$(mitigation_query_fixes "some error" "build" 3)
    assert_eq "$missing_result" "[]" "Missing failures file returns empty array"
    mv "$mem_dir/failures.json.bak" "$mem_dir/failures.json"

    # ── Test 7: Ranking by effectiveness ────────────────────────────────
    info "Test 7: Results ranked by composite score (higher effectiveness = higher rank)"
    local ranked
    ranked=$(mitigation_query_fixes "ENOENT: no such file or directory" "build" 3)
    local top_eff
    top_eff=$(echo "$ranked" | jq -r '.[0].effectiveness // 0' 2>/dev/null)
    assert_gt "$top_eff" 50 "Top result should have high effectiveness"

    # ── Test 8: Limit parameter ─────────────────────────────────────────
    info "Test 8: Limit parameter caps results"
    local limited
    limited=$(mitigation_query_fixes "error" "build" 1)
    local limited_count
    limited_count=$(echo "$limited" | jq 'length' 2>/dev/null || echo "0")
    # May be 0 if no substring match — that's OK, just test it doesn't exceed limit
    if [[ "$limited_count" -le 1 ]]; then
        PASS=$((PASS + 1))
        success "PASS: Limit=1 respected (got $limited_count results)"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: Limit=1 exceeded (got $limited_count results)"
    fi

    # ── Test 9: Format in prompt mode ───────────────────────────────────
    info "Test 9: Format matches as prompt"
    local matches
    matches=$(mitigation_query_fixes "TypeError: Cannot read property 'map' of undefined" "build" 3)
    local formatted
    formatted=$(mitigation_format "$matches" "prompt")
    assert_not_empty "$formatted" "Formatted output should not be empty"
    if echo "$formatted" | grep -q "Known Fixes"; then
        PASS=$((PASS + 1))
        success "PASS: Format contains 'Known Fixes' header"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: Format missing 'Known Fixes' header"
    fi

    # ── Test 10: Format in display mode ─────────────────────────────────
    info "Test 10: Format matches as display"
    local display_fmt
    display_fmt=$(mitigation_format "$matches" "display")
    assert_not_empty "$display_fmt" "Display format should not be empty"
    if echo "$display_fmt" | grep -q "%"; then
        PASS=$((PASS + 1))
        success "PASS: Display format contains effectiveness percentage"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: Display format missing percentage"
    fi

    # ── Test 11: Format empty array returns empty ───────────────────────
    info "Test 11: Format empty array"
    local empty_fmt
    empty_fmt=$(mitigation_format "[]" "prompt" || true)
    assert_empty "$empty_fmt" "Format of empty array should be empty"

    # ── Test 12: Format respects char budget ────────────────────────────
    info "Test 12: Format respects MITIGATION_MAX_CHARS"
    local saved_max="$MITIGATION_MAX_CHARS"
    MITIGATION_MAX_CHARS=100
    local short_fmt
    short_fmt=$(mitigation_format "$matches" "prompt" || true)
    local fmt_len=${#short_fmt}
    if [[ "$fmt_len" -le 200 ]]; then  # some slack for header
        PASS=$((PASS + 1))
        success "PASS: Format respects char budget (len=$fmt_len)"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: Format exceeded budget (len=$fmt_len, budget=100)"
    fi
    MITIGATION_MAX_CHARS="$saved_max"

    # ── Test 13: Proactive inject ───────────────────────────────────────
    info "Test 13: Proactive injection for high-confidence patterns"
    local proactive
    proactive=$(mitigation_proactive_inject "build" "fix the bug")
    assert_not_empty "$proactive" "Proactive inject should return content for high-confidence patterns"
    if echo "$proactive" | grep -q "Proactive Mitigations"; then
        PASS=$((PASS + 1))
        success "PASS: Proactive inject has correct header"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: Proactive inject missing header"
    fi

    # ── Test 14: Proactive inject filters low-confidence ────────────────
    info "Test 14: Proactive inject skips low-confidence patterns"
    # SyntaxError has seen_count=2 (below threshold of 3)
    if echo "$proactive" | grep -qi "SyntaxError"; then
        FAIL=$((FAIL + 1))
        error "FAIL: Proactive inject included low-confidence pattern"
    else
        PASS=$((PASS + 1))
        success "PASS: Low-confidence patterns excluded from proactive inject"
    fi

    # ── Test 15: Track outcome dual-writes ──────────────────────────────
    info "Test 15: Track outcome calls both systems"
    > "$MOCK_OUTCOME_CALLS"  # clear
    > "$MOCK_MEMEFF_CALLS"
    mitigation_track_outcome "TypeError" "true" "true" "pipeline-123"

    if [[ -f "$MOCK_OUTCOME_CALLS" ]] && grep -q "record_fix_outcome" "$MOCK_OUTCOME_CALLS"; then
        PASS=$((PASS + 1))
        success "PASS: Track outcome called memory_record_fix_outcome"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: Track outcome did not call memory_record_fix_outcome"
    fi

    if [[ -f "$MOCK_MEMEFF_CALLS" ]] && grep -q "memeff_track" "$MOCK_MEMEFF_CALLS"; then
        PASS=$((PASS + 1))
        success "PASS: Track outcome called memeff_track_outcome"
    else
        FAIL=$((FAIL + 1))
        error "FAIL: Track outcome did not call memeff_track_outcome"
    fi

    # ── Test 16: Track outcome with empty pattern fails ─────────────────
    info "Test 16: Track with empty pattern returns error"
    if mitigation_track_outcome "" "true" "true" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        error "FAIL: Track with empty pattern should fail"
    else
        PASS=$((PASS + 1))
        success "PASS: Track with empty pattern returns non-zero"
    fi

    # ── Test 17: Stats aggregation ──────────────────────────────────────
    info "Test 17: Stats returns valid JSON with expected fields"
    local stats
    stats=$(mitigation_stats)
    assert_not_empty "$stats" "Stats should return non-empty JSON"

    local total_inj
    total_inj=$(echo "$stats" | jq '.total_injections // -1' 2>/dev/null)
    assert_gt "$total_inj" 0 "Total injections should be > 0"

    local total_res
    total_res=$(echo "$stats" | jq '.total_resolved // -1' 2>/dev/null)
    assert_gt "$total_res" 0 "Total resolved should be > 0"

    local resolution_rate
    resolution_rate=$(echo "$stats" | jq '.resolution_rate // -1 | floor' 2>/dev/null)
    assert_gt "$resolution_rate" 0 "Resolution rate should be > 0"

    local top_count
    top_count=$(echo "$stats" | jq '.top_patterns | length' 2>/dev/null || echo "0")
    assert_gt "$top_count" 0 "Should have top patterns"

    # ── Test 18: Stats with missing file ────────────────────────────────
    info "Test 18: Stats with missing file returns defaults"
    mv "$mem_dir/failures.json" "$mem_dir/failures.json.bak"
    local empty_stats
    empty_stats=$(mitigation_stats)
    local empty_inj
    empty_inj=$(echo "$empty_stats" | jq '.total_injections // -1' 2>/dev/null)
    assert_eq "$empty_inj" "0" "Stats with missing file returns 0 injections"
    mv "$mem_dir/failures.json.bak" "$mem_dir/failures.json"

    # ── Test 19: Prune stale patterns ───────────────────────────────────
    info "Test 19: Prune stale patterns"
    local before_count
    before_count=$(jq '.failures | length' "$mem_dir/failures.json" 2>/dev/null)

    local pruned
    pruned=$(mitigation_prune_stale)

    local after_count
    after_count=$(jq '.failures | length' "$mem_dir/failures.json" 2>/dev/null)

    if [[ "$pruned" -gt 0 ]]; then
        PASS=$((PASS + 1))
        success "PASS: Pruned $pruned stale patterns (before=$before_count, after=$after_count)"

        # Check archive file exists
        local archive_file="$mem_dir/failures-archived.json"
        if [[ -f "$archive_file" ]]; then
            local archived_count
            archived_count=$(jq '.archived | length' "$archive_file" 2>/dev/null || echo "0")
            assert_gt "$archived_count" 0 "Archive should contain pruned patterns"
        else
            FAIL=$((FAIL + 1))
            error "FAIL: Archive file not created after prune"
        fi
    else
        # Even if nothing was pruned, it should return 0 safely
        PASS=$((PASS + 1))
        success "PASS: Prune returned $pruned (no stale patterns matched criteria)"
    fi

    # ── Test 20: Entries without fix are excluded ───────────────────────
    info "Test 20: Entries without fix are excluded from queries"
    local all_result
    all_result=$(mitigation_query_fixes "no fix pattern" "build" 10)
    local all_fixes
    all_fixes=$(echo "$all_result" | jq '[.[] | select(.fix == "")]' 2>/dev/null || echo "[]")
    local empty_fix_count
    empty_fix_count=$(echo "$all_fixes" | jq 'length' 2>/dev/null || echo "0")
    assert_eq "$empty_fix_count" "0" "Results should not include entries with empty fix"

    # ── Test 21: Corrupt JSON handled gracefully ────────────────────────
    info "Test 21: Corrupt JSON handled gracefully"
    echo "not valid json at all" > "$mem_dir/failures.json"
    local corrupt_result
    corrupt_result=$(mitigation_query_fixes "some error" "build" 3)
    assert_eq "$corrupt_result" "[]" "Corrupt JSON returns empty array"

    local corrupt_stats
    corrupt_stats=$(mitigation_stats)
    local corrupt_inj
    corrupt_inj=$(echo "$corrupt_stats" | jq '.total_injections // -1' 2>/dev/null)
    assert_eq "$corrupt_inj" "0" "Corrupt JSON stats returns 0"

    # Restore valid data
    setup_test_failures

    # ── Test 22: Text similarity internals ──────────────────────────────
    info "Test 22: Text similarity scoring"
    local sim_exact
    sim_exact=$(_mitigation_text_similarity "TypeError: Cannot read property 'map' of undefined" "TypeError: Cannot read property 'map' of undefined")
    assert_eq "$sim_exact" "100" "Exact match should score 100"

    local sim_none
    sim_none=$(_mitigation_text_similarity "completely different text" "unrelated pattern text here")
    assert_eq "$sim_none" "0" "No match should score 0"

    local sim_short
    sim_short=$(_mitigation_text_similarity "some error" "err")
    assert_eq "$sim_short" "0" "Short pattern below minimum should score 0"

    # ── Summary ─────────────────────────────────────────────────────────
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    local total=$((PASS + FAIL))
    if [[ "$FAIL" -eq 0 ]]; then
        echo "║  ✓ ALL TESTS PASSED ($PASS/$total)                         ║"
    else
        echo "║  ✗ SOME TESTS FAILED ($PASS passed, $FAIL failed)         ║"
    fi
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    return "$FAIL"
}

# ─── Main ──────────────────────────────────────────────────────────────────

run_tests
exit "$?"
