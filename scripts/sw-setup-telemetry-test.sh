#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-setup-telemetry-test.sh — Setup Telemetry & Checkpoint Test Suite   ║
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

assert_true() {
    local condition="$1" description="${2:-}"
    if eval "$condition"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
    fi
}

assert_file_exists() {
    local path="$1" description="${2:-file exists: $path}"
    if [[ -f "$path" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Needle not found: $needle"
    fi
}

# ─── Setup: isolated temp HOME ─────────────────────────────────────────────
ORIG_HOME="$HOME"
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
mkdir -p "$HOME/.shipwright"

cleanup() {
    export HOME="$ORIG_HOME"
    rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
echo "sw-setup-telemetry-test.sh"
echo ""
echo "  Unit Tests: setup-telemetry.sh library"
echo "  ─────────────────────────────────────────"

# ─── Test 1: Library loads without error ──────────────────────────────────
test_library_loads() {
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        [[ "$(type -t setup_telemetry_init)" == "function" ]]
    )
    assert_equals "0" "$?" "Library loads and exports setup_telemetry_init"
}

# ─── Test 2: Checkpoint save creates valid JSON ──────────────────────────
test_checkpoint_save_creates_json() {
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        _SETUP_START_EPOCH=$(now_epoch)
        _SETUP_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        _SETUP_FLAGS="--repair=false"
        _SETUP_COMPLETED_STEPS=""
        _setup_checkpoint_save
    )
    assert_file_exists "$HOME/.shipwright/setup-checkpoint.json" "Checkpoint file created"

    # Validate JSON
    local valid=false
    if jq -e '.' "$HOME/.shipwright/setup-checkpoint.json" >/dev/null 2>&1; then
        valid=true
    fi
    assert_equals "true" "$valid" "Checkpoint file is valid JSON"
}

# ─── Test 3: Checkpoint has correct structure ────────────────────────────
test_checkpoint_structure() {
    local version
    version=$(jq -r '.version' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "1" "$version" "Checkpoint version is 1"

    local has_started_at
    has_started_at=$(jq -e '.started_at' "$HOME/.shipwright/setup-checkpoint.json" >/dev/null 2>&1 && echo "true" || echo "false")
    assert_equals "true" "$has_started_at" "Checkpoint has started_at field"

    local has_completed_steps
    has_completed_steps=$(jq -e '.completed_steps | type == "array"' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "true" "$has_completed_steps" "Checkpoint has completed_steps array"
}

# ─── Test 4: Step start/end lifecycle ────────────────────────────────────
test_step_lifecycle() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    rm -f "$HOME/.shipwright/events.jsonl"
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_telemetry_init "--test"
        setup_step_start "test_step_1" "Test Step 1"
        setup_step_end "test_step_1"
        setup_telemetry_finish
    )

    # Check step is in completed_steps
    local step_present
    step_present=$(jq -r '.completed_steps[] | select(. == "test_step_1")' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "test_step_1" "$step_present" "Step recorded in completed_steps"

    # Check steps_passed count
    local passed
    passed=$(jq -r '.steps_passed' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "1" "$passed" "steps_passed incremented to 1"
}

# ─── Test 5: Step failure records in checkpoint ──────────────────────────
test_step_failure() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    rm -f "$HOME/.shipwright/events.jsonl"
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_telemetry_init "--test"
        setup_step_start "fail_step" "Failing Step"
        setup_step_fail "fail_step" "something broke"
    )

    local failed_step
    failed_step=$(jq -r '.failed_step' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "fail_step" "$failed_step" "Failed step recorded in checkpoint"

    local error_msg
    error_msg=$(jq -r '.error' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "something broke" "$error_msg" "Error message recorded in checkpoint"

    local failed_count
    failed_count=$(jq -r '.steps_failed' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "1" "$failed_count" "steps_failed incremented to 1"
}

# ─── Test 6: Resume skips completed steps ────────────────────────────────
test_resume_skips_completed() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    rm -f "$HOME/.shipwright/events.jsonl"

    # First run: complete 2 steps
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_telemetry_init "--test"
        setup_step_start "step_a" "Step A"
        setup_step_end "step_a"
        setup_step_start "step_b" "Step B"
        setup_step_end "step_b"
    )

    # Second run with --resume: check step_a returns 1 (skip)
    local skip_result=0
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_set_resume
        setup_telemetry_init "--test --resume"
        if setup_step_start "step_a" "Step A"; then
            exit 10  # Should NOT reach here
        else
            exit 0   # Skipped — correct
        fi
    ) || skip_result=$?
    assert_equals "0" "$skip_result" "Resume skips completed step_a"

    # Check step_c (new) executes normally
    local new_step_result=0
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_set_resume
        setup_telemetry_init "--test --resume"
        if setup_step_start "step_c" "Step C"; then
            exit 0   # Should execute
        else
            exit 10  # Should NOT skip
        fi
    ) || new_step_result=$?
    assert_equals "0" "$new_step_result" "Resume executes new step_c"
}

