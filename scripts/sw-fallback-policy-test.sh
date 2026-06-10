#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-fallback-policy-test.sh — Fallback Policy System Test Suite          ║
# ║                                                                          ║
# ║  Validates _smart_fallback precedence, clamping, fail-safe behavior,     ║
# ║  the audit scan, and the sw-fallback CLI. Hermetic: temp HOME + config.  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Hermetic environment ───────────────────────────────────────────────────
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/sw-fbp-test.XXXXXX")"
export HOME="$TEST_HOME"
export WORK_DIR="$TEST_HOME"
mkdir -p "$TEST_HOME/.shipwright" "$TEST_HOME/.claude"

POLICY="$TEST_HOME/fallback-policy.json"
OVERRIDES="$TEST_HOME/.shipwright/adaptive-overrides.json"
REAL_POLICY="$SCRIPT_DIR/../config/fallback-policy.json"
export SW_FALLBACK_POLICY_FILE="$POLICY"
export SW_FALLBACK_OVERRIDES_FILE="$OVERRIDES"

cat > "$POLICY" <<'JSON'
{
  "version": "1",
  "policies": {
    "net.timeout":  {"static": 30, "adaptive_range": [5, 120], "learning_enabled": true,  "confidence_threshold": 0.85},
    "net.disabled": {"static": 40, "adaptive_range": [5, 120], "learning_enabled": false, "confidence_threshold": 0.85}
  }
}
JSON

cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT

# shellcheck source=lib/fallback-policy.sh
source "$SCRIPT_DIR/lib/fallback-policy.sh"

print_test_header "Fallback Policy System Tests"

# ─── Precedence & resolution ────────────────────────────────────────────────
print_test_section "Resolution precedence"

assert_eq "unknown key falls through to hardcoded default" \
    "99" "$(_smart_fallback "no.such.key" 99)"

assert_eq "static policy value beats hardcoded default" \
    "30" "$(_smart_fallback "net.timeout" 7)"

assert_eq "env SW_<KEY> override beats static policy" \
    "11" "$(SW_NET_TIMEOUT=11 _smart_fallback "net.timeout" 7)"

DCFG="$TEST_HOME/.claude/daemon-config.json"
echo '{"fallback_overrides": {"net.timeout": 22}}' > "$DCFG"
assert_eq "daemon-config .fallback_overrides beats static policy" \
    "22" "$(DAEMON_CONFIG="$DCFG" _smart_fallback "net.timeout" 7)"
rm -f "$DCFG"

# ─── Adaptive override tier ─────────────────────────────────────────────────
print_test_section "Adaptive override tier"

echo '{"net.timeout": {"value": 45, "confidence": 0.9}}' > "$OVERRIDES"
assert_eq "confident in-range learned override is applied" \
    "45" "$(_smart_fallback "net.timeout" 7)"
rm -f "$OVERRIDES"

echo '{"net.timeout": {"value": 5000, "confidence": 0.95}}' > "$OVERRIDES"
assert_eq "out-of-range learned override is clamped to adaptive_range max" \
    "120" "$(_smart_fallback "net.timeout" 7)"
rm -f "$OVERRIDES"

echo '{"net.timeout": {"value": 45, "confidence": 0.5}}' > "$OVERRIDES"
assert_eq "low-confidence override is skipped, static returned" \
    "30" "$(_smart_fallback "net.timeout" 7)"
rm -f "$OVERRIDES"

echo '{"net.disabled": {"value": 45, "confidence": 0.99}}' > "$OVERRIDES"
assert_eq "learning_enabled=false ignores learned override" \
    "40" "$(_smart_fallback "net.disabled" 7)"
rm -f "$OVERRIDES"

# ─── Fail-safe & guards ─────────────────────────────────────────────────────
print_test_section "Fail-safe behavior"

assert_eq "invalid key returns hardcoded default (injection guard)" \
    "7" "$(_smart_fallback 'bad key;rm' 7)"

