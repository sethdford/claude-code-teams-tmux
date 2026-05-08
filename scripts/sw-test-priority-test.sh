#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-test-priority-test — Test suite for test-priority orchestration       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_proj() {
    local proj="$TEST_TEMP_DIR/proj"
    rm -rf "$proj" && mkdir -p "$proj/scripts/lib" "$proj/.claude"
    cp "$SCRIPT_DIR/lib/test-dep-map.sh"   "$proj/scripts/lib/"
    cp "$SCRIPT_DIR/lib/test-optimizer.sh" "$proj/scripts/lib/"
    cp "$SCRIPT_DIR/lib/test-priority.sh"  "$proj/scripts/lib/"

    cat > "$proj/scripts/lib/foo.sh" <<'EOF'
#!/usr/bin/env bash
foo() { echo foo; }
EOF
    cat > "$proj/scripts/lib/bar.sh" <<'EOF'
#!/usr/bin/env bash
bar() { echo bar; }
EOF

    cat > "$proj/scripts/foo-test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/foo.sh"
[[ "$(foo)" == "foo" ]] || exit 1
EOF
    chmod +x "$proj/scripts/foo-test.sh"

    cat > "$proj/scripts/bar-test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/bar.sh"
exit 0
EOF
    chmod +x "$proj/scripts/bar-test.sh"

    cat > "$proj/scripts/broken-test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
    chmod +x "$proj/scripts/broken-test.sh"

    echo "$proj"
}

print_test_header "test-priority"

# ─── test-dep-map ───────────────────────────────────────────────────────────
print_test_section "test-dep-map: build & query"

PROJ=$(setup_proj)
( cd "$PROJ" && \
  source scripts/lib/test-dep-map.sh && \
  tdm_build_map . "*-test.sh" )
assert_pass "tdm_build_map runs without error"

assert_file_exists "Cache file written" "$PROJ/.claude/intelligence-cache/test-dep-map.json"

RESULT=$(cd "$PROJ" && source scripts/lib/test-dep-map.sh && \
    tdm_tests_for_changed "scripts/lib/foo.sh")
assert_contains "tdm_tests_for_changed maps src→test" "$RESULT" "foo-test.sh"

RESULT=$(cd "$PROJ" && source scripts/lib/test-dep-map.sh && \
    tdm_tests_for_changed "scripts/lib/bar.sh")
assert_contains "second source maps to second test" "$RESULT" "bar-test.sh"

RESULT=$(cd "$PROJ" && source scripts/lib/test-dep-map.sh && \
    tdm_tests_for_changed 2>/dev/null || echo "")
assert_eq "empty changed list returns empty" "" "$RESULT"

# ─── test-priority ordering ─────────────────────────────────────────────────
print_test_section "test-priority: ordering"

PROJ=$(setup_proj)
ORDERED=$(cd "$PROJ" && \
    source scripts/lib/test-priority.sh && \
    tp_order_tests "scripts/lib/foo.sh" 2>/dev/null)

FIRST=$(echo "$ORDERED" | head -1)
assert_contains "affected test ranked first" "$FIRST" "foo-test.sh"

# ─── test-priority cold start (no history) ──────────────────────────────────
print_test_section "test-priority: cold start"

PROJ=$(setup_proj)
ORDERED=$(cd "$PROJ" && \
    source scripts/lib/test-priority.sh && \
    tp_order_tests 2>/dev/null)
LINE_COUNT=$(echo "$ORDERED" | grep -c '\-test.sh' || true)
assert_gt "cold start returns all discovered tests" "$LINE_COUNT" "0"

# ─── test-priority fast-fail run ────────────────────────────────────────────
print_test_section "test-priority: fast-fail execution"

PROJ=$(setup_proj)
set +e
( cd "$PROJ" && \
  source scripts/lib/test-priority.sh && \
  tp_run_prioritized "" >/dev/null 2>&1 )
