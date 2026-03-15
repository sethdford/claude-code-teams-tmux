#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  loop-model-selection.sh — Per-Iteration Adaptive Model Selection       ║
# ║                                                                         ║
# ║  Position-based model routing for the build loop:                       ║
# ║  - Early iterations use cheaper models (haiku) for scaffolding          ║
# ║  - Middle iterations use balanced models (sonnet) for development       ║
# ║  - Late iterations use powerful models (opus) for edge cases            ║
# ║  - Stuck detection overrides position routing when convergence stalls   ║
# ║                                                                         ║
# ║  Usage: Source from sw-loop.sh, call loop_model_select() before each    ║
# ║  Claude invocation in the build loop iteration                          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_LOOP_MODEL_SELECTION_LOADED:-}" ]] && return 0
_LOOP_MODEL_SELECTION_LOADED=1

# ─── Defaults ──────────────────────────────────────────────────────────────
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ─── Load helpers ──────────────────────────────────────────────────────────
if [[ "$(type -t info 2>/dev/null)" != "function" ]]; then
    info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
    success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
    warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
    error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
fi
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
    now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
    emit_event() {
        local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
        local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
        while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
        echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
    }
fi

# Read config helper (fallback if not loaded)
if [[ "$(type -t _config_get 2>/dev/null)" != "function" ]]; then
    _config_get() {
        local key="$1" default="${2:-}"
        local config_file=".claude/daemon-config.json"
        if [[ -f "$config_file" ]] && command -v jq >/dev/null 2>&1; then
            local val
            val=$(jq -r ".$key // empty" "$config_file" 2>/dev/null)
            echo "${val:-$default}"
        else
            echo "$default"
        fi
    }
fi

# ─── Per-Tier Cost Tracking Variables ──────────────────────────────────────
LOOP_COST_HAIKU_ITERATIONS=0
LOOP_COST_HAIKU_INPUT=0
LOOP_COST_HAIKU_OUTPUT=0
LOOP_COST_SONNET_ITERATIONS=0
LOOP_COST_SONNET_INPUT=0
LOOP_COST_SONNET_OUTPUT=0
LOOP_COST_OPUS_ITERATIONS=0
LOOP_COST_OPUS_INPUT=0
LOOP_COST_OPUS_OUTPUT=0

# ─── Stuck Detection State ────────────────────────────────────────────────
# Bash 3.2 compatible: use indexed array, not associative
STUCK_WINDOW=()
STUCK_WINDOW_SIZE=3
LOOP_MODEL_STRATEGY="default"
_LOOP_MODEL_ESCALATED=false

# ─── Initialize adaptive model selection for a loop run ───────────────────
loop_model_init() {
    local strategy="${1:-}"

    # Read from config if not provided
    if [[ -z "$strategy" ]]; then
        strategy=$(_config_get "loop.model_strategy" "default" 2>/dev/null || echo "default")
    fi

    # Validate strategy
    case "$strategy" in
        default|aggressive|conservative) ;;
        *) strategy="default" ;;
    esac

    LOOP_MODEL_STRATEGY="$strategy"
    STUCK_WINDOW=()
    _LOOP_MODEL_ESCALATED=false

    # Reset per-tier counters
    LOOP_COST_HAIKU_ITERATIONS=0
    LOOP_COST_HAIKU_INPUT=0
    LOOP_COST_HAIKU_OUTPUT=0
    LOOP_COST_SONNET_ITERATIONS=0
    LOOP_COST_SONNET_INPUT=0
    LOOP_COST_SONNET_OUTPUT=0
    LOOP_COST_OPUS_ITERATIONS=0
    LOOP_COST_OPUS_INPUT=0
    LOOP_COST_OPUS_OUTPUT=0
}

