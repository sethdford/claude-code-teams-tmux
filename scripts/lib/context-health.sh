#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright context-health — Real-time context window health monitor      ║
# ║  Per-iteration tick: estimate → check → snapshot → emit → act            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_CONTEXT_HEALTH_LOADED:-}" ]] && return 0
_CONTEXT_HEALTH_LOADED=1

# Require the base budget library (degrade gracefully if missing).
if [[ "$(type -t context_budget_estimate 2>/dev/null)" != "function" ]]; then
    _CH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=context-budget.sh
    [[ -f "$_CH_SCRIPT_DIR/context-budget.sh" ]] && source "$_CH_SCRIPT_DIR/context-budget.sh" 2>/dev/null || true
fi

# ─── Threshold config (percentages) ─────────────────────────────────────────
# loop.context_alert_threshold     → yellow (default 60)
# loop.context_compress_threshold  → red    (default 80)
# loop.context_restart_threshold   → critical (default 90)
context_health_thresholds() {
    local alert compress restart
    if [[ "$(type -t _smart_int 2>/dev/null)" == "function" ]]; then
        alert=$(_smart_int "loop.context_alert_threshold" 60)
        compress=$(_smart_int "loop.context_compress_threshold" 80)
        restart=$(_smart_int "loop.context_restart_threshold" 90)
    else
        alert=60; compress=80; restart=90
    fi
    # Sanity: ensure monotonic ordering
    [[ "$alert" =~ ^[0-9]+$ ]] || alert=60
    [[ "$compress" =~ ^[0-9]+$ ]] || compress=80
    [[ "$restart" =~ ^[0-9]+$ ]] || restart=90
    echo "$alert $compress $restart"
}

# Classify utilization against thresholds.
# Args: utilization_percent alert_thresh compress_thresh restart_thresh
# Echo: status\taction
context_health_classify() {
    local util="${1:-0}" a="${2:-60}" c="${3:-80}" r="${4:-90}"
    [[ "$util" =~ ^[0-9]+$ ]] || util=0
    if (( util >= r )); then
        echo "critical	restart_session"
    elif (( util >= c )); then
        echo "red	compress"
    elif (( util >= a )); then
        echo "yellow	alert"
    else
        echo "green	continue"
    fi
}

# Read previous status from snapshot for transition detection.
_context_health_prev_status() {
    local snapshot="$1"
    [[ -f "$snapshot" ]] || { echo "none"; return 0; }
    if command -v jq >/dev/null 2>&1; then
        jq -r '.status // "none"' "$snapshot" 2>/dev/null || echo "none"
    else
        echo "none"
    fi
}

# Write atomic snapshot file.
_context_health_write_snapshot() {
    local snapshot="$1" json="$2"
    local dir tmp
    dir="$(dirname "$snapshot")"
    mkdir -p "$dir" 2>/dev/null || true
    tmp=$(mktemp "${dir}/context-health.json.tmp.XXXXXX" 2>/dev/null) || tmp="/tmp/context-health-$$.tmp"
    printf '%s\n' "$json" > "$tmp" 2>/dev/null || return 1
    mv "$tmp" "$snapshot" 2>/dev/null || return 1
    return 0
}

# ─── Main tick ───────────────────────────────────────────────────────────────
# Runs one health sample for the current iteration.
# Args: prompt_content artifacts_dir iteration [job_id]
# Echoes: single-line JSON {status, action, utilization_percent, iteration, transition}
# Side effects:
#   - writes $artifacts_dir/context-health.json (snapshot)
#   - emits 'context_health' event on status transition (if emit_event exists)
# Returns: 0 always (graceful degradation on missing deps)
context_health_tick() {
    local prompt="${1:-}"
    local artifacts_dir="${2:-./.claude/pipeline-artifacts}"
    local iteration="${3:-0}"
    local job_id="${4:-${PIPELINE_JOB_ID:-loop-$$}}"

    # Graceful degradation: estimator missing → stub snapshot, no crash.
    if [[ "$(type -t context_budget_estimate 2>/dev/null)" != "function" ]]; then
        local stub='{"status":"unknown","action":"none","utilization_percent":0,"iteration":'"$iteration"',"transition":false,"reason":"estimator_unavailable"}'
        _context_health_write_snapshot "$artifacts_dir/context-health.json" "$stub" || true
        echo "$stub"
        return 0
    fi

    mkdir -p "$artifacts_dir" 2>/dev/null || true

    # 1. Estimate (existing library — chars/4 heuristic).
    local estimate
    estimate=$(context_budget_estimate "$prompt" "$artifacts_dir" 2>/dev/null || echo '{}')

    # 2. Extract utilization.
    local util=0
    if command -v jq >/dev/null 2>&1; then
        util=$(echo "$estimate" | jq -r '.utilization_percent // 0' 2>/dev/null || echo 0)
        [[ "$util" =~ ^[0-9]+$ ]] || util=0
    fi

    # 3. Read thresholds and classify.
    local thresholds a c r
    thresholds=$(context_health_thresholds)
    a=$(echo "$thresholds" | awk '{print $1}')
    c=$(echo "$thresholds" | awk '{print $2}')
    r=$(echo "$thresholds" | awk '{print $3}')

    local classification status action
    classification=$(context_health_classify "$util" "$a" "$c" "$r")
    status=$(echo "$classification" | awk -F'\t' '{print $1}')
    action=$(echo "$classification" | awk -F'\t' '{print $2}')

    # 4. Detect transition.
    local snapshot="$artifacts_dir/context-health.json"
    local prev_status
    prev_status=$(_context_health_prev_status "$snapshot")
    local transition="false"
    if [[ "$prev_status" != "$status" && "$prev_status" != "none" ]]; then
        transition="true"
    fi

    # 5. Build and write snapshot.
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    local snap_json
    snap_json=$(cat <<EOF
{"status":"$status","action":"$action","utilization_percent":$util,"iteration":$iteration,"alert_threshold":$a,"compress_threshold":$c,"restart_threshold":$r,"prev_status":"$prev_status","transition":$transition,"job_id":"$job_id","timestamp":"$ts"}
EOF
)
    _context_health_write_snapshot "$snapshot" "$snap_json" || true

    # 6. Emit event on transition OR non-green (for dashboards/analysis).
    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        if [[ "$transition" == "true" || "$status" != "green" ]]; then
            emit_event "context_health" \
                "iteration=$iteration" \
                "status=$status" \
                "action=$action" \
                "utilization=$util" \
                "prev_status=$prev_status" \
                "transition=$transition" \
                "job_id=$job_id" 2>/dev/null || true
        fi
    fi

    echo "$snap_json"
    return 0
}

# Decide whether the loop should escalate to session restart.
# Args: snapshot_json_or_file
# Returns: 0 if restart needed, 1 otherwise.
context_health_should_restart() {
    local input="${1:-}"
    local json=""
    if [[ -f "$input" ]]; then
        json=$(cat "$input" 2>/dev/null || echo "{}")
    else
        json="$input"
    fi
    [[ -z "$json" ]] && return 1
    local status=""
    if command -v jq >/dev/null 2>&1; then
        status=$(echo "$json" | jq -r '.status // ""' 2>/dev/null || echo "")
    fi
    [[ "$status" == "critical" ]] && return 0
    return 1
}

return 0
