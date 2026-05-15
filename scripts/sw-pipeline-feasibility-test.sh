#!/usr/bin/env bash
# Unit tests for scripts/lib/pipeline-feasibility.sh
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "pipeline-feasibility tests"

setup_test_env "sw-pipeline-feasibility-test"
trap cleanup_test_env EXIT

export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export NO_GITHUB=true
export ISSUE_NUMBER=""
mkdir -p "$ARTIFACTS_DIR"

info()       { :; }
success()    { :; }
warn()       { :; }
error()      { :; }
emit_event() { :; }

source "$SCRIPT_DIR/lib/compat.sh"
_PIPELINE_FEASIBILITY_LOADED=""
source "$SCRIPT_DIR/lib/pipeline-feasibility.sh"

# ─── Heuristics ─────────────────────────────────────────────────────────
print_test_section "heuristics"

result=$(_feas_check_body_length "")
assert_contains "Empty body deducts -25" "$result" "-25"

result=$(_feas_check_body_length "$(printf 'x%.0s' {1..200})")
assert_contains "Long body deducts 0" "$result" "0	"

result=$(_feas_check_conflicting_labels "feature,revert")
assert_contains "feature+revert deducts -25" "$result" "-25"

result=$(_feas_check_conflicting_labels "wontfix")
assert_contains "wontfix deducts -40" "$result" "-40"

result=$(_feas_check_conflicting_labels "bug,enhancement")
assert_contains "Coherent labels: 0 deduction" "$result" "Labels coherent"

result=$(_feas_apply_label_bonuses "hotfix,bug")
assert_contains "hotfix gives +25 bonus" "$result" "+25"

result=$(_feas_check_vagueness_terms "please improve and refactor things")
assert_contains "Multiple vague terms w/o number deducts -10" "$result" "-10"

result=$(_feas_check_vagueness_terms "Reduce p99 latency by 50ms in /api endpoint")
assert_contains "Concrete metric: 0 deduction" "$result" "No unqualified"

result=$(_feas_check_architecture_violation "Use declare -A for the map")
assert_contains "declare -A flagged" "$result" "-15"

result=$(_feas_check_architecture_violation "Add a normal helper function")
assert_contains "Clean body: 0 deduction" "$result" "No architecture"

spec="$TEST_TEMP_DIR/spec-large.json"
files_json=$(jq -n '[range(0;120)] | map(tostring + ".sh")')
echo "{\"affected_files\":$files_json}" > "$spec"
result=$(_feas_check_scope "$spec")
assert_contains "Scope >100 files deducts -30" "$result" "-30"

spec="$TEST_TEMP_DIR/spec-small.json"
echo '{"affected_files":["a.sh","b.sh"]}' > "$spec"
result=$(_feas_check_scope "$spec")
assert_contains "Scope small: 0 deduction" "$result" "Scope ok"

result=$(_feas_check_acceptance_criteria "$TEST_TEMP_DIR/missing.json")
assert_contains "Missing criteria file deducts -15" "$result" "-15"

crit="$TEST_TEMP_DIR/criteria-good.json"
echo '{"criteria":[{"text":"a"},{"text":"b"},{"text":"c"}]}' > "$crit"
result=$(_feas_check_acceptance_criteria "$crit")
assert_contains "3 criteria: 0 deduction" "$result" "3 acceptance criteria"

# ─── Scoring ────────────────────────────────────────────────────────────
print_test_section "feasibility_score"

intake="$ARTIFACTS_DIR/intake.json"
echo '{"goal":"fix","body":"","labels":""}' > "$intake"
score_json=$(feasibility_score "$intake" "")
score=$(echo "$score_json" | jq -r '.score')
verdict=$(echo "$score_json" | jq -r '.verdict')
if [[ "$score" -lt 70 ]]; then assert_pass "Empty body score $score < 70"
else assert_fail "Empty body score $score >= 70"; fi
if [[ "$verdict" == "BLOCK" || "$verdict" == "WARN" || "$verdict" == "PASS" ]]; then
    assert_pass "Verdict is one of {BLOCK,WARN,PASS}: $verdict"
else
    assert_fail "Verdict invalid: $verdict"
fi

body="Add input validation to POST /api/users so an empty email returns HTTP 400 with a JSON error message containing field=email and code=missing_field. Update tests in users.test.js to cover the case."
jq -n --arg b "$body" --arg l "hotfix" \
  '{goal:"add validation", body:$b, labels:$l}' > "$intake"