# ─── Pure position-based model routing ─────────────────────────────────────
# Returns model name based on iteration position within the loop.
# No side effects — purely deterministic.
loop_model_for_position() {
    local iteration="${1:-1}"
    local max_iterations="${2:-20}"
    local strategy="${3:-$LOOP_MODEL_STRATEGY}"

    # Sanitize inputs
    iteration=${iteration//[^0-9]/}
    max_iterations=${max_iterations//[^0-9]/}
    [[ -z "$iteration" || "$iteration" -lt 1 ]] && iteration=1
    [[ -z "$max_iterations" || "$max_iterations" -lt 1 ]] && max_iterations=20

    # Edge case: very short loops (<=3 iterations) — just use sonnet
    if [[ "$max_iterations" -le 3 ]]; then
        echo "sonnet"
        return 0
    fi

    local haiku_end sonnet_end

    case "$strategy" in
        aggressive)
            # 1 → haiku, 2..ceil(N*0.7) → sonnet, rest → opus
            haiku_end=1
            sonnet_end=$(awk -v n="$max_iterations" 'BEGIN{v=int(n*0.7); if(n*0.7>v) v++; print v}')
            ;;
        conservative)
            # 1-3 → haiku, 4..ceil(N*0.9) → sonnet, rest → opus
            haiku_end=3
            sonnet_end=$(awk -v n="$max_iterations" 'BEGIN{v=int(n*0.9); if(n*0.9>v) v++; print v}')
            ;;
        *)
            # default: 1-2 → haiku, 3..ceil(N*0.8) → sonnet, rest → opus
            haiku_end=2
            sonnet_end=$(awk -v n="$max_iterations" 'BEGIN{v=int(n*0.8); if(n*0.8>v) v++; print v}')
            ;;
    esac

    if [[ "$iteration" -le "$haiku_end" ]]; then
        echo "haiku"
    elif [[ "$iteration" -le "$sonnet_end" ]]; then
        echo "sonnet"
    else
        echo "opus"
    fi
}

