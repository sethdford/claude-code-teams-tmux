#!/usr/bin/env bash
# stage-profiler.sh — Stage Duration Profiler Library
# Percentile computation, regression detection, bottleneck analysis, adaptive export.
# Source from pipeline-execution.sh or sw-stage-profiler.sh.
# Requires: jq, helpers (info, warn, error, emit_event).

[[ -n "${_STAGE_PROFILER_LOADED:-}" ]] && return 0
_STAGE_PROFILER_LOADED=1

# shellcheck disable=SC2034
VERSION="3.2.4"

# ─── Configuration ──────────────────────────────────────────────────────────

# Regression detection thresholds
PROFILER_REGRESSION_PCT=20         # Flag when >20% above P95
PROFILER_REGRESSION_MIN_DELTA=5    # Minimum absolute delta (seconds)
PROFILER_MIN_SAMPLES=5             # Require N samples before detecting regressions
PROFILER_LOOKBACK=100              # Use last N samples for percentile calc

# Data sources
PROFILER_HISTORY_FILE="${HOME}/.shipwright/optimization/stage-durations.jsonl"
PROFILER_DB_FILE="${HOME}/.shipwright/shipwright.db"
PROFILER_EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# Known stages
PROFILER_STAGES="intake plan design build test review compound_quality pr merge deploy validate monitor"

# ─── Initialize ─────────────────────────────────────────────────────────────

profiler_init() {
    local dir
    dir=$(dirname "$PROFILER_HISTORY_FILE")
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || true
    [[ -f "$PROFILER_HISTORY_FILE" ]] || touch "$PROFILER_HISTORY_FILE" 2>/dev/null || true
    return 0
}

# ─── Data Retrieval ─────────────────────────────────────────────────────────

# _profiler_get_durations(stage, [days]) — Get duration values for a stage.
# Tries: 1) SQLite pipeline_stages, 2) JSONL history file, 3) events.jsonl fallback
# Outputs one duration per line (integer seconds).
_profiler_get_durations() {
    local stage="${1:-}" days="${2:-30}"

    # Method 1: SQLite
    if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$PROFILER_DB_FILE" ]]; then
        local cutoff
        cutoff=$(date -u -d "${days} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                 date -u -v-${days}d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
        if [[ -n "$cutoff" ]]; then
            local result
            result=$(sqlite3 "$PROFILER_DB_FILE" \
                "SELECT duration_secs FROM pipeline_stages WHERE stage_name='${stage}' AND status='success' AND created_at >= '${cutoff}' AND duration_secs > 0 ORDER BY created_at DESC LIMIT ${PROFILER_LOOKBACK};" 2>/dev/null) || result=""
            if [[ -n "$result" ]]; then
                echo "$result"
                return 0
            fi
        fi
    fi

    # Method 2: JSONL history file (shared with adaptive-timeout)
    if [[ -f "$PROFILER_HISTORY_FILE" ]]; then
        local result
        result=$(grep "\"stage\":\"$stage\"" "$PROFILER_HISTORY_FILE" 2>/dev/null | \
            tail -n "$PROFILER_LOOKBACK" | \
            jq -r '.duration_s // empty' 2>/dev/null) || result=""
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    fi

    # Method 3: events.jsonl fallback
    if [[ -f "$PROFILER_EVENTS_FILE" ]]; then
        local result
        result=$(grep "\"stage.completed\"" "$PROFILER_EVENTS_FILE" 2>/dev/null | \
            grep "\"stage\":\"$stage\"" 2>/dev/null | \
            tail -n "$PROFILER_LOOKBACK" | \
            jq -r '.duration_s // empty' 2>/dev/null) || result=""
        if [[ -n "$result" ]]; then
            echo "$result"
            return 0
        fi
    fi

    return 1
}

# _profiler_sample_count(stage) — Count samples for a stage.
_profiler_sample_count() {
    local stage="${1:-}"
    local durations
    durations=$(_profiler_get_durations "$stage" 90 2>/dev/null) || durations=""
    if [[ -z "$durations" ]]; then
        echo "0"
        return 0
    fi
    echo "$durations" | wc -l | xargs
}

# ─── Percentile Computation ────────────────────────────────────────────────

# _profiler_percentile(percentile) — Compute percentile from stdin (one value per line).
# $1: percentile as decimal (e.g., 0.50, 0.95)
# Reads values from stdin. Outputs integer result.
_profiler_percentile() {
    local pct="${1:-0.95}"
    awk -v pct="$pct" '{arr[NR]=$1} END {
        n=NR; if (n==0) exit 1
        # Insertion sort
        for (i=2; i<=n; i++) {
            key=arr[i]; j=i-1
            while (j>=1 && arr[j]>key) { arr[j+1]=arr[j]; j-- }
            arr[j+1]=key
        }
        idx=int(n*pct); if (idx<1) idx=1
        printf "%d\n", arr[idx]
    }' 2>/dev/null
}

