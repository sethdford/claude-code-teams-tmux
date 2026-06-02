#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-flaky-test.sh — Flaky Test Detection & Auto-Quarantine Test Suite    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"; echo "    Actual:   $actual"
    fi
}
assert_contains() {
    local needle="$1" haystack="$2" description="${3:-}"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"; echo "    Actual: $haystack"
    fi
}
assert_not_contains() {
    local needle="$1" haystack="$2" description="${3:-}"
    if ! echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected NOT to contain: $needle"; echo "    Actual: $haystack"
    fi
}

# ─── Environment ────────────────────────────────────────────────────────────
# Isolate the SQLite DB under a temp HOME so we never touch the real DB.
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/flaky-test.XXXXXX")"
export HOME="$TEST_HOME"
export NO_GITHUB=true
trap 'rm -rf "$TEST_HOME"' EXIT

SW="$SCRIPT_DIR/sw-flaky.sh"
DBSH="$SCRIPT_DIR/sw-db.sh"

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sw-flaky-test.sh: sqlite3 not available — skipping (PASS: 0 FAIL: 0)"
    echo "PASS: 0"; echo "FAIL: 0"; exit 0
fi

# Fresh schema in the temp HOME.
bash "$DBSH" migrate >/dev/null 2>&1 || bash "$DBSH" init >/dev/null 2>&1

DBF="$HOME/.shipwright/shipwright.db"

# Helper: record a single status line for a test across pipeline runs.
record_run() {
    local pid="$1" status_line="$2"
    local f; f="$(mktemp)"
    printf '%s\n' "$status_line" > "$f"
    bash "$SW" record "$pid" "$f" >/dev/null 2>&1
    rm -f "$f"
}