# ─── Stuck detection via sliding window ────────────────────────────────────
# Appends convergence score to window, returns exit 0 if stuck (no progress).
# "Stuck" = all scores in the window are within 5 points of each other.
loop_model_detect_stuck() {
    local conv_score="${1:-50}"

    # Sanitize
    conv_score=${conv_score//[^0-9]/}
    [[ -z "$conv_score" ]] && conv_score=50

    # Append to window
    STUCK_WINDOW=("${STUCK_WINDOW[@]}" "$conv_score")

    # Trim window to size
    while [[ ${#STUCK_WINDOW[@]} -gt $STUCK_WINDOW_SIZE ]]; do
        STUCK_WINDOW=("${STUCK_WINDOW[@]:1}")
    done

    # Need full window to detect stuck
    if [[ ${#STUCK_WINDOW[@]} -lt $STUCK_WINDOW_SIZE ]]; then
        return 1  # not stuck (not enough data)
    fi

    # Check if all scores are within 5 points of each other
    local min=999 max=0
    local score
    for score in "${STUCK_WINDOW[@]}"; do
        [[ "$score" -lt "$min" ]] && min=$score
        [[ "$score" -gt "$max" ]] && max=$score
    done

    local spread=$(( max - min ))
    if [[ "$spread" -le 5 ]]; then
        return 0  # stuck
    fi

    return 1  # not stuck
}

# ─── Main selection function ───────────────────────────────────────────────
# Combines position routing with stuck detection override.
# Returns model name on stdout.
loop_model_select() {
    local iteration="${1:-1}"
    local max_iterations="${2:-20}"
    local convergence_score="${3:-50}"
    local test_passed="${4:-unknown}"
    local error_count="${5:-0}"
    local current_model="${6:-sonnet}"

    # Get position-based baseline
    local position_model
    position_model=$(loop_model_for_position "$iteration" "$max_iterations" "$LOOP_MODEL_STRATEGY") || position_model="$current_model"

    # Check for stuck condition — override with escalation
    local selected_model="$position_model"
    local escalation_reason=""

    if loop_model_detect_stuck "$convergence_score"; then
        # Stuck detected — escalate one tier above position-based choice
        case "$position_model" in
            haiku)  selected_model="sonnet"; escalation_reason="stuck_convergence" ;;
            sonnet) selected_model="opus";   escalation_reason="stuck_convergence" ;;
            opus)   selected_model="opus";   escalation_reason="" ;;  # already at max
        esac
    fi

    # Additional escalation: tests failing with errors
    error_count=${error_count//[^0-9]/}
    error_count=${error_count:-0}
    if [[ "$test_passed" == "false" && "$error_count" -ge 2 ]]; then
        # Escalate if not already at a higher tier
        case "$selected_model" in
            haiku)  selected_model="sonnet"; escalation_reason="repeated_errors" ;;
            sonnet)
                if [[ "$error_count" -ge 4 ]]; then
                    selected_model="opus"; escalation_reason="persistent_errors"
                fi
                ;;
        esac
    fi

    # Emit events
    if type emit_event >/dev/null 2>&1; then
        emit_event "loop_model_selected" \
            "iteration=$iteration" \
            "max=$max_iterations" \
            "position_model=$position_model" \
            "selected_model=$selected_model" \
            "strategy=$LOOP_MODEL_STRATEGY" \
            "convergence=$convergence_score"

        if [[ -n "$escalation_reason" ]]; then
            _LOOP_MODEL_ESCALATED=true
            emit_event "loop_model_escalated" \
                "iteration=$iteration" \
                "from=$position_model" \
                "to=$selected_model" \
                "reason=$escalation_reason" \
                "convergence=$convergence_score" \
                "error_count=$error_count"
        fi
    fi

    echo "$selected_model"
}

# ─── Per-tier cost tracking ────────────────────────────────────────────────
loop_model_track_cost() {
    local model="${1:-sonnet}"
    local input_tokens="${2:-0}"
    local output_tokens="${3:-0}"

    # Sanitize
    input_tokens=${input_tokens//[^0-9]/}
    output_tokens=${output_tokens//[^0-9]/}
    input_tokens=${input_tokens:-0}
    output_tokens=${output_tokens:-0}

    case "$model" in
        *haiku*)
            LOOP_COST_HAIKU_ITERATIONS=$(( LOOP_COST_HAIKU_ITERATIONS + 1 ))
            LOOP_COST_HAIKU_INPUT=$(( LOOP_COST_HAIKU_INPUT + input_tokens ))
            LOOP_COST_HAIKU_OUTPUT=$(( LOOP_COST_HAIKU_OUTPUT + output_tokens ))
            ;;
        *opus*)
            LOOP_COST_OPUS_ITERATIONS=$(( LOOP_COST_OPUS_ITERATIONS + 1 ))
            LOOP_COST_OPUS_INPUT=$(( LOOP_COST_OPUS_INPUT + input_tokens ))
            LOOP_COST_OPUS_OUTPUT=$(( LOOP_COST_OPUS_OUTPUT + output_tokens ))
            ;;
        *)
            LOOP_COST_SONNET_ITERATIONS=$(( LOOP_COST_SONNET_ITERATIONS + 1 ))
            LOOP_COST_SONNET_INPUT=$(( LOOP_COST_SONNET_INPUT + input_tokens ))
            LOOP_COST_SONNET_OUTPUT=$(( LOOP_COST_SONNET_OUTPUT + output_tokens ))
            ;;
    esac

    # Write JSON cost file atomically (if jq available)
    if command -v jq >/dev/null 2>&1; then
        mkdir -p "$ARTIFACTS_DIR"
        local cost_file="${ARTIFACTS_DIR}/loop-model-costs.json"
        local haiku_cost sonnet_cost opus_cost
        haiku_cost=$(awk -v i="$LOOP_COST_HAIKU_INPUT" -v o="$LOOP_COST_HAIKU_OUTPUT" \
            'BEGIN{printf "%.6f", (i * 0.25 + o * 1.25) / 1000000}')
        sonnet_cost=$(awk -v i="$LOOP_COST_SONNET_INPUT" -v o="$LOOP_COST_SONNET_OUTPUT" \
            'BEGIN{printf "%.6f", (i * 3 + o * 15) / 1000000}')
        opus_cost=$(awk -v i="$LOOP_COST_OPUS_INPUT" -v o="$LOOP_COST_OPUS_OUTPUT" \
            'BEGIN{printf "%.6f", (i * 15 + o * 75) / 1000000}')

        local ts
        ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        jq -n \
            --arg ts "$ts" \
            --argjson hi "$LOOP_COST_HAIKU_ITERATIONS" \
            --argjson hin "$LOOP_COST_HAIKU_INPUT" \
            --argjson hout "$LOOP_COST_HAIKU_OUTPUT" \
            --arg hcost "$haiku_cost" \
            --argjson si "$LOOP_COST_SONNET_ITERATIONS" \
            --argjson sin "$LOOP_COST_SONNET_INPUT" \
            --argjson sout "$LOOP_COST_SONNET_OUTPUT" \
            --arg scost "$sonnet_cost" \
            --argjson oi "$LOOP_COST_OPUS_ITERATIONS" \
            --argjson oin "$LOOP_COST_OPUS_INPUT" \
            --argjson oout "$LOOP_COST_OPUS_OUTPUT" \
            --arg ocost "$opus_cost" \
            '{
                ts: $ts,
                haiku: {iterations: $hi, input_tokens: $hin, output_tokens: $hout, cost_usd: ($hcost|tonumber)},
                sonnet: {iterations: $si, input_tokens: $sin, output_tokens: $sout, cost_usd: ($scost|tonumber)},
                opus: {iterations: $oi, input_tokens: $oin, output_tokens: $oout, cost_usd: ($ocost|tonumber)}
            }' > "${cost_file}.tmp.$$" 2>/dev/null && mv "${cost_file}.tmp.$$" "$cost_file" 2>/dev/null || true
    fi
}

# ─── Summary: print per-tier cost breakdown ────────────────────────────────
loop_model_summary() {
    local total_iterations=$(( LOOP_COST_HAIKU_ITERATIONS + LOOP_COST_SONNET_ITERATIONS + LOOP_COST_OPUS_ITERATIONS ))

    # Skip if no tracking data
    [[ "$total_iterations" -eq 0 ]] && return 0

    local haiku_cost sonnet_cost opus_cost total_cost
    haiku_cost=$(awk -v i="$LOOP_COST_HAIKU_INPUT" -v o="$LOOP_COST_HAIKU_OUTPUT" \
        'BEGIN{printf "%.4f", (i * 0.25 + o * 1.25) / 1000000}')
    sonnet_cost=$(awk -v i="$LOOP_COST_SONNET_INPUT" -v o="$LOOP_COST_SONNET_OUTPUT" \
        'BEGIN{printf "%.4f", (i * 3 + o * 15) / 1000000}')
    opus_cost=$(awk -v i="$LOOP_COST_OPUS_INPUT" -v o="$LOOP_COST_OPUS_OUTPUT" \
        'BEGIN{printf "%.4f", (i * 15 + o * 75) / 1000000}')
    total_cost=$(awk -v h="$haiku_cost" -v s="$sonnet_cost" -v o="$opus_cost" \
        'BEGIN{printf "%.4f", h + s + o}')

    echo -e "  \033[1mModel Usage:\033[0m"
    [[ "$LOOP_COST_HAIKU_ITERATIONS" -gt 0 ]] && \
        echo -e "    haiku:  ${LOOP_COST_HAIKU_ITERATIONS} iters, \$${haiku_cost}"
    [[ "$LOOP_COST_SONNET_ITERATIONS" -gt 0 ]] && \
        echo -e "    sonnet: ${LOOP_COST_SONNET_ITERATIONS} iters, \$${sonnet_cost}"
    [[ "$LOOP_COST_OPUS_ITERATIONS" -gt 0 ]] && \
        echo -e "    opus:   ${LOOP_COST_OPUS_ITERATIONS} iters, \$${opus_cost}"
    echo -e "    total:  ${total_iterations} iters, \$${total_cost}"

    # Emit summary event
    if type emit_event >/dev/null 2>&1; then
        emit_event "loop_model_cost_summary" \
            "haiku_iters=$LOOP_COST_HAIKU_ITERATIONS" \
            "sonnet_iters=$LOOP_COST_SONNET_ITERATIONS" \
            "opus_iters=$LOOP_COST_OPUS_ITERATIONS" \
            "total_cost_usd=$total_cost" \
            "strategy=$LOOP_MODEL_STRATEGY" \
            "escalated=$_LOOP_MODEL_ESCALATED"
    fi
}