# profiler_compute_stats(stage) — Compute P50, P95, mean, min, max, count for a stage.
# Output: JSON object with all stats.
profiler_compute_stats() {
    local stage="${1:-}"
    local durations
    durations=$(_profiler_get_durations "$stage" 90 2>/dev/null) || durations=""

    if [[ -z "$durations" ]]; then
        printf '{"stage":"%s","samples":0,"p50":null,"p95":null,"mean":null,"min":null,"max":null}\n' "$stage"
        return 0
    fi

    local count p50 p95 stats_line
    count=$(echo "$durations" | wc -l | xargs)
    p50=$(echo "$durations" | _profiler_percentile 0.50) || p50=0
    p95=$(echo "$durations" | _profiler_percentile 0.95) || p95=0

    # mean, min, max via awk
    stats_line=$(echo "$durations" | awk '{
        sum+=$1; if(NR==1||$1<min)min=$1; if(NR==1||$1>max)max=$1
    } END {
        if(NR>0) printf "%d %d %d", int(sum/NR), min, max; else print "0 0 0"
    }' 2>/dev/null) || stats_line="0 0 0"

    local mean min_val max_val
    read -r mean min_val max_val <<< "$stats_line"

    printf '{"stage":"%s","samples":%d,"p50":%d,"p95":%d,"mean":%d,"min":%d,"max":%d}\n' \
        "$stage" "$count" "$p50" "$p95" "$mean" "$min_val" "$max_val"
}

# ─── Regression Detection ──────────────────────────────────────────────────

