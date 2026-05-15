#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline-dag — Dependency DAG resolver for pipeline stages   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Reads a pipeline template JSON (path in $1) and computes execution waves
# from each stage's optional `depends_on` array. Stages with no dependencies
# (or whose dependencies are all complete) form a wave that may run in
# parallel. Cycles and unknown deps are reported as errors.
#
# Bash 3.2 compatible: no associative arrays.

[[ -n "${_PIPELINE_DAG_LOADED:-}" ]] && return 0
_PIPELINE_DAG_LOADED=1

VERSION="3.3.0"

# dag_stage_ids <config> — print enabled stage IDs, one per line, in template order
dag_stage_ids() {
    local config="$1"
    jq -r '.stages[] | select(.enabled == true) | .id' "$config" 2>/dev/null
}

# dag_stage_deps <config> <stage_id> — print space-separated dependency ids
dag_stage_deps() {
    local config="$1" stage="$2"
    jq -r --arg s "$stage" '
        .stages[]
        | select(.id == $s)
        | (.depends_on // [])
        | join(" ")
    ' "$config" 2>/dev/null
}

# dag_validate <config>
#
# Checks every `depends_on` reference points to an enabled stage and that
# the graph has no cycle. Prints a readable error and returns non-zero on
# the first problem; returns 0 on a clean graph.
dag_validate() {
    local config="$1"
    local ids deps_str dep id
    ids=$(dag_stage_ids "$config")
    [[ -z "$ids" ]] && return 0

    # Unknown-dep check
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        deps_str=$(dag_stage_deps "$config" "$id")
        for dep in $deps_str; do
            if ! grep -qx -- "$dep" <<< "$ids"; then
                echo "pipeline-dag: stage '$id' depends on unknown or disabled stage '$dep'" >&2
                return 1
            fi
            if [[ "$dep" == "$id" ]]; then
                echo "pipeline-dag: stage '$id' depends on itself" >&2
                return 1
            fi
        done
    done <<< "$ids"

    # Cycle check via Kahn-style consumption — we iterate dag_next_wave until
    # either all stages are consumed (acyclic) or no progress is possible.
    local done_list="" remaining
    remaining="$ids"
    local progressed=1
    while [[ -n "$remaining" && "$progressed" -eq 1 ]]; do
        progressed=0
        local wave
        wave=$(_dag_compute_wave "$config" "$done_list" "$remaining")
        if [[ -n "$wave" ]]; then
            progressed=1
            local w
            for w in $wave; do
                done_list+="$w"$'\n'
                remaining=$(grep -vx -- "$w" <<< "$remaining" || true)
            done
        fi
    done

    if [[ -n "$remaining" ]]; then
        local cyc
        cyc=$(tr '\n' ' ' <<< "$remaining" | sed 's/ *$//')
        echo "pipeline-dag: cycle detected among stages: $cyc" >&2
        return 1
    fi
    return 0
}

# _dag_compute_wave <config> <done_newline_list> <remaining_newline_list>
#
# Prints space-separated IDs of stages whose deps are all in <done_list>.
# Internal helper used by dag_validate and dag_next_wave.
_dag_compute_wave() {
    local config="$1" done_list="$2" remaining="$3"
    local id deps_str dep ready out=""
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        deps_str=$(dag_stage_deps "$config" "$id")
        ready=1
        for dep in $deps_str; do
            if ! grep -qx -- "$dep" <<< "$done_list"; then
                ready=0
                break
            fi
        done
        if [[ "$ready" -eq 1 ]]; then
            out+="$id "
        fi
    done <<< "$remaining"
    echo "${out% }"
}

# dag_next_wave <config> <done_newline_separated_ids>
#
# Prints space-separated stage IDs that are ready to run given the
# already-completed set. Empty output means the pipeline is finished
# (caller's responsibility to detect).
dag_next_wave() {
    local config="$1" done_list="${2:-}"
    local all remaining
    all=$(dag_stage_ids "$config")
    remaining="$all"
    if [[ -n "$done_list" ]]; then
        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            remaining=$(grep -vx -- "$d" <<< "$remaining" || true)
        done <<< "$done_list"
    fi
    [[ -z "$remaining" ]] && return 0
    _dag_compute_wave "$config" "$done_list" "$remaining"
}

# dag_waves <config>
#
# Prints each wave on its own line as space-separated IDs. Useful for
# debugging and tests. Returns non-zero on cycle/invalid graph.
dag_waves() {
    local config="$1"
    if ! dag_validate "$config" >/dev/null 2>&1; then
        dag_validate "$config"  # re-run to surface the error
        return 1
    fi
    local done_list="" wave
    while :; do
        wave=$(dag_next_wave "$config" "$done_list")
        [[ -z "$wave" ]] && break
        echo "$wave"
        local w
        for w in $wave; do
            done_list+="$w"$'\n'
        done
    done
}

# dag_has_depends_on <config>
#
# Returns 0 if any stage declares a non-empty depends_on array, 1 otherwise.
# Used to decide whether to engage the parallel executor at all.
dag_has_depends_on() {
    local config="$1"
    local count
    count=$(jq '[.stages[] | select((.depends_on // []) | length > 0)] | length' "$config" 2>/dev/null)
    [[ "${count:-0}" -gt 0 ]]
}

# dag_descendants <config> <stage_id>
#
# Prints all stages that transitively depend on <stage_id> (newline-separated).
# Used to mark `skipped:upstream_failed` when a stage fails.
dag_descendants() {
    local config="$1" root="$2"
    local frontier="$root" next id deps_str dep visited="$root"
    while [[ -n "$frontier" ]]; do
        next=""
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            deps_str=$(dag_stage_deps "$config" "$id")
            for dep in $deps_str; do
                if grep -qx -- "$dep" <<< "$frontier" && ! grep -qx -- "$id" <<< "$visited"; then
                    next+="$id"$'\n'
                    visited+=$'\n'"$id"
                fi
            done
        done < <(dag_stage_ids "$config")
        frontier=$(printf '%s' "$next" | sed '/^$/d')
    done
    # Strip the root from the visited list before printing
    grep -vx -- "$root" <<< "$visited" || true
}
