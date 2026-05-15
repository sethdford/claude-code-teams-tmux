#!/usr/bin/env bash
# Module: pipeline-limits
# Global pipeline timeout and emergency cost circuit breaker.
# Public API:
#   limits_init                      — read config + env, export PIPELINE_LIMITS_*
#   limits_pipeline_cost_cents       — sum cost (cents) for current run since start
#   limits_check <stage_id>          — 0 ok / 124 timeout / 125 cost
#   limits_abort <code> <stage>      — checkpoint, set status, emit event, notify
set -euo pipefail

# Module guard
[[ -n "${_MODULE_PIPELINE_LIMITS_LOADED:-}" ]] && return 0
_MODULE_PIPELINE_LIMITS_LOADED=1

VERSION="3.3.0"

# Exit codes (also used as return codes from limits_check)
LIMITS_OK=0
LIMITS_EXIT_TIMEOUT=124
LIMITS_EXIT_COST=125

# ─── Defaults & helpers ──────────────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
COST_FILE="${COST_FILE:-${HOME}/.shipwright/costs.json}"

# Output helpers (only define if not already provided by caller)
[[ "$(type -t info  2>/dev/null)" == "function" ]] || info()  { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t warn  2>/dev/null)" == "function" ]] || warn()  { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]] || error() { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { :; }
[[ "$(type -t now_epoch 2>/dev/null)" == "function" ]] || now_epoch() { date +%s; }
[[ "$(type -t now_iso   2>/dev/null)" == "function" ]] || now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Source compat for _smart_int if not present
if [[ "$(type -t _smart_int 2>/dev/null)" != "function" ]]; then
    if [[ -f "$SCRIPT_DIR/compat.sh" ]]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/compat.sh" 2>/dev/null || true
    elif [[ -f "$SCRIPT_DIR/lib/compat.sh" ]]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/lib/compat.sh" 2>/dev/null || true
    fi
fi
# Final fallback: stub _smart_int
[[ "$(type -t _smart_int 2>/dev/null)" == "function" ]] || _smart_int() { echo "$2"; }

