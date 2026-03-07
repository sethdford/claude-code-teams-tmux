#!/usr/bin/env bash
# intelligence-stream.sh — Real-time intelligence event streaming to active pipelines
# Sourced by sw-pipeline.sh and sw-loop.sh. Provides polling, formatting, and state management
# for intelligence events (intelligence.*, prediction.*, discovery.*) consumed at iteration boundaries.

[[ -n "${_INTELLIGENCE_STREAM_LOADED:-}" ]] && return 0
_INTELLIGENCE_STREAM_LOADED=1

# ─── Configuration ────────────────────────────────────────────────────────────
INTEL_STREAM_MAX_EVENTS="${INTEL_STREAM_MAX_EVENTS:-10}"
INTEL_STREAM_EVENT_PREFIXES="intelligence. prediction. discovery."

# ─── Poll for new intelligence events ────────────────────────────────────────
# Args: pipeline_id (string), last_seen_id (integer, default 0)
# Returns: JSON array on stdout, "[]" if none or on error
poll_intelligence_events() {
    local pipeline_id="${1:-}"
    local last_seen_id="${2:-0}"
    local max_events="${INTEL_STREAM_MAX_EVENTS}"

    # Validate last_seen_id is numeric
    [[ ! "$last_seen_id" =~ ^[0-9]+$ ]] && last_seen_id=0

    # Try SQLite first
    if type db_available >/dev/null 2>&1 && db_available 2>/dev/null; then
        local query="SELECT id, ts, ts_epoch, type, source, correlation_id, payload FROM events WHERE id > ${last_seen_id} AND (type LIKE 'intelligence.%' OR type LIKE 'prediction.%' OR type LIKE 'discovery.%')"
        if [[ -n "$pipeline_id" ]]; then
            query="${query} AND (payload LIKE '%${pipeline_id}%' OR correlation_id LIKE '%${pipeline_id}%')"
        fi
        query="${query} ORDER BY id ASC LIMIT ${max_events};"

        local result
        result=$(sqlite3 -json "${DB_FILE:-${HOME}/.shipwright/shipwright.db}" "$query" 2>/dev/null || echo "")
        if [[ -n "$result" && "$result" != "[]" ]]; then
            echo "$result"
            return 0
        fi
    fi

    # Fallback: grep JSONL
    local events_file="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"
    if [[ -f "$events_file" ]]; then
        local matched="["
        local count=0
        local first=true
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local etype
            etype=$(echo "$line" | jq -r '.type // ""' 2>/dev/null) || continue
            # Check event type prefix
            local is_intel=false
            case "$etype" in
                intelligence.*|prediction.*|discovery.*) is_intel=true ;;
            esac
            [[ "$is_intel" != "true" ]] && continue

            # Pipeline filter (if provided)
            if [[ -n "$pipeline_id" ]]; then
                echo "$line" | grep -qF "$pipeline_id" || continue
            fi

            if [[ "$first" == "true" ]]; then
                first=false
            else
                matched="${matched},"
            fi
            matched="${matched}${line}"
            count=$((count + 1))
            [[ "$count" -ge "$max_events" ]] && break
        done < "$events_file"
        matched="${matched}]"

        if [[ "$count" -gt 0 ]]; then
            echo "$matched"
            return 0
        fi
    fi

    echo "[]"
    return 0
}

# ─── Format intelligence events into actionable context ──────────────────────
# Args: events_json (JSON array string)
# Returns: Markdown string on stdout grouped by category
format_intelligence_context() {
    local events_json="${1:-[]}"

    # Validate JSON
    echo "$events_json" | jq empty 2>/dev/null || { echo ""; return 0; }

    local event_count
    event_count=$(echo "$events_json" | jq 'length' 2>/dev/null || echo "0")
    [[ "$event_count" -eq 0 ]] && { echo ""; return 0; }

    local output=""

    # Group predictions
    local predictions
    predictions=$(echo "$events_json" | jq -r '[.[] | select(.type | startswith("prediction."))] | .[] | "- [\(.type)]: \(.payload // .source // "signal detected")"' 2>/dev/null || true)
    if [[ -n "$predictions" ]]; then
        output="${output}**Predictions:**
${predictions}
"
    fi

    # Group intelligence signals
    local intel_signals
    intel_signals=$(echo "$events_json" | jq -r '[.[] | select(.type | startswith("intelligence."))] | .[] | "- [\(.type)]: \(.payload // .source // "signal detected")"' 2>/dev/null || true)
    if [[ -n "$intel_signals" ]]; then
        output="${output}**Intelligence:**
${intel_signals}
"
    fi

    # Group discoveries
    local discoveries
    discoveries=$(echo "$events_json" | jq -r '[.[] | select(.type | startswith("discovery."))] | .[] | "- [\(.type)]: \(.payload // .source // "signal detected")"' 2>/dev/null || true)
    if [[ -n "$discoveries" ]]; then
        output="${output}**Discoveries:**
${discoveries}
"
    fi

    echo "$output"
}

# ─── Save stream state atomically ────────────────────────────────────────────
# Args: pipeline_id (string), last_seen_id (integer)
# Returns: 0 on success, 1 on failure
save_stream_state() {
    local pipeline_id="${1:-default}"
    local last_seen_id="${2:-0}"
    local state_dir="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
    local state_file="${state_dir}/intelligence-stream-state.json"

    [[ -d "$state_dir" ]] || mkdir -p "$state_dir"

    local tmp_file
    tmp_file="$(mktemp "${state_dir}/intel-state-XXXXXX.tmp" 2>/dev/null || mktemp /tmp/intel-state-XXXXXX.tmp)"

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"

    # Use jq for safe JSON construction
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg pid "$pipeline_id" --arg lid "$last_seen_id" --arg ts "$ts" \
            '{pipeline_id: $pid, last_seen_id: ($lid | tonumber), updated_at: $ts}' > "$tmp_file" 2>/dev/null
    else
        echo "{\"pipeline_id\":\"${pipeline_id}\",\"last_seen_id\":${last_seen_id},\"updated_at\":\"${ts}\"}" > "$tmp_file"
    fi

    mv "$tmp_file" "$state_file" 2>/dev/null || { rm -f "$tmp_file"; return 1; }
    return 0
}

# ─── Load stream state ───────────────────────────────────────────────────────
# Args: pipeline_id (string)
# Returns: last_seen_id (integer) on stdout, "0" if no state exists
load_stream_state() {
    local pipeline_id="${1:-default}"
    local state_dir="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
    local state_file="${state_dir}/intelligence-stream-state.json"

    if [[ -f "$state_file" ]]; then
        local last_seen_id
        last_seen_id=$(jq -r '.last_seen_id // 0' "$state_file" 2>/dev/null || echo "0")
        # Validate numeric
        [[ "$last_seen_id" =~ ^[0-9]+$ ]] && echo "$last_seen_id" && return 0
    fi

    echo "0"
    return 0
}
