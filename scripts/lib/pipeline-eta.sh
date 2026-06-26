# pipeline-eta.sh — Shared pipeline progress / ETA estimation
#
# Single source of truth for the estimation math consumed by sw-status.sh (bash)
# and mirrored by dashboard/server.ts (TypeScript). Given the set of enabled and
# completed stages plus elapsed time, it computes completion percentage and an
# ETA in seconds from P50/P90 historical stage durations stored in SQLite.
#
# Algorithm (kept identical to the TS mirror in dashboard/server.ts):
#   1. progress_pct = completed_stages / total_enabled_stages * 100
#   2. For each not-yet-complete stage with >= ETA_MIN_SAMPLES historical
#      durations, filter outliers via the IQR method, then take P50/P90.
#   3. eta_seconds = Σ P50(remaining), eta_p90_seconds = Σ P90(remaining)
#   4. If any remaining stage lacks enough history, basis = "stage_count"
#      (no time estimate) — graceful degradation, never a bogus ETA.
#
# Source from any script: requires `jq`. now_epoch/emit_event/query_stage_durations
# are used when available and degrade gracefully when absent.
[[ -n "${_PIPELINE_ETA_LOADED:-}" ]] && return 0
_PIPELINE_ETA_LOADED=1

VERSION="3.3.0"

# Tunables (env-overridable)
ETA_MIN_SAMPLES="${ETA_MIN_SAMPLES:-3}"          # min historical runs per stage for an ETA
ETA_CACHE_TTL="${ETA_CACHE_TTL:-86400}"          # 24h cache for the duration map
ETA_CACHE_FILE="${ETA_CACHE_FILE:-.claude/intelligence-cache.json}"

# Fallbacks for helpers normally provided by helpers.sh
[[ "$(type -t now_epoch 2>/dev/null)" == "function" ]] || now_epoch() { date +%s; }

# ─── Statistics helpers ─────────────────────────────────────────────────────

# eta_percentile <json-array> <p>  →  numeric percentile (linear interpolation
# between neighbours, matching scripts/sw-adaptive.sh::percentile).
eta_percentile() {
    local arr="$1" p="$2"
    jq -n --argjson arr "$arr" --arg p "$p" '
        ($arr | map(tonumber?) | sort) as $sorted
        | ($sorted | length) as $len
        | if $len == 0 then null
          else
            ((($p | tonumber) / 100) * ($len - 1) | floor) as $idx
            | if $idx >= $len - 1 then $sorted[-1]
              else ($sorted[$idx] + $sorted[$idx + 1]) / 2 end
          end'
}

# eta_filter_outliers <json-array>  →  json-array with IQR outliers removed.
# Keeps values in [Q1 - 1.5*IQR, Q3 + 1.5*IQR]. Arrays smaller than 4 pass through.
eta_filter_outliers() {
    local arr="$1"
    jq -n --argjson arr "$arr" '
        ($arr | map(tonumber?) | sort) as $s
        | ($s | length) as $n
        | if $n < 4 then $s
          else
            (($n - 1) * 0.25 | floor) as $qi1
            | (($n - 1) * 0.75 | floor) as $qi3
            | $s[$qi1] as $q1
            | $s[$qi3] as $q3
            | ($q3 - $q1) as $iqr
            | ($q1 - 1.5 * $iqr) as $lo
            | ($q3 + 1.5 * $iqr) as $hi
            | [ $s[] | select(. >= $lo and . <= $hi) ]
          end'
}

# ─── Duration map (cached) ──────────────────────────────────────────────────

