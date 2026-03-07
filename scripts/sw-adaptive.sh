#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright adaptive — data-driven pipeline tuning                       ║
# ║  Replace static defaults with learned values from historical runs         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# DB layer for dual-read (SQLite + JSONL fallback)
# shellcheck source=sw-db.sh
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# ─── Paths ─────────────────────────────────────────────────────────────────
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"
MODELS_FILE="${HOME}/.shipwright/adaptive-models.json"
REPO_DIR="${PWD}"

# ─── Default Thresholds ─────────────────────────────────────────────────────
MIN_CONFIDENCE_SAMPLES=10
MED_CONFIDENCE_SAMPLES=50
MIN_TIMEOUT=60
MAX_TIMEOUT=7200
MIN_ITERATIONS=2
MAX_ITERATIONS=50
MIN_POLL_INTERVAL=10
MAX_POLL_INTERVAL=300
MIN_COVERAGE=0
MAX_COVERAGE=100

# ─── JSON Helper: Percentile ────────────────────────────────────────────────
# Compute P-th percentile of sorted numeric array (bash + jq)
# Usage: percentile "[1, 5, 10, 15, 20]" 95
percentile() {
    local arr="$1"
    local p="$2"
    jq -n --arg arr "$arr" --arg p "$p" '
        ($arr | fromjson | map(tonumber?) | sort) as $sorted |
        ($sorted | length) as $len |
        ((($p | tonumber) / 100) * ($len - 1) | floor) as $idx |
        if $len == 0 then null
        elif $idx >= $len - 1 then $sorted[-1]
        else
            ($sorted[$idx] + $sorted[$idx + 1]) / 2
        end
    '
}

# ─── JSON Helper: Mean ──────────────────────────────────────────────────────
mean() {
    local arr="$1"
    jq -n --arg arr "$arr" '
        ($arr | fromjson | add / length)
    '
}

# ─── JSON Helper: Median ───────────────────────────────────────────────────
median() {
    local arr="$1"
    percentile "$arr" 50
}

# ─── JSON Helper: Stddev ───────────────────────────────────────────────────
stddev() {
    local arr="$1"
    jq -n --arg arr "$arr" '
        ($arr | fromjson) as $data |
        ($data | add / length) as $mean |
        (($data | map(. - $mean | . * .) | add) / ($data | length)) | sqrt
    '
}

# ─── Determine Confidence Level ─────────────────────────────────────────────
confidence_level() {
    local samples="$1"
    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "low"
    elif [[ "$samples" -lt "$MED_CONFIDENCE_SAMPLES" ]]; then
        echo "medium"
    else
        echo "high"
    fi
}

# ─── Load Models from Cache ─────────────────────────────────────────────────
load_models() {
    if [[ -f "$MODELS_FILE" ]]; then
        cat "$MODELS_FILE"
    else
        echo '{}'
    fi
}

# ─── Save Models to Cache ───────────────────────────────────────────────────
save_models() {
    local models="$1"
    mkdir -p "${HOME}/.shipwright"
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-adaptive-models.XXXXXX")
    echo "$models" > "$tmp_file"
    mv "$tmp_file" "$MODELS_FILE"
}

