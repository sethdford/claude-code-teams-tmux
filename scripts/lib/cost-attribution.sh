#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost-attribution — Per-Issue Cost Attribution Engine          ║
# ║  Issue-level cost tracking · ROI analysis · Budget forecasting           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard
[[ -n "${_COST_ATTRIBUTION_LOADED:-}" ]] && return 0
_COST_ATTRIBUTION_LOADED=1

# ─── Default Paths ──────────────────────────────────────────────────────────
COST_DIR="${COST_DIR:-${HOME}/.shipwright}"
SCRIPT_DIR="${SCRIPT_DIR:-.}"

# ─── Helper Functions (fallback if not sourced from main script) ─────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

# ─── Source DB layer ────────────────────────────────────────────────────────
if [[ "$(type -t db_available 2>/dev/null)" != "function" ]]; then
    if [[ -f "$SCRIPT_DIR/sw-db.sh" ]]; then
        # shellcheck source=../sw-db.sh
        source "$SCRIPT_DIR/sw-db.sh"
    elif [[ -f "$SCRIPT_DIR/../sw-db.sh" ]]; then
        source "$SCRIPT_DIR/../sw-db.sh"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Recording Functions
# ═══════════════════════════════════════════════════════════════════════════

# record_attribution <job_id> <issue_number> <stage> <model> <input_tokens> <output_tokens> <cost_usd> [iteration] [duration_secs]
# Writes to both SQLite (via db_upsert_attribution) and JSON fallback
record_attribution() {
    local job_id="${1:-}"
    local issue_number="${2:-0}"
    local stage="${3:-unknown}"
    local model="${4:-sonnet}"
    local input_tokens="${5:-0}"
    local output_tokens="${6:-0}"
    local cost_usd="${7:-0}"
    local iteration="${8:-0}"
    local duration_secs="${9:-0}"

    if [[ -z "$job_id" ]] || [[ "$issue_number" -eq 0 ]]; then
        return 1
    fi

    # SQLite path
    if [[ "$(type -t db_upsert_attribution 2>/dev/null)" == "function" ]]; then
        db_upsert_attribution "$job_id" "$issue_number" "$stage" "$model" \
            "$input_tokens" "$output_tokens" "$cost_usd" "$iteration" "$duration_secs" 2>/dev/null || true
    fi

    # JSON fallback (dual-write)
    local attrib_file="${COST_DIR}/cost-attributions.jsonl"
    mkdir -p "$COST_DIR"
    local tmp_file
    tmp_file="${attrib_file}.tmp.$$"
    local ts
    ts="$(now_iso)"
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg job "$job_id" --arg issue "$issue_number" --arg stg "$stage" \
            --arg mdl "$model" --arg it "$input_tokens" --arg ot "$output_tokens" \
            --arg cost "$cost_usd" --arg iter "$iteration" --arg dur "$duration_secs" \
            --arg ts "$ts" \
            '{job_id:$job,issue_number:($issue|tonumber),stage:$stg,model:$mdl,input_tokens:($it|tonumber),output_tokens:($ot|tonumber),cost_usd:($cost|tonumber),iteration:($iter|tonumber),duration_secs:($dur|tonumber),created_at:$ts}' \
            >> "$tmp_file" 2>/dev/null && mv "$tmp_file" "$attrib_file.$$" && cat "$attrib_file.$$" >> "$attrib_file" && rm -f "$attrib_file.$$"
    else
        echo "{\"job_id\":\"${job_id}\",\"issue_number\":${issue_number},\"stage\":\"${stage}\",\"model\":\"${model}\",\"input_tokens\":${input_tokens},\"output_tokens\":${output_tokens},\"cost_usd\":${cost_usd},\"iteration\":${iteration},\"duration_secs\":${duration_secs},\"created_at\":\"${ts}\"}" >> "$attrib_file"
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Query Functions — Human-Readable Output
# ═══════════════════════════════════════════════════════════════════════════

# attrib_by_issue [--issue N] [--period D] [--breakdown] [--json] [--limit N] [--sort cost|issue|date]
attrib_by_issue() {
    local issue="" period=30 breakdown=0 json_out=0 limit=20 sort_by="cost"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)     issue="${2:-}"; shift 2 ;;
            --period)    period="${2:-30}"; shift 2 ;;
            --breakdown) breakdown=1; shift ;;
            --json)      json_out=1; shift ;;
            --limit)     limit="${2:-20}"; shift 2 ;;
            --sort)      sort_by="${2:-cost}"; shift 2 ;;
            *)           shift ;;
        esac
    done

    if [[ -n "$issue" ]] && [[ "$breakdown" -eq 1 ]]; then
        # Per-stage breakdown for a single issue
        local stages_json
        stages_json=$(db_query_attribution_stages "$issue" 2>/dev/null || echo "[]")
        if [[ "$json_out" -eq 1 ]]; then
            echo "$stages_json"
            return 0
        fi
        _render_issue_breakdown "$issue" "$stages_json"
        return 0
    fi

    # Summary by issue
    local issues_json
    issues_json=$(db_query_attribution_by_issue "$issue" "$period" 2>/dev/null || echo "[]")
    if [[ "$json_out" -eq 1 ]]; then
        echo "$issues_json"
        return 0
    fi
    _render_issue_summary "$issues_json" "$period"
}

