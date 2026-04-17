#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-analytics-test.sh — Analytics Engine Test Suite                       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
  local expected="$1" actual="$2" description="${3:-}"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
  else
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" description="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
  else
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
    echo "    Expected substring: $needle"
    echo "    Actual: $haystack"
  fi
}

assert_exit_code() {
  local expected="$1" actual="$2" description="${3:-}"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
  else
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
    echo "    Expected exit code: $expected"
    echo "    Actual exit code: $actual"
  fi
}

# ─── Test: analytics_track emits valid JSON event ─────────────────────────
test_track_valid_event() {
  local tmpdir
  tmpdir=$(mktemp -d)
  export HOME="$tmpdir"
  mkdir -p "$HOME/.shipwright"

  local result=0
  "$SCRIPT_DIR/sw-analytics.sh" track setup_start '{}' "session-001" > /dev/null 2>&1 || result=$?

  assert_exit_code 0 "$result" "analytics_track with valid event returns 0"

  if [[ -f "$HOME/.shipwright/analytics.jsonl" ]]; then
    local event_count
    event_count=$(jq -s 'length' "$HOME/.shipwright/analytics.jsonl" 2>/dev/null || echo "0")
    assert_equals "1" "$event_count" "exactly 1 event written"
  else
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m analytics.jsonl file created"
  fi

  rm -rf "$tmpdir"
}

# ─── Test: analytics_track rejects invalid JSON ────────────────────────────
test_track_invalid_json() {
  local tmpdir
  tmpdir=$(mktemp -d)
  export HOME="$tmpdir"

  local result=0
  "$SCRIPT_DIR/sw-analytics.sh" track setup_start '{invalid json}' > /dev/null 2>&1 || result=$?

  assert_exit_code 1 "$result" "analytics_track with invalid JSON returns 1"

  rm -rf "$tmpdir"
}

# ─── Test: analytics_track requires event_type ──────────────────────────────
test_track_missing_event_type() {
  local tmpdir
  tmpdir=$(mktemp -d)
  export HOME="$tmpdir"

  local result=0
  "$SCRIPT_DIR/sw-analytics.sh" track > /dev/null 2>&1 || result=$?

  assert_exit_code 1 "$result" "analytics_track without event_type returns 1"

  rm -rf "$tmpdir"
}

# ─── Test: event record has required fields ────────────────────────────
test_event_record_structure() {
  local tmpdir
  tmpdir=$(mktemp -d)
  export HOME="$tmpdir"
  mkdir -p "$HOME/.shipwright"

  "$SCRIPT_DIR/sw-analytics.sh" track setup_start '{}' "session-001" > /dev/null 2>&1 || true

  local event=""
  event=$(jq -s '.[0]' "$HOME/.shipwright/analytics.jsonl" 2>/dev/null || echo "")

  assert_contains "$event" '"timestamp"' "event record contains timestamp field"
  assert_contains "$event" '"session_id"' "event record contains session_id field"
  assert_contains "$event" '"event_type"' "event record contains event_type field"
  assert_contains "$event" '"metadata"' "event record contains metadata field"

  rm -rf "$tmpdir"
}

# ─── Test: analytics_funnel with empty file ─────────────────────────────
test_funnel_empty() {
  local tmpdir
  tmpdir=$(mktemp -d)
  export HOME="$tmpdir"

  local output
  output=$("$SCRIPT_DIR/sw-analytics.sh" funnel setup 2>/dev/null)

  assert_contains "$output" "total_started" "funnel returns JSON with total_started field"
  assert_contains "$output" '"total_started": 0' "funnel with empty analytics file returns total_started: 0"

  rm -rf "$tmpdir"
}

# ─── Test: analytics_funnel requires funnel_name ─────────────────────────
test_funnel_missing_name() {
  local tmpdir
  tmpdir=$(mktemp -d)
  export HOME="$tmpdir"

  local result=0
  "$SCRIPT_DIR/sw-analytics.sh" funnel > /dev/null 2>&1 || result=$?

  assert_exit_code 1 "$result" "analytics_funnel without name returns 1"

  rm -rf "$tmpdir"
}

# ─── Test: analytics_report requires dates ──────────────────────────────
test_report_missing_dates() {
  local tmpdir
  tmpdir=$(mktemp -d)
  export HOME="$tmpdir"

  local result=0
  "$SCRIPT_DIR/sw-analytics.sh" report > /dev/null 2>&1 || result=$?

  assert_exit_code 1 "$result" "analytics_report without dates returns 1"

  rm -rf "$tmpdir"
}

# ─── Test: analytics help command ──────────────────────────────────────
test_analytics_help() {
  local output
  output=$("$SCRIPT_DIR/sw-analytics.sh" help 2>&1)

  assert_contains "$output" "Usage:" "help output contains Usage"
  assert_contains "$output" "track" "help output mentions track subcommand"
  assert_contains "$output" "report" "help output mentions report subcommand"
}

# ─── Test: metadata is preserved in event ──────────────────────────────
test_metadata_preservation() {
  local tmpdir
  tmpdir=$(mktemp -d)
  export HOME="$tmpdir"
  mkdir -p "$HOME/.shipwright"

  "$SCRIPT_DIR/sw-analytics.sh" track setup_phase_complete '{"phase":"plan","status":"success"}' > /dev/null 2>&1 || true

  local metadata=""
  metadata=$(jq -sc '.[0].metadata' "$HOME/.shipwright/analytics.jsonl" 2>/dev/null || echo "")

  assert_contains "$metadata" '"phase":"plan"' "metadata contains phase field"
  assert_contains "$metadata" '"status":"success"' "metadata contains status field"

  rm -rf "$tmpdir"
}

# ─── Run All Tests ───────────────────────────────────────────────────────
main() {
  local blue='\033[38;2;0;102;255m'
  local reset='\033[0m'

  echo -e "${blue}━━━━━ Analytics Engine Test Suite ━━━━━${reset}"
  echo

  echo "▸ Event Tracking Tests"
  test_track_valid_event
  test_track_invalid_json
  test_track_missing_event_type
  echo

  echo "▸ Event Structure Tests"
  test_event_record_structure
  test_metadata_preservation
  echo

  echo "▸ Funnel Analysis Tests"
  test_funnel_empty
  test_funnel_missing_name
  echo

  echo "▸ Report Generation Tests"
  test_report_missing_dates
  echo

  echo "▸ Help & Documentation Tests"
  test_analytics_help
  echo

  echo -e "${blue}━━━━━ Results ━━━━━${reset}"
  local total=$((PASS + FAIL))
  echo "PASS: $PASS"
  echo "FAIL: $FAIL"
  echo "TOTAL: $total"
  echo

  if [[ $FAIL -eq 0 ]]; then
    echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m All tests passed"
    return 0
  else
    echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m Some tests failed"
    return 1
  fi
}

main
