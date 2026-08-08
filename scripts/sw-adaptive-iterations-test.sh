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
adaptive_iterations_suggest "medium" "feature" >/dev/null
budget="$ADAPTIVE_SUGGESTED"
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
adaptive_iterations_suggest "medium" "feature" >/dev/null
budget="$ADAPTIVE_SUGGESTED"
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

# ─── Test 19: Cohort Round-Trip (emit → read back) ────────────────────────
#
# Regression guard for the defect that made this feature inert in production:
# every test above hand-authored fixture events carrying a "cohort" field, but
# sw-loop.sh's real loop.iteration_complete emission did not include one. So the
# reader always saw cohort "default" and cohort-specific history never
# accumulated. These assertions close the loop end to end.

info "Test 19: Cohort round-trip through the real emit path"

# The emitter side: sw-loop.sh must actually put a cohort on the event.
loop_emission=$(grep -A9 'emit_event "loop.iteration_complete"' "$SCRIPT_DIR/sw-loop.sh")
assert_contains "$loop_emission" "cohort=" \
    "sw-loop.sh emits cohort= on loop.iteration_complete"

# The cohort must be computed for every run, not only when acting is enabled —
# otherwise history can never bootstrap.
budget_fn=$(sed -n '/^apply_adaptive_budget()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")
assert_contains "$budget_fn" "ADAPTIVE_COHORT=\$(adaptive_iterations_cohort" \
    "apply_adaptive_budget computes the cohort key"

# The reader side: events written by the real emit_event are consumable.
roundtrip_home="$TMPDIR/roundtrip"
mkdir -p "$roundtrip_home/.shipwright"
roundtrip_events="$roundtrip_home/.shipwright/events.jsonl"

HOME="$roundtrip_home" EVENTS_FILE="$roundtrip_events" bash -c '
    set -uo pipefail
    source "'"$SCRIPT_DIR"'/lib/helpers.sh"
    for i in 2 4 6 8 10; do
        emit_event "loop.iteration_complete" \
            "iteration=$i" "job_id=rt-$i" "cohort=medium-feature" "status=running"
    done
' >/dev/null 2>&1

roundtrip_samples=$(_iter_samples_for_cohort "medium-feature" "$roundtrip_events")
roundtrip_count=$(echo "$roundtrip_samples" | awk 'NF {c++} END {print c+0}')
assert_equals "5" "$roundtrip_count" \
    "Real emit_event output is readable by _iter_samples_for_cohort"

roundtrip_p90=$(echo "$roundtrip_samples" | _iter_percentile 90)
assert_equals "10" "$roundtrip_p90" "Round-tripped samples produce the expected P90"

# A different cohort must not pick these up.
other_count=$(_iter_samples_for_cohort "high-security" "$roundtrip_events" | awk 'NF {c++} END {print c+0}')
assert_equals "0" "$other_count" "Cohort filter excludes non-matching cohorts"

# ─── Test 20: Adversarial Cohort Labels ───────────────────────────────────
#
# Cohort keys are derived from issue labels, which are attacker-influenced on a
# public repo. They are passed to jq via --arg and never interpolated into the
# jq program, so quotes, backslashes, `$` and backticks must be inert.

info "Test 20: Adversarial characters in cohort labels"

adversarial_home="$TMPDIR/adversarial"
mkdir -p "$adversarial_home/.shipwright"
adversarial_events="$adversarial_home/.shipwright/events.jsonl"

# shellcheck disable=SC2016  # the metacharacters are the point — do not expand
adversarial_label='he said "hi" \ $(touch /tmp/sw-pwned) `id` $HOME'
adversarial_cohort=$(adaptive_iterations_cohort "high" "$adversarial_label")

HOME="$adversarial_home" EVENTS_FILE="$adversarial_events" \
ADV_COHORT="$adversarial_cohort" bash -c '
    set -uo pipefail
    source "'"$SCRIPT_DIR"'/lib/helpers.sh"
    for i in 1 2 3 4 5; do
        emit_event "loop.iteration_complete" \
            "iteration=$i" "job_id=adv-$i" "cohort=$ADV_COHORT"
    done
' >/dev/null 2>&1

# Every emitted line must still be valid JSON — no escaping breakage.
adversarial_valid=$(jq -c . "$adversarial_events" 2>/dev/null | wc -l | tr -d ' ')
assert_equals "5" "$adversarial_valid" "Adversarial label produces valid JSON events"

adversarial_count=$(_iter_samples_for_cohort "$adversarial_cohort" "$adversarial_events" \
    | awk 'NF {c++} END {print c+0}')
assert_equals "5" "$adversarial_count" "Adversarial cohort round-trips exactly"

# The jq filter must not have been altered into matching everything.
benign_count=$(_iter_samples_for_cohort "high-benign" "$adversarial_events" \
    | awk 'NF {c++} END {print c+0}')
assert_equals "0" "$benign_count" "Adversarial label does not widen the jq filter"

# Nothing was executed as a side effect.
[[ ! -e /tmp/sw-pwned ]] && { success "No command injection from cohort label"; PASS=$((PASS+1)); } || \
    { error "Cohort label caused command execution"; FAIL=$((FAIL+1)); rm -f /tmp/sw-pwned; }

# ─── Test 21: Lookback and Scan Bounds ────────────────────────────────────
#
# events.jsonl grows for the life of the machine. Reading it must stay bounded
# in both samples considered and wall-clock, or every loop start pays for the
# whole history. The old implementation spawned one jq per line: on this file it
# would have been ~10,000 processes.

info "Test 21: Bounded scan over a large events file"

large_events="$TMPDIR/large-events.jsonl"
{
    for i in $(seq 1 10000); do
        echo "{\"ts\":\"2026-08-01T00:00:00Z\",\"type\":\"loop.iteration_complete\",\"iteration\":$(( i % 12 + 1 )),\"job_id\":\"job-$i\",\"cohort\":\"bulk\"}"
    done
} > "$large_events"

large_start=$(date +%s)
large_samples=$(_iter_samples_for_cohort "bulk" "$large_events")
large_global=$(_iter_samples_global "$large_events")
large_elapsed=$(( $(date +%s) - large_start ))

large_count=$(echo "$large_samples" | awk 'NF {c++} END {print c+0}')
assert_equals "$ITERATIONS_LOOKBACK" "$large_count" \
    "Cohort samples bounded to ITERATIONS_LOOKBACK on a 10k-line file"

global_count=$(echo "$large_global" | awk 'NF {c++} END {print c+0}')
assert_equals "$ITERATIONS_LOOKBACK" "$global_count" \
    "Global samples bounded to ITERATIONS_LOOKBACK on a 10k-line file"

[[ "$large_elapsed" -lt 5 ]] && { success "10k-line file scanned in ${large_elapsed}s (< 5s)"; PASS=$((PASS+1)); } || \
    { error "Scanning 10k lines took ${large_elapsed}s, expected < 5s"; FAIL=$((FAIL+1)); }

# ─── Test 22: Tier and Sample Count Reporting ─────────────────────────────
#
# The budget number alone is not traceable — loop.budget_selected must be able
# to say which tier produced it and how many samples it saw.

info "Test 22: suggest() reports tier and sample count"

tier_events="$TMPDIR/tier-events.jsonl"
export ITERATIONS_HISTORY_FILE="$tier_events"

: > "$tier_events"
adaptive_iterations_suggest "medium" "feature" >/dev/null
budget="$ADAPTIVE_SUGGESTED"
assert_equals "fallback" "$ADAPTIVE_TIER" "Empty history reports the fallback tier"
assert_equals "0" "$ADAPTIVE_SAMPLES" "Fallback tier reports zero samples"
assert_equals "20" "$budget" "Fallback tier returns the static default"

for i in 3 4 5 6 7; do
    echo "{\"type\":\"loop.iteration_complete\",\"iteration\":$i,\"cohort\":\"medium-feature\"}" >> "$tier_events"
done
adaptive_iterations_suggest "medium" "feature" >/dev/null
budget="$ADAPTIVE_SUGGESTED"
assert_equals "cohort" "$ADAPTIVE_TIER" "Sufficient cohort history reports the cohort tier"
assert_equals "5" "$ADAPTIVE_SAMPLES" "Cohort tier reports its sample count"
assert_equals "8" "$budget" "Cohort tier returns P90 + 1"

: > "$tier_events"
for j in 1 2 3; do
    for i in 1 2 3; do
        echo "{\"type\":\"loop.iteration_complete\",\"iteration\":$i,\"job_id\":\"g$j\"}" >> "$tier_events"
    done
done
adaptive_iterations_suggest "medium" "feature" >/dev/null
budget="$ADAPTIVE_SUGGESTED"
assert_equals "global" "$ADAPTIVE_TIER" "No cohort history falls through to the global tier"
assert_equals "3" "$ADAPTIVE_SAMPLES" "Global tier reports one sample per job"
assert_equals "4" "$budget" "Global tier returns P90 + 1"

# ─── Test 23: Budget Explanation Is Wired Into the Loop ───────────────────

info "Test 23: sw-loop.sh logs the explanation, not just the number"

assert_contains "$budget_fn" "adaptive_iterations_explain" \
    "apply_adaptive_budget explains the chosen budget"

explanation=$(adaptive_iterations_explain "medium-feature" "8" "global" "3")
assert_contains "$explanation" "Global history" "Global tier explanation names the tier"
assert_contains "$explanation" "3 samples" "Global tier explanation reports the sample count"

# ─── Test 24: Nearest-Rank Percentile Keeps the Slow Tail ─────────────────
#
# Regression: the rank was computed by rounding rather than ceiling, which lands
# one index low for many sample counts (6-9, 16-19, ... at p=90). That silently
# discarded the slowest runs — the exact tail an iteration budget exists to
# cover. Six samples is the first divergent count, and sits right above the
# 5-sample cohort threshold, so real cohorts hit it immediately.

info "Test 24: P90 uses nearest-rank (ceil), not a rounded rank"

# ceil(0.9 * 6) = 6 → the 6th value. A rounded rank would return the 5th (5).
p90_six=$(printf '1\n2\n3\n4\n5\n20\n' | _iter_percentile 90)
assert_equals "20" "$p90_six" "P90 of 6 samples takes the 6th value, not the 5th"

# ceil(0.9 * 16) = 15 → the 15th value. A rounded rank would return the 14th.
p90_sixteen=$(printf '%s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 | _iter_percentile 90)
assert_equals "15" "$p90_sixteen" "P90 of 16 samples takes the 15th value, not the 14th"

# Exact ranks stay put: ceil(0.9 * 10) = 9, no rounding either way.
p90_ten=$(printf '%s\n' 1 2 3 4 5 6 7 8 9 10 | _iter_percentile 90)
assert_equals "9" "$p90_ten" "P90 of 10 samples is unchanged when the rank is exact"

# The budget derived from a divergent cohort reflects the tail (20 + 1).
cat > "$events_file" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"1","cohort":"medium-tail"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"2","cohort":"medium-tail"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"3","cohort":"medium-tail"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"4","cohort":"medium-tail"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"5","cohort":"medium-tail"}
{"ts":"2026-08-01T00:00:00Z","type":"loop.iteration_complete","iteration":"20","cohort":"medium-tail"}
EOF
export ITERATIONS_HISTORY_FILE="$events_file"
budget=$(adaptive_iterations_suggest "medium" "tail")
assert_equals "21" "$budget" "Six-sample cohort budgets for the slow tail (P90 20 + 1)"

# ─── Summary ───────────────────────────────────────────────────────────────

echo ""
echo "Test Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
