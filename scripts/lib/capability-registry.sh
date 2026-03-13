#!/usr/bin/env bash
# Module: capability-registry
# Platform Capability Self-Assessment Registry
# Tracks success/failure rates by task category, gates pipelines below threshold
set -euo pipefail

# Module guard
[[ -n "${_MODULE_CAPABILITY_REGISTRY_LOADED:-}" ]] && return 0; _MODULE_CAPABILITY_REGISTRY_LOADED=1

# ─── Defaults ──────────────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Ensure helpers are loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }

# ─── Configuration Defaults ──────────────────────────────────────────
CAPABILITY_MIN_SUCCESS_RATE="${CAPABILITY_MIN_SUCCESS_RATE:-0.50}"
CAPABILITY_CONSERVATIVE_THRESHOLD="${CAPABILITY_CONSERVATIVE_THRESHOLD:-0.70}"
CAPABILITY_MIN_SAMPLES="${CAPABILITY_MIN_SAMPLES:-5}"
CAPABILITY_HYSTERESIS_MARGIN="${CAPABILITY_HYSTERESIS_MARGIN:-0.02}"
CAPABILITY_CONSERVATIVE_SAFE_CATEGORIES="${CAPABILITY_CONSERVATIVE_SAFE_CATEGORIES:-docs,bug}"

# ─── Load config from daemon-config.json ───────────────────────────
_capability_load_config() {
    local config_file=".claude/daemon-config.json"
    if [[ -f "$config_file" ]] && command -v jq >/dev/null 2>&1; then
        CAPABILITY_MIN_SUCCESS_RATE=$(jq -r '.capability.min_success_rate // 0.50' "$config_file" 2>/dev/null || echo "0.50")
        CAPABILITY_CONSERVATIVE_THRESHOLD=$(jq -r '.capability.conservative_threshold // 0.70' "$config_file" 2>/dev/null || echo "0.70")
        CAPABILITY_MIN_SAMPLES=$(jq -r '.capability.min_samples // 5' "$config_file" 2>/dev/null || echo "5")
        CAPABILITY_HYSTERESIS_MARGIN=$(jq -r '.capability.hysteresis_margin // 0.02' "$config_file" 2>/dev/null || echo "0.02")
        local safe
        safe=$(jq -r '.capability.conservative_safe_categories // empty' "$config_file" 2>/dev/null || true)
        if [[ -n "$safe" && "$safe" != "null" ]]; then
            CAPABILITY_CONSERVATIVE_SAFE_CATEGORIES=$(echo "$safe" | jq -r 'if type == "array" then join(",") else . end' 2>/dev/null || echo "docs,bug")
        fi
    fi
}

# ─── Repo Hash ──────────────────────────────────────────────────────
_capability_repo_hash() {
    local origin
    origin=$(git config --get remote.origin.url 2>/dev/null || echo "local")
    echo -n "$origin" | shasum -a 256 | cut -c1-12
}

# ─── Pre-flight Gate ──────────────────────────────────────────────
# capability_check_task <category> — returns 0 (pass) or 1 (reject)
capability_check_task() {
    local category="${1:-}"
    [[ -z "$category" ]] && return 0

    # Override flag bypasses check
    if [[ "${OVERRIDE_CAPABILITY_CHECK:-false}" == "true" ]]; then
        emit_event "capability.check" "category=$category" "result=override"
        return 0
    fi

    # Fail-open if DB functions not available
    if ! type db_capability_query >/dev/null 2>&1; then
        return 0
    fi

    _capability_load_config

    local rh
    rh=$(_capability_repo_hash)

    local entry
    entry=$(db_capability_query "$rh" "$category" 2>/dev/null) || { return 0; }

    # No entry or empty array — cold start, allow
    if [[ -z "$entry" || "$entry" == "[]" || "$entry" == "null" ]]; then
        emit_event "capability.check" "category=$category" "result=pass" "reason=cold_start"
        return 0
    fi

    local total_runs success_rate last_gate
    total_runs=$(echo "$entry" | jq -r '.[0].total_runs // 0' 2>/dev/null || echo "0")
    success_rate=$(echo "$entry" | jq -r '.[0].success_rate // 1.0' 2>/dev/null || echo "1.0")
    last_gate=$(echo "$entry" | jq -r '.[0].last_gate_result // "pass"' 2>/dev/null || echo "pass")

    # Not enough samples — allow
    if [[ "$total_runs" -lt "$CAPABILITY_MIN_SAMPLES" ]]; then
        emit_event "capability.check" "category=$category" "result=pass" "reason=insufficient_data" "total_runs=$total_runs"
        return 0
    fi

    # Conservative mode check
    if capability_is_conservative_mode 2>/dev/null; then
        if ! _capability_is_safe_category "$category"; then
            local conservative_result
            conservative_result=$(_capability_threshold_check "$success_rate" "$CAPABILITY_CONSERVATIVE_THRESHOLD" "$last_gate")
            if [[ "$conservative_result" == "reject" ]]; then
                emit_event "capability.rejected" "category=$category" "success_rate=$success_rate" "reason=conservative_mode"
                warn "Capability check: '$category' rejected (conservative mode, rate=${success_rate}, threshold=${CAPABILITY_CONSERVATIVE_THRESHOLD})"
                _capability_update_gate_result "$rh" "$category" "reject"
                return 1
            fi
        fi
    fi

    # Normal threshold check with hysteresis
    local result
    result=$(_capability_threshold_check "$success_rate" "$CAPABILITY_MIN_SUCCESS_RATE" "$last_gate")
    if [[ "$result" == "reject" ]]; then
        emit_event "capability.rejected" "category=$category" "success_rate=$success_rate" "threshold=$CAPABILITY_MIN_SUCCESS_RATE"
        warn "Capability check: '$category' rejected (rate=${success_rate}, threshold=${CAPABILITY_MIN_SUCCESS_RATE})"
        _capability_update_gate_result "$rh" "$category" "reject"
        return 1
    fi

    emit_event "capability.check" "category=$category" "result=pass" "success_rate=$success_rate"
    _capability_update_gate_result "$rh" "$category" "pass"
    return 0
}

