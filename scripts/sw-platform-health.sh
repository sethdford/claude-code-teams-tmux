#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-platform-health.sh — Platform Self-Improvement Health Dashboard     ║
# ║                                                                          ║
# ║  Collects platform health metrics (hardcoded counts, fallbacks,          ║
# ║  TODOs/FIXMEs/HACKs, script sizes), stores trend snapshots, generates   ║
# ║  alerts, and auto-creates GitHub issues when thresholds are exceeded.    ║
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
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Constants ─────────────────────────────────────────────────────────────
HEALTH_DIR="${HOME}/.shipwright/platform-health"
THRESHOLD_HARDCODED=50
THRESHOLD_SCRIPT_LINES=3000
THRESHOLD_DEBT_TREND_7D=5
MAX_ISSUES_PER_RUN=3
THRESHOLD_DISPLAY_LINES=2000

# ─── Help text ─────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright platform-health <command> [OPTIONS]

COMMANDS
  scan          Scan codebase and output health metrics as JSON
  show          Display formatted health dashboard in terminal
  json          Output full health report (snapshot + trends + alerts) as JSON
  auto-issue    Check thresholds and create GitHub issues for violations
  history       Show historical trend data
  snapshot      Take a snapshot and save to disk

OPTIONS
  --help, -h      Show this help text
  --version, -v   Show version
  --scripts-dir   Override scripts directory to scan (default: auto-detect)

EXAMPLES
  shipwright platform-health scan
  shipwright platform-health show
  shipwright platform-health auto-issue
  shipwright platform-health history

EOF
}

# ─── Scan: collect platform health metrics ─────────────────────────────────
platform_health_scan() {
    local scan_dir="${1:-$SCRIPT_DIR}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Count hardcoded values (case-insensitive grep for "hardcoded" or "hard-coded")
    local hardcoded_count=0
    hardcoded_count=$(grep -ri "hardcoded\|hard-coded\|hard_coded" "$scan_dir"/sw-*.sh 2>/dev/null | grep -cv "^$" || true)
    hardcoded_count="${hardcoded_count:-0}"

    # Count fallback patterns: ${VAR:-value} but filter out empty defaults ${VAR:-}
    local fallback_count=0
    fallback_count=$(grep -r '${[A-Za-z_][A-Za-z_0-9]*:-[^}][^}]*}' "$scan_dir"/sw-*.sh 2>/dev/null | grep -cv ':-\(test\|false\|true\|0\|1\|""\)' || true)
    fallback_count="${fallback_count:-0}"

    # Count TODOs, FIXMEs, HACKs (exclude test files)
    local todo_count=0 fixme_count=0 hack_count=0
    todo_count=$(grep -r "TODO" "$scan_dir"/sw-*.sh 2>/dev/null | grep -cv "\-test\.sh" || true)
    todo_count="${todo_count:-0}"
    fixme_count=$(grep -r "FIXME" "$scan_dir"/sw-*.sh 2>/dev/null | grep -cv "\-test\.sh" || true)
    fixme_count="${fixme_count:-0}"
    hack_count=$(grep -r "HACK" "$scan_dir"/sw-*.sh 2>/dev/null | grep -cv "\-test\.sh" || true)
    hack_count="${hack_count:-0}"

    local total_debt=$((hardcoded_count + fallback_count + todo_count + fixme_count + hack_count))

    # Top 10 largest scripts (non-test)
    local top_scripts="[]"
    local scripts_over_threshold=0
    if ls "$scan_dir"/sw-*.sh >/dev/null 2>&1; then
        local tmp_sizes
        tmp_sizes=$(mktemp)
        for f in "$scan_dir"/sw-*.sh; do
            local base
            base=$(basename "$f")
            # Skip test scripts
            case "$base" in *-test.sh) continue;; esac
            local lines
            lines=$(wc -l < "$f")
            echo "$lines $base" >> "$tmp_sizes"
        done
        # Sort and take top 10
        sort -rn "$tmp_sizes" > "${tmp_sizes}.sorted"
        top_scripts="["
        local first=true
        local count=0
        while IFS=' ' read -r lines name; do
            [[ -z "$lines" ]] && continue
            if [[ "$first" == "true" ]]; then
                first=false
            else
                top_scripts="${top_scripts},"
            fi
            top_scripts="${top_scripts}{\"name\":$(printf '%s' "$name" | jq -Rs .),\"lines\":${lines}}"
            if [[ "$lines" -gt "$THRESHOLD_DISPLAY_LINES" ]]; then
                scripts_over_threshold=$((scripts_over_threshold + 1))
            fi
            count=$((count + 1))
            [[ "$count" -ge 10 ]] && break
        done < "${tmp_sizes}.sorted"
        top_scripts="${top_scripts}]"
        rm -f "$tmp_sizes" "${tmp_sizes}.sorted"
    fi

    # Output JSON
    jq -n \
        --arg ts "$ts" \
        --argjson hardcoded "$hardcoded_count" \
        --argjson fallback "$fallback_count" \
        --argjson todo "$todo_count" \
        --argjson fixme "$fixme_count" \
        --argjson hack "$hack_count" \
        --argjson debt "$total_debt" \
        --argjson top "$top_scripts" \
        --argjson over "$scripts_over_threshold" \
        --argjson threshold "$THRESHOLD_DISPLAY_LINES" \
        '{
            ts: $ts,
            hardcoded_count: $hardcoded,
            fallback_count: $fallback,
            todo_count: $todo,
            fixme_count: $fixme,
            hack_count: $hack,
            total_debt: $debt,
            top_scripts: $top,
            scripts_over_threshold: $over,
            threshold_lines: $threshold
        }'
}

