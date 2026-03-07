#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright adaptive-timeout — P95 Duration-Based Stage Timeout Engine   ║
# ║  Analyze historical stage durations, recommend + apply adaptive timeouts ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# DB layer
# shellcheck source=sw-db.sh
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"

# Fallbacks when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m>\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m+\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m!\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1mx\033[0m $*" >&2; }
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
BOLD="\033[1m"
CYAN="\033[38;2;0;212;255m"
DIM="\033[2m"
RESET="\033[0m"

# Load library modules
# shellcheck source=lib/stage-duration-metrics.sh
[[ -f "$SCRIPT_DIR/lib/stage-duration-metrics.sh" ]] && source "$SCRIPT_DIR/lib/stage-duration-metrics.sh"
# shellcheck source=lib/timeout-recommendation-engine.sh
[[ -f "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh" ]] && source "$SCRIPT_DIR/lib/timeout-recommendation-engine.sh"

# ─── Paths ─────────────────────────────────────────────────────────────────
DAEMON_CONFIG="${DAEMON_CONFIG:-.claude/daemon-config.json}"
ALL_STAGES="intake plan design build test review compound_quality pr merge deploy validate monitor"

# ─── Per-stage default timeouts ────────────────────────────────────────────
_default_timeout() {
    local stage="$1"
    case "$stage" in
        intake|pr|merge)                echo 300 ;;
        plan|design)                    echo 600 ;;
        build)                          echo 1800 ;;
        test)                           echo 900 ;;
        review|compound_quality)        echo 600 ;;
        deploy|validate|monitor)        echo 600 ;;
        *)                              echo 1800 ;;
    esac
}

# ─── Read adaptive_timeouts config ─────────────────────────────────────────
_read_config() {
    local key="${1:-enabled}"
    local default="${2:-}"
    if [[ -f "$DAEMON_CONFIG" ]]; then
        local val
        val=$(jq -r --arg k "$key" '.adaptive_timeouts[$k] // empty' "$DAEMON_CONFIG" 2>/dev/null || true)
        if [[ -n "$val" ]]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# ═══════════════════════════════════════════════════════════════════════════
# SUBCOMMANDS
# ═══════════════════════════════════════════════════════════════════════════

# ─── analyze: Calculate and store recommendations ──────────────────────────
cmd_analyze() {
    local repo_hash=""
    local window_days="30"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-hash) repo_hash="$2"; shift 2 ;;
            --window) window_days="$2"; shift 2 ;;
            --json) local json_output=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$repo_hash" ]]; then
        repo_hash=$(echo "${REPO_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
    fi

    local results="[]"
    local analyzed=0

    for stage in $ALL_STAGES; do
        local rec
        rec=$(calculate_recommended_timeout "$stage" "$repo_hash" \
            "$(_read_config p95_buffer 1.2)" \
            "$(_read_config min_timeout_seconds 60)" \
            "$(_read_config max_timeout_seconds 7200)")

        local count recommended p95 p99
        count=$(echo "$rec" | jq '.sample_count' 2>/dev/null || echo "0")
        recommended=$(echo "$rec" | jq '.recommended_timeout' 2>/dev/null || echo "0")
        p95=$(echo "$rec" | jq '.p95' 2>/dev/null || echo "0")
        p99=$(echo "$rec" | jq '.p99' 2>/dev/null || echo "0")

        # Save to DB if we have data
        if [[ "$count" -ge "${TIMEOUT_REC_MIN_SAMPLES:-10}" ]]; then
            local p50
            p50=$(get_stage_duration_stats "$stage" "$repo_hash" "$window_days" | jq '.p50' 2>/dev/null || echo "0")
            save_timeout_recommendation "$repo_hash" "$stage" "$p50" "$p95" "$p99" "$count" "$recommended"
            analyzed=$((analyzed + 1))
        fi

        results=$(echo "$results" | jq --argjson rec "$rec" '. + [$rec]')
    done

    emit_event "timeout.analysis_complete" "stages_analyzed=$analyzed" "repo_hash=$repo_hash" 2>/dev/null || true

    if [[ "${json_output:-false}" == "true" ]]; then
        echo "$results" | jq .
    else
        info "Analyzed ${analyzed} stages with sufficient data (>=${TIMEOUT_REC_MIN_SAMPLES:-10} samples)"
        printf "\n"
        printf "  %-20s  %8s  %8s  %8s  %8s  %s\n" "Stage" "P95" "Rec.T/O" "Samples" "Current" "Rationale"
        printf "  %-20s  %8s  %8s  %8s  %8s  %s\n" "$(printf '%.0s-' {1..20})" "--------" "--------" "--------" "--------" "$(printf '%.0s-' {1..30})"

        echo "$results" | jq -c '.[]' | while IFS= read -r rec; do
            local s p95_val recommended count rationale current
            s=$(echo "$rec" | jq -r '.stage_type')
            p95_val=$(echo "$rec" | jq -r '.p95')
            recommended=$(echo "$rec" | jq -r '.recommended_timeout')
            count=$(echo "$rec" | jq -r '.sample_count')
            rationale=$(echo "$rec" | jq -r '.rationale')
            current=$(_default_timeout "$s")

            if [[ -f "$DAEMON_CONFIG" ]]; then
                local cfg_val
                cfg_val=$(jq -r --arg s "$s" '.adaptive_timeouts.stage_timeouts[$s] // 0' "$DAEMON_CONFIG" 2>/dev/null || echo "0")
                [[ "$cfg_val" -gt 0 ]] 2>/dev/null && current="$cfg_val"
            fi

            printf "  %-20s  %7ss  %7ss  %8s  %7ss  %s\n" "$s" "${p95_val%%.*}" "${recommended}" "$count" "$current" "${rationale:0:40}"
        done
        printf "\n"
    fi
}

