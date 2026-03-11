#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  success-rate-constraints.sh — Strategic Agent Success Rate Feedback     ║
# ║  Rolling success rate, complexity constraints, and hysteresis            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Guard against multiple sources
[[ -n "${_SUCCESS_RATE_CONSTRAINTS_LOADED:-}" ]] && return 0
_SUCCESS_RATE_CONSTRAINTS_LOADED=1

set -euo pipefail

VERSION="1.0.0"

# Defaults — allow override via daemon-config.json or environment
SUCCESS_RATE_CONSTRAINTS_ENABLED="${SUCCESS_RATE_CONSTRAINTS_ENABLED:-false}"
SUCCESS_RATE_WINDOW_SIZE="${SUCCESS_RATE_WINDOW_SIZE:-50}"  # Last N outcomes
SUCCESS_RATE_MIN_DATA_POINTS="${SUCCESS_RATE_MIN_DATA_POINTS:-5}"  # Must have at least this many outcomes
SUCCESS_RATE_DATA_FRESHNESS_HOURS="${SUCCESS_RATE_DATA_FRESHNESS_HOURS:-24}"  # Data older than this is stale
SUCCESS_RATE_CONSTRAINT_THRESHOLD_LOW="${SUCCESS_RATE_CONSTRAINT_THRESHOLD_LOW:-40}"  # <40% = heavy constraints
SUCCESS_RATE_CONSTRAINT_THRESHOLD_MED="${SUCCESS_RATE_CONSTRAINT_THRESHOLD_MED:-60}"  # <60% = moderate constraints
SUCCESS_RATE_RECOVERY_THRESHOLD="${SUCCESS_RATE_RECOVERY_THRESHOLD:-70}"  # >70% = relax all constraints
SUCCESS_RATE_MIN_COMPLEXITY_ALLOWED="${SUCCESS_RATE_MIN_COMPLEXITY_ALLOWED:-3}"  # Always allow complexity ≤ 3
SUCCESS_RATE_DEFER_COMPLEXITY_HIGH="${SUCCESS_RATE_DEFER_COMPLEXITY_HIGH:-4}"  # Defer complexity >4 when low
SUCCESS_RATE_DEFER_COMPLEXITY_MED="${SUCCESS_RATE_DEFER_COMPLEXITY_MED:-7}"  # Defer complexity >7 when medium

# Tuning state file (hysteresis, last constraint level, etc.)
CONSTRAINT_TUNING_FILE="${HOME}/.shipwright/optimization/daemon-tuning.json"

