#!/usr/bin/env bash
# sw-waste-detector-test.sh — Unit tests for loop-waste-detector.sh
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stub helpers used by the lib
info()    { echo "ℹ $*"; }
success() { echo "✓ $*"; }
warn()    { echo "⚠ $*"; }
error()   { echo "✗ $*" >&2; }

# Load compat for _smart_int
source "$SCRIPT_DIR/lib/compat.sh"
source "$SCRIPT_DIR/lib/loop-waste-detector.sh"

PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1)); success "$msg"
    else
        FAIL=$((FAIL + 1)); error "$msg (expected '$expected', got '$actual')"
    fi
}

assert_true() {
    local cond="$1" msg="$2"
    if [[ "$cond" == "true" || "$cond" == "0" ]]; then
        PASS=$((PASS + 1)); success "$msg"
    else
        FAIL=$((FAIL + 1)); error "$msg (got '$cond')"
    fi
}

setup_sandbox() {
    SANDBOX="$(mktemp -d 2>/dev/null || mktemp -d -t waste-test)"
    local sandbox="$SANDBOX"
    PROJECT_ROOT="$sandbox"
    LOG_DIR="$sandbox/logs"
    ARTIFACTS_DIR="$sandbox/artifacts"
    mkdir -p "$LOG_DIR" "$ARTIFACTS_DIR"
    AGENT_NUM=1
    ITERATION=5
    MAX_ITERATIONS=20
    DAEMON_CONFIG="$sandbox/daemon-config.json"
    echo '{}' > "$DAEMON_CONFIG"
    # Initialise a minimal repo so git diff calls work
    ( cd "$sandbox" && git init -q && git config user.email t@t && git config user.name t \
        && echo init > a.txt && git add a.txt && git commit -q -m init ) >/dev/null 2>&1 || true
    # Reset event capture
    EVENTS_FILE="$sandbox/events.jsonl"
    : > "$EVENTS_FILE"
    # Stub emit_event to write JSONL
    emit_event() {
        local type="$1"; shift
        local rec="{\"type\":\"$type\""
        local kv
        for kv in "$@"; do
            local k="${kv%%=*}"; local v="${kv#*=}"
            rec="$rec,\"$k\":\"$(echo "$v" | sed 's/"/\\"/g')\""
        done
        rec="$rec}"
        echo "$rec" >> "$EVENTS_FILE"
    }
    export PROJECT_ROOT LOG_DIR ARTIFACTS_DIR AGENT_NUM ITERATION MAX_ITERATIONS DAEMON_CONFIG
    waste_detector_init
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_zero_progress() {
    setup_sandbox; local sb="$SANDBOX"
    if waste_detect_zero_progress; then
        assert_true "true" "T1: zero progress detected when diff is empty"
    else
        assert_true "false" "T1: zero progress detected when diff is empty"
    fi
    rm -rf "$sb"
}

test_circular_edits() {
    setup_sandbox; local sb="$SANDBOX"
    # Simulate 4 iterations all touching the same file
    for i in 1 2 3 4; do
        echo "$i|src/foo.ts,src/bar.ts" >> "$WASTE_FILE_HISTORY"
    done
    if waste_detect_circular_edits; then
        if [[ "$WASTE_CIRCULAR_FILES" == *"src/foo.ts"* ]]; then
            assert_true "true" "T2: circular edits detected with foo.ts in result"
        else
            assert_true "false" "T2: circular files list contains foo.ts (got '$WASTE_CIRCULAR_FILES')"
        fi
    else
        assert_true "false" "T2: circular edits returned 0"
    fi
    rm -rf "$sb"
}

test_circular_edits_no_repeat() {
    setup_sandbox; local sb="$SANDBOX"
    echo "1|a.ts" >> "$WASTE_FILE_HISTORY"
    echo "2|b.ts" >> "$WASTE_FILE_HISTORY"
    echo "3|c.ts" >> "$WASTE_FILE_HISTORY"
    echo "4|d.ts" >> "$WASTE_FILE_HISTORY"
    if waste_detect_circular_edits; then
        assert_true "false" "T3: no circular edits when files differ each iter"
    else
        assert_true "true" "T3: no circular edits when files differ each iter"
    fi
    rm -rf "$sb"
}

test_semantic_dup_threshold() {
    setup_sandbox; local sb="$SANDBOX"
    ITERATION=4
    # Create two identical iteration logs → 100% overlap
    cat > "$LOG_DIR/iteration-3.log" <<'EOF'
line a
line b
line c
line d
EOF
    cp "$LOG_DIR/iteration-3.log" "$LOG_DIR/iteration-2.log"
    if waste_detect_semantic_dup 4; then
        assert_eq "100" "$WASTE_SIMILARITY_PCT" "T4: 100% similarity reported on identical logs"
    else
        assert_true "false" "T4: semantic dup detected on identical logs"
    fi
    rm -rf "$sb"
}

test_report_writer() {
    setup_sandbox; local sb="$SANDBOX"
    WASTE_REASONS="zero_progress,circular_edits"
    WASTE_CIRCULAR_FILES="src/foo.ts"
    WASTE_DIFF_LINES=2
    WASTE_SIMILARITY_PCT=92
    WASTE_CONSECUTIVE=3
    local report
    report="$(waste_write_report 7)"
    if [[ -f "$report" ]]; then
        local v
        v="$(jq -r '.version' "$report")"
        assert_eq "1.0.0" "$v" "T5a: waste-report.json version field present"
        local n
        n="$(jq -r '.consecutive_waste_iterations' "$report")"
        assert_eq "3" "$n" "T5b: consecutive_waste_iterations matches"
        local cost
        cost="$(jq -r '.estimated_cost_saved_usd' "$report")"
        if [[ "$cost" =~ ^[0-9]+\.[0-9]+$ ]]; then
            PASS=$((PASS + 1)); success "T5c: estimated_cost_saved_usd is a number ($cost)"
        else
            FAIL=$((FAIL + 1)); error "T5c: cost not numeric ($cost)"
        fi
    else
        assert_true "false" "T5: waste-report.json written"
    fi
    rm -rf "$sb"
}

test_event_emission() {
    setup_sandbox; local sb="$SANDBOX"
    # Force zero-progress signal — diff is empty in fresh repo
    if waste_detect 5; then
        if grep -q '"type":"waste_detected"' "$EVENTS_FILE"; then
            PASS=$((PASS + 1)); success "T6: waste_detected event emitted"
        else
            FAIL=$((FAIL + 1)); error "T6: waste_detected event missing from events.jsonl"
        fi
    else
        FAIL=$((FAIL + 1)); error "T6: waste_detect did not return 0 on empty diff"
    fi
    rm -rf "$sb"
}

test_disabled_flag() {
    setup_sandbox; local sb="$SANDBOX"
    WASTE_DETECTION_ENABLED=0
    if waste_detect 5; then
        FAIL=$((FAIL + 1)); error "T7: waste_detect should not fire when disabled"
    else
        PASS=$((PASS + 1)); success "T7: disabled flag suppresses detection"
    fi
    rm -rf "$sb"
}

test_termination_threshold() {
    setup_sandbox; local sb="$SANDBOX"
    WASTE_TERMINATION_THRESHOLD=3
    WASTE_CONSECUTIVE=2
    if waste_should_terminate; then
        FAIL=$((FAIL + 1)); error "T8a: should not terminate at consecutive=2"
    else
        PASS=$((PASS + 1)); success "T8a: no termination below threshold"
    fi
    WASTE_CONSECUTIVE=3
    if waste_should_terminate; then
        PASS=$((PASS + 1)); success "T8b: termination at threshold"
    else
        FAIL=$((FAIL + 1)); error "T8b: should terminate at consecutive=3"
    fi
    rm -rf "$sb"
}

test_graceful_no_git() {
    local sb; sb="$(mktemp -d)"
    PROJECT_ROOT="$sb"  # no git init
    LOG_DIR="$sb/logs"; mkdir -p "$LOG_DIR"
    AGENT_NUM=1; ITERATION=1; MAX_ITERATIONS=20
    DAEMON_CONFIG="$sb/daemon-config.json"; echo '{}' > "$DAEMON_CONFIG"
    waste_detector_init
    # Should not crash even when git fails
    set +e
    waste_detect_zero_progress
    local rc=$?
    set -e
    # rc==0 (waste detected because diff empty) is fine; we just need no crash
    PASS=$((PASS + 1)); success "T9: graceful when git absent (rc=$rc)"
    rm -rf "$sb"
}

# ─── Run ──────────────────────────────────────────────────────────────────────

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Iteration Waste Detector Test Suite                       ║"
echo "╚════════════════════════════════════════════════════════════╝"

test_zero_progress
test_circular_edits
test_circular_edits_no_repeat
test_semantic_dup_threshold
test_report_writer
test_event_emission
test_disabled_flag
test_termination_threshold
test_graceful_no_git

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
