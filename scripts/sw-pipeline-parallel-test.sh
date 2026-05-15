#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline-parallel test — Wave-based parallel executor       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test-helpers.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/pipeline-dag.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/pipeline-parallel.sh"

print_test_header "pipeline-parallel Tests"

setup_test_env "pipeline-parallel"
trap cleanup_test_env EXIT

CFG="$TEST_TEMP_DIR/template.json"
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"

# ─── Test stubs used in lieu of the real run_pipeline machinery ──────────
# Each stage execution writes a timestamped line to events.log so we can
# verify ordering and parallelism.
EVENT_LOG="$ARTIFACTS_DIR/events.log"
: > "$EVENT_LOG"

# When this var is set, stage with that id will fail.
FAIL_STAGE=""

_run_one_stage() {
    local id="$1"
    echo "$(date +%s.%N) start $id" >> "$EVENT_LOG"
    # Tiny sleep to make overlap detectable.
    sleep 0.2
    echo "$(date +%s.%N) end $id" >> "$EVENT_LOG"
    if [[ "$id" == "$FAIL_STAGE" ]]; then
        return 7
    fi
    return 0
}

set_stage_status() { echo "$1=$2" >> "$ARTIFACTS_DIR/status.log"; }
emit_event() { :; }

# ─── Test 1: parallel siblings actually overlap ──────────────────────────
jq -n '{
  stages: [
    {id:"intake", enabled:true, gate:"auto"},
    {id:"plan",   enabled:true, gate:"auto", depends_on:["intake"]},
    {id:"design", enabled:true, gate:"auto", depends_on:["intake"]},
    {id:"build",  enabled:true, gate:"auto", depends_on:["plan","design"]}
  ]
}' > "$CFG"

: > "$EVENT_LOG"
export PIPELINE_PARALLEL_MAX=4
FAIL_STAGE=""
run_pipeline_parallel "$CFG" > /dev/null
rc=$?
assert_eq "parallel run with no failures exits 0" "0" "$rc"

# Verify plan and design overlapped: plan's start should be before design's end.
plan_start=$(awk '$2=="start" && $3=="plan"  {print $1}' "$EVENT_LOG")
design_start=$(awk '$2=="start" && $3=="design" {print $1}' "$EVENT_LOG")
plan_end=$(awk   '$2=="end"   && $3=="plan"  {print $1}' "$EVENT_LOG")
design_end=$(awk '$2=="end"   && $3=="design" {print $1}' "$EVENT_LOG")
overlap=$(awk -v ps="$plan_start" -v pe="$plan_end" -v ds="$design_start" -v de="$design_end" '
    BEGIN { if (ps < de && ds < pe) print "1"; else print "0" }')
assert_eq "plan and design execute concurrently" "1" "$overlap"

# Verify intake ran first.
intake_end=$(awk '$2=="end" && $3=="intake" {print $1}' "$EVENT_LOG")
before=$(awk -v i="$intake_end" -v p="$plan_start" 'BEGIN { print (i <= p) ? "1" : "0" }')
assert_eq "intake completes before plan begins" "1" "$before"

# ─── Test 2: failure marks descendants as upstream_failed ────────────────
: > "$EVENT_LOG"
: > "$ARTIFACTS_DIR/status.log"
FAIL_STAGE="plan"
rc=0
run_pipeline_parallel "$CFG" >/dev/null 2>&1 || rc=$?
assert_eq "failed plan propagates non-zero" "7" "$rc"
status_log=$(cat "$ARTIFACTS_DIR/status.log")
assert_contains "build marked upstream_failed" "$status_log" "build=skipped:upstream_failed"

# ─── Test 3: gate=approve stages run alone (serial within wave) ──────────
jq -n '{
  stages: [
    {id:"intake", enabled:true, gate:"auto"},
    {id:"plan",   enabled:true, gate:"approve", depends_on:["intake"]},
    {id:"design", enabled:true, gate:"auto",    depends_on:["intake"]}
  ]
}' > "$CFG"
: > "$EVENT_LOG"
export SKIP_GATES="false"
FAIL_STAGE=""
# Stub gate prompt out by running with SKIP_GATES off but _run_one_stage doesn't
# actually ask — pipeline-parallel only splits the wave, it doesn't prompt.
run_pipeline_parallel "$CFG" >/dev/null
# In wave 2: plan (approve) and design (auto) — they must NOT overlap.
plan_start=$(awk '$2=="start" && $3=="plan"   {print $1}' "$EVENT_LOG")
plan_end=$(awk   '$2=="end"   && $3=="plan"   {print $1}' "$EVENT_LOG")
design_start=$(awk '$2=="start" && $3=="design" {print $1}' "$EVENT_LOG")
design_end=$(awk   '$2=="end"   && $3=="design" {print $1}' "$EVENT_LOG")
serial=$(awk -v pe="$plan_end" -v ds="$design_start" -v de="$design_end" -v ps="$plan_start" '
    BEGIN { if (pe <= ds || de <= ps) print "1"; else print "0" }')
assert_eq "approve-gated stage does not overlap auto siblings" "1" "$serial"

# ─── Test 4: cycle in template aborts before running ─────────────────────
jq -n '{
  stages: [
    {id:"a", enabled:true, gate:"auto", depends_on:["b"]},
    {id:"b", enabled:true, gate:"auto", depends_on:["a"]}
  ]
}' > "$CFG"
: > "$EVENT_LOG"
rc=0
run_pipeline_parallel "$CFG" >/dev/null 2>&1 || rc=$?
assert_gt "cycle aborts with non-zero exit" "$rc" "0"
assert_eq "cycle abort runs no stages" "" "$(cat "$EVENT_LOG")"

print_test_results