# ─── Snapshot: save scan results to disk ───────────────────────────────────
platform_health_snapshot() {
    local scan_dir="${1:-$SCRIPT_DIR}"
    mkdir -p "$HEALTH_DIR"
    local today
    today=$(date -u +"%Y-%m-%d")
    local snapshot
    snapshot=$(platform_health_scan "$scan_dir")

    # Atomic write: tmp + mv
    local tmp_file
    tmp_file=$(mktemp "${HEALTH_DIR}/tmp.XXXXXX")
    echo "$snapshot" > "$tmp_file"
    mv "$tmp_file" "${HEALTH_DIR}/${today}.json"

    emit_event "platform_health.snapshot" "date=$today" "total_debt=$(echo "$snapshot" | jq -r '.total_debt')"
    echo "$snapshot"
}

# ─── Trends: compute 7/30 day deltas ──────────────────────────────────────
platform_health_trends() {
    local today_snapshot="${1:-}"
    if [[ -z "$today_snapshot" ]]; then
        local today
        today=$(date -u +"%Y-%m-%d")
        if [[ -f "${HEALTH_DIR}/${today}.json" ]]; then
            today_snapshot=$(cat "${HEALTH_DIR}/${today}.json")
        else
            # No snapshot yet, return zero deltas
            echo '{"delta_7d":{"hardcoded":0,"fallback":0,"debt":0,"scripts_over_threshold":0},"delta_30d":{"hardcoded":0,"fallback":0,"debt":0,"scripts_over_threshold":0}}'
            return 0
        fi
    fi

    local current_hardcoded current_fallback current_debt current_over
    current_hardcoded=$(echo "$today_snapshot" | jq -r '.hardcoded_count')
    current_fallback=$(echo "$today_snapshot" | jq -r '.fallback_count')
    current_debt=$(echo "$today_snapshot" | jq -r '.total_debt')
    current_over=$(echo "$today_snapshot" | jq -r '.scripts_over_threshold')

    local delta_7d delta_30d

    # Compute 7-day delta
    delta_7d=$(platform_health_delta "$current_hardcoded" "$current_fallback" "$current_debt" "$current_over" 7)
    # Compute 30-day delta
    delta_30d=$(platform_health_delta "$current_hardcoded" "$current_fallback" "$current_debt" "$current_over" 30)

    jq -n --argjson d7 "$delta_7d" --argjson d30 "$delta_30d" '{delta_7d: $d7, delta_30d: $d30}'
}

# ─── Delta helper: compute delta for N days ago ───────────────────────────
platform_health_delta() {
    local cur_hardcoded="$1" cur_fallback="$2" cur_debt="$3" cur_over="$4" days="$5"

    # Find snapshot from N days ago
    local target_date
    if date --version >/dev/null 2>&1; then
        # GNU date
        target_date=$(date -u -d "${days} days ago" +"%Y-%m-%d")
    else
        # BSD date (macOS)
        target_date=$(date -u -v-"${days}"d +"%Y-%m-%d")
    fi

    if [[ -f "${HEALTH_DIR}/${target_date}.json" ]]; then
        local old_hardcoded old_fallback old_debt old_over
        old_hardcoded=$(jq -r '.hardcoded_count' "${HEALTH_DIR}/${target_date}.json")
        old_fallback=$(jq -r '.fallback_count' "${HEALTH_DIR}/${target_date}.json")
        old_debt=$(jq -r '.total_debt' "${HEALTH_DIR}/${target_date}.json")
        old_over=$(jq -r '.scripts_over_threshold' "${HEALTH_DIR}/${target_date}.json")
        jq -n \
            --argjson h "$((cur_hardcoded - old_hardcoded))" \
            --argjson f "$((cur_fallback - old_fallback))" \
            --argjson d "$((cur_debt - old_debt))" \
            --argjson o "$((cur_over - old_over))" \
            '{hardcoded: $h, fallback: $f, debt: $d, scripts_over_threshold: $o}'
    else
        echo '{"hardcoded":0,"fallback":0,"debt":0,"scripts_over_threshold":0}'
    fi
}

