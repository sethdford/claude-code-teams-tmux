#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline DAG — Test Suite                                      ║
# ║  Validates default-deps, cycle detection, missing-dep errors, and         ║
# ║  topological layering for the parallel stage execution engine.            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

DAG_LIB="$SCRIPT_DIR/lib/pipeline-dag.sh"

# Source the pure library so functions are callable directly.
# shellcheck disable=SC1090
source "$DAG_LIB"

print_test_header "Pipeline DAG Library Test Suite"

# ─────────────────────────────────────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────────────────────────────────────
DIAMOND='{"stages":[
  {"id":"A","enabled":true,"depends_on":[]},
  {"id":"B","enabled":true,"depends_on":["A"]},
  {"id":"C","enabled":true,"depends_on":["A"]},
  {"id":"D","enabled":true,"depends_on":["B","C"]}]}'

LINEAR_NODEPS='{"stages":[
  {"id":"intake","enabled":true},
  {"id":"plan","enabled":true},
  {"id":"build","enabled":true}]}'

MIXED='{"stages":[
  {"id":"intake","enabled":true},
  {"id":"plan","enabled":true},
  {"id":"review","enabled":true,"depends_on":["plan"]},
  {"id":"spec_verification","enabled":true,"depends_on":["plan"]},
  {"id":"off","enabled":false},
  {"id":"pr","enabled":true,"depends_on":["review","spec_verification"]}]}'

CYCLE='{"stages":[
  {"id":"A","enabled":true,"depends_on":["B"]},
  {"id":"B","enabled":true,"depends_on":["A"]}]}'

CYCLE3='{"stages":[
  {"id":"A","enabled":true,"depends_on":["C"]},
  {"id":"B","enabled":true,"depends_on":["A"]},
  {"id":"C","enabled":true,"depends_on":["B"]}]}'

MISSING='{"stages":[
  {"id":"A","enabled":true,"depends_on":["Z"]}]}'

DEP_ON_DISABLED='{"stages":[
  {"id":"A","enabled":false},
  {"id":"B","enabled":true,"depends_on":["A"]}]}'

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "dag_compute_layers — topological layering"
# ─────────────────────────────────────────────────────────────────────────────

layers=$(dag_compute_layers "$DIAMOND")
expected=$'A\nB C\nD'
assert_eq "diamond A->{B,C}->D yields 3 layers (A | B C | D)" "$expected" "$layers"

# Within-layer order preserves template order (B before C, not C before B).
layer1=$(echo "$layers" | sed -n '2p')
assert_eq "within-layer order is deterministic (template order B C)" "B C" "$layer1"

# A wide fan-out: 3 independent stages after a root all share one layer.
WIDE='{"stages":[
  {"id":"root","enabled":true,"depends_on":[]},
  {"id":"x","enabled":true,"depends_on":["root"]},
  {"id":"y","enabled":true,"depends_on":["root"]},
  {"id":"z","enabled":true,"depends_on":["root"]}]}'
wide_layers=$(dag_compute_layers "$WIDE")
assert_eq "three independent stages collapse into one parallel layer" \
    $'root\nx y z' "$wide_layers"

# Single stage → single layer.
single=$(dag_compute_layers '{"stages":[{"id":"solo","enabled":true,"depends_on":[]}]}')
assert_eq "single enabled stage yields one layer" "solo" "$single"

# Disabled stages are excluded from layers entirely.
mixed_layers=$(dag_compute_layers "$(dag_default_depends_on "$MIXED")")
assert_contains "disabled stage 'off' absent from layers" "$mixed_layers" "review spec_verification"
if echo "$mixed_layers" | grep -qw "off"; then
    assert_fail "disabled stage must not appear in any layer"
else
    assert_pass "disabled stage must not appear in any layer"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "dag_default_depends_on — linear backward-compatible fallback"
# ─────────────────────────────────────────────────────────────────────────────

defaulted=$(dag_default_depends_on "$LINEAR_NODEPS")
intake_dep=$(echo "$defaulted" | jq -c '.stages[] | select(.id=="intake") | .depends_on')
plan_dep=$(echo "$defaulted" | jq -c '.stages[] | select(.id=="plan") | .depends_on')
build_dep=$(echo "$defaulted" | jq -c '.stages[] | select(.id=="build") | .depends_on')
assert_eq "first enabled stage defaults to empty deps" "[]" "$intake_dep"
assert_eq "second stage defaults to dep on first" '["intake"]' "$plan_dep"
assert_eq "third stage defaults to dep on second" '["plan"]' "$build_dep"

# Linear default ⇒ every stage is its own layer (sequential parity).
linear_layers=$(dag_compute_layers "$defaulted")
assert_eq "no-deps template layers strictly sequentially" $'intake\nplan\nbuild' "$linear_layers"

