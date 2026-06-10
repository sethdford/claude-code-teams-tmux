#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-error-quality — Error Feedback Loop Quality Analyzer CLI              ║
# ║                                                                           ║
# ║  Measures error-message actionability, correlates quality with fix        ║
# ║  success, surfaces the lowest-actionability error types, and generates    ║
# ║  improved error templates for injection into future build iterations.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/error-quality-analyzer.sh"

usage() {
    cat <<'EOF'
Usage: shipwright errors <command> [args]

Commands:
  score <error-summary.json>     Score every error line in a summary file (AC1)
  emit  <error-summary.json>     Emit an error.quality event for an iteration (AC4)
  correlate [events] [min]       Correlate error quality with fix success (AC2)
  offenders [events] [min] [n]   Show the N lowest-actionability error types (AC5)
  templates [events] [min] [n]   Generate improved error templates (AC3)
  report [events] [min] [n]      Human-readable report + template generation

Defaults: events=~/.shipwright/events.jsonl  min=10  n=5
EOF
}

main() {
    local cmd="${1:-report}"
    shift 2>/dev/null || true

    case "$cmd" in
        score)      eqa_score_summary_file "${1:?error-summary.json required}" ;;
        emit)       eqa_emit_iteration_quality "${1:?error-summary.json required}" "${2:-}" ;;
        correlate)  eqa_correlate "${1:-}" "${2:-}" ;;
        offenders)  eqa_top_offenders "${1:-}" "${2:-}" "${3:-}" ;;
        templates)  eqa_generate_templates "${1:-}" "${2:-}" "${3:-}" ;;
        report)     eqa_report "${1:-}" "${2:-}" "${3:-}" ;;
        help|-h|--help) usage ;;
        version|--version) echo "$VERSION" ;;
        *)          echo "Unknown command: $cmd" >&2; usage; exit 1 ;;
    esac
}

main "$@"
