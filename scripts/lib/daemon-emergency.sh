# daemon-emergency.sh — Emergency mode activation/deactivation for daemon (for sw-daemon.sh)
# Auto-activates conservative limits when rolling success rate collapses.
# Source from sw-daemon.sh after daemon-state.sh. Requires helpers, state, config.

[[ -n "${_DAEMON_EMERGENCY_LOADED:-}" ]] && return 0
_DAEMON_EMERGENCY_LOADED=1

# Defaults for variables normally set by sw-daemon.sh (safe under set -u).
DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
STATE_FILE="${STATE_FILE:-${DAEMON_DIR}/daemon-state.json}"
EVENTS_FILE="${EVENTS_FILE:-${DAEMON_DIR}/events.jsonl}"
EMERGENCY_FLAG="${EMERGENCY_FLAG:-${DAEMON_DIR}/daemon-emergency.flag}"
LOG_DIR="${LOG_DIR:-${DAEMON_DIR}/logs}"
MIN_WORKERS="${MIN_WORKERS:-1}"
MAX_WORKERS="${MAX_WORKERS:-8}"

# Configuration variables (set by sw-daemon.sh from config)
EMERGENCY_MODE_ENABLED="${EMERGENCY_MODE_ENABLED:-true}"
EMERGENCY_ACTIVATION_THRESHOLD="${EMERGENCY_ACTIVATION_THRESHOLD:-30}"
EMERGENCY_RECOVERY_THRESHOLD="${EMERGENCY_RECOVERY_THRESHOLD:-60}"
EMERGENCY_ROLLING_WINDOW="${EMERGENCY_ROLLING_WINDOW:-10}"
EMERGENCY_MIN_SAMPLES="${EMERGENCY_MIN_SAMPLES:-5}"
EMERGENCY_RECOVERY_CHECKS="${EMERGENCY_RECOVERY_CHECKS:-3}"
EMERGENCY_MAX_DURATION_MINUTES="${EMERGENCY_MAX_DURATION_MINUTES:-120}"

# In-memory recovery counter (scoped to daemon process)
DAEMON_EMERGENCY_RECOVERY_COUNTER=0

# ─── Primary Entry Point: daemon_emergency_check() ──────────────────────────
# Called every N poll cycles to check success rate and manage emergency state.
# Returns 0 on success, 1 on error or insufficient data
daemon_emergency_check() {
    # Exit early if disabled
    if [[ "${EMERGENCY_MODE_ENABLED}" != "true" ]]; then
        return 1
    fi

    # Check if events file exists and is readable
    if [[ ! -f "$EVENTS_FILE" ]]; then
        return 1
    fi

    # Read last N completed pipeline events (parse JSONL directly with jq)
    local recent_events
    recent_events=$(jq -s "[.[] | select(.type == \"pipeline.completed\")] | if length > ${EMERGENCY_ROLLING_WINDOW} then .[-${EMERGENCY_ROLLING_WINDOW}:] else . end" "$EVENTS_FILE" 2>/dev/null) || return 1

    if [[ -z "$recent_events" || "$recent_events" == "[]" ]]; then
        return 1
    fi

    # Count total and successes
    local total failures success_rate
    total=$(echo "$recent_events" | jq 'length' 2>/dev/null || echo 0)

    if [[ $total -lt "${EMERGENCY_MIN_SAMPLES}" ]]; then
        return 1
    fi

    # A completion is a success if it has no "error" field in optional data
    # Check if result field exists and is not "failed"
    failures=$(echo "$recent_events" | jq '[.[] | select(.data.result == "failed" or (.data.error != null and .data.error != ""))] | length' 2>/dev/null || echo 0)
    if ! [[ "$failures" =~ ^[0-9]+$ ]]; then failures=0; fi

    local successes=$((total - failures))
    success_rate=$((successes * 100 / total))

    # Log the check
    daemon_log "INFO" "emergency_check: success_rate=${success_rate}% (${successes}/${total}), threshold=${EMERGENCY_ACTIVATION_THRESHOLD}%"

    # Emit event
    emit_event "daemon.emergency_check" "success_rate=${success_rate}" "mode=$(daemon_emergency_is_active 2>/dev/null && echo 'active' || echo 'inactive')" "recovery_count=${DAEMON_EMERGENCY_RECOVERY_COUNTER}"

    # Activation logic: if NOT active and success_rate is very bad
    if ! daemon_emergency_is_active 2>/dev/null; then
        if [[ $success_rate -le "${EMERGENCY_ACTIVATION_THRESHOLD}" ]]; then
            daemon_log "ERROR" "Success rate collapsed to ${success_rate}% (threshold: ${EMERGENCY_ACTIVATION_THRESHOLD}%) — activating emergency mode"
            daemon_emergency_activate "$success_rate" "$total" "$failures"
            return 0
        fi
    else
        # Deactivation logic: if active and success_rate has recovered
        if [[ $success_rate -ge "${EMERGENCY_RECOVERY_THRESHOLD}" ]]; then
            DAEMON_EMERGENCY_RECOVERY_COUNTER=$((DAEMON_EMERGENCY_RECOVERY_COUNTER + 1))
            daemon_log "INFO" "Success rate recovered to ${success_rate}% (recovery_check ${DAEMON_EMERGENCY_RECOVERY_COUNTER}/${EMERGENCY_RECOVERY_CHECKS})"

            if [[ ${DAEMON_EMERGENCY_RECOVERY_COUNTER} -ge "${EMERGENCY_RECOVERY_CHECKS}" ]]; then
                daemon_log "SUCCESS" "Recovery sustained for ${EMERGENCY_RECOVERY_CHECKS} checks — deactivating emergency mode"
                daemon_emergency_deactivate "$success_rate" "recovered"
                DAEMON_EMERGENCY_RECOVERY_COUNTER=0
                return 0
            fi
        else
            # Reset recovery counter if we slip below recovery threshold
            if [[ ${DAEMON_EMERGENCY_RECOVERY_COUNTER} -gt 0 ]]; then
                daemon_log "WARN" "Recovery interrupted (rate dropped to ${success_rate}%) — resetting recovery counter"
                DAEMON_EMERGENCY_RECOVERY_COUNTER=0
            fi
        fi
    fi

    return 0
}

