#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-template-validate-test.sh — Template Schema Validator Test Suite     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
TMPDIR_TEST=""

# ─── Test helpers ─────────────────────────────────────────────────────────
pass() {
    PASS=$((PASS + 1))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $1"
    [[ -n "${2:-}" ]] && echo "    $2"
}

setup() {
    TMPDIR_TEST=$(mktemp -d "${TMPDIR:-/tmp}/sw-validate-test.XXXXXX")
}

teardown() {
    [[ -n "$TMPDIR_TEST" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}

trap teardown EXIT

# Source the validation library
source "$SCRIPT_DIR/lib/pipeline-validation.sh"

# ─── Helper: write JSON to temp file ─────────────────────────────────────
write_template() {
    local file="$TMPDIR_TEST/$1"
    cat > "$file"
    echo "$file"
}

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS — Core validation library
# ═══════════════════════════════════════════════════════════════════════════

echo "sw-template-validate-test.sh"
echo ""
echo "── Unit tests: validation library ──"
setup

# ─── Test: valid minimal template passes ──────────────────────────────────
test_valid_minimal() {
    local file
    file=$(write_template "valid.json" <<'EOF'
{
  "name": "test",
  "description": "A test template",
  "defaults": { "test_cmd": "npm test", "model": "opus", "agents": 1 },
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "build", "enabled": true, "gate": "auto", "config": {} },
    { "id": "test", "enabled": true, "gate": "auto", "config": {} },
    { "id": "pr", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    if validate_pipeline_template "$file" 2>/dev/null; then
        pass "valid minimal template passes"
    else
        fail "valid minimal template passes" "expected exit 0"
    fi
}

# ─── Test: missing name field ─────────────────────────────────────────────
test_missing_name() {
    local file
    file=$(write_template "no-name.json" <<'EOF'
{
  "description": "Missing name",
  "defaults": {},
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "missing name detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "missing required field: 'name'"; then
            pass "missing name detected"
        else
            fail "missing name detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: missing description field ──────────────────────────────────────
test_missing_description() {
    local file
    file=$(write_template "no-desc.json" <<'EOF'
{
  "name": "test",
  "defaults": {},
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "missing description detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "missing required field: 'description'"; then
            pass "missing description detected"
        else
            fail "missing description detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: missing defaults field ─────────────────────────────────────────
test_missing_defaults() {
    local file
    file=$(write_template "no-defaults.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "missing defaults detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "missing required field: 'defaults'"; then
            pass "missing defaults detected"
        else
            fail "missing defaults detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: missing stages field ───────────────────────────────────────────
test_missing_stages() {
    local file
    file=$(write_template "no-stages.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {}
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "missing stages detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "missing required field: 'stages'"; then
            pass "missing stages detected"
        else
            fail "missing stages detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: empty stages array ─────────────────────────────────────────────
test_empty_stages() {
    local file
    file=$(write_template "empty-stages.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": []
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "empty stages detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "must not be empty"; then
            pass "empty stages detected"
        else
            fail "empty stages detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: unknown stage ID ───────────────────────────────────────────────
test_unknown_stage_id() {
    local file
    file=$(write_template "bad-id.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "id": "foobar", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "unknown stage id detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "unknown stage id 'foobar'"; then
            pass "unknown stage id detected"
        else
            fail "unknown stage id detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: invalid gate value ─────────────────────────────────────────────
test_invalid_gate() {
    local file
    file=$(write_template "bad-gate.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "id": "intake", "enabled": true, "gate": "manual", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "invalid gate value detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "invalid gate value 'manual'"; then
            pass "invalid gate value detected"
        else
            fail "invalid gate value detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: enabled not boolean ────────────────────────────────────────────
test_enabled_not_boolean() {
    local file
    file=$(write_template "bad-enabled.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "id": "intake", "enabled": "yes", "gate": "auto", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "non-boolean enabled detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "'enabled' must be a boolean"; then
            pass "non-boolean enabled detected"
        else
            fail "non-boolean enabled detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: missing config object ──────────────────────────────────────────
test_missing_config() {
    local file
    file=$(write_template "no-config.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto" }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "missing config detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "'config' must be an object"; then
            pass "missing config detected"
        else
            fail "missing config detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: duplicate stage IDs ────────────────────────────────────────────
test_duplicate_stage_ids() {
    local file
    file=$(write_template "dup-ids.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "duplicate stage ids detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "duplicate stage id: 'intake'"; then
            pass "duplicate stage ids detected"
        else
            fail "duplicate stage ids detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: stage ordering violation ───────────────────────────────────────
test_stage_ordering_violation() {
    local file
    file=$(write_template "bad-order.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "id": "test", "enabled": true, "gate": "auto", "config": {} },
    { "id": "build", "enabled": true, "gate": "auto", "config": {} },
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "ordering violation detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "stage ordering violation"; then
            pass "ordering violation detected"
        else
            fail "ordering violation detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: disabled stages skip ordering check ────────────────────────────
test_disabled_stages_skip_ordering() {
    local file
    file=$(write_template "disabled-ok.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "id": "pr", "enabled": true, "gate": "auto", "config": {} },
    { "id": "test", "enabled": false, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    if validate_pipeline_template "$file" 2>/dev/null; then
        pass "disabled stages skip ordering check"
    else
        fail "disabled stages skip ordering check" "expected to pass (test is disabled)"
    fi
}

# ─── Test: negative max_iterations ────────────────────────────────────────
test_negative_max_iterations() {
    local file
    file=$(write_template "neg-iter.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "id": "build", "enabled": true, "gate": "auto", "config": { "max_iterations": -5 } }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "negative max_iterations detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "'max_iterations' must be a positive integer"; then
            pass "negative max_iterations detected"
        else
            fail "negative max_iterations detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: coverage_min out of range ──────────────────────────────────────
test_coverage_min_out_of_range() {
    local file
    file=$(write_template "bad-cov.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "id": "test", "enabled": true, "gate": "auto", "config": { "coverage_min": 150 } }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "coverage_min out of range detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "'coverage_min' must be 0-100"; then
            pass "coverage_min out of range detected"
        else
            fail "coverage_min out of range detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: invalid JSON input ─────────────────────────────────────────────
test_invalid_json() {
    local file
    file=$(write_template "bad.json" <<'EOF'
{ this is not json }
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "invalid JSON detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "not valid JSON"; then
            pass "invalid JSON detected"
        else
            fail "invalid JSON detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: multiple errors accumulated ────────────────────────────────────
test_multiple_errors_accumulated() {
    local file
    file=$(write_template "multi-err.json" <<'EOF'
{
  "defaults": {},
  "stages": [
    { "id": "foobar", "enabled": "yes", "gate": "manual" }
  ]
}
EOF
    )
    local output
    output=$(validate_pipeline_template "$file" 2>&1) || true
    local error_count
    error_count=$(echo "$output" | grep -c "validation error:" || true)
    if [[ "$error_count" -ge 3 ]]; then
        pass "multiple errors accumulated ($error_count errors)"
    else
        fail "multiple errors accumulated" "expected >=3 errors, got $error_count: $output"
    fi
}

# ─── Test: defaults.agents must be positive ───────────────────────────────
test_agents_must_be_positive() {
    local file
    file=$(write_template "bad-agents.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": { "agents": 0 },
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "zero agents detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "defaults.agents must be a positive integer"; then
            pass "zero agents detected"
        else
            fail "zero agents detected" "wrong error: $output"
        fi
    fi
}

# ─── Test: extra fields are allowed (forward-compatible) ──────────────────
test_extra_fields_allowed() {
    local file
    file=$(write_template "extra.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": { "test_cmd": "npm test", "model": "opus", "agents": 1 },
  "custom_field": "hello",
  "tdd": true,
  "intelligence": { "adversarial_enabled": true },
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": { "custom": true } }
  ]
}
EOF
    )
    if validate_pipeline_template "$file" 2>/dev/null; then
        pass "extra fields are allowed (forward-compatible)"
    else
        fail "extra fields are allowed" "should not reject unknown fields"
    fi
}

# ─── Test: missing stage id field ─────────────────────────────────────────
test_missing_stage_id() {
    local file
    file=$(write_template "no-id.json" <<'EOF'
{
  "name": "test",
  "description": "test",
  "defaults": {},
  "stages": [
    { "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    local output
    if output=$(validate_pipeline_template "$file" 2>&1); then
        fail "missing stage id detected" "expected validation to fail"
    else
        if echo "$output" | grep -q "missing required field 'id'"; then
            pass "missing stage id detected"
        else
            fail "missing stage id detected" "wrong error: $output"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# INTEGRATION TESTS — CLI entry point
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "── Integration tests: CLI ──"

# ─── Test: CLI validates a valid template file ────────────────────────────
test_cli_valid_file() {
    local file
    file=$(write_template "cli-valid.json" <<'EOF'
{
  "name": "test",
  "description": "A test template",
  "defaults": { "test_cmd": "npm test", "model": "opus", "agents": 1 },
  "stages": [
    { "id": "intake", "enabled": true, "gate": "auto", "config": {} },
    { "id": "build", "enabled": true, "gate": "auto", "config": {} },
    { "id": "test", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    if bash "$SCRIPT_DIR/sw-template-validate.sh" "$file" >/dev/null 2>&1; then
        pass "CLI validates valid template file"
    else
        fail "CLI validates valid template file"
    fi
}

# ─── Test: CLI rejects invalid template ───────────────────────────────────
test_cli_rejects_invalid() {
    local file
    file=$(write_template "cli-invalid.json" <<'EOF'
{
  "stages": [
    { "id": "unknown_stage", "enabled": true, "gate": "auto", "config": {} }
  ]
}
EOF
    )
    if bash "$SCRIPT_DIR/sw-template-validate.sh" "$file" >/dev/null 2>&1; then
        fail "CLI rejects invalid template"
    else
        pass "CLI rejects invalid template"
    fi
}

# ─── Test: CLI --help exits 0 ─────────────────────────────────────────────
test_cli_help() {
    if bash "$SCRIPT_DIR/sw-template-validate.sh" --help >/dev/null 2>&1; then
        pass "CLI --help exits 0"
    else
        fail "CLI --help exits 0"
    fi
}

# ─── Test: CLI --version outputs version ──────────────────────────────────
test_cli_version() {
    local output
    output=$(bash "$SCRIPT_DIR/sw-template-validate.sh" --version 2>/dev/null)
    if [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        pass "CLI --version outputs version"
    else
        fail "CLI --version outputs version" "got: $output"
    fi
}

# ─── Test: CLI with no args exits 1 ──────────────────────────────────────
test_cli_no_args() {
    if bash "$SCRIPT_DIR/sw-template-validate.sh" >/dev/null 2>&1; then
        fail "CLI with no args exits 1"
    else
        pass "CLI with no args exits 1"
    fi
}

# ─── Test: CLI validates by template name ─────────────────────────────────
test_cli_by_name() {
    if bash "$SCRIPT_DIR/sw-template-validate.sh" standard >/dev/null 2>&1; then
        pass "CLI validates by template name"
    else
        fail "CLI validates by template name"
    fi
}

# ─── Test: CLI --all validates all built-in templates ─────────────────────
test_cli_all() {
    if bash "$SCRIPT_DIR/sw-template-validate.sh" --all >/dev/null 2>&1; then
        pass "CLI --all validates all built-in templates"
    else
        fail "CLI --all validates all built-in templates"
    fi
}

# ─── Test: CLI nonexistent template fails ─────────────────────────────────
test_cli_nonexistent() {
    if bash "$SCRIPT_DIR/sw-template-validate.sh" nonexistent_template_xyz >/dev/null 2>&1; then
        fail "CLI nonexistent template fails"
    else
        pass "CLI nonexistent template fails"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# BUILT-IN TEMPLATE TESTS — No false positives
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "── Built-in template validation (no false positives) ──"

test_builtin_templates() {
    local template_dir="$SCRIPT_DIR/../templates/pipelines"
    if [[ ! -d "$template_dir" ]]; then
        fail "template directory exists" "not found: $template_dir"
        return
    fi

    for f in "$template_dir"/*.json; do
        [[ ! -f "$f" ]] && continue
        local name
        name=$(basename "$f")
        if validate_pipeline_template "$f" 2>/dev/null; then
            pass "built-in template valid: $name"
        else
            fail "built-in template valid: $name"
            validate_pipeline_template "$f" 2>&1 | head -5 || true
        fi
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# Run all tests
# ═══════════════════════════════════════════════════════════════════════════

# Unit tests
test_valid_minimal
test_missing_name
test_missing_description
test_missing_defaults
test_missing_stages
test_empty_stages
test_unknown_stage_id
test_invalid_gate
test_enabled_not_boolean
test_missing_config
test_duplicate_stage_ids
test_stage_ordering_violation
test_disabled_stages_skip_ordering
test_negative_max_iterations
test_coverage_min_out_of_range
test_invalid_json
test_multiple_errors_accumulated
test_agents_must_be_positive
test_extra_fields_allowed
test_missing_stage_id

# Integration tests
test_cli_valid_file
test_cli_rejects_invalid
test_cli_help
test_cli_version
test_cli_no_args
test_cli_by_name
test_cli_all
test_cli_nonexistent

# Built-in templates
test_builtin_templates

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