# Explicit depends_on is preserved (not overwritten by the default pass).
preserved=$(dag_default_depends_on "$MIXED")
review_dep=$(echo "$preserved" | jq -c '.stages[] | select(.id=="review") | .depends_on')
assert_eq "explicit depends_on preserved through default pass" '["plan"]' "$review_dep"

# An explicit empty depends_on ([]) is honored as a root, not re-linearized.
ROOTY='{"stages":[
  {"id":"a","enabled":true},
  {"id":"b","enabled":true,"depends_on":[]}]}'
rooty=$(dag_default_depends_on "$ROOTY")
b_dep=$(echo "$rooty" | jq -c '.stages[] | select(.id=="b") | .depends_on')
assert_eq "explicit empty depends_on stays a root" "[]" "$b_dep"

# Disabled stages are never given a depends_on key.
disabled_passthrough=$(dag_default_depends_on "$DEP_ON_DISABLED")
has_key=$(echo "$disabled_passthrough" | jq '.stages[] | select(.id=="A") | has("depends_on")')
assert_eq "disabled stage left untouched by default pass" "false" "$has_key"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "dag_validate_acyclic — error boundaries"
# ─────────────────────────────────────────────────────────────────────────────

if dag_validate_acyclic "$DIAMOND" 2>/dev/null; then
    assert_pass "valid DAG passes validation"
else
    assert_fail "valid DAG passes validation"
fi

# Direct 2-cycle.
err=$(dag_validate_acyclic "$CYCLE" 2>&1) && rc=0 || rc=$?
assert_eq "two-node cycle is rejected (exit 1)" "1" "$rc"
assert_contains "cycle error names E_DAG_CYCLE" "$err" "E_DAG_CYCLE"

# Transitive 3-cycle A->C->B->A.
err3=$(dag_validate_acyclic "$CYCLE3" 2>&1) && rc3=0 || rc3=$?
assert_eq "transitive 3-node cycle is rejected" "1" "$rc3"
assert_contains "3-cycle reports the offending stage set" "$err3" "E_DAG_CYCLE"

# Missing dependency target.
errm=$(dag_validate_acyclic "$MISSING" 2>&1) && rcm=0 || rcm=$?
assert_eq "missing dep target is rejected" "1" "$rcm"
assert_contains "missing dep error names E_DAG_MISSING_DEP" "$errm" "E_DAG_MISSING_DEP"
assert_contains "missing dep error shows the edge" "$errm" "A -> Z"

# Dependency on a disabled stage is treated as missing.
errd=$(dag_validate_acyclic "$DEP_ON_DISABLED" 2>&1) && rcd=0 || rcd=$?
assert_eq "dep on disabled stage is rejected" "1" "$rcd"
assert_contains "disabled-dep error names E_DAG_MISSING_DEP" "$errd" "E_DAG_MISSING_DEP"

# dag_compute_layers fails fast on a cyclic graph (no partial output).
if cyc_layers=$(dag_compute_layers "$CYCLE" 2>/dev/null); then
    assert_fail "dag_compute_layers aborts on cycle" "got output: $cyc_layers"
else
    assert_pass "dag_compute_layers aborts on cycle"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "Determinism — identical output across repeated runs"
# ─────────────────────────────────────────────────────────────────────────────

run1=$(dag_compute_layers "$(dag_default_depends_on "$MIXED")")
deterministic=true
for _ in 1 2 3 4 5; do
    runN=$(dag_compute_layers "$(dag_default_depends_on "$MIXED")")
    [[ "$runN" == "$run1" ]] || deterministic=false
done
if $deterministic; then
    assert_pass "layering is deterministic across 5 repeated runs"
else
    assert_fail "layering is deterministic across 5 repeated runs"
fi

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "CLI entrypoint — debugging subcommands"
# ─────────────────────────────────────────────────────────────────────────────

cli_layers=$(echo "$DIAMOND" | bash "$DAG_LIB" layers)
assert_eq "CLI 'layers' matches function output" "$expected" "$cli_layers"

cli_validate=$(echo "$DIAMOND" | bash "$DAG_LIB" validate 2>/dev/null)
assert_eq "CLI 'validate' prints OK on valid DAG" "OK" "$cli_validate"

echo "$CYCLE" | bash "$DAG_LIB" validate >/dev/null 2>&1 && cli_rc=0 || cli_rc=$?
assert_eq "CLI 'validate' exits non-zero on cycle" "1" "$cli_rc"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "pipeline-parallel — partition (whitelist / gate / mutating)"
# ─────────────────────────────────────────────────────────────────────────────

# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/pipeline-parallel.sh"

PARALLEL_CFG='{"stages":[
  {"id":"review","gate":"auto"},
  {"id":"compound_quality","gate":"auto"},
  {"id":"build","gate":"auto"},
  {"id":"adversarial","gate":"approve"},
  {"id":"deploy","gate":"auto"}]}'
export PIPELINE_CONFIG="$PARALLEL_CFG"

part=$(parallel_partition "review compound_quality build adversarial deploy")
safe_line=$(printf '%s\n' "$part" | sed -n 's/^SAFE://p')
single_line=$(printf '%s\n' "$part" | sed -n 's/^SINGLE://p')
assert_eq "whitelisted read-only stages are parallel-safe" "review compound_quality" "$safe_line"
assert_contains "mutating stage 'build' forced singleton" "$single_line" "build"
assert_contains "mutating stage 'deploy' forced singleton" "$single_line" "deploy"
assert_contains "gate:approve stage forced singleton even if whitelisted" "$single_line" "adversarial"

if parallel_is_safe "review"; then assert_pass "parallel_is_safe true for whitelisted review"
else assert_fail "parallel_is_safe true for whitelisted review"; fi
if parallel_is_safe "build"; then assert_fail "parallel_is_safe false for mutating build"
else assert_pass "parallel_is_safe false for mutating build"; fi
if parallel_is_safe "test"; then assert_fail "build/test never parallelize (test singleton)"
else assert_pass "build/test never parallelize (test singleton)"; fi
if parallel_is_safe "plan"; then assert_fail "non-whitelisted stage is not safe"
else assert_pass "non-whitelisted stage is not safe"; fi

# Partition preserves template order within each group.
ordered=$(parallel_partition "compound_quality review" | sed -n 's/^SAFE://p')
assert_eq "partition preserves input order within safe group" "compound_quality review" "$ordered"

# ─────────────────────────────────────────────────────────────────────────────
print_test_section "pipeline-parallel — run_layer (concurrency / failure / no orphans)"
# ─────────────────────────────────────────────────────────────────────────────

PARALLEL_LOG_DIR="$(mktemp -d)"
export PARALLEL_LOG_DIR
_mock_stage() { sleep 0.3; echo "ran $1"; [[ "$1" == "boom" ]] && return 9; return 0; }
export PARALLEL_STAGE_RUNNER=_mock_stage

# Concurrency: 3 stages @0.3s under cap 3 must finish well under the serial 0.9s.
export SW_PARALLEL_MAX_CONCURRENCY=3
_t0=$(date +%s%N)
parallel_run_layer "a b c" && _rc=0 || _rc=$?
_par_ms=$(( ($(date +%s%N) - _t0) / 1000000 ))
assert_eq "run_layer returns 0 when all stages succeed" "0" "$_rc"
if [[ $_par_ms -lt 700 ]]; then assert_pass "3 stages run concurrently (${_par_ms}ms < 700ms)"
else assert_fail "3 stages run concurrently (${_par_ms}ms not < 700ms)"; fi

# Concurrency cap honored: cap 1 serializes (2 stages ≥ 0.6s).
export SW_PARALLEL_MAX_CONCURRENCY=1
_t0=$(date +%s%N)
parallel_run_layer "a b" && _rc=0 || _rc=$?
_ser_ms=$(( ($(date +%s%N) - _t0) / 1000000 ))
if [[ $_ser_ms -ge 550 ]]; then assert_pass "concurrency cap=1 serializes (${_ser_ms}ms >= 550ms)"
else assert_fail "concurrency cap=1 serializes (${_ser_ms}ms not >= 550ms)"; fi
export SW_PARALLEL_MAX_CONCURRENCY=3

# Failure propagation + first-failure capture.
parallel_run_layer "a boom c" && _rc=0 || _rc=$?
assert_eq "run_layer propagates the failing stage's exit code" "9" "$_rc"
assert_eq "PARALLEL_FAILED_STAGE records the failed stage" "boom" "$PARALLEL_FAILED_STAGE"

# No orphan PIDs after a failed layer.
_orphans=$(jobs -p | wc -l | tr -d ' ')
assert_eq "no orphan PIDs after failed layer (all siblings waited)" "0" "$_orphans"

# Deterministic, non-interleaved merge in the requested order.
merged=$(parallel_merge_logs "c a")
assert_contains "merged logs include per-stage header" "$merged" "stage: c"
first_stage=$(printf '%s\n' "$merged" | sed -n 's/^───── stage: \(.*\) ─────/\1/p' | head -1)
assert_eq "merge order follows requested id order, not completion" "c" "$first_stage"

rm -rf "$PARALLEL_LOG_DIR"

print_test_results
