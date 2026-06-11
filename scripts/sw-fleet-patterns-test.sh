#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Fleet Patterns Test Suite — Cross-Repo Pattern Learning Engine         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERR in test_XXX: $BASH_SOURCE:$LINENO" >&2; exit 1' ERR

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Test Harness Setup ──────────────────────────────────────────────────────

# Mock home for isolation
export HOME="$(mktemp -d)"
export FLEET_INDEX="${HOME}/.shipwright/fleet-memory/index.json"
export FLEET_METRICS="${HOME}/.shipwright/fleet-memory/metrics.json"
export DAEMON_CONFIG_PATH="${HOME}/.claude/daemon-config.json"

# Source the library under test
# shellcheck source=lib/fleet-memory.sh
[[ -f "$SCRIPT_DIR/lib/fleet-memory.sh" ]] && source "$SCRIPT_DIR/lib/fleet-memory.sh" || {
  echo "FATAL: fleet-memory.sh not found"
  exit 1
}

# ─── Test Helpers ───────────────────────────────────────────────────────────
run_test() {
  local name="$1"
  local fn="$2"
  echo -n "  Testing: $name ... "
  if $fn >/dev/null 2>&1; then
    echo "✓"
    ((PASS++))
  else
    echo "✗"
    echo "    FAILED: $fn"
    ((FAIL++))
  fi
}

# ─── Unit Tests ──────────────────────────────────────────────────────────────

test_init_store() {
  fleet_memory_init_store
  [[ -f "$FLEET_INDEX" ]] || return 1
  [[ -f "$FLEET_METRICS" ]] || return 1
  jq empty < "$FLEET_INDEX" || return 1
  jq empty < "$FLEET_METRICS" || return 1
  return 0
}

test_init_store_idempotent() {
  fleet_memory_init_store
  fleet_memory_init_store
  [[ -f "$FLEET_INDEX" ]] || return 1
  return 0
}

test_fingerprint() {
  local fp
  fp=$(fleet_pattern_fingerprint ".")
  echo "$fp" | jq empty || return 1
  return 0
}

test_opt_in_default_off() {
  # Default: opt-in = false
  _fleet_opt_in "/nonexistent" && return 1 || return 0
}

test_opt_in_config_enabled() {
  # Create config with enabled=true
  mkdir -p "/tmp/test-repo/.claude"
  echo '{"pattern_learning":{"enabled":true}}' > "/tmp/test-repo/.claude/fleet-config.json"
  _fleet_opt_in "/tmp/test-repo" || return 1
  return 0
}

test_score_identical() {
  local pattern='{"fingerprint":{"language":"javascript"},"error_signature":"test error","issue_keywords":[]}'
  local target='{"language":"javascript","framework":"","test_runner":"","package_manager":""}'
  local score
  score=$(_fleet_score "$pattern" "$target" "test error" "")
  [[ "$score" -ge 50 ]] || return 1  # Should have high score for matching language + error
  return 0
}

test_match_empty_store() {
  fleet_memory_init_store
  local matches
  matches=$(fleet_pattern_match '{"language":"javascript"}' "" "" 3)
  [[ "$(echo "$matches" | jq 'length')" -eq 0 ]] || return 1
  return 0
}

test_capture_opt_out() {
  fleet_memory_init_store
  # Should capture nothing when opted out
  fleet_pattern_capture "/nonexistent-repo" "/tmp/state.md" "/tmp/artifacts" || true
  local count
  count=$(jq '.patterns | length' "$FLEET_INDEX" 2>/dev/null || echo 0)
  [[ "$count" -eq 0 ]] || return 1
  return 0
}

test_inject_opt_out() {
  fleet_memory_init_store
  # Should return empty when opted out
  local result
  result=$(fleet_pattern_inject "build" "/nonexistent" "" 2>/dev/null || echo "")
  [[ -z "$result" ]] || return 1
  return 0
}

# ─── Test Suite ─────────────────────────────────────────────────────────────
echo -e "\n━━ Fleet Memory Test Suite (v$VERSION) ━━\n"

PASS=0
FAIL=0

echo "Core Functionality:"
run_test "init_store creates files" test_init_store
run_test "init_store is idempotent" test_init_store_idempotent
run_test "fingerprint returns valid JSON" test_fingerprint
run_test "opt-in default is OFF (privacy first)" test_opt_in_default_off
run_test "opt-in reads config enabled" test_opt_in_config_enabled
run_test "scoring ranks identical patterns high" test_score_identical
run_test "match returns empty when no patterns" test_match_empty_store
run_test "capture gates on opt-out" test_capture_opt_out
run_test "inject returns empty when opted out" test_inject_opt_out

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && echo -e "\n✓ All tests passed!\n" && exit 0
echo -e "\n✗ Tests failed!\n" && exit 1
