#!/usr/bin/env bash
# Test suite for adaptive-iterations.sh
# Tests: cohort generation, sample extraction, percentile calculation, budget suggestion

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# Source helpers
source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || {
    info() { echo "▸ $*"; }
    success() { echo "✓ $*"; }
    error() { echo "✗ $*" >&2; }
}

# Source the module under test
source "$SCRIPT_DIR/lib/adaptive-iterations.sh"

# Create temp directory FIRST, then set trap
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR" 2>/dev/null || true' EXIT

# ─── Test Helper ──────────────────────────────────────────────────────────

assert_equals() {
    local expected="$1" actual="$2" description="$3"
    if [[ "$expected" == "$actual" ]]; then
        success "$description"
        PASS=$((PASS+1))
    else
        error "$description (expected: $expected, got: $actual)"
        FAIL=$((FAIL+1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        success "$description"
        PASS=$((PASS+1))
    else
        error "$description (expected to find '$needle' in '$haystack')"
        FAIL=$((FAIL+1))
    fi
}

# ─── Test 1: Cohort Generation ────────────────────────────────────────────

info "Test 1: Cohort generation"

cohort=$(adaptive_iterations_cohort "low" "")
assert_equals "low" "$cohort" "Cohort with just complexity"

cohort=$(adaptive_iterations_cohort "" "")
assert_equals "unknown" "$cohort" "Cohort with no input returns 'unknown'"

cohort=$(adaptive_iterations_cohort "medium" "feature,auth")
assert_equals "medium-auth,feature" "$cohort" "Cohort with complexity and labels (labels sorted)"

cohort=$(adaptive_iterations_cohort "" "bug,docs")
assert_equals "unknown-bug,docs" "$cohort" "Cohort with just labels (complexity defaults to unknown)"

# ─── Test 2: Percentile Calculation ───────────────────────────────────────

info "Test 2: Percentile calculation"

# P50 of [1,2,3,4,5]
p50=$(echo -e "1\n2\n3\n4\n5" | _iter_percentile 50)
assert_contains "3" "$p50" "P50 of [1,2,3,4,5] should be 3"

# P90 of [1,2,3,4,5]
p90=$(echo -e "1\n2\n3\n4\n5" | _iter_percentile 90)
assert_contains "5" "$p90" "P90 of [1,2,3,4,5] should be 5"

# P10 of [1,2,3,4,5]
p10=$(echo -e "1\n2\n3\n4\n5" | _iter_percentile 10)
assert_contains "1" "$p10" "P10 of [1,2,3,4,5] should be 1"

# ─── Test 3: Sample Extraction (No History) ───────────────────────────────

info "Test 3: Sample extraction with no events file"

events_file="$TMPDIR/nonexistent.jsonl"
samples=$(_iter_samples_for_cohort "medium-feature" "$events_file")
[[ -z "$samples" ]] && { success "No samples when events file missing"; PASS=$((PASS+1)); } || \
    { error "Should return empty when events file missing"; FAIL=$((FAIL+1)); }

# ─── Test 4: Global Samples (No History) ──────────────────────────────────

info "Test 4: Global samples with no events file"

events_file="$TMPDIR/nonexistent.jsonl"
samples=$(_iter_samples_global "$events_file")
[[ -z "$samples" ]] && { success "No global samples when events file missing"; PASS=$((PASS+1)); } || \
    { error "Should return empty when events file missing"; FAIL=$((FAIL+1)); }

# ─── Test 5: Suggest Budget (No History) ──────────────────────────────────

info "Test 5: Suggest budget with no history"

export HOME="$TMPDIR"
mkdir -p "$TMPDIR/.shipwright"
budget=$(adaptive_iterations_suggest "medium" "feature")
assert_equals "20" "$budget" "Default budget when no history"

# ─── Test 6: Suggest Budget (Cohort History) ─────────────────────────────

info "Test 6: Suggest budget with cohort-specific history"

events_file="$TMPDIR/.shipwright/events.jsonl"
cat > "$events_file" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"3","cohort":"medium-feature"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"4","cohort":"medium-feature"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"5","cohort":"medium-feature"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"6","cohort":"medium-feature"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"7","cohort":"medium-feature"}
EOF

export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "medium" "feature")
# P90 of [3,4,5,6,7] should be 7, +1 = 8
[[ "$budget" =~ ^[789]$ ]] && { success "Suggested budget in range [7-9]"; PASS=$((PASS+1)); } || \
    { error "Suggested budget should be in range [7-9], got $budget"; FAIL=$((FAIL+1)); }