# ─── Query events by field and value ────────────────────────────────────────
query_events() {
    local field="$1"
    local value="$2"
    db_query_events "" 5000 | jq "
        map(select(.${field} == \"${value}\")) | map(.duration_s, .iterations, .model, .template, .score, .coverage // empty) | flatten
    " 2>/dev/null || echo "[]"
}

# ─── Get Timeout Recommendation ─────────────────────────────────────────────
# Uses stage.completed events (pipeline emits duration_s in seconds)
get_timeout() {
    local stage="${1:-build}"
    local repo="${2:-.}"
    local default="${3:-1800}"

    # Query events for this stage (pipeline emits stage.completed with duration_s)
    local durations
    durations=$(db_query_events "" 5000 | jq "
        map(select(.type == \"stage.completed\" and .stage == \"${stage}\") | .duration_s // empty) |
        map(select(. > 0 and (. | type) == \"number\")) | sort
    " 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$durations" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    # Compute P95 + 20% buffer
    local p95
    p95=$(percentile "$durations" 95)
    local timeout
    timeout=$(echo "$p95 * 1.2" | bc 2>/dev/null | cut -d. -f1)

    # Apply safety bounds
    if [[ "$timeout" -lt "$MIN_TIMEOUT" ]]; then timeout="$MIN_TIMEOUT"; fi
    if [[ "$timeout" -gt "$MAX_TIMEOUT" ]]; then timeout="$MAX_TIMEOUT"; fi

    echo "$timeout"
}

# ─── Get Iterations Recommendation ─────────────────────────────────────────
# Uses pipeline.completed (iterations = self_heal_count + 1) or prediction.validated (actual_iterations)
get_iterations() {
    local complexity="${1:-5}"
    local stage="${2:-build}"
    local default="${3:-10}"

    # Query pipeline.completed iterations or prediction.validated actual_iterations
    local iterations_data
    iterations_data=$(db_query_events "" 5000 | jq "
        (
            map(select(.type == \"pipeline.completed\") | ((.self_heal_count // 0 | tonumber) + 1)) |
            map(select(. > 0))
        ) + (
            map(select(.type == \"prediction.validated\" and .actual_iterations != null) | .actual_iterations | tonumber) |
            map(select(. > 0))
        ) |
        map(select(. > 0))
    " 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$iterations_data" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    # Compute mean
    local mean_iters
    mean_iters=$(mean "$iterations_data")
    local result
    result=$(echo "$mean_iters" | cut -d. -f1)

    # Apply safety bounds
    if [[ "$result" -lt "$MIN_ITERATIONS" ]]; then result="$MIN_ITERATIONS"; fi
    if [[ "$result" -gt "$MAX_ITERATIONS" ]]; then result="$MAX_ITERATIONS"; fi

    echo "$result"
}

# ─── Get Model Recommendation ───────────────────────────────────────────────
# Uses model.outcome (pipeline emits .model, .success; no exit_code/token_cost)
get_model() {
    local stage="${1:-build}"
    local default="${2:-opus}"

    # Query model.outcome by stage: success=true maps to exit_code=0; estimate cost from model name
    local model_success
    model_success=$(db_query_events "" 5000 | jq "
        map(select(.type == \"model.outcome\" and (.stage == \"${stage}\" or .stage == null))) |
        group_by(.model) |
        map({
            model: .[0].model,
            total: length,
            success: map(select(.success == true or .success == \"true\")) | length,
            cost: (.[0].model | if . == \"haiku\" then 1 elif . == \"sonnet\" then 2 else 3 end)
        }) |
        map(select(.total >= 5)) |
        map(select((.success / .total) > 0.9)) |
        sort_by(.cost) |
        .[0].model // \"$default\"
    " 2>/dev/null || echo "\"$default\"")

    echo "$model_success" | tr -d '"'
}

# ─── Get Team Size Recommendation ───────────────────────────────────────────
# Pipeline does not emit team_size; use pipeline.started unique agents if available
get_team_size() {
    local complexity="${1:-5}"
    local default="${2:-2}"

    # team_size not emitted by pipeline; return default when no data
    local team_data
    team_data=$(db_query_events "" 5000 | jq "
        map(select(.team_size != null) | .team_size) |
        map(select(. > 0))
    " 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$team_data" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    local mean_team
    mean_team=$(mean "$team_data")
    local result
    result=$(echo "$mean_team" | cut -d. -f1)

    # Bounds: 1-8 agents
    if [[ "$result" -lt 1 ]]; then result=1; fi
    if [[ "$result" -gt 8 ]]; then result=8; fi

    echo "$result"
}

# ─── Get Template Recommendation ────────────────────────────────────────────
# Uses template.outcome (pipeline emits .template, .success); .complexity if present
get_template() {
    local complexity="${1:-5}"
    local default="${2:-standard}"

    # Find most successful template (template.outcome has .template, .success; .complexity optional)
    local template
    template=$(db_query_events "" 5000 | jq "
        map(select(.type == \"template.outcome\" and .template != null)) |
        group_by(.template) |
        map({
            template: .[0].template,
            success_rate: (map(select(.success == true or .success == \"true\")) | length / (length | if . > 0 then . else 1 end))
        }) |
        sort_by(-.success_rate) |
        .[0].template // \"$default\"
    " 2>/dev/null || echo "\"$default\"")

    echo "$template" | tr -d '"'
}

# ─── Get Poll Interval Recommendation ───────────────────────────────────────
# daemon.poll emits issues_found, active (no queue_depth); keep default when no data
get_poll_interval() {
    local default="${1:-60}"

    # queue_update with queue_depth not emitted by pipeline; daemon.poll has issues_found, active
    local queue_events
    queue_events=$(db_query_events "" 5000 | jq "
        map(select(.type == \"daemon.poll\" and .issues_found != null) | .issues_found // 0 | tonumber) |
        map(select(. > 0))
    " 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$queue_events" | jq 'length')

    if [[ "$samples" -lt 5 ]]; then
        echo "$default"
        return
    fi

    local mean_queue
    mean_queue=$(mean "$queue_events")

    # Heuristic: more issues found → shorter interval
    local interval
    interval=$(echo "60 - (${mean_queue} * 2)" | bc 2>/dev/null || echo "$default")

    # Apply bounds
    if [[ "$interval" -lt "$MIN_POLL_INTERVAL" ]]; then interval="$MIN_POLL_INTERVAL"; fi
    if [[ "$interval" -gt "$MAX_POLL_INTERVAL" ]]; then interval="$MAX_POLL_INTERVAL"; fi

    echo "$interval"
}

# ─── Get Retry Limit Recommendation ────────────────────────────────────────
# Uses retry.classified (pipeline emits .error_class); success inferred from subsequent stage.completed
get_retry_limit() {
    local error_class="${1:-generic}"
    local default="${2:-2}"

    # retry.classified has error_class; retries/successes not directly emitted, keep default
    local retry_data
    retry_data=$(db_query_events "" 5000 | jq "
        map(select(.type == \"retry.classified\" and .error_class != null)) |
        group_by(.error_class) |
        map({
            error_class: .[0].error_class,
            retries: length,
            successes: (length * 0.5)
        }) |
        map(select(.error_class == \"${error_class}\")) |
        .[0]
    " 2>/dev/null || echo "{}")

    # Extract success rate with safe defaults for missing data
    local success_rate
    success_rate=$(echo "$retry_data" | jq 'if .retries and .retries > 0 then .successes / .retries else 0.5 end')

    # Heuristic: higher success rate → allow more retries (cap at 5)
    local limit
    limit=$(echo "scale=0; ${success_rate} * 5" | bc 2>/dev/null | cut -d. -f1)
    if [[ -z "$limit" ]]; then limit="$default"; fi

    if [[ "$limit" -lt 1 ]]; then limit=1; fi
    if [[ "$limit" -gt 5 ]]; then limit=5; fi

    echo "$limit"
}

# ─── Get Quality Threshold Recommendation ───────────────────────────────────
# Uses build.commit_quality (pipeline emits .score) or pipeline.quality_gate_failed; no exit_code on same event
get_quality_threshold() {
    local default="${1:-70}"

    # build.commit_quality has .score; pipeline.quality_gate_failed has .quality_score
    local quality_data
    quality_data=$(db_query_events "" 5000 | jq "
        (
            map(select(.type == \"build.commit_quality\" and .score != null) | .score | tonumber)
        ) + (
            map(select(.type == \"pipeline.quality_gate_failed\" and .quality_score != null) | .quality_score | tonumber)
        ) |
        map(select(. > 0)) |
        sort
    " 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$quality_data" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    # Use 25th percentile of passing runs as recommended threshold
    local p25
    p25=$(percentile "$quality_data" 25)
    local result
    result=$(echo "$p25" | cut -d. -f1)

    # Bounds: 50-95
    if [[ "$result" -lt 50 ]]; then result=50; fi
    if [[ "$result" -gt 95 ]]; then result=95; fi

    echo "$result"
}

# ─── Get Coverage Min Recommendation ────────────────────────────────────────
# Uses quality.coverage or test.completed (pipeline emits .coverage)
get_coverage_min() {
    local default="${1:-80}"

    # quality.coverage and test.completed emit .coverage
    local coverage_data
    coverage_data=$(db_query_events "" 5000 | jq "
        map(select((.type == \"quality.coverage\" or .type == \"test.completed\") and .coverage != null) | .coverage | tonumber) |
        map(select(. > 0)) |
        sort
    " 2>/dev/null || echo "[]")

    local samples
    samples=$(echo "$coverage_data" | jq 'length')

    if [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default"
        return
    fi

    # Use median of successful runs
    local med_coverage
    med_coverage=$(median "$coverage_data")
    local result
    result=$(echo "$med_coverage" | cut -d. -f1)

    # Bounds: 0-100
    if [[ "$result" -lt "$MIN_COVERAGE" ]]; then result="$MIN_COVERAGE"; fi
    if [[ "$result" -gt "$MAX_COVERAGE" ]]; then result="$MAX_COVERAGE"; fi

    echo "$result"
}

# ═══════════════════════════════════════════════════════════════════════════
# Adaptive Stage Timeout Engine — P95 Duration-Based Auto-Tuning
# ═══════════════════════════════════════════════════════════════════════════

STAGE_DURATIONS_FILE="${HOME}/.shipwright/optimization/stage-durations.json"
ADAPTIVE_STATE_FILE="${HOME}/.shipwright/adaptive-state.json"
TIMEOUT_TUNING_FILE="${HOME}/.shipwright/timeout-tuning-state.json"
TIMEOUT_ADJUST_INTERVAL=604800  # 7 days in seconds
TIMEOUT_BUFFER_MULTIPLIER="1.2"
ALL_STAGES="intake plan design build test review compound_quality pr merge deploy validate monitor"

# Aggregate stage durations from SQLite (or JSONL fallback)
# Returns JSON: {p50, p95, p99, mean, stddev, samples, confidence, last_updated}
aggregate_stage_durations() {
    local stage="${1:-build}"
    local repo_hash="${2:-}"
    local window_days="${3:-30}"

    local durations="[]"

    # Try SQLite first
    if type db_query_stage_durations >/dev/null 2>&1; then
        durations=$(db_query_stage_durations "$stage" "$repo_hash" "$window_days" 2>/dev/null || echo "[]")
    fi

    # JSONL fallback if SQLite returned empty
    if [[ "$durations" == "[]" ]] && [[ -f "${EVENTS_FILE:-}" ]]; then
        local cutoff_epoch
        cutoff_epoch=$(( $(date +%s) - (window_days * 86400) ))
        durations=$(jq -s "
            map(select(.type == \"stage.completed\" and .stage == \"${stage}\" and
                (.ts_epoch // 0 | tonumber) > ${cutoff_epoch}) | .duration_s // empty) |
            map(select(. > 0 and (. | type) == \"number\")) | sort
        " "$EVENTS_FILE" 2>/dev/null || echo "[]")
    fi

    local samples
    samples=$(echo "$durations" | jq 'length' 2>/dev/null || echo "0")
    [[ "$samples" =~ ^[0-9]+$ ]] || samples=0

    if [[ "$samples" -eq 0 ]]; then
        jq -nc '{p50: 0, p95: 0, p99: 0, mean: 0, stddev: 0, samples: 0, confidence: "low", last_updated: "never"}'
        return
    fi

    local p50 p95 p99 m sd conf
    p50=$(percentile "$durations" 50 2>/dev/null || echo "0")
    p95=$(percentile "$durations" 95 2>/dev/null || echo "0")
    p99=$(percentile "$durations" 99 2>/dev/null || echo "0")
    m=$(mean "$durations" 2>/dev/null || echo "0")
    sd=$(stddev "$durations" 2>/dev/null || echo "0")
    conf=$(confidence_level "$samples")

    jq -nc --argjson p50 "${p50:-0}" --argjson p95 "${p95:-0}" --argjson p99 "${p99:-0}" \
        --argjson mean "${m:-0}" --argjson stddev "${sd:-0}" --argjson samples "$samples" \
        --arg conf "$conf" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{p50: $p50, p95: $p95, p99: $p99, mean: $mean, stddev: $stddev, samples: $samples, confidence: $conf, last_updated: $ts}'
}

# Calculate adaptive timeout for a stage: max(P95 * buffer, MIN_TIMEOUT), clamped
calculate_adaptive_timeout() {
    local stage="${1:-build}"
    local repo_hash="${2:-}"
    local buffer="${3:-$TIMEOUT_BUFFER_MULTIPLIER}"

    # Get per-stage default
    local default_timeout
    default_timeout=$(_stage_default_timeout "$stage")

    local agg
    agg=$(aggregate_stage_durations "$stage" "$repo_hash" 2>/dev/null || echo '{}')

    local samples conf p95
    samples=$(echo "$agg" | jq -r '.samples // 0' 2>/dev/null || echo "0")
    conf=$(echo "$agg" | jq -r '.confidence // "low"' 2>/dev/null || echo "low")
    p95=$(echo "$agg" | jq -r '.p95 // 0' 2>/dev/null || echo "0")

    # Low confidence: return default
    if [[ "$conf" == "low" ]] || [[ "$samples" -lt "$MIN_CONFIDENCE_SAMPLES" ]]; then
        echo "$default_timeout"
        return
    fi

    # Calculate: P95 * buffer
    local timeout
    if command -v bc >/dev/null 2>&1; then
        timeout=$(echo "$p95 * $buffer" | bc 2>/dev/null | cut -d. -f1)
    else
        # Integer fallback: p95 + p95/5 (approximates * 1.2)
        local p95_int="${p95%%.*}"
        timeout=$(( p95_int + p95_int / 5 ))
    fi

    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout="$default_timeout"
    [[ "$timeout" -lt "$MIN_TIMEOUT" ]] && timeout="$MIN_TIMEOUT"
    [[ "$timeout" -gt "$MAX_TIMEOUT" ]] && timeout="$MAX_TIMEOUT"

    echo "$timeout"
}

# Per-stage default timeouts
_stage_default_timeout() {
    local stage="$1"
    case "$stage" in
        intake|pr|merge)                echo 300 ;;
        plan|design)                    echo 600 ;;
        build)                          echo 1800 ;;
        test)                           echo 900 ;;
        review|compound_quality)        echo 600 ;;
        deploy|validate|monitor)        echo 600 ;;
        *)                              echo 1800 ;;
    esac
}

# Check if timeout adjustment is due (every 7 days)
should_adjust_timeouts() {
    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return 1
    fi

    if [[ ! -f "$ADAPTIVE_STATE_FILE" ]]; then
        return 0  # Never adjusted — trigger
    fi

    local last_epoch
    last_epoch=$(jq -r '.last_adjustment_epoch // 0' "$ADAPTIVE_STATE_FILE" 2>/dev/null || echo "0")
    [[ "$last_epoch" =~ ^[0-9]+$ ]] || return 0

    local now_epoch
    now_epoch=$(date +%s)
    local elapsed=$(( now_epoch - last_epoch ))

    if [[ "$elapsed" -ge "$TIMEOUT_ADJUST_INTERVAL" ]]; then
        return 0
    fi
    return 1
}

# Recalculate all stage P95 values and write state files
trigger_timeout_adjustment() {
    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" != "true" ]]; then
        return
    fi

    mkdir -p "$HOME/.shipwright/optimization"

    local stages_json="{}"
    local tuning_stages="{}"
    local stage

    for stage in $ALL_STAGES; do
        local agg
        agg=$(aggregate_stage_durations "$stage" "" 30 2>/dev/null || echo '{}')

        local p50 p95 p99 samples conf timeout_s
        p50=$(echo "$agg" | jq -r '.p50 // 0')
        p95=$(echo "$agg" | jq -r '.p95 // 0')
        p99=$(echo "$agg" | jq -r '.p99 // 0')
        samples=$(echo "$agg" | jq -r '.samples // 0')
        conf=$(echo "$agg" | jq -r '.confidence // "low"')
        timeout_s=$(calculate_adaptive_timeout "$stage" "" 2>/dev/null || _stage_default_timeout "$stage")

        stages_json=$(echo "$stages_json" | jq --arg s "$stage" \
            --argjson p50 "${p50:-0}" --argjson p95 "${p95:-0}" --argjson p99 "${p99:-0}" \
            --argjson samples "${samples:-0}" --arg conf "$conf" --argjson timeout "$timeout_s" \
            '.[$s] = {p50_duration_s: $p50, p90_duration_s: $p95, p95_duration_s: $p95, p99_duration_s: $p99, timeout_s: $timeout, samples: $samples, confidence: $conf}')

        tuning_stages=$(echo "$tuning_stages" | jq --arg s "$stage" \
            --argjson p95 "${p95:-0}" --argjson timeout "$timeout_s" --argjson samples "${samples:-0}" --arg conf "$conf" \
            '.[$s] = {p95: $p95, timeout_s: $timeout, samples: $samples, confidence: $conf}')

        # Anomaly detection: emit event if P99 + 2*stddev is exceeded
        local sd
        sd=$(echo "$agg" | jq -r '.stddev // 0')
        if [[ "$samples" -gt 0 ]] && command -v bc >/dev/null 2>&1; then
            local anomaly_threshold
            anomaly_threshold=$(echo "$p99 + 2 * $sd" | bc 2>/dev/null | cut -d. -f1 || true)
            [[ -n "$anomaly_threshold" && "$anomaly_threshold" =~ ^[0-9]+$ ]] && \
                emit_event "adaptation.timeout_adjusted" "stage=$stage" "p95=$p95" "timeout_s=$timeout_s" "samples=$samples" "anomaly_threshold=$anomaly_threshold" 2>/dev/null || true
        fi
    done

    # Write stage-durations.json (atomic)
    local tmp_dur="${STAGE_DURATIONS_FILE}.tmp.$$"
    jq -nc --argjson stages "$stages_json" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{stages: $stages, last_updated: $ts}' > "$tmp_dur" && mv "$tmp_dur" "$STAGE_DURATIONS_FILE"

    # Write timeout-tuning-state.json (atomic)
    local now_epoch
    now_epoch=$(date +%s)
    local next_epoch=$(( now_epoch + TIMEOUT_ADJUST_INTERVAL ))
    local tmp_tuning="${TIMEOUT_TUNING_FILE}.tmp.$$"
    jq -nc --argjson stages "$tuning_stages" --argjson last "$now_epoch" --argjson next "$next_epoch" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{last_adjustment: $ts, last_adjustment_epoch: $last, next_adjustment_epoch: $next, stages: $stages}' \
        > "$tmp_tuning" && mv "$tmp_tuning" "$TIMEOUT_TUNING_FILE"

    # Write adaptive-state.json (atomic)
    local tmp_state="${ADAPTIVE_STATE_FILE}.tmp.$$"
    jq -nc --argjson epoch "$now_epoch" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{last_adjustment_epoch: $epoch, last_adjustment: $ts}' > "$tmp_state" && mv "$tmp_state" "$ADAPTIVE_STATE_FILE"

    info "Timeout adjustment complete — updated $(echo "$ALL_STAGES" | wc -w | tr -d ' ') stages"
}

# Show timeouts subcommand
cmd_show_timeouts() {
    local repo_hash="${1:-}"

    printf "\n"
    printf "  %-20s  %8s  %8s  %8s  %8s  %s\n" "Stage" "Timeout" "P95" "Samples" "Confid." "Source"
    printf "  %-20s  %8s  %8s  %8s  %8s  %s\n" "────────────────────" "────────" "────────" "────────" "────────" "────────"

    local stage
    for stage in $ALL_STAGES; do
        local agg timeout_s source
        agg=$(aggregate_stage_durations "$stage" "$repo_hash" 30 2>/dev/null || echo '{}')

        local p95 samples conf
        p95=$(echo "$agg" | jq -r '.p95 // 0')
        samples=$(echo "$agg" | jq -r '.samples // 0')
        conf=$(echo "$agg" | jq -r '.confidence // "low"')

        if [[ "$conf" != "low" ]] && [[ "$samples" -ge "$MIN_CONFIDENCE_SAMPLES" ]]; then
            timeout_s=$(calculate_adaptive_timeout "$stage" "$repo_hash" 2>/dev/null || _stage_default_timeout "$stage")
            source="adaptive"
        else
            timeout_s=$(_stage_default_timeout "$stage")
            source="default"
        fi

        printf "  %-20s  %7ss  %7ss  %8s  %8s  %s\n" "$stage" "$timeout_s" "${p95%%.*}" "$samples" "$conf" "$source"
    done

    # Show last adjustment time
    if [[ -f "$ADAPTIVE_STATE_FILE" ]]; then
        local last_adj
        last_adj=$(jq -r '.last_adjustment // "never"' "$ADAPTIVE_STATE_FILE" 2>/dev/null || echo "never")
        printf "\n  Last adjustment: %s\n" "$last_adj"
    else
        printf "\n  Last adjustment: never\n"
    fi
    printf "\n"
}

# ─── Main: get subcommand ───────────────────────────────────────────────────
cmd_get() {
    local metric="${1:-}"
    [[ -n "$metric" ]] && shift || true

    local stage="build"
    local repo="${REPO_DIR}"
    local complexity=5
    local default=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage) stage="$2"; shift 2 ;;
            --repo) repo="$2"; shift 2 ;;
            --complexity) complexity="$2"; shift 2 ;;
            --default) default="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    case "$metric" in
        timeout)
            get_timeout "$stage" "$repo" "${default:-1800}"
            ;;
        iterations)
            get_iterations "$complexity" "$stage" "${default:-10}"
            ;;
        model)
            get_model "$stage" "${default:-opus}"
            ;;
        team_size)
            get_team_size "$complexity" "${default:-2}"
            ;;
        template)
            get_template "$complexity" "${default:-standard}"
            ;;
        poll_interval)
            get_poll_interval "${default:-60}"
            ;;
        retry_limit)
            get_retry_limit "generic" "${default:-2}"
            ;;
        quality_threshold)
            get_quality_threshold "${default:-70}"
            ;;
        coverage_min)
            get_coverage_min "${default:-80}"
            ;;
        *)
            error "Unknown metric: $metric"
            echo "Available metrics: timeout, iterations, model, team_size, template, poll_interval, retry_limit, quality_threshold, coverage_min"
            return 1
            ;;
    esac
}

# ─── Main: profile subcommand ───────────────────────────────────────────────
cmd_profile() {
    # profile takes no positional args, just --options
    local repo="${REPO_DIR}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    info "Adaptive Profile for ${CYAN}${repo}${RESET}"
    echo ""

    # Table header
    printf "%-25s %-15s %-15s %-12s %-10s\n" "Metric" "Learned" "Default" "Samples" "Confidence"
    printf "%s\n" "$(printf '%.0s─' {1..80})"

    # Timeout
    local timeout_val
    timeout_val=$(get_timeout "build" "$repo" "1800")
    local timeout_samples
    timeout_samples=$(db_query_events "" 5000 | jq "map(select(.type == \"stage.completed\" and .stage == \"build\") | .duration_s) | length" 2>/dev/null || echo "0")
    local timeout_conf
    timeout_conf=$(confidence_level "$timeout_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "timeout (s)" "$timeout_val" "1800" "$timeout_samples" "$timeout_conf"

    # Iterations
    local iter_val
    iter_val=$(get_iterations 5 "build" "10")
    local iter_samples
    iter_samples=$(db_query_events "" 5000 | jq "
        (
            map(select(.type == \"pipeline.completed\")) +
            map(select(.type == \"prediction.validated\" and .actual_iterations != null))
        ) | length
    " 2>/dev/null || echo "0")
    local iter_conf
    iter_conf=$(confidence_level "$iter_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "iterations" "$iter_val" "10" "$iter_samples" "$iter_conf"

    # Model
    local model_val
    model_val=$(get_model "build" "opus")
    local model_samples
    model_samples=$(db_query_events "" 5000 | jq "map(select(.type == \"model.outcome\" and .model != null)) | length" 2>/dev/null || echo "0")
    local model_conf
    model_conf=$(confidence_level "$model_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "model" "$model_val" "opus" "$model_samples" "$model_conf"

    # Team size
    local team_val
    team_val=$(get_team_size 5 "2")
    local team_samples
    team_samples=$(db_query_events "" 5000 | jq "map(select(.team_size != null)) | length" 2>/dev/null || echo "0")
    local team_conf
    team_conf=$(confidence_level "$team_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "team_size" "$team_val" "2" "$team_samples" "$team_conf"

    # Template
    local template_val
    template_val=$(get_template 5 "standard")
    local template_samples
    template_samples=$(db_query_events "" 5000 | jq "map(select(.type == \"template.outcome\" and .template != null)) | length" 2>/dev/null || echo "0")
    local template_conf
    template_conf=$(confidence_level "$template_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "template" "$template_val" "standard" "$template_samples" "$template_conf"

    # Poll interval
    local poll_val
    poll_val=$(get_poll_interval "60")
    local poll_samples
    poll_samples=$(db_query_events "" 5000 | jq "map(select(.type == \"daemon.poll\")) | length" 2>/dev/null || echo "0")
    local poll_conf
    poll_conf=$(confidence_level "$poll_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "poll_interval (s)" "$poll_val" "60" "$poll_samples" "$poll_conf"

    # Quality threshold
    local quality_val
    quality_val=$(get_quality_threshold "70")
    local quality_samples
    quality_samples=$(db_query_events "" 5000 | jq "
        (
            map(select(.type == \"build.commit_quality\" and .score != null)) +
            map(select(.type == \"pipeline.quality_gate_failed\" and .quality_score != null))
        ) | length
    " 2>/dev/null || echo "0")
    local quality_conf
    quality_conf=$(confidence_level "$quality_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "quality_threshold" "$quality_val" "70" "$quality_samples" "$quality_conf"

    # Coverage min
    local coverage_val
    coverage_val=$(get_coverage_min "80")
    local coverage_samples
    coverage_samples=$(db_query_events "" 5000 | jq "
        map(select((.type == \"quality.coverage\" or .type == \"test.completed\") and .coverage != null)) | length
    " 2>/dev/null || echo "0")
    local coverage_conf
    coverage_conf=$(confidence_level "$coverage_samples")
    printf "%-25s %-15s %-15s %-12s %-10s\n" "coverage_min (%)" "$coverage_val" "80" "$coverage_samples" "$coverage_conf"

    echo ""
}

# ─── Main: train subcommand ─────────────────────────────────────────────────
cmd_train() {
    # train takes no positional args, just --options
    local repo="${REPO_DIR}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local event_count
    event_count=$(db_query_events "" 5000 | jq 'length' 2>/dev/null || echo 0)
    if [[ "${event_count:-0}" -eq 0 ]]; then
        warn "No events found (checked DB and JSONL fallback)"
        return 1
    fi

    info "Training adaptive models from events (DB + JSONL fallback)"
    info "Processing ${CYAN}${event_count}${RESET} events..."

    # Build comprehensive models JSON using jq directly
    local timeout_learned timeout_samples
    timeout_learned=$(get_timeout "build" "$repo" "1800")
    timeout_samples=$(db_query_events "" 5000 | jq "map(select(.type == \"stage.completed\" and .stage == \"build\") | .duration_s) | length" 2>/dev/null || echo 0)

    local iterations_learned iterations_samples
    iterations_learned=$(get_iterations 5 "build" "10")
    iterations_samples=$(db_query_events "" 5000 | jq "
        (map(select(.type == \"pipeline.completed\")) + map(select(.type == \"prediction.validated\" and .actual_iterations != null))) | length
    " 2>/dev/null || echo 0)

    local model_learned model_samples
    model_learned=$(get_model "build" "opus")
    model_samples=$(db_query_events "" 5000 | jq "map(select(.type == \"model.outcome\" and .model != null)) | length" 2>/dev/null || echo 0)

    local team_learned team_samples
    team_learned=$(get_team_size 5 "2")
    team_samples=$(db_query_events "" 5000 | jq "map(select(.team_size != null)) | length" 2>/dev/null || echo 0)

    local quality_learned quality_samples
    quality_learned=$(get_quality_threshold "70")
    quality_samples=$(db_query_events "" 5000 | jq "
        (map(select(.type == \"build.commit_quality\" and .score != null)) + map(select(.type == \"pipeline.quality_gate_failed\" and .quality_score != null))) | length
    " 2>/dev/null || echo 0)

    local coverage_learned coverage_samples
    coverage_learned=$(get_coverage_min "80")
    coverage_samples=$(db_query_events "" 5000 | jq "map(select((.type == \"quality.coverage\" or .type == \"test.completed\") and .coverage != null)) | length" 2>/dev/null || echo 0)

    local trained_at
    trained_at=$(now_iso)

    # Build JSON using jq with variables
    local models
    models=$(jq -n \
        --arg trained_at "$trained_at" \
        --arg timeout_learned "$timeout_learned" \
        --arg iterations_learned "$iterations_learned" \
        --arg model_learned "$model_learned" \
        --arg team_learned "$team_learned" \
        --arg quality_learned "$quality_learned" \
        --arg coverage_learned "$coverage_learned" \
        --arg timeout_samples "$timeout_samples" \
        --arg iterations_samples "$iterations_samples" \
        --arg model_samples "$model_samples" \
        --arg team_samples "$team_samples" \
        --arg quality_samples "$quality_samples" \
        --arg coverage_samples "$coverage_samples" \
        '{
            timeout: {
                learned: ($timeout_learned | tonumber),
                default: 1800,
                samples: ($timeout_samples | tonumber)
            },
            iterations: {
                learned: ($iterations_learned | tonumber),
                default: 10,
                samples: ($iterations_samples | tonumber)
            },
            model: {
                learned: $model_learned,
                default: "opus",
                samples: ($model_samples | tonumber)
            },
            team_size: {
                learned: ($team_learned | tonumber),
                default: 2,
                samples: ($team_samples | tonumber)
            },
            quality_threshold: {
                learned: ($quality_learned | tonumber),
                default: 70,
                samples: ($quality_samples | tonumber)
            },
            coverage_min: {
                learned: ($coverage_learned | tonumber),
                default: 80,
                samples: ($coverage_samples | tonumber)
            },
            trained_at: $trained_at
        }')

    save_models "$models"
    success "Models trained and saved to ${CYAN}${MODELS_FILE}${RESET}"
}

# ─── Main: compare subcommand ───────────────────────────────────────────────
cmd_compare() {
    # compare takes no positional args, just --options
    local repo="${REPO_DIR}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    info "Learned vs Default Values for ${CYAN}${repo}${RESET}"
    echo ""

    printf "%-25s %-15s %-15s %-15s\n" "Metric" "Default" "Learned" "Difference"
    printf "%s\n" "$(printf '%.0s─' {1..70})"

    # Timeout
    local timeout_hard=1800
    local timeout_learn
    timeout_learn=$(get_timeout "build" "$repo" "$timeout_hard")
    local timeout_diff=$((timeout_learn - timeout_hard))
    printf "%-25s %-15s %-15s %-15s\n" "timeout (s)" "$timeout_hard" "$timeout_learn" "$timeout_diff"

    # Iterations
    local iter_hard=10
    local iter_learn
    iter_learn=$(get_iterations 5 "build" "$iter_hard")
    local iter_diff=$((iter_learn - iter_hard))
    printf "%-25s %-15s %-15s %-15s\n" "iterations" "$iter_hard" "$iter_learn" "$iter_diff"

    # Model
    local model_hard="opus"
    local model_learn
    model_learn=$(get_model "build" "$model_hard")
    printf "%-25s %-15s %-15s %-15s\n" "model" "$model_hard" "$model_learn" "-"

    # Team size
    local team_hard=2
    local team_learn
    team_learn=$(get_team_size 5 "$team_hard")
    local team_diff=$((team_learn - team_hard))
    printf "%-25s %-15s %-15s %-15s\n" "team_size" "$team_hard" "$team_learn" "$team_diff"

    # Quality threshold
    local quality_hard=70
    local quality_learn
    quality_learn=$(get_quality_threshold "$quality_hard")
    local quality_diff=$((quality_learn - quality_hard))
    printf "%-25s %-15s %-15s %-15s\n" "quality_threshold" "$quality_hard" "$quality_learn" "$quality_diff"

    # Coverage min
    local coverage_hard=80
    local coverage_learn
    coverage_learn=$(get_coverage_min "$coverage_hard")
    local coverage_diff=$((coverage_learn - coverage_hard))
    printf "%-25s %-15s %-15s %-15s\n" "coverage_min (%)" "$coverage_hard" "$coverage_learn" "$coverage_diff"

    echo ""
}

# ─── Main: recommend subcommand ─────────────────────────────────────────────
cmd_recommend() {
    # recommend takes --issue as required option
    local issue=""
    local repo="${REPO_DIR}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue) issue="$2"; shift 2 ;;
            --repo) repo="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$issue" ]]; then
        error "Missing --issue argument"
        return 1
    fi

    info "Generating recommendation for issue ${CYAN}#${issue}${RESET}..."

    # Simulate complexity score (in real implementation, query GitHub API)
    local complexity=5

    # Build JSON recommendation
    local recommendation
    recommendation=$(jq -n "{
        issue: ${issue},
        template: \"$(get_template "$complexity" "standard")\",
        model: \"$(get_model "build" "opus")\",
        max_iterations: $(get_iterations "$complexity" "build" "10"),
        team_size: $(get_team_size "$complexity" "2"),
        timeout: $(get_timeout "build" "$repo" "1800"),
        quality_threshold: $(get_quality_threshold "70"),
        poll_interval: $(get_poll_interval "60"),
        coverage_min: $(get_coverage_min "80"),
        confidence: \"high\",
        reasoning: \"Based on $(db_query_events "" 5000 | jq 'length' 2>/dev/null || echo 0) historical events\"
    }")

    echo "$recommendation" | jq .
}

# ─── Main: reset subcommand ─────────────────────────────────────────────────
cmd_reset() {
    # reset takes optional --metric
    local metric=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --metric) metric="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$metric" ]]; then
        info "Clearing all learned data..."
        rm -f "$MODELS_FILE"
        success "Cleared ${CYAN}${MODELS_FILE}${RESET}"
    else
        info "Clearing learned data for metric: ${CYAN}${metric}${RESET}"
        local models
        models=$(load_models)
        models=$(echo "$models" | jq "del(.${metric})")
        save_models "$models"
        success "Reset metric ${CYAN}${metric}${RESET}"
    fi
}

# ─── Main: help subcommand ──────────────────────────────────────────────────
cmd_help() {
    cat <<EOF
${BOLD}shipwright adaptive${RESET} — Data-Driven Pipeline Tuning

${BOLD}USAGE${RESET}
  sw adaptive <subcommand> [options]

${BOLD}SUBCOMMANDS${RESET}
  ${CYAN}get${RESET} <metric> [--stage S] [--repo R] [--complexity C] [--default V]
    Return adaptive value for a metric (replaces static defaults)
    Metrics: timeout, iterations, model, team_size, template, poll_interval,
             retry_limit, quality_threshold, coverage_min

  ${CYAN}profile${RESET} [--repo REPO]
    Show all learned parameters with confidence levels

  ${CYAN}train${RESET} [--repo REPO]
    Rebuild models from events.jsonl (run after significant pipeline activity)

  ${CYAN}compare${RESET} [--repo REPO]
    Side-by-side table: learned vs default values

  ${CYAN}recommend${RESET} --issue N [--repo REPO]
    Full JSON recommendation for an issue (template, model, team_size, etc.)

  ${CYAN}show${RESET} timeouts [--repo-hash HASH]
    Display adaptive timeout table for all stages

  ${CYAN}adjust${RESET}
    Force recalculation of all stage timeout P95 values

  ${CYAN}reset${RESET} [--metric METRIC]
    Clear learned data (all, or specific metric)

  ${CYAN}help${RESET}
    Show this help message

${BOLD}EXAMPLES${RESET}
  # Get learned timeout for build stage
  sw adaptive get timeout --stage build

  # Show all learned parameters
  sw adaptive profile

  # Train models from events (run after major pipeline activity)
  sw adaptive train

  # Get complete recommendation for issue #42
  sw adaptive recommend --issue 42

  # Compare learned vs defaults
  sw adaptive compare

${BOLD}STORAGE${RESET}
  Events:      ${CYAN}${EVENTS_FILE}${RESET}
  Models:      ${CYAN}${MODELS_FILE}${RESET}

${BOLD}STATISTICS${RESET}
  • Low confidence:    < 10 samples
  • Medium confidence: 10-50 samples
  • High confidence:   > 50 samples

  • Timeout:  P95 of historical stage durations + 20% buffer
  • Iterations: Mean of successful build iterations
  • Model: Cheapest model with >90% success rate
  • Team size: Mean team size from historical runs
  • Quality threshold: 25th percentile of passing quality scores
  • Coverage: Median coverage from successful runs
EOF
}

# ─── Main Entry Point ────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        get)
            cmd_get "$@"
            ;;
        profile)
            cmd_profile "$@"
            ;;
        train)
            cmd_train "$@"
            ;;
        compare)
            cmd_compare "$@"
            ;;
        recommend)
            cmd_recommend "$@"
            ;;
        show)
            local show_sub="${1:-}"
            shift 2>/dev/null || true
            case "$show_sub" in
                timeouts) cmd_show_timeouts "$@" ;;
                *) error "Usage: sw adaptive show timeouts [--repo-hash HASH]"; return 1 ;;
            esac
            ;;
        adjust)
            ADAPTIVE_THRESHOLDS_ENABLED=true trigger_timeout_adjustment
            ;;
        reset)
            cmd_reset "$@"
            ;;
        help)
            cmd_help
            ;;
        version)
            echo "sw-adaptive v${VERSION}"
            ;;
        *)
            error "Unknown command: $cmd"
            cmd_help
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
