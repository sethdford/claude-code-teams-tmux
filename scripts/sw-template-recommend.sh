#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright template recommend — Intelligence-driven template selection  ║
# ║  Recommends pipeline templates based on historical success rates,        ║
# ║  project type, speed, and cost metrics from pipeline_outcomes.          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Fallbacks for isolated environments
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
        local payload; payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
        while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
        echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
    }
fi

# ─── Load dependencies ────────────────────────────────────────────────────
# shellcheck source=sw-db.sh
source "$SCRIPT_DIR/sw-db.sh"
# shellcheck source=lib/template-recommend.sh
source "$SCRIPT_DIR/lib/template-recommend.sh"

# ─── Colors ────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ═══════════════════════════════════════════════════════════════════════════
# CLI Commands
# ═══════════════════════════════════════════════════════════════════════════

cmd_recommend() {
    local project_type="" days=90 json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)     project_type="$2"; shift 2 ;;
            --days)     days="$2"; shift 2 ;;
            --json)     json_output=true; shift ;;
            *)          shift ;;
        esac
    done

    # Initialize DB if needed (redirect migration output to stderr)
    migrate_schema >/dev/null 2>&1 || true

    local result
    result=$(tr_recommend "$project_type" "$days")

    if [[ "$json_output" == "true" ]]; then
        echo "$result" | jq '.' 2>/dev/null || echo "$result"
        return
    fi

    # Pretty-print recommendation
    local recommended score confidence reason pt
    recommended=$(echo "$result" | jq -r '.recommended // "standard"' 2>/dev/null)
    score=$(echo "$result" | jq -r '.score // 0' 2>/dev/null)
    confidence=$(echo "$result" | jq -r '.confidence // "none"' 2>/dev/null)
    reason=$(echo "$result" | jq -r '.reason // ""' 2>/dev/null)
    pt=$(echo "$result" | jq -r '.project_type // "unknown"' 2>/dev/null)

    echo ""
    echo -e "${CYAN}${BOLD}  Template Recommendation${RESET}"
    echo -e "  ════════════════════════════════════════"
    echo ""
    echo -e "  ${BOLD}Project type:${RESET}    ${pt}"
    echo -e "  ${BOLD}Recommended:${RESET}     ${GREEN}${BOLD}${recommended}${RESET}"
    echo -e "  ${BOLD}Score:${RESET}           ${score}/100"

    # Confidence indicator
    case "$confidence" in
        high)   echo -e "  ${BOLD}Confidence:${RESET}      ${GREEN}●●●${RESET} high (10+ samples)" ;;
        medium) echo -e "  ${BOLD}Confidence:${RESET}      ${YELLOW}●●○${RESET} medium (3-9 samples)" ;;
        low)    echo -e "  ${BOLD}Confidence:${RESET}      ${RED}●○○${RESET} low (<3 samples)" ;;
        *)      echo -e "  ${BOLD}Confidence:${RESET}      ${DIM}○○○${RESET} no data" ;;
    esac

    case "$reason" in
        data_driven)                 echo -e "  ${BOLD}Basis:${RESET}           Historical outcome data" ;;
        cold_start_project_heuristic) echo -e "  ${BOLD}Basis:${RESET}           Project structure heuristic (no outcome data)" ;;
        cold_start_no_data)          echo -e "  ${BOLD}Basis:${RESET}           Default (no outcome data available)" ;;
        cold_start_no_db)            echo -e "  ${BOLD}Basis:${RESET}           Default (database unavailable)" ;;
    esac

    # Show all scored templates
    local scores_count
    scores_count=$(echo "$result" | jq '.scores | length' 2>/dev/null || echo 0)
    if [[ "$scores_count" -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Template Rankings (${days}d window):${RESET}"
        echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
        printf "  ${DIM}%-14s %8s %8s %10s %8s${RESET}\n" "Template" "Score" "Success" "Avg Time" "Samples"
        echo -e "  ${DIM}─────────────────────────────────────────${RESET}"

        echo "$result" | jq -r '.scores | sort_by(-.score)[] |
            "\(.template)|\(.score)|\(.success_rate)|\(.avg_duration_secs)|\(.total)"' 2>/dev/null | while IFS='|' read -r tpl tpl_score rate dur total; do
            # Format duration
            local dur_min
            dur_min=$(awk -v d="$dur" 'BEGIN { printf "%.0f", d / 60 }')

            # Format success rate as percentage
            local rate_pct
            rate_pct=$(awk -v r="$rate" 'BEGIN { printf "%.0f", r * 100 }')

            # Color the recommended template
            local tpl_display="$tpl"
            if [[ "$tpl" == "$recommended" ]]; then
                tpl_display="${GREEN}${BOLD}${tpl}${RESET}"
                printf "  %-26s %8s %7s%% %8sm %8s\n" "$tpl_display" "$tpl_score" "$rate_pct" "$dur_min" "$total"
            else
                printf "  %-14s %8s %7s%% %8sm %8s\n" "$tpl" "$tpl_score" "$rate_pct" "$dur_min" "$total"
            fi
        done
    fi
    echo ""
}

cmd_stats() {
    local project_type="" days=90 json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)     project_type="$2"; shift 2 ;;
            --days)     days="$2"; shift 2 ;;
            --json)     json_output=true; shift ;;
            *)          shift ;;
        esac
    done

    migrate_schema >/dev/null 2>&1 || true

    local stats
    stats=$(tr_all_template_stats "$project_type" "$days")

    if [[ "$json_output" == "true" ]]; then
        echo "$stats" | jq '.' 2>/dev/null || echo "$stats"
        return
    fi

    local count
    count=$(echo "$stats" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 || "$stats" == "[]" ]]; then
        warn "No template outcome data found (${days}d window)"
        info "Run pipelines to collect data, then check again"
        return 0
    fi

    echo ""
    echo -e "${CYAN}${BOLD}  Template Success Rates (${days}d)${RESET}"
    echo -e "  ════════════════════════════════════════"
    echo ""
    printf "  ${DIM}%-14s %8s %8s %10s %10s %8s${RESET}\n" "Template" "Success" "Total" "Avg Time" "Avg Cost" "Last Run"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────${RESET}"

    echo "$stats" | jq -r '.[] |
        "\(.template)|\(.success_rate)|\(.total)|\(.avg_duration_secs)|\(.avg_cost_usd)|\(.last_run)"' 2>/dev/null | while IFS='|' read -r tpl rate total dur cost last; do
        local rate_pct dur_min
        rate_pct=$(awk -v r="$rate" 'BEGIN { printf "%.0f", r * 100 }')
        dur_min=$(awk -v d="$dur" 'BEGIN { printf "%.0f", d / 60 }')

        # Color code success rate
        local rate_color="$RED"
        if [[ "$rate_pct" -ge 80 ]]; then rate_color="$GREEN"
        elif [[ "$rate_pct" -ge 60 ]]; then rate_color="$YELLOW"
        fi

        local last_short
        last_short=$(echo "$last" | cut -c1-10)

        printf "  %-14s ${rate_color}%7s%%${RESET} %8s %8sm %9s %10s\n" "$tpl" "$rate_pct" "$total" "$dur_min" "\$${cost}" "$last_short"
    done
    echo ""
}

