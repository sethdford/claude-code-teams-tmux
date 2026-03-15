#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-config-validate-test.sh — Config Schema Validation Test Suite        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ─────────────────────────────────────────────────────────────
assert_pass() {
    local description="$1"
    PASS=$((PASS + 1))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
}

assert_fail() {
    local description="$1"
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
}

assert_exit_code() {
    local expected="$1" actual="$2" description="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$description"
    else
        assert_fail "$description (expected exit $expected, got $actual)"
    fi
}

# ─── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

SCHEMA_FILE="$SCRIPT_DIR/../config/daemon-config.schema.json"

# Source the validation library
source "$SCRIPT_DIR/lib/config-validate.sh"

# ─── Test: valid config passes validation ─────────────────────────────────────
test_valid_config() {
    local cfg="$TMPDIR_BASE/valid.json"
    cat > "$cfg" <<'EOF'
{
  "max_parallel": 2,
  "poll_interval": 60,
  "pipeline_template": "autonomous",
  "self_optimize": true,
  "watch_label": "shipwright",
  "intelligence": {
    "enabled": true,
    "cache_ttl_seconds": 3600,
    "ab_test_ratio": 0.2
  }
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "valid config passes validation"
}

# ─── Test: invalid JSON syntax fails ──────────────────────────────────────────
test_invalid_json() {
    local cfg="$TMPDIR_BASE/bad-syntax.json"
    echo '{ "max_parallel": 2, }' > "$cfg"
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "invalid JSON syntax fails validation"
}

# ─── Test: wrong type for string field ────────────────────────────────────────
test_wrong_type_string() {
    local cfg="$TMPDIR_BASE/bad-type-str.json"
    cat > "$cfg" <<'EOF'
{
  "watch_label": 123
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "number for string field fails"
}

# ─── Test: wrong type for integer field ───────────────────────────────────────
test_wrong_type_int() {
    local cfg="$TMPDIR_BASE/bad-type-int.json"
    cat > "$cfg" <<'EOF'
{
  "max_parallel": "two"
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "string for integer field fails"
}

# ─── Test: wrong type for boolean field ───────────────────────────────────────
test_wrong_type_bool() {
    local cfg="$TMPDIR_BASE/bad-type-bool.json"
    cat > "$cfg" <<'EOF'
{
  "self_optimize": "yes"
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "string for boolean field fails"
}

# ─── Test: value below minimum fails ─────────────────────────────────────────
test_below_minimum() {
    local cfg="$TMPDIR_BASE/below-min.json"
    cat > "$cfg" <<'EOF'
{
  "max_parallel": 0
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "value below minimum fails"
}

# ─── Test: value above maximum fails ─────────────────────────────────────────
test_above_maximum() {
    local cfg="$TMPDIR_BASE/above-max.json"
    cat > "$cfg" <<'EOF'
{
  "max_parallel": 100
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "value above maximum fails"
}

# ─── Test: invalid enum value fails ──────────────────────────────────────────
test_invalid_enum() {
    local cfg="$TMPDIR_BASE/bad-enum.json"
    cat > "$cfg" <<'EOF'
{
  "pipeline_template": "nonexistent"
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "invalid enum value fails"
}

# ─── Test: valid enum values pass ─────────────────────────────────────────────
test_valid_enum() {
    local cfg="$TMPDIR_BASE/good-enum.json"
    cat > "$cfg" <<'EOF'
{
  "pipeline_template": "fast"
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "valid enum value passes"
}

# ─── Test: missing config file fails ─────────────────────────────────────────
test_missing_file() {
    local rc=0
    _validate_daemon_config "/nonexistent/file.json" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "missing config file fails"
}

# ─── Test: missing schema file skips gracefully ──────────────────────────────
test_missing_schema() {
    local cfg="$TMPDIR_BASE/valid2.json"
    echo '{"max_parallel": 2}' > "$cfg"
    local rc=0
    _validate_daemon_config "$cfg" "/nonexistent/schema.json" >/dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "missing schema file skips gracefully"
}

# ─── Test: SKIP_CONFIG_VALIDATION bypasses ────────────────────────────────────
test_skip_flag() {
    local cfg="$TMPDIR_BASE/bad-skip.json"
    echo '{ broken json' > "$cfg"
    local rc=0
    SKIP_CONFIG_VALIDATION=true _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "SKIP_CONFIG_VALIDATION=true bypasses validation"
}

# ─── Test: empty object passes ────────────────────────────────────────────────
test_empty_object() {
    local cfg="$TMPDIR_BASE/empty.json"
    echo '{}' > "$cfg"
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "empty object passes validation"
}

# ─── Test: unknown fields pass (additionalProperties: true) ──────────────────
test_unknown_fields() {
    local cfg="$TMPDIR_BASE/extra.json"
    cat > "$cfg" <<'EOF'
{
  "custom_field": "whatever",
  "max_parallel": 2
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "unknown fields are allowed"
}

# ─── Test: nested object type validation ──────────────────────────────────────
test_nested_type() {
    local cfg="$TMPDIR_BASE/bad-nested.json"
    cat > "$cfg" <<'EOF'
{
  "intelligence": {
    "enabled": "not-a-bool"
  }
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "nested field wrong type fails"
}

# ─── Test: nested range validation ────────────────────────────────────────────
test_nested_range() {
    local cfg="$TMPDIR_BASE/bad-nested-range.json"
    cat > "$cfg" <<'EOF'
{
  "intelligence": {
    "ab_test_ratio": 1.5
  }
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "nested value above maximum fails"
}

# ─── Test: the real repo config passes ────────────────────────────────────────
test_real_config() {
    local real_cfg="$SCRIPT_DIR/../.claude/daemon-config.json"
    if [[ -f "$real_cfg" ]]; then
        local rc=0
        _validate_daemon_config "$real_cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
        assert_exit_code 0 "$rc" "real .claude/daemon-config.json passes validation"
    else
        assert_pass "real config not present (skipped)"
    fi
}

# ─── Test: non-object root fails ─────────────────────────────────────────────
test_non_object_root() {
    local cfg="$TMPDIR_BASE/array-root.json"
    echo '[1, 2, 3]' > "$cfg"
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "array root fails validation"
}

# ─── Test: float for integer field fails ──────────────────────────────────────
test_float_for_int() {
    local cfg="$TMPDIR_BASE/float-int.json"
    cat > "$cfg" <<'EOF'
{
  "max_parallel": 2.5
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "float for integer field fails"
}

# ─── Test: multiple errors reported ──────────────────────────────────────────
test_multiple_errors() {
    local cfg="$TMPDIR_BASE/multi-err.json"
    cat > "$cfg" <<'EOF'
{
  "max_parallel": "bad",
  "self_optimize": 42,
  "pipeline_template": "invalid"
}
EOF
    local rc=0
    local output
    output=$(_validate_daemon_config "$cfg" "$SCHEMA_FILE" 2>&1) || rc=$?
    assert_exit_code 1 "$rc" "multiple errors detected"
    # Check that error count is reported
    if echo "$output" | grep -q "3 error"; then
        assert_pass "reports correct error count"
    else
        assert_fail "reports correct error count"
    fi
}

# ─── Test: watch_mode enum ────────────────────────────────────────────────────
test_watch_mode_enum() {
    local cfg="$TMPDIR_BASE/watch-mode.json"
    cat > "$cfg" <<'EOF'
{
  "watch_mode": "org"
}
EOF
    local rc=0
    _validate_daemon_config "$cfg" "$SCHEMA_FILE" >/dev/null 2>&1 || rc=$?
    assert_exit_code 0 "$rc" "valid watch_mode enum passes"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
echo "sw-config-validate-test.sh"
test_valid_config
test_invalid_json
test_wrong_type_string
test_wrong_type_int
test_wrong_type_bool
test_below_minimum
test_above_maximum
test_invalid_enum
test_valid_enum
test_missing_file
test_missing_schema
test_skip_flag
test_empty_object
test_unknown_fields
test_nested_type
test_nested_range
test_real_config
test_non_object_root
test_float_for_int
test_multiple_errors
test_watch_mode_enum

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
