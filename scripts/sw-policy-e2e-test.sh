#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright policy e2e test — Verify config/policy.json is honored     ║
# ║  Pipeline thresholds · Daemon defaults · Policy get · Schema          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"



assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}${BOLD}✓${RESET} $label"
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$label")
        echo -e "  ${RED}${BOLD}✗${RESET} $label"
        echo -e "    ${DIM}expected: $expected${RESET}"
        echo -e "    ${DIM}actual:   $actual${RESET}"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -q "$needle"; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}${BOLD}✓${RESET} $label"
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$label")
        echo -e "  ${RED}${BOLD}✗${RESET} $label"
        echo -e "    ${DIM}output missing: $needle${RESET}"
    fi
}

assert_ge() {
    local label="$1" min="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$actual" -ge "$min" ]]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}${BOLD}✓${RESET} $label"
    else
        FAIL=$((FAIL + 1))
        FAILURES+=("$label")
        echo -e "  ${RED}${BOLD}✗${RESET} $label"
        echo -e "    ${DIM}expected >= $min, got $actual${RESET}"
    fi
}

echo ""
echo -e "  ${CYAN}${BOLD}shipwright policy e2e test${RESET}"
echo -e "  ${DIM}══════════════════════════════════════════${RESET}"

# ═══════════════════════════════════════════════════════════════════════
# Test 1: policy.json is valid JSON
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Policy File Validity${RESET}"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$REPO_DIR/config/policy.json" ]]; then
    if jq empty "$REPO_DIR/config/policy.json" 2>/dev/null; then
        assert_eq "policy.json is valid JSON" "0" "0"
    else
        assert_eq "policy.json is valid JSON" "valid" "invalid"
    fi
else
    assert_eq "policy.json exists" "exists" "missing"
fi

# Test: all required top-level keys present (including new sections)
for key in daemon pipeline quality strategic sweep hygiene recruit loop decision; do
    val=$(jq -r ".$key // \"missing\"" "$REPO_DIR/config/policy.json" 2>/dev/null)
    if [[ "$val" != "missing" && "$val" != "null" ]]; then
        assert_eq "policy has .$key section" "present" "present"
    else
        assert_eq "policy has .$key section" "present" "missing"
    fi
done

# ═══════════════════════════════════════════════════════════════════════
# Test 2: policy_get reads correct values from mock policy
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}policy_get Function${RESET}"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp/config"
cat > "$tmp/config/policy.json" <<'POLICY'
{
  "pipeline": {
    "coverage_threshold_percent": 85,
    "quality_gate_score_threshold": 90,
    "max_iterations_default": 15,
    "max_cycles_convergence_cap": 42
  },
  "daemon": {
    "poll_interval_seconds": 120,
    "health_heartbeat_timeout": 300
  },
  "hygiene": {
    "artifact_age_days": 21
  }
}
POLICY

# Read coverage threshold (expect 85, not default 60)
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".pipeline.coverage_threshold_percent\" \"60\"")
assert_eq "policy_get reads pipeline.coverage_threshold_percent" "85" "$got"

# Read daemon poll interval (expect 120)
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.poll_interval_seconds\" \"60\"")
assert_eq "policy_get reads daemon.poll_interval_seconds" "120" "$got"

# Read hygiene artifact age (expect 21)
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".hygiene.artifact_age_days\" \"7\"")
assert_eq "policy_get reads hygiene.artifact_age_days" "21" "$got"

# Read missing key (expect default)
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".nonexistent.key\" \"fallback_val\"")
assert_eq "policy_get returns default for missing key" "fallback_val" "$got"

# Read with empty policy (expect default)
echo '{}' > "$tmp/config/policy.json"
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".pipeline.coverage_threshold_percent\" \"60\"")
assert_eq "policy_get returns default from empty policy" "60" "$got"

rm -rf "$tmp"

# ═══════════════════════════════════════════════════════════════════════
# Test 3: pipeline-quality.sh reads policy thresholds
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Pipeline Quality Thresholds from Policy${RESET}"

tmp2=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp2/config"
cat > "$tmp2/config/policy.json" <<'POLICY'
{
  "pipeline": {
    "coverage_threshold_percent": 75,
    "quality_gate_score_threshold": 80
  },
  "quality": {
    "coverage_threshold": 75,
    "gate_score_threshold": 80
  }
}
POLICY