# eta_cache_store <key> <durations-json> <now-epoch>
# Merges the duration map into ETA_CACHE_FILE under .eta[<key>] atomically,
# without disturbing other top-level keys (e.g. intelligence "entries").
eta_cache_store() {
    local key="$1" durations="$2" now="$3"
    [[ -z "${ETA_CACHE_FILE:-}" ]] && return 0
    mkdir -p "$(dirname "$ETA_CACHE_FILE")" 2>/dev/null || true
    local base="{}"
    [[ -f "$ETA_CACHE_FILE" ]] && base=$(cat "$ETA_CACHE_FILE" 2>/dev/null || echo "{}")
    [[ -z "$base" ]] && base="{}"
    local tmp="${ETA_CACHE_FILE}.eta.tmp.$$"
    if echo "$base" | jq \
        --arg k "$key" --argjson durs "$durations" --argjson now "$now" '
        .eta = (.eta // {}) | .eta[$k] = {durations: $durs, cached_at: $now}' \
        > "$tmp" 2>/dev/null; then
        mv "$tmp" "$ETA_CACHE_FILE" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
}

# eta_duration_map  →  JSON {stage:[durations]} for all stages, cached 24h.
# Reads from cache when fresh; otherwise queries SQLite and refreshes the cache.
eta_duration_map() {
    local now key cached
    now=$(now_epoch)
    key="stage_durations"

    if [[ -f "$ETA_CACHE_FILE" ]]; then
        cached=$(jq -c \
            --arg k "$key" --argjson now "$now" --argjson ttl "$ETA_CACHE_TTL" '
            (.eta[$k] // empty)
            | select((.cached_at // 0) + $ttl > $now)
            | .durations' "$ETA_CACHE_FILE" 2>/dev/null || true)
        if [[ -n "$cached" && "$cached" != "null" ]]; then
            echo "$cached"
            return 0
        fi
    fi

    local durs="{}"
    if type query_stage_durations >/dev/null 2>&1 && type db_available >/dev/null 2>&1 && db_available 2>/dev/null; then
        durs=$(query_stage_durations 2>/dev/null || echo "{}")
    fi
    [[ -z "$durs" || "$durs" == "null" ]] && durs="{}"

    eta_cache_store "$key" "$durs" "$now"
    echo "$durs"
}

# ─── Estimation ─────────────────────────────────────────────────────────────

# pipeline_eta_estimate <enabled_csv> <completed_csv> [elapsed_secs] [duration_map_json]
# Emits a JSON object:
#   {progress_pct, eta_seconds, eta_p90_seconds, confidence, basis,
#    total_stages, completed_stages, elapsed_seconds}
# basis ∈ {p50_history, stage_count, complete}; eta is null when basis=stage_count.
pipeline_eta_estimate() {
    local enabled_csv="$1" completed_csv="${2:-}" elapsed_secs="${3:-0}" dmap="${4:-}"

    local enabled completed
    enabled=$(echo "$enabled_csv" | tr ',' ' ')
    completed=" $(echo "$completed_csv" | tr ',' ' ' | xargs) "

    local total=0 done=0 s
    for s in $enabled; do
        [[ -z "$s" ]] && continue
        total=$((total + 1))
        [[ "$completed" == *" $s "* ]] && done=$((done + 1))
    done

    local progress_pct=0
    [[ "$total" -gt 0 ]] && progress_pct=$(( done * 100 / total ))

    [[ -z "$dmap" ]] && dmap=$(eta_duration_map)
    [[ -z "$dmap" || "$dmap" == "null" ]] && dmap="{}"

    local remaining_p50=0 remaining_p90=0 min_samples=999999 covered=1 remaining_count=0
    for s in $enabled; do
        [[ -z "$s" ]] && continue
        [[ "$completed" == *" $s "* ]] && continue
        remaining_count=$((remaining_count + 1))

        local raw n filtered p50 p90
        raw=$(echo "$dmap" | jq -c --arg s "$s" '.[$s] // []' 2>/dev/null || echo "[]")
        n=$(echo "$raw" | jq 'length' 2>/dev/null || echo 0)
        if [[ "${n:-0}" -lt "$ETA_MIN_SAMPLES" ]]; then
            covered=0
            continue
        fi
        filtered=$(eta_filter_outliers "$raw")
        p50=$(eta_percentile "$filtered" 50)
        p90=$(eta_percentile "$filtered" 90)
        remaining_p50=$(awk -v a="$remaining_p50" -v b="$p50" 'BEGIN{printf "%d", a+b}')
        remaining_p90=$(awk -v a="$remaining_p90" -v b="$p90" 'BEGIN{printf "%d", a+b}')
        [[ "$n" -lt "$min_samples" ]] && min_samples="$n"
    done

    local eta_seconds="null" eta_p90="null" basis confidence
    if [[ "$remaining_count" -le 0 ]]; then
        eta_seconds=0; eta_p90=0; basis="complete"; confidence="high"
    elif [[ "$covered" -eq 1 ]]; then
        eta_seconds="$remaining_p50"; eta_p90="$remaining_p90"; basis="p50_history"
        if   [[ "$min_samples" -ge 10 ]]; then confidence="high"
        elif [[ "$min_samples" -ge 5  ]]; then confidence="medium"
        else confidence="low"; fi
    else
        basis="stage_count"; confidence="none"
    fi

    # Observability: record the estimate so accuracy can be tracked post-run.
    if type emit_event >/dev/null 2>&1; then
        emit_event "eta.computed" "progress=$progress_pct" "eta=$eta_seconds" \
            "basis=$basis" "confidence=$confidence" 2>/dev/null || true
    fi

    jq -nc \
        --argjson pct "$progress_pct" --argjson eta "$eta_seconds" --argjson eta90 "$eta_p90" \
        --arg basis "$basis" --arg conf "$confidence" \
        --argjson total "$total" --argjson done "$done" --argjson elapsed "${elapsed_secs:-0}" '
        {progress_pct: $pct, eta_seconds: $eta, eta_p90_seconds: $eta90,
         confidence: $conf, basis: $basis, total_stages: $total,
         completed_stages: $done, elapsed_seconds: $elapsed}'
}

# pipeline_eta_format <estimate-json>  →  human string for sw-status.
#   p50_history → "Progress: 42% (~18 min remaining)"
#   complete    → "Progress: 100% (complete)"
#   stage_count → "Progress: 4/9 stages"
pipeline_eta_format() {
    local json="$1"
    local pct basis eta total done
    pct=$(echo "$json"   | jq -r '.progress_pct')
    basis=$(echo "$json" | jq -r '.basis')
    eta=$(echo "$json"   | jq -r '.eta_seconds')
    total=$(echo "$json" | jq -r '.total_stages')
    done=$(echo "$json"  | jq -r '.completed_stages')

    if [[ "$basis" == "p50_history" && "$eta" != "null" ]]; then
        local mins=$(( (eta + 30) / 60 ))
        if [[ "$mins" -lt 1 ]]; then
            echo "Progress: ${pct}% (~${eta}s remaining)"
        else
            echo "Progress: ${pct}% (~${mins} min remaining)"
        fi
    elif [[ "$basis" == "complete" ]]; then
        echo "Progress: 100% (complete)"
    else
        echo "Progress: ${done}/${total} stages"
    fi
}
