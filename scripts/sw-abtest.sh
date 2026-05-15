#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   sw-abtest.sh — Cross-pipeline A/B testing CLI
#
#   Generalized A/B framework for validating any intelligence
#   feature (memory, adversarial, simulation, architecture,
#   composer, predictive) across pipeline runs.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

VERSION="3.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/helpers.sh
source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=lib/ab-test.sh
source "$SCRIPT_DIR/lib/ab-test.sh"

show_help() {
    cat <<EOF
shipwright abtest v${VERSION} — Cross-pipeline A/B testing framework

USAGE
  shipwright abtest <command> [args]

COMMANDS
  assign <experiment> [ratio]
        Assign control or treatment for a pipeline run (default ratio 0.2)
  record <experiment> <pipeline_id> <group> <iterations> <cost> <test_failures> <status>
        Record a completed pipeline result
  report <experiment>
        Show control vs treatment comparison report
  status <experiment>
        Emit JSON summary of sample sizes for an experiment
  list
        List known experiments with recorded results
  help, --help, -h
        Show this help

ENVIRONMENT
  AB_BASE_DIR   Override results directory (default \$HOME/.shipwright/abtest)

EXAMPLES
  shipwright abtest assign adversarial 0.5
  shipwright abtest record adversarial pipe-123 treatment 4 1200 0 success
  shipwright abtest report adversarial
  shipwright abtest list
EOF
}

cmd_assign() {
    local experiment="${1:-}" ratio="${2:-0.2}"
    if [[ -z "$experiment" ]]; then
        error "Usage: shipwright abtest assign <experiment> [ratio]"
        return 1
    fi
    ab_assign "$experiment" "$ratio"
}

cmd_record() {
    if [[ $# -lt 7 ]]; then
        error "Usage: shipwright abtest record <experiment> <pipeline_id> <group> <iterations> <cost> <test_failures> <status>"
        return 1
    fi
    ab_record_result "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

cmd_report() {
    local experiment="${1:-}"
    if [[ -z "$experiment" ]]; then
        error "Usage: shipwright abtest report <experiment>"
        return 1
    fi
    ab_report "$experiment"
}

cmd_status() {
    local experiment="${1:-}"
    if [[ -z "$experiment" ]]; then
        error "Usage: shipwright abtest status <experiment>"
        return 1
    fi
    ab_status "$experiment"
}

cmd_list() {
    ab_list
}

main() {
    local cmd="${1:-help}"
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        assign) cmd_assign "$@" ;;
        record) cmd_record "$@" ;;
        report) cmd_report "$@" ;;
        status) cmd_status "$@" ;;
        list)   cmd_list "$@" ;;
        help|--help|-h) show_help ;;
        --version|-v) echo "$VERSION" ;;
        *) error "Unknown command: $cmd"; show_help; return 1 ;;
    esac
}

main "$@"