# profiler_check_regression(stage, duration_s) — Check if a duration is a regression.
# Returns 0 if regression detected, 1 if normal.
# Outputs JSON with regression details if detected.
profiler_check_regression() {
    local stage="${1:-}" duration_s="${2:-0}"

    # Validate
    if ! [[ "$duration_s" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    local durations
    durations=$(_profiler_get_durations "$stage" 30 2>/dev/null) || durations=""
    if [[ -z "$durations" ]]; then
        return 1
    fi

    local count
    count=$(echo "$durations" | wc -l | xargs)
    if [[ "$count" -lt "$PROFILER_MIN_SAMPLES" ]]; then
        return 1
    fi

    local p95
    p95=$(echo "$durations" | _profiler_percentile 0.95) || p95=0
    if [[ "$p95" -le 0 ]]; then
        return 1
    fi

    # Regression threshold: P95 * (1 + REGRESSION_PCT/100)
    local threshold delta
    threshold=$(( p95 + (p95 * PROFILER_REGRESSION_PCT / 100) ))
    delta=$(( duration_s - p95 ))

    if [[ "$duration_s" -gt "$threshold" ]] && [[ "$delta" -ge "$PROFILER_REGRESSION_MIN_DELTA" ]]; then
        local pct_over
        pct_over=$(( (delta * 100) / p95 ))
        printf '{"stage":"%s","duration_s":%d,"p95":%d,"threshold":%d,"delta":%d,"pct_over":%d,"regression":true}\n' \
            "$stage" "$duration_s" "$p95" "$threshold" "$delta" "$pct_over"
        return 0
    fi

    return 1
}

# ─── Post-Stage Analysis Hook ──────────────────────────────────────────────

# profiler_analyze_stage(stage, duration_s, result) — Called after each stage.
# Checks for regression and emits event if detected. Safe to call in pipeline.
# $1: stage name
# $2: duration in seconds
# $3: result (success/failure)
profiler_analyze_stage() {
    local stage="${1:-}" duration_s="${2:-0}" result="${3:-success}"

    # Only analyze successful stages (failures have external causes)
    if [[ "$result" != "success" ]]; then
        return 0
    fi

    # Check for regression
    local regression_json
    regression_json=$(profiler_check_regression "$stage" "$duration_s" 2>/dev/null) || regression_json=""

    if [[ -n "$regression_json" ]]; then
        local p95 delta pct_over
        p95=$(echo "$regression_json" | jq -r '.p95' 2>/dev/null) || p95=0
        delta=$(echo "$regression_json" | jq -r '.delta' 2>/dev/null) || delta=0
        pct_over=$(echo "$regression_json" | jq -r '.pct_over' 2>/dev/null) || pct_over=0

        warn "Stage ${stage} regression: ${duration_s}s (P95: ${p95}s, +${pct_over}% / +${delta}s)"

        # Emit profiler regression event
        if type emit_event >/dev/null 2>&1; then
            emit_event "profiler.regression" \
                "stage=$stage" \
                "duration_s=$duration_s" \
                "p95=$p95" \
                "delta=$delta" \
                "pct_over=$pct_over"
        fi
    fi

    return 0
}

# ─── Bottleneck Analysis ───────────────────────────────────────────────────

# profiler_bottlenecks([days], [top_n]) — Rank stages by mean duration.
# $1: lookback days (default 7)
# $2: number of results (default 5)
# Outputs JSON array of top bottleneck stages.
profiler_bottlenecks() {
    local days="${1:-7}" top_n="${2:-5}"
    local result="["
    local first=true
    local entries=""

    for stage in $PROFILER_STAGES; do
        local durations
        durations=$(_profiler_get_durations "$stage" "$days" 2>/dev/null) || continue
        [[ -z "$durations" ]] && continue

        local mean count
        count=$(echo "$durations" | wc -l | xargs)
        mean=$(echo "$durations" | awk '{sum+=$1} END {if(NR>0) printf "%d", int(sum/NR); else print 0}' 2>/dev/null) || mean=0
        [[ "$mean" -gt 0 ]] || continue

        entries="${entries}${mean} ${stage} ${count}\n"
    done

    if [[ -z "$entries" ]]; then
        echo "[]"
        return 0
    fi

    # Sort by mean descending, take top N
    local sorted
    sorted=$(printf '%b' "$entries" | sort -rn | head -n "$top_n")

    while IFS=' ' read -r mean stage count; do
        [[ -z "$stage" ]] && continue
        if [[ "$first" == "true" ]]; then
            first=false
        else
            result="${result},"
        fi
        result="${result}{\"stage\":\"${stage}\",\"mean_s\":${mean},\"samples\":${count}}"
    done <<< "$sorted"

    result="${result}]"
    echo "$result"
}

# ─── Budget Analysis ───────────────────────────────────────────────────────

# _profiler_stage_timeout(stage) — Get configured timeout for a stage.
_profiler_stage_timeout() {
    local stage="${1:-}"
    case "$stage" in
        intake)           echo 60 ;;
        plan)             echo 300 ;;
        design)           echo 300 ;;
        build)            echo 1800 ;;
        test)             echo 600 ;;
        review)           echo 600 ;;
        compound_quality) echo 900 ;;
        pr)               echo 120 ;;
        merge)            echo 120 ;;
        deploy)           echo 300 ;;
        validate)         echo 300 ;;
        monitor)          echo 300 ;;
        *)                echo 300 ;;
    esac
}

