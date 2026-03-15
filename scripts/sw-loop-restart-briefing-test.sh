#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop-restart-briefing test — Intelligent briefing system     ║
# ║                                                                         ║
# ║  Tests change categorization, error pattern extraction, iteration       ║
# ║  history summarization, and recommendation generation.                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the module
source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/compat.sh" 2>/dev/null || true
source "$SCRIPT_DIR/lib/loop-restart-briefing.sh" 2>/dev/null || {
    echo "FAIL: Could not source loop-restart-briefing.sh"
    exit 1
}

PASS=0
FAIL=0

# ─── Test 1: categorize_changes with no modified files ────────────────────

echo -n "Test 1: categorize_changes with no modified files... "
test_dir=$(mktemp -d)
(
    cd "$test_dir"
    git init --quiet && git config user.email "test@example.com" && git config user.name "Test"
    touch README.md && git add README.md && git commit -q -m "Initial"

    result=$(briefing_categorize_changes "$test_dir" 2>/dev/null || echo '{}')
    echo "$result" | jq . > /dev/null 2>&1 || { echo "Invalid JSON"; exit 1; }
    total=$(echo "$result" | jq '.total // 0' 2>/dev/null || echo 0)
    [[ "$total" == 0 ]] || { echo "Expected 0 total, got $total"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi
rm -rf "$test_dir"

# ─── Test 2: categorize_changes with mixed file types ────────────────────

echo -n "Test 2: categorize_changes with mixed file types... "
test_dir=$(mktemp -d)
(
    cd "$test_dir"
    git init --quiet && git config user.email "test@example.com" && git config user.name "Test"
    mkdir -p src test docs
    touch README.md src/main.js test/test.js docs/guide.md config.json
    git add . && git commit -q -m "Initial"
    echo "modified" > src/main.js && echo "modified" > test/test.js && echo "modified" > docs/guide.md

    result=$(briefing_categorize_changes "$test_dir" 2>/dev/null || echo '{}')
    echo "$result" | jq . > /dev/null 2>&1 || { echo "Invalid JSON"; exit 1; }

    source_count=$(echo "$result" | jq '.source.count // 0' 2>/dev/null || echo 0)
    test_count=$(echo "$result" | jq '.test.count // 0' 2>/dev/null || echo 0)
    docs_count=$(echo "$result" | jq '.docs.count // 0' 2>/dev/null || echo 0)

    [[ "$source_count" == "1" ]] || { echo "Expected source_count=1, got $source_count"; exit 1; }
    [[ "$test_count" == "1" ]] || { echo "Expected test_count=1, got $test_count"; exit 1; }
    [[ "$docs_count" == "1" ]] || { echo "Expected docs_count=1, got $docs_count"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi
rm -rf "$test_dir"

# ─── Test 3: extract_error_patterns with no errors ────────────────────

echo -n "Test 3: extract_error_patterns with no errors... "
test_dir=$(mktemp -d)
(
    result=$(briefing_extract_error_patterns "$test_dir/nonexistent.json" 2>/dev/null || echo '{}')
    echo "$result" | jq . > /dev/null 2>&1 || { echo "Invalid JSON"; exit 1; }
    error_count=$(echo "$result" | jq '.error_count // 0' 2>/dev/null || echo 0)
    [[ "$error_count" == 0 ]] || { echo "Expected error_count=0, got $error_count"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi
rm -rf "$test_dir"

# ─── Test 4: extract_error_patterns with errors ────────────────────

echo -n "Test 4: extract_error_patterns with errors... "
test_dir=$(mktemp -d)
(
    error_file="$test_dir/error-summary.json"
    cat > "$error_file" <<'EOF'
{
  "error_count": 3,
  "errors": [
    {"message": "TypeError: Cannot read property 'foo' of undefined"},
    {"message": "TypeError: Cannot read property 'foo' of undefined"},
    {"message": "SyntaxError: Unexpected token }"}
  ],
  "patterns": ["type_error", "syntax_error"]
}
EOF
    result=$(briefing_extract_error_patterns "$error_file" 2>/dev/null || echo '{}')
    echo "$result" | jq . > /dev/null 2>&1 || { echo "Invalid JSON"; exit 1; }
    error_count=$(echo "$result" | jq '.error_count // 0' 2>/dev/null || echo 0)
    [[ "$error_count" == 3 ]] || { echo "Expected error_count=3, got $error_count"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi
rm -rf "$test_dir"

# ─── Test 5: summarize_iterations with no history ────────────────────

echo -n "Test 5: summarize_iterations with no history... "
test_dir=$(mktemp -d)
(
    result=$(briefing_summarize_iterations "$test_dir" 2>/dev/null || echo '{}')
    echo "$result" | jq . > /dev/null 2>&1 || { echo "Invalid JSON"; exit 1; }
    attempts=$(echo "$result" | jq '.total_attempts // 0' 2>/dev/null || echo 0)
    [[ "$attempts" == 0 ]] || { echo "Expected attempts=0, got $attempts"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi
rm -rf "$test_dir"

# ─── Test 6: summarize_iterations with history ────────────────────

echo -n "Test 6: summarize_iterations with history... "
test_dir=$(mktemp -d)
(
    progress_file="$test_dir/progress.md"
    restart_history="$test_dir/restart-history.json"

    cat > "$progress_file" <<'EOF'
## Iteration 1
✓ PASSED: test_foo
✗ FAILED: test_bar

## Iteration 2
✓ PASSED: test_foo
✓ PASSED: test_bar

## Iteration 3
✓ PASSED: test_foo
EOF

    cat > "$restart_history" <<'EOF'
[
  {"restart_number": 1, "iteration": 10, "test_passed": false},
  {"restart_number": 2, "iteration": 15, "test_passed": true}
]
EOF

    result=$(briefing_summarize_iterations "$test_dir" 2>/dev/null || echo '{}')
    echo "$result" | jq . > /dev/null 2>&1 || { echo "Invalid JSON"; exit 1; }
    restart_count=$(echo "$result" | jq '.restart_count // 0' 2>/dev/null || echo 0)
    [[ "$restart_count" == 2 ]] || { echo "Expected restart_count=2, got $restart_count"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi
rm -rf "$test_dir"

# ─── Test 7: recommend_next_steps for context_exhaustion ────────────────────

echo -n "Test 7: recommend_next_steps for context_exhaustion... "
(
    error_json='{\"error_count\": 0}'
    iter_json='{\"restart_count\": 1, \"total_attempts\": 20}'
    changes_json='{\"source\": {\"count\": 5}, \"test\": {\"count\": 0}}'

    result=$(briefing_recommend_next_steps "context_exhaustion" "$error_json" "$iter_json" "$changes_json" 2>/dev/null || echo '{}')
    echo "$result" | jq . > /dev/null 2>&1 || { echo "Invalid JSON"; exit 1; }
    priority=$(echo "$result" | jq -r '.priority // ""' 2>/dev/null || echo "")
    [[ "$priority" == "high" ]] || { echo "Expected priority=high, got $priority"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi

# ─── Test 8: recommend_next_steps for stuck_loop ────────────────────

echo -n "Test 8: recommend_next_steps for stuck_loop... "
(
    error_json='{\"error_count\": 5}'
    iter_json='{\"restart_count\": 0}'
    changes_json='{\"source\": {\"count\": 2}}'

    result=$(briefing_recommend_next_steps "stuck_loop" "$error_json" "$iter_json" "$changes_json" 2>/dev/null || echo '{}')
    echo "$result" | jq . > /dev/null 2>&1 || { echo "Invalid JSON"; exit 1; }
    priority=$(echo "$result" | jq -r '.priority // ""' 2>/dev/null || echo "")
    [[ "$priority" == "critical" ]] || { echo "Expected priority=critical, got $priority"; exit 1; }
    has_recs=$(echo "$result" | jq '.recommendations | length // 0' 2>/dev/null || echo 0)
    [[ "$has_recs" -gt 0 ]] || { echo "Expected recommendations, got none"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi

# ─── Test 9: generate_enhanced_briefing ────────────────────

echo -n "Test 9: generate_enhanced_briefing... "
test_dir=$(mktemp -d)
(
    cd "$test_dir"
    git init --quiet && git config user.email "test@example.com" && git config user.name "Test"
    touch README.md && git add README.md && git commit -q -m "Initial"
    echo "modified" > README.md

    state_file="./restart-state.json"
    cat > "$state_file" <<'EOF'
{
  "timestamp": "2026-03-15T10:00:00Z",
  "goal": "Build feature X",
  "progress": {
    "iteration": 5,
    "max_iterations": 20,
    "test_status": "false"
  },
  "restart_count": 1
}
EOF

    output_file="./briefing-output.md"
    briefing_generate_enhanced "$state_file" "stuck_loop" "$output_file" 2>/dev/null || { echo "Failed to generate"; exit 1; }

    [[ -f "$output_file" ]] || { echo "Output file not created"; exit 1; }
    grep -q "# Intelligent Session Restart Briefing" "$output_file" || { echo "Missing briefing header"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi
rm -rf "$test_dir"

# ─── Test 10: generate_enhanced_briefing with invalid state ────────────────────

echo -n "Test 10: generate_enhanced_briefing with invalid state... "
test_dir=$(mktemp -d)
(
    cd "$test_dir"
    state_file="./nonexistent.json"
    output_file="./briefing-output.md"

    briefing_generate_enhanced "$state_file" "unknown" "$output_file" 2>/dev/null && { echo "Should have failed"; exit 1; }
    [[ ! -f "$output_file" ]] || { echo "Output file should not be created"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi
rm -rf "$test_dir"

# ─── Test 11: module exports ────────────────────

echo -n "Test 11: module exports... "
(
    [[ "$(type -t briefing_categorize_changes)" == "function" ]] || { echo "briefing_categorize_changes not exported"; exit 1; }
    [[ "$(type -t briefing_extract_error_patterns)" == "function" ]] || { echo "briefing_extract_error_patterns not exported"; exit 1; }
    [[ "$(type -t briefing_summarize_iterations)" == "function" ]] || { echo "briefing_summarize_iterations not exported"; exit 1; }
    [[ "$(type -t briefing_recommend_next_steps)" == "function" ]] || { echo "briefing_recommend_next_steps not exported"; exit 1; }
    [[ "$(type -t briefing_generate_enhanced)" == "function" ]] || { echo "briefing_generate_enhanced not exported"; exit 1; }
)
if [[ $? -eq 0 ]]; then
    echo "PASS"
    ((PASS++))
else
    echo "FAIL"
    ((FAIL++))
fi

# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test Results: $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
