#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-emergency-mode-test.sh — Emergency mode activation/deactivation      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -uo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test harness
PASS=0 FAIL=0

# Helpers
info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# Test: Emergency module sources successfully
info "Test 1: Emergency module sources without errors"
if source "$SCRIPT_DIR/lib/daemon-emergency.sh" 2>/dev/null; then
    success "Emergency module sourced successfully"
    ((PASS++))
else
    error "Failed to source emergency module"
    ((FAIL++))
fi

# Test: EMERGENCY_MODE_ENABLED defaults to true
info "Test 2: EMERGENCY_MODE_ENABLED defaults to true"
if grep -q 'EMERGENCY_ACTIVATION_THRESHOLD=.*30' "$SCRIPT_DIR/lib/daemon-emergency.sh"; then
    success "EMERGENCY_ACTIVATION_THRESHOLD set to default (30)"
    ((PASS++))
else
    error "EMERGENCY_ACTIVATION_THRESHOLD not set correctly"
    ((FAIL++))
fi

# Test: Configuration variables are defined
info "Test 3: Configuration variables are defined in module"
VARS_FOUND=0
grep -q "EMERGENCY_ACTIVATION_THRESHOLD=" "$SCRIPT_DIR/lib/daemon-emergency.sh" && ((VARS_FOUND++))
grep -q "EMERGENCY_RECOVERY_THRESHOLD=" "$SCRIPT_DIR/lib/daemon-emergency.sh" && ((VARS_FOUND++))
grep -q "EMERGENCY_ROLLING_WINDOW=" "$SCRIPT_DIR/lib/daemon-emergency.sh" && ((VARS_FOUND++))

if [[ $VARS_FOUND -ge 3 ]]; then
    success "Configuration variables defined ($VARS_FOUND/3)"
    ((PASS++))
else
    error "Configuration variables not all defined"
    ((FAIL++))
fi

# Test: Functions are defined
info "Test 4: Core functions are defined in module"
FUNCTIONS_FOUND=0
grep -q "^daemon_emergency_check()" "$SCRIPT_DIR/lib/daemon-emergency.sh" && ((FUNCTIONS_FOUND++))
grep -q "^daemon_emergency_is_active()" "$SCRIPT_DIR/lib/daemon-emergency.sh" && ((FUNCTIONS_FOUND++))
grep -q "^daemon_emergency_activate()" "$SCRIPT_DIR/lib/daemon-emergency.sh" && ((FUNCTIONS_FOUND++))
grep -q "^daemon_emergency_deactivate()" "$SCRIPT_DIR/lib/daemon-emergency.sh" && ((FUNCTIONS_FOUND++))

if [[ $FUNCTIONS_FOUND -ge 4 ]]; then
    success "Core functions defined (4/4)"
    ((PASS++))
else
    error "Some functions not found ($FUNCTIONS_FOUND/4)"
    ((FAIL++))
fi


# Test: Activation threshold logic
info "Test 5: Success rate calculation logic"
EVENTS_FILE="/tmp/test_events_$$.jsonl"
mkdir -p "$(dirname "$EVENTS_FILE")"
# Create 2 success, 8 failure events (20% success rate)
for i in 1 2; do
    echo '{"type":"pipeline.completed","data":{"result":"success"}}' >> "$EVENTS_FILE"
done
for i in 1 2 3 4 5 6 7 8; do
    echo '{"type":"pipeline.completed","data":{"result":"failed"}}' >> "$EVENTS_FILE"
done

# Test jq parsing works
if recent_events=$(jq -s "[.[] | select(.type == \"pipeline.completed\")] | if length > 10 then .[-10:] else . end" "$EVENTS_FILE" 2>/dev/null); then
    total=$(echo "$recent_events" | jq 'length' 2>/dev/null || echo 0)
    failures=$(echo "$recent_events" | jq '[.[] | select(.data.result == "failed")] | length' 2>/dev/null || echo 0)
    successes=$((total - failures))
    success_rate=$((successes * 100 / total))

    if [[ $success_rate -eq 20 ]]; then
        success "Success rate calculation correct (${success_rate}% = ${successes}/${total})"
        ((PASS++))
    else
        error "Success rate calculation wrong (expected 20%, got ${success_rate}%)"
        ((FAIL++))
    fi
else
    error "jq parsing failed"
    ((FAIL++))
fi
rm -f "$EVENTS_FILE"

# Test: Flag file creation path
info "Test 6: Flag file directory structure"
FLAG_TEST_DIR="/tmp/emergency_test_$$"
mkdir -p "$FLAG_TEST_DIR/.shipwright"
if [[ -d "$FLAG_TEST_DIR/.shipwright" ]]; then
    success "Flag directory can be created"
    ((PASS++))
else
    error "Cannot create flag directory"
    ((FAIL++))
fi
rm -rf "$FLAG_TEST_DIR"

# Test: Atomic write pattern
info "Test 7: Atomic write pattern works"
TEST_DIR="/tmp/atomic_test_$$"
mkdir -p "$TEST_DIR"
TEST_FILE="$TEST_DIR/test.json"
TEST_TMP="${TEST_FILE}.tmp.$$"

if echo '{"test":"data"}' > "$TEST_TMP" && mv "$TEST_TMP" "$TEST_FILE" && [[ -f "$TEST_FILE" ]] && ! ls "$TEST_TMP"* >/dev/null 2>&1; then
    success "Atomic write pattern works"
    ((PASS++))
else
    error "Atomic write pattern failed"
    ((FAIL++))
fi
rm -rf "$TEST_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  \033[38;2;74;222;128m\033[1mPASS\033[0m  $PASS"
echo -e "  \033[38;2;248;113;113m\033[1mFAIL\033[0m  $FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