# ─── Record Outcome ──────────────────────────────────────────────
# capability_record_outcome <category> <subcategory> <success>
# success: 1 = pass, 0 = fail
capability_record_outcome() {
    local category="${1:-}" subcategory="${2:-}" success="${3:-1}"
    [[ -z "$category" ]] && return 0

    if ! type db_capability_upsert >/dev/null 2>&1; then
        return 0
    fi

    local rh
    rh=$(_capability_repo_hash)

    if db_capability_upsert "$rh" "$category" "$subcategory" "$success" 2>/dev/null; then
        emit_event "capability.updated" "category=$category" "success=$success"
    else
        warn "Failed to record capability outcome for '$category'" 2>/dev/null || true
    fi
}

# ─── Conservative Mode ──────────────────────────────────────────────
# Returns 0 if conservative mode is active (overall rate < threshold)
capability_is_conservative_mode() {
    if ! type db_capability_overall_rate >/dev/null 2>&1; then
        return 1
    fi

    _capability_load_config

    local rh overall_rate
    rh=$(_capability_repo_hash)
    overall_rate=$(db_capability_overall_rate "$rh" 2>/dev/null || echo "1")

    # No data — not conservative
    if [[ "$overall_rate" == "0" ]]; then
        local total
        total=$(db_capability_query "$rh" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        [[ "$total" -eq 0 ]] && return 1
    fi

    # Compare using awk (bash 3.2 safe)
    local is_below
    is_below=$(awk "BEGIN { print ($overall_rate < $CAPABILITY_CONSERVATIVE_THRESHOLD) ? 1 : 0 }" 2>/dev/null || echo "0")
    [[ "$is_below" -eq 1 ]]
}

# ─── Internal Helpers ──────────────────────────────────────────────

# Threshold check with hysteresis band
_capability_threshold_check() {
    local rate="$1" threshold="$2" last_gate="${3:-pass}"
    local margin="$CAPABILITY_HYSTERESIS_MARGIN"

    local result
    if [[ "$last_gate" == "reject" ]]; then
        # Must exceed threshold + margin to re-admit
        result=$(awk "BEGIN { print ($rate >= ($threshold + $margin)) ? \"pass\" : \"reject\" }" 2>/dev/null || echo "pass")
    else
        # Must drop below threshold - margin to reject
        result=$(awk "BEGIN { print ($rate < ($threshold - $margin)) ? \"reject\" : \"pass\" }" 2>/dev/null || echo "pass")
    fi
    echo "$result"
}

# Check if category is in the safe list
_capability_is_safe_category() {
    local category="$1"
    local IFS=","
    local safe
    for safe in $CAPABILITY_CONSERVATIVE_SAFE_CATEGORIES; do
        [[ "$safe" == "$category" ]] && return 0
    done
    return 1
}

# Update last gate result in DB
_capability_update_gate_result() {
    local rh="$1" category="$2" result="$3"
    if type db_available >/dev/null 2>&1 && db_available 2>/dev/null; then
        local _sq="'"
        rh="${rh//$_sq/$_sq$_sq}"
        category="${category//$_sq/$_sq$_sq}"
        sqlite3 -cmd ".timeout 5000" "${DB_FILE:-$HOME/.shipwright/shipwright.db}" \
            "UPDATE capability_registry SET last_gate_result = '${result}' WHERE repo_hash = '${rh}' AND category = '${category}' AND subcategory = '';" 2>/dev/null || true
    fi
}
