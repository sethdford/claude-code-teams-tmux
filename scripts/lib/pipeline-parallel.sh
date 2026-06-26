#!/usr/bin/env bash
# Module: pipeline-parallel
# Parallel layer executor for the dependency-graph stage scheduler.
#
# Given an execution layer (a set of stage ids that share no real dependency,
# see pipeline-dag.sh), this module decides which stages are *safe* to run
# concurrently, fans the safe set out as capped background jobs, waits for all
# of them (even on failure — no orphan PIDs), and deterministically merges their
# per-stage logs in template order.
#
# Safety is WHITELISTED, never inferred. Stage definitions describe execution
# ORDER, not side effects: two stages with no declared dependency can still
# collide on the git working tree, $ARTIFACTS_DIR/*, pipeline-state.md, GitHub
# check runs, and the cost ledger. A stage therefore joins a parallel layer only
# if ALL of the following hold:
#   1. it is in the read-only whitelist (SW_PARALLEL_SAFE_STAGES),
#   2. its gate is not `approve` (human approval must serialize), and
#   3. it is not in the mutating set (build merge deploy validate) — and
#      `build`/`test` are additionally forced singleton so the self-healing
#      build loop is preserved verbatim.
# Everything else is forced into its own singleton group and run sequentially.
#
# Bash 3.2 compatible: PID→id tracking uses space-separated strings, not
# associative arrays. jq is the only external dependency for partitioning.
set -euo pipefail

# Module guard
[[ -n "${_MODULE_PIPELINE_PARALLEL_LOADED:-}" ]] && return 0
_MODULE_PIPELINE_PARALLEL_LOADED=1

VERSION="3.3.0"

# Read-only stages that may share a parallel layer. Override via env.
: "${SW_PARALLEL_SAFE_STAGES:=review spec_verification compound_quality adversarial security-audit code-review}"
# Stages that mutate shared state and must never parallelize.
: "${SW_PARALLEL_MUTATING_STAGES:=build test merge deploy validate}"
# Max concurrent stages in one parallel group.
: "${SW_PARALLEL_MAX_CONCURRENCY:=3}"

# Set by parallel_run_layer when a stage exits non-zero (first failure wins).
PARALLEL_FAILED_STAGE=""

# Error identifiers:
#   E_STAGE_FAILED — at least one stage in the layer exited non-zero.

