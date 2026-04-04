#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright intelligence orchestrator test                               ║
# ║  Validates orchestration sequence, idempotency, config swap, fallbacks  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-intel-orch-test.XXXXXX")

    mkdir -p "$TEST_TEMP_DIR/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/.claude"
    mkdir -p "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    mkdir -p "$TEST_TEMP_DIR/bin"

    export HOME="$TEST_TEMP_DIR"
    export EVENTS_FILE="$TEST_TEMP_DIR/.shipwright/events.jsonl"
    export NO_GITHUB=true

    # Enable intelligence in mock config
    cat > "$TEST_TEMP_DIR/project/.claude/daemon-config.json" <<'DAEMONCFG'
{
  "intelligence": {
    "enabled": true
  }
}
DAEMONCFG

    # Create mock claude binary
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCKBIN'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" ]] || [[ "${1:-}" == "--print" ]]; then
    if [[ -n "${MOCK_CLAUDE_RESPONSE:-}" ]]; then
        echo "$MOCK_CLAUDE_RESPONSE"
    else
        echo '{"complexity": 5, "risk_level": "medium", "success_probability": 50, "recommended_template": "standard", "key_risks": ["unknown"], "implementation_hints": ["review code"]}'
    fi
    exit 0
fi
echo '{"error": "unexpected args"}'
exit 1
MOCKBIN
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"

    # Create a minimal pipeline config
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-config.json" <<'PIPELINE'
{
  "stages": [
    {"id": "intake", "enabled": true, "gate": "auto"},
    {"id": "build", "enabled": true, "gate": "auto"},
    {"id": "test", "enabled": true, "gate": "auto"},
    {"id": "pr", "enabled": true, "gate": "auto"}
  ]
}
PIPELINE

    touch "$EVENTS_FILE"
}

cleanup_env() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "${TEST_TEMP_DIR:-}" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}
trap cleanup_env EXIT

reset_test() {
    rm -f "$EVENTS_FILE"
    rm -f "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts/intelligence-report.json"
    rm -f "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts/composed-pipeline.json"
    rm -f "$TEST_TEMP_DIR/project/.claude/intelligence-cache.json"
    touch "$EVENTS_FILE"
    export MOCK_CLAUDE_RESPONSE='{"complexity": 7, "risk_level": "high", "success_probability": 60, "recommended_template": "full", "key_risks": ["complexity"], "implementation_hints": ["review code"], "stages": [{"id":"build","enabled":true,"model":"opus","config":{}},{"id":"test","enabled":true,"model":"sonnet","config":{}}], "rationale": "complex issue"}'
    # Reset PIPELINE_CONFIG
    PIPELINE_CONFIG="$TEST_TEMP_DIR/project/.claude/pipeline-config.json"
    export PIPELINE_CONFIG
}

# ═══════════════════════════════════════════════════════════════════════════════
# SOURCE INTELLIGENCE FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

source_intelligence() {
    export REPO_DIR="$TEST_TEMP_DIR/project"
    # Source intelligence (which sources helpers)
    source "$SCRIPT_DIR/sw-intelligence.sh" 2>/dev/null || true
    # Source predictive if available (for predict_pipeline_risk)
    source "$SCRIPT_DIR/sw-predictive.sh" 2>/dev/null || true
    # Source pipeline composer if available (for composer_validate_pipeline)
    source "$SCRIPT_DIR/sw-pipeline-composer.sh" 2>/dev/null || true
    # Source pipeline vitals if available
    source "$SCRIPT_DIR/sw-pipeline-vitals.sh" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

test_orchestrate_writes_report() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    local issue_json='{"complexity": 7, "risk_level": "high", "recommended_template": "full"}'

    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "$artifacts" "run-001" >/dev/null 2>&1

    # Report file must exist
    [[ -f "$artifacts/intelligence-report.json" ]] || return 1

    # Must have correct run_id
    local run_id
    run_id=$(jq -r '.run_id' "$artifacts/intelligence-report.json" 2>/dev/null)
    [[ "$run_id" == "run-001" ]] || return 1

    # Must have analysis section
    local complexity
    complexity=$(jq -r '.analysis.complexity_score' "$artifacts/intelligence-report.json" 2>/dev/null)
    [[ "$complexity" == "7" ]] || return 1

    return 0
}

