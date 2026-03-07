#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Timeout Recommendation Engine — P95 duration-based auto-tuning          ║
# ║  Calculates recommendations and applies to daemon-config.json            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2155

# Guard: only load once
[[ "${_TIMEOUT_REC_ENGINE_LOADED:-}" == "true" ]] && return 0
_TIMEOUT_REC_ENGINE_LOADED=true

# ─── Defaults ────────────────────────────────────────────────────────────────
TIMEOUT_REC_MIN_SAMPLES="${TIMEOUT_REC_MIN_SAMPLES:-10}"
TIMEOUT_REC_BUFFER="${TIMEOUT_REC_BUFFER:-1.2}"
TIMEOUT_REC_MIN="${TIMEOUT_REC_MIN:-60}"
TIMEOUT_REC_MAX="${TIMEOUT_REC_MAX:-7200}"
TIMEOUT_REC_WINDOW_DAYS="${TIMEOUT_REC_WINDOW_DAYS:-30}"
TIMEOUT_REC_CHANGE_THRESHOLD="${TIMEOUT_REC_CHANGE_THRESHOLD:-5}"  # percent

# ─── Calculate percentiles from a JSON array ─────────────────────────────────
# Usage: _calc_percentile "[1,2,3,4,5]" 95
_calc_percentile() {
    local arr="$1"
    local p="$2"
    jq -n --arg arr "$arr" --arg p "$p" '
        ($arr | fromjson | map(tonumber?) | sort) as $sorted |
        ($sorted | length) as $len |
        ((($p | tonumber) / 100) * ($len - 1) | floor) as $idx |
        if $len == 0 then 0
        elif $idx >= $len - 1 then $sorted[-1]
        else ($sorted[$idx] + $sorted[$idx + 1]) / 2
        end
    ' 2>/dev/null || echo "0"
}

# ─── Get stats for a stage ────────────────────────────────────────────────────
# Returns JSON: {p50, p95, p99, count, min, max, mean}
get_stage_duration_stats() {
    local stage_type="${1:?stage_type required}"
    local repo_hash="${2:-}"
    local window_days="${3:-$TIMEOUT_REC_WINDOW_DAYS}"

    local durations="[]"
    if type db_query_stage_durations >/dev/null 2>&1; then
        durations=$(db_query_stage_durations "$stage_type" "$repo_hash" "$window_days" 2>/dev/null || echo "[]")
    fi

    local count
    count=$(echo "$durations" | jq 'length' 2>/dev/null || echo "0")
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    if [[ "$count" -eq 0 ]]; then
        jq -nc '{p50: 0, p95: 0, p99: 0, count: 0, min: 0, max: 0, mean: 0}'
        return
    fi

    local p50 p95 p99 min_val max_val mean_val
    p50=$(_calc_percentile "$durations" 50)
    p95=$(_calc_percentile "$durations" 95)
    p99=$(_calc_percentile "$durations" 99)
    min_val=$(echo "$durations" | jq 'min // 0' 2>/dev/null || echo "0")
    max_val=$(echo "$durations" | jq 'max // 0' 2>/dev/null || echo "0")
    mean_val=$(echo "$durations" | jq 'add / length // 0' 2>/dev/null || echo "0")

    jq -nc --argjson p50 "${p50:-0}" --argjson p95 "${p95:-0}" --argjson p99 "${p99:-0}" \
        --argjson count "$count" --argjson min "${min_val:-0}" --argjson max "${max_val:-0}" \
        --argjson mean "${mean_val:-0}" \
        '{p50: $p50, p95: $p95, p99: $p99, count: $count, min: $min, max: $max, mean: $mean}'
}

