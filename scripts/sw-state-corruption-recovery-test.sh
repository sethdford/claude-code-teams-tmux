#!/usr/bin/env bash
# sw-state-corruption-recovery-test.sh — Test suite for atomic writes and recovery
# Tests pipeline state corruption detection, atomic writes, and rollback mechanisms

set -euo pipefail

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Test Framework ──────────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/helpers.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

test_case() {
    local name="$1"
    echo -e "\n${CYAN}▶${RESET} $name"
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        ((TESTS_PASSED++))
        success "PASS"
    else
        ((TESTS_FAILED++))
        error "FAIL: expected '$expected', got '$actual'" ${msg:+" — $msg"}
    fi
}

assert_file_exists() {
    local file="$1"
    if [[ -f "$file" ]]; then
        ((TESTS_PASSED++))
        success "PASS"
    else
        ((TESTS_FAILED++))
        error "FAIL: file not found: $file"
    fi
}

assert_file_valid() {
    local file="$1"
    if grep -q "^---$" "$file" && grep -q "^goal:" "$file"; then
        ((TESTS_PASSED++))
        success "PASS"
    else
        ((TESTS_FAILED++))
        error "FAIL: file not valid (missing delimiters or goal): $file"
    fi
}

# ─── Test Setup ──────────────────────────────────────────────────────────
setup_test_env() {
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-state-test.XXXXXX")
    TEST_STATE="$TEST_DIR/pipeline-state.md"
    TEST_ARTIFACTS="$TEST_DIR/artifacts"
    mkdir -p "$TEST_ARTIFACTS/checkpoints"

    # Source the pipeline state lib
    export SCRIPT_DIR
    export STATE_FILE="$TEST_STATE"
    export ARTIFACTS_DIR="$TEST_ARTIFACTS"
    source "$SCRIPT_DIR/lib/pipeline-state.sh"
}

teardown_test_env() {
    rm -rf "$TEST_DIR"
}

# ─── Tests ───────────────────────────────────────────────────────────────

# Test 1: Valid state file passes validation
test_case "validate_state_file accepts well-formed state"
setup_test_env
cat > "$TEST_STATE" <<'EOF'
---
pipeline: test-pipeline
goal: "test goal"
status: running
current_stage: intake
---

## Log
Initial state
EOF
validate_state_file "$TEST_STATE"
assert_eq "0" "$?" "validation should succeed"
teardown_test_env

# Test 2: Truncated state file (no closing delimiter) fails validation
test_case "validate_state_file rejects truncated state"
setup_test_env
cat > "$TEST_STATE" <<'EOF'
---
pipeline: test-pipeline
goal: "test goal"
status: running
EOF
if validate_state_file "$TEST_STATE"; then
    ((TESTS_FAILED++))
    error "FAIL: should reject truncated file"
else
    ((TESTS_PASSED++))
    success "PASS"
fi
teardown_test_env

# Test 3: Missing goal key fails validation
test_case "validate_state_file rejects missing goal"
setup_test_env
cat > "$TEST_STATE" <<'EOF'
---
pipeline: test-pipeline
status: running
current_stage: intake
---

## Log
EOF
if validate_state_file "$TEST_STATE"; then
    ((TESTS_FAILED++))
    error "FAIL: should reject missing goal"
else
    ((TESTS_PASSED++))
    success "PASS"
fi
teardown_test_env

# Test 4: Empty file fails validation
test_case "validate_state_file rejects empty file"
setup_test_env
touch "$TEST_STATE"
if validate_state_file "$TEST_STATE"; then
    ((TESTS_FAILED++))
    error "FAIL: should reject empty file"
else
    ((TESTS_PASSED++))
    success "PASS"
fi
teardown_test_env

# Test 5: Atomic write creates valid file (no stray tmp files)
test_case "atomic_write_file creates valid file atomically"
setup_test_env

# Create tmp file with valid state
TMP_STATE=$(mktemp "$TEST_DIR/tmp-state.XXXXXX")
cat > "$TMP_STATE" <<'EOF'
---
pipeline: atomic-test
goal: "atomic write test"
status: running
current_stage: build
---

## Log
Built with atomic writes
EOF

atomic_write_file "$TEST_STATE" "$TMP_STATE" validate_state_file
local result=$?

# Check: state file exists and is valid
if [[ -f "$TEST_STATE" ]]; then
    ((TESTS_PASSED++))
    success "PASS: state file created"
else
    ((TESTS_FAILED++))
    error "FAIL: state file not created"
fi

# Check: no stray tmp files
if ls "$TEST_DIR"/tmp-state.* >/dev/null 2>&1; then
    ((TESTS_FAILED++))
    error "FAIL: stray tmp file left behind"
else
    ((TESTS_PASSED++))
    success "PASS: no stray tmp files"
fi

# Check: state is valid
if grep -q "^goal:" "$TEST_STATE"; then
    ((TESTS_PASSED++))
    success "PASS: state is valid"
else
    ((TESTS_FAILED++))
    error "FAIL: state is invalid"
fi

teardown_test_env