# Helper: Load config from daemon-config.json if available
_load_constraint_config() {
    local config_file="${1:-./.claude/daemon-config.json}"

    if [[ ! -f "$config_file" ]]; then
        return 0  # Graceful: use defaults if config doesn't exist
    fi

    # Extract success_rate_constraints config, if it exists
    local config_json
    config_json=$(jq -r '.success_rate_constraints // {}' "$config_file" 2>/dev/null || echo "{}")

    [[ -z "$config_json" || "$config_json" == "null" ]] && return 0

    # Load all configuration keys
    SUCCESS_RATE_CONSTRAINTS_ENABLED=$(echo "$config_json" | jq -r '.enabled // '"${SUCCESS_RATE_CONSTRAINTS_ENABLED}" 2>/dev/null || echo "${SUCCESS_RATE_CONSTRAINTS_ENABLED}")
    SUCCESS_RATE_WINDOW_SIZE=$(echo "$config_json" | jq -r '.window_size // '"${SUCCESS_RATE_WINDOW_SIZE}" 2>/dev/null || echo "${SUCCESS_RATE_WINDOW_SIZE}")
    SUCCESS_RATE_MIN_DATA_POINTS=$(echo "$config_json" | jq -r '.min_data_points // '"${SUCCESS_RATE_MIN_DATA_POINTS}" 2>/dev/null || echo "${SUCCESS_RATE_MIN_DATA_POINTS}")
    SUCCESS_RATE_DATA_FRESHNESS_HOURS=$(echo "$config_json" | jq -r '.data_freshness_hours // '"${SUCCESS_RATE_DATA_FRESHNESS_HOURS}" 2>/dev/null || echo "${SUCCESS_RATE_DATA_FRESHNESS_HOURS}")
    SUCCESS_RATE_CONSTRAINT_THRESHOLD_LOW=$(echo "$config_json" | jq -r '.constraint_threshold_low // '"${SUCCESS_RATE_CONSTRAINT_THRESHOLD_LOW}" 2>/dev/null || echo "${SUCCESS_RATE_CONSTRAINT_THRESHOLD_LOW}")
    SUCCESS_RATE_CONSTRAINT_THRESHOLD_MED=$(echo "$config_json" | jq -r '.constraint_threshold_med // '"${SUCCESS_RATE_CONSTRAINT_THRESHOLD_MED}" 2>/dev/null || echo "${SUCCESS_RATE_CONSTRAINT_THRESHOLD_MED}")
    SUCCESS_RATE_RECOVERY_THRESHOLD=$(echo "$config_json" | jq -r '.recovery_threshold // '"${SUCCESS_RATE_RECOVERY_THRESHOLD}" 2>/dev/null || echo "${SUCCESS_RATE_RECOVERY_THRESHOLD}")
    SUCCESS_RATE_MIN_COMPLEXITY_ALLOWED=$(echo "$config_json" | jq -r '.min_complexity_always_allowed // '"${SUCCESS_RATE_MIN_COMPLEXITY_ALLOWED}" 2>/dev/null || echo "${SUCCESS_RATE_MIN_COMPLEXITY_ALLOWED}")
    SUCCESS_RATE_DEFER_COMPLEXITY_HIGH=$(echo "$config_json" | jq -r '.defer_complexity_high // '"${SUCCESS_RATE_DEFER_COMPLEXITY_HIGH}" 2>/dev/null || echo "${SUCCESS_RATE_DEFER_COMPLEXITY_HIGH}")
    SUCCESS_RATE_DEFER_COMPLEXITY_MED=$(echo "$config_json" | jq -r '.defer_complexity_med // '"${SUCCESS_RATE_DEFER_COMPLEXITY_MED}" 2>/dev/null || echo "${SUCCESS_RATE_DEFER_COMPLEXITY_MED}")
}

# ═══════════════════════════════════════════════════════════════════════════════
# CORE FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# Compute rolling success rate from events.jsonl
# Returns: JSON object with { success_rate, samples, age_hours, freshness_ok }
compute_rolling_success_rate() {
    local events_file="${1:-${HOME}/.shipwright/events.jsonl}"

    # Cold-start: if no events exist, assume 100% success (no constraints)
    if [[ ! -f "$events_file" ]]; then
        echo '{"success_rate":100,"samples":0,"age_hours":0,"freshness_ok":true}'
        return 0
    fi

    # Extract pipeline.completed events, reverse time order (newest last)
    local outcomes
    outcomes=$(grep '"type":"pipeline.completed"' "$events_file" 2>/dev/null | tail -"${SUCCESS_RATE_WINDOW_SIZE}" || echo "")

    if [[ -z "$outcomes" ]]; then
        # No outcomes recorded yet
        echo '{"success_rate":100,"samples":0,"age_hours":0,"freshness_ok":true}'
        return 0
    fi

    # Count successes and total samples
    local total=0
    local successes=0
    local oldest_ts_epoch=0

    while IFS= read -r line; do
        ((total++)) || true

        # Extract result field
        local result
        result=$(echo "$line" | jq -r '.result // "unknown"' 2>/dev/null || echo "unknown")

        # Extract timestamp for freshness check
        local ts_epoch
        ts_epoch=$(echo "$line" | jq -r '.ts_epoch // 0' 2>/dev/null || echo "0")

        if [[ "$ts_epoch" -gt 0 && ("$oldest_ts_epoch" -eq 0 || "$ts_epoch" -lt "$oldest_ts_epoch") ]]; then
            oldest_ts_epoch=$ts_epoch
        fi

        [[ "$result" == "success" ]] && ((successes++)) || true
    done <<< "$outcomes"

    # Calculate success rate
    local success_rate=0
    if [[ $total -gt 0 ]]; then
        success_rate=$(( (successes * 100) / total ))
    fi

    # Check data freshness
    local now_epoch
    now_epoch=$(date +%s 2>/dev/null || echo "0")
    local age_hours=0
    local freshness_ok=true

    if [[ $oldest_ts_epoch -gt 0 && $now_epoch -gt 0 ]]; then
        age_hours=$(( (now_epoch - oldest_ts_epoch) / 3600 ))
        if [[ $age_hours -gt "${SUCCESS_RATE_DATA_FRESHNESS_HOURS}" ]]; then
            freshness_ok=false
        fi
    fi

    # Determine if we have enough data points
    local enough_data="false"
    [[ $total -ge "${SUCCESS_RATE_MIN_DATA_POINTS}" ]] && enough_data="true"

    # If data is stale or insufficient, return 100% success (no constraints)
    if [[ "$freshness_ok" == "false" || "$enough_data" == "false" ]]; then
        echo "{\"success_rate\":100,\"samples\":${total},\"age_hours\":${age_hours},\"freshness_ok\":true}"
        return 0
    fi

    # Return actual success rate with metadata
    jq -n \
        --argjson success_rate "$success_rate" \
        --argjson samples "$total" \
        --argjson age_hours "$age_hours" \
        --argjson freshness_ok "${freshness_ok,,}" \
        '{success_rate: $success_rate, samples: $samples, age_hours: $age_hours, freshness_ok: $freshness_ok}'
}

