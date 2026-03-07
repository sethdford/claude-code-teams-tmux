#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright intelligence-stream test — Real-time intelligence streaming  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/artifacts"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    if command -v od &>/dev/null; then
        ln -sf "$(command -v od)" "$TEST_TEMP_DIR/bin/od"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    export EVENTS_FILE="$HOME/.shipwright/events.jsonl"
    export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
}

trap cleanup_test_env EXIT

echo ""
print_test_header "Intelligence Stream Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# Source the library under test
source "$SCRIPT_DIR/lib/intelligence-stream.sh"

# ─── Test 1: poll_intelligence_events returns empty when no events ────
echo -e "  ${CYAN}poll_intelligence_events — empty state${RESET}"
result=$(poll_intelligence_events "test-pipeline" "0" 2>/dev/null)
assert_eq "returns [] when no events file" "[]" "$result"

# ─── Test 2: poll_intelligence_events returns filtered events ─────────
echo ""
echo -e "  ${CYAN}poll_intelligence_events — filtered events${RESET}"
# Create events file with mixed types
cat > "$EVENTS_FILE" <<'JSONL'
{"ts":"2026-03-07T08:00:00Z","type":"stage.complete","source":"pipeline","pipeline_id":"issue-42"}
{"ts":"2026-03-07T08:01:00Z","type":"intelligence.analysis","source":"sw-intelligence","pipeline_id":"issue-42","complexity":"high"}
{"ts":"2026-03-07T08:02:00Z","type":"prediction.risk_assessed","source":"sw-predictive","pipeline_id":"issue-42","risk":"medium"}
{"ts":"2026-03-07T08:03:00Z","type":"discovery.broadcast","source":"sw-discovery","pipeline_id":"issue-42","pattern":"test-fix"}
{"ts":"2026-03-07T08:04:00Z","type":"loop.iteration","source":"sw-loop","pipeline_id":"issue-42"}
{"ts":"2026-03-07T08:05:00Z","type":"intelligence.model_ucb1","source":"pipeline","pipeline_id":"issue-99"}
JSONL

result=$(poll_intelligence_events "" "0" 2>/dev/null)
event_count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
# Should return intelligence.*, prediction.*, discovery.* but not stage.* or loop.*
assert_gt "returns only intelligence events (got $event_count)" "$event_count" "0"

# Verify no stage.complete or loop.iteration events leaked through
if echo "$result" | grep -qF "stage.complete"; then
    assert_fail "excludes stage.complete events"
else
    assert_pass "excludes stage.complete events"
fi
if echo "$result" | grep -qF "loop.iteration"; then
    assert_fail "excludes loop.iteration events"
else
    assert_pass "excludes loop.iteration events"
fi

# ─── Test 3: poll_intelligence_events pipeline filtering ──────────────
echo ""
echo -e "  ${CYAN}poll_intelligence_events — pipeline filtering${RESET}"
result=$(poll_intelligence_events "issue-42" "0" 2>/dev/null)
if echo "$result" | grep -qF "issue-99"; then
    assert_fail "filters by pipeline_id (issue-99 should be excluded)"
else
    assert_pass "filters by pipeline_id (issue-99 excluded)"
fi
if echo "$result" | grep -qF "issue-42"; then
    assert_pass "includes matching pipeline events"
else
    assert_fail "includes matching pipeline events"
fi

# ─── Test 4: poll_intelligence_events respects max events ────────────
echo ""
echo -e "  ${CYAN}poll_intelligence_events — max events limit${RESET}"
# Add many intelligence events
for i in $(seq 1 15); do
    echo "{\"ts\":\"2026-03-07T09:00:${i}Z\",\"type\":\"intelligence.test${i}\",\"source\":\"test\"}" >> "$EVENTS_FILE"
done
INTEL_STREAM_MAX_EVENTS=5
result=$(poll_intelligence_events "" "0" 2>/dev/null)
event_count=$(echo "$result" | jq 'length' 2>/dev/null || echo "0")
if [[ "$event_count" -le 5 ]]; then
    assert_pass "respects max events limit ($event_count <= 5)"
