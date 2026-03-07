#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-pipeline-analytics.sh — Pipeline Execution Visibility & Analytics    ║
# ║                                                                          ║
# ║  Success rate breakdowns by template, stage, complexity, time of day.   ║
# ║  Failure attribution and trend analysis for 7/30/90 day windows.        ║
# ║  JSON output for strategic agent consumption.                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.2.4"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
    emit_event() { :; }
fi

# Source database layer
# shellcheck source=sw-db.sh
source "$SCRIPT_DIR/sw-db.sh"

# ─── Colors ──────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Help text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright analytics [OPTIONS]

DESCRIPTION
  Pipeline execution visibility dashboard with success rate attribution.
  Shows success rates broken down by template, stage failures, complexity,
  and time of day. Supports JSON output for machine consumption.

OPTIONS
  --json            Output as JSON (for strategic agent consumption)
  --period DAYS     Time window: 7, 30, or 90 (default: 7)
  --active          Show only active/running pipelines
  --help, -h        Show this help text
  --version, -v     Show version

EXAMPLES
  shipwright analytics                  Dashboard view (last 7 days)
  shipwright analytics --period 30      Last 30 days
  shipwright analytics --json           JSON output for agents
  shipwright analytics --active         Active pipelines only

EOF
}

# ─── JSON Output ────────────────────────────────────────────────────────────
analytics_json() {
    local period="$1"

    local summary by_template by_stage_failure by_complexity by_hour trends active cost_total
    summary=$(db_analytics_summary "$period")
    by_template=$(db_analytics_by_template "$period")
    by_stage_failure=$(db_analytics_by_stage_failure "$period")
    by_complexity=$(db_analytics_by_complexity "$period")
    by_hour=$(db_analytics_by_hour "$period")
    trends=$(db_analytics_trends)
    active=$(db_analytics_active)
    cost_total=$(db_analytics_cost_total "$period")

    local generated_at
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --argjson period_days "$period" \
        --arg generated_at "$generated_at" \
        --argjson summary "$summary" \
        --argjson by_template "$by_template" \
        --argjson by_stage_failure "$by_stage_failure" \
        --argjson by_complexity "$by_complexity" \
        --argjson by_hour "$by_hour" \
        --argjson trends "$trends" \
        --argjson active "$active" \
        --argjson cost_total "$cost_total" \
        '{
            period_days: $period_days,
            generated_at: $generated_at,
            summary: ($summary + {total_cost_usd: $cost_total}),
            by_template: (if $by_template == null then [] else $by_template end),
            by_stage_failure: (if $by_stage_failure == null then [] else $by_stage_failure end),
            by_complexity: (if $by_complexity == null then [] else $by_complexity end),
            by_hour: (if $by_hour == null then [] else $by_hour end),
            trends: {periods: (if $trends == null then [] else $trends end)},
            active_pipelines: (if $active == null then [] else $active end)
        }'
}

