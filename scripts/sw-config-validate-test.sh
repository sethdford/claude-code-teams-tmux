#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-config-validate-test.sh — Config Validation Test Suite               ║
# ║  Tests _config_validate, _config_validate_file, and config chain         ║
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

assert_exit_code() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected exit code: $expected"
        echo "    Actual exit code:   $actual"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    Actual: $haystack"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Create a mini repo structure for testing
mkdir -p "$TMP_DIR/config" "$TMP_DIR/scripts/lib" "$TMP_DIR/.claude"

# Copy config.sh into temp structure
cp "$SCRIPT_DIR/lib/config.sh" "$TMP_DIR/scripts/lib/config.sh"

# Source config.sh from the real repo for function access
_SW_CONFIG_LOADED=""
source "$SCRIPT_DIR/lib/config.sh"

# ─── Test: valid defaults.json passes validation ───────────────────────────
test_valid_defaults() {
    cat > "$TMP_DIR/valid.json" <<'EOF'
{
  "loop": {
    "model": "opus",
    "max_iterations": 20,
    "auto_extend": true
  },
  "vitals": {
    "weight_momentum": 35,
    "weight_convergence": 30
  }
}
EOF

    cat > "$TMP_DIR/schema.json" <<'EOF'
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "loop": {
      "type": "object",
      "properties": {
        "model": { "type": "string" },
        "max_iterations": { "type": "integer" },
        "auto_extend": { "type": "boolean" }
      },
      "additionalProperties": false
    },
    "vitals": {
      "type": "object",
      "properties": {
        "weight_momentum": { "type": "integer" },
        "weight_convergence": { "type": "integer" }
      },
      "additionalProperties": false
    }
  }
}
EOF

    local rc=0
    _config_validate_file "$TMP_DIR/valid.json" "$TMP_DIR/schema.json" 2>/dev/null || rc=$?
    assert_exit_code 0 "$rc" "valid config passes validation"
}

# ─── Test: type mismatch detected ──────────────────────────────────────────
test_type_mismatch() {
    cat > "$TMP_DIR/bad-types.json" <<'EOF'
{
  "loop": {
    "model": 42,
    "max_iterations": "not-a-number",
    "auto_extend": "yes"
  }
}
EOF

    cat > "$TMP_DIR/schema.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "loop": {
      "type": "object",
      "properties": {
        "model": { "type": "string" },
        "max_iterations": { "type": "integer" },
        "auto_extend": { "type": "boolean" }
      },
      "additionalProperties": false
    }
  }
}
EOF

    local output rc=0
    output=$(_config_validate_file "$TMP_DIR/bad-types.json" "$TMP_DIR/schema.json" 2>&1) || rc=$?
    assert_exit_code 1 "$rc" "type mismatches cause validation failure"
    assert_contains "$output" "expected string" "reports string type error"
    assert_contains "$output" "expected boolean" "reports boolean type error"
}

# ─── Test: unknown keys detected ───────────────────────────────────────────
test_unknown_keys() {
    cat > "$TMP_DIR/unknown.json" <<'EOF'
{
  "loop": {
    "model": "opus",
    "bogus_key": 42
  }
}
EOF

    cat > "$TMP_DIR/schema.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "loop": {
      "type": "object",
      "properties": {
        "model": { "type": "string" }
      },
      "additionalProperties": false
    }
  }
}
EOF

    local output rc=0
    output=$(_config_validate_file "$TMP_DIR/unknown.json" "$TMP_DIR/schema.json" 2>&1) || rc=$?
    assert_exit_code 1 "$rc" "unknown keys cause validation failure"
    assert_contains "$output" "unknown key" "reports unknown key error"
}

# ─── Test: missing file returns error ──────────────────────────────────────
test_missing_file() {
    local rc=0
    _config_validate_file "$TMP_DIR/nonexistent.json" "$TMP_DIR/schema.json" 2>/dev/null || rc=$?
    assert_exit_code 1 "$rc" "missing config file returns error"
}

# ─── Test: missing schema skips validation ─────────────────────────────────
test_missing_schema() {
    cat > "$TMP_DIR/valid.json" <<'EOF'
{"loop": {"model": "opus"}}
EOF

    local rc=0
    _config_validate_file "$TMP_DIR/valid.json" "$TMP_DIR/no-such-schema.json" 2>/dev/null || rc=$?
    assert_exit_code 0 "$rc" "missing schema file skips validation (returns 0)"
}

# ─── Test: invalid JSON detected ──────────────────────────────────────────
test_invalid_json() {
    echo "not json {{{" > "$TMP_DIR/invalid.json"
    cat > "$TMP_DIR/schema.json" <<'EOF'
{"type": "object", "properties": {}}
EOF

    local rc=0
    _config_validate_file "$TMP_DIR/invalid.json" "$TMP_DIR/schema.json" 2>/dev/null || rc=$?
    assert_exit_code 1 "$rc" "invalid JSON detected"
}

# ─── Test: _config_validate --strict exits 1 on errors ────────────────────
test_strict_mode() {
    # Point to a bad defaults file
    local orig_defaults="$_DEFAULTS_FILE"
    local orig_repo="$_CONFIG_REPO_DIR"

    _CONFIG_REPO_DIR="$TMP_DIR"
    _DEFAULTS_FILE="$TMP_DIR/config/defaults.json"
    _DAEMON_CONFIG_FILE="$TMP_DIR/.claude/daemon-config.json"

    # Create an invalid defaults.json
    mkdir -p "$TMP_DIR/config"
    cat > "$TMP_DIR/config/defaults.json" <<'EOF'
{
  "loop": {
    "model": 999
  }
}
EOF

    # Copy the real schema
    cp "$SCRIPT_DIR/../config/defaults.schema.json" "$TMP_DIR/config/defaults.schema.json"

    local rc=0
    _config_validate --strict 2>/dev/null || rc=$?
    assert_exit_code 1 "$rc" "--strict mode exits 1 on validation errors"

    # Restore
    _DEFAULTS_FILE="$orig_defaults"
    _CONFIG_REPO_DIR="$orig_repo"
}