# ─── Activation: daemon_emergency_activate() ──────────────────────────────────
# Saves pre-emergency config and applies conservative limits
daemon_emergency_activate() {
    local success_rate="${1:-0}"
    local total="${2:-0}"
    local failures="${3:-0}"

    # Get current settings (from environment)
    local pre_max_parallel="${MAX_PARALLEL:-${MAX_WORKERS}}"
    local pre_template="${PIPELINE_TEMPLATE:-autonomous}"
    local pre_max_retries="${MAX_RETRIES:-2}"
    local activated_at
    activated_at=$(now_iso 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create flag file with pre-emergency config (atomic: tmp + mv)
    local flag_tmp="${EMERGENCY_FLAG}.tmp.$$"
    local flag_json
    flag_json=$(cat <<EOF
{
  "activated_at": "${activated_at}",
  "success_rate_at_activation": ${success_rate},
  "reason": "success_rate_${success_rate}_percent",
  "total_in_window": ${total},
  "failures_in_window": ${failures},
  "pre_emergency_config": {
    "max_parallel": ${pre_max_parallel},
    "pipeline_template": "${pre_template}",
    "max_retries": ${pre_max_retries}
  }
}
EOF
)
    echo "$flag_json" > "$flag_tmp" 2>/dev/null || {
        daemon_log "ERROR" "Failed to write emergency flag file (tmp)"
        return 1
    }
    mv "$flag_tmp" "$EMERGENCY_FLAG" 2>/dev/null || {
        daemon_log "ERROR" "Failed to write emergency flag file (mv)"
        rm -f "$flag_tmp" 2>/dev/null || true
        return 1
    }

    # Apply emergency limits (global variables)
    MAX_PARALLEL="${MIN_WORKERS}"
    PIPELINE_TEMPLATE="full"
    MAX_RETRIES=$(( pre_max_retries > 3 ? pre_max_retries : 3 ))

    # Update daemon state
    locked_state_update "emergency_mode" "true" 2>/dev/null || true
    locked_state_update "emergency_activated_at" "${activated_at}" 2>/dev/null || true

    # Emit event
    emit_event "daemon.emergency_activated" "success_rate=${success_rate}" "threshold=${EMERGENCY_ACTIVATION_THRESHOLD}" "window=${EMERGENCY_ROLLING_WINDOW}" "failures=${failures}" "total=${total}"

    daemon_log "ERROR" "EMERGENCY MODE ACTIVATED: max_parallel=${MAX_PARALLEL}, template=full, max_retries=${MAX_RETRIES}"
}

# ─── Deactivation: daemon_emergency_deactivate() ─────────────────────────────
# Restores pre-emergency config and removes flag file
daemon_emergency_deactivate() {
    local success_rate="${1:-0}"
    local reason="${2:-unknown}"

    # Read flag file to get pre-emergency config
    if [[ ! -f "$EMERGENCY_FLAG" ]]; then
        daemon_log "WARN" "Emergency deactivate called but flag file not found"
        return 1
    fi

    local flag_data
    flag_data=$(cat "$EMERGENCY_FLAG" 2>/dev/null) || {
        daemon_log "WARN" "Failed to read emergency flag file"
        return 1
    }

    # Extract pre-emergency values
    local pre_max_parallel pre_template pre_max_retries activated_at
    pre_max_parallel=$(echo "$flag_data" | jq -r '.pre_emergency_config.max_parallel // empty' 2>/dev/null || echo "$MAX_WORKERS")
    pre_template=$(echo "$flag_data" | jq -r '.pre_emergency_config.pipeline_template // empty' 2>/dev/null || echo "autonomous")
    pre_max_retries=$(echo "$flag_data" | jq -r '.pre_emergency_config.max_retries // empty' 2>/dev/null || echo "2")
    activated_at=$(echo "$flag_data" | jq -r '.activated_at // empty' 2>/dev/null || echo "unknown")

    # Restore pre-emergency config
    MAX_PARALLEL="${pre_max_parallel}"
    PIPELINE_TEMPLATE="${pre_template}"
    MAX_RETRIES="${pre_max_retries}"

    # Calculate duration
    local duration_s=0
    if [[ "$activated_at" != "unknown" ]]; then
        local now_epoch activated_epoch
        now_epoch=$(now_epoch 2>/dev/null || date +%s)
        activated_epoch=$(date -d "$activated_at" +%s 2>/dev/null || echo "0")
        if [[ "$activated_epoch" =~ ^[0-9]+$ ]]; then
            duration_s=$((now_epoch - activated_epoch))
        fi
    fi

    # Remove flag file
    rm -f "$EMERGENCY_FLAG" 2>/dev/null || {
        daemon_log "WARN" "Failed to remove emergency flag file"
    }

    # Update daemon state
    locked_state_update "emergency_mode" "false" 2>/dev/null || true
    locked_state_update "emergency_activated_at" "" 2>/dev/null || true

    # Emit event
    emit_event "daemon.emergency_deactivated" "success_rate=${success_rate}" "threshold=${EMERGENCY_RECOVERY_THRESHOLD}" "duration_s=${duration_s}" "reason=${reason}"

    daemon_log "SUCCESS" "EMERGENCY MODE DEACTIVATED (duration: ${duration_s}s): restored max_parallel=${MAX_PARALLEL}, template=${PIPELINE_TEMPLATE}, max_retries=${MAX_RETRIES}"
}

# ─── State Query: daemon_emergency_is_active() ────────────────────────────────
# Returns 0 if emergency mode is currently active and valid, 1 otherwise
# Auto-deactivates if expired
daemon_emergency_is_active() {
    if [[ ! -f "$EMERGENCY_FLAG" ]]; then
        return 1
    fi

    local flag_data
    flag_data=$(cat "$EMERGENCY_FLAG" 2>/dev/null) || return 1

    local activated_at
    activated_at=$(echo "$flag_data" | jq -r '.activated_at // empty' 2>/dev/null) || return 1

    if [[ -z "$activated_at" ]]; then
        return 1
    fi

    # Check expiration
    local now_epoch activated_epoch max_duration_seconds
    now_epoch=$(now_epoch 2>/dev/null || date +%s)
    activated_epoch=$(date -d "$activated_at" +%s 2>/dev/null || echo "0")
    max_duration_seconds=$((EMERGENCY_MAX_DURATION_MINUTES * 60))

    if [[ ! "$activated_epoch" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if [[ $((now_epoch - activated_epoch)) -gt $max_duration_seconds ]]; then
        # Auto-deactivate on expiration
        daemon_log "WARN" "Emergency mode expired (${EMERGENCY_MAX_DURATION_MINUTES}m max) — auto-deactivating"
        daemon_emergency_deactivate "0" "expired"
        return 1
    fi

    return 0
}

# ─── Ceiling Query: daemon_emergency_get_ceiling() ────────────────────────────
# Returns the max parallelism allowed when emergency mode is active
# Used by daemon_auto_scale() to constrain MAX_PARALLEL
daemon_emergency_get_ceiling() {
    if daemon_emergency_is_active 2>/dev/null; then
        echo "${MIN_WORKERS}"
    else
        echo "${MAX_WORKERS}"
    fi
}

# ─── Startup: daemon_emergency_load_state() ───────────────────────────────────
# Called once at daemon startup to restore emergency mode state from flag file
daemon_emergency_load_state() {
    if [[ ! -f "$EMERGENCY_FLAG" ]]; then
        return 0  # No flag file; start normally
    fi

    if ! daemon_emergency_is_active 2>/dev/null; then
        return 0  # Flag expired; start normally
    fi

    # Flag is valid; restore pre-emergency config
    local flag_data
    flag_data=$(cat "$EMERGENCY_FLAG" 2>/dev/null) || return 0

    local pre_max_parallel pre_template pre_max_retries
    pre_max_parallel=$(echo "$flag_data" | jq -r '.pre_emergency_config.max_parallel // empty' 2>/dev/null)
    pre_template=$(echo "$flag_data" | jq -r '.pre_emergency_config.pipeline_template // empty' 2>/dev/null)
    pre_max_retries=$(echo "$flag_data" | jq -r '.pre_emergency_config.max_retries // empty' 2>/dev/null)

    if [[ -n "$pre_max_parallel" && "$pre_max_parallel" =~ ^[0-9]+$ ]]; then
        MAX_PARALLEL="${MIN_WORKERS}"
    fi

    if [[ -n "$pre_template" ]]; then
        PIPELINE_TEMPLATE="full"
    fi

    if [[ -n "$pre_max_retries" && "$pre_max_retries" =~ ^[0-9]+$ ]]; then
        MAX_RETRIES=$(( pre_max_retries > 3 ? pre_max_retries : 3 ))
    fi

    # Update daemon state to reflect emergency mode
    locked_state_update "emergency_mode" "true" 2>/dev/null || true

    local activated_at
    activated_at=$(echo "$flag_data" | jq -r '.activated_at // empty' 2>/dev/null)
    if [[ -n "$activated_at" ]]; then
        locked_state_update "emergency_activated_at" "${activated_at}" 2>/dev/null || true
    fi

    daemon_log "WARN" "Daemon startup: restoring emergency mode (from flag at ${activated_at})"
}

# ─── Helper Functions ──────────────────────────────────────────────────────────

# Emit an event to events.jsonl (delegated to helpers.sh)
# Usage: emit_event "type" "key1=val1" "key2=val2"
emit_event() {
    local event_type="$1"
    shift
    local data_pairs=("$@")

    if [[ -z "$EVENTS_FILE" ]]; then
        return 0
    fi

    local timestamp
    timestamp=$(now_iso 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    local data_json="{}"
    for pair in "${data_pairs[@]}"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"

        # Attempt to parse numeric values
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            data_json=$(echo "$data_json" | jq --arg k "$key" --arg v "$value" '.[$k] |= ($v | tonumber)' 2>/dev/null || echo "{}")
        else
            data_json=$(echo "$data_json" | jq --arg k "$key" --arg v "$value" '.[$k] = $v' 2>/dev/null || echo "{}")
        fi
    done

    local event_json
    event_json=$(jq -n \
        --arg type "$event_type" \
        --arg timestamp "$timestamp" \
        --argjson data "$data_json" \
        '{type: $type, timestamp: $timestamp, data: $data}' 2>/dev/null) || return 1

    echo "$event_json" >> "$EVENTS_FILE" 2>/dev/null || true
}

# Log a message (delegated to helpers.sh or fallback)
daemon_log() {
    local level="$1"
    local message="$2"

    # Try to use helpers.sh log function if available, otherwise fallback
    if declare -f "log_${level,,}" > /dev/null 2>&1; then
        "log_${level,,}" "$message"
    else
        printf "[%s] %s\n" "$level" "$message" >> "${LOG_DIR}/daemon.log" 2>/dev/null || true
    fi
}

# Current time in ISO8601 (delegated to helpers.sh)
now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || return 1
}

# Current time in epoch seconds
now_epoch() {
    date +%s 2>/dev/null || return 1
}

# State update function (delegated to daemon-state.sh)
locked_state_update() {
    local key="$1"
    local value="$2"

    if [[ -z "$STATE_FILE" ]]; then
        return 1
    fi

    # If locked_state_update is already defined (from daemon-state.sh), use it
    if declare -f "locked_state_update" > /dev/null 2>&1; then
        "locked_state_update" "$key" "$value"
    else
        # Fallback: direct jq update (not atomic, but safe for this purpose)
        local tmp_file="${STATE_FILE}.tmp.$$"
        jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE" > "$tmp_file" 2>/dev/null && \
            mv "$tmp_file" "$STATE_FILE" 2>/dev/null || {
            rm -f "$tmp_file" 2>/dev/null || true
            return 1
        }
    fi
}
