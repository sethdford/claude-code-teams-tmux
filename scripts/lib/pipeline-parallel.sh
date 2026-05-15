#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline-parallel — Wave-based parallel stage executor       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Drives the dependency-aware pipeline runner. Stages that share a wave run
# concurrently as bash background jobs; failures in any wave abort further
# waves and mark transitive descendants as `skipped:upstream_failed`.
#
# Gate-serial guard: any stage whose gate is `approve` is always run on its
# own (waves are split so it doesn't share parallelism with peers) — gates
# need stdin and clean status output.
#
# Bash 3.2 compatible. Requires:
#   _run_one_stage <stage_id>             — provided by pipeline-execution.sh
#   dag_*                                  — provided by pipeline-dag.sh
#
# Off by default. Engaged only when PIPELINE_PARALLEL_ENABLED=true AND the
# template declares any depends_on edges.

[[ -n "${_PIPELINE_PARALLEL_LOADED:-}" ]] && return 0
_PIPELINE_PARALLEL_LOADED=1

VERSION="3.3.0"

PIPELINE_PARALLEL_MAX="${PIPELINE_PARALLEL_MAX:-4}"

# _pp_stage_gate <config> <id> — read gate field
_pp_stage_gate() {
    jq -r --arg s "$2" '.stages[] | select(.id == $s) | .gate // "auto"' "$1" 2>/dev/null
}

# _pp_split_wave_by_gate <config> <wave>
#
# Stages with gate=approve must run serially. We split the wave so each
# approve-gated stage forms its own sub-wave and the rest run together.
# Echoes one sub-wave per line.
_pp_split_wave_by_gate() {
    local config="$1" wave="$2"
    local s gate auto_bucket=""
    for s in $wave; do
        gate=$(_pp_stage_gate "$config" "$s")
        if [[ "$gate" == "approve" && "${SKIP_GATES:-false}" != "true" ]]; then
            [[ -n "$auto_bucket" ]] && { echo "$auto_bucket"; auto_bucket=""; }
            echo "$s"
        else
            auto_bucket+="$s "
        fi
    done
    [[ -n "$auto_bucket" ]] && echo "${auto_bucket% }"
}

# _pp_run_wave <wave>
#
# Spawns a bg job per stage, throttled by PIPELINE_PARALLEL_MAX, waits for
# all, and returns the first non-zero exit (or 0). Stage stdout/stderr are
# captured per-stage to <ARTIFACTS_DIR>/parallel-logs/<stage>.log so concurrent
# output does not interleave on the terminal.
_pp_run_wave() {
    local wave="$*"
    local log_dir="${ARTIFACTS_DIR:-/tmp}/parallel-logs"
    mkdir -p "$log_dir"

    local s pids="" stage_for_pid="" running=0
    local first_failure=""
    local failed_stage=""

    for s in $wave; do
        # Throttle: if at cap, wait for any one to finish before launching more.
        while [[ "$running" -ge "$PIPELINE_PARALLEL_MAX" ]]; do
            local finished_pid rc
            # `wait -n` is bash 4+; emulate by polling with `wait <pid>` on
            # the oldest pid (good enough for our wave sizes).
            finished_pid="${pids%% *}"
            wait "$finished_pid" 2>/dev/null
            rc=$?
            local fs
            fs=$(_pp_lookup_stage "$finished_pid" "$stage_for_pid")
            if [[ "$rc" -ne 0 && -z "$first_failure" ]]; then
                first_failure="$rc"
                failed_stage="$fs"
            fi
            pids="${pids#"$finished_pid"}"
            pids="${pids# }"
            running=$((running - 1))
        done

        (
            _run_one_stage "$s"
        ) >"$log_dir/$s.log" 2>&1 &
        local pid=$!
        pids+="$pid "
        stage_for_pid+="$pid=$s"$'\n'
        running=$((running + 1))
    done

    # Drain remaining.
    local p
    for p in $pids; do
        wait "$p" 2>/dev/null
        local rc=$?
        local fs
        fs=$(_pp_lookup_stage "$p" "$stage_for_pid")
        # Echo captured log so user sees output (in stage order via for-loop).
        if [[ -f "$log_dir/$fs.log" ]]; then
            cat "$log_dir/$fs.log"
        fi
        if [[ "$rc" -ne 0 && -z "$first_failure" ]]; then
            first_failure="$rc"
            failed_stage="$fs"
        fi
    done

    if [[ -n "$first_failure" ]]; then
        LAST_PARALLEL_FAILED_STAGE="$failed_stage"
        return "$first_failure"
    fi
    return 0
}

# _pp_lookup_stage <pid> <map_newlines>
_pp_lookup_stage() {
    local pid="$1" map="$2"
    grep "^$pid=" <<< "$map" 2>/dev/null | head -1 | cut -d= -f2-
}

# run_pipeline_parallel <config>
#
# Wave-by-wave execution. On stage failure, marks transitive descendants
# `skipped:upstream_failed` and aborts. Caller must have sourced
# pipeline-dag.sh and provided _run_one_stage.
run_pipeline_parallel() {
    local config="${1:-$PIPELINE_CONFIG}"

    if ! dag_validate "$config"; then
        return 1
    fi

    local done_list="" wave sub
    while :; do
        wave=$(dag_next_wave "$config" "$done_list")
        [[ -z "$wave" ]] && break
        # Split out approve-gated stages so they run alone.
        while IFS= read -r sub; do
            [[ -z "$sub" ]] && continue
            local wave_rc=0
            _pp_run_wave $sub || wave_rc=$?
            if [[ "$wave_rc" -ne 0 ]]; then
                local fs="${LAST_PARALLEL_FAILED_STAGE:-unknown}"
                # Mark descendants as skipped
                local desc d
                desc=$(dag_descendants "$config" "$fs" 2>/dev/null || true)
                while IFS= read -r d; do
                    [[ -z "$d" ]] && continue
                    if type set_stage_status >/dev/null 2>&1; then
                        set_stage_status "$d" "skipped:upstream_failed" 2>/dev/null || true
                    fi
                    emit_event "stage.skipped" "stage=$d" "reason=upstream_failed:$fs" 2>/dev/null || true
                done <<< "$desc"
                return "$wave_rc"
            fi
            for s in $sub; do
                done_list+="$s"$'\n'
            done
        done < <(_pp_split_wave_by_gate "$config" "$wave")
    done
    return 0
}
