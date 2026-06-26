#!/usr/bin/env bash
# Module: pipeline-dag
# Pure dependency-graph library for the parallel stage execution engine.
#
# Computes execution layers from stage `depends_on` declarations via Kahn's
# topological layering and validates acyclicity. These functions are PURE:
# they read a pipeline JSON document (arg or stdin) and write to stdout/stderr
# with NO side effects (no files, no git, no network). jq is the only dependency.
#
# Backward compatibility: a stage with no `depends_on` field is treated as
# depending on the previous enabled stage (a linear chain), so the layered
# engine reproduces today's strictly-sequential order when no template opts in.
#
# Bash 3.2 compatible: graph state lives in jq, not associative arrays.
set -euo pipefail

# Module guard
[[ -n "${_MODULE_PIPELINE_DAG_LOADED:-}" ]] && return 0
_MODULE_PIPELINE_DAG_LOADED=1

VERSION="3.3.0"

# Error identifiers (emitted to stderr alongside a human-readable message).
#   E_DAG_CYCLE        — circular dependency among enabled stages
#   E_DAG_MISSING_DEP  — depends_on references an unknown/disabled stage

# Read the pipeline JSON from $1 if given, otherwise from stdin.
_dag_input() {
    if [[ $# -gt 0 && -n "${1:-}" ]]; then
        printf '%s' "$1"
    else
        cat
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# dag_default_depends_on <pipeline_json>
# For every enabled stage WITHOUT a `depends_on` key, inject a linear dependency
# on the previous enabled stage (the first enabled stage gets []). Stages that
# already declare `depends_on` (including an explicit []) are left untouched.
# Disabled stages are never modified. Prints the augmented pipeline JSON.
# ─────────────────────────────────────────────────────────────────────────────
dag_default_depends_on() {
    local json
    json=$(_dag_input "$@")
    printf '%s' "$json" | jq '
        ([.stages[] | select(.enabled == true) | .id]) as $order
        | .stages |= map(
            if (.enabled == true) and (has("depends_on") | not) then
                .id as $sid
                | (($order | index($sid)) // 0) as $i
                | .depends_on = (if $i == 0 then [] else [$order[$i - 1]] end)
            else . end
          )
    '
}

# ─────────────────────────────────────────────────────────────────────────────
# dag_validate_acyclic <pipeline_json>
# Exit 0 if the enabled-stage dependency graph is a valid DAG with all deps
# referencing enabled stages. On failure prints an error identifier + detail to
# stderr and exits 1.
#   - missing/disabled dep target  → E_DAG_MISSING_DEP
#   - cycle                        → E_DAG_CYCLE (with the unresolved stage set)
# ─────────────────────────────────────────────────────────────────────────────
dag_validate_acyclic() {
    local json
    json=$(_dag_input "$@")

    # 1) Missing / disabled dependency targets.
    local missing
    missing=$(printf '%s' "$json" | jq -r '
        ([.stages[] | select(.enabled == true) | .id]) as $nodes
        | [ .stages[]
            | select(.enabled == true)
            | . as $s
            | (.depends_on // [])[]
            | . as $d
            | select(($nodes | index($d)) | not)
            | "\($s.id) -> \($d)" ]
        | .[]
    ' 2>/dev/null) || true
    if [[ -n "$missing" ]]; then
        echo "E_DAG_MISSING_DEP: depends_on references unknown or disabled stage(s):" >&2
        echo "$missing" | sed 's/^/  /' >&2
        return 1
    fi

    # 2) Cycle detection via Kahn's algorithm. jq errors with the stuck set.
    local stuck
    if stuck=$(printf '%s' "$json" | jq -r '
        ([.stages[] | select(.enabled == true) | .id]) as $nodes
        | (reduce (.stages[] | select(.enabled == true)) as $s ({};
            .[$s.id] = [ ($s.depends_on // [])[] | select(. as $d | $nodes | index($d)) ]
          )) as $deps
        | { remaining: $nodes }
        | until((.remaining | length) == 0;
            .remaining as $rem
            | [ $rem[] | select(($deps[.] // []) | all(. as $d | ($rem | index($d) | not))) ] as $ready
            | if ($ready | length) == 0
              then ("E_DAG_CYCLE\t" + ($rem | join(" "))) | error
              else .remaining = [ $rem[] | select(. as $n | ($ready | index($n) | not)) ] end
          )
        | "OK"
    ' 2>&1); then
        return 0
    fi

    # jq aborted: surface the cycle path captured in the error message.
    local cycle
    cycle=$(printf '%s' "$stuck" | sed -n 's/.*E_DAG_CYCLE\t\(.*\)/\1/p' | head -1)
    echo "E_DAG_CYCLE: circular dependency among stages: ${cycle:-unknown}" >&2
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# dag_compute_layers <pipeline_json>
# Print execution layers, one per line, each a space-separated list of enabled
# stage ids. Layer N depends only on stages in layers 0..N-1. Within-layer order
# preserves template order for determinism. Exits 1 on cycle/missing dep.
# ─────────────────────────────────────────────────────────────────────────────
dag_compute_layers() {
    local json
    json=$(_dag_input "$@")

    # Fail fast (and with a clear message) on invalid graphs.
    dag_validate_acyclic "$json" || return 1

    printf '%s' "$json" | jq -r '
        ([.stages[] | select(.enabled == true) | .id]) as $nodes
        | (reduce (.stages[] | select(.enabled == true)) as $s ({};
            .[$s.id] = [ ($s.depends_on // [])[] | select(. as $d | $nodes | index($d)) ]
          )) as $deps
        | { remaining: $nodes, out: [] }
        | until((.remaining | length) == 0;
            .remaining as $rem
            | [ $rem[] | select(($deps[.] // []) | all(. as $d | ($rem | index($d) | not))) ] as $ready
            | .out += [$ready]
            | .remaining = [ $rem[] | select(. as $n | ($ready | index($n) | not)) ]
          )
        | .out[] | join(" ")
    '
}

# Allow direct CLI use for debugging:  pipeline-dag.sh <layers|validate|defaults> [file]
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _cmd="${1:-layers}"
    _file="${2:-}"
    _payload=""
    [[ -n "$_file" ]] && _payload=$(cat "$_file")
    case "$_cmd" in
        layers)   dag_compute_layers "$_payload" ;;
        validate) dag_validate_acyclic "$_payload" && echo "OK" ;;
        defaults) dag_default_depends_on "$_payload" ;;
        *) echo "usage: pipeline-dag.sh <layers|validate|defaults> [file.json]" >&2; exit 2 ;;
    esac
fi