# ─── apply: Apply recommendations to config ────────────────────────────────
cmd_apply() {
    local repo_hash=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-hash) repo_hash="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            --json) local json_output=true; shift ;;
            --auto) shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$repo_hash" ]]; then
        repo_hash=$(echo "${REPO_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
    fi

    # Ensure config has adaptive_timeouts section
    if [[ -f "$DAEMON_CONFIG" ]] && [[ "$dry_run" != "true" ]]; then
        local has_section
        has_section=$(jq 'has("adaptive_timeouts")' "$DAEMON_CONFIG" 2>/dev/null || echo "false")
        if [[ "$has_section" != "true" ]]; then
            local tmp_config
            tmp_config=$(mktemp "${TMPDIR:-/tmp}/sw-config.XXXXXX")
            jq '. + {adaptive_timeouts: {enabled: true, auto_apply: false, analysis_interval_days: 7, p95_buffer: 1.2, min_timeout_seconds: 60, max_timeout_seconds: 7200, manual_overrides: {}, stage_timeouts: {}}}' "$DAEMON_CONFIG" > "$tmp_config" 2>/dev/null && \
                mv "$tmp_config" "$DAEMON_CONFIG" || rm -f "$tmp_config"
        fi
    fi

    local result
    result=$(apply_timeout_recommendations "$repo_hash" "$DAEMON_CONFIG" "$dry_run")

    local updated
    updated=$(echo "$result" | jq '.stages_updated' 2>/dev/null || echo "0")

    if [[ "${json_output:-false}" == "true" ]]; then
        echo "$result" | jq .
    else
        if [[ "$dry_run" == "true" ]]; then
            info "Dry run — no changes applied"
        fi

        if [[ "$updated" -eq 0 ]]; then
            info "No timeout adjustments needed (all within ${TIMEOUT_REC_CHANGE_THRESHOLD:-5}% threshold)"
        else
            if [[ "$dry_run" == "true" ]]; then
                info "Would update ${updated} stage timeout(s):"
            else
                success "Updated ${updated} stage timeout(s):"
            fi

            echo "$result" | jq -c '.adjustments[]' | while IFS= read -r adj; do
                local s old new reason skipped
                s=$(echo "$adj" | jq -r '.stage_type')
                old=$(echo "$adj" | jq '.old_timeout')
                new=$(echo "$adj" | jq '.new_timeout')
                reason=$(echo "$adj" | jq -r '.reason')
                skipped=$(echo "$adj" | jq '.skipped')

                if [[ "$skipped" == "true" ]]; then
                    printf "  %-20s  %5ss -> %5ss  (skipped: %s)\n" "$s" "$old" "$new" "$reason"
                else
                    printf "  %-20s  %5ss -> %5ss  (%s)\n" "$s" "$old" "$new" "$reason"
                fi
            done
        fi
        printf "\n"
    fi
}

