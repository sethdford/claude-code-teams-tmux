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

print_test_results