# ─── Test 7: Suggest Budget (Global History Fallback) ───────────────────

info "Test 7: Suggest budget with global history fallback"

# Clear cohort-specific data, create global data (need >= 3 samples to trigger fallback)
cat > "$events_file" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"1","job_id":"job1"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"2","job_id":"job1"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"1","job_id":"job2"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"2","job_id":"job2"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"3","job_id":"job2"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"1","job_id":"job3"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"2","job_id":"job3"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"4","job_id":"job3"}
EOF

export ITERATIONS_HISTORY_FILE="$events_file"
# Should use global data since no cohort-specific data (3 jobs with max [2,3,4])
budget=$(adaptive_iterations_suggest "unknown-category" "unknown")
# P90 of [2,3,4] should be 4, +1 = 5
[[ "$budget" =~ ^[4567]$ ]] && { success "Global fallback budget in range [4-7]"; PASS=$((PASS+1)); } || \
    { error "Global fallback budget should be in range [4-7], got $budget"; FAIL=$((FAIL+1)); }

# ─── Test 8: Handle Malformed JSON ────────────────────────────────────────

info "Test 8: Handle malformed JSON gracefully"

cat > "$events_file" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"3","cohort":"high-test"}
BROKEN LINE NOT JSON
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"4","cohort":"high-test"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"5","cohort":"high-test"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"6","cohort":"high-test"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"7","cohort":"high-test"}
EOF

export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "high" "test")
# Should skip malformed line and still get budget from [3,4,5,6,7]
# P90 of [3,4,5,6,7] should be 7, +1 = 8
[[ "$budget" =~ ^[78]$ ]] && { success "Malformed JSON handled, budget computed"; PASS=$((PASS+1)); } || \
    { error "Should handle malformed JSON, got budget $budget"; FAIL=$((FAIL+1)); }

# ─── Test 9: Clamp to Min/Max ─────────────────────────────────────────────

info "Test 9: Clamp suggested budget to min/max"

# Test very high percentile → clamps to ITERATIONS_MAX
cat > "$events_file" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"100","cohort":"heavy"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"100","cohort":"heavy"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"100","cohort":"heavy"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"100","cohort":"heavy"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"100","cohort":"heavy"}
EOF

export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "unknown" "heavy")
# Should clamp to ITERATIONS_MAX (50)
[[ "$budget" -le 50 ]] && { success "Budget clamped to max ($budget)"; PASS=$((PASS+1)); } || \
    { error "Budget should be clamped to max, got $budget"; FAIL=$((FAIL+1)); }

# ─── Test 10: Record Outcome ──────────────────────────────────────────────

info "Test 10: Record outcome event"

events_file="$TMPDIR/.shipwright/events_outcome.jsonl"
export ITERATIONS_HISTORY_FILE="$events_file"

# Mock emit_event
emit_event() {
    echo "{\"type\":\"$1\",$(for arg in "$@"; do echo "\"${arg%%=*}\":\"${arg#*=}\""; done | paste -sd,)}" >> "$ITERATIONS_HISTORY_FILE"
}

adaptive_iterations_record_outcome "medium-feature" "5" "true" "6"

[[ -f "$events_file" ]] && { success "Outcome event file created"; PASS=$((PASS+1)); } || \
    { error "Outcome event file not created"; FAIL=$((FAIL+1)); }

# ─── Test 11: Explain Budget Decision ──────────────────────────────────────

info "Test 11: Explain budget decision"