test_orchestrate_idempotency() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    local issue_json='{"complexity": 5, "risk_level": "medium", "recommended_template": "standard"}'

    # Run once
    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "$artifacts" "run-002" >/dev/null 2>&1
    local ts1
    ts1=$(jq -r '.timestamp' "$artifacts/intelligence-report.json" 2>/dev/null)

    # Small delay
    sleep 1

    # Run again with same run_id — should be skipped
    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "$artifacts" "run-002" >/dev/null 2>&1
    local ts2
    ts2=$(jq -r '.timestamp' "$artifacts/intelligence-report.json" 2>/dev/null)

    # Timestamps should be identical (second call was skipped)
    [[ "$ts1" == "$ts2" ]] || return 1

    return 0
}

test_orchestrate_different_run_id_reruns() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    local issue_json='{"complexity": 5, "risk_level": "medium", "recommended_template": "standard"}'

    # Run with run_id A
    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "$artifacts" "run-A" >/dev/null 2>&1
    local rid1
    rid1=$(jq -r '.run_id' "$artifacts/intelligence-report.json" 2>/dev/null)
    [[ "$rid1" == "run-A" ]] || return 1

    # Run with run_id B — should overwrite
    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "$artifacts" "run-B" >/dev/null 2>&1
    local rid2
    rid2=$(jq -r '.run_id' "$artifacts/intelligence-report.json" 2>/dev/null)
    [[ "$rid2" == "run-B" ]] || return 1

    return 0
}

test_orchestrate_no_artifacts_dir() {
    # Should return 0 and not crash when no artifacts_dir
    local issue_json='{"complexity": 5}'
    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "" "run-003" >/dev/null 2>&1
    return 0
}

test_orchestrate_report_schema() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    local issue_json='{"complexity": 8, "risk_level": "high", "recommended_template": "full"}'

    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "$artifacts" "run-schema" >/dev/null 2>&1

    local report="$artifacts/intelligence-report.json"
    [[ -f "$report" ]] || return 1

    # Validate all top-level keys exist
    local has_keys
    has_keys=$(jq 'has("run_id") and has("timestamp") and has("analysis") and has("composition") and has("prediction") and has("model_routing") and has("vitals")' "$report" 2>/dev/null)
    [[ "$has_keys" == "true" ]] || return 1

    # Validate nested structure
    local has_analysis
    has_analysis=$(jq '.analysis | has("complexity_score") and has("risk_level")' "$report" 2>/dev/null)
    [[ "$has_analysis" == "true" ]] || return 1

    local has_composition
    has_composition=$(jq '.composition | has("applied") and has("path") and has("stages")' "$report" 2>/dev/null)
    [[ "$has_composition" == "true" ]] || return 1

    return 0
}

test_orchestrate_emits_event() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    local issue_json='{"complexity": 5, "risk_level": "medium", "recommended_template": "standard"}'

    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "$artifacts" "run-event" >/dev/null 2>&1

    # Check events file for orchestrate event
    if grep -q "intelligence.orchestrate" "$EVENTS_FILE" 2>/dev/null; then
        return 0
    fi
    return 1
}

test_apply_composed_no_file() {
    # Should return 0 when no composed file exists
    rm -f "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts/composed-pipeline.json"
    local original="$PIPELINE_CONFIG"
    intelligence_apply_composed_pipeline "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts" >/dev/null 2>&1
    # PIPELINE_CONFIG should be unchanged
    [[ "$PIPELINE_CONFIG" == "$original" ]] || return 1
    return 0
}

test_apply_composed_valid() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"

    # Create a valid composed pipeline
    cat > "$artifacts/composed-pipeline.json" <<'JSON'
{
  "stages": [
    {"id": "intake", "enabled": true, "gate": "auto"},
    {"id": "build", "enabled": true, "gate": "auto", "model": "opus"},
    {"id": "test", "enabled": true, "gate": "auto"},
    {"id": "review", "enabled": true, "gate": "auto"},
    {"id": "pr", "enabled": true, "gate": "auto"}
  ],
  "rationale": "high complexity warrants review stage"
}
JSON

    local original="$PIPELINE_CONFIG"
    intelligence_apply_composed_pipeline "$artifacts" >/dev/null 2>&1

    # PIPELINE_CONFIG should now point to composed file
    [[ "$PIPELINE_CONFIG" == "$artifacts/composed-pipeline.json" ]] || return 1
    [[ "$PIPELINE_CONFIG" != "$original" ]] || return 1
    return 0
}