# ─── show: Display current timeouts and stats ─────────────────────────────
cmd_show() {
    local repo_hash=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-hash) repo_hash="$2"; shift 2 ;;
            --json) local json_output=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$repo_hash" ]]; then
        repo_hash=$(echo "${REPO_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
    fi

    local results="{}"

    if [[ "${json_output:-false}" != "true" ]]; then
        printf "\n"
        printf "  %-20s  %8s  %8s  %8s  %8s  %8s  %s\n" "Stage" "Timeout" "P95" "P50" "Samples" "Source" "Manual"
        printf "  %-20s  %8s  %8s  %8s  %8s  %8s  %s\n" "$(printf '%.0s-' {1..20})" "--------" "--------" "--------" "--------" "--------" "--------"
    fi

    for stage in $ALL_STAGES; do
        local stats timeout_s source manual_override="no"
        stats=$(get_stage_duration_stats "$stage" "$repo_hash" 2>/dev/null || echo '{"p50":0,"p95":0,"count":0}')

        local p50 p95 count
        p50=$(echo "$stats" | jq '.p50 // 0' 2>/dev/null || echo "0")
        p95=$(echo "$stats" | jq '.p95 // 0' 2>/dev/null || echo "0")
        count=$(echo "$stats" | jq '.count // 0' 2>/dev/null || echo "0")

        # Check config for manual override
        if [[ -f "$DAEMON_CONFIG" ]]; then
            local manual
            manual=$(jq -r --arg s "$stage" '.adaptive_timeouts.manual_overrides[$s] // "null"' "$DAEMON_CONFIG" 2>/dev/null || echo "null")
            if [[ "$manual" != "null" ]]; then
                timeout_s="$manual"
                source="manual"
                manual_override="yes"
            fi
        fi

        # Check config for adaptive timeout
        if [[ "${source:-}" != "manual" ]] && [[ -f "$DAEMON_CONFIG" ]]; then
            local cfg_val
            cfg_val=$(jq -r --arg s "$stage" '.adaptive_timeouts.stage_timeouts[$s] // "null"' "$DAEMON_CONFIG" 2>/dev/null || echo "null")
            if [[ "$cfg_val" != "null" ]]; then
                timeout_s="$cfg_val"
                source="adaptive"
            fi
        fi

        # Default fallback
        if [[ -z "${timeout_s:-}" ]] || [[ "${source:-}" == "" ]]; then
            timeout_s=$(_default_timeout "$stage")
            source="default"
        fi

        if [[ "${json_output:-false}" == "true" ]]; then
            results=$(echo "$results" | jq --arg s "$stage" --argjson t "$timeout_s" \
                --argjson p95 "${p95:-0}" --argjson p50 "${p50:-0}" --argjson n "$count" \
                --arg src "$source" --arg man "$manual_override" \
                '.[$s] = {timeout: $t, p95: $p95, p50: $p50, samples: $n, source: $src, manual: $man}')
        else
            printf "  %-20s  %7ss  %7ss  %7ss  %8s  %8s  %s\n" \
                "$stage" "$timeout_s" "${p95%%.*}" "${p50%%.*}" "$count" "$source" "$manual_override"
        fi
    done

    if [[ "${json_output:-false}" == "true" ]]; then
        echo "$results" | jq .
    else
        printf "\n"
    fi
}

# ─── history: Show timeout adjustment history ──────────────────────────────
cmd_history() {
    local repo_hash=""
    local stage=""
    local days=30
    local limit=50

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-hash) repo_hash="$2"; shift 2 ;;
            --stage) stage="$2"; shift 2 ;;
            --days) days="$2"; shift 2 ;;
            --limit) limit="$2"; shift 2 ;;
            --json) local json_output=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$repo_hash" ]]; then
        repo_hash=$(echo "${REPO_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
    fi

    # Query from DB
    local results="[]"
    if type _db_query >/dev/null 2>&1; then
        local stage_clause=""
        if [[ -n "$stage" ]]; then
            stage_clause="AND stage_type = '${stage}'"
        fi
        results=$(_db_query -json "SELECT repo_hash, stage_type, old_timeout, new_timeout, reason, applied_at FROM timeout_adjustments WHERE repo_hash = '${repo_hash}' ${stage_clause} AND applied_at > datetime('now', '-${days} days') ORDER BY applied_at DESC LIMIT ${limit};" 2>/dev/null || echo "[]")
    fi

    local count
    count=$(echo "$results" | jq 'length' 2>/dev/null || echo "0")

    if [[ "${json_output:-false}" == "true" ]]; then
        echo "$results" | jq .
    else
        if [[ "$count" -eq 0 ]]; then
            info "No timeout adjustments found in the last ${days} days"
        else
            info "Timeout adjustment history (last ${days} days):"
            printf "\n"
            printf "  %-20s  %8s  %8s  %8s  %-20s  %s\n" "Stage" "Old" "New" "Change" "Reason" "Applied"
            printf "  %-20s  %8s  %8s  %8s  %-20s  %s\n" "$(printf '%.0s-' {1..20})" "--------" "--------" "--------" "$(printf '%.0s-' {1..20})" "$(printf '%.0s-' {1..20})"

            echo "$results" | jq -c '.[]' | while IFS= read -r adj; do
                local s old new reason applied change
                s=$(echo "$adj" | jq -r '.stage_type')
                old=$(echo "$adj" | jq '.old_timeout')
                new=$(echo "$adj" | jq '.new_timeout')
                reason=$(echo "$adj" | jq -r '.reason')
                applied=$(echo "$adj" | jq -r '.applied_at')
                change=$(( new - old ))

                printf "  %-20s  %7ss  %7ss  %+7ss  %-20s  %s\n" "$s" "$old" "$new" "$change" "$reason" "${applied:0:19}"
            done
        fi
        printf "\n"
    fi
}