# ─── Test: _config_validate without --strict returns 0 on errors ──────────
test_non_strict_mode() {
    local orig_defaults="$_DEFAULTS_FILE"
    local orig_repo="$_CONFIG_REPO_DIR"

    _CONFIG_REPO_DIR="$TMP_DIR"
    _DEFAULTS_FILE="$TMP_DIR/config/defaults.json"
    _DAEMON_CONFIG_FILE="$TMP_DIR/.claude/daemon-config.json"

    # Create an invalid defaults.json
    cat > "$TMP_DIR/config/defaults.json" <<'EOF'
{
  "loop": {
    "model": 999
  }
}
EOF

    cp "$SCRIPT_DIR/../config/defaults.schema.json" "$TMP_DIR/config/defaults.schema.json"

    local rc=0
    _config_validate 2>/dev/null || rc=$?
    assert_exit_code 0 "$rc" "non-strict mode returns 0 despite errors"

    _DEFAULTS_FILE="$orig_defaults"
    _CONFIG_REPO_DIR="$orig_repo"
}

# ─── Test: real defaults.json passes validation ───────────────────────────
test_real_defaults_valid() {
    local defaults="$SCRIPT_DIR/../config/defaults.json"
    local schema="$SCRIPT_DIR/../config/defaults.schema.json"
    [[ -f "$defaults" ]] || { ((FAIL++)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m real defaults.json not found"; return; }
    [[ -f "$schema" ]] || { ((FAIL++)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m schema file not found"; return; }

    local rc=0
    _config_validate_file "$defaults" "$schema" 2>/dev/null || rc=$?
    assert_exit_code 0 "$rc" "real defaults.json passes schema validation"
}

# ─── Test: config chain reads new keys from defaults.json ─────────────────
test_config_chain_reads_new_keys() {
    local val
    val=$(_config_get "vitals.weight_momentum" "0")
    assert_equals "35" "$val" "config chain reads vitals.weight_momentum from defaults.json"

    val=$(_config_get "cost.opus_input_per_m" "0")
    assert_equals "15.00" "$val" "config chain reads cost.opus_input_per_m from defaults.json"

    val=$(_config_get "predictive.anomaly_threshold" "0")
    assert_equals "3.0" "$val" "config chain reads predictive.anomaly_threshold from defaults.json"

    val=$(_config_get "model_router.complexity_low" "0")
    assert_equals "30" "$val" "config chain reads model_router.complexity_low from defaults.json"

    val=$(_config_get "fleet.metrics_period" "0")
    assert_equals "7" "$val" "config chain reads fleet.metrics_period from defaults.json"

    val=$(_config_get "loop.model" "")
    assert_equals "opus" "$val" "config chain reads loop.model from defaults.json"

    val=$(_config_get "daemon.patrol_interval" "0")
    assert_equals "3600" "$val" "config chain reads daemon.patrol_interval from defaults.json"
}

# ─── Test: env var override takes precedence ──────────────────────────────
test_env_override() {
    export SHIPWRIGHT_VITALS_WEIGHT_MOMENTUM=99
    local val
    val=$(_config_get "vitals.weight_momentum" "0")
    assert_equals "99" "$val" "env var SHIPWRIGHT_VITALS_WEIGHT_MOMENTUM overrides defaults.json"
    unset SHIPWRIGHT_VITALS_WEIGHT_MOMENTUM
}

# ─── Test: number type validation for floats ──────────────────────────────
test_number_type_validation() {
    cat > "$TMP_DIR/floats.json" <<'EOF'
{
  "cost": {
    "opus_input_per_m": 15.00,
    "opus_output_per_m": "not-a-number"
  }
}
EOF

    cat > "$TMP_DIR/float-schema.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "cost": {
      "type": "object",
      "properties": {
        "opus_input_per_m": { "type": "number" },
        "opus_output_per_m": { "type": "number" }
      },
      "additionalProperties": false
    }
  }
}
EOF

    local output rc=0
    output=$(_config_validate_file "$TMP_DIR/floats.json" "$TMP_DIR/float-schema.json" 2>&1) || rc=$?
    assert_exit_code 1 "$rc" "string in number field detected"
    assert_contains "$output" "expected number" "reports number type error"
}

# ─── Test: array type validation ──────────────────────────────────────────
test_array_type_validation() {
    cat > "$TMP_DIR/arrays.json" <<'EOF'
{
  "labels": {
    "incident": "not-an-array"
  }
}
EOF

    cat > "$TMP_DIR/array-schema.json" <<'EOF'
{
  "type": "object",
  "properties": {
    "labels": {
      "type": "object",
      "properties": {
        "incident": { "type": "array" }
      },
      "additionalProperties": false
    }
  }
}
EOF

    local output rc=0
    output=$(_config_validate_file "$TMP_DIR/arrays.json" "$TMP_DIR/array-schema.json" 2>&1) || rc=$?
    assert_exit_code 1 "$rc" "string in array field detected"
    assert_contains "$output" "expected array" "reports array type error"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-config-validate-test.sh"
test_valid_defaults
test_type_mismatch
test_unknown_keys
test_missing_file
test_missing_schema
test_invalid_json
test_strict_mode
test_non_strict_mode
test_real_defaults_valid
test_config_chain_reads_new_keys
test_env_override
test_number_type_validation
test_array_type_validation

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