cmd_trends() {
    local project_type="" json_output=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)     project_type="$2"; shift 2 ;;
            --json)     json_output=true; shift ;;
            *)          shift ;;
        esac
    done

    migrate_schema >/dev/null 2>&1 || true

    local trends
    trends=$(tr_success_trends "$project_type")

    if [[ "$json_output" == "true" ]]; then
        echo "$trends" | jq '.' 2>/dev/null || echo "$trends"
        return
    fi

    echo ""
    echo -e "${CYAN}${BOLD}  Template Success Trends${RESET}"
    echo -e "  ════════════════════════════════════════"

    local period
    for period in 7d 30d 90d; do
        local period_data
        period_data=$(echo "$trends" | jq -r --arg p "$period" '.[$p]' 2>/dev/null || echo "[]")
        local period_count
        period_count=$(echo "$period_data" | jq 'length' 2>/dev/null || echo 0)

        echo ""
        echo -e "  ${BOLD}${period} window:${RESET}"
        if [[ "$period_count" -eq 0 || "$period_data" == "[]" ]]; then
            echo -e "  ${DIM}  No data${RESET}"
            continue
        fi

        echo "$period_data" | jq -r '.[] | "  \(.template): \(.success_rate * 100 | floor)% (\(.total) runs)"' 2>/dev/null | while read -r line; do
            echo "  $line"
        done
    done
    echo ""
}