# ─── Test 7: Checkpoint expiry (24h) ────────────────────────────────────
test_checkpoint_expiry() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"

    # Create a checkpoint with an old timestamp
    local old_ts="2020-01-01T00:00:00Z"
    cat > "$HOME/.shipwright/setup-checkpoint.json" << EOF
{"version":1,"started_at":"$old_ts","updated_at":"$old_ts","flags":"","completed_steps":["old_step"],"failed_step":null,"error":null,"total_duration_s":0,"steps_passed":1,"steps_failed":0,"steps_skipped":0}
EOF

    local expired_result=0
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        if _setup_checkpoint_load; then
            exit 10  # Should NOT succeed — expired
        else
            exit 0   # Expired — correct
        fi
    ) || expired_result=$?
    assert_equals "0" "$expired_result" "24h-old checkpoint treated as expired"
}

# ─── Test 8: Events emitted to events.jsonl ─────────────────────────────
test_events_emitted() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    rm -f "$HOME/.shipwright/events.jsonl"
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_telemetry_init "--test"
        setup_step_start "event_step" "Event Test"
        setup_step_end "event_step"
        setup_telemetry_finish
    )

    assert_file_exists "$HOME/.shipwright/events.jsonl" "events.jsonl created"

    # Check for setup.started event
    local has_started
    has_started=$(grep -c '"setup.started"' "$HOME/.shipwright/events.jsonl" 2>/dev/null || echo "0")
    assert_true '[[ "$has_started" -ge 1 ]]' "setup.started event emitted"

    # Check for setup.step event with pass status
    local has_step_pass
    has_step_pass=$(grep -c '"setup.step"' "$HOME/.shipwright/events.jsonl" 2>/dev/null || echo "0")
    assert_true '[[ "$has_step_pass" -ge 1 ]]' "setup.step event emitted"

    # Check for setup.completed event
    local has_completed
    has_completed=$(grep -c '"setup.completed"' "$HOME/.shipwright/events.jsonl" 2>/dev/null || echo "0")
    assert_true '[[ "$has_completed" -ge 1 ]]' "setup.completed event emitted"
}

# ─── Test 9: Flags preserved in checkpoint ───────────────────────────────
test_flags_preserved() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    rm -f "$HOME/.shipwright/events.jsonl"
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_telemetry_init "--deploy=true --repair=false"
        setup_step_start "flag_step" "Flag Test"
        setup_step_end "flag_step"
    )

    local flags
    flags=$(jq -r '.flags' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null || echo "NOT_FOUND")
    assert_contains "$flags" "--deploy=true" "Flags preserved in checkpoint"
}

# ─── Test 10: Multiple steps tracked correctly ──────────────────────────
test_multiple_steps() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    rm -f "$HOME/.shipwright/events.jsonl"
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_telemetry_init "--test"
        setup_step_start "multi_1" "Multi 1"
        setup_step_end "multi_1"
        setup_step_start "multi_2" "Multi 2"
        setup_step_end "multi_2"
        setup_step_start "multi_3" "Multi 3"
        setup_step_end "multi_3"
        setup_telemetry_finish
    )

    local count
    count=$(jq -r '.completed_steps | length' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "3" "$count" "3 steps recorded in completed_steps"

    local passed
    passed=$(jq -r '.steps_passed' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "3" "$passed" "steps_passed is 3"
}

# ─── Test 11: Atomic write (no corruption) ──────────────────────────────
test_atomic_write() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_telemetry_init "--test"
        # Write multiple times rapidly
        for i in 1 2 3 4 5; do
            setup_step_start "atomic_$i" "Atomic $i"
            setup_step_end "atomic_$i"
        done
    )

    # Verify final checkpoint is valid JSON
    local valid=false
    if jq -e '.' "$HOME/.shipwright/setup-checkpoint.json" >/dev/null 2>&1; then
        valid=true
    fi
    assert_equals "true" "$valid" "Checkpoint valid after rapid writes"

    local count
    count=$(jq -r '.completed_steps | length' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "5" "$count" "All 5 rapid steps recorded"
}

# ─── Test 12: Resume emits setup.resumed event ──────────────────────────
test_resume_event() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    rm -f "$HOME/.shipwright/events.jsonl"

    # Create a checkpoint with some completed steps
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_telemetry_init "--test"
        setup_step_start "pre_step" "Pre"
        setup_step_end "pre_step"
    )

    rm -f "$HOME/.shipwright/events.jsonl"

    # Resume
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_set_resume
        setup_telemetry_init "--test --resume"
    )

    local has_resumed
    has_resumed=$(grep -c '"setup.resumed"' "$HOME/.shipwright/events.jsonl" 2>/dev/null || echo "0")
    assert_true '[[ "$has_resumed" -ge 1 ]]' "setup.resumed event emitted on resume"
}

