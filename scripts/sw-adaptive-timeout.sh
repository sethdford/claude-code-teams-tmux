#!/usr/bin/env bash
# sw-adaptive-timeout.sh — Adaptive Stage Timeout Engine CLI
# Provides commands to learn, report, reset, and manage adaptive timeouts.
# Usage: shipwright adaptive-timeout [command] [args]

set -euo pipefail

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

trap "exit 1" ERR

# ─── Source Dependencies ───────────────────────────────────────────────────

[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/adaptive-timeout.sh" ]] && source "$SCRIPT_DIR/lib/adaptive-timeout.sh"

# ─── Help Text ─────────────────────────────────────────────────────────────

_usage() {
    cat <<'EOF'
Usage: shipwright adaptive-timeout [command] [options]

Commands:
  learn                        Learn and apply adaptive timeouts (default)
  report                       Show adaptive timeout statistics and recommendations
  reset                        Clear all historical timeout data (for testing)
  record <stage> <duration>    Manually record a stage duration
  check-anomaly <stage>        Check if a stage duration is anomalous

Options for 'record':
  --stage <name>              Stage name (required)
  --duration <seconds>        Duration in seconds (required)
  --template <name>           Pipeline template (standard/fast/full/hotfix/etc)
  --complexity <level>        Complexity level (simple/medium/complex/critical)

Options for 'check-anomaly':
  --stage <name>              Stage name (required)
  --duration <seconds>        Duration in seconds to check (required)

Environment Variables:
  ADAPTIVE_TIMEOUT_ENABLED     Enable/disable adaptive timeouts (true|false)
  TIMEOUT_HISTORY_FILE         Override history file path
  TIMEOUT_MIN_SAMPLES          Minimum samples before using adaptive (default: 10)
  TIMEOUT_BUFFER_PCT           Buffer percentage for P95 (default: 20)

Examples:
  shipwright adaptive-timeout report
  shipwright adaptive-timeout learn
  shipwright adaptive-timeout record --stage build --duration 1234
  shipwright adaptive-timeout check-anomaly --stage build --duration 2000
  shipwright adaptive-timeout reset

See ~/.shipwright/optimization/stage-durations.jsonl for historical data.
EOF
}

# ─── Helpers ────────────────────────────────────────────────────────────────

_cmd_record() {
    local stage="" duration="" template="standard" complexity="medium"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage) stage="$2"; shift 2 ;;
            --duration) duration="$2"; shift 2 ;;
            --template) template="$2"; shift 2 ;;
            --complexity) complexity="$2"; shift 2 ;;
            *)
                error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ -z "$stage" || -z "$duration" ]]; then
        error "Missing required arguments: --stage and --duration"
        return 1
    fi

    if ! timeout_record "$stage" "$duration" "$template" "$complexity"; then
        error "Failed to record stage duration"
        return 1
    fi

    success "Recorded: $stage completed in ${duration}s (template: $template, complexity: $complexity)"
    emit_event "adaptive_timeout" "action=record" "stage=$stage" "duration_s=$duration" "template=$template"
}

_cmd_learn() {
    timeout_init
    info "Analyzing historical performance data..."

    local count=0
    local stages=(intake plan design build test review compound_quality pr merge deploy validate monitor)

    for stage in "${stages[@]}"; do
        local samples
        samples=$(timeout_sample_count "$stage") || samples=0
        if [[ "$samples" -gt 0 ]]; then
            local timeout
            timeout=$(timeout_get "$stage")
            success "$stage: $samples samples → adaptive timeout: ${timeout}s"
            count=$((count + 1))
        fi
    done

    if [[ "$count" -eq 0 ]]; then
        warn "No historical data available yet. Run some pipelines to collect timeout data."
    else
        success "Adaptive timeouts learned from $count stages"
        emit_event "adaptive_timeout" "action=learn" "stages=$count"
    fi
}

_cmd_report() {
    timeout_init
    timeout_report
}

_cmd_reset() {
    if timeout_reset; then
        success "Historical timeout data cleared"
        emit_event "adaptive_timeout" "action=reset"
    else
        error "Failed to clear historical data"
        return 1
    fi
}

_cmd_check_anomaly() {
    local stage="" duration=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stage) stage="$2"; shift 2 ;;
            --duration) duration="$2"; shift 2 ;;
            *)
                error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    if [[ -z "$stage" || -z "$duration" ]]; then
        error "Missing required arguments: --stage and --duration"
        return 1
    fi

    timeout_init

    local sample_count
    sample_count=$(timeout_sample_count "$stage") || sample_count=0

    if [[ "$sample_count" -lt "$TIMEOUT_MIN_SAMPLES" ]]; then
        info "Not enough data for $stage (${sample_count}/${TIMEOUT_MIN_SAMPLES} samples)"
        emit_event "adaptive_timeout" "action=check_anomaly" "stage=$stage" "duration_s=$duration" "result=insufficient_data"
        return 0
    fi

    local p95
    p95=$(timeout_calculate_p95 "$stage") || p95=""

    if [[ -z "$p95" ]]; then
        warn "Could not calculate P95 for $stage"
        emit_event "adaptive_timeout" "action=check_anomaly" "stage=$stage" "duration_s=$duration" "result=calc_failed"
        return 1
    fi

    if [[ "$duration" -gt "$p95" ]]; then
        local excess
        excess=$(( (duration - p95) * 100 / p95 ))
        warn "$stage: Duration $duration exceeds P95 threshold ($p95) by ${excess}%"
        emit_event "adaptive_timeout" "action=check_anomaly" "stage=$stage" "duration_s=$duration" "p95=$p95" "result=anomaly"
    else
        success "$stage: Duration $duration is within P95 threshold ($p95)"
        emit_event "adaptive_timeout" "action=check_anomaly" "stage=$stage" "duration_s=$duration" "p95=$p95" "result=normal"
    fi
}

# ─── Main Dispatcher ────────────────────────────────────────────────────────

main() {
    local cmd="${1:-learn}"

    case "$cmd" in
        help|--help|-h)
            _usage
            exit 0
            ;;
        learn)
            shift || true
            _cmd_learn "$@"
            ;;
        report)
            shift || true
            _cmd_report "$@"
            ;;
        reset)
            shift || true
            _cmd_reset "$@"
            ;;
        record)
            shift || true
            _cmd_record "$@"
            ;;
        check-anomaly)
            shift || true
            _cmd_check_anomaly "$@"
            ;;
        *)
            error "Unknown command: $cmd"
            _usage
            exit 1
            ;;
    esac
}

main "$@"
