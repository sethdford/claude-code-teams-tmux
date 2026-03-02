#!/usr/bin/env bash
# Stage duration history for pipeline progress estimation
# Stores historical stage durations to estimate remaining time

STAGE_DURATIONS_FILE="${REPO_DIR:-$HOME/.shipwright}/stage-durations.json"

# Load stage durations from file
load_stage_durations() {
    if [[ -f "$STAGE_DURATIONS_FILE" ]]; then
        cat "$STAGE_DURATIONS_FILE"
    else
        echo "{}"
    fi
}

# Save stage duration to history
save_stage_duration() {
    local stage_id="$1"
    local duration_sec="$2"
    
    [[ -z "$stage_id" || -z "$duration_sec" ]] && return 1
    
    mkdir -p "$(dirname "$STAGE_DURATIONS_FILE")" 2>/dev/null || true
    
    local current
    current=$(load_stage_durations)
    
    # Add new duration to history (keep last 20)
    local stage_history
    stage_history=$(echo "$current" | jq --arg stage "$stage_id" --arg dur "$duration_sec" \
        '($stage | if . == null then {} else . end) as $s | 
         if has($stage) then .[$stage] += [$dur | tonumber] | .[$stage] = .[$stage][-20:] 
         else .[$stage] = [$dur | tonumber] 
         end' 2>/dev/null || echo "{}")
    
    echo "$stage_history" > "$STAGE_DURATIONS_FILE"
}

# Get average duration for a stage
get_avg_stage_duration() {
    local stage_id="$1"
    local current
    current=$(load_stage_durations)
    
    local avg
    avg=$(echo "$current" | jq --arg stage "$stage_id" \
        'if has($stage) and ($stage | length) > 0 then 
            (reduce .[$stage][] as $item (0; . + $item)) / (.[$stage] | length) 
         else null 
         end' 2>/dev/null || echo "null")
    
    echo "$avg"
}

# Estimate remaining time based on completed and pending stages
estimate_remaining_time() {
    local current_stage="$1"
    local completed_stages="$2"  # JSON array of completed stage IDs
    local total_stages="$3"
    
    local total_avg=0
    local remaining_count=0
    
    # Get all stages from pipeline config
    local all_stages
    all_stages=$(echo '{"stages":[]}' | jq '.stages')
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "$PIPELINE_CONFIG" ]]; then
        all_stages=$(jq '.stages[] | .id' "$PIPELINE_CONFIG" 2>/dev/null || echo '[]')
    fi
    
    # Calculate remaining stages
    local remaining_stages=()
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        local found=0
        while IFS= read -r comp; do
            [[ "$comp" == "$stage" ]] && found=1
        done <<< "$completed_stages"
        if [[ $found -eq 0 ]]; then
            remaining_stages+=("$stage")
        fi
    done <<< "$all_stages"
    
    # Sum average durations for remaining stages
    for stage in "${remaining_stages[@]}"; do
        local avg
        avg=$(get_avg_stage_duration "$stage")
        if [[ "$avg" != "null" && -n "$avg" ]]; then
            total_avg=$(echo "$total_avg + $avg" | bc 2>/dev/null || echo "$total_avg")
        fi
    done
    
    echo "$total_avg"
}

# Format duration in human readable format
format_duration_short() {
    local secs="$1"
    if [[ -z "$secs" || "$secs" == "0" || "$secs" == "null" ]]; then
        echo "~0s"
        return
    fi
    
    if [[ "$secs" -lt 60 ]]; then
        echo "~${secs}s"
    elif [[ "$secs" -lt 3600 ]]; then
        local mins=$((secs / 60))
        echo "~${mins}min"
    else
        local hours=$((secs / 3600))
        local mins=$(((secs % 3600) / 60))
        echo "~${hours}h${mins}m"
    fi
}

# Build progress display string: "Stage 3/12 (build) — ~32min remaining, $2.47 spent"
build_progress_display() {
    local current_stage="$1"
    local stage_index="$2"
    local total_stages="$3"
    local elapsed_sec="$4"
    local cost_usd="$5"
    
    local remaining_sec
    remaining_sec=$(estimate_remaining_time "$current_stage" "[]" "$total_stages")
    
    local remaining_fmt
    remaining_fmt=$(format_duration_short "$remaining_sec")
    
    local stage_name
    stage_name=$(get_stage_description "$current_stage" 2>/dev/null || echo "$current_stage")
    
    echo "Stage ${stage_index}/${total_stages} (${stage_name}) — ${remaining_fmt} remaining, \$${cost_usd:-0.00} spent"
}