# profiler_budget() — Identify stages exceeding their timeout budget.
# Outputs JSON array of stages where P95 > timeout.
profiler_budget() {
    local result="["
    local first=true

    for stage in $PROFILER_STAGES; do
        local durations
        durations=$(_profiler_get_durations "$stage" 30 2>/dev/null) || continue
        [[ -z "$durations" ]] && continue

        local count
        count=$(echo "$durations" | wc -l | xargs)
        [[ "$count" -lt "$PROFILER_MIN_SAMPLES" ]] && continue

        local p95 timeout_s
        p95=$(echo "$durations" | _profiler_percentile 0.95) || continue
        timeout_s=$(_profiler_stage_timeout "$stage")

        if [[ "$p95" -gt "$timeout_s" ]]; then
            local pct_over
            pct_over=$(( (p95 - timeout_s) * 100 / timeout_s ))
            if [[ "$first" == "true" ]]; then first=false; else result="${result},"; fi
            result="${result}{\"stage\":\"${stage}\",\"p95\":${p95},\"timeout\":${timeout_s},\"pct_over\":${pct_over}}"
        fi
    done

    result="${result}]"
    echo "$result"
}

# ─── Trends ────────────────────────────────────────────────────────────────

# profiler_trends(stage, [windows]) — Show trend across time windows.
# $1: stage name
# $2: comma-separated day windows (default "7,14,30")
# Outputs JSON with mean per window.
profiler_trends() {
    local stage="${1:-build}" windows="${2:-7,14,30}"
    local result="{\"stage\":\"${stage}\",\"windows\":["
    local first=true

    local IFS=','
    for days in $windows; do
        local durations
        durations=$(_profiler_get_durations "$stage" "$days" 2>/dev/null) || durations=""

        local mean=0 count=0
        if [[ -n "$durations" ]]; then
            count=$(echo "$durations" | wc -l | xargs)
            mean=$(echo "$durations" | awk '{sum+=$1} END {if(NR>0) printf "%d", int(sum/NR); else print 0}' 2>/dev/null) || mean=0
        fi

        if [[ "$first" == "true" ]]; then first=false; else result="${result},"; fi
        result="${result}{\"days\":${days},\"mean_s\":${mean},\"samples\":${count}}"
    done
    unset IFS

    result="${result}]}"
    echo "$result"
}

# ─── Export for Adaptive Timeout ───────────────────────────────────────────

# profiler_export_adaptive() — Export profiler data for adaptive timeout engine.
# Outputs JSON object keyed by stage with P50, P95, samples.
profiler_export_adaptive() {
    local result="{"
    local first=true

    for stage in $PROFILER_STAGES; do
        local stats
        stats=$(profiler_compute_stats "$stage" 2>/dev/null) || continue

        local samples
        samples=$(echo "$stats" | jq -r '.samples' 2>/dev/null) || samples=0
        [[ "$samples" -gt 0 ]] || continue

        if [[ "$first" == "true" ]]; then first=false; else result="${result},"; fi
        result="${result}\"${stage}\":${stats}"
    done

    result="${result}}"
    echo "$result"
}

# ─── Widget ────────────────────────────────────────────────────────────────

# profiler_widget() — Produce dashboard-compatible JSON widget.
profiler_widget() {
    local bottlenecks budget regressions
    bottlenecks=$(profiler_bottlenecks 7 3 2>/dev/null) || bottlenecks="[]"
    budget=$(profiler_budget 2>/dev/null) || budget="[]"

    # Check recent regressions from events
    regressions="[]"
    if [[ -f "$PROFILER_EVENTS_FILE" ]]; then
        regressions=$(grep "\"profiler.regression\"" "$PROFILER_EVENTS_FILE" 2>/dev/null | \
            tail -n 5 | jq -s '.' 2>/dev/null) || regressions="[]"
    fi

    printf '{"type":"stage-profiler","bottlenecks":%s,"budget_violations":%s,"recent_regressions":%s}\n' \
        "$bottlenecks" "$budget" "$regressions"
}