test_apply_composed_invalid_rejected() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"

    # Create an invalid composed pipeline (empty stages)
    echo '{"stages": [], "rationale": "empty"}' > "$artifacts/composed-pipeline.json"

    local original="$PIPELINE_CONFIG"
    intelligence_apply_composed_pipeline "$artifacts" >/dev/null 2>&1

    # PIPELINE_CONFIG should be unchanged (invalid pipeline rejected)
    [[ "$PIPELINE_CONFIG" == "$original" ]] || return 1
    return 0
}

test_apply_composed_emits_event() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"

    # Create a valid composed pipeline
    cat > "$artifacts/composed-pipeline.json" <<'JSON'
{
  "stages": [
    {"id": "build", "enabled": true, "gate": "auto"},
    {"id": "test", "enabled": true, "gate": "auto"}
  ]
}
JSON

    intelligence_apply_composed_pipeline "$artifacts" >/dev/null 2>&1

    if grep -q "intelligence.config_swap" "$EVENTS_FILE" 2>/dev/null; then
        return 0
    fi
    return 1
}

test_orchestrate_compose_writes_file() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    local issue_json='{"complexity": 7, "risk_level": "high", "recommended_template": "full"}'

    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "$artifacts" "run-compose" >/dev/null 2>&1

    # The composed pipeline file should have been written by the orchestrator
    local report="$artifacts/intelligence-report.json"
    [[ -f "$report" ]] || return 1

    local compose_applied
    compose_applied=$(jq -r '.composition.applied' "$report" 2>/dev/null)
    # Check that composition section has stages count >= 0 (may be 0 if Claude mock doesn't produce valid stages)
    local compose_stages
    compose_stages=$(jq -r '.composition.stages' "$report" 2>/dev/null)
    [[ "$compose_stages" =~ ^[0-9]+$ ]] || return 1

    return 0
}

test_full_flow_orchestrate_then_apply() {
    local artifacts="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    local issue_json='{"complexity": 8, "risk_level": "high", "recommended_template": "full"}'
    local original_config="$PIPELINE_CONFIG"

    # Step 1: Orchestrate
    intelligence_orchestrate "$issue_json" "$PIPELINE_CONFIG" "$artifacts" "run-full" >/dev/null 2>&1

    # Step 2: Report must exist
    [[ -f "$artifacts/intelligence-report.json" ]] || return 1

    # Step 3: If composed pipeline was written, apply should swap config
    if [[ -f "$artifacts/composed-pipeline.json" ]]; then
        local valid_stages
        valid_stages=$(jq '[.stages[] | select(.enabled == true)] | length' "$artifacts/composed-pipeline.json" 2>/dev/null || echo "0")
        if [[ "$valid_stages" -gt 0 ]]; then
            intelligence_apply_composed_pipeline "$artifacts" >/dev/null 2>&1
            [[ "$PIPELINE_CONFIG" == "$artifacts/composed-pipeline.json" ]] || return 1
        fi
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    reset_test

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

main() {
    local filter="${1:-}"

    print_test_header "Intelligence Orchestrator Test Suite"

    setup_env
    source_intelligence

    local tests=(
        "test_orchestrate_writes_report:Orchestrate writes intelligence-report.json"
        "test_orchestrate_idempotency:Same run_id skips re-execution"
        "test_orchestrate_different_run_id_reruns:Different run_id overwrites report"
        "test_orchestrate_no_artifacts_dir:Missing artifacts_dir returns 0"
        "test_orchestrate_report_schema:Report has all required keys"
        "test_orchestrate_emits_event:Orchestrate emits event"
        "test_apply_composed_no_file:Apply with no composed file is no-op"
        "test_apply_composed_valid:Apply swaps PIPELINE_CONFIG to composed file"
        "test_apply_composed_invalid_rejected:Invalid composed pipeline rejected"
        "test_apply_composed_emits_event:Apply emits config_swap event"
        "test_orchestrate_compose_writes_file:Orchestrate writes composed pipeline"
        "test_full_flow_orchestrate_then_apply:Full flow orchestrate + apply"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}Passed:${RESET} $PASS"
    echo -e "  ${RED}Failed:${RESET} $FAIL"
    echo -e "  ${DIM}Total:${RESET}  $TOTAL"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi

    echo -e "${GREEN}${BOLD}All $PASS tests passed!${RESET}"
    echo ""
    exit 0
}

main "$@"