# ─── status: Quick status check ────────────────────────────────────────────
cmd_status() {
    local enabled
    enabled=$(_read_config enabled false)
    local auto_apply
    auto_apply=$(_read_config auto_apply false)
    local interval
    interval=$(_read_config analysis_interval_days 7)
    local buffer
    buffer=$(_read_config p95_buffer 1.2)

    printf "\n"
    printf "  Adaptive Timeouts:\n"
    printf "    Enabled:           %s\n" "$enabled"
    printf "    Auto-apply:        %s\n" "$auto_apply"
    printf "    Analysis interval: %s days\n" "$interval"
    printf "    P95 buffer:        %sx\n" "$buffer"
    printf "    Min timeout:       %ss\n" "$(_read_config min_timeout_seconds 60)"
    printf "    Max timeout:       %ss\n" "$(_read_config max_timeout_seconds 7200)"

    # Manual overrides
    if [[ -f "$DAEMON_CONFIG" ]]; then
        local overrides
        overrides=$(jq -r '.adaptive_timeouts.manual_overrides // {} | to_entries | map("\(.key)=\(.value)s") | join(", ")' "$DAEMON_CONFIG" 2>/dev/null || echo "none")
        printf "    Manual overrides:  %s\n" "${overrides:-none}"
    fi
    printf "\n"
}

# ─── help ──────────────────────────────────────────────────────────────────
cmd_help() {
    cat <<EOF
${BOLD}shipwright adaptive-timeout${RESET} -- P95 Duration-Based Stage Timeout Engine

${BOLD}USAGE${RESET}
  sw adaptive-timeout <subcommand> [options]

${BOLD}SUBCOMMANDS${RESET}
  ${CYAN}analyze${RESET} [--repo-hash H] [--window N] [--json]
    Calculate timeout recommendations from historical stage durations.
    Uses P95 * buffer formula with 30-day rolling window.

  ${CYAN}apply${RESET} [--repo-hash H] [--dry-run] [--json]
    Apply recommendations to daemon-config.json.
    Respects manual overrides. Use --dry-run to preview changes.

  ${CYAN}show${RESET} [--repo-hash H] [--json]
    Display current timeouts for all stages (source: adaptive/manual/default).

  ${CYAN}history${RESET} [--repo-hash H] [--stage S] [--days N] [--json]
    Show timeout adjustment history from the audit trail.

  ${CYAN}status${RESET}
    Show adaptive timeout configuration.

  ${CYAN}help${RESET}
    Show this help message.

${BOLD}CONFIGURATION${RESET} (in daemon-config.json)
  {
    "adaptive_timeouts": {
      "enabled": true,
      "auto_apply": false,
      "analysis_interval_days": 7,
      "p95_buffer": 1.2,
      "min_timeout_seconds": 60,
      "max_timeout_seconds": 7200,
      "manual_overrides": { "build": 1800 },
      "stage_timeouts": {}
    }
  }

${BOLD}FORMULA${RESET}
  timeout = max(P95 * buffer, min_timeout), clamped to max_timeout
  Changes only applied when difference > 5% from current value.
  Manual overrides always take precedence over auto-tuning.

${BOLD}EXAMPLES${RESET}
  sw adaptive-timeout analyze                  # Analyze all stages
  sw adaptive-timeout apply --dry-run          # Preview changes
  sw adaptive-timeout apply                    # Apply recommendations
  sw adaptive-timeout show --json              # JSON output
  sw adaptive-timeout history --stage build    # Build stage history
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        analyze)  cmd_analyze "$@" ;;
        apply)    cmd_apply "$@" ;;
        show)     cmd_show "$@" ;;
        history)  cmd_history "$@" ;;
        status)   cmd_status ;;
        help)     cmd_help ;;
        version)  echo "sw-adaptive-timeout v${VERSION}" ;;
        *)
            error "Unknown command: $cmd"
            cmd_help
            return 1
            ;;
    esac
}

# Source guard: only run main when executed directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