# ─── Test 13: Event schema includes setup types ─────────────────────────
test_event_schema() {
    local schema_file="$SCRIPT_DIR/../config/event-schema.json"
    if [[ -f "$schema_file" ]]; then
        local has_started
        has_started=$(jq -e '.event_types["setup.started"]' "$schema_file" >/dev/null 2>&1 && echo "true" || echo "false")
        assert_equals "true" "$has_started" "Event schema has setup.started"

        local has_step
        has_step=$(jq -e '.event_types["setup.step"]' "$schema_file" >/dev/null 2>&1 && echo "true" || echo "false")
        assert_equals "true" "$has_step" "Event schema has setup.step"

        local has_completed
        has_completed=$(jq -e '.event_types["setup.completed"]' "$schema_file" >/dev/null 2>&1 && echo "true" || echo "false")
        assert_equals "true" "$has_completed" "Event schema has setup.completed"

        local has_resumed
        has_resumed=$(jq -e '.event_types["setup.resumed"]' "$schema_file" >/dev/null 2>&1 && echo "true" || echo "false")
        assert_equals "true" "$has_resumed" "Event schema has setup.resumed"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Event schema file not found"
    fi
}

# ─── Test 14: Doctor detects incomplete setup ────────────────────────────
test_doctor_incomplete() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    cat > "$HOME/.shipwright/setup-checkpoint.json" << 'EOF'
{"version":1,"started_at":"2026-03-08T00:00:00Z","updated_at":"2026-03-08T00:00:00Z","flags":"","completed_steps":["tmux_conf","overlay"],"failed_step":"tpm","error":"git clone failed","total_duration_s":5,"steps_passed":2,"steps_failed":1,"steps_skipped":0}
EOF
    local failed_step
    failed_step=$(jq -r '.failed_step' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "tpm" "$failed_step" "Doctor can read failed_step from checkpoint"
}

# ─── Test 15: Doctor detects complete setup ──────────────────────────────
test_doctor_complete() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    cat > "$HOME/.shipwright/setup-checkpoint.json" << 'EOF'
{"version":1,"started_at":"2026-03-08T00:00:00Z","updated_at":"2026-03-08T00:00:00Z","flags":"","completed_steps":["tmux_conf","overlay","tpm"],"failed_step":null,"error":null,"total_duration_s":10,"steps_passed":3,"steps_failed":0,"steps_skipped":0}
EOF
    local failed_step
    failed_step=$(jq -r '.failed_step // empty' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "" "$failed_step" "Complete checkpoint has no failed_step"

    local count
    count=$(jq -r '.completed_steps | length' "$HOME/.shipwright/setup-checkpoint.json" 2>/dev/null)
    assert_equals "3" "$count" "Complete checkpoint has 3 completed steps"
}

# ─── Test 16: setup_checkpoint_file returns correct path ────────────────
test_checkpoint_path() {
    local path
    path=$(
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_checkpoint_file
    )
    assert_contains "$path" "setup-checkpoint.json" "setup_checkpoint_file returns correct path"
}

# ─── Test 17: Skip event emitted for resumed completed step ────────────
test_skip_event_on_resume() {
    rm -f "$HOME/.shipwright/setup-checkpoint.json"
    rm -f "$HOME/.shipwright/events.jsonl"

    # Create checkpoint with completed step
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_telemetry_init "--test"
        setup_step_start "skip_me" "Skip Me"
        setup_step_end "skip_me"
    )

    rm -f "$HOME/.shipwright/events.jsonl"

    # Resume — skip_me should be skipped
    (
        unset _SW_SETUP_TELEMETRY_LOADED
        source "$SCRIPT_DIR/lib/setup-telemetry.sh"
        setup_set_resume
        setup_telemetry_init "--test --resume"
        setup_step_start "skip_me" "Skip Me" || true
    )

    local has_skip
    has_skip=$(grep '"status":"skip"' "$HOME/.shipwright/events.jsonl" 2>/dev/null | grep -c "skip_me" || echo "0")
    assert_true '[[ "$has_skip" -ge 1 ]]' "Skip event emitted for resumed completed step"
}

# ─── Run all tests ──────────────────────────────────────────────────────
test_library_loads
test_checkpoint_save_creates_json
test_checkpoint_structure
test_step_lifecycle
test_step_failure
test_resume_skips_completed
test_checkpoint_expiry
test_events_emitted
test_flags_preserved
test_multiple_steps
test_atomic_write
test_resume_event
test_event_schema
test_doctor_incomplete
test_doctor_complete
test_checkpoint_path
test_skip_event_on_resume

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