# ─── Calculate recommended timeout for a stage ───────────────────────────────
# Returns JSON: {stage_type, recommended_timeout, p95, p99, sample_count, rationale}
calculate_recommended_timeout() {
    local stage_type="${1:?stage_type required}"
    local repo_hash="${2:-}"
    local buffer="${3:-$TIMEOUT_REC_BUFFER}"
    local min_timeout="${4:-$TIMEOUT_REC_MIN}"
    local max_timeout="${5:-$TIMEOUT_REC_MAX}"

    local stats
    stats=$(get_stage_duration_stats "$stage_type" "$repo_hash")

    local count p95 p99 max_val
    count=$(echo "$stats" | jq '.count' 2>/dev/null || echo "0")
    p95=$(echo "$stats" | jq '.p95' 2>/dev/null || echo "0")
    p99=$(echo "$stats" | jq '.p99' 2>/dev/null || echo "0")
    max_val=$(echo "$stats" | jq '.max' 2>/dev/null || echo "0")

    local rationale="insufficient_data"
    local recommended=0

    if [[ "$count" -lt "$TIMEOUT_REC_MIN_SAMPLES" ]]; then
        rationale="insufficient_data: ${count} samples < ${TIMEOUT_REC_MIN_SAMPLES} minimum"
        recommended=0
    else
        # Calculate: P95 * buffer
        if command -v bc >/dev/null 2>&1; then
            recommended=$(echo "$p95 * $buffer" | bc 2>/dev/null | cut -d. -f1)
        else
            local p95_int="${p95%%.*}"
            recommended=$(( p95_int + p95_int / 5 ))
        fi

        [[ "$recommended" =~ ^[0-9]+$ ]] || recommended=0

        # Clamp
        [[ "$recommended" -lt "$min_timeout" ]] && recommended="$min_timeout"
        [[ "$recommended" -gt "$max_timeout" ]] && recommended="$max_timeout"

        rationale="P95(${p95%%.*}s) * ${buffer} = ${recommended}s from ${count} samples"

        # Anomaly detection: flag if max > 5 * median
        local p50
        p50=$(echo "$stats" | jq '.p50' 2>/dev/null || echo "0")
        local p50_int="${p50%%.*}"
        local max_int="${max_val%%.*}"
        if [[ "$p50_int" -gt 0 ]] && [[ "$max_int" -gt $(( p50_int * 5 )) ]]; then
            rationale="${rationale}; ANOMALY: max(${max_int}s) > 5x median(${p50_int}s)"
        fi
    fi

    jq -nc --arg stage "$stage_type" --argjson rec "$recommended" \
        --argjson p95 "${p95:-0}" --argjson p99 "${p99:-0}" \
        --argjson count "$count" --arg rationale "$rationale" \
        '{stage_type: $stage, recommended_timeout: $rec, p95: $p95, p99: $p99, sample_count: $count, rationale: $rationale}'
}

# ─── Generate adjustment report ───────────────────────────────────────────────
# Returns JSON array of stages where recommendation differs from current by >threshold%
generate_adjustment_report() {
    local repo_hash="${1:-}"
    local config_file="${2:-${DAEMON_CONFIG:-}}"
    local change_threshold="${3:-$TIMEOUT_REC_CHANGE_THRESHOLD}"

    local stages="intake plan design build test review compound_quality pr merge deploy validate monitor"
    local report="[]"

    for stage in $stages; do
        local rec
        rec=$(calculate_recommended_timeout "$stage" "$repo_hash")

        local recommended
        recommended=$(echo "$rec" | jq '.recommended_timeout' 2>/dev/null || echo "0")
        [[ "$recommended" -eq 0 ]] && continue

        # Get current timeout from config
        local current=0
        if [[ -n "$config_file" ]] && [[ -f "$config_file" ]]; then
            current=$(jq -r --arg s "$stage" '.adaptive_timeouts.stage_timeouts[$s] // 0' "$config_file" 2>/dev/null || echo "0")
        fi
        # Fallback to default
        if [[ "$current" -eq 0 ]]; then
            case "$stage" in
                intake|pr|merge)             current=300 ;;
                plan|design)                 current=600 ;;
                build)                       current=1800 ;;
                test)                        current=900 ;;
                review|compound_quality)     current=600 ;;
                deploy|validate|monitor)     current=600 ;;
                *)                           current=1800 ;;
            esac
        fi

        # Calculate change percent
        local change_pct=0
        if [[ "$current" -gt 0 ]]; then
            if command -v bc >/dev/null 2>&1; then
                change_pct=$(echo "scale=0; ($recommended - $current) * 100 / $current" | bc 2>/dev/null || echo "0")
            else
                change_pct=$(( (recommended - current) * 100 / current ))
            fi
        fi

        # Absolute value for threshold check
        local abs_change="${change_pct#-}"

        if [[ "$abs_change" -gt "$change_threshold" ]]; then
            report=$(echo "$report" | jq --arg s "$stage" --argjson cur "$current" \
                --argjson rec "$recommended" --argjson pct "$change_pct" \
                '. + [{stage_type: $s, current_timeout: $cur, recommended_timeout: $rec, change_percent: $pct}]')
        fi
    done

    echo "$report"
}

