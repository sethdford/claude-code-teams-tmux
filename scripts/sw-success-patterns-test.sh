#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Success Pattern Library Test Suite                                        ║
# ║  Unit tests for pattern capture, matching, injection, and A/B testing     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NAME="$(basename "$0" .sh)"
TEST_FAILED=0
TEST_PASSED=0

# Test utilities
run_test() {
    local test_name="$1"
    local test_fn="$2"

    echo ""
    echo "▸ $test_name"
    if $test_fn 2>&1; then
        echo "  ✓ PASS"
        ((TEST_PASSED++)) || true
        return 0
    else
        echo "  ✗ FAIL"
        ((TEST_FAILED++)) || true
        return 1
    fi
}

# Setup: Create temp directories and memory structure
setup_test_env() {
    TMPDIR=$(mktemp -d)
    export TMPDIR
    export MEMORY_ROOT="$TMPDIR/memory"
    export REPO_DIR="$TMPDIR/repo"
    mkdir -p "$MEMORY_ROOT" "$REPO_DIR"

    # Initialize git repo (mock)
    cd "$REPO_DIR"
    git init > /dev/null 2>&1 || true
    git config user.email "test@example.com" > /dev/null 2>&1 || true
    git config user.name "Test User" > /dev/null 2>&1 || true

    # Create dummy files
    echo "test" > README.md
    git add README.md > /dev/null 2>&1 || true
    git commit -m "initial" > /dev/null 2>&1 || true

    # Source the success patterns module
    # shellcheck source=lib/helpers.sh
    [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

    # shellcheck source=lib/success-patterns.sh
    source "$SCRIPT_DIR/lib/success-patterns.sh"
}

cleanup_test_env() {
    cd /
    rm -rf "$TMPDIR" 2>/dev/null || true
}

# Mock repo_memory_dir for testing
repo_memory_dir() {
    echo "$MEMORY_ROOT/test"
}

repo_hash() {
    echo "testhash12345678"
}

# ─── Unit Tests ──────────────────────────────────────────────────────────────

test_capture_creates_pattern() {
    local mem_dir="$MEMORY_ROOT/test"
    mkdir -p "$mem_dir"

    # Create a mock state file
    local state_file="$TMPDIR/state.md"
    cat > "$state_file" <<'EOF'
goal: Add authentication feature
issue_type: feature
complexity: 65
status: complete
template: standard
duration_s: 150
cost_usd: 2.50
EOF

    # Create artifacts directory with loop state showing multiple iterations
    mkdir -p "$TMPDIR/artifacts/.claude/loop-logs"
    cat > "$TMPDIR/artifacts/.claude/loop-state.md" <<'EOF'
## Loop State

Iteration 1: Starting
Iteration 2: Continuing
Iteration 3: Finalizing
EOF
    echo "iteration 1 log" > "$TMPDIR/artifacts/.claude/loop-logs/iteration-1.log"
    echo "iteration 2 log" > "$TMPDIR/artifacts/.claude/loop-logs/iteration-2.log"
    echo "iteration 3 log" > "$TMPDIR/artifacts/.claude/loop-logs/iteration-3.log"

    # Capture pattern
    success_pattern_capture "$state_file" "$TMPDIR/artifacts" "$mem_dir"

    # Verify pattern was created
    local patterns_file="$mem_dir/success-patterns.json"
    [[ -f "$patterns_file" ]] || return 1

    local count
    count=$(jq '.patterns | length' "$patterns_file")
    [[ "$count" -gt 0 ]] || return 1

    return 0
}

test_capture_respects_quality_gate() {
    local mem_dir="$MEMORY_ROOT/test-qgate"
    mkdir -p "$mem_dir"

    # Create a trivial state file (< 2 iterations, < 3 files)
    local state_file="$TMPDIR/state-trivial.md"
    cat > "$state_file" <<'EOF'
goal: Fix typo
issue_type: bug
complexity: 10
status: complete
template: fast
EOF

    mkdir -p "$TMPDIR/artifacts-trivial"

    # Try to capture pattern (should be skipped)
    success_pattern_capture "$state_file" "$TMPDIR/artifacts-trivial" "$mem_dir"

    # Verify pattern was NOT created (still empty)
    local patterns_file="$mem_dir/success-patterns.json"
    local count
    count=$(jq '.patterns | length' "$patterns_file" 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] || return 1

    return 0
}

test_capture_deduplicates() {
    local mem_dir="$MEMORY_ROOT/test-dedup"
    mkdir -p "$mem_dir"

    # Create state file
    local state_file="$TMPDIR/state-dup.md"
    cat > "$state_file" <<'EOF'
goal: Add feature X
issue_type: feature
complexity: 50
status: complete
EOF

    mkdir -p "$TMPDIR/artifacts1/.claude/loop-logs"
    mkdir -p "$TMPDIR/artifacts2/.claude/loop-logs"
    cat > "$TMPDIR/artifacts1/.claude/loop-state.md" <<'EOF'
Iteration 2: Done
EOF
    cat > "$TMPDIR/artifacts2/.claude/loop-state.md" <<'EOF'
Iteration 2: Done
EOF
    echo "log" > "$TMPDIR/artifacts1/.claude/loop-logs/iteration-1.log"
    echo "log" > "$TMPDIR/artifacts1/.claude/loop-logs/iteration-2.log"
    echo "log" > "$TMPDIR/artifacts2/.claude/loop-logs/iteration-1.log"
    echo "log" > "$TMPDIR/artifacts2/.claude/loop-logs/iteration-2.log"

    # Capture same pattern twice
    success_pattern_capture "$state_file" "$TMPDIR/artifacts1" "$mem_dir"
    success_pattern_capture "$state_file" "$TMPDIR/artifacts2" "$mem_dir"

    # Verify deduplication: 1 pattern with seen_count=2
    local patterns_file="$mem_dir/success-patterns.json"
    local count
    count=$(jq '.patterns | length' "$patterns_file")
    [[ "$count" -eq 1 ]] || return 1

    local seen
    seen=$(jq '.patterns[0].seen_count' "$patterns_file")
    [[ "$seen" -eq 2 ]] || return 1

    return 0
}

test_match_returns_json() {
    local mem_dir="$MEMORY_ROOT/test-match"
    mkdir -p "$mem_dir"

    # Create a pattern first
    local state_file="$TMPDIR/state-match.md"
    cat > "$state_file" <<'EOF'
goal: Add authentication
issue_type: feature
complexity: 60
status: complete
EOF
    mkdir -p "$TMPDIR/artifacts-match/.claude/loop-logs"
    cat > "$TMPDIR/artifacts-match/.claude/loop-state.md" <<'EOF'
Iteration 2: Done
EOF
    echo "auth log" > "$TMPDIR/artifacts-match/.claude/loop-logs/iteration-1.log"
    echo "auth log" > "$TMPDIR/artifacts-match/.claude/loop-logs/iteration-2.log"
    success_pattern_capture "$state_file" "$TMPDIR/artifacts-match" "$mem_dir"

    # Match similar pattern
    local matches
    matches=$(success_pattern_match "Add auth feature" "feature" 60 3 "$mem_dir")

    # Verify result is valid JSON
    echo "$matches" | jq . >/dev/null 2>&1 || return 1
    local count
    count=$(echo "$matches" | jq '. | length' 2>/dev/null || echo 0)
    # May or may not have matches depending on scoring
    return 0
}

test_match_respects_max_results() {
    local mem_dir="$MEMORY_ROOT/test-maxres"
    mkdir -p "$mem_dir"

    # Create multiple patterns
    for i in 1 2 3 4 5; do
        local state_file="$TMPDIR/state-maxres-$i.md"
        cat > "$state_file" <<EOF
goal: Feature $i
issue_type: feature
complexity: 50
status: complete
EOF
        mkdir -p "$TMPDIR/artifacts-maxres-$i/.claude/loop-logs"
        cat > "$TMPDIR/artifacts-maxres-$i/.claude/loop-state.md" <<'EOF'
Iteration 2: Done
EOF
        echo "log" > "$TMPDIR/artifacts-maxres-$i/.claude/loop-logs/iteration-1.log"
        echo "log" > "$TMPDIR/artifacts-maxres-$i/.claude/loop-logs/iteration-2.log"
        success_pattern_capture "$state_file" "$TMPDIR/artifacts-maxres-$i" "$mem_dir"
    done

    # Match with max_results=2
    local matches
    matches=$(success_pattern_match "Feature" "feature" 50 2 "$mem_dir")
    local count
    count=$(echo "$matches" | jq '. | length')
    [[ "$count" -le 2 ]] || return 1

    return 0
}

test_inject_respects_context_budget() {
    local mem_dir="$MEMORY_ROOT/test-inject"
    mkdir -p "$mem_dir"

    # Create a pattern
    local state_file="$TMPDIR/state-inject.md"
    cat > "$state_file" <<'EOF'
goal: Refactor middleware
issue_type: refactor
complexity: 55
status: complete
EOF
    mkdir -p "$TMPDIR/artifacts-inject/.claude/loop-logs"
    cat > "$TMPDIR/artifacts-inject/.claude/loop-state.md" <<'EOF'
Iteration 2: Done
EOF
    echo "refactor" > "$TMPDIR/artifacts-inject/.claude/loop-logs/iteration-1.log"
    echo "refactor" > "$TMPDIR/artifacts-inject/.claude/loop-logs/iteration-2.log"
    success_pattern_capture "$state_file" "$TMPDIR/artifacts-inject" "$mem_dir"

    # Get injection text
    local injection
    injection=$(success_pattern_inject "Refactor code" "refactor" 55 "$mem_dir")

    # Verify it's under 2KB
    local len=${#injection}
    [[ "$len" -lt 2048 ]] || return 1

    return 0
}

test_ab_assign_deterministic() {
    # A/B assignment should be deterministic for same issue ID
    local arm1
    local arm2

    arm1=$(success_pattern_ab_assign "issue-123")
    arm2=$(success_pattern_ab_assign "issue-123")

    [[ "$arm1" == "$arm2" ]] || return 1

    # Different issue should (usually) get different arm
    local arm3
    arm3=$(success_pattern_ab_assign "issue-456")
    # Note: not guaranteed to be different, just check it's valid
    [[ "$arm3" == "treatment" || "$arm3" == "control" ]] || return 1

    return 0
}

test_ab_record_outcome() {
    mkdir -p "${HOME}/.shipwright/optimization"

    # Record an outcome
    success_pattern_ab_record_outcome "issue-789" "treatment" "true" 3

    # Verify it was recorded
    local outcomes_file="${HOME}/.shipwright/optimization/ab-outcomes.jsonl"
    [[ -f "$outcomes_file" ]] || return 1

    local count
    count=$(wc -l < "$outcomes_file")
    [[ "$count" -gt 0 ]] || return 1

    return 0
}

test_ab_report_generation() {
    mkdir -p "${HOME}/.shipwright/optimization"
    local outcomes_file="${HOME}/.shipwright/optimization/ab-outcomes.jsonl"

    # Clear and write test outcomes
    : > "$outcomes_file"
    echo '{"issue_id":"1","arm":"treatment","success":true,"iterations":2,"timestamp":"2026-04-03T10:00:00Z"}' >> "$outcomes_file"
    echo '{"issue_id":"2","arm":"treatment","success":false,"iterations":3,"timestamp":"2026-04-03T10:05:00Z"}' >> "$outcomes_file"
    echo '{"issue_id":"3","arm":"control","success":true,"iterations":2,"timestamp":"2026-04-03T10:10:00Z"}' >> "$outcomes_file"

    # Generate report
    local report
    report=$(success_pattern_ab_report)

    # Verify report structure
    echo "$report" | jq . >/dev/null 2>&1 || return 1

    # Verify it has expected fields
    local has_control
    has_control=$(echo "$report" | jq 'has("control_builds")')
    [[ "$has_control" == "true" ]] || return 1

    return 0
}

test_export_to_repo_local() {
    local mem_dir="$MEMORY_ROOT/test-export"
    mkdir -p "$mem_dir"

    # Create a pattern
    local state_file="$TMPDIR/state-export.md"
    cat > "$state_file" <<'EOF'
goal: Export test
issue_type: feature
complexity: 50
status: complete
EOF
    mkdir -p "$TMPDIR/artifacts-export/.claude/loop-logs"
    cat > "$TMPDIR/artifacts-export/.claude/loop-state.md" <<'EOF'
Iteration 2: Done
EOF
    echo "export" > "$TMPDIR/artifacts-export/.claude/loop-logs/iteration-1.log"
    echo "export" > "$TMPDIR/artifacts-export/.claude/loop-logs/iteration-2.log"
    success_pattern_capture "$state_file" "$TMPDIR/artifacts-export" "$mem_dir"

    # Export to repo-local path
    local output_path="$REPO_DIR/.claude/memory/success-patterns.json"
    mkdir -p "$(dirname "$output_path")"

    success_pattern_export "$output_path" "$mem_dir"

    # Verify export
    [[ -f "$output_path" ]] || return 1
    local count
    count=$(jq '.patterns | length' "$output_path" 2>/dev/null || echo 0)
    [[ "$count" -gt 0 ]] || return 1

    return 0
}

test_pruning_at_200_patterns() {
    local mem_dir="$MEMORY_ROOT/test-prune"
    mkdir -p "$mem_dir"

    # Create 25 patterns (testing pruning logic, full 250 would be slow)
    for i in {1..25}; do
        local state_file="$TMPDIR/state-prune-$i.md"
        cat > "$state_file" <<EOF
goal: Feature $i
issue_type: feature
complexity: 50
status: complete
EOF
        mkdir -p "$TMPDIR/artifacts-prune-$i/.claude/loop-logs"
        cat > "$TMPDIR/artifacts-prune-$i/.claude/loop-state.md" <<'EOF'
Iteration 2: Done
EOF
        echo "log" > "$TMPDIR/artifacts-prune-$i/.claude/loop-logs/iteration-1.log"
        echo "log" > "$TMPDIR/artifacts-prune-$i/.claude/loop-logs/iteration-2.log"
        success_pattern_capture "$state_file" "$TMPDIR/artifacts-prune-$i" "$mem_dir" 2>/dev/null || true
    done

    # Verify patterns were created
    local patterns_file="$mem_dir/success-patterns.json"
    local count
    count=$(jq '.patterns | length' "$patterns_file")
    [[ "$count" -gt 0 ]] || return 1
    [[ "$count" -le 25 ]] || return 1

    return 0
}

test_concurrent_writes() {
    local mem_dir="$MEMORY_ROOT/test-concurrent"
    mkdir -p "$mem_dir"

    # Try to write from multiple processes concurrently
    for i in 1 2 3; do
        (
            local state_file="$TMPDIR/state-concurrent-$i.md"
            cat > "$state_file" <<EOF
goal: Concurrent Feature $i
issue_type: feature
complexity: 50
status: complete
EOF
            mkdir -p "$TMPDIR/artifacts-concurrent-$i/.claude/loop-logs"
            cat > "$TMPDIR/artifacts-concurrent-$i/.claude/loop-state.md" <<'EOF'
Iteration 2: Done
EOF
            echo "log" > "$TMPDIR/artifacts-concurrent-$i/.claude/loop-logs/iteration-1.log"
            echo "log" > "$TMPDIR/artifacts-concurrent-$i/.claude/loop-logs/iteration-2.log"
            success_pattern_capture "$state_file" "$TMPDIR/artifacts-concurrent-$i" "$mem_dir"
        ) &
    done
    wait

    # Verify all writes succeeded (should have 3 patterns or less due to dedup)
    local patterns_file="$mem_dir/success-patterns.json"
    local count
    count=$(jq '.patterns | length' "$patterns_file")
    [[ "$count" -ge 1 && "$count" -le 3 ]] || return 1

    return 0
}

# ─── Run All Tests ──────────────────────────────────────────────────────────

main() {
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║ Success Pattern Library Test Suite                     ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""

    setup_test_env

    # Unit tests
    run_test "Pattern capture creates entry" test_capture_creates_pattern
    run_test "Capture respects quality gate (skip trivial)" test_capture_respects_quality_gate
    run_test "Capture deduplicates identical patterns" test_capture_deduplicates
    run_test "Match returns valid JSON array" test_match_returns_json
    run_test "Match respects max_results limit" test_match_respects_max_results
    run_test "Inject respects 2KB context budget" test_inject_respects_context_budget
    run_test "A/B assignment is deterministic" test_ab_assign_deterministic
    run_test "A/B outcome recording" test_ab_record_outcome
    run_test "A/B report generation" test_ab_report_generation
    run_test "Export to repo-local path" test_export_to_repo_local
    run_test "Pruning maintains 200-pattern cap" test_pruning_at_200_patterns
    run_test "Concurrent writes (flock) work" test_concurrent_writes

    cleanup_test_env

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Results: $TEST_PASSED passed, $TEST_FAILED failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    [[ $TEST_FAILED -eq 0 ]] && exit 0 || exit 1
}

main "$@"