# Get current constraint level (none/moderate/heavy) with hysteresis
# Returns: JSON object with { level, reason, should_defer }
get_constraint_level() {
    local success_rate="${1:-100}"  # Default to 100% if not provided

    # Load current tuning state to apply hysteresis
    local current_level="none"
    local last_constraint_level=""

    if [[ -f "$CONSTRAINT_TUNING_FILE" ]]; then
        last_constraint_level=$(jq -r '.last_constraint_level // "none"' "$CONSTRAINT_TUNING_FILE" 2>/dev/null || echo "none")
        current_level="$last_constraint_level"
    fi

    # Hysteresis: separate thresholds for entering/exiting each state
    # Enter HIGH constraints if <40%, exit only if >70%
    if [[ $success_rate -lt "${SUCCESS_RATE_CONSTRAINT_THRESHOLD_LOW}" ]]; then
        current_level="heavy"
    elif [[ $success_rate -ge "${SUCCESS_RATE_RECOVERY_THRESHOLD}" ]]; then
        current_level="none"
    elif [[ $success_rate -lt "${SUCCESS_RATE_CONSTRAINT_THRESHOLD_MED}" ]]; then
        # Check if we're already moderate or heavy; if we're none and between 40-60%, stay in none
        if [[ "$last_constraint_level" == "heavy" || "$last_constraint_level" == "moderate" || $success_rate -lt "${SUCCESS_RATE_CONSTRAINT_THRESHOLD_LOW}" ]]; then
            current_level="moderate"
        fi
    fi

    local should_defer=false
    local reason="success rate is ${success_rate}%"

    [[ "$current_level" != "none" ]] && should_defer=true

    # Output JSON
    jq -n \
        --arg level "$current_level" \
        --argjson should_defer "${should_defer,,}" \
        --arg reason "$reason" \
        '{level: $level, should_defer: $should_defer, reason: $reason}'
}

# Check if an issue should be deferred based on complexity and constraint level
# Args: complexity_score constraint_level
# Returns: JSON object with { should_defer, reason }
should_defer_issue() {
    local complexity="${1:-0}"
    local constraint_level="${2:-none}"

    local should_defer="false"
    local reason=""

    # Always allow minimum complexity through
    if [[ $complexity -le "${SUCCESS_RATE_MIN_COMPLEXITY_ALLOWED}" ]]; then
        echo '{"should_defer":false,"reason":"complexity within always-allowed threshold"}'
        return 0
    fi

    # Apply constraint thresholds based on level
    case "$constraint_level" in
        heavy)
            if [[ $complexity -gt "${SUCCESS_RATE_DEFER_COMPLEXITY_HIGH}" ]]; then
                should_defer="true"
                reason="heavy constraints: complexity ${complexity} > ${SUCCESS_RATE_DEFER_COMPLEXITY_HIGH}"
            fi
            ;;
        moderate)
            if [[ $complexity -gt "${SUCCESS_RATE_DEFER_COMPLEXITY_MED}" ]]; then
                should_defer="true"
                reason="moderate constraints: complexity ${complexity} > ${SUCCESS_RATE_DEFER_COMPLEXITY_MED}"
            fi
            ;;
        none)
            should_defer="false"
            reason="no constraints active"
            ;;
    esac

    jq -n \
        --argjson should_defer "${should_defer,,}" \
        --arg reason "$reason" \
        '{should_defer: $should_defer, reason: $reason}'
}

