#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-template-recommender.sh — Smart Template Recommendation CLI           ║
# ║                                                                           ║
# ║  Recommends the optimal pipeline template for an issue, with a            ║
# ║  confidence score and human-readable reasoning. Tracks recommendation     ║
# ║  accuracy against actual outcomes via a feedback loop.                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.3.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# Bandit selector (optional — enriches with historical success).
# shellcheck source=lib/bandit-selector.sh
[[ -f "$SCRIPT_DIR/lib/bandit-selector.sh" ]] && source "$SCRIPT_DIR/lib/bandit-selector.sh" 2>/dev/null || true

# Core engine.
# shellcheck source=lib/template-recommender.sh
source "$SCRIPT_DIR/lib/template-recommender.sh"

: "${CYAN:=}" "${GREEN:=}" "${YELLOW:=}" "${DIM:=}" "${BOLD:=}" "${RESET:=}"

show_help() {
    cat <<EOF
USAGE
  shipwright template <command> [OPTIONS]

DESCRIPTION
  Smart template recommendation engine. Analyzes an issue's labels, description,
  complexity, repo characteristics, and historical outcomes to recommend the
  optimal pipeline template with a confidence score and reasoning.

COMMANDS
  recommend     Recommend a template for an issue
  explain       Show the full score breakdown for an issue
  feedback      Record the actual template + outcome for an issue
  accuracy      Show recommended-vs-actual accuracy from the feedback log

OPTIONS (recommend / explain)
  --issue <N>          Fetch issue title/body/labels from GitHub
  --goal "<text>"      Use a goal description instead of a GitHub issue
  --labels "a,b,c"     Comma-separated labels (with --goal)
  --json               Emit raw JSON instead of human output

OPTIONS (feedback)
  --issue <N>          Issue number
  --template <name>    The template actually used
  --outcome <result>   success | failure

OPTIONS (global)
  --help, -h           Show this help text
  --version, -v        Show version

EXAMPLES
  shipwright template recommend --issue 624
  shipwright template recommend --goal "fix typo in README" --labels docs
  shipwright template recommend --issue 624 --json
  shipwright template explain --goal "refactor auth module" --labels security
  shipwright template feedback --issue 624 --template full --outcome success
  shipwright template accuracy
EOF
}

# Build issue JSON from --issue (GitHub) or --goal/--labels (offline).
_build_issue_json() {
    local issue_num="$1" goal="$2" labels="$3"

    if [[ -n "$issue_num" && "${NO_GITHUB:-false}" != "true" ]] && command -v gh >/dev/null 2>&1; then
        local fetched
        fetched=$(gh issue view "$issue_num" --json title,body,labels 2>/dev/null || echo "")
        if [[ -n "$fetched" ]]; then
            echo "$fetched"
            return 0
        fi
        warn "Could not fetch issue #$issue_num from GitHub; falling back to --goal" >&2
    fi

    # Offline / goal-based.
    local labels_json="[]"
    if [[ -n "$labels" ]]; then
        labels_json=$(echo "$labels" | jq -R 'split(",") | map(select(length > 0))' 2>/dev/null || echo "[]")
    fi
    local title="$goal"
    [[ -z "$title" && -n "$issue_num" ]] && title="Issue #$issue_num"
    jq -n --arg title "$title" --arg body "$goal" --argjson labels "$labels_json" \
        '{title: $title, body: $body, labels: $labels}'
}

_print_human() {
    local rec_json="$1"
    local template confidence issue_type
    template=$(echo "$rec_json" | jq -r '.template')
    confidence=$(echo "$rec_json" | jq -r '.confidence')
    issue_type=$(echo "$rec_json" | jq -r '.signals.issue_type')

    echo
    echo -e "  ${BOLD}Recommended template:${RESET} ${CYAN}${template}${RESET}"
    echo -e "  ${BOLD}Confidence:${RESET} ${confidence}%   ${DIM}(issue type: ${issue_type})${RESET}"
    echo
    echo -e "  ${BOLD}Reasoning:${RESET}"
    echo "$rec_json" | jq -r '.reasoning[]' | while IFS= read -r line; do
        echo -e "    ${DIM}•${RESET} ${line}"
    done
    echo
}

cmd_recommend() {
    local issue_num="" goal="" labels="" json_out=false explain=false
    [[ "${1:-}" == "--explain-mode" ]] && { explain=true; shift; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)   issue_num="$2"; shift 2 ;;
            --goal)    goal="$2"; shift 2 ;;
            --labels)  labels="$2"; shift 2 ;;
            --json)    json_out=true; shift ;;
            *) error "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$issue_num" && -z "$goal" ]]; then
        error "Provide --issue <N> or --goal \"<text>\""
        return 1
    fi

    local issue_json rec_json
    issue_json=$(_build_issue_json "$issue_num" "$goal" "$labels")
    rec_json=$(recommend_template "$issue_json")

    # Record the recommendation (not yet applied) regardless of output format.
    if [[ -n "$issue_num" ]]; then
        local t c
        t=$(echo "$rec_json" | jq -r '.template')
        c=$(echo "$rec_json" | jq -r '.confidence')
        tr_record_recommendation "$issue_num" "$t" "$c" "false"
    fi

    if [[ "$json_out" == "true" ]]; then
        echo "$rec_json"
        return 0
    fi

    if [[ "$explain" == "true" ]]; then
        _print_human "$rec_json"
        echo -e "  ${BOLD}Score breakdown:${RESET}"
        echo "$rec_json" | jq -r '.scores | to_entries[] | "    \(.key): \(.value)"'
        echo
    else
        _print_human "$rec_json"
    fi
}

cmd_feedback() {
    local issue_num="" template="" outcome=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)    issue_num="$2"; shift 2 ;;
            --template) template="$2"; shift 2 ;;
            --outcome)  outcome="$2"; shift 2 ;;
            *) error "Unknown option: $1"; return 1 ;;
        esac
    done
    if [[ -z "$issue_num" || -z "$template" || -z "$outcome" ]]; then
        error "feedback requires --issue, --template, and --outcome"
        return 1
    fi
    case "$outcome" in
        success|failure) ;;
        *) error "--outcome must be 'success' or 'failure'"; return 1 ;;
    esac
    tr_record_outcome "$issue_num" "$template" "$outcome"
    success "Recorded outcome for issue #${issue_num}: ${template} → ${outcome}"
}

cmd_accuracy() {
    local acc_json
    acc_json=$(tr_accuracy)
    if [[ "${1:-}" == "--json" ]]; then
        echo "$acc_json"
        return 0
    fi
    local total matched accuracy
    total=$(echo "$acc_json" | jq -r '.total')
    matched=$(echo "$acc_json" | jq -r '.matched')
    accuracy=$(echo "$acc_json" | jq -r '.accuracy')
    echo
    echo -e "  ${BOLD}Template recommendation accuracy${RESET}"
    echo -e "    Evaluated:  ${total}"
    echo -e "    Matched:    ${matched}"
    echo -e "    Accuracy:   ${GREEN}${accuracy}%${RESET}"
    echo
}

main() {
    case "${1:-}" in
        --help|-h|help|"") show_help; exit 0 ;;
        --version|-v) echo "$VERSION"; exit 0 ;;
        recommend) shift; cmd_recommend "$@" ;;
        explain)   shift; cmd_recommend --explain-mode "$@" ;;
        feedback)  shift; cmd_feedback "$@" ;;
        accuracy)  shift; cmd_accuracy "$@" ;;
        *) error "Unknown command: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