cmd_record() {
    local job_id="" template="" success="" duration=0 cost=0 project_type="" issue="" complexity="medium"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --job-id)       job_id="$2"; shift 2 ;;
            --template)     template="$2"; shift 2 ;;
            --success)      success="$2"; shift 2 ;;
            --duration)     duration="$2"; shift 2 ;;
            --cost)         cost="$2"; shift 2 ;;
            --type)         project_type="$2"; shift 2 ;;
            --issue)        issue="$2"; shift 2 ;;
            --complexity)   complexity="$2"; shift 2 ;;
            *)              shift ;;
        esac
    done

    if [[ -z "$job_id" || -z "$template" || -z "$success" ]]; then
        error "Usage: shipwright template recommend record --job-id <id> --template <tpl> --success <0|1> [--duration <secs>] [--cost <usd>] [--type <project_type>]"
        exit 1
    fi

    migrate_schema >/dev/null 2>&1 || true
    tr_record_outcome "$job_id" "$template" "$success" "$duration" "$cost" "$project_type" "$issue" "$complexity"
    success "Recorded outcome: template=$template success=$success project_type=${project_type:-auto}"
}

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}  shipwright template recommend${RESET} — Intelligence-driven template selection"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET}"
    echo -e "    shipwright template recommend [--type <project_type>] [--days <N>] [--json]"
    echo -e "    shipwright template stats [--type <project_type>] [--days <N>] [--json]"
    echo -e "    shipwright template trends [--type <project_type>] [--json]"
    echo -e "    shipwright template record --job-id <id> --template <tpl> --success <0|1>"
    echo ""
    echo -e "  ${BOLD}Commands:${RESET}"
    echo -e "    ${CYAN}recommend${RESET}    Recommend best template based on historical data"
    echo -e "    ${CYAN}stats${RESET}        Show success rates for all templates"
    echo -e "    ${CYAN}trends${RESET}       Show success rate trends (7d/30d/90d)"
    echo -e "    ${CYAN}record${RESET}       Manually record a pipeline outcome"
    echo ""
    echo -e "  ${BOLD}Options:${RESET}"
    echo -e "    --type <type>    Filter by project type (nodejs, python, rust, etc.)"
    echo -e "    --days <N>       Lookback window in days (default: 90)"
    echo -e "    --json           Output raw JSON"
    echo ""
    echo -e "  ${BOLD}Examples:${RESET}"
    echo -e "    ${DIM}shipwright template recommend${RESET}"
    echo -e "    ${DIM}shipwright template recommend --type nodejs --json${RESET}"
    echo -e "    ${DIM}shipwright template stats --days 30${RESET}"
    echo -e "    ${DIM}shipwright template trends --type python${RESET}"
    echo ""
}

# ─── Main Router ──────────────────────────────────────────────────────────
main() {
    local subcmd="${1:-recommend}"
    shift 2>/dev/null || true

    case "$subcmd" in
        recommend)  cmd_recommend "$@" ;;
        stats)      cmd_stats "$@" ;;
        trends)     cmd_trends "$@" ;;
        record)     cmd_record "$@" ;;
        help|--help|-h)  show_help ;;
        *)
            error "Unknown subcommand: $subcmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