# ─── Alerts: check thresholds ─────────────────────────────────────────────
platform_health_alerts() {
    local snapshot="${1:-}"
    local trends="${2:-}"

    if [[ -z "$snapshot" ]]; then
        echo "[]"
        return 0
    fi

    local alerts="[]"

    # Check hardcoded count threshold
    local hardcoded
    hardcoded=$(echo "$snapshot" | jq -r '.hardcoded_count')
    if [[ "$hardcoded" -gt "$THRESHOLD_HARDCODED" ]]; then
        alerts=$(echo "$alerts" | jq --argjson t "$THRESHOLD_HARDCODED" --argjson c "$hardcoded" \
            '. + [{"type":"hardcoded_high","severity":"warning","message":"Hardcoded value count exceeds threshold","threshold":$t,"current":$c}]')
    fi

    # Check individual script size thresholds
    local script_count
    script_count=$(echo "$snapshot" | jq '.top_scripts | length')
    local i=0
    while [[ "$i" -lt "$script_count" ]]; do
        local sname slines
        sname=$(echo "$snapshot" | jq -r ".top_scripts[$i].name")
        slines=$(echo "$snapshot" | jq -r ".top_scripts[$i].lines")
        if [[ "$slines" -gt "$THRESHOLD_SCRIPT_LINES" ]]; then
            alerts=$(echo "$alerts" | jq \
                --arg s "$sname" \
                --argjson l "$slines" \
                --argjson t "$THRESHOLD_SCRIPT_LINES" \
                '. + [{"type":"script_too_large","severity":"warning","message":"Script exceeds size threshold","script":$s,"lines":$l,"threshold":$t,"current":$l}]')
        fi
        i=$((i + 1))
    done

    # Check debt trend (7-day) threshold
    if [[ -n "$trends" ]]; then
        local debt_7d
        debt_7d=$(echo "$trends" | jq -r '.delta_7d.debt')
        if [[ "$debt_7d" -gt "$THRESHOLD_DEBT_TREND_7D" ]]; then
            alerts=$(echo "$alerts" | jq \
                --argjson t "$THRESHOLD_DEBT_TREND_7D" \
                --argjson c "$debt_7d" \
                '. + [{"type":"debt_trending_up","severity":"critical","message":"Technical debt trending up over 7 days","threshold":$t,"current":$c}]')
        fi
    fi

    echo "$alerts"
}

# ─── Auto-issue: create GitHub issues for alert conditions ────────────────
platform_health_auto_issue() {
    local alerts="${1:-[]}"
    local created=0
    local alert_count
    alert_count=$(echo "$alerts" | jq 'length')

    if [[ "$alert_count" -eq 0 ]]; then
        info "No platform health alerts — no issues to create"
        return 0
    fi

    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        info "[dry-run] Would create issues for $alert_count alert(s)"
        local j=0
        while [[ "$j" -lt "$alert_count" ]]; do
            local msg
            msg=$(echo "$alerts" | jq -r ".[$j].message")
            info "  [dry-run] Platform Self-Improvement: $msg"
            j=$((j + 1))
        done
        return 0
    fi

    local i=0
    while [[ "$i" -lt "$alert_count" && "$created" -lt "$MAX_ISSUES_PER_RUN" ]]; do
        local alert_type alert_msg alert_severity
        alert_type=$(echo "$alerts" | jq -r ".[$i].type")
        alert_msg=$(echo "$alerts" | jq -r ".[$i].message")
        alert_severity=$(echo "$alerts" | jq -r ".[$i].severity")

        local title="Platform Self-Improvement: ${alert_msg}"
        local body=""

        case "$alert_type" in
            hardcoded_high)
                local current threshold
                current=$(echo "$alerts" | jq -r ".[$i].current")
                threshold=$(echo "$alerts" | jq -r ".[$i].threshold")
                body="## Platform Health Alert