# ─── usd→cents conversion ────────────────────────────────────────────────────
# Convert decimal USD string to integer cents (handles "0.01", "50", "50.0").
limits_usd_to_cents() {
    local usd="${1:-0}"
    # Validate — allow optional sign, digits, optional decimal
    if [[ ! "$usd" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        echo "0"
        return 0
    fi
    awk -v v="$usd" 'BEGIN { printf "%.0f", v * 100 }'
}

# ─── limits_init ─────────────────────────────────────────────────────────────
# Reads pipeline.global_timeout_seconds (default 14400) and pipeline.max_cost_usd
# (default 50.0). Exports:
#   PIPELINE_LIMITS_TIMEOUT_S    integer seconds; 0 = disabled
#   PIPELINE_LIMITS_MAX_CENTS    integer cents;   0 = disabled
#   PIPELINE_LIMITS_START_EPOCH  pipeline start epoch
#   PIPELINE_LIMITS_RUN_ID       pipeline identifier (issue or goal slug)
limits_init() {
    local timeout_s max_usd max_cents

    # Timeout: env (SW_GLOBAL_TIMEOUT_SECONDS) → daemon-config.json → 14400 default
    local env_timeout=""
    eval 'env_timeout="${SW_GLOBAL_TIMEOUT_SECONDS:-}"' 2>/dev/null || true
    if [[ -n "$env_timeout" ]]; then
        timeout_s="$env_timeout"
    else
        local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
        local cfg_to=""
        if [[ -f "$cfg" ]]; then
            cfg_to=$(jq -r '.pipeline.global_timeout_seconds // empty' "$cfg" 2>/dev/null || true)
        fi
        if [[ -n "$cfg_to" && "$cfg_to" != "null" ]]; then
            timeout_s="$cfg_to"
        else
            timeout_s="14400"
        fi
    fi
    # Sanitize: numeric only
    [[ "$timeout_s" =~ ^-?[0-9]+$ ]] || timeout_s=14400

    # max_cost_usd may be float — read directly via similar chain
    local env_val=""
    eval 'env_val="${SW_MAX_COST_USD:-}"' 2>/dev/null || true
    if [[ -n "$env_val" ]]; then
        max_usd="$env_val"
    else
        local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
        local cfg_val=""
        if [[ -f "$cfg" ]]; then
            cfg_val=$(jq -r '.pipeline.max_cost_usd // empty' "$cfg" 2>/dev/null || true)
        fi
        if [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
            max_usd="$cfg_val"
        else
            max_usd="50.0"
        fi
    fi
    max_cents=$(limits_usd_to_cents "$max_usd")

    # Treat negatives as disabled
    [[ "$timeout_s" -lt 0 ]] && timeout_s=0
    [[ "$max_cents" -lt 0 ]] && max_cents=0

    PIPELINE_LIMITS_TIMEOUT_S="$timeout_s"
    PIPELINE_LIMITS_MAX_CENTS="$max_cents"
    PIPELINE_LIMITS_START_EPOCH="${PIPELINE_START_EPOCH:-${PIPELINE_LIMITS_START_EPOCH:-$(now_epoch)}}"
    PIPELINE_LIMITS_RUN_ID="${ISSUE_NUMBER:-${PIPELINE_RUN_ID:-${GOAL:-unknown}}}"
    export PIPELINE_LIMITS_TIMEOUT_S PIPELINE_LIMITS_MAX_CENTS \
           PIPELINE_LIMITS_START_EPOCH PIPELINE_LIMITS_RUN_ID

    emit_event "limits.init" \
        "timeout_s=${PIPELINE_LIMITS_TIMEOUT_S}" \
        "max_cents=${PIPELINE_LIMITS_MAX_CENTS}" \
        "run_id=${PIPELINE_LIMITS_RUN_ID}"
    return 0
}

# ─── limits_pipeline_cost_cents ──────────────────────────────────────────────
# Sums cost entries (in cents) recorded since PIPELINE_LIMITS_START_EPOCH.
# Filters by issue when set. Fail-open: returns 0 on any error.
limits_pipeline_cost_cents() {
    local start_epoch="${PIPELINE_LIMITS_START_EPOCH:-0}"
    local run_id="${PIPELINE_LIMITS_RUN_ID:-}"

    [[ ! -f "$COST_FILE" ]] && { echo "0"; return 0; }

    local total_usd
    total_usd=$(jq -r --argjson since "$start_epoch" --arg issue "$run_id" '
        def matches(e):
          ((e.ts_epoch // 0) >= $since)
          and (($issue == "" or $issue == "unknown") or ((e.issue // "") == $issue));
        [ .entries[]? | select(matches(.)) | (.cost_usd // 0) ] | add // 0
    ' "$COST_FILE" 2>/dev/null) || total_usd=""

    if [[ -z "$total_usd" || "$total_usd" == "null" ]]; then
        emit_event "limits.cost_read_failed" "run_id=${run_id}" "file=${COST_FILE}"
        echo "0"
        return 0
    fi

    limits_usd_to_cents "$total_usd"
}

# ─── limits_check ────────────────────────────────────────────────────────────
# Returns 0 if both within bounds; 124 if timeout exceeded; 125 if cost exceeded.
# On breach, writes $ARTIFACTS_DIR/limits-breach.json atomically.
limits_check() {
    local stage_id="${1:-unknown}"
    local timeout_s="${PIPELINE_LIMITS_TIMEOUT_S:-0}"
    local max_cents="${PIPELINE_LIMITS_MAX_CENTS:-0}"
    local start="${PIPELINE_LIMITS_START_EPOCH:-$(now_epoch)}"
    local now elapsed
    now=$(now_epoch)
    elapsed=$(( now - start ))
    [[ "$elapsed" -lt 0 ]] && elapsed=0

    # Check timeout (fail-closed when configured)
    if [[ "$timeout_s" -gt 0 && "$elapsed" -ge "$timeout_s" ]]; then
        _limits_write_breach "timeout" "$stage_id" "$elapsed" "0"
        return $LIMITS_EXIT_TIMEOUT
    fi

    # Check cost (fail-open: cost read errors yield 0)
    if [[ "$max_cents" -gt 0 ]]; then
        local cost_cents
        cost_cents=$(limits_pipeline_cost_cents)
        [[ "$cost_cents" =~ ^[0-9]+$ ]] || cost_cents=0
        if [[ "$cost_cents" -ge "$max_cents" ]]; then
            _limits_write_breach "cost" "$stage_id" "$elapsed" "$cost_cents"
            return $LIMITS_EXIT_COST
        fi
    fi

    return $LIMITS_OK
}

_limits_write_breach() {
    local reason="$1" stage="$2" elapsed="$3" cost_cents="$4"
    local timeout_s="${PIPELINE_LIMITS_TIMEOUT_S:-0}"
    local max_cents="${PIPELINE_LIMITS_MAX_CENTS:-0}"
    mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
    local out="$ARTIFACTS_DIR/limits-breach.json"
    local tmp
    tmp=$(mktemp "${out}.tmp.XXXXXX" 2>/dev/null) || tmp="${out}.tmp.$$"
    jq -n \
        --arg reason "$reason" \
        --arg stage  "$stage" \
        --arg run_id "${PIPELINE_LIMITS_RUN_ID:-}" \
        --arg ts     "$(now_iso)" \
        --argjson elapsed_s   "$elapsed" \
        --argjson cost_cents  "$cost_cents" \
        --argjson timeout_s   "$timeout_s" \
        --argjson max_cents   "$max_cents" \
        '{reason:$reason, stage:$stage, run_id:$run_id, ts:$ts,
          elapsed_s:$elapsed_s, cost_cents:$cost_cents,
          limit_timeout_s:$timeout_s, limit_max_cents:$max_cents}' \
        > "$tmp" 2>/dev/null && mv "$tmp" "$out" || rm -f "$tmp"
}

# ─── limits_abort ────────────────────────────────────────────────────────────
# Saves a checkpoint, sets pipeline status to aborted_<reason>, emits event,
# prints a notification with elapsed/cost/limits/resume hint, returns the code.
limits_abort() {
    local code="${1:-1}" stage="${2:-unknown}"
    local reason="manual"
    case "$code" in
        $LIMITS_EXIT_TIMEOUT) reason="timeout" ;;
        $LIMITS_EXIT_COST)    reason="cost"    ;;
    esac

    local elapsed cost_cents
    elapsed=$(( $(now_epoch) - ${PIPELINE_LIMITS_START_EPOCH:-$(now_epoch)} ))
    [[ "$elapsed" -lt 0 ]] && elapsed=0
    cost_cents=$(limits_pipeline_cost_cents 2>/dev/null || echo 0)
    [[ "$cost_cents" =~ ^[0-9]+$ ]] || cost_cents=0

    # Save checkpoint (best-effort)
    if type checkpoint_save_context >/dev/null 2>&1; then
        checkpoint_save_context "$stage" 2>/dev/null || true
    fi

    # Set pipeline status
    if type update_status >/dev/null 2>&1; then
        update_status "aborted_${reason}" "$stage" 2>/dev/null || true
    else
        PIPELINE_STATUS="aborted_${reason}"
        export PIPELINE_STATUS
    fi

    emit_event "pipeline.aborted" \
        "issue=${ISSUE_NUMBER:-0}" \
        "stage=${stage}" \
        "reason=${reason}" \
        "elapsed_s=${elapsed}" \
        "cost_cents=${cost_cents}" \
        "exit_code=${code}"

    # Pretty-print notification
    local elapsed_h cost_usd timeout_h max_usd resume_cmd
    elapsed_h=$(awk -v s="$elapsed" 'BEGIN{ h=int(s/3600); m=int((s%3600)/60); printf "%dh %dm %ds", h, m, s%60 }')
    cost_usd=$(awk -v c="$cost_cents" 'BEGIN{ printf "%.2f", c/100 }')
    timeout_h=$(awk -v s="${PIPELINE_LIMITS_TIMEOUT_S:-0}" 'BEGIN{ if(s<=0){print "disabled"} else { printf "%dh %dm", int(s/3600), int((s%3600)/60) } }')
    max_usd=$(awk -v c="${PIPELINE_LIMITS_MAX_CENTS:-0}" 'BEGIN{ if(c<=0){print "disabled"} else { printf "$%.2f", c/100 } }')
    if [[ -n "${ISSUE_NUMBER:-}" && "${ISSUE_NUMBER:-0}" != "0" ]]; then
        resume_cmd="shipwright pipeline resume --issue ${ISSUE_NUMBER}"
    else
        resume_cmd="shipwright pipeline resume"
    fi

    error "Pipeline aborted: ${reason} limit exceeded at stage '${stage}'"
    info  "  elapsed: ${elapsed_h}   cost: \$${cost_usd}"
    info  "  limits:  timeout=${timeout_h}   max_cost=${max_usd}"
    info  "  resume:  ${resume_cmd}"

    return "$code"
}
