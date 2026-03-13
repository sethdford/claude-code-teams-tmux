#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-smoke-test-test.sh — Smoke Test & Minimal Template Test Suite        ║
# ║                                                                          ║
# ║  Validates the minimal pipeline template structure, the smoke test       ║
# ║  runner script, and pipeline composer validation.                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEMPLATE_FILE="$REPO_DIR/templates/pipelines/minimal.json"
SMOKE_SCRIPT="$SCRIPT_DIR/sw-smoke-test.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TEMPLATE STRUCTURE TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "sw-smoke-test-test.sh — Minimal Template & Smoke Test"

print_test_section "Template Structure"

test_template_exists() {
    assert_file_exists "minimal.json template exists" "$TEMPLATE_FILE"
}

test_template_valid_json() {
    if jq '.' "$TEMPLATE_FILE" >/dev/null 2>&1; then
        assert_pass "minimal.json is valid JSON"
    else
        assert_fail "minimal.json is valid JSON" "jq parse failed"
    fi
}

test_template_name() {
    local name
    name=$(jq -r '.name' "$TEMPLATE_FILE")
    assert_eq "template name is 'minimal'" "minimal" "$name"
}

test_template_description() {
    local desc
    desc=$(jq -r '.description' "$TEMPLATE_FILE")
    if [[ -n "$desc" && "$desc" != "null" ]]; then
        assert_pass "template has description"
    else
        assert_fail "template has description" "description is empty or null"
    fi
}

test_template_model() {
    local model
    model=$(jq -r '.defaults.model' "$TEMPLATE_FILE")
    assert_eq "default model is sonnet" "sonnet" "$model"
}