# attrib_roi [--period D] [--json] [--sort roi|cost]
attrib_roi() {
    local period=30 json_out=0 sort_by="roi"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --period) period="${2:-30}"; shift 2 ;;
            --json)   json_out=1; shift ;;
            --sort)   sort_by="${2:-roi}"; shift 2 ;;
            *)        shift ;;
        esac
    done

    local roi_json
    roi_json=$(db_query_attribution_roi "$period" 2>/dev/null || echo "[]")
    if [[ "$json_out" -eq 1 ]]; then
        echo "$roi_json"
        return 0
    fi
    _render_roi_dashboard "$roi_json" "$period"
}

# attrib_forecast [--horizon D] [--json]
attrib_forecast() {
    local horizon=30 json_out=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --horizon) horizon="${2:-30}"; shift 2 ;;
            --json)    json_out=1; shift ;;
            *)         shift ;;
        esac
    done

    local forecast_json
    forecast_json=$(db_query_attribution_forecast "$horizon" 2>/dev/null || echo "{}")
    if [[ "$json_out" -eq 1 ]]; then
        echo "$forecast_json"
        return 0
    fi
    _render_forecast "$forecast_json" "$horizon"
}

# ═══════════════════════════════════════════════════════════════════════════
# Rendering Helpers
# ═══════════════════════════════════════════════════════════════════════════

_render_issue_summary() {
    local json="$1" period="$2"
    local CYAN='\033[38;2;0;212;255m' GREEN='\033[38;2;74;222;128m' DIM='\033[2m' BOLD='\033[1m' RESET='\033[0m'

    echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Cost Attribution by Issue — Last ${period} Days                     ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if ! command -v jq >/dev/null 2>&1; then
        echo "$json"
        return 0
    fi

    local count
    count=$(echo "$json" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]] || [[ "$json" == "[]" ]]; then
        echo -e "  ${DIM}No cost attribution data found.${RESET}"
        return 0
    fi

    printf "  ${BOLD}%-8s  %-12s  %-12s  %-8s  %-8s${RESET}\n" "Issue" "Cost (USD)" "Tokens" "Stages" "Records"
    printf "  ${DIM}%-8s  %-12s  %-12s  %-8s  %-8s${RESET}\n" "────────" "────────────" "────────────" "────────" "────────"

    echo "$json" | jq -r '.[] | "\(.issue_number)\t\(.total_cost)\t\(.total_input_tokens + .total_output_tokens)\t\(.stage_count)\t\(.record_count)"' 2>/dev/null | while IFS=$'\t' read -r iss cost tokens stages records; do
        printf "  ${GREEN}#%-7s${RESET}  \$%-11s  %-12s  %-8s  %-8s\n" "$iss" "$cost" "$tokens" "$stages" "$records"
    done

    local total_cost
    total_cost=$(echo "$json" | jq '[.[].total_cost] | add | . * 100 | round / 100' 2>/dev/null || echo "0")
    echo ""
    echo -e "  ${BOLD}Total: \$${total_cost}${RESET}"
}