EXIT=$?
set -e
assert_eq "fast-fail returns 1 on failure" "1" "$EXIT"

# ─── test-priority all-pass run ─────────────────────────────────────────────
print_test_section "test-priority: all pass"

PROJ=$(setup_proj)
rm -f "$PROJ/scripts/broken-test.sh"
set +e
( cd "$PROJ" && \
  source scripts/lib/test-priority.sh && \
  tp_run_prioritized "" >/dev/null 2>&1 )
EXIT=$?
set -e
assert_eq "all-pass returns 0" "0" "$EXIT"

# ─── test-priority config loading ───────────────────────────────────────────
print_test_section "test-priority: config loading"

PROJ=$(setup_proj)
mkdir -p "$PROJ/.claude"
cat > "$PROJ/.claude/daemon-config.json" <<'EOF'
{"test_prioritization": {"enabled": true, "fast_fail_mode": false, "history_window_runs": 25, "affected_only": true, "max_priority_tests": 5, "affected_weight": 70, "failrate_weight": 30}}
EOF

OUT=$(cd "$PROJ" && \
    source scripts/lib/test-priority.sh && \
    tp_load_config && \
    echo "enabled=$TP_ENABLED fast_fail=$TP_FAST_FAIL_MODE window=$TP_HISTORY_WINDOW affected=$TP_AFFECTED_ONLY max=$TP_MAX_TESTS aw=$TP_AFFECTED_WEIGHT fw=$TP_FAILRATE_WEIGHT")

assert_contains "config: enabled"      "$OUT" "enabled=true"
assert_contains "config: fast_fail_mode" "$OUT" "fast_fail=false"
assert_contains "config: history_window_runs" "$OUT" "window=25"
assert_contains "config: affected_only" "$OUT" "affected=true"
assert_contains "config: max_priority_tests" "$OUT" "max=5"
assert_contains "config: affected_weight" "$OUT" "aw=70"
assert_contains "config: failrate_weight" "$OUT" "fw=30"

# ─── memory test outcome helpers ────────────────────────────────────────────
print_test_section "memory: record + retrieve test outcomes"

export HOME="$TEST_TEMP_DIR/home_$$"
mkdir -p "$HOME/.shipwright/memory"

# Use the real sw-memory.sh (it uses HOME env var which we just override)
PROJ=$(setup_proj)
cp "$SCRIPT_DIR/sw-memory.sh" "$PROJ/sw-memory.sh"

( cd "$PROJ" && \
  source ./sw-memory.sh && \
  memory_record_test_outcome "scripts/foo-test.sh" "fail" 2 "scripts/lib/foo.sh" && \
  memory_record_test_outcome "scripts/foo-test.sh" "pass" 1 "scripts/lib/foo.sh" && \
  memory_record_test_outcome "scripts/foo-test.sh" "fail" 3 "scripts/lib/foo.sh" )

RATE=$(cd "$PROJ" && source ./sw-memory.sh && \
    memory_get_test_failure_rate "scripts/foo-test.sh" 50)
case "$RATE" in
    0.66*|0.67*) assert_pass "failure rate ≈ 0.667 (got $RATE)" ;;
    *)           assert_fail "failure rate ≈ 0.667" "got '$RATE'" ;;
esac

RATE=$(cd "$PROJ" && source ./sw-memory.sh && \
    memory_get_test_failure_rate "scripts/never-run-test.sh" 50)
case "$RATE" in
    0.0*|0|0.000) assert_pass "unknown test → 0.0 (got $RATE)" ;;
    *)            assert_fail "unknown test → 0.0" "got '$RATE'" ;;
esac

# ─── Live-config safety: prioritization disabled by default ─────────────────
print_test_section "live config: default-disabled safety"

DISABLED=$(jq -r '.test_prioritization.enabled' "$SCRIPT_DIR/../.claude/daemon-config.json" 2>/dev/null || echo "missing")
assert_eq "live config: test_prioritization disabled by default" "false" "$DISABLED"

print_test_results