else
    assert_fail "respects max events limit" "got $event_count, expected <= 5"
fi
INTEL_STREAM_MAX_EVENTS=10  # Reset

# ─── Test 5: format_intelligence_context produces structured output ───
echo ""
echo -e "  ${CYAN}format_intelligence_context — structured output${RESET}"
test_events='[{"type":"prediction.risk_assessed","source":"predictive","payload":"risk=high"},{"type":"intelligence.analysis","source":"engine","payload":"complexity=medium"},{"type":"discovery.broadcast","source":"discovery","payload":"pattern=fix"}]'
formatted=$(format_intelligence_context "$test_events" 2>/dev/null)
assert_contains "includes Predictions header" "$formatted" "Predictions"
assert_contains "includes Intelligence header" "$formatted" "Intelligence"
assert_contains "includes Discoveries header" "$formatted" "Discoveries"

# ─── Test 6: format_intelligence_context handles empty input ──────────
echo ""
echo -e "  ${CYAN}format_intelligence_context — edge cases${RESET}"
empty_result=$(format_intelligence_context "[]" 2>/dev/null)
assert_eq "returns empty for empty array" "" "$empty_result"

malformed_result=$(format_intelligence_context "not-json" 2>/dev/null)
assert_eq "returns empty for malformed JSON" "" "$malformed_result"

# ─── Test 7: save_stream_state / load_stream_state round-trip ─────────
echo ""
echo -e "  ${CYAN}save/load stream state — round-trip${RESET}"
save_stream_state "test-pipeline" "42"
loaded=$(load_stream_state "test-pipeline")
assert_eq "round-trip preserves last_seen_id" "42" "$loaded"

# Verify atomic write (file exists and is valid JSON)
state_file="$ARTIFACTS_DIR/intelligence-stream-state.json"
if [[ -f "$state_file" ]]; then
    assert_pass "state file created"
    if jq empty "$state_file" 2>/dev/null; then
        assert_pass "state file is valid JSON"
    else
        assert_fail "state file is valid JSON"
    fi
else
    assert_fail "state file created"
fi

# ─── Test 8: load_stream_state returns 0 for missing state ───────────
echo ""
echo -e "  ${CYAN}load_stream_state — missing/corrupt state${RESET}"
rm -f "$state_file"
loaded=$(load_stream_state "nonexistent-pipeline")
assert_eq "returns 0 for missing state file" "0" "$loaded"

# Corrupt state file
echo "{{corrupt json}}" > "$state_file"
loaded=$(load_stream_state "test-pipeline")
assert_eq "returns 0 for corrupt state file" "0" "$loaded"

# ─── Test 9: eventbus stream subcommand exists ───────────────────────
echo ""
echo -e "  ${CYAN}eventbus stream subcommand${RESET}"
# Just verify the help text includes stream
output=$(bash "$SCRIPT_DIR/sw-eventbus.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "eventbus help exits 0" "0" "$rc"
assert_contains "help shows stream subcommand" "$output" "stream"

# ─── Test 10: intelligence-stream.sh is sourceable without error ──────
echo ""
echo -e "  ${CYAN}library sourcing${RESET}"
(
    _INTELLIGENCE_STREAM_LOADED=""
    source "$SCRIPT_DIR/lib/intelligence-stream.sh" 2>/dev/null
) && rc=0 || rc=$?
assert_eq "library sources without error" "0" "$rc"

# Verify functions are available
if type poll_intelligence_events >/dev/null 2>&1; then
    assert_pass "poll_intelligence_events function available"
else
    assert_fail "poll_intelligence_events function available"
fi
if type format_intelligence_context >/dev/null 2>&1; then
    assert_pass "format_intelligence_context function available"
else
    assert_fail "format_intelligence_context function available"
fi
if type save_stream_state >/dev/null 2>&1; then
    assert_pass "save_stream_state function available"
else
    assert_fail "save_stream_state function available"
fi
if type load_stream_state >/dev/null 2>&1; then
    assert_pass "load_stream_state function available"
else
    assert_fail "load_stream_state function available"
fi

echo ""
echo ""
print_test_results