# ─── Terminal Dashboard ────────────────────────────────────────────────────
analytics_dashboard() {
    local period="$1"

    echo ""
    echo -e "${CYAN}${BOLD}  Pipeline Analytics Dashboard${RESET}  ${DIM}(last ${period} days)${RESET}"
    echo -e "  ${DIM}════════════════════════════════════════════════════════${RESET}"
    echo ""

    # Summary
    local summary
    summary=$(db_analytics_summary "$period")
    local total successful failed success_rate avg_duration
    total=$(echo "$summary" | jq -r '.total_runs // 0')
    successful=$(echo "$summary" | jq -r '.successful // 0')
    failed=$(echo "$summary" | jq -r '.failed // 0')
    success_rate=$(echo "$summary" | jq -r '.success_rate // 0')
    avg_duration=$(echo "$summary" | jq -r '.avg_duration_secs // 0')

    if [[ "$total" -eq 0 ]]; then
        echo -e "  ${DIM}No pipeline data found for the last ${period} days.${RESET}"
        echo -e "  ${DIM}Run some pipelines to see analytics here.${RESET}"
        echo ""
        return 0
    fi

    local cost_total
    cost_total=$(db_analytics_cost_total "$period")

    # Color-code success rate
    local rate_color="$GREEN"
    if [[ "$(echo "$success_rate < 50" | bc -l 2>/dev/null || echo 0)" -eq 1 ]]; then
        rate_color="$RED"
    elif [[ "$(echo "$success_rate < 80" | bc -l 2>/dev/null || echo 0)" -eq 1 ]]; then
        rate_color="$YELLOW"
    fi

    echo -e "  ${BOLD}Summary${RESET}"
    echo -e "  Total Runs:    ${BOLD}${total}${RESET}"
    echo -e "  Successful:    ${GREEN}${successful}${RESET}"
    echo -e "  Failed:        ${RED}${failed}${RESET}"
    echo -e "  Success Rate:  ${rate_color}${BOLD}${success_rate}%${RESET}"
    echo -e "  Avg Duration:  ${DIM}${avg_duration}s${RESET}"
    echo -e "  Total Cost:    ${DIM}\$${cost_total}${RESET}"
    echo ""

    # By Template
    local by_template
    by_template=$(db_analytics_by_template "$period")
    local template_count
    template_count=$(echo "$by_template" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$template_count" -gt 0 ]]; then
        echo -e "  ${BOLD}By Template${RESET}"
        echo -e "  ${DIM}%-15s %6s %6s %6s %8s${RESET}" | xargs printf "  %-15s %6s %6s %6s %8s\n" "Template" "Total" "Pass" "Fail" "Rate"
        echo -e "  ${DIM}─────────────────────────────────────────────${RESET}"
        echo "$by_template" | jq -r '.[] | "  \(.template)\t\(.total)\t\(.successful)\t\(.failed)\t\(.success_rate)%"' 2>/dev/null | while IFS=$'\t' read -r tpl tot ok fl rt; do
            printf "  %-15s %6s %6s %6s %8s\n" "$tpl" "$tot" "$ok" "$fl" "$rt"
        done
        echo ""
    fi

    # Stage Failures
    local by_stage_failure
    by_stage_failure=$(db_analytics_by_stage_failure "$period")
    local stage_count
    stage_count=$(echo "$by_stage_failure" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$stage_count" -gt 0 ]]; then
        echo -e "  ${BOLD}Failure Attribution (by Stage)${RESET}"
        echo "$by_stage_failure" | jq -r '.[] | "  \(.stage_name)\t\(.failure_count)\t\(.pct_of_failures)%"' 2>/dev/null | while IFS=$'\t' read -r stage fc pct; do
            printf "  ${RED}%-15s${RESET} %4s failures  (%s)\n" "$stage" "$fc" "$pct"
        done
        echo ""
    fi

    # Trends
    local trends
    trends=$(db_analytics_trends)
    local trend_count
    trend_count=$(echo "$trends" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$trend_count" -gt 0 ]]; then
        echo -e "  ${BOLD}Trends${RESET}"
        echo "$trends" | jq -r '.[] | "  \(.label)\t\(.total) runs\t\(.success_rate)% success\t~\(.avg_duration_secs)s avg"' 2>/dev/null | while IFS=$'\t' read -r label rest1 rest2 rest3; do
            echo -e "  ${DIM}${label}${RESET}  ${rest1}  ${rest2}  ${rest3}"
        done
        echo ""
    fi

    # Active Pipelines
    local active
    active=$(db_analytics_active)
    local active_count
    active_count=$(echo "$active" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$active_count" -gt 0 ]]; then
        echo -e "  ${BOLD}Active Pipelines${RESET} (${active_count})"
        echo "$active" | jq -r '.[] | "  \(.job_id)\t\(.current_stage)\t\(.elapsed_secs)s\t\(.goal)"' 2>/dev/null | while IFS=$'\t' read -r jid stage elapsed goal; do
            local short_goal
            short_goal="${goal:0:40}"
            printf "  ${CYAN}%-12s${RESET} stage=%-10s %6ss  %s\n" "$jid" "$stage" "$elapsed" "$short_goal"
        done
        echo ""
    fi
}

# ─── Active Pipelines Only ─────────────────────────────────────────────────
analytics_active_only() {
    local json_mode="$1"
    local active
    active=$(db_analytics_active)

    if [[ "$json_mode" == "true" ]]; then
        echo "$active"
        return 0
    fi

    local active_count
    active_count=$(echo "$active" | jq 'length' 2>/dev/null || echo "0")

    echo ""
    echo -e "${CYAN}${BOLD}  Active Pipelines${RESET}"
    echo -e "  ${DIM}════════════════════════════════════════════════════════${RESET}"
    echo ""

    if [[ "$active_count" -eq 0 ]]; then
        echo -e "  ${DIM}No active pipelines.${RESET}"
        echo ""
        return 0
    fi

    echo "$active" | jq -r '.[] | "  \(.job_id)\t\(.template)\t\(.current_stage)\t\(.elapsed_secs)s\t\(.goal)"' 2>/dev/null | while IFS=$'\t' read -r jid tpl stage elapsed goal; do
        local short_goal
        short_goal="${goal:0:50}"
        printf "  ${CYAN}%-12s${RESET} [%-10s] stage=%-10s %6ss  %s\n" "$jid" "$tpl" "$stage" "$elapsed" "$short_goal"
    done
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local json_mode="false"
    local period=7
    local active_only="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)       json_mode="true"; shift ;;
            --period)     period="${2:-7}"; shift 2 ;;
            --active)     active_only="true"; shift ;;
            --help|-h)    show_help; exit 0 ;;
            --version|-v) echo "$VERSION"; exit 0 ;;
            *)            error "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done

    # Validate period
    case "$period" in
        7|30|90) ;;
        *) warn "Invalid period: $period (using 7)"; period=7 ;;
    esac

    # Ensure DB exists
    if ! check_sqlite3 2>/dev/null; then
        if [[ "$json_mode" == "true" ]]; then
            echo '{"period_days":'"$period"',"summary":{"total_runs":0,"successful":0,"failed":0,"success_rate":0,"avg_duration_secs":0,"total_cost_usd":0},"by_template":[],"by_stage_failure":[],"by_complexity":[],"by_hour":[],"trends":{"periods":[]},"active_pipelines":[]}'
            exit 0
        fi
        warn "SQLite not available. No analytics data."
        exit 0
    fi

    # Initialize schema if needed
    init_schema 2>/dev/null || true

    if [[ "$active_only" == "true" ]]; then
        analytics_active_only "$json_mode"
        exit 0
    fi

    if [[ "$json_mode" == "true" ]]; then
        analytics_json "$period"
    else
        analytics_dashboard "$period"
    fi

    emit_event "analytics_viewed" "period=${period}" "mode=$([ "$json_mode" == "true" ] && echo "json" || echo "terminal")"
}

main "$@"
