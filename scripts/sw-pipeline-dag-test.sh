#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline-dag test — Validate dependency DAG resolver         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test-helpers.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/pipeline-dag.sh"

print_test_header "pipeline-dag Tests"

setup_test_env "pipeline-dag"
trap cleanup_test_env EXIT

CFG="$TEST_TEMP_DIR/template.json"

# ─── Test 1: linear chain (no depends_on) ─────────────────────────────────
jq -n '{
  stages: [
    {id:"a", enabled:true, gate:"auto"},
    {id:"b", enabled:true, gate:"auto"},
    {id:"c", enabled:true, gate:"auto"}
  ]
}' > "$CFG"

out=$(dag_waves "$CFG")
assert_eq "no depends_on → one wave containing all enabled stages" "a b c" "$out"

dag_has_depends_on "$CFG" && assert_fail "dag_has_depends_on false on plain template" "" \
    || assert_pass "dag_has_depends_on false on plain template"

# ─── Test 2: simple DAG with parallel siblings ────────────────────────────
jq -n '{
  stages: [
    {id:"intake", enabled:true, gate:"auto"},
    {id:"plan",   enabled:true, gate:"auto", depends_on:["intake"]},
    {id:"design", enabled:true, gate:"auto", depends_on:["intake"]},
    {id:"build",  enabled:true, gate:"auto", depends_on:["plan","design"]}
  ]
}' > "$CFG"

waves=$(dag_waves "$CFG")
w1=$(sed -n '1p' <<< "$waves")
w2=$(sed -n '2p' <<< "$waves")
w3=$(sed -n '3p' <<< "$waves")
assert_eq "wave 1 = intake" "intake" "$w1"
assert_contains "wave 2 contains plan" "$w2" "plan"
assert_contains "wave 2 contains design" "$w2" "design"
assert_eq "wave 3 = build" "build" "$w3"

dag_has_depends_on "$CFG" && assert_pass "dag_has_depends_on true when template has deps" \
    || assert_fail "dag_has_depends_on true when template has deps" ""

# ─── Test 3: cycle detection ──────────────────────────────────────────────
jq -n '{
  stages: [
    {id:"a", enabled:true, gate:"auto", depends_on:["c"]},
    {id:"b", enabled:true, gate:"auto", depends_on:["a"]},
    {id:"c", enabled:true, gate:"auto", depends_on:["b"]}
  ]
}' > "$CFG"

err_output=$(dag_validate "$CFG" 2>&1 || true)
assert_contains "cycle error mentions 'cycle'" "$err_output" "cycle"
assert_contains "cycle error lists node a" "$err_output" "a"

# ─── Test 4: unknown dependency ────────────────────────────────────────────
jq -n '{
  stages: [
    {id:"a", enabled:true, gate:"auto"},
    {id:"b", enabled:true, gate:"auto", depends_on:["nope"]}
  ]
}' > "$CFG"

err_output=$(dag_validate "$CFG" 2>&1 || true)
assert_contains "unknown dep error mentions 'unknown'" "$err_output" "unknown or disabled"
assert_contains "unknown dep error names the missing ref" "$err_output" "nope"

# ─── Test 5: self-dependency rejected ─────────────────────────────────────
jq -n '{
  stages: [
    {id:"a", enabled:true, gate:"auto", depends_on:["a"]}
  ]
}' > "$CFG"

err_output=$(dag_validate "$CFG" 2>&1 || true)
assert_contains "self-dep rejected" "$err_output" "itself"

# ─── Test 6: disabled stages excluded ─────────────────────────────────────
jq -n '{
  stages: [
    {id:"a", enabled:true,  gate:"auto"},
    {id:"b", enabled:false, gate:"auto"},
    {id:"c", enabled:true,  gate:"auto", depends_on:["a"]}
  ]
}' > "$CFG"

out=$(dag_stage_ids "$CFG")
assert_eq "disabled stage filtered" "a
c" "$out"

dag_validate "$CFG" >/dev/null 2>&1 \
    && assert_pass "disabled stage doesn't break validate" \
    || assert_fail "disabled stage doesn't break validate" ""

# ─── Test 7: descendants of a failing stage ───────────────────────────────
jq -n '{
  stages: [
    {id:"intake", enabled:true, gate:"auto"},
    {id:"plan",   enabled:true, gate:"auto", depends_on:["intake"]},
    {id:"design", enabled:true, gate:"auto", depends_on:["intake"]},
    {id:"build",  enabled:true, gate:"auto", depends_on:["plan","design"]},
    {id:"pr",     enabled:true, gate:"auto", depends_on:["build"]}
  ]
}' > "$CFG"

desc=$(dag_descendants "$CFG" "plan" | sort | tr '\n' ' ')
assert_contains "plan's descendants include build" "$desc" "build"
assert_contains "plan's descendants include pr" "$desc" "pr"

print_test_results