# Source pipeline-quality.sh in a subshell with our mock policy
# shellcheck disable=SC2097,SC2098
got_cov=$(REPO_DIR="$tmp2" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  unset _PIPELINE_QUALITY_LOADED POLICY_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/pipeline-quality.sh"
  echo "$PIPELINE_COVERAGE_THRESHOLD"
')
assert_eq "pipeline-quality reads coverage threshold from policy" "75" "$got_cov"

# shellcheck disable=SC2097,SC2098
got_gate=$(REPO_DIR="$tmp2" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  unset _PIPELINE_QUALITY_LOADED POLICY_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/pipeline-quality.sh"
  echo "$PIPELINE_QUALITY_GATE_THRESHOLD"
')
assert_eq "pipeline-quality reads gate threshold from policy" "80" "$got_gate"

# Verify pipeline_quality_min_threshold function
# shellcheck disable=SC2097,SC2098
got_min=$(REPO_DIR="$tmp2" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  unset _PIPELINE_QUALITY_LOADED POLICY_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/pipeline-quality.sh"
  pipeline_quality_min_threshold
')
assert_eq "pipeline_quality_min_threshold returns policy value" "80" "$got_min"

rm -rf "$tmp2"

# ═══════════════════════════════════════════════════════════════════════
# Test 4: daemon policy_get integration (poll interval, stage timeouts)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Daemon Policy Integration${RESET}"

tmp3=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp3/config"
cat > "$tmp3/config/policy.json" <<'POLICY'
{
  "daemon": {
    "poll_interval_seconds": 45,
    "health_heartbeat_timeout": 200,
    "stage_timeouts": {
      "build": 600,
      "test": 300
    },
    "auto_scale_interval_cycles": 3,
    "optimize_interval_cycles": 7,
    "stale_reaper_interval_cycles": 8
  }
}
POLICY

# poll interval
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp3" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.poll_interval_seconds\" \"60\"")
assert_eq "daemon poll_interval from policy" "45" "$got"

# heartbeat timeout
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp3" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.health_heartbeat_timeout\" \"120\"")
assert_eq "daemon heartbeat_timeout from policy" "200" "$got"

# stage timeout for build
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp3" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.stage_timeouts.build\" \"300\"")
assert_eq "daemon stage_timeouts.build from policy" "600" "$got"

# auto_scale_interval from policy
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp3" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".daemon.auto_scale_interval_cycles\" \"5\"")
assert_eq "daemon auto_scale_interval from policy" "3" "$got"

rm -rf "$tmp3"

# ═══════════════════════════════════════════════════════════════════════
# Test 5: real policy.json values match expectations
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Real Policy Values Sanity${RESET}"

# Verify real config/policy.json has sane values
real_poll=$(jq -r '.daemon.poll_interval_seconds' "$REPO_DIR/config/policy.json")
assert_ge "daemon.poll_interval_seconds >= 10" "10" "$real_poll"

real_cov=$(jq -r '.pipeline.coverage_threshold_percent' "$REPO_DIR/config/policy.json")
assert_ge "pipeline.coverage_threshold >= 1" "1" "$real_cov"

real_gate=$(jq -r '.pipeline.quality_gate_score_threshold' "$REPO_DIR/config/policy.json")
assert_ge "pipeline.quality_gate_score >= 1" "1" "$real_gate"

real_max_iter=$(jq -r '.pipeline.max_iterations_default' "$REPO_DIR/config/policy.json")
assert_ge "pipeline.max_iterations_default >= 1" "1" "$real_max_iter"

real_strat=$(jq -r '.strategic.max_issues_per_cycle' "$REPO_DIR/config/policy.json")
assert_ge "strategic.max_issues_per_cycle >= 1" "1" "$real_strat"

# ═══════════════════════════════════════════════════════════════════════
# Test 6: policy_get with HOME-based fallback
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}HOME-Based Policy Fallback${RESET}"

tmp4=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp4/home/.shipwright"
cat > "$tmp4/home/.shipwright/policy.json" <<'POLICY'
{"hygiene":{"artifact_age_days":30}}
POLICY
# No config/policy.json in REPO_DIR — should fall back to HOME
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$tmp4/norepo" HOME="$tmp4/home" SCRIPT_DIR="$SCRIPT_DIR" bash -c "source \"$SCRIPT_DIR/lib/policy.sh\"; policy_get \".hygiene.artifact_age_days\" \"7\"")
assert_eq "policy_get falls back to HOME policy.json" "30" "$got"

rm -rf "$tmp4"