_render_issue_breakdown() {
    local issue="$1" json="$2"
    local CYAN='\033[38;2;0;212;255m' GREEN='\033[38;2;74;222;128m' DIM='\033[2m' BOLD='\033[1m' RESET='\033[0m'

    echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Cost Breakdown — Issue #${issue}                                    ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if ! command -v jq >/dev/null 2>&1; then
        echo "$json"
        return 0
    fi

    local count
    count=$(echo "$json" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]] || [[ "$json" == "[]" ]]; then
        echo -e "  ${DIM}No attribution data for issue #${issue}.${RESET}"
        return 0
    fi

    printf "  ${BOLD}%-16s  %-10s  %-12s  %-12s  %-10s  %-6s${RESET}\n" "Stage" "Model" "Cost (USD)" "Tokens" "Duration" "Iters"
    printf "  ${DIM}%-16s  %-10s  %-12s  %-12s  %-10s  %-6s${RESET}\n" "────────────────" "──────────" "────────────" "────────────" "──────────" "──────"

    echo "$json" | jq -r '.[] | "\(.stage)\t\(.model)\t\(.cost)\t\(.input_tokens + .output_tokens)\t\(.duration_secs)\t\(.iterations)"' 2>/dev/null | while IFS=$'\t' read -r stg mdl cost tokens dur iters; do
        local dur_fmt="${dur}s"
        if [[ "$dur" -gt 60 ]]; then
            dur_fmt="$((dur / 60))m$((dur % 60))s"
        fi
        printf "  ${GREEN}%-16s${RESET}  %-10s  \$%-11s  %-12s  %-10s  %-6s\n" "$stg" "$mdl" "$cost" "$tokens" "$dur_fmt" "$iters"
    done

    local total
    total=$(echo "$json" | jq '[.[].cost] | add | . * 100 | round / 100' 2>/dev/null || echo "0")
    echo ""
    echo -e "  ${BOLD}Total: \$${total}${RESET}"
}

_render_roi_dashboard() {
    local json="$1" period="$2"
    local CYAN='\033[38;2;0;212;255m' GREEN='\033[38;2;74;222;128m' AMBER='\033[38;2;251;191;36m' DIM='\033[2m' BOLD='\033[1m' RESET='\033[0m'

    echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  ROI Dashboard — Last ${period} Days                                ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if ! command -v jq >/dev/null 2>&1; then
        echo "$json"
        return 0
    fi

    local count
    count=$(echo "$json" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]] || [[ "$json" == "[]" ]]; then
        echo -e "  ${DIM}No pipeline outcome data found.${RESET}"
        return 0
    fi

    printf "  ${BOLD}%-8s  %-10s  %-10s  %-8s  %-12s  %-10s${RESET}\n" "Issue" "Template" "Complexity" "Success" "Cost (USD)" "ROI Score"
    printf "  ${DIM}%-8s  %-10s  %-10s  %-8s  %-12s  %-10s${RESET}\n" "────────" "──────────" "──────────" "────────" "────────────" "──────────"

    echo "$json" | jq -r '.[] | "\(.issue_number)\t\(.template)\t\(.complexity)\t\(.success)\t\(.attributed_cost // .pipeline_cost)\t\(.roi_score)"' 2>/dev/null | while IFS=$'\t' read -r iss tpl cpx succ cost roi; do
        local succ_icon
        if [[ "$succ" -eq 1 ]]; then
            succ_icon="${GREEN}✓${RESET}"
        else
            succ_icon="${AMBER}✗${RESET}"
        fi
        printf "  #%-7s  %-10s  %-10s  %b        \$%-11s  %-10s\n" "$iss" "$tpl" "$cpx" "$succ_icon" "$cost" "$roi"
    done

    # Summary stats
    local avg_roi total_spend success_rate
    avg_roi=$(echo "$json" | jq '[.[].roi_score] | add / length | . * 100 | round / 100' 2>/dev/null || echo "0")
    total_spend=$(echo "$json" | jq '[.[] | (.attributed_cost // .pipeline_cost)] | add | . * 100 | round / 100' 2>/dev/null || echo "0")
    success_rate=$(echo "$json" | jq '([.[].success] | add) / length * 100 | round' 2>/dev/null || echo "0")

    echo ""
    echo -e "  ${BOLD}Summary:${RESET} Avg ROI: ${avg_roi}  |  Total spend: \$${total_spend}  |  Success rate: ${success_rate}%"
}