# ─────────────────────────────────────────────────────────────────────────────
# _parallel_stage_gate <stage_id>
# Echo the gate value for a stage from $PIPELINE_CONFIG (empty if none/unknown).
# ─────────────────────────────────────────────────────────────────────────────
_parallel_stage_gate() {
    local id="$1"
    [[ -n "${PIPELINE_CONFIG:-}" ]] || { echo ""; return 0; }
    printf '%s' "$PIPELINE_CONFIG" \
        | jq -r --arg id "$id" '
            (.stages[]? | select(.id == $id) | .gate) // "" ' 2>/dev/null \
        | head -1 || echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# _parallel_in_list <needle> <space-separated-haystack>
# Exit 0 if needle is a whole-word member of the list.
# ─────────────────────────────────────────────────────────────────────────────
_parallel_in_list() {
    local needle="$1" item
    shift
    for item in $1; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# parallel_is_safe <stage_id>
# Exit 0 if the stage may share a parallel layer (whitelist ∧ gate!=approve ∧
# not mutating). Exit 1 otherwise. Pure — depends only on $PIPELINE_CONFIG and
# the SW_PARALLEL_* env lists.
# ─────────────────────────────────────────────────────────────────────────────
parallel_is_safe() {
    local id="$1"
    _parallel_in_list "$id" "$SW_PARALLEL_SAFE_STAGES" || return 1
    _parallel_in_list "$id" "$SW_PARALLEL_MUTATING_STAGES" && return 1
    [[ "$(_parallel_stage_gate "$id")" == "approve" ]] && return 1
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# parallel_partition <layer_ids>
# Split a layer's space-separated ids into a parallel-safe group and forced
# singletons, preserving input order within each group. Prints exactly:
#     SAFE:<space-separated safe ids>
#     SINGLE:<space-separated singleton ids>
# (Either list may be empty.) Always exits 0.
# ─────────────────────────────────────────────────────────────────────────────
parallel_partition() {
    local layer="$1" id safe="" single=""
    for id in $layer; do
        if parallel_is_safe "$id"; then
            safe="${safe:+$safe }$id"
        else
            single="${single:+$single }$id"
        fi
    done
    echo "SAFE:$safe"
    echo "SINGLE:$single"
}

# ─────────────────────────────────────────────────────────────────────────────
# parallel_run_layer <safe_ids>
# Run each id concurrently (throttled to SW_PARALLEL_MAX_CONCURRENCY) via the
# stage runner named in $PARALLEL_STAGE_RUNNER (default: run_stage_with_retry).
# Each stage's stdout+stderr is captured to $PARALLEL_LOG_DIR/<id>.log.
#
# On the first non-zero exit, stops spawning NEW stages, waits for all in-flight
# siblings (no orphan PIDs), records the first failing id in PARALLEL_FAILED_STAGE,
# and returns that stage's exit code. Returns 0 only if every stage succeeded.
# ─────────────────────────────────────────────────────────────────────────────
parallel_run_layer() {
    local ids="$1"
    local runner="${PARALLEL_STAGE_RUNNER:-run_stage_with_retry}"
    local log_dir="${PARALLEL_LOG_DIR:-${ARTIFACTS_DIR:-.}/parallel-logs}"
    mkdir -p "$log_dir"

    PARALLEL_FAILED_STAGE=""
    local rc=0
    local pids="" running=0 id
    # Parallel arrays (bash 3.2): pid_list[i] ↔ id_list[i].
    local pid_list="" id_list=""

    _parallel_reap_one() {
        # Wait for any one tracked pid to finish; update rc/PARALLEL_FAILED_STAGE.
        local wpid="$1" wid="$2" wrc=0
        wait "$wpid" || wrc=$?
        if [[ $wrc -ne 0 && -z "$PARALLEL_FAILED_STAGE" ]]; then
            PARALLEL_FAILED_STAGE="$wid"
            rc=$wrc
        fi
    }

    for id in $ids; do
        # Throttle: once at the cap, drain the oldest in-flight job.
        while [[ $running -ge $SW_PARALLEL_MAX_CONCURRENCY ]]; do
            local oldest_pid="${pid_list%% *}" oldest_id="${id_list%% *}"
            pid_list="${pid_list#* }"; [[ "$pid_list" == "$oldest_pid" ]] && pid_list=""
            id_list="${id_list#* }";  [[ "$id_list" == "$oldest_id" ]] && id_list=""
            _parallel_reap_one "$oldest_pid" "$oldest_id"
            running=$((running - 1))
        done

        # Once a failure is recorded, stop spawning new stages.
        [[ -n "$PARALLEL_FAILED_STAGE" ]] && break

        ( "$runner" "$id" ) >"$log_dir/$id.log" 2>&1 &
        local p=$!
        pid_list="${pid_list:+$pid_list }$p"
        id_list="${id_list:+$id_list }$id"
        running=$((running + 1))
    done

    # Drain all remaining in-flight stages — no orphan PIDs, even on failure.
    while [[ $running -gt 0 ]]; do
        local op="${pid_list%% *}" oi="${id_list%% *}"
        pid_list="${pid_list#* }"; [[ "$pid_list" == "$op" ]] && pid_list=""
        id_list="${id_list#* }";  [[ "$id_list" == "$oi" ]] && id_list=""
        _parallel_reap_one "$op" "$oi"
        running=$((running - 1))
    done

    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# parallel_merge_logs <ordered_ids>
# Concatenate per-stage logs from $PARALLEL_LOG_DIR in the given (template) order
# so concurrent output is presented deterministically, never interleaved. Each
# stage block is fenced with a header. Missing logs are skipped silently.
# ─────────────────────────────────────────────────────────────────────────────
parallel_merge_logs() {
    local ids="$1" id
    local log_dir="${PARALLEL_LOG_DIR:-${ARTIFACTS_DIR:-.}/parallel-logs}"
    for id in $ids; do
        local f="$log_dir/$id.log"
        [[ -f "$f" ]] || continue
        echo "───── stage: $id ─────"
        cat "$f"
    done
}

# Allow direct CLI use for debugging:  pipeline-parallel.sh partition "<ids>"
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _cmd="${1:-partition}"
    case "$_cmd" in
        partition) parallel_partition "${2:-}" ;;
        is-safe)   parallel_is_safe "${2:-}" && echo "safe" || echo "singleton" ;;
        *) echo "usage: pipeline-parallel.sh <partition|is-safe> \"<ids>\"" >&2; exit 2 ;;
    esac
fi