echo '{"criteria":[{"text":"empty email returns 400"},{"text":"error includes field=email"}]}' > "$ARTIFACTS_DIR/acceptance-criteria.json"
score_json=$(feasibility_score "$intake" "")
verdict=$(echo "$score_json" | jq -r '.verdict')
score=$(echo "$score_json" | jq -r '.score')
assert_eq "Strong issue: verdict=PASS" "PASS" "$verdict"
if [[ "$score" -ge 80 ]]; then assert_pass "Strong issue score $score >= 80"
else assert_fail "Strong issue score $score < 80"; fi

# ─── Gate ───────────────────────────────────────────────────────────────
print_test_section "feasibility_gate"

cleanup_artifacts() {
    rm -f "$ARTIFACTS_DIR"/feasibility*.* "$ARTIFACTS_DIR"/acceptance-criteria.json
}

cleanup_artifacts
echo '{"goal":"fix","body":"","labels":"wontfix"}' > "$ARTIFACTS_DIR/intake.json"
rc=0; feasibility_gate "$ARTIFACTS_DIR" || rc=$?
assert_eq "wontfix issue: gate returns 1" "1" "$rc"
[[ -f "$ARTIFACTS_DIR/feasibility.json"        ]] && assert_pass "feasibility.json written"        || assert_fail "feasibility.json missing"
[[ -f "$ARTIFACTS_DIR/feasibility-report.md"   ]] && assert_pass "feasibility-report.md written"   || assert_fail "report missing"
verdict=$(jq -r '.verdict' "$ARTIFACTS_DIR/feasibility.json")
assert_eq "Verdict in artifact = BLOCK" "BLOCK" "$verdict"

cleanup_artifacts
echo "{\"goal\":\"add\",\"body\":\"$body\",\"labels\":\"hotfix\"}" > "$ARTIFACTS_DIR/intake.json"
echo '{"criteria":[{"text":"a"},{"text":"b"}]}' > "$ARTIFACTS_DIR/acceptance-criteria.json"
rc=0; feasibility_gate "$ARTIFACTS_DIR" || rc=$?
assert_eq "Strong issue: gate returns 0" "0" "$rc"
verdict=$(jq -r '.verdict' "$ARTIFACTS_DIR/feasibility.json")
assert_eq "Verdict in artifact = PASS" "PASS" "$verdict"

cleanup_artifacts
echo '{"goal":"fix","body":"","labels":"wontfix"}' > "$ARTIFACTS_DIR/intake.json"
rc=0; SW_FEASIBILITY_ENABLED=false feasibility_gate "$ARTIFACTS_DIR" || rc=$?
assert_eq "Kill switch: gate returns 0 even on doomed issue" "0" "$rc"
[[ ! -f "$ARTIFACTS_DIR/feasibility.json" ]] && assert_pass "Kill switch wrote no artifact" || assert_fail "Kill switch unexpectedly wrote artifact"

cleanup_artifacts
echo '{"goal":"fix","body":"","labels":"wontfix"}' > "$ARTIFACTS_DIR/intake.json"
rc=0; SW_FEASIBILITY_MIN_SCORE=0 feasibility_gate "$ARTIFACTS_DIR" || rc=$?
assert_eq "Threshold=0 demotes BLOCK to PASS, gate returns 0" "0" "$rc"

cleanup_artifacts
echo '{"goal":"fix","body":"","labels":"wontfix"}' > "$ARTIFACTS_DIR/intake.json"
rc=0; ISSUE_NUMBER=999 NO_GITHUB=true feasibility_gate "$ARTIFACTS_DIR" || rc=$?
assert_eq "NO_GITHUB blocks GH calls but gate still returns 1" "1" "$rc"
[[ -f "$ARTIFACTS_DIR/feasibility.json" ]] && assert_pass "Local artifact written despite NO_GITHUB" || assert_fail "Local artifact missing"

# ─── Report ─────────────────────────────────────────────────────────────
print_test_section "feasibility_report"

out_md="$TEST_TEMP_DIR/report.md"
feasibility_report "$ARTIFACTS_DIR/feasibility.json" "$out_md"
[[ -f "$out_md" ]] && assert_pass "Report markdown written" || assert_fail "Report markdown missing"
grep -q "Pre-Flight Feasibility Report" "$out_md" && assert_pass "Report has title"             || assert_fail "Report missing title"
grep -q "Per-Check Breakdown"             "$out_md" && assert_pass "Report has breakdown section" || assert_fail "Report missing breakdown"

print_test_results
