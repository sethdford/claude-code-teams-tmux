#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright stage-profiler — Stage Duration Profiler                      ║
# ║  Percentile profiles · Regression detection · Bottleneck alerts           ║
# ║  Budget analysis · Trend tracking · Dashboard widgets                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded
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
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

# Source profiler library
# shellcheck source=lib/stage-profiler.sh
source "$SCRIPT_DIR/lib/stage-profiler.sh"

# ─── Subcommands ───────────────────────────────────────────────────────────

cmd_profile() {
    local stage="${1:-}"
    if [[ -n "$stage" ]]; then
        profiler_compute_stats "$stage"
    else
        profiler_report "text"
    fi
}

cmd_check() {
    local stage="${1:-}" duration="${2:-}"
    local exit_code=0

    if [[ -n "$stage" ]] && [[ -n "$duration" ]]; then
        # Check specific stage/duration
        local result
        result=$(profiler_check_regression "$stage" "$duration" 2>/dev/null) || true
        if [[ -n "$result" ]]; then
            echo "$result"
            exit_code=2
        else
            success "No regression detected for ${stage} at ${duration}s"
        fi
    else
        # Check all stages against their latest durations from events
        info "Checking all stages for regressions..."
        local found=0

        for s in $PROFILER_STAGES; do
            local latest_dur
            latest_dur=$(_profiler_get_durations "$s" 1 2>/dev/null | head -n 1) || continue
            [[ -z "$latest_dur" ]] && continue

            local result
            result=$(profiler_check_regression "$s" "$latest_dur" 2>/dev/null) || true
            if [[ -n "$result" ]]; then
                echo "$result"
                found=$((found + 1))
            fi
        done

        if [[ "$found" -gt 0 ]]; then
            warn "${found} regression(s) detected"
            exit_code=2
        else
            success "No regressions detected"
        fi
    fi

    return $exit_code
}

cmd_bottlenecks() {
    local days="${1:-7}" top_n="${2:-5}"
    local result
    result=$(profiler_bottlenecks "$days" "$top_n")

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null) || count=0

    if [[ "$count" -eq 0 ]]; then
        info "No bottleneck data available"
        return 0
    fi

    echo ""
    printf "├─ Top %d Bottlenecks (last %d days)\n" "$top_n" "$days"
    printf "│\n"
    printf "│  %-20s %10s %8s\n" "Stage" "Mean" "Samples"
    printf "│  %s\n" "$(printf '%.0s─' {1..45})"

    echo "$result" | jq -r '.[] | [.stage, .mean_s, .samples] | @tsv' 2>/dev/null | \
    while IFS=$'\t' read -r stage mean samples; do
        local formatted
        formatted=$(format_duration "$mean")
        printf "│  %-20s %10s %8s\n" "$stage" "$formatted" "$samples"
    done

    echo ""
}

cmd_budget() {
    local result
    result=$(profiler_budget)

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null) || count=0

    if [[ "$count" -eq 0 ]]; then
        success "All stages within timeout budgets"
        return 0
    fi

    echo ""
    printf "├─ Budget Violations\n"
    printf "│\n"
    printf "│  %-20s %8s %10s %8s\n" "Stage" "P95" "Timeout" "Over"
    printf "│  %s\n" "$(printf '%.0s─' {1..55})"

    echo "$result" | jq -r '.[] | [.stage, .p95, .timeout, .pct_over] | @tsv' 2>/dev/null | \
    while IFS=$'\t' read -r stage p95 timeout pct_over; do
        printf "│  %-20s %7ds %9ds %7d%%\n" "$stage" "$p95" "$timeout" "$pct_over"
    done

    echo ""
    return 2
}

cmd_report() {
    local format="text"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) format="json"; shift ;;
            *) shift ;;
        esac
    done
    profiler_report "$format"
}

cmd_export() {
    profiler_export_adaptive
}

cmd_widget() {
    profiler_widget
}

cmd_trends() {
    local stage="${1:-build}" windows="${2:-7,14,30}"
    local result
    result=$(profiler_trends "$stage" "$windows")

    local format="${3:-text}"
    if [[ "$format" == "json" ]] || [[ "${3:-}" == "--json" ]]; then
        echo "$result"
        return 0
    fi

    echo ""
    printf "├─ Trend: %s\n" "$stage"
    printf "│\n"
    printf "│  %-10s %10s %8s\n" "Window" "Mean" "Samples"
    printf "│  %s\n" "$(printf '%.0s─' {1..35})"

    echo "$result" | jq -r '.windows[] | [.days, .mean_s, .samples] | @tsv' 2>/dev/null | \
    while IFS=$'\t' read -r days mean samples; do
        local formatted
        formatted=$(format_duration "$mean")
        printf "│  %-10s %10s %8s\n" "${days}d" "$formatted" "$samples"
    done

    echo ""
}

cmd_reset() {
    profiler_reset
    success "Profiler history cleared"
}

cmd_help() {
    cat <<'HELP'
shipwright stage-profiler — Stage Duration Profiler

Usage: shipwright stage-profiler <command> [options]

Commands:
  profile [stage]           Show P50/P95/mean/min/max for all or one stage
  check [stage duration]    Detect regressions (exit 2 if found)
  bottlenecks [days] [n]    Rank top N slowest stages (default: 7d, top 5)
  budget                    Identify stages exceeding timeout budgets
  report [--json]           Full profiler report (text or JSON)
  export                    Export data for adaptive timeout engine
  widget                    Dashboard-compatible JSON widget
  trends <stage> [windows]  Show duration trends (default: 7,14,30 day windows)
  reset                     Clear profiler history
  help                      Show this help

Examples:
  shipwright profiler profile build
  shipwright profiler check build 450
  shipwright profiler bottlenecks 14 3
  shipwright profiler report --json
  shipwright profiler trends test 7,14,30

Data Sources (in priority order):
  1. SQLite pipeline_stages table
  2. JSONL stage-durations.jsonl (shared with adaptive-timeout)
  3. events.jsonl fallback (stage.completed events)
HELP
}

# ─── Main ──────────────────────────────────────────────────────────────────

main() {
    profiler_init

    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        profile)      cmd_profile "$@" ;;
        check)        cmd_check "$@" ;;
        bottlenecks)  cmd_bottlenecks "$@" ;;
        budget)       cmd_budget "$@" ;;
        report)       cmd_report "$@" ;;
        export)       cmd_export "$@" ;;
        widget)       cmd_widget "$@" ;;
        trends)       cmd_trends "$@" ;;
        reset)        cmd_reset "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            error "Unknown command: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
