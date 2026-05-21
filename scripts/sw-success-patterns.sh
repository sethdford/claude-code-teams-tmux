#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Success Pattern CLI wrapper for the injection engine                     ║
# ║  Exposes: index, score, inject, report, forget                           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/lib/success-patterns.sh" ]] && source "$SCRIPT_DIR/lib/success-patterns.sh"

VERSION="3.3.0"

usage() {
    cat <<EOF
Usage: shipwright success-patterns <subcommand> [options]

Subcommands:
  index                          Index patterns in memory
  score --issue <num>           Score issue against historical patterns
  inject --issue <num>          Inject top patterns into pipeline context
  report                        Show effectiveness report
  forget <pattern_id>           Remove pattern from effectiveness tracking

Options:
  --threshold <num>             Similarity threshold (default: 60)
  --max-k <num>                 Max patterns to return (default: 3)

Examples:
  shipwright success-patterns index
  shipwright success-patterns score --issue 513
  shipwright success-patterns report
EOF
    exit 0
}

[[ $# -eq 0 ]] && usage

cmd="${1:-}"
shift || true

case "$cmd" in
    index)
        patterns=$(sp_load_patterns)
        count=$(echo "$patterns" | jq 'length' 2>/dev/null || echo 0)
        echo "✓ Indexed $count patterns from $(sp_paths)"
        ;;
    score)
        issue_num=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --issue) issue_num="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -z "$issue_num" ]] && { echo "Missing --issue"; exit 1; }

        patterns=$(sp_load_patterns)
        scores=$(sp_score_issue "Issue #$issue_num" "[]" "[]" "$patterns")
        echo "Scores for issue #$issue_num:"
        echo "$scores" | jq '.[0:5] | .[] | {id: .pattern_id[0:12], score}'
        ;;
    inject)
        issue_num=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --issue) issue_num="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -z "$issue_num" ]] && { echo "Missing --issue"; exit 1; }

        patterns=$(sp_load_patterns)
        scores=$(sp_score_issue "Issue #$issue_num" "[]" "[]" "$patterns")
        top_k=$(sp_top_k "$scores" 60 3)
        fragment=$(sp_render_injection "$patterns" "$top_k")
        echo "$fragment"
        ;;
    report)
        report=$(sp_effectiveness_report)
        echo "Success Pattern Effectiveness:"
        echo "$report" | jq '.'
        ;;
    forget)
        pattern_id="${1:-}"
        [[ -z "$pattern_id" ]] && { echo "Missing pattern ID"; exit 1; }
        echo "✓ Marked pattern $pattern_id for removal (not yet implemented)"
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        usage
        ;;
esac