_render_forecast() {
    local json="$1" horizon="$2"
    local CYAN='\033[38;2;0;212;255m' GREEN='\033[38;2;74;222;128m' AMBER='\033[38;2;251;191;36m' DIM='\033[2m' BOLD='\033[1m' RESET='\033[0m'

    echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Budget Forecast — ${horizon}-Day Horizon                             ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if ! command -v jq >/dev/null 2>&1; then
        echo "$json"
        return 0
    fi

    local total_30d total_7d avg_30d avg_7d projected
    total_30d=$(echo "$json" | jq -r '.total_30d // 0' 2>/dev/null || echo "0")
    total_7d=$(echo "$json" | jq -r '.total_7d // 0' 2>/dev/null || echo "0")
    avg_30d=$(echo "$json" | jq -r '.avg_daily_30d // 0' 2>/dev/null || echo "0")
    avg_7d=$(echo "$json" | jq -r '.avg_daily_7d // 0' 2>/dev/null || echo "0")
    projected=$(echo "$json" | jq -r '.projected_cost // 0' 2>/dev/null || echo "0")

    echo -e "  ${BOLD}Historical Spend${RESET}"
    echo -e "    Last 7 days:   \$${total_7d}  (avg \$${avg_7d}/day)"
    echo -e "    Last 30 days:  \$${total_30d}  (avg \$${avg_30d}/day)"
    echo ""
    echo -e "  ${BOLD}Forecast (${horizon} days)${RESET}"
    echo -e "    Projected spend: ${GREEN}\$${projected}${RESET}"

    # Budget check
    if [[ "$(type -t db_remaining_budget 2>/dev/null)" == "function" ]]; then
        local remaining
        remaining=$(db_remaining_budget 2>/dev/null || echo "unlimited")
        if [[ "$remaining" != "unlimited" ]]; then
            echo -e "    Daily budget remaining: \$${remaining}"
            # Simple days-until-exhaustion estimate
            if command -v awk >/dev/null 2>&1 && [[ "$avg_7d" != "0" ]]; then
                local days_left
                days_left=$(awk -v rem="$remaining" -v avg="$avg_7d" 'BEGIN { if (avg > 0) printf "%d", rem / avg; else print "∞" }')
                echo -e "    Estimated budget runway: ${AMBER}${days_left} days${RESET}"
            fi
        fi
    fi

    # Trend indicator
    if command -v awk >/dev/null 2>&1; then
        local trend
        trend=$(awk -v a7="$avg_7d" -v a30="$avg_30d" 'BEGIN {
            if (a30 == 0) { print "stable"; exit }
            pct = (a7 - a30) / a30 * 100
            if (pct > 10) print "↑ increasing (" sprintf("%.0f", pct) "%)"
            else if (pct < -10) print "↓ decreasing (" sprintf("%.0f", pct) "%)"
            else print "→ stable"
        }')
        echo ""
        echo -e "  ${BOLD}Trend:${RESET} ${trend}"
    fi
}
