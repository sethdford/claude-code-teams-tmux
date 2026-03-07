#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Stage Duration Metrics — Recording and querying stage timing data       ║
# ║  Called from pipeline-state.sh to persist durations for adaptive tuning  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2155

# Guard: only load once
[[ "${_STAGE_DURATION_METRICS_LOADED:-}" == "true" ]] && return 0
_STAGE_DURATION_METRICS_LOADED=true

# ─── Record a stage duration to the persistence layer ─────────────────────────
# Args: stage_type duration_seconds status repo_hash [job_id]
# Status: "complete" or "timeout"
record_stage_duration() {
    local stage_type="${1:?stage_type required}"
    local duration_seconds="${2:?duration_seconds required}"
    local status="${3:-complete}"
    local repo_hash="${4:-}"
    local job_id="${5:-${SHIPWRIGHT_PIPELINE_ID:-unknown}}"

    # Validate duration is a positive number
    if ! [[ "$duration_seconds" =~ ^[0-9]+\.?[0-9]*$ ]] || [[ "${duration_seconds%%.*}" -le 0 && "$duration_seconds" != "0" ]]; then
        return 0  # silently skip invalid durations
    fi

    # Reject absurd durations (>24 hours)
    local dur_int="${duration_seconds%%.*}"
    if [[ "$dur_int" -gt 86400 ]]; then
        if type emit_event >/dev/null 2>&1; then
            emit_event "timeout.duration_rejected" "stage=$stage_type" "duration=$duration_seconds" "reason=exceeds_24h" 2>/dev/null || true
        fi
        return 0
    fi

    # Calculate repo_hash if not provided
    if [[ -z "$repo_hash" ]]; then
        repo_hash=$(echo "${REPO_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
    fi

    # Try SQLite first
    if type db_save_stage_duration >/dev/null 2>&1; then
        db_save_stage_duration "$job_id" "$stage_type" "$dur_int" "$status" "$repo_hash" 2>/dev/null || true
    fi

    # Emit event for audit trail
    if type emit_event >/dev/null 2>&1; then
        emit_event "timeout.stage_duration_recorded" "stage=$stage_type" "duration_s=$dur_int" "status=$status" "repo_hash=$repo_hash" 2>/dev/null || true
    fi
}

# ─── Record a timeout event ───────────────────────────────────────────────────
# Args: stage_type repo_hash timeout_seconds actual_seconds
record_timeout_event() {
    local stage_type="${1:?stage_type required}"
    local repo_hash="${2:-}"
    local timeout_seconds="${3:-0}"
    local actual_seconds="${4:-0}"

    if [[ -z "$repo_hash" ]]; then
        repo_hash=$(echo "${REPO_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
    fi

    # Record the duration as a timeout
    record_stage_duration "$stage_type" "$actual_seconds" "timeout" "$repo_hash"

    # Emit specific timeout event
    if type emit_event >/dev/null 2>&1; then
        emit_event "timeout.detected" "stage=$stage_type" "timeout_s=$timeout_seconds" "actual_s=$actual_seconds" "repo_hash=$repo_hash" 2>/dev/null || true
    fi
}

# ─── Track when adaptive timeout prevented a false positive ───────────────────
# Args: stage_type repo_hash extra_time_needed
track_false_timeout_prevented() {
    local stage_type="${1:?stage_type required}"
    local repo_hash="${2:-}"
    local extra_time_needed="${3:-0}"

    if type emit_event >/dev/null 2>&1; then
        emit_event "timeout.false_positive_prevented" "stage=$stage_type" "extra_time_s=$extra_time_needed" "repo_hash=$repo_hash" 2>/dev/null || true
    fi
}

# ─── Track when timeout caught an anomaly ─────────────────────────────────────
# Args: stage_type repo_hash reason
track_timeout_avoided() {
    local stage_type="${1:?stage_type required}"
    local repo_hash="${2:-}"
    local reason="${3:-anomaly_detected}"

    if type emit_event >/dev/null 2>&1; then
        emit_event "timeout.avoided" "stage=$stage_type" "reason=$reason" "repo_hash=$repo_hash" 2>/dev/null || true
    fi
}
