#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright capability — Platform Capability Self-Assessment Registry    ║
# ║  View, manage, and configure task success/failure tracking               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Fallbacks
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# Colors
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# Load DB
source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null || true
# Load capability registry
source "$SCRIPT_DIR/lib/capability-registry.sh" 2>/dev/null || true

# ─── Repo Hash ──────────────────────────────────────────────────────
_repo_hash() {
    local origin
    origin=$(git config --get remote.origin.url 2>/dev/null || echo "local")
    echo -n "$origin" | shasum -a 256 | cut -c1-12
}

# ─── Show Command ──────────────────────────────────────────────────
cmd_show() {
    local json_mode=false
    [[ "${1:-}" == "--json" ]] && json_mode=true

    if ! db_available 2>/dev/null; then
        error "Database not available. Run: shipwright db init"
        return 1
    fi

    local rh
    rh=$(_repo_hash)
    local entries
    entries=$(db_capability_query "$rh" 2>/dev/null || echo "[]")

    if [[ "$json_mode" == "true" ]]; then
        echo "$entries" | jq '.' 2>/dev/null || echo "$entries"
        return 0
    fi

    echo ""
    echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  Platform Capability Self-Assessment Registry                ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    local count
    count=$(echo "$entries" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${DIM}No capability data recorded yet.${RESET}"
        echo -e "  ${DIM}Data will appear after pipeline runs complete.${RESET}"
        echo ""
        return 0
    fi

    # Header
    printf "  ${BOLD}%-15s %8s %8s %8s %12s %10s${RESET}\n" "Category" "Runs" "Pass" "Fail" "Rate" "Confidence"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────${RESET}"

    # Rows
    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local cat total succ fail rate conf
        cat=$(echo "$entries" | jq -r ".[$i].category" 2>/dev/null)
        total=$(echo "$entries" | jq -r ".[$i].total_runs // 0" 2>/dev/null)
        succ=$(echo "$entries" | jq -r ".[$i].success_count // 0" 2>/dev/null)
        fail=$(echo "$entries" | jq -r ".[$i].failure_count // 0" 2>/dev/null)
        rate=$(echo "$entries" | jq -r ".[$i].success_rate // 0" 2>/dev/null)
        conf=$(echo "$entries" | jq -r ".[$i].confidence_level // \"low\"" 2>/dev/null)

        local rate_pct
        rate_pct=$(awk "BEGIN { printf \"%.0f%%\", $rate * 100 }" 2>/dev/null || echo "0%")

        local color="$GREEN"
        local rate_num
        rate_num=$(awk "BEGIN { print ($rate < 0.50) ? 1 : 0 }" 2>/dev/null || echo "0")
        [[ "$rate_num" -eq 1 ]] && color="$RED"
        rate_num=$(awk "BEGIN { print ($rate >= 0.50 && $rate < 0.70) ? 1 : 0 }" 2>/dev/null || echo "0")
        [[ "$rate_num" -eq 1 ]] && color="$YELLOW"

        printf "  %-15s %8s %8s %8s ${color}%12s${RESET} %10s\n" "$cat" "$total" "$succ" "$fail" "$rate_pct" "$conf"
        i=$((i + 1))
    done

    echo ""

    # Overall rate
    local overall
    overall=$(db_capability_overall_rate "$rh" 2>/dev/null || echo "0")
    local overall_pct
    overall_pct=$(awk "BEGIN { printf \"%.0f%%\", $overall * 100 }" 2>/dev/null || echo "0%")
    echo -e "  ${BOLD}Overall Success Rate:${RESET} ${overall_pct}"

    # Conservative mode
    if capability_is_conservative_mode 2>/dev/null; then
        echo -e "  ${YELLOW}${BOLD}⚠ Conservative mode ACTIVE${RESET} ${DIM}(overall rate below threshold)${RESET}"
    fi
    echo ""
}

# ─── Heatmap Command ──────────────────────────────────────────────
cmd_heatmap() {
    if ! db_available 2>/dev/null; then
        error "Database not available. Run: shipwright db init"
        return 1
    fi

    local rh
    rh=$(_repo_hash)
    local entries
    entries=$(db_capability_query "$rh" 2>/dev/null || echo "[]")

    echo ""
    echo -e "${CYAN}${BOLD}  Capability Heatmap${RESET}"
    echo ""

    local count
    count=$(echo "$entries" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${DIM}No data yet.${RESET}"
        echo ""
        return 0
    fi

    local all_categories="bug refactor testing security docs devops migration architecture feature"
    local cat
    for cat in $all_categories; do
        local entry_data rate total
        entry_data=$(echo "$entries" | jq -r ".[] | select(.category == \"$cat\")" 2>/dev/null || echo "")

        if [[ -z "$entry_data" ]]; then
            printf "  %-14s ${DIM}░░░░░░░░░░░░░░░░░░░░  no data${RESET}\n" "$cat"
            continue
        fi

        rate=$(echo "$entry_data" | jq -r '.success_rate // 0' 2>/dev/null || echo "0")
        total=$(echo "$entry_data" | jq -r '.total_runs // 0' 2>/dev/null || echo "0")

        # Generate bar (20 chars wide)
        local bar_len
        bar_len=$(awk "BEGIN { printf \"%d\", $rate * 20 }" 2>/dev/null || echo "0")
        local empty_len=$((20 - bar_len))

        local color="$GREEN"
        local is_low
        is_low=$(awk "BEGIN { print ($rate < 0.50) ? 1 : 0 }" 2>/dev/null || echo "0")
        [[ "$is_low" -eq 1 ]] && color="$RED"
        is_low=$(awk "BEGIN { print ($rate >= 0.50 && $rate < 0.70) ? 1 : 0 }" 2>/dev/null || echo "0")
        [[ "$is_low" -eq 1 ]] && color="$YELLOW"

        local filled="" empty=""
        local j=0
        while [[ "$j" -lt "$bar_len" ]]; do filled="${filled}█"; j=$((j + 1)); done
        j=0
        while [[ "$j" -lt "$empty_len" ]]; do empty="${empty}░"; j=$((j + 1)); done

        local rate_pct
        rate_pct=$(awk "BEGIN { printf \"%.0f%%\", $rate * 100 }" 2>/dev/null || echo "0%")

        printf "  %-14s ${color}%s${DIM}%s${RESET}  %s ${DIM}(%s runs)${RESET}\n" "$cat" "$filled" "$empty" "$rate_pct" "$total"
    done
    echo ""
}

# ─── Reset Command ──────────────────────────────────────────────────
cmd_reset() {
    local category="${1:-}"

    if ! db_available 2>/dev/null; then
        error "Database not available. Run: shipwright db init"
        return 1
    fi

    local rh
    rh=$(_repo_hash)

    if [[ -n "$category" ]]; then
        db_capability_reset "$rh" "$category"
        success "Reset capability data for category: $category"
    else
        db_capability_reset "$rh"
        success "Reset all capability data for this repository"
    fi
}

# ─── Configure Command ──────────────────────────────────────────────
cmd_configure() {
    _capability_load_config 2>/dev/null || true

    echo ""
    echo -e "${CYAN}${BOLD}  Capability Configuration${RESET}"
    echo ""
    echo -e "  ${BOLD}min_success_rate:${RESET}              ${CAPABILITY_MIN_SUCCESS_RATE}"
    echo -e "  ${BOLD}conservative_threshold:${RESET}        ${CAPABILITY_CONSERVATIVE_THRESHOLD}"
    echo -e "  ${BOLD}min_samples:${RESET}                   ${CAPABILITY_MIN_SAMPLES}"
    echo -e "  ${BOLD}hysteresis_margin:${RESET}             ${CAPABILITY_HYSTERESIS_MARGIN}"
    echo -e "  ${BOLD}conservative_safe_categories:${RESET}  ${CAPABILITY_CONSERVATIVE_SAFE_CATEGORIES}"
    echo ""
    echo -e "  ${DIM}Configure in .claude/daemon-config.json under the \"capability\" key${RESET}"
    echo ""
}

# ─── Status Command ──────────────────────────────────────────────────
cmd_status() {
    if ! db_available 2>/dev/null; then
        error "Database not available. Run: shipwright db init"
        return 1
    fi

    local rh
    rh=$(_repo_hash)
    local overall
    overall=$(db_capability_overall_rate "$rh" 2>/dev/null || echo "0")
    local overall_pct
    overall_pct=$(awk "BEGIN { printf \"%.0f%%\", $overall * 100 }" 2>/dev/null || echo "0%")

    local entries
    entries=$(db_capability_query "$rh" 2>/dev/null || echo "[]")
    local count
    count=$(echo "$entries" | jq 'length' 2>/dev/null || echo "0")
    local total_runs
    total_runs=$(echo "$entries" | jq '[.[].total_runs] | add // 0' 2>/dev/null || echo "0")

    echo ""
    echo -e "${CYAN}${BOLD}  Capability Status${RESET}"
    echo ""
    echo -e "  ${BOLD}Categories tracked:${RESET}  $count"
    echo -e "  ${BOLD}Total runs:${RESET}          $total_runs"
    echo -e "  ${BOLD}Overall success rate:${RESET} $overall_pct"

    if capability_is_conservative_mode 2>/dev/null; then
        echo -e "  ${BOLD}Mode:${RESET}                ${YELLOW}${BOLD}CONSERVATIVE${RESET} ${DIM}(only safe categories allowed)${RESET}"
    else
        echo -e "  ${BOLD}Mode:${RESET}                ${GREEN}${BOLD}NORMAL${RESET}"
    fi
    echo ""
}

# ─── Help ──────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}shipwright capability${RESET} — Platform Capability Self-Assessment Registry"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  shipwright capability <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}show${RESET} [--json]     Display registry entries with success rates"
    echo -e "  ${CYAN}heatmap${RESET}           Terminal-colored category heatmap"
    echo -e "  ${CYAN}reset${RESET} [category]  Reset registry data (all or specific category)"
    echo -e "  ${CYAN}configure${RESET}         Show current configuration thresholds"
    echo -e "  ${CYAN}status${RESET}            Conservative mode status and overall rate"
    echo -e "  ${CYAN}help${RESET}              Show this help"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright capability show${RESET}"
    echo -e "  ${DIM}shipwright capability show --json${RESET}"
    echo -e "  ${DIM}shipwright capability heatmap${RESET}"
    echo -e "  ${DIM}shipwright capability reset refactor${RESET}"
    echo -e "  ${DIM}shipwright capability status${RESET}"
    echo ""
    echo -e "${BOLD}CONFIGURATION${RESET}  ${DIM}(.claude/daemon-config.json)${RESET}"
    echo -e "  ${DIM}capability.min_success_rate${RESET}     Reject below this (default: 0.50)"
    echo -e "  ${DIM}capability.conservative_threshold${RESET}  Conservative mode trigger (default: 0.70)"
    echo -e "  ${DIM}capability.min_samples${RESET}          Min runs before gating (default: 5)"
    echo ""
}

# ─── Main Router ──────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        show)      cmd_show "$@" ;;
        heatmap)   cmd_heatmap "$@" ;;
        reset)     cmd_reset "$@" ;;
        configure) cmd_configure "$@" ;;
        status)    cmd_status "$@" ;;
        help|--help|-h) show_help ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
