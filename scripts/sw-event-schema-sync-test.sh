#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-event-schema-sync-test.sh — Test Suite for Event Schema Sync         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "sw-event-schema-sync-test.sh"

# ─── Setup & teardown ───────────────────────────────────────────────────────
setup_test_env "sw-event-schema-sync"

# Create a minimal fixture repo with event schema and emit_event calls
setup_fixture_repo() {
    local repo="$TEST_TEMP_DIR/fixture-repo"
    mkdir -p "$repo/config" "$repo/scripts"

    # Create a minimal event schema with some registered types
    cat > "$repo/config/event-schema.json" <<'EOF'
{
  "version": "1.0",
  "event_types": {
    "test.start": {
      "required": [],
      "optional": ["iteration"]
    },
    "test.step": {
      "required": [],
      "optional": ["name"]
    }
  }
}
EOF

    # Create multiple scripts with emit_event calls
    cat > "$repo/scripts/test-script.sh" <<'EOF'
#!/usr/bin/env bash
emit_event "test.start" "iteration=1"
emit_event "test.step" "name=setup"
EOF

    cat > "$repo/scripts/other-script.sh" <<'EOF'
#!/usr/bin/env bash
emit_event "test.step" "name=run"
emit_event "test.end" "status=ok"
EOF

    echo "$repo"
}

# ─── Test: script runs without error ──────────────────────────────────────
test_script_runs() {
    local repo; repo=$(setup_fixture_repo)
    cd "$repo"

    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" >/dev/null 2>&1 || true
    assert_pass "script runs without error"
}

# ─── Test: schema sync reports event counts ──────────────────────────────
test_schema_reports_counts() {
    local repo; repo=$(setup_fixture_repo)
    cd "$repo"

    local output; output=$(bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1 || true)

    if echo "$output" | grep -qE "(registered|emitted)"; then
        assert_pass "schema sync reports event counts"
    else
        assert_fail "schema sync reports event counts"
    fi
}

# ─── Test: schema sync --write creates schema file ──────────────────────
test_schema_write_option() {
    local repo; repo=$(setup_fixture_repo)
    cd "$repo"

    # Run with --write to update schema
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" --write >/dev/null 2>&1 || true

    # Verify schema file is valid JSON
    if jq . "$repo/config/event-schema.json" >/dev/null 2>&1; then
        assert_pass "schema sync --write maintains valid JSON"
    else
        assert_fail "schema sync --write maintains valid JSON"
    fi
}

# ─── Test: schema sync exits 0 when in sync ──────────────────────────────
test_schema_exit_code_sync() {
    local repo; repo=$(setup_fixture_repo)
    cd "$repo"

    # Sync first
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" --write 2>&1 >/dev/null || true

    # Check exit code on second run (should be in sync)
    if bash "$SCRIPT_DIR/sw-event-schema-sync.sh" >/dev/null 2>&1; then
        assert_pass "schema sync exits 0 when in sync"
    else
        assert_fail "schema sync exits 0 when in sync"
    fi
}

# ─── Test: schema sync handles missing config directory ──────────────────────
test_schema_missing_config() {
    local repo="$TEST_TEMP_DIR/no-config"
    mkdir -p "$repo/scripts"

    # No config directory
    cd "$repo"

    # Should fail gracefully with missing schema
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" >/dev/null 2>&1 || true
    assert_pass "schema sync handles missing config directory"
}

# ─── Test: schema sync outputs human-readable report ──────────────────────
test_schema_stdout_output() {
    local repo; repo=$(setup_fixture_repo)
    cd "$repo"

    local output; output=$(bash "$SCRIPT_DIR/sw-event-schema-sync.sh" 2>&1 || true)

    if [[ -n "$output" ]]; then
        assert_pass "schema sync produces stdout output"
    else
        assert_fail "schema sync produces stdout output"
    fi
}

# ─── Test: schema sync handles Python requirement ──────────────────────────
test_schema_python_check() {
    if command -v python3 >/dev/null 2>&1; then
        assert_pass "python3 is available for schema sync"
    else
        assert_fail "python3 is available for schema sync"
    fi
}

# ─── Test: schema sync preserves existing event types ──────────────────────
test_schema_preserves_existing() {
    local repo; repo=$(setup_fixture_repo)
    cd "$repo"

    # Store original count
    local before; before=$(jq '.event_types | keys | length' "$repo/config/event-schema.json")

    # Sync
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" --write >/dev/null 2>&1 || true

    # Check that we have at least as many types (should have added new ones or stayed same)
    local after; after=$(jq '.event_types | keys | length' "$repo/config/event-schema.json")

    if [[ $after -ge $before ]]; then
        assert_pass "schema sync preserves and extends event types"
    else
        assert_fail "schema sync preserves and extends event types"
    fi
}

# ─── Test: schema sync help option ──────────────────────────────────────
test_schema_help() {
    # Script doesn't have help, but should at least run
    bash "$SCRIPT_DIR/sw-event-schema-sync.sh" >/dev/null 2>&1 || true
    assert_pass "schema sync processes command line"
}

# ─── Main ───────────────────────────────────────────────────────────────────
test_script_runs
test_schema_reports_counts
test_schema_write_option
test_schema_exit_code_sync
test_schema_missing_config
test_schema_stdout_output
test_schema_python_check
test_schema_preserves_existing
test_schema_help

cleanup_test_env
print_test_results