# ═══════════════════════════════════════════════════════════════════════
# Test 7: policy_validate passes on valid policy
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}policy_validate Function${RESET}"

tmp5=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$REPO_DIR" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  unset POLICY_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/policy.sh"
  policy_validate "'"$REPO_DIR"'/config/policy.json" 2>&1
  echo "EXIT:$?"
')
exit_code=$(echo "$got" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "policy_validate passes on real policy.json" "0" "${exit_code:-1}"

# Test: policy_validate catches out-of-range value
cat > "$tmp5/bad-policy.json" <<'POLICY'
{
  "version": "2",
  "daemon": {"poll_interval_seconds": -1},
  "pipeline": {"coverage_threshold_percent": 200},
  "quality": {"coverage_threshold": 50}
}
POLICY

# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$REPO_DIR" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  unset POLICY_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/policy.sh"
  output=$(policy_validate "'"$tmp5"'/bad-policy.json" 2>&1)
  rc=$?
  echo "$output"
  echo "EXIT:$rc"
')
exit_code=$(echo "$got" | grep "EXIT:" | sed 's/EXIT://')
assert_eq "policy_validate fails on bad values" "2" "${exit_code:-0}"
assert_contains "policy_validate reports poll_interval violation" "poll_interval_seconds" "$got"
assert_contains "policy_validate reports coverage violation" "coverage_threshold_percent" "$got"

# Test: policy_validate catches missing sections
cat > "$tmp5/missing-policy.json" <<'POLICY'
{"version": "2"}
POLICY

# shellcheck disable=SC2097,SC2098
got=$(REPO_DIR="$REPO_DIR" SCRIPT_DIR="$SCRIPT_DIR" bash -c '
  unset POLICY_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/policy.sh"
  output=$(policy_validate "'"$tmp5"'/missing-policy.json" 2>&1)
  rc=$?
  echo "$output"
  echo "EXIT:$rc"
')
exit_code=$(echo "$got" | grep "EXIT:" | sed 's/EXIT://')
if [[ "${exit_code:-0}" -gt 0 ]]; then
    assert_eq "policy_validate fails on missing sections" "fail" "fail"
else
    assert_eq "policy_validate fails on missing sections" "fail" "pass"
fi
assert_contains "policy_validate reports missing daemon" "missing .daemon" "$got"

rm -rf "$tmp5"

# ═══════════════════════════════════════════════════════════════════════
# Test 8: config.sh override precedence chain
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Override Precedence Chain${RESET}"

tmp6=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp6/config" "$tmp6/.claude"

# Base policy: loop.max_iterations = 20
cat > "$tmp6/config/policy.json" <<'POLICY'
{"loop": {"max_iterations": 20}, "daemon": {}, "pipeline": {}, "quality": {}}
POLICY

# Override: loop.max_iterations = 30
cat > "$tmp6/.claude/policy-overrides.json" <<'OVERRIDE'
{"loop": {"max_iterations": 30}}
OVERRIDE

# Defaults
cat > "$tmp6/config/defaults.json" <<'DEFAULTS'
{"loop": {"max_iterations": 15}}
DEFAULTS

# Test: override wins over base policy
# shellcheck disable=SC2097,SC2098
got=$(cd "$tmp6" && bash -c '
  unset _SW_CONFIG_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/config.sh"
  _config_get_int "loop.max_iterations" 10
')
assert_eq "policy-overrides.json wins over policy.json" "30" "$got"

# Test: env var wins over everything
# shellcheck disable=SC2097,SC2098
got=$(cd "$tmp6" && SHIPWRIGHT_LOOP_MAX_ITERATIONS=50 bash -c '
  unset _SW_CONFIG_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/config.sh"
  _config_get_int "loop.max_iterations" 10
')
assert_eq "env var wins over all config files" "50" "$got"

# Test: without override file, base policy wins
rm "$tmp6/.claude/policy-overrides.json"
# shellcheck disable=SC2097,SC2098
got=$(cd "$tmp6" && bash -c '
  unset _SW_CONFIG_LOADED 2>/dev/null
  source "'"$SCRIPT_DIR"'/lib/config.sh"
  _config_get_int "loop.max_iterations" 10
')
assert_eq "base policy used when no overrides" "20" "$got"

rm -rf "$tmp6"

# ═══════════════════════════════════════════════════════════════════════
# Test 9: loop section values in real policy.json
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Loop Section Values${RESET}"

real_max_iter=$(jq -r '.loop.max_iterations // "missing"' "$REPO_DIR/config/policy.json")
assert_eq "loop.max_iterations = 20" "20" "$real_max_iter"

real_ext_size=$(jq -r '.loop.extension_size // "missing"' "$REPO_DIR/config/policy.json")
assert_eq "loop.extension_size = 5" "5" "$real_ext_size"

real_cb_thresh=$(jq -r '.loop.circuit_breaker_threshold // "missing"' "$REPO_DIR/config/policy.json")
assert_eq "loop.circuit_breaker_threshold = 3" "3" "$real_cb_thresh"

real_ctx_budget=$(jq -r '.loop.context_budget_chars // "missing"' "$REPO_DIR/config/policy.json")
assert_eq "loop.context_budget_chars = 200000" "200000" "$real_ctx_budget"

real_test_timeout=$(jq -r '.loop.test_timeout // "missing"' "$REPO_DIR/config/policy.json")
assert_eq "loop.test_timeout = 900" "900" "$real_test_timeout"

# ═══════════════════════════════════════════════════════════════════════
# Test 10: schema has loop and decision sections
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Schema Completeness${RESET}"

schema_keys=$(jq -r '.properties | keys[]' "$REPO_DIR/config/policy.schema.json" 2>/dev/null)
assert_contains "schema defines loop section" "loop" "$schema_keys"
assert_contains "schema defines decision section" "decision" "$schema_keys"
assert_contains "schema defines daemon section" "daemon" "$schema_keys"

# Verify loop schema has key properties
loop_props=$(jq -r '.properties.loop.properties | keys[]' "$REPO_DIR/config/policy.schema.json" 2>/dev/null)
assert_contains "loop schema has max_iterations" "max_iterations" "$loop_props"
assert_contains "loop schema has circuit_breaker_threshold" "circuit_breaker_threshold" "$loop_props"
assert_contains "loop schema has context_budget_chars" "context_budget_chars" "$loop_props"

# Verify daemon schema has patrol sub-object
patrol_props=$(jq -r '.properties.daemon.properties.patrol.properties | keys[]' "$REPO_DIR/config/policy.schema.json" 2>/dev/null || true)
assert_contains "daemon schema has patrol.interval_seconds" "interval_seconds" "$patrol_props"

# Verify pipeline schema has build_test_retries
pipeline_props=$(jq -r '.properties.pipeline.properties | keys[]' "$REPO_DIR/config/policy.schema.json" 2>/dev/null)
assert_contains "pipeline schema has build_test_retries" "build_test_retries" "$pipeline_props"

# ═══════════════════════════════════════════════════════════════════════
# Test 11: suggest-overrides dry-run with mock adaptive data
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}Adaptive Suggest-Overrides${RESET}"

tmp7=$(mktemp -d "${TMPDIR:-/tmp}/sw-policy-e2e.XXXXXX")
mkdir -p "$tmp7/.shipwright" "$tmp7/.claude"

# Create mock adaptive-models.json with high-confidence data
cat > "$tmp7/.shipwright/adaptive-models.json" <<'MODELS'
{
  "timeout.build": {"value": 450, "sample_count": 25},
  "iterations": {"value": 15, "sample_count": 30},
  "quality_threshold": {"value": 75, "sample_count": 50},
  "timeout.test": {"value": 5, "sample_count": 25}
}
MODELS

# Run suggest-overrides in dry-run mode
# shellcheck disable=SC2097,SC2098
got=$(cd "$tmp7" && HOME="$tmp7" bash -c '
  source "'"$SCRIPT_DIR"'/lib/compat.sh" 2>/dev/null || true
  source "'"$SCRIPT_DIR"'/sw-adaptive.sh" 2>/dev/null || true
  MODELS_FILE="'"$tmp7"'/.shipwright/adaptive-models.json"
  cmd_suggest_overrides --dry-run --min-samples 20 2>&1
' 2>&1 || true)
assert_contains "suggest-overrides reports dry-run" "Dry run" "$got"

# Test rejection of out-of-bounds value (timeout.test = 5, min is 60)
# The value 5 should be rejected as out of bounds for daemon.stage_timeouts.test (min 60)
assert_contains "suggest-overrides rejects out-of-bounds" "Rejected" "$got"

rm -rf "$tmp7"

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${DIM}──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}${FAIL} of ${TOTAL} tests failed${RESET}"
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
    exit 1
else
    echo -e "  ${GREEN}${BOLD}All ${TOTAL} tests passed${RESET}"
fi