# Test 6: .bak rotation on successful write
test_case "atomic_write_file rotates .bak file"
setup_test_env

# Create initial state
TMP1=$(mktemp "$TEST_DIR/tmp-state.XXXXXX")
cat > "$TMP1" <<'EOF'
---
pipeline: old
goal: "old goal"
status: running
---
EOF
atomic_write_file "$TEST_STATE" "$TMP1" validate_state_file

# Write new state (should rotate old to .bak)
TMP2=$(mktemp "$TEST_DIR/tmp-state.XXXXXX")
cat > "$TMP2" <<'EOF'
---
pipeline: new
goal: "new goal"
status: running
---
EOF
atomic_write_file "$TEST_STATE" "$TMP2" validate_state_file

# Check: .bak file exists with old state
if [[ -f "${TEST_STATE}.bak" ]] && grep -q "old goal" "${TEST_STATE}.bak"; then
    ((TESTS_PASSED++))
    success "PASS: .bak file created with old state"
else
    ((TESTS_FAILED++))
    error "FAIL: .bak rotation failed"
fi

teardown_test_env

# Test 7: Recover from .bak file
test_case "recover_state restores from .bak backup"
setup_test_env

# Create a corrupt state file
cat > "$TEST_STATE" <<'EOF'
---
pipeline: corrupt
goal: "valid goal
status: incomplete
EOF

# Create valid .bak
cat > "${TEST_STATE}.bak" <<'EOF'
---
pipeline: backup
goal: "backup goal"
status: running
current_stage: test
---
EOF

# Run recovery
if recover_state "$TEST_STATE" "$TEST_ARTIFACTS/checkpoints"; then
    ((TESTS_PASSED++))
    success "PASS: recovered from .bak"
else
    ((TESTS_FAILED++))
    error "FAIL: recovery from .bak failed"
fi

# Check: state file now matches .bak
if grep -q "backup goal" "$TEST_STATE"; then
    ((TESTS_PASSED++))
    success "PASS: state matches .bak"
else
    ((TESTS_FAILED++))
    error "FAIL: state doesn't match .bak after recovery"
fi

teardown_test_env

# Test 8: Recover from checkpoint when .bak unavailable
test_case "recover_state restores from checkpoint"
setup_test_env

# Create corrupt state with no .bak
cat > "$TEST_STATE" <<'EOF'
---
incomplete state
EOF

# Create checkpoint
CHECKPOINT="$TEST_ARTIFACTS/checkpoints/checkpoint-001.json"
cat > "$CHECKPOINT" <<'EOF'
{
  "stage": "build",
  "status": "running",
  "goal": "checkpoint recovery goal",
  "issue": ""
}
EOF

if recover_state "$TEST_STATE" "$TEST_ARTIFACTS/checkpoints"; then
    ((TESTS_PASSED++))
    success "PASS: recovered from checkpoint"
else
    ((TESTS_FAILED++))
    error "FAIL: recovery from checkpoint failed"
fi

# Check: variables restored from checkpoint
if [[ "$CURRENT_STAGE" == "build" && "$GOAL" == "checkpoint recovery goal" ]]; then
    ((TESTS_PASSED++))
    success "PASS: state variables restored from checkpoint"
else
    ((TESTS_FAILED++))
    error "FAIL: state variables not restored"
fi

teardown_test_env

# Test 9: Concurrent writes are serialized
test_case "atomic_write_file serializes concurrent writes"
setup_test_env

# Start 5 concurrent writes with 50ms stagger
for i in {1..5}; do
    (
        sleep 0.05
        TMP=$(mktemp "$TEST_DIR/tmp-state.XXXXXX")
        cat > "$TMP" <<EOF
---
pipeline: concurrent-$i
goal: "concurrent write $i"
status: running
---
EOF
        atomic_write_file "$TEST_STATE" "$TMP" validate_state_file
    ) &
done
wait

# Check: final state is valid
if validate_state_file "$TEST_STATE"; then
    ((TESTS_PASSED++))
    success "PASS: final state is valid after concurrent writes"
else
    ((TESTS_FAILED++))
    error "FAIL: final state is invalid"
fi

# Check: no stray tmp files
if ls "$TEST_DIR"/tmp-state.* >/dev/null 2>&1; then
    ((TESTS_FAILED++))
    error "FAIL: stray tmp file left after concurrent writes"
else
    ((TESTS_PASSED++))
    success "PASS: no stray tmp files after concurrent writes"
fi

teardown_test_env

# ─── Results ─────────────────────────────────────────────────────────────
echo -e "\n${CYAN}${BOLD}━━━ Test Summary ━━━${RESET}"
echo -e "  ${GREEN}✓ Passed:${RESET}  $TESTS_PASSED"
echo -e "  ${RED}✗ Failed:${RESET}  $TESTS_FAILED"
[[ "$TESTS_SKIPPED" -gt 0 ]] && echo -e "  ${YELLOW}⊘ Skipped:${RESET} $TESTS_SKIPPED"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
    exit 0
else
    exit 1
fi