**Type**: Hardcoded values exceeding threshold
**Current count**: ${current}
**Threshold**: ${threshold}
**Severity**: ${alert_severity}

### Suggested Actions
- Run \`shipwright platform-health scan\` to see current metrics
- Search for hardcoded values: \`grep -rn 'hardcoded\\|hard-coded' scripts/sw-*.sh\`
- Replace hardcoded values with configurable parameters

_Auto-generated by Shipwright platform health monitor_"
                ;;
            script_too_large)
                local script_name script_lines script_threshold
                script_name=$(echo "$alerts" | jq -r ".[$i].script")
                script_lines=$(echo "$alerts" | jq -r ".[$i].lines")
                script_threshold=$(echo "$alerts" | jq -r ".[$i].threshold")
                title="Platform Self-Improvement: ${script_name} exceeds ${script_threshold} lines"
                body="## Platform Health Alert

**Type**: Script too large
**Script**: ${script_name}
**Lines**: ${script_lines}
**Threshold**: ${script_threshold}
**Severity**: ${alert_severity}

### Suggested Actions
- Extract helper functions into \`scripts/lib/\` modules
- Split into focused sub-scripts
- Run \`shipwright platform-health show\` for full dashboard

_Auto-generated by Shipwright platform health monitor_"
                ;;
            debt_trending_up)
                local debt_current debt_threshold
                debt_current=$(echo "$alerts" | jq -r ".[$i].current")
                debt_threshold=$(echo "$alerts" | jq -r ".[$i].threshold")
                body="## Platform Health Alert

**Type**: Technical debt trending up
**7-day debt increase**: +${debt_current}
**Threshold**: +${debt_threshold}
**Severity**: ${alert_severity}

### Suggested Actions
- Run \`shipwright platform-health history\` to see trend data
- Review recent commits for debt-introducing changes
- Prioritize cleanup of high-debt areas

_Auto-generated by Shipwright platform health monitor_"
                ;;
        esac

        # Dedup: check for existing open issue with similar title
        local existing
        existing=$(gh issue list --state open --search "Platform Self-Improvement:" --label platform --json title --jq '.[].title' 2>/dev/null || echo "")
        if echo "$existing" | grep -qF "$title" 2>/dev/null; then
            info "  Skipping duplicate: $title"
        else
            if gh issue create --title "$title" --body "$body" --label "platform,technical-debt" 2>/dev/null; then
                created=$((created + 1))
                emit_event "platform_health.issue_created" "type=$alert_type" "title=$title"
                success "  Created issue: $title"
            else
                warn "  Failed to create issue: $title"
            fi
        fi

        i=$((i + 1))
    done

    if [[ "$created" -gt 0 ]]; then
        info "Created $created platform health issue(s)"
    fi
}

# ─── JSON: full health report ──────────────────────────────────────────────
platform_health_json() {
    local scan_dir="${1:-$SCRIPT_DIR}"
    local snapshot trends alerts history

    # Get or create today's snapshot
    local today
    today=$(date -u +"%Y-%m-%d")
    if [[ -f "${HEALTH_DIR}/${today}.json" ]]; then
        snapshot=$(cat "${HEALTH_DIR}/${today}.json")
    else
        snapshot=$(platform_health_scan "$scan_dir")
    fi

    trends=$(platform_health_trends "$snapshot")
    alerts=$(platform_health_alerts "$snapshot" "$trends")

    # Build history from recent snapshots
    history="[]"
    if [[ -d "$HEALTH_DIR" ]]; then
        local files
        files=$(ls -1 "${HEALTH_DIR}"/*.json 2>/dev/null | sort -r | head -30 || true)
        if [[ -n "$files" ]]; then
            while IFS= read -r f; do
                [[ -f "$f" ]] || continue
                local fdate fdebt
                fdate=$(basename "$f" .json)
                fdebt=$(jq -r '.total_debt' "$f" 2>/dev/null || echo "0")
                history=$(echo "$history" | jq --arg d "$fdate" --argjson t "$fdebt" '. + [{"date":$d,"total_debt":$t}]')
            done <<< "$files"
        fi
    fi

    jq -n \
        --argjson snapshot "$snapshot" \
        --argjson trends "$trends" \
        --argjson alerts "$alerts" \
        --argjson history "$history" \
        '{snapshot: $snapshot, trends: $trends, alerts: $alerts, history: $history}'
}

# ─── History: show historical trend data ───────────────────────────────────
platform_health_history() {
    if [[ ! -d "$HEALTH_DIR" ]]; then
        info "No platform health history yet. Run 'shipwright platform-health snapshot' first."
        return 0
    fi

    local files
    files=$(ls -1 "${HEALTH_DIR}"/*.json 2>/dev/null | sort -r | head -30 || true)
    if [[ -z "$files" ]]; then
        info "No platform health snapshots found."
        return 0
    fi

    echo ""
    echo -e "\033[1m  Platform Health History\033[0m"
    echo -e "  \033[2m────────────────────────────────────────\033[0m"
    printf "  %-12s  %6s  %6s  %6s  %6s  %6s  %6s\n" "Date" "Hdcod" "Fallbk" "TODO" "FIXME" "HACK" "Debt"
    echo -e "  \033[2m────────────────────────────────────────\033[0m"

    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        local fdate hardcoded fallback todo fixme hack debt
        fdate=$(basename "$f" .json)
        hardcoded=$(jq -r '.hardcoded_count // 0' "$f" 2>/dev/null)
        fallback=$(jq -r '.fallback_count // 0' "$f" 2>/dev/null)
        todo=$(jq -r '.todo_count // 0' "$f" 2>/dev/null)
        fixme=$(jq -r '.fixme_count // 0' "$f" 2>/dev/null)
        hack=$(jq -r '.hack_count // 0' "$f" 2>/dev/null)
        debt=$(jq -r '.total_debt // 0' "$f" 2>/dev/null)
        printf "  %-12s  %6s  %6s  %6s  %6s  %6s  %6s\n" "$fdate" "$hardcoded" "$fallback" "$todo" "$fixme" "$hack" "$debt"
    done <<< "$files"
    echo ""
}

# ─── Show: formatted terminal dashboard ────────────────────────────────────
platform_health_show() {
    local scan_dir="${1:-$SCRIPT_DIR}"
    local snapshot trends alerts

    # Get or create today's snapshot
    local today
    today=$(date -u +"%Y-%m-%d")
    if [[ -f "${HEALTH_DIR}/${today}.json" ]]; then
        snapshot=$(cat "${HEALTH_DIR}/${today}.json")
    else
        snapshot=$(platform_health_scan "$scan_dir")
    fi

    trends=$(platform_health_trends "$snapshot")
    alerts=$(platform_health_alerts "$snapshot" "$trends")

    local hardcoded fallback todo fixme hack debt over
    hardcoded=$(echo "$snapshot" | jq -r '.hardcoded_count')
    fallback=$(echo "$snapshot" | jq -r '.fallback_count')
    todo=$(echo "$snapshot" | jq -r '.todo_count')
    fixme=$(echo "$snapshot" | jq -r '.fixme_count')
    hack=$(echo "$snapshot" | jq -r '.hack_count')
    debt=$(echo "$snapshot" | jq -r '.total_debt')
    over=$(echo "$snapshot" | jq -r '.scripts_over_threshold')

    echo ""
    echo -e "\033[1m  Platform Health Dashboard\033[0m"
    echo -e "  \033[2m════════════════════════════════════════\033[0m"

    echo -e "\n  \033[1mDebt Metrics\033[0m"
    echo -e "  Hardcoded values:  \033[38;2;0;212;255m${hardcoded}\033[0m"
    echo -e "  Fallback patterns: \033[38;2;0;212;255m${fallback}\033[0m"
    echo -e "  TODO comments:     \033[38;2;0;212;255m${todo}\033[0m"
    echo -e "  FIXME comments:    \033[38;2;250;204;21m${fixme}\033[0m"
    echo -e "  HACK comments:     \033[38;2;248;113;113m${hack}\033[0m"
    echo -e "  \033[1mTotal debt score:   ${debt}\033[0m"

    # Trends
    local d7_debt d30_debt
    d7_debt=$(echo "$trends" | jq -r '.delta_7d.debt')
    d30_debt=$(echo "$trends" | jq -r '.delta_30d.debt')
    echo -e "\n  \033[1mTrends\033[0m"
    local d7_color="\033[38;2;74;222;128m"
    local d30_color="\033[38;2;74;222;128m"
    [[ "$d7_debt" -gt 0 ]] && d7_color="\033[38;2;248;113;113m"
    [[ "$d30_debt" -gt 0 ]] && d30_color="\033[38;2;248;113;113m"
    local d7_sign="" d30_sign=""
    [[ "$d7_debt" -gt 0 ]] && d7_sign="+"
    [[ "$d30_debt" -gt 0 ]] && d30_sign="+"
    echo -e "  7-day delta:  ${d7_color}${d7_sign}${d7_debt}\033[0m"
    echo -e "  30-day delta: ${d30_color}${d30_sign}${d30_debt}\033[0m"

    # Top scripts
    echo -e "\n  \033[1mTop Scripts by Size\033[0m"
    echo -e "  \033[2m──────────────────────────────────────\033[0m"
    local script_count
    script_count=$(echo "$snapshot" | jq '.top_scripts | length')
    local idx=0
    while [[ "$idx" -lt "$script_count" && "$idx" -lt 10 ]]; do
        local sname slines
        sname=$(echo "$snapshot" | jq -r ".top_scripts[$idx].name")
        slines=$(echo "$snapshot" | jq -r ".top_scripts[$idx].lines")
        local scolor="\033[0m"
        [[ "$slines" -gt "$THRESHOLD_SCRIPT_LINES" ]] && scolor="\033[38;2;248;113;113m"
        [[ "$slines" -gt "$THRESHOLD_DISPLAY_LINES" && "$slines" -le "$THRESHOLD_SCRIPT_LINES" ]] && scolor="\033[38;2;250;204;21m"
        printf "  %-35s ${scolor}%5s lines\033[0m\n" "$sname" "$slines"
        idx=$((idx + 1))
    done
    echo -e "  Scripts over ${THRESHOLD_DISPLAY_LINES} lines: \033[38;2;250;204;21m${over}\033[0m"

    # Alerts
    local alert_count
    alert_count=$(echo "$alerts" | jq 'length')
    if [[ "$alert_count" -gt 0 ]]; then
        echo -e "\n  \033[38;2;248;113;113m\033[1mAlerts ($alert_count)\033[0m"
        local aidx=0
        while [[ "$aidx" -lt "$alert_count" ]]; do
            local amsg asev
            amsg=$(echo "$alerts" | jq -r ".[$aidx].message")
            asev=$(echo "$alerts" | jq -r ".[$aidx].severity")
            local aicon="⚠"
            [[ "$asev" == "critical" ]] && aicon="✗"
            echo -e "  ${aicon} ${amsg}"
            aidx=$((aidx + 1))
        done
    else
        echo -e "\n  \033[38;2;74;222;128m\033[1mNo alerts — all metrics within thresholds\033[0m"
    fi
    echo ""
}

# ─── Patrol integration ───────────────────────────────────────────────────
platform_health_patrol() {
    local scan_dir="${1:-$SCRIPT_DIR}"
    info "  Running platform health scan..."
    local snapshot
    snapshot=$(platform_health_snapshot "$scan_dir")
    local trends
    trends=$(platform_health_trends "$snapshot")
    local alerts
    alerts=$(platform_health_alerts "$snapshot" "$trends")
    local alert_count
    alert_count=$(echo "$alerts" | jq 'length')
    if [[ "$alert_count" -gt 0 ]]; then
        warn "  Platform health: $alert_count alert(s) detected"
        platform_health_auto_issue "$alerts"
    else
        success "  Platform health: all metrics within thresholds"
    fi
}

# ─── Main ──────────────────────────────────────────────────────────────────
main() {
    local scripts_dir="$SCRIPT_DIR"
    local cmd="${1:-show}"
    shift || true

    # Parse global options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) show_help; exit 0 ;;
            --version|-v) echo "$VERSION"; exit 0 ;;
            --scripts-dir) scripts_dir="$2"; shift 2 ;;
            *) break ;;
        esac
    done

    case "$cmd" in
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-v)
            echo "$VERSION"
            exit 0
            ;;
        scan)
            platform_health_scan "$scripts_dir"
            ;;
        snapshot)
            platform_health_snapshot "$scripts_dir"
            ;;
        show)
            platform_health_show "$scripts_dir"
            ;;
        json)
            platform_health_json "$scripts_dir"
            ;;
        auto-issue)
            local snapshot trends alerts
            snapshot=$(platform_health_scan "$scripts_dir")
            trends=$(platform_health_trends "$snapshot")
            alerts=$(platform_health_alerts "$snapshot" "$trends")
            platform_health_auto_issue "$alerts"
            ;;
        history)
            platform_health_history
            ;;
        patrol)
            platform_health_patrol "$scripts_dir"
            ;;
        *)
            error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