CORRUPT="$TEST_HOME/corrupt.json"
echo 'not json at all {' > "$CORRUPT"
corrupt_out=$(SW_FALLBACK_POLICY_FILE="$CORRUPT" bash -c '
    source "'"$SCRIPT_DIR"'/lib/fallback-policy.sh"
    _smart_fallback "net.timeout" 7
' 2>/dev/null || echo "ABORTED")
assert_eq "corrupt policy file falls back to hardcoded default (no abort)" \
    "7" "$corrupt_out"

assert_contains "resolver never returns empty" \
    "$(_smart_fallback "net.timeout" "")" "30"

# ─── Clamp helper ───────────────────────────────────────────────────────────
print_test_section "Clamp helper"

assert_eq "clamp above max -> max"        "120" "$(_fallback_clamp 200 5 120)"
assert_eq "clamp below min -> min"        "5"   "$(_fallback_clamp 1 5 120)"
assert_eq "clamp in-range -> unchanged"   "50"  "$(_fallback_clamp 50 5 120)"
assert_eq "clamp non-numeric -> passthrough" "abc" "$(_fallback_clamp abc 5 120)"

# ─── Audit scan ─────────────────────────────────────────────────────────────
print_test_section "Audit scan"

SCAN_DIR="$TEST_HOME/scan"
mkdir -p "$SCAN_DIR"
cat > "$SCAN_DIR/sample.sh" <<'EOF'
#!/usr/bin/env bash
x="${FOO:-bar}"
y="${TIMEOUT:-30}"
EOF
audit_line=$(_fallback_audit "$SCAN_DIR" | head -1)
assert_contains "audit emits variable field" "$audit_line" '"variable"'
assert_contains "audit emits default field"  "$audit_line" '"default"'
foo_default=$(_fallback_audit "$SCAN_DIR" | jq -r 'select(.variable=="FOO") | .default' 2>/dev/null | head -1)
assert_eq "audit captures FOO default 'bar'" "bar" "$foo_default"

# ─── CLI ────────────────────────────────────────────────────────────────────
print_test_section "sw-fallback CLI"

cli_out=$(SW_FALLBACK_POLICY_FILE="$REAL_POLICY" "$SCRIPT_DIR/sw-fallback.sh" validate 2>&1) && cli_rc=0 || cli_rc=$?
assert_exit_code "CLI validate passes on shipped policy" 0 "${cli_rc:-1}"
assert_contains "CLI validate reports valid" "$cli_out" "valid"

BAD="$TEST_HOME/bad-policy.json"
echo '{"version":"1","policies":{"x.y":{"static":500,"adaptive_range":[5,120],"learning_enabled":false}}}' > "$BAD"
SW_FALLBACK_POLICY_FILE="$BAD" "$SCRIPT_DIR/sw-fallback.sh" validate >/dev/null 2>&1 && bad_rc=0 || bad_rc=$?
assert_exit_code "CLI validate rejects static outside adaptive_range" 1 "${bad_rc:-0}"

help_out=$("$SCRIPT_DIR/sw-fallback.sh" --help 2>&1)
assert_contains "help lists audit subcommand"    "$help_out" "audit"
assert_contains "help lists validate subcommand" "$help_out" "validate"
assert_contains "help lists get subcommand"      "$help_out" "get"

get_out=$(SW_FALLBACK_POLICY_FILE="$POLICY" "$SCRIPT_DIR/sw-fallback.sh" get net.timeout 7 2>&1)
assert_eq "CLI get resolves static policy value" "30" "$get_out"

# ─── Adaptive bridge writer (sw-adaptive.sh) ────────────────────────────────
print_test_section "Adaptive bridge (write_adaptive_override)"

# Source sw-adaptive defensively (it sets its own traps); use the real policy.
bridge_write() {
    # Run in a clean subshell so the bridge's set -e/ERR trap can't leak.
    SW_FALLBACK_POLICY_FILE="$REAL_POLICY" \
    SW_FALLBACK_OVERRIDES_FILE="$OVERRIDES" \
    HOME="$TEST_HOME" \
    bash -c '
        set +e
        source "'"$SCRIPT_DIR"'/sw-adaptive.sh" 2>/dev/null
        trap - ERR          # drop sw-adaptive ERR trap (references $BASH_SOURCE)
        set +eu             # sw-adaptive set -eu; intended return 1 must not abort
        write_adaptive_override "'"$1"'" "'"$2"'" "'"$3"'" >/dev/null 2>&1
        echo "rc=$?"
    '
}

rm -f "$OVERRIDES"
br=$(bridge_write "network.gh_timeout" 25 0.9)
assert_contains "bridge writes confident in-range override (rc=0)" "$br" "rc=0"
written=$(jq -r '."network.gh_timeout".value' "$OVERRIDES" 2>/dev/null || echo "")
assert_eq "bridge persisted clamped value" "25" "$written"

br=$(bridge_write "network.gh_timeout" 9999 0.95)
clamped=$(jq -r '."network.gh_timeout".value' "$OVERRIDES" 2>/dev/null || echo "")
assert_eq "bridge clamps out-of-range value to adaptive_range max (300)" "300" "$clamped"

br=$(bridge_write "network.gh_timeout" 50 0.5)
assert_contains "bridge skips low-confidence write (rc=1)" "$br" "rc=1"

br=$(bridge_write "bogus.undeclared.key" 5 0.99)
assert_contains "bridge skips undeclared key (rc=1)" "$br" "rc=1"

br=$(bridge_write "network.gh_timeout" notanumber 0.99)
assert_contains "bridge skips non-numeric value (rc=1)" "$br" "rc=1"
rm -f "$OVERRIDES"

# Resolver consumes a bridge-written override end-to-end (with learning enabled).
LEARN_POLICY="$TEST_HOME/learn-policy.json"
echo '{"version":"1","policies":{"net.timeout":{"static":30,"adaptive_range":[5,120],"learning_enabled":true,"confidence_threshold":0.85}}}' > "$LEARN_POLICY"
echo '{"net.timeout":{"value":77,"confidence":0.9}}' > "$OVERRIDES"
e2e=$(SW_FALLBACK_POLICY_FILE="$LEARN_POLICY" bash -c '
    source "'"$SCRIPT_DIR"'/lib/fallback-policy.sh"
    _smart_fallback "net.timeout" 7
')
assert_eq "resolver applies a bridge-shaped learned override end-to-end" "77" "$e2e"
rm -f "$OVERRIDES"

# ─── Real shipped policy sanity ─────────────────────────────────────────────
print_test_section "Shipped policy"

# Migration target is >= 67 high-impact fallbacks (see issue #620). Use a floor
# rather than an exact count so the assertion tracks incremental migration
# progress while still catching regressions/deletions below the current baseline.
real_count=$(jq -r '.policies | length' "$REAL_POLICY" 2>/dev/null || echo 0)
assert_gt "shipped policy declares a growing set of high-impact fallbacks (>= 29)" "$real_count" "28"
learning_on=$(jq -r '[.policies[] | select(.learning_enabled == true)] | length' "$REAL_POLICY" 2>/dev/null || echo -1)
assert_eq "all shipped policies have learning_enabled=false (GA-safe)" "0" "$learning_on"

print_test_results