# Get iteration cap based on constraint level
# Returns: integer iteration count (e.g., 10, 15, 20)
get_iteration_cap() {
    local constraint_level="${1:-none}"

    case "$constraint_level" in
        heavy)
            echo 10  # Aggressive cap when success rate is very low
            ;;
        moderate)
            echo 15  # Moderate cap
            ;;
        none)
            echo 20  # Default (no constraint)
            ;;
        *)
            echo 20
            ;;
    esac
}

# Downgrade pipeline template based on constraint level
# Args: current_template constraint_level
# Returns: string (template name)
constrain_template() {
    local current_template="${1:-standard}"
    local constraint_level="${2:-none}"

    case "$constraint_level" in
        heavy)
            # Downgrade complex templates to fast or hotfix
            case "$current_template" in
                full|enterprise|deployed|autonomous)
                    echo "hotfix"
                    ;;
                standard)
                    echo "fast"
                    ;;
                *)
                    echo "$current_template"
                    ;;
            esac
            ;;
        moderate)
            # Downgrade only the most complex templates
            case "$current_template" in
                full|enterprise|deployed)
                    echo "standard"
                    ;;
                autonomous)
                    echo "standard"
                    ;;
                *)
                    echo "$current_template"
                    ;;
            esac
            ;;
        none)
            # No downgrade
            echo "$current_template"
            ;;
        *)
            echo "$current_template"
            ;;
    esac
}

# Save constraint state (for hysteresis on next run)
# Args: constraint_level
save_constraint_state() {
    local constraint_level="${1:-none}"

    mkdir -p "$(dirname "$CONSTRAINT_TUNING_FILE")"

    # Atomic write: write to temp file, then move
    local tmp_file="${CONSTRAINT_TUNING_FILE}.tmp.$$"

    jq -n \
        --arg level "$constraint_level" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{last_constraint_level: $level, last_updated: $ts}' > "$tmp_file"

    mv "$tmp_file" "$CONSTRAINT_TUNING_FILE"
}

# Emit an event for observability
# Args: event_type key=value pairs...
_emit_constraint_event() {
    local event_type="$1"
    shift

    # Build JSON payload
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"${event_type}\""

    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local val="${1#*=}"
        # Escape JSON values
        val=$(echo "$val" | jq -Rs '.')
        payload="${payload},\"${key}\":${val}"
        shift
    done

    payload="${payload}}"

    # Append to events log
    mkdir -p "${HOME}/.shipwright"
    echo "$payload" >> "${HOME}/.shipwright/events.jsonl"
}

# Public wrapper: compute success rate, get constraint level, emit event
# Returns: JSON with { success_rate, constraint_level, should_defer }
analyze_success_rate_constraints() {
    local events_file="${1:-${HOME}/.shipwright/events.jsonl}"
    local config_file="${2:-./.claude/daemon-config.json}"

    # Load config first
    _load_constraint_config "$config_file"

    # If disabled, return empty constraints
    if [[ "$SUCCESS_RATE_CONSTRAINTS_ENABLED" != "true" ]]; then
        echo '{"enabled":false,"success_rate":100,"constraint_level":"none","should_defer":false}'
        return 0
    fi

    # Compute rolling success rate
    local rate_data
    rate_data=$(compute_rolling_success_rate "$events_file")
    local success_rate
    success_rate=$(echo "$rate_data" | jq -r '.success_rate' 2>/dev/null || echo "100")

    # Get constraint level with hysteresis
    local level_data
    level_data=$(get_constraint_level "$success_rate")
    local constraint_level
    constraint_level=$(echo "$level_data" | jq -r '.level' 2>/dev/null || echo "none")
    local should_defer
    should_defer=$(echo "$level_data" | jq -r '.should_defer' 2>/dev/null || echo "false")

    # Save state for next run
    save_constraint_state "$constraint_level"

    # Emit event for observability
    _emit_constraint_event "constraint.analysis" \
        "success_rate=${success_rate}" \
        "constraint_level=${constraint_level}" \
        "should_defer=${should_defer}"

    # Return result
    jq -n \
        --argjson enabled true \
        --argjson success_rate "$success_rate" \
        --arg constraint_level "$constraint_level" \
        --argjson should_defer "${should_defer,,}" \
        '{enabled: $enabled, success_rate: $success_rate, constraint_level: $constraint_level, should_defer: $should_defer}'
}

# Initialize constraints on load (if enabled)
_load_constraint_config "./.claude/daemon-config.json" || true