test_template_agents() {
    local agents
    agents=$(jq -r '.defaults.agents' "$TEMPLATE_FILE")
    assert_eq "default agents is 1" "1" "$agents"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE CONFIGURATION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Stage Configuration"

test_intake_enabled() {
    local enabled
    enabled=$(jq -r '.stages[] | select(.id == "intake") | .enabled' "$TEMPLATE_FILE")
    assert_eq "intake stage is enabled" "true" "$enabled"
}

test_intake_auto_gate() {
    local gate
    gate=$(jq -r '.stages[] | select(.id == "intake") | .gate' "$TEMPLATE_FILE")
    assert_eq "intake gate is auto" "auto" "$gate"
}

test_build_enabled() {
    local enabled
    enabled=$(jq -r '.stages[] | select(.id == "build") | .enabled' "$TEMPLATE_FILE")
    assert_eq "build stage is enabled" "true" "$enabled"
}

test_build_auto_gate() {
    local gate
    gate=$(jq -r '.stages[] | select(.id == "build") | .gate' "$TEMPLATE_FILE")
    assert_eq "build gate is auto" "auto" "$gate"
}

test_build_max_iterations() {
    local iters
    iters=$(jq -r '.stages[] | select(.id == "build") | .config.max_iterations' "$TEMPLATE_FILE")
    assert_eq "build max_iterations is 5" "5" "$iters"
}

test_build_timeout() {
    local timeout
    timeout=$(jq -r '.stages[] | select(.id == "build") | .config.timeout' "$TEMPLATE_FILE")
    assert_eq "build timeout is 600 (10 min)" "600" "$timeout"
}

test_build_no_audit() {
    local audit
    audit=$(jq -r '.stages[] | select(.id == "build") | .config.audit' "$TEMPLATE_FILE")
    assert_eq "build audit disabled" "false" "$audit"
}

test_build_no_quality_gates() {
    local qg
    qg=$(jq -r '.stages[] | select(.id == "build") | .config.quality_gates' "$TEMPLATE_FILE")
    assert_eq "build quality_gates disabled" "false" "$qg"
}

test_plan_disabled() {
    local enabled
    enabled=$(jq -r '.stages[] | select(.id == "plan") | .enabled' "$TEMPLATE_FILE")
    assert_eq "plan stage is disabled" "false" "$enabled"
}

test_test_disabled() {
    local enabled
    enabled=$(jq -r '.stages[] | select(.id == "test") | .enabled' "$TEMPLATE_FILE")
    assert_eq "test stage is disabled" "false" "$enabled"
}

test_review_disabled() {
    local enabled
    enabled=$(jq -r '.stages[] | select(.id == "review") | .enabled' "$TEMPLATE_FILE")
    assert_eq "review stage is disabled" "false" "$enabled"
}

test_compound_quality_disabled() {
    local enabled
    enabled=$(jq -r '.stages[] | select(.id == "compound_quality") | .enabled' "$TEMPLATE_FILE")
    assert_eq "compound_quality stage is disabled" "false" "$enabled"
}

test_pr_disabled() {
    local enabled
    enabled=$(jq -r '.stages[] | select(.id == "pr") | .enabled' "$TEMPLATE_FILE")
    assert_eq "pr stage is disabled" "false" "$enabled"
}

test_deploy_disabled() {
    local enabled
    enabled=$(jq -r '.stages[] | select(.id == "deploy") | .enabled' "$TEMPLATE_FILE")
    assert_eq "deploy stage is disabled" "false" "$enabled"
}

test_only_two_stages_enabled() {
    local count
    count=$(jq '[.stages[] | select(.enabled == true)] | length' "$TEMPLATE_FILE")
    assert_eq "exactly 2 stages enabled (intake + build)" "2" "$count"
}

# ═══════════════════════════════════════════════════════════════════════════════
# INTELLIGENCE DISABLED TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Intelligence Configuration"

test_adversarial_disabled() {
    local val
    val=$(jq -r '.intelligence.adversarial_enabled' "$TEMPLATE_FILE")
    assert_eq "adversarial intelligence disabled" "false" "$val"
}

test_architecture_disabled() {
    local val
    val=$(jq -r '.intelligence.architecture_enabled' "$TEMPLATE_FILE")
    assert_eq "architecture intelligence disabled" "false" "$val"
}

test_simulation_disabled() {
    local val
    val=$(jq -r '.intelligence.simulation_enabled' "$TEMPLATE_FILE")
    assert_eq "simulation intelligence disabled" "false" "$val"
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMPOSER VALIDATION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Pipeline Composer Validation"

test_template_passes_composer_validation() {
    # Source only what we need for validation
    local validate_output
    local exit_code=0

    # The composer validate checks: stages array, ids, ordering of enabled stages
    validate_output=$(bash "$SCRIPT_DIR/sw-pipeline-composer.sh" validate "$TEMPLATE_FILE" 2>&1) || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        assert_pass "template passes composer validation"
    else
        assert_fail "template passes composer validation" "$validate_output"
    fi
}

test_stage_ordering_intake_before_build() {
    local enabled_ids
    enabled_ids=$(jq -r '[.stages[] | select(.enabled == true) | .id] | join(",")' "$TEMPLATE_FILE")
    # intake should appear before build in the enabled stages
    local intake_pos=-1
    local build_pos=-1
    local pos=0
    local IFS=","
    for sid in $enabled_ids; do
        if [[ "$sid" == "intake" ]]; then intake_pos=$pos; fi
        if [[ "$sid" == "build" ]]; then build_pos=$pos; fi
        pos=$((pos + 1))
    done
    if [[ "$intake_pos" -ge 0 && "$build_pos" -ge 0 && "$intake_pos" -lt "$build_pos" ]]; then
        assert_pass "intake comes before build in enabled stages"
    else
        assert_fail "intake comes before build in enabled stages" "intake=$intake_pos build=$build_pos"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# SMOKE TEST SCRIPT TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Smoke Test Script"

test_smoke_script_exists() {
    assert_file_exists "sw-smoke-test.sh exists" "$SMOKE_SCRIPT"
}

test_smoke_script_executable() {
    if [[ -x "$SMOKE_SCRIPT" ]]; then
        assert_pass "sw-smoke-test.sh is executable"
    else
        assert_fail "sw-smoke-test.sh is executable"
    fi
}

test_smoke_script_has_version() {
    if grep -q 'VERSION=' "$SMOKE_SCRIPT"; then
        assert_pass "sw-smoke-test.sh has VERSION"
    else
        assert_fail "sw-smoke-test.sh has VERSION"
    fi
}

test_smoke_script_help() {
    local output
    local exit_code=0
    output=$(bash "$SMOKE_SCRIPT" --help 2>&1) || exit_code=$?
    assert_exit_code "--help exits 0" "0" "$exit_code"
    assert_contains "--help shows USAGE" "$output" "USAGE"
    assert_contains "--help mentions minimal" "$output" "minimal"
}

test_smoke_script_version() {
    local output
    local exit_code=0
    output=$(bash "$SMOKE_SCRIPT" --version 2>&1) || exit_code=$?
    assert_exit_code "--version exits 0" "0" "$exit_code"
    assert_contains_regex "--version outputs semver" "$output" '^[0-9]+\.[0-9]+\.[0-9]+'
}

test_smoke_script_invalid_option() {
    local exit_code=0
    bash "$SMOKE_SCRIPT" --invalid >/dev/null 2>&1 || exit_code=$?
    assert_eq "invalid option exits non-zero" "1" "$exit_code"
}

test_smoke_script_uses_minimal_pipeline() {
    if grep -q '\-\-pipeline minimal' "$SMOKE_SCRIPT"; then
        assert_pass "smoke test uses --pipeline minimal"
    else
        assert_fail "smoke test uses --pipeline minimal"
    fi
}

test_smoke_script_uses_health_check_file() {
    if grep -q 'health-check-' "$SMOKE_SCRIPT"; then
        assert_pass "smoke test creates health-check file"
    else
        assert_fail "smoke test creates health-check file"
    fi
}

test_smoke_script_signals_loop_complete() {
    if grep -q 'LOOP_COMPLETE' "$SMOKE_SCRIPT"; then
        assert_pass "smoke test goal signals LOOP_COMPLETE"
    else
        assert_fail "smoke test goal signals LOOP_COMPLETE"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEMPLATE DISCOVERABLE VIA PIPELINE LIST
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Template Discovery"

test_template_in_pipelines_dir() {
    local templates_dir="$REPO_DIR/templates/pipelines"
    if [[ -f "$templates_dir/minimal.json" ]]; then
        assert_pass "minimal.json in templates/pipelines/ directory"
    else
        assert_fail "minimal.json in templates/pipelines/ directory"
    fi
}

test_template_among_siblings() {
    # Verify it sits alongside fast.json, standard.json, etc.
    local templates_dir="$REPO_DIR/templates/pipelines"
    if [[ -f "$templates_dir/fast.json" && -f "$templates_dir/minimal.json" ]]; then
        assert_pass "minimal.json alongside fast.json"
    else
        assert_fail "minimal.json alongside fast.json"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# Template structure
test_template_exists
test_template_valid_json
test_template_name
test_template_description
test_template_model
test_template_agents

# Stage configuration
test_intake_enabled
test_intake_auto_gate
test_build_enabled
test_build_auto_gate
test_build_max_iterations
test_build_timeout
test_build_no_audit
test_build_no_quality_gates
test_plan_disabled
test_test_disabled
test_review_disabled
test_compound_quality_disabled
test_pr_disabled
test_deploy_disabled
test_only_two_stages_enabled

# Intelligence
test_adversarial_disabled
test_architecture_disabled
test_simulation_disabled

# Composer validation
test_template_passes_composer_validation
test_stage_ordering_intake_before_build

# Smoke test script
test_smoke_script_exists
test_smoke_script_executable
test_smoke_script_has_version
test_smoke_script_help
test_smoke_script_version
test_smoke_script_invalid_option
test_smoke_script_uses_minimal_pipeline
test_smoke_script_uses_health_check_file
test_smoke_script_signals_loop_complete

# Discovery
test_template_in_pipelines_dir
test_template_among_siblings

print_test_results
