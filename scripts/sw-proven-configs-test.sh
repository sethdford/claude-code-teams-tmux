#!/usr/bin/env bash
# Test Suite: Proven Configurations System (Comprehensive)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1.0.0"

echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo "║  Test Suite: Proven Configurations (16 test cases)                    ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""

# Source library
source "$SCRIPT_DIR/lib/proven-configs.sh" 2>/dev/null || { echo "ERROR: Cannot load library"; exit 1; }

PASS=0
FAIL=0

# Helper
test_assert() {
    local name="$1"
    local result="$2"
    if [[ "$result" == "0" ]]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (exit code: $result)"
        FAIL=$((FAIL + 1))
    fi
}

# Test 1: Directory creation
echo "Testing core library functions:"
echo ""
_proven_config_dir "test-repo" >/dev/null 2>&1
test_assert "01: Directory creation" "$?"

# Test 2: Keyword extraction
keywords=$(_proven_config_extract_keywords "fix authentication bug in login page" 2>/dev/null)
[[ "$keywords" == *"authentication"* ]] && [[ "$keywords" == *"bug"* ]] && rc=0 || rc=1
test_assert "02: Keyword extraction finds relevant words" "$rc"

# Test 3: Repo hash generation
hash=$(_proven_config_repo_hash "." 2>/dev/null)
[[ -n "$hash" && ${#hash} -gt 0 ]] && rc=0 || rc=1
test_assert "03: Repo hash generation" "$rc"

# Test 4: Label similarity (identical labels)
similarity=$(_proven_config_label_similarity "backend database" "backend database" 2>/dev/null)
[[ "$similarity" == "1"* ]] && rc=0 || rc=1
test_assert "04: Label similarity (identical)" "$rc"

# Test 5: List returns valid JSON
list_output=$(proven_config_list "test" 2>/dev/null)
echo "$list_output" | jq empty 2>/dev/null && rc=0 || rc=1
test_assert "05: List returns valid JSON" "$rc"

# Test 6: Stats returns valid JSON with expected fields
stats=$(proven_config_stats "test" 2>/dev/null)
echo "$stats" | jq '.total_configs' >/dev/null 2>&1 && rc=0 || rc=1
test_assert "06: Stats returns valid JSON with fields" "$rc"

# Test 7: Match on empty repo returns gracefully
result=$(proven_config_match "bug" 5 "backend" "fix auth bug" "." 2>/dev/null || true)
[[ -z "$result" ]] && rc=0 || rc=1
test_assert "07: Match on empty repo returns empty" "$rc"

# Test 8: Apply sets PIPELINE_TEMPLATE variable
test_config='{"id":"test1","config":{"template":"fast","model":"sonnet"}}'
unset PIPELINE_TEMPLATE || true
proven_config_apply "$test_config" 2>/dev/null || true
[[ "${PIPELINE_TEMPLATE:-}" == "fast" ]] && rc=0 || rc=1
test_assert "08: Apply sets PIPELINE_TEMPLATE" "$rc"

# Test 9: Apply sets PROVEN_CONFIG_ID variable
unset PROVEN_CONFIG_ID || true
proven_config_apply "$test_config" 2>/dev/null || true
[[ "${PROVEN_CONFIG_ID:-}" == "test1" ]] && rc=0 || rc=1
test_assert "09: Apply sets PROVEN_CONFIG_ID" "$rc"

# Test 10: Capture creates a valid config entry
echo "Testing capture and replay:"
echo ""
TEMP_STATE=$(mktemp)
cat > "$TEMP_STATE" <<'TESTEOF'
{
  "pipeline_template": "standard",
  "model": "sonnet",
  "max_iterations": 10,
  "timeout_s": 600,
  "quality_threshold": 70,
  "coverage_min": 80,
  "effort_level": "medium",
  "team_size": 1,
  "issue_type": "bug",
  "complexity": 5,
  "labels": "backend database",
  "goal": "fix database connection pooling issue"
}
TESTEOF
ARTIFACTS_DIR=$(mktemp -d)
captured_id=$(proven_config_capture "$TEMP_STATE" "$ARTIFACTS_DIR" "." 2>&1 | tail -1)
[[ -n "$captured_id" && "$captured_id" == "pc-"* ]] && rc=0 || rc=1
test_assert "10: Capture creates valid config with ID" "$rc"
rm -f "$TEMP_STATE"

# Test 11: CLI help command works
help_output=$(bash "$SCRIPT_DIR/sw-proven-configs.sh" help 2>&1)
echo "$help_output" | grep -q "USAGE" && rc=0 || rc=1
test_assert "11: CLI help command works" "$rc"

# Test 12: CLI list command works
bash "$SCRIPT_DIR/sw-proven-configs.sh" list >/dev/null 2>&1 && rc=0 || rc=1
test_assert "12: CLI list command executes" "$rc"

# Test 13: Track replay increments replay_count
echo "Testing replay tracking and demotion:"
echo ""
repo_hash=$(_proven_config_repo_hash "." 2>/dev/null) || repo_hash="default"
config_file="$HOME/.shipwright/proven-configs/$repo_hash/configs.jsonl"
mkdir -p "$(dirname "$config_file")" 2>/dev/null || true

# Create a test config entry (compact JSON for JSONL format)
test_entry=$(jq -cn --arg id "test-config-1" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{id: $id, captured_at: $now, issue_type: "bug", complexity: 5, labels: "test", goal_keywords: "test fix", config: {template: "standard", model: "sonnet", max_iterations: 10, timeout_s: 600, quality_threshold: 70, coverage_min: 80, effort_level: "medium", team_size: 1}, outcome: {result: "success", cost_usd: 0.5, duration_s: 120, iterations_used: 1, stages_passed: 10, stages_total: 10}, replay_count: 0, replay_success_count: 0, last_replayed_at: null, confidence: 1.0}')
echo "$test_entry" > "$config_file"

# Track a successful replay
proven_config_track_replay "test-config-1" "success" "." 2>/dev/null && rc=0 || rc=1
test_assert "13: Track replay success works" "$rc"

# Test 14: Verify replay_count was incremented
new_entry=$(tail -1 "$config_file")
replay_count=$(echo "$new_entry" | jq -r '.replay_count' 2>/dev/null || echo "0")
[[ "$replay_count" == "1" ]] && rc=0 || rc=1
test_assert "14: Replay count incremented correctly" "$rc"

# Test 15: Demotion logic activates when success rate < 40% after 5+ replays
# Create a config with 5 replays, only 1 success (20% success rate)
now_str=$(date -u +%Y-%m-%dT%H:%M:%SZ)
demoted_entry=$(jq -cn --arg id "test-demote" --arg now "$now_str" '{id: $id, captured_at: $now, issue_type: "bug", complexity: 5, labels: "test", goal_keywords: "test", config: {template: "standard", model: "sonnet", max_iterations: 10, timeout_s: 600, quality_threshold: 70, coverage_min: 80, effort_level: "medium", team_size: 1}, outcome: {result: "success", cost_usd: 0.5, duration_s: 120, iterations_used: 1, stages_passed: 10, stages_total: 10}, replay_count: 5, replay_success_count: 1, last_replayed_at: $now, confidence: 0.2}')
echo "$demoted_entry" >> "$config_file"

# Track another failure on this config (should trigger demotion: 1/6 = 16%)
proven_config_track_replay "test-demote" "failure" "." 2>/dev/null || true

# Check if demoted flag was set
demoted_result=$(tail -1 "$config_file" | jq -r '.demoted // "false"' 2>/dev/null || echo "false")
[[ "$demoted_result" == "true" ]] && rc=0 || rc=1
test_assert "15: Demotion flag set when confidence < 0.4 after 5+ replays" "$rc"

# Test 16: Prune removes configs below min_confidence
# Create a low-confidence config
now_str2=$(date -u +%Y-%m-%dT%H:%M:%SZ)
low_conf=$(jq -cn --arg id "low-conf" --arg now "$now_str2" '{id: $id, captured_at: $now, issue_type: "feature", complexity: 3, labels: "test", goal_keywords: "test", config: {template: "standard", model: "sonnet", max_iterations: 10, timeout_s: 600, quality_threshold: 70, coverage_min: 80, effort_level: "medium", team_size: 1}, outcome: {result: "success", cost_usd: 0.5, duration_s: 120, iterations_used: 1, stages_passed: 10, stages_total: 10}, replay_count: 10, replay_success_count: 1, last_replayed_at: $now, confidence: 0.1}')
echo "$low_conf" >> "$config_file"

# Prune with min_confidence 0.3 (should remove the 0.1 confidence config)
count_before=$(wc -l < "$config_file")
proven_config_prune 90 0.3 "." 2>/dev/null || true
count_after=$(wc -l < "$config_file")
[[ $count_after -lt $count_before ]] && rc=0 || rc=1
test_assert "16: Prune removes low-confidence configs" "$rc"

echo ""
echo "╔════════════════════════════════════════════════════════════════════════╗"
printf "║  Results: %d/16 PASSED\n" "$PASS"
echo "╚════════════════════════════════════════════════════════════════════════╝"
echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
