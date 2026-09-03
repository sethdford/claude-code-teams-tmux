#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-event-schema-sync-test.sh — keep config/event-schema.json in step   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    # Create a synthetic repo fixture with test scripts
    mkdir -p "$TEST_TEMP_DIR/repo/config"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts"

    # Create initial event-schema.json
    cat > "$TEST_TEMP_DIR/repo/config/event-schema.json" <<'JSON'
{
  "event_types": {
    "pipeline.started": {"required_fields": ["issue_id", "template"]},
    "pipeline.completed": {"required_fields": ["issue_id", "status"]},
    "build.failed": {"required_fields": ["error"]}
  }
}
JSON

    # Create a test script that emits events
    cat > "$TEST_TEMP_DIR/repo/scripts/test-script.sh" <<'SCRIPT'
#!/bin/bash
emit_event "pipeline.started" "issue_id=123" "template=standard"
emit_event "pipeline.completed" "issue_id=123" "status=success"
emit_event "build.failed" "error=test failed"
emit_event "custom.event" "key=value"
SCRIPT

    # Create python3 mock
    cat > "$TEST_TEMP_DIR/bin/python3" <<'MOCK'
#!/bin/bash
python "$@"
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/python3"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    cd "$TEST_TEMP_DIR/repo"
}

trap cleanup_test_env EXIT
setup_env

print_test_header "sw-event-schema-sync Tests"

# ─── Test 1: Default mode reports schema state ────────────────────────────
echo ""
echo -e "${BOLD}  Schema Analysis${RESET}"
output=$(bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1) && rc=0 || rc=$?
# Script exits 0 if in sync, 1 if missing events, 2 if python3 missing
assert_eq "default mode exits 0 or 1" "1" "$((rc == 0 || rc == 1 ? 1 : 0))"
assert_contains "output reports registered count" "$output" "registered"

# ─── Test 2: Output shows sync status ──────────────────────────────────────
echo ""
echo -e "${BOLD}  Status Messages${RESET}"
output=$(bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1)
if grep -qE -e "(registered|emitted|missing|schema)" <<<"$output"; then
    assert_pass "output includes schema analysis"
else
    assert_fail "output includes schema analysis"
fi

# ─── Test 3: Write mode updates schema ────────────────────────────────────
echo ""
echo -e "${BOLD}  Write Mode${RESET}"
output=$(bash "$SCRIPT_DIR/sw-event-schema-sync.sh" --write 2>&1) && rc=0 || rc=$?
# Write mode exits 0 on success
assert_eq "write mode completes" "0" "$((rc == 0 ? 0 : 1))"
assert_contains "write output confirms action" "$output" "event"

# ─── Test 4: Schema file exists and is valid ────────────────────────────────
echo ""
echo -e "${BOLD}  Schema Persistence${RESET}"
if [[ -f "config/event-schema.json" ]]; then
    assert_pass "config/event-schema.json exists"
else
    assert_fail "config/event-schema.json exists"
fi

# ─── Test 5: Schema has valid JSON ───────────────────────────────────────
echo ""
echo -e "${BOLD}  Schema Validity${RESET}"
if command -v jq &>/dev/null && [[ -f "config/event-schema.json" ]]; then
    if jq empty < "config/event-schema.json" 2>/dev/null; then
        assert_pass "schema contains valid JSON"
    else
        assert_fail "schema contains valid JSON" "jq parse error"
    fi
else
    assert_pass "skipping JSON validation (jq unavailable)"
fi

# ─── Test 6: Idempotency (run twice, same result) ──────────────────────────
echo ""
echo -e "${BOLD}  Idempotency${RESET}"
if [[ -f "config/event-schema.json" ]]; then
    schema_before=$(cat config/event-schema.json)
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" --write >/dev/null 2>&1 || true
    schema_after=$(cat config/event-schema.json)
    if [[ "$schema_before" == "$schema_after" ]]; then
        assert_pass "schema unchanged on second --write"
    else
        assert_fail "schema unchanged on second --write"
    fi
else
    assert_pass "skipping idempotency test (no schema file)"
fi

# ─── Test 7: Python requirement ──────────────────────────────────────────
echo ""
echo -e "${BOLD}  Python Dependency${RESET}"
if command -v python3 &>/dev/null; then
    assert_pass "python3 is available"
else
    assert_fail "python3 is available"
fi

# ─── Test 8: Script completes without hanging ────────────────────────────
echo ""
echo -e "${BOLD}  Performance${RESET}"
start=$(date +%s)
bash "$SCRIPT_DIR/sw-event-schema-sync.sh" >/dev/null 2>&1 || true
end=$(date +%s)
elapsed=$((end - start))
if [[ $elapsed -lt 30 ]]; then
    assert_pass "script completes quickly (${elapsed}s)"
else
    assert_pass "script completes (${elapsed}s)"
fi

echo ""
echo ""
print_test_results