# ─── Tests ──────────────────────────────────────────────────────────────────
test_schema_v7() {
    local v; v=$(sqlite3 "$DBF" "SELECT MAX(version) FROM _schema;" 2>/dev/null)
    assert_equals "7" "$v" "schema migrated to v7"
    local tables; tables=$(sqlite3 "$DBF" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('test_results','flaky_quarantine');" 2>/dev/null | tr '\n' ' ')
    assert_contains "test_results" "$tables" "test_results table exists"
    assert_contains "flaky_quarantine" "$tables" "flaky_quarantine table exists"
}

test_migration_idempotent() {
    # Re-running migrate must not error or change the version.
    bash "$DBSH" migrate >/dev/null 2>&1
    bash "$DBSH" migrate >/dev/null 2>&1
    local v; v=$(sqlite3 "$DBF" "SELECT MAX(version) FROM _schema;" 2>/dev/null)
    assert_equals "7" "$v" "double migrate stays at v7 (idempotent)"
}

test_record_and_detect() {
    # Flaky test: passes 3, fails 2 of 5 runs → 40% > 20% threshold.
    record_run "p1" " ✓ test/x.test.js > flaky one (1ms)"
    record_run "p2" " ✗ test/x.test.js > flaky one"
    record_run "p3" " ✓ test/x.test.js > flaky one (1ms)"
    record_run "p4" " ✗ test/x.test.js > flaky one"
    record_run "p5" " ✓ test/x.test.js > flaky one (1ms)"
    # Stable test: always passes.
    for p in p1 p2 p3 p4 p5; do
        record_run "${p}b" " ✓ test/x.test.js > stable one (1ms)"
    done
    local out; out=$(bash "$SW" detect --json 2>/dev/null)
    assert_contains "flaky one" "$out" "detect flags the flaky test"
    assert_not_contains "stable one" "$out" "detect ignores the stable test"
    local rate; rate=$(echo "$out" | jq -r '.[] | select(.test_name | contains("flaky one")) | .failure_rate')
    assert_equals "40.0" "$rate" "failure rate computed as 40%"
}

test_min_failures_guard() {
    # Single failure in window must NOT flag (required_failures default 2).
    record_run "s1" " ✓ test/y.test.js > rare blip (1ms)"
    record_run "s2" " ✗ test/y.test.js > rare blip"
    record_run "s3" " ✓ test/y.test.js > rare blip (1ms)"
    record_run "s4" " ✓ test/y.test.js > rare blip (1ms)"
    record_run "s5" " ✓ test/y.test.js > rare blip (1ms)"
    local out; out=$(bash "$SW" detect --json 2>/dev/null)
    assert_not_contains "rare blip" "$out" "single failure not flagged (required_failures=2)"
}

test_tap_parsing() {
    local f; f="$(mktemp)"
    cat > "$f" <<'EOF'
TAP version 13
ok 1 - tap passing test
not ok 2 - tap failing test
ok 3 - tap skipped test # SKIP not ready
EOF
    bash "$SW" record "tap-1" "$f" >/dev/null 2>&1
    rm -f "$f"
    local pass fail skip
    pass=$(sqlite3 "$DBF" "SELECT status FROM test_results WHERE test_name='tap passing test';")
    fail=$(sqlite3 "$DBF" "SELECT status FROM test_results WHERE test_name='tap failing test';")
    skip=$(sqlite3 "$DBF" "SELECT status FROM test_results WHERE test_name='tap skipped test';")
    assert_equals "PASS" "$pass" "TAP 'ok' parsed as PASS"
    assert_equals "FAIL" "$fail" "TAP 'not ok' parsed as FAIL"
    assert_equals "SKIP" "$skip" "TAP '# SKIP' parsed as SKIP"
}

test_quarantine_mutates_source() {
    local work; work="$(mktemp -d)"
    mkdir -p "$work/test"
    cat > "$work/test/q.test.js" <<'EOF'
import { test, expect } from 'vitest'

test('mutate me flaky', () => {
  expect(1).toBe(1)
})
EOF
    # Build flaky history for this test.
    record_run "q1" " ✓ test/q.test.js > mutate me flaky (1ms)"
    record_run "q2" " ✗ test/q.test.js > mutate me flaky"
    record_run "q3" " ✗ test/q.test.js > mutate me flaky"
    record_run "q4" " ✓ test/q.test.js > mutate me flaky (1ms)"
    record_run "q5" " ✓ test/q.test.js > mutate me flaky (1ms)"
    ( cd "$work" && bash "$SW" quarantine --auto >/dev/null 2>&1 )
    local content; content=$(cat "$work/test/q.test.js")
    assert_contains "test.skip('mutate me flaky'" "$content" "test( converted to test.skip("
    assert_contains "QUARANTINED: flaky test" "$content" "QUARANTINED comment inserted"
    rm -rf "$work"
}

test_quarantine_records_and_counts() {
    local cnt; cnt=$(bash "$SW" count 2>/dev/null)
    # At least the two quarantined tests from prior tests (flaky one + mutate me flaky)
    if [[ "${cnt:-0}" -ge 1 ]]; then
        PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m count reflects active quarantines ($cnt)"
    else
        FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m count reflects active quarantines"
        echo "    Got: $cnt"
    fi
    local listed; listed=$(bash "$SW" list 2>/dev/null)
    assert_contains "flaky one" "$listed" "list shows quarantined test"
}

test_lift_quarantine() {
    bash "$SW" lift "test/x.test.js > flaky one" >/dev/null 2>&1
    local active; active=$(bash "$SW" list --json 2>/dev/null | jq -r '.[] | select(.test_name | contains("flaky one")) | .test_name')
    assert_equals "" "$active" "lifted test no longer in active list"
    local all; all=$(bash "$SW" list --all --json 2>/dev/null)
    assert_contains "flaky one" "$all" "lifted test still present with --all"
}

test_ambiguous_quarantine_no_mutation() {
    local work; work="$(mktemp -d)"
    mkdir -p "$work/test"
    # Two declarations with the same title → ambiguous, must NOT mutate.
    cat > "$work/test/amb.test.js" <<'EOF'
import { test } from 'vitest'
test('dup title', () => {})
test('dup title', () => {})
EOF
    record_run "a1" " ✗ test/amb.test.js > dup title"
    record_run "a2" " ✗ test/amb.test.js > dup title"
    record_run "a3" " ✓ test/amb.test.js > dup title (1ms)"
    local rc=0
    ( cd "$work" && bash "$SW" quarantine "test/amb.test.js > dup title" >/dev/null 2>&1 ) || rc=$?
    local content; content=$(cat "$work/test/amb.test.js")
    assert_not_contains "test.skip" "$content" "ambiguous title leaves source untouched"
    rm -rf "$work"
}

test_skip_status_not_recounted() {
    # SKIP rows must not count toward the rate; only PASS/FAIL do.
    # 3 FAIL + 2 SKIP → rate over 3 runs = 100% (SKIP rows ignored).
    record_run "k1" " ✗ test/z.test.js > skip excluded test"
    record_run "k2" " ✗ test/z.test.js > skip excluded test"
    record_run "k3" " ✗ test/z.test.js > skip excluded test"
    record_run "k4" " ↓ test/z.test.js > skip excluded test"
    record_run "k5" " ↓ test/z.test.js > skip excluded test"
    local row
    row=$(bash "$SW" detect --json 2>/dev/null | jq -c '.[] | select(.test_name | contains("skip excluded test"))')
    local rate runs
    rate=$(echo "$row" | jq -r '.failure_rate')
    runs=$(echo "$row" | jq -r '.runs')
    assert_equals "100.0" "$rate" "SKIP rows excluded from rate (3 FAIL = 100%)"
    assert_equals "3" "$runs" "window counts 3 PASS/FAIL runs, not the 2 SKIP rows"
}

test_help_and_version() {
    local h; h=$(bash "$SW" --help 2>/dev/null)
    assert_contains "shipwright flaky" "$h" "help text shown"
    local v; v=$(bash "$SW" --version 2>/dev/null)
    assert_contains "." "$v" "version string printed"
}

test_router_registration() {
    assert_contains "flaky)" "$(cat "$SCRIPT_DIR/sw")" "flaky registered in sw router"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-flaky-test.sh"
test_schema_v7
test_migration_idempotent
test_record_and_detect
test_min_failures_guard
test_tap_parsing
test_quarantine_mutates_source
test_quarantine_records_and_counts
test_lift_quarantine
test_ambiguous_quarantine_no_mutation
test_skip_status_not_recounted
test_help_and_version
test_router_registration

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
