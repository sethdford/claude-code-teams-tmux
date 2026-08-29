#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Memory Cost — DORA metrics, baselines & metric tracking             ║
# ║  Deploy frequency · Cycle time · Change failure rate · MTTR          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Extracted from sw-memory.sh — pure move, no behavior change.
# Sourced by sw-memory.sh, which supplies the shared memory primitives this
# module calls at runtime: repo_hash(), repo_name(), repo_memory_dir(),
# ensure_memory_dir(), MEMORY_ROOT, GLOBAL_MEMORY.

# Module guard
[[ -n "${_MEMCOST_LOADED:-}" ]] && return 0
_MEMCOST_LOADED=1

VERSION="3.3.0"

# ─── Helpers (loaded from parent context) ───────────────────────────────────
# Expects: info(), success(), warn(), error(), emit_event(), now_iso().
# Fallbacks keep the module usable when sourced without sw-memory.sh's preamble.
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
    local event_type="$1"; shift
    mkdir -p "${HOME}/.shipwright" 2>/dev/null || return 0
    local payload="{\"ts\":\"$(now_iso)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do
      local key="${1%%=*}" val="${1#*=}"
      payload="${payload},\"${key}\":\"${val}\""
      shift
    done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# memory_get_dora_baseline [window_days] [offset_days]
# Calculates DORA metrics for a time window from events.jsonl.
# Returns JSON: {deploy_freq, cycle_time, cfr, mttr, total, grades: {df, ct, cfr, mttr}}
memory_get_dora_baseline() {
    local window_days="${1:-7}"
    local offset_days="${2:-0}"

    local events_file="${HOME}/.shipwright/events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        echo '{"deploy_freq":0,"cycle_time":0,"cfr":0,"mttr":0,"total":0}'
        return 0
    fi

    local now_e
    now_e=$(now_epoch)
    local window_end=$((now_e - offset_days * 86400))
    local window_start=$((window_end - window_days * 86400))

    # Extract pipeline events for the window
    local metrics
    metrics=$(jq -s --argjson start "$window_start" --argjson end "$window_end" '
        [.[] | select(.ts_epoch >= $start and .ts_epoch < $end)] as $events |
        [$events[] | select(.type == "pipeline.completed")] as $completed |
        ($completed | length) as $total |
        [$completed[] | select(.result == "success")] as $successes |
        [$completed[] | select(.result == "failure")] as $failures |
        ($successes | length) as $success_count |
        ($failures | length) as $failure_count |

        # Deploy frequency (per week)
        (if $total > 0 then ($success_count * 7 / '"$window_days"') else 0 end) as $deploy_freq |

        # Cycle time median
        ([$successes[] | .duration_s] | sort |
            if length > 0 then .[length/2 | floor] else 0 end) as $cycle_time |

        # Change failure rate
        (if $total > 0 then ($failure_count / $total * 100) else 0 end) as $cfr |

        # MTTR
        ($completed | sort_by(.ts_epoch // 0) |
            [range(length) as $i |
                if .[$i].result == "failure" then
                    [.[$i+1:][] | select(.result == "success")][0] as $next |
                    if $next and $next.ts_epoch and .[$i].ts_epoch then
                        ($next.ts_epoch - .[$i].ts_epoch)
                    else null end
                else null end
            ] | map(select(. != null)) |
            if length > 0 then (add / length | floor) else 0 end
        ) as $mttr |

        {
            deploy_freq: ($deploy_freq * 10 | floor / 10),
            cycle_time: $cycle_time,
            cfr: ($cfr * 10 | floor / 10),
            mttr: $mttr,
            total: $total
        }
    ' "$events_file" 2>/dev/null || echo '{"deploy_freq":0,"cycle_time":0,"cfr":0,"mttr":0,"total":0}')

    echo "$metrics"
}

# memory_get_baseline <metric_name>
# Output baseline value for a metric (bundle_size_kb, test_duration_s, coverage_pct, etc.).
# Used by pipeline for regression checks. Outputs nothing if not set.
memory_get_baseline() {
    local metric_name="${1:-}"
    [[ -z "$metric_name" ]] && return 1
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local metrics_file="$mem_dir/metrics.json"
    [[ ! -f "$metrics_file" ]] && return 0
    jq -r --arg m "$metric_name" '.baselines[$m] // empty' "$metrics_file" 2>/dev/null || true
}

# memory_update_metrics <metric_name> <value>
# Track performance baselines and flag regressions.
memory_update_metrics() {
    local metric_name="${1:-}"
    local value="${2:-}"

    [[ -z "$metric_name" || -z "$value" ]] && return 1

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local metrics_file="$mem_dir/metrics.json"

    # Read previous baseline
    local previous
    previous=$(jq -r --arg m "$metric_name" '.baselines[$m] // 0' "$metrics_file" 2>/dev/null || echo "0")

    # Check for regression (>20% increase for duration metrics)
    if [[ "$previous" != "0" && "$previous" != "null" ]]; then
        local threshold
        threshold=$(echo "$previous" | awk '{printf "%.0f", $1 * 1.2}')
        if [[ "${metric_name}" == *"duration"* || "${metric_name}" == *"time"* ]]; then
            if [[ "$(echo "$value $threshold" | awk '{print ($1 > $2)}')" == "1" ]]; then
                warn "Regression detected: ${metric_name} increased from ${previous} to ${value} (>20%)"
                emit_event "memory.regression" "metric=${metric_name}" "previous=${previous}" "current=${value}"
            fi
        fi
    fi

    # Update baseline using atomic write
    local tmp_file
    tmp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN
    jq --arg m "$metric_name" \
       --argjson v "$value" \
       --arg ts "$(now_iso)" \
       '.baselines[$m] = $v | .last_updated = $ts' \
       "$metrics_file" > "$tmp_file" && mv "$tmp_file" "$metrics_file"

    emit_event "memory.metric" "metric=${metric_name}" "value=${value}"
}