# ─── Full Report ───────────────────────────────────────────────────────────

# profiler_report([format]) — Generate comprehensive profiler report.
# $1: "json" or "text" (default "text")
profiler_report() {
    local format="${1:-text}"

    if [[ "$format" == "json" ]]; then
        local profiles="["
        local first=true
        for stage in $PROFILER_STAGES; do
            local stats
            stats=$(profiler_compute_stats "$stage" 2>/dev/null) || continue
            if [[ "$first" == "true" ]]; then first=false; else profiles="${profiles},"; fi
            profiles="${profiles}${stats}"
        done
        profiles="${profiles}]"

        local bottlenecks budget
        bottlenecks=$(profiler_bottlenecks 7 5 2>/dev/null) || bottlenecks="[]"
        budget=$(profiler_budget 2>/dev/null) || budget="[]"

        printf '{"profiles":%s,"bottlenecks":%s,"budget_violations":%s}\n' \
            "$profiles" "$bottlenecks" "$budget"
        return 0
    fi

    # Text format
    echo ""
    printf "├─ Stage Duration Profile\n"
    printf "│\n"
    printf "│  %-20s %8s %8s %8s %8s %8s %6s\n" "Stage" "P50" "P95" "Mean" "Min" "Max" "N"
    printf "│  %s\n" "$(printf '%.0s─' {1..80})"

    for stage in $PROFILER_STAGES; do
        local stats
        stats=$(profiler_compute_stats "$stage" 2>/dev/null) || continue
        local samples p50 p95 mean min_val max_val
        samples=$(echo "$stats" | jq -r '.samples' 2>/dev/null) || samples=0

        if [[ "$samples" -eq 0 ]]; then
            printf "│  %-20s %8s %8s %8s %8s %8s %6d\n" "$stage" "—" "—" "—" "—" "—" 0
        else
            p50=$(echo "$stats" | jq -r '.p50' 2>/dev/null) || p50=0
            p95=$(echo "$stats" | jq -r '.p95' 2>/dev/null) || p95=0
            mean=$(echo "$stats" | jq -r '.mean' 2>/dev/null) || mean=0
            min_val=$(echo "$stats" | jq -r '.min' 2>/dev/null) || min_val=0
            max_val=$(echo "$stats" | jq -r '.max' 2>/dev/null) || max_val=0
            printf "│  %-20s %7ds %7ds %7ds %7ds %7ds %6d\n" \
                "$stage" "$p50" "$p95" "$mean" "$min_val" "$max_val" "$samples"
        fi
    done

    echo "│"

    # Budget violations
    local budget
    budget=$(profiler_budget 2>/dev/null) || budget="[]"
    local budget_count
    budget_count=$(echo "$budget" | jq 'length' 2>/dev/null) || budget_count=0
    if [[ "$budget_count" -gt 0 ]]; then
        printf "│  ⚠ Budget Violations:\n"
        echo "$budget" | jq -r '.[] | "│    \(.stage): P95=\(.p95)s > timeout=\(.timeout)s (+\(.pct_over)%)"' 2>/dev/null
    fi

    # Bottlenecks
    local bottlenecks
    bottlenecks=$(profiler_bottlenecks 7 5 2>/dev/null) || bottlenecks="[]"
    local bn_count
    bn_count=$(echo "$bottlenecks" | jq 'length' 2>/dev/null) || bn_count=0
    if [[ "$bn_count" -gt 0 ]]; then
        printf "│  Top Bottlenecks (7d):\n"
        echo "$bottlenecks" | jq -r '.[] | "│    \(.stage): mean=\(.mean_s)s (n=\(.samples))"' 2>/dev/null
    fi

    echo ""
}

# ─── Reset ─────────────────────────────────────────────────────────────────

# profiler_reset() — Clear profiler history data.
profiler_reset() {
    if [[ -f "$PROFILER_HISTORY_FILE" ]]; then
        > "$PROFILER_HISTORY_FILE"
    fi
    return 0
}