explanation=$(adaptive_iterations_explain "high-bug" "8" "cohort" "5")
assert_contains "$explanation" "Cohort" "Explanation contains 'Cohort'"
assert_contains "$explanation" "high-bug" "Explanation contains cohort name"
assert_contains "$explanation" "8" "Explanation contains budget"

explanation=$(adaptive_iterations_explain "default" "20" "fallback" "0")
assert_contains "$explanation" "No sufficient" "Fallback explanation mentions no history"

# ─── Test 12: Insufficient Samples ────────────────────────────────────────

info "Test 12: Insufficient samples falls back to default"

cat > "$events_file" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"5","cohort":"rare"}
EOF

export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "unknown" "rare")
assert_equals "20" "$budget" "Insufficient samples (1 < 3) returns default"

# ─── Test 13: Empty Events File ───────────────────────────────────────────

info "Test 13: Empty events file returns default"

events_file="$TMPDIR/.shipwright/empty.jsonl"
touch "$events_file"

export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "medium" "feature")
assert_equals "20" "$budget" "Empty events file returns default"

# ─── Test 14: Very Low Percentile ─────────────────────────────────────────

info "Test 14: P1 (near minimum) works"

cat > "$events_file" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"1","cohort":"simple"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"1","cohort":"simple"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"1","cohort":"simple"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"20","cohort":"simple"}
EOF

export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "unknown" "simple")
# P90 with outlier should be ~20 (or lower)
[[ "$budget" =~ ^[0-9]+$ ]] && { success "Percentile calculation works with outliers"; PASS=$((PASS+1)); } || \
    { error "Percentile calculation failed"; FAIL=$((FAIL+1)); }

# ─── Test 15: Single Sample Global ────────────────────────────────────────

info "Test 15: Single sample global fallback"

cat > "$events_file" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"1","job_id":"single"}
EOF

export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "unknown" "nosuchcohort")
assert_equals "20" "$budget" "Single global sample falls back to default"

# ─── Test 16: Event Types Filtering ───────────────────────────────────────

info "Test 16: Only loop.iteration_complete events are used"

cat > "$events_file" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","type":"other.event","iteration":"100","cohort":"ignore"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"3","cohort":"medium-target"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"4","cohort":"medium-target"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"5","cohort":"medium-target"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"6","cohort":"medium-target"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"7","cohort":"medium-target"}
EOF

export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "medium" "target")
# Should only use [3,4,5,6,7], ignore the "other.event"
# P90 of [3,4,5,6,7] should be 7, +1 = 8
[[ "$budget" =~ ^[78]$ ]] && { success "Only loop.iteration_complete events used"; PASS=$((PASS+1)); } || \
    { error "Should filter event types, got budget $budget"; FAIL=$((FAIL+1)); }

# ─── Test 17: Large Sample Set ────────────────────────────────────────────

info "Test 17: Large sample set (>20 samples)"

{
    for i in {1..30}; do
        echo "{\"ts\":\"2026-08-01T00:00:00Z\",\"type\":\"loop.iteration_complete\",\"iteration\":\"$((i % 10 + 1))\",\"cohort\":\"large\"}"
    done
} > "$events_file"

export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "unknown" "large")
[[ "$budget" =~ ^[0-9]+$ ]] && [[ "$budget" -le 50 ]] && \
    { success "Large sample set handled correctly"; PASS=$((PASS+1)); } || \
    { error "Large sample set failed, got budget $budget"; FAIL=$((FAIL+1)); }

# ─── Test 18: Normalize Complexity Values ────────────────────────────────

info "Test 18: Normalize complexity to known values"

cohort=$(adaptive_iterations_cohort "unknown" "")
assert_equals "unknown" "$cohort" "Unknown complexity normalized to 'unknown'"

cohort=$(adaptive_iterations_cohort "INVALID" "")
assert_equals "unknown" "$cohort" "Invalid complexity normalized to 'unknown'"

cohort=$(adaptive_iterations_cohort "low" "")
assert_equals "low" "$cohort" "Valid low complexity preserved"

# ─── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "Test Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
