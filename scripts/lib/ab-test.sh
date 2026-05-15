#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   lib/ab-test.sh — Generalized A/B testing primitives
#
#   Experiment-agnostic primitives for randomized assignment and
#   result aggregation across pipeline runs. Each experiment gets
#   its own JSONL results file at $AB_BASE_DIR/<experiment>.jsonl.
#
#   Public functions:
#     ab_assign         <experiment> [ratio]            -> "control"|"treatment"
#     ab_record_assignment <experiment> <pipeline_id> <group>
#     ab_record_result  <experiment> <pipeline_id> <group> <iterations> <cost> <test_failures> <status>
#     ab_report         <experiment>
#     ab_list                                            -> known experiments
#     ab_status         <experiment>                     -> JSON sample-size summary
#     ab_results_file   <experiment>                     -> path to JSONL file
#
#   Source this from any script:
#     source "$SCRIPT_DIR/lib/ab-test.sh"
# ═══════════════════════════════════════════════════════════════════

[[ -n "${_SW_AB_TEST_LOADED:-}" ]] && return 0
_SW_AB_TEST_LOADED=1

AB_BASE_DIR="${AB_BASE_DIR:-${HOME}/.shipwright/abtest}"

# Validate experiment name (alphanumeric, dash, underscore only)
_ab_valid_name() {
    local name="$1"
    [[ -n "$name" ]] && [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# Return path to a given experiment's JSONL results file
ab_results_file() {
    local experiment="$1"
    _ab_valid_name "$experiment" || { echo ""; return 1; }
    echo "${AB_BASE_DIR}/${experiment}.jsonl"
}

# Assign control or treatment for this run based on a ratio in [0,1]
#   $1: experiment name (recorded for traceability)
#   $2: ab_ratio (default 0.2 — 20% control, 80% treatment)
# Returns: "control" or "treatment"
ab_assign() {
    local experiment="$1"
    local ab_ratio="${2:-0.2}"

    _ab_valid_name "$experiment" || return 1

    # Validate ratio is between 0 and 1
    if ! echo "$ab_ratio" | grep -qE '^0(\.[0-9]+)?$|^1(\.0+)?$'; then
        ab_ratio="0.2"
    fi

    local rand=$((RANDOM % 100))
    local threshold
    threshold=$(echo "$ab_ratio * 100" | bc 2>/dev/null || echo "20")
    threshold=${threshold%.*}
    [[ -z "$threshold" ]] && threshold=20

    if [[ "$rand" -lt "$threshold" ]]; then
        echo "control"
    else
        echo "treatment"
    fi
}

# Record assignment event (no JSONL write — just emit_event when available)
#   $1: experiment, $2: pipeline_id, $3: group
ab_record_assignment() {
    local experiment="$1" pipeline_id="$2" group="$3"

    _ab_valid_name "$experiment" || return 1
    [[ -z "$pipeline_id" || -z "$group" ]] && return 1

    if declare -f emit_event >/dev/null 2>&1; then
        local ts
        ts=$(declare -f now_iso >/dev/null && now_iso || date -u +%Y-%m-%dT%H:%M:%SZ)
        emit_event "abtest.assigned" \
            "experiment=$experiment" \
            "pipeline_id=$pipeline_id" \
            "group=$group" \
            "timestamp=$ts"
    fi
    return 0
}

# Record result after pipeline completion (concurrency-safe append)
#   $1: experiment, $2: pipeline_id, $3: group,
#   $4: iterations, $5: cost, $6: test_failures, $7: completion_status
ab_record_result() {
    local experiment="$1" pipeline_id="$2" group="$3"
    local iterations="${4:-0}" cost="${5:-0}" test_failures="${6:-0}"
    local completion_status="${7:-unknown}"

    _ab_valid_name "$experiment" || return 1
    [[ -z "$pipeline_id" || -z "$group" ]] && return 1
    command -v jq >/dev/null 2>&1 || return 1

    local results_file
    results_file=$(ab_results_file "$experiment")
    mkdir -p "$(dirname "$results_file")"

    local ts
    ts=$(declare -f now_iso >/dev/null && now_iso || date -u +%Y-%m-%dT%H:%M:%SZ)

    local result_json
    result_json=$(jq -nc \
        --arg experiment "$experiment" \
        --arg pipeline_id "$pipeline_id" \
        --arg group "$group" \
        --arg timestamp "$ts" \
        --arg iterations "$iterations" \
        --arg cost "$cost" \
        --arg test_failures "$test_failures" \
        --arg completion_status "$completion_status" \
        '{
            experiment: $experiment,
            pipeline_id: $pipeline_id,
            group: $group,
            timestamp: $timestamp,
            iterations: ($iterations | tonumber? // 0),
            cost: ($cost | tonumber? // 0),
            test_failures: ($test_failures | tonumber? // 0),
            completion_status: $completion_status
        }')

    # Atomic append — single `echo >>` is line-atomic on POSIX for <PIPE_BUF lines.
    # Use flock when available for stronger guarantees under heavy concurrency.
    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 200
            printf '%s\n' "$result_json" >> "$results_file"
        ) 200>"${results_file}.lock"
    else
        printf '%s\n' "$result_json" >> "$results_file"
    fi

    if declare -f emit_event >/dev/null 2>&1; then
        emit_event "abtest.result" \
            "experiment=$experiment" \
            "pipeline_id=$pipeline_id" \
            "group=$group" \
            "iterations=$iterations" \
            "cost=$cost" \
            "test_failures=$test_failures" \
            "completion_status=$completion_status"
    fi
    return 0
}

# List known experiments (one per line)
ab_list() {
    [[ -d "$AB_BASE_DIR" ]] || return 0
    local f
    for f in "$AB_BASE_DIR"/*.jsonl; do
        [[ -f "$f" ]] || continue
        local base
        base=$(basename "$f" .jsonl)
        echo "$base"
    done
}

# Emit JSON summary {control_count, treatment_count} for an experiment
ab_status() {
    local experiment="$1"
    _ab_valid_name "$experiment" || return 1
    local f
    f=$(ab_results_file "$experiment")
    local cc=0 tc=0
    if [[ -f "$f" ]]; then
        cc=$(grep -c '"group":"control"' "$f" 2>/dev/null || echo 0)
        tc=$(grep -c '"group":"treatment"' "$f" 2>/dev/null || echo 0)
    fi
    cc=${cc//[^0-9]/}
    tc=${tc//[^0-9]/}
    printf '{"experiment":"%s","control_count":%d,"treatment_count":%d}\n' \
        "$experiment" "${cc:-0}" "${tc:-0}"
}

# Compute per-group aggregate metrics for an experiment via jq
#   $1: experiment, $2: group ("control"|"treatment")
# Emits JSON: {count, avg_iterations, avg_cost, success_rate}
ab_aggregate() {
    local experiment="$1" group="$2"
    _ab_valid_name "$experiment" || return 1
    local f
    f=$(ab_results_file "$experiment")
    [[ -f "$f" ]] || { echo '{"count":0,"avg_iterations":0,"avg_cost":0,"success_rate":0}'; return 0; }
    command -v jq >/dev/null 2>&1 || { echo '{"count":0,"avg_iterations":0,"avg_cost":0,"success_rate":0}'; return 1; }

    grep "\"group\":\"$group\"" "$f" 2>/dev/null | jq -s '
        if length == 0 then
            {count: 0, avg_iterations: 0, avg_cost: 0, success_rate: 0}
        else
            {
                count: length,
                avg_iterations: ([.[].iterations // 0] | add / length | floor),
                avg_cost: ([.[].cost // 0] | add / length | floor),
                success_rate: (([.[] | select(.completion_status == "success")] | length) / length * 100 | floor)
            }
        end
    ' 2>/dev/null || echo '{"count":0,"avg_iterations":0,"avg_cost":0,"success_rate":0}'
}

# Human-readable report comparing control vs treatment for an experiment
ab_report() {
    local experiment="$1"
    _ab_valid_name "$experiment" || { echo "Invalid experiment name" >&2; return 1; }
    local f
    f=$(ab_results_file "$experiment")

    if [[ ! -f "$f" ]]; then
        echo "No A/B test results found for experiment '$experiment' at $f" >&2
        return 1
    fi
    command -v jq >/dev/null 2>&1 || { echo "jq required for A/B report" >&2; return 1; }

    local control_data treatment_data
    control_data=$(ab_aggregate "$experiment" "control")
    treatment_data=$(ab_aggregate "$experiment" "treatment")

    local c_count t_count c_iter t_iter c_cost t_cost c_succ t_succ
    c_count=$(echo "$control_data" | jq -r '.count // 0')
    t_count=$(echo "$treatment_data" | jq -r '.count // 0')
    c_iter=$(echo "$control_data" | jq -r '.avg_iterations // 0')
    t_iter=$(echo "$treatment_data" | jq -r '.avg_iterations // 0')
    c_cost=$(echo "$control_data" | jq -r '.avg_cost // 0')
    t_cost=$(echo "$treatment_data" | jq -r '.avg_cost // 0')
    c_succ=$(echo "$control_data" | jq -r '.success_rate // 0')
    t_succ=$(echo "$treatment_data" | jq -r '.success_rate // 0')

    local iter_delta cost_delta succ_delta
    iter_delta=$((c_iter - t_iter))
    cost_delta=$((c_cost - t_cost))
    succ_delta=$((t_succ - c_succ))

    echo "A/B Test Report — experiment: $experiment"
    echo ""
    echo "Sample Sizes"
    printf "  Control:   %3d pipelines\n" "$c_count"
    printf "  Treatment: %3d pipelines\n" "$t_count"
    echo ""
    echo "Metrics"
    printf "  %-22s %10s %10s %10s\n" "Metric" "Control" "Treatment" "Delta"
    printf "  %-22s %10d %10d %10d\n" "Avg Iterations"    "$c_iter" "$t_iter" "$iter_delta"
    printf "  %-22s %10d %10d %10d\n" "Avg Cost (tokens)" "$c_cost" "$t_cost" "$cost_delta"
    printf "  %-22s %10d%% %10d%% %10d\n" "Success Rate"  "$c_succ" "$t_succ" "$succ_delta"
    echo ""
}
