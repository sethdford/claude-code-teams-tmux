# pipeline-quality.sh — Quality gate thresholds from policy (for pipeline + quality scripts)
# Source from sw-pipeline.sh or sw-quality.sh. Requires SCRIPT_DIR and policy.sh.
[[ -n "${_PIPELINE_QUALITY_LOADED:-}" ]] && return 0
_PIPELINE_QUALITY_LOADED=1

# Policy overrides when config/policy.json exists
[[ -f "${SCRIPT_DIR:-}/lib/policy.sh" ]] && source "${SCRIPT_DIR:-}/lib/policy.sh"
if type policy_get_with_override >/dev/null 2>&1; then
    PIPELINE_COVERAGE_THRESHOLD=$(policy_get_with_override "PIPELINE_COVERAGE_THRESHOLD" ".pipeline.coverage_threshold_percent" "60")
    PIPELINE_QUALITY_GATE_THRESHOLD=$(policy_get_with_override "PIPELINE_QUALITY_GATE_THRESHOLD" ".pipeline.quality_gate_score_threshold" "70")
    QUALITY_COVERAGE_THRESHOLD=$(policy_get_with_override "QUALITY_COVERAGE_THRESHOLD" ".quality.coverage_threshold" "70")
    QUALITY_GATE_SCORE_THRESHOLD=$(policy_get_with_override "QUALITY_GATE_SCORE_THRESHOLD" ".quality.gate_score_threshold" "70")
    QUALITY_WEIGHT_TEST_PASS=$(policy_get_with_override "QUALITY_WEIGHT_TEST_PASS" ".quality.audit_weights.test_pass" "30")
    QUALITY_WEIGHT_COVERAGE=$(policy_get_with_override "QUALITY_WEIGHT_COVERAGE" ".quality.audit_weights.coverage" "20")
    QUALITY_WEIGHT_SECURITY=$(policy_get_with_override "QUALITY_WEIGHT_SECURITY" ".quality.audit_weights.security" "20")
    QUALITY_WEIGHT_ARCHITECTURE=$(policy_get_with_override "QUALITY_WEIGHT_ARCHITECTURE" ".quality.audit_weights.architecture" "15")
    QUALITY_WEIGHT_CORRECTNESS=$(policy_get_with_override "QUALITY_WEIGHT_CORRECTNESS" ".quality.audit_weights.correctness" "15")
elif type policy_get >/dev/null 2>&1; then
    PIPELINE_COVERAGE_THRESHOLD=$(policy_get ".pipeline.coverage_threshold_percent" "60")
    PIPELINE_QUALITY_GATE_THRESHOLD=$(policy_get ".pipeline.quality_gate_score_threshold" "70")
    QUALITY_COVERAGE_THRESHOLD=$(policy_get ".quality.coverage_threshold" "70")
    QUALITY_GATE_SCORE_THRESHOLD=$(policy_get ".quality.gate_score_threshold" "70")
    QUALITY_WEIGHT_TEST_PASS=$(policy_get ".quality.audit_weights.test_pass" "30")
    QUALITY_WEIGHT_COVERAGE=$(policy_get ".quality.audit_weights.coverage" "20")
    QUALITY_WEIGHT_SECURITY=$(policy_get ".quality.audit_weights.security" "20")
    QUALITY_WEIGHT_ARCHITECTURE=$(policy_get ".quality.audit_weights.architecture" "15")
    QUALITY_WEIGHT_CORRECTNESS=$(policy_get ".quality.audit_weights.correctness" "15")
else
    PIPELINE_COVERAGE_THRESHOLD=60
    PIPELINE_QUALITY_GATE_THRESHOLD=70
    QUALITY_COVERAGE_THRESHOLD=70
    QUALITY_GATE_SCORE_THRESHOLD=70
    QUALITY_WEIGHT_TEST_PASS=30
    QUALITY_WEIGHT_COVERAGE=20
    QUALITY_WEIGHT_SECURITY=20
    QUALITY_WEIGHT_ARCHITECTURE=15
    QUALITY_WEIGHT_CORRECTNESS=15
fi

# Minimum quality gate threshold for non-strict mode (floor)
pipeline_quality_min_threshold() {
    echo "${PIPELINE_QUALITY_GATE_THRESHOLD:-70}"
}