# ─── Apply timeout recommendations ───────────────────────────────────────────
# Updates daemon-config.json with new timeouts. Respects manual overrides.
# Returns JSON: {stages_updated, adjustments}
apply_timeout_recommendations() {
    local repo_hash="${1:-}"
    local config_file="${2:-${DAEMON_CONFIG:-.claude/daemon-config.json}}"
    local dry_run="${3:-false}"

    local report
    report=$(generate_adjustment_report "$repo_hash" "$config_file")

    local count
    count=$(echo "$report" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        jq -nc '{stages_updated: 0, adjustments: []}'
        return
    fi

    # Read manual overrides from config
    local manual_overrides="{}"
    if [[ -f "$config_file" ]]; then
        manual_overrides=$(jq '.adaptive_timeouts.manual_overrides // {}' "$config_file" 2>/dev/null || echo "{}")
    fi

    local applied="[]"
    local updated_count=0

    while IFS= read -r adj; do
        local stage current rec
        stage=$(echo "$adj" | jq -r '.stage_type')
        current=$(echo "$adj" | jq '.current_timeout')
        rec=$(echo "$adj" | jq '.recommended_timeout')

        # Check manual override
        local manual
        manual=$(echo "$manual_overrides" | jq -r --arg s "$stage" '.[$s] // "null"')
        if [[ "$manual" != "null" ]]; then
            applied=$(echo "$applied" | jq --arg s "$stage" --argjson cur "$current" \
                --argjson rec "$rec" --arg reason "manual_override" \
                '. + [{stage_type: $s, old_timeout: $cur, new_timeout: $cur, reason: $reason, skipped: true}]')
            continue
        fi

        if [[ "$dry_run" != "true" ]] && [[ -f "$config_file" ]]; then
            # Update config atomically
            local tmp_config
            tmp_config=$(mktemp "${TMPDIR:-/tmp}/sw-config.XXXXXX")
            jq --arg s "$stage" --argjson t "$rec" \
                '.adaptive_timeouts.stage_timeouts[$s] = $t' "$config_file" > "$tmp_config" 2>/dev/null && \
                mv "$tmp_config" "$config_file" || rm -f "$tmp_config"

            # Record adjustment in DB if available
            if type db_save_timeout_adjustment >/dev/null 2>&1; then
                db_save_timeout_adjustment "$repo_hash" "$stage" "$current" "$rec" "auto_p95" 2>/dev/null || true
            fi

            # Emit event
            if type emit_event >/dev/null 2>&1; then
                emit_event "timeout.adjustment_applied" "stage=$stage" "old=$current" "new=$rec" 2>/dev/null || true
            fi
        fi

        applied=$(echo "$applied" | jq --arg s "$stage" --argjson cur "$current" \
            --argjson rec "$rec" --arg reason "p95_auto_tuning" \
            '. + [{stage_type: $s, old_timeout: $cur, new_timeout: $rec, reason: $reason, skipped: false}]')
        updated_count=$((updated_count + 1))
    done < <(echo "$report" | jq -c '.[]')

    jq -nc --argjson count "$updated_count" --argjson adj "$applied" \
        '{stages_updated: $count, adjustments: $adj}'
}

# ─── Save a timeout recommendation to DB ──────────────────────────────────────
save_timeout_recommendation() {
    local repo_hash="${1:-}"
    local stage_type="${2:?stage_type required}"
    local p50="${3:-0}" p95="${4:-0}" p99="${5:-0}"
    local sample_count="${6:-0}" recommended="${7:-0}"

    if type _db_exec >/dev/null 2>&1; then
        local ts
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        _db_exec "INSERT INTO timeout_recommendations (repo_hash, stage_type, p50, p95, p99, sample_count, recommended_timeout, last_calculated_at) VALUES ('${repo_hash}', '${stage_type}', ${p50}, ${p95}, ${p99}, ${sample_count}, ${recommended}, '${ts}') ON CONFLICT(repo_hash, stage_type) DO UPDATE SET p50=${p50}, p95=${p95}, p99=${p99}, sample_count=${sample_count}, recommended_timeout=${recommended}, last_calculated_at='${ts}';" 2>/dev/null || true
    fi
}
