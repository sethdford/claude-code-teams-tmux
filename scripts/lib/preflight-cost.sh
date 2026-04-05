#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  preflight-cost.sh — Pre-Flight Cost & Success Probability Estimator    ║
# ║  Estimates pipeline cost and success probability before execution.      ║
# ║  Advisory only — never blocks a pipeline that would otherwise succeed.  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard
[[ -n "${_MODULE_PREFLIGHT_COST_LOADED:-}" ]] && return 0; _MODULE_PREFLIGHT_COST_LOADED=1

VERSION="3.3.0"

# ─── Module State ──────────────────────────────────────────────────────────
PREFLIGHT_COST_ENABLED="false"
_PREFLIGHT_COST_MAX_USD=""
_PREFLIGHT_COST_MIN_SUCCESS=""
_PREFLIGHT_COST_WARN_USD=""
_PREFLIGHT_COST_WARN_SUCCESS=""
_PREFLIGHT_COST_INTERACTIVE=""
_PREFLIGHT_COST_LOG=""
_PREFLIGHT_PREDICTIONS_FILE="${HOME}/.shipwright/cost-predictions.jsonl"

# ─── Helpers (fallbacks if not loaded) ──────────────────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { :; }

# ─── preflight_cost_init ───────────────────────────────────────────────────
# Loads cost_policy from policy.json, sets module globals.
# Returns 0 always (disabled is not an error).
preflight_cost_init() {
    local policy_file="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/config/policy.json"

    if [[ ! -f "$policy_file" ]]; then
        PREFLIGHT_COST_ENABLED="false"
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        PREFLIGHT_COST_ENABLED="false"
        return 0
    fi

    # Read cost_policy block
    local cost_policy=""
    cost_policy=$(jq -r '.cost_policy // empty' "$policy_file" 2>/dev/null || true)
    if [[ -z "$cost_policy" || "$cost_policy" == "null" ]]; then
        PREFLIGHT_COST_ENABLED="false"
        return 0
    fi

    local enabled=""
    enabled=$(echo "$cost_policy" | jq -r '.enabled // false' 2>/dev/null || echo "false")
    if [[ "$enabled" != "true" ]]; then
        PREFLIGHT_COST_ENABLED="false"
        return 0
    fi

    PREFLIGHT_COST_ENABLED="true"
    _PREFLIGHT_COST_MAX_USD=$(echo "$cost_policy" | jq -r '.max_cost_usd // 25' 2>/dev/null || echo "25")
    _PREFLIGHT_COST_MIN_SUCCESS=$(echo "$cost_policy" | jq -r '.min_success_probability // 30' 2>/dev/null || echo "30")
    _PREFLIGHT_COST_WARN_USD=$(echo "$cost_policy" | jq -r '.warn_cost_usd // 15' 2>/dev/null || echo "15")
    _PREFLIGHT_COST_WARN_SUCCESS=$(echo "$cost_policy" | jq -r '.warn_success_probability // 50' 2>/dev/null || echo "50")
    _PREFLIGHT_COST_INTERACTIVE=$(echo "$cost_policy" | jq -r '.interactive_prompt // true' 2>/dev/null || echo "true")
    _PREFLIGHT_COST_LOG=$(echo "$cost_policy" | jq -r '.log_predictions // true' 2>/dev/null || echo "true")

    mkdir -p "$(dirname "$_PREFLIGHT_PREDICTIONS_FILE")" 2>/dev/null || true
    return 0
}

# ─── preflight_cost_estimate ───────────────────────────────────────────────
# Input: JSON string with {title, body, labels[], number}
# Output to stdout: CostEstimate JSON
# Returns: 0 on success, 1 if estimate unavailable
preflight_cost_estimate() {
    local issue_json="${1:-}"

    if [[ "$PREFLIGHT_COST_ENABLED" != "true" ]]; then
        return 1
    fi

    if [[ -z "$issue_json" ]]; then
        return 1
    fi

    # Try intelligence-based estimation first
    local estimate=""
    estimate=$(_preflight_intelligence_estimate "$issue_json" 2>/dev/null || true)

    if [[ -n "$estimate" ]]; then
        echo "$estimate"
        _preflight_log_prediction "$issue_json" "$estimate" 2>/dev/null || true
        return 0
    fi

    # Fallback: heuristic estimation
    estimate=$(_preflight_heuristic_estimate "$issue_json" 2>/dev/null || true)

    if [[ -n "$estimate" ]]; then
        echo "$estimate"
        _preflight_log_prediction "$issue_json" "$estimate" 2>/dev/null || true
        return 0
    fi

    return 1
}

# ─── preflight_cost_gate ──────────────────────────────────────────────────
# Input: JSON from preflight_cost_estimate
# Returns: 0=proceed, 1=blocked, 2=warn
preflight_cost_gate() {
    local estimate_json="${1:-}"

    if [[ "$PREFLIGHT_COST_ENABLED" != "true" ]]; then
        return 0
    fi

    if [[ -z "$estimate_json" ]]; then
        return 0
    fi

    local est_cost="" est_success=""
    est_cost=$(echo "$estimate_json" | jq -r '.estimated_cost_usd // 0' 2>/dev/null || echo "0")
    est_success=$(echo "$estimate_json" | jq -r '.success_probability // 100' 2>/dev/null || echo "100")

    # Check hard block thresholds
    if awk -v c="$est_cost" -v m="$_PREFLIGHT_COST_MAX_USD" 'BEGIN { exit !(c > m) }' 2>/dev/null; then
        echo "Estimated cost \$${est_cost} exceeds maximum \$${_PREFLIGHT_COST_MAX_USD}"
        return 1
    fi

    if awk -v s="$est_success" -v m="$_PREFLIGHT_COST_MIN_SUCCESS" 'BEGIN { exit !(s < m) }' 2>/dev/null; then
        echo "Success probability ${est_success}% below minimum ${_PREFLIGHT_COST_MIN_SUCCESS}%"
        return 1
    fi

    # Check warning thresholds
    if awk -v c="$est_cost" -v w="$_PREFLIGHT_COST_WARN_USD" 'BEGIN { exit !(c > w) }' 2>/dev/null; then
        echo "Estimated cost \$${est_cost} approaching limit (warn: \$${_PREFLIGHT_COST_WARN_USD})"
        return 2
    fi

    if awk -v s="$est_success" -v w="$_PREFLIGHT_COST_WARN_SUCCESS" 'BEGIN { exit !(s < w) }' 2>/dev/null; then
        echo "Success probability ${est_success}% is low (warn: ${_PREFLIGHT_COST_WARN_SUCCESS}%)"
        return 2
    fi

    return 0
}

# ─── preflight_cost_prompt ────────────────────────────────────────────────
# Interactive mode. Prints estimate summary, asks Y/n/adjust.
# Returns: 0=approved, 1=declined
preflight_cost_prompt() {
    local estimate_json="${1:-}"

    if [[ -z "$estimate_json" ]]; then
        return 0
    fi

    # Auto-approve if not a TTY
    if [[ ! -t 0 ]]; then
        return 0
    fi

    if [[ "$_PREFLIGHT_COST_INTERACTIVE" != "true" ]]; then
        return 0
    fi

    local est_cost est_iters est_success est_confidence est_template model_used
    est_cost=$(echo "$estimate_json" | jq -r '.estimated_cost_usd // "?"' 2>/dev/null || echo "?")
    est_iters=$(echo "$estimate_json" | jq -r '.estimated_iterations // "?"' 2>/dev/null || echo "?")
    est_success=$(echo "$estimate_json" | jq -r '.success_probability // "?"' 2>/dev/null || echo "?")
    est_confidence=$(echo "$estimate_json" | jq -r '.confidence // "?"' 2>/dev/null || echo "?")
    est_template=$(echo "$estimate_json" | jq -r '.recommended_template // "standard"' 2>/dev/null || echo "standard")
    model_used=$(echo "$estimate_json" | jq -r '.model_used // "unknown"' 2>/dev/null || echo "unknown")

    # Estimate duration: ~25min per iteration
    local est_duration="?"
    if [[ "$est_iters" =~ ^[0-9]+$ ]]; then
        est_duration=$(( est_iters * 25 ))
    fi

    echo ""
    echo -e "\033[38;2;0;212;255m\033[1m┌─── Pre-Flight Estimate ───────────────────────────┐\033[0m"
    printf "\033[38;2;0;212;255m│\033[0m  %-22s %s\n" "Estimated cost:" "\$${est_cost}"
    printf "\033[38;2;0;212;255m│\033[0m  %-22s %s\n" "Success probability:" "${est_success}%"
    printf "\033[38;2;0;212;255m│\033[0m  %-22s %s\n" "Est. iterations:" "${est_iters}"
    printf "\033[38;2;0;212;255m│\033[0m  %-22s %s\n" "Est. duration:" "~${est_duration}min"
    printf "\033[38;2;0;212;255m│\033[0m  %-22s %s\n" "Confidence:" "${est_confidence}%"
    printf "\033[38;2;0;212;255m│\033[0m  %-22s %s\n" "Template:" "${est_template}"
    printf "\033[38;2;0;212;255m│\033[0m  %-22s %s\n" "Model:" "${model_used}"
    echo -e "\033[38;2;0;212;255m\033[1m└───────────────────────────────────────────────────┘\033[0m"
    echo ""

    local answer=""
    read -r -p "Proceed? [Y/n/adjust] " answer < /dev/tty 2>/dev/null || answer="y"

    case "$answer" in
        n|N|no|No|NO)
            info "Pipeline cancelled by user"
            return 1
            ;;
        a|A|adjust|Adjust|ADJUST)
            echo ""
            echo -e "  Available templates: fast, standard, full, hotfix, cost-aware"
            local new_template=""
            read -r -p "  Template [${est_template}]: " new_template < /dev/tty 2>/dev/null || new_template=""
            if [[ -n "$new_template" ]]; then
                PIPELINE_NAME="$new_template"
                info "Template adjusted to: $new_template"
            fi
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# ─── preflight_cost_log_outcome ───────────────────────────────────────────
# Backfills the prediction record with actuals after pipeline completes.
# Returns 0 always (logging failure is non-fatal).
preflight_cost_log_outcome() {
    local issue_num="${1:-}"
    local actual_cost="${2:-0}"
    local actual_iterations="${3:-0}"
    local status="${4:-unknown}"

    if [[ "$_PREFLIGHT_COST_LOG" != "true" ]]; then
        return 0
    fi

    if [[ -z "$issue_num" ]]; then
        return 0
    fi

    local outcome_json=""
    outcome_json=$(jq -n \
        --arg issue "$issue_num" \
        --arg actual_cost "$actual_cost" \
        --arg actual_iters "$actual_iterations" \
        --arg status "$status" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            type: "outcome",
            issue_number: $issue,
            actual_cost_usd: ($actual_cost | tonumber),
            actual_iterations: ($actual_iters | tonumber),
            status: $status,
            recorded_at: $ts
        }' 2>/dev/null) || return 0

    _preflight_atomic_append "$outcome_json"
    return 0
}

# ─── Private: Intelligence-based estimate ─────────────────────────────────
_preflight_intelligence_estimate() {
    local issue_json="${1:-}"

    # Check if intelligence functions are available
    if ! type intelligence_analyze_issue >/dev/null 2>&1; then
        return 1
    fi
    if ! type intelligence_predict_cost >/dev/null 2>&1; then
        return 1
    fi

    local analysis=""
    analysis=$(intelligence_analyze_issue "$issue_json" 2>/dev/null || true)
    if [[ -z "$analysis" ]]; then
        return 1
    fi

    local prediction=""
    prediction=$(intelligence_predict_cost "$analysis" 2>/dev/null || true)
    if [[ -z "$prediction" ]]; then
        return 1
    fi

    # Extract and normalize fields
    local est_cost est_iters confidence
    est_cost=$(echo "$prediction" | jq -r '.estimated_cost_usd // empty' 2>/dev/null || true)
    est_iters=$(echo "$prediction" | jq -r '.estimated_iterations // empty' 2>/dev/null || true)
    confidence=$(echo "$prediction" | jq -r '.confidence // 60' 2>/dev/null || echo "60")

    if [[ -z "$est_cost" || -z "$est_iters" ]]; then
        return 1
    fi

    # Calculate success probability from intelligence data
    local complexity=""
    complexity=$(echo "$analysis" | jq -r '.complexity // 50' 2>/dev/null || echo "50")
    local success_prob=""
    success_prob=$(awk -v c="$complexity" 'BEGIN { p = 95 - (c * 0.5); if (p < 10) p = 10; if (p > 95) p = 95; printf "%.0f", p }')

    # Determine recommended template
    local template="standard"
    if awk -v c="$est_cost" 'BEGIN { exit !(c < 2) }' 2>/dev/null; then
        template="fast"
    elif awk -v c="$est_cost" 'BEGIN { exit !(c > 10) }' 2>/dev/null; then
        template="full"
    fi

    jq -n \
        --argjson cost "$est_cost" \
        --argjson iters "$est_iters" \
        --argjson success "$success_prob" \
        --argjson conf "$confidence" \
        --arg template "$template" \
        '{
            estimated_cost_usd: $cost,
            estimated_iterations: $iters,
            success_probability: $success,
            confidence: $conf,
            signals_triggered: [],
            recommended_template: $template,
            model_used: "intelligence"
        }'
}

# ─── Private: Heuristic estimate ──────────────────────────────────────────
_preflight_heuristic_estimate() {
    local issue_json="${1:-}"

    local title body label_count labels_raw number
    title=$(echo "$issue_json" | jq -r '.title // ""' 2>/dev/null || echo "")
    body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null || echo "")
    label_count=$(echo "$issue_json" | jq -r '.labels | length // 0' 2>/dev/null || echo "0")
    labels_raw=$(echo "$issue_json" | jq -r '.labels[]? | if type == "object" then .name else . end' 2>/dev/null || echo "")
    number=$(echo "$issue_json" | jq -r '.number // 0' 2>/dev/null || echo "0")

    local baseline=2
    local signals_count=0
    local signals_list=""

    # Signal 1: Vague body (< 100 chars)
    local body_len=${#body}
    if [[ "$body_len" -lt 100 ]]; then
        signals_count=$((signals_count + 1))
        signals_list="${signals_list:+$signals_list,}\"vague_body\""
    fi

    # Signal 2: Many labels (> 3)
    if [[ "$label_count" -gt 3 ]]; then
        signals_count=$((signals_count + 1))
        signals_list="${signals_list:+$signals_list,}\"many_labels\""
    fi

    # Signal 3: Complex or epic label
    if echo "$labels_raw" | grep -qiE "complex|epic"; then
        signals_count=$((signals_count + 1))
        signals_list="${signals_list:+$signals_list,}\"complexity_label\""
    fi

    # Signal 4: Check intelligence cache for file complexity
    local cache_file="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude/intelligence-cache.json"
    local estimated_files=0
    if [[ -f "$cache_file" ]]; then
        estimated_files=$(jq -r '.file_count // 0' "$cache_file" 2>/dev/null || echo "0")
        if [[ "$estimated_files" -gt 200 ]]; then
            signals_count=$((signals_count + 1))
            signals_list="${signals_list:+$signals_list,}\"large_codebase\""
        fi
    fi

    # Signal 5: Check recent pipeline failures
    local recent_failures=0
    local events_file="${HOME}/.shipwright/events.jsonl"
    if [[ -f "$events_file" ]]; then
        recent_failures=$(tail -100 "$events_file" 2>/dev/null | grep -c '"pipeline.failed"' || true)
        recent_failures=${recent_failures:-0}
        if [[ "$recent_failures" -gt 3 ]]; then
            signals_count=$((signals_count + 1))
            signals_list="${signals_list:+$signals_list,}\"unstable_repo\""
        fi
    fi

    # Signal 6: Check memory for similar issue iteration counts
    local memory_high_iters="false"
    local mem_dir="${HOME}/.shipwright/memory"
    if [[ -d "$mem_dir" ]]; then
        local success_file=""
        success_file=$(find "$mem_dir" -name "success-patterns.json" -maxdepth 3 2>/dev/null | head -1 || true)
        if [[ -n "$success_file" && -f "$success_file" ]]; then
            local avg_iters=""
            avg_iters=$(jq -r '[.[].iterations // 2] | add / length // 2' "$success_file" 2>/dev/null || echo "2")
            if awk -v a="$avg_iters" 'BEGIN { exit !(a > 3) }' 2>/dev/null; then
                memory_high_iters="true"
                signals_count=$((signals_count + 1))
                signals_list="${signals_list:+$signals_list,}\"high_historical_iterations\""
            fi
        fi
    fi

    # Signal 7: Long title (may indicate multi-part requirement)
    local title_len=${#title}
    if [[ "$title_len" -gt 80 ]]; then
        signals_count=$((signals_count + 1))
        signals_list="${signals_list:+$signals_list,}\"long_title\""
    fi

    # Signal 8: Body contains multiple code blocks (complex spec)
    local code_block_count=0
    code_block_count=$(echo "$body" | grep -c '```' || true)
    code_block_count=${code_block_count:-0}
    if [[ "$code_block_count" -gt 4 ]]; then
        signals_count=$((signals_count + 1))
        signals_list="${signals_list:+$signals_list,}\"complex_spec\""
    fi

    # Calculate iterations with multiplier
    local multiplier="1.0"
    if [[ "$signals_count" -le 0 ]]; then
        multiplier="0.8"
    elif [[ "$signals_count" -ge 3 ]]; then
        multiplier="1.5"
    fi

    local raw_iters=""
    raw_iters=$(awk -v b="$baseline" -v s="$signals_count" -v m="$multiplier" \
        'BEGIN { v = (b + s) * m; if (v < 1) v = 1; if (v > 8) v = 8; printf "%.0f", v }')

    # Cost per iteration based on default model
    local per_iter_cost=5.0  # opus default
    local default_model=""
    if type _smart_model >/dev/null 2>&1; then
        default_model=$(_smart_model "default" "opus" 2>/dev/null || echo "opus")
    else
        default_model="${SW_MODEL_DEFAULT:-opus}"
    fi
    case "$default_model" in
        haiku*)  per_iter_cost=0.20 ;;
        sonnet*) per_iter_cost=1.50 ;;
        opus*)   per_iter_cost=5.00 ;;
        *)       per_iter_cost=3.00 ;;
    esac

    local est_cost=""
    est_cost=$(awk -v i="$raw_iters" -v c="$per_iter_cost" 'BEGIN { printf "%.2f", i * c }')

    # Success probability: higher signals = lower probability
    local success_prob=""
    success_prob=$(awk -v s="$signals_count" 'BEGIN { p = 95 - (s * 12); if (p < 10) p = 10; printf "%.0f", p }')

    # Confidence based on available data sources
    local data_sources=1  # always have the issue itself
    [[ -f "$cache_file" ]] && data_sources=$((data_sources + 1))
    [[ -f "$events_file" ]] && data_sources=$((data_sources + 1))
    [[ "$memory_high_iters" == "true" || -d "$mem_dir" ]] && data_sources=$((data_sources + 1))
    local confidence=""
    confidence=$(awk -v d="$data_sources" 'BEGIN { c = 40 + (d * 10); if (c > 80) c = 80; printf "%.0f", c }')

    # Recommended template
    local template="standard"
    if [[ "$signals_count" -le 1 ]] && awk -v c="$est_cost" 'BEGIN { exit !(c < 3) }' 2>/dev/null; then
        template="fast"
    elif [[ "$signals_count" -ge 4 ]] || awk -v c="$est_cost" 'BEGIN { exit !(c > 15) }' 2>/dev/null; then
        template="full"
    fi

    jq -n \
        --argjson cost "$est_cost" \
        --argjson iters "$raw_iters" \
        --argjson success "$success_prob" \
        --argjson conf "$confidence" \
        --argjson signals "[$signals_list]" \
        --arg template "$template" \
        '{
            estimated_cost_usd: $cost,
            estimated_iterations: $iters,
            success_probability: $success,
            confidence: $conf,
            signals_triggered: $signals,
            recommended_template: $template,
            model_used: "heuristic"
        }'
}

# ─── Private: Log prediction ─────────────────────────────────────────────
_preflight_log_prediction() {
    local issue_json="${1:-}"
    local estimate_json="${2:-}"

    if [[ "$_PREFLIGHT_COST_LOG" != "true" ]]; then
        return 0
    fi

    local issue_num=""
    issue_num=$(echo "$issue_json" | jq -r '.number // 0' 2>/dev/null || echo "0")

    local prediction_json=""
    prediction_json=$(jq -n \
        --arg issue "$issue_num" \
        --argjson estimate "$estimate_json" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
            type: "prediction",
            issue_number: $issue,
            estimate: $estimate,
            predicted_at: $ts
        }' 2>/dev/null) || return 0

    _preflight_atomic_append "$prediction_json"
    return 0
}

# ─── Private: Atomic JSONL append ─────────────────────────────────────────
_preflight_atomic_append() {
    local json_line="${1:-}"
    [[ -z "$json_line" ]] && return 0

    mkdir -p "$(dirname "$_PREFLIGHT_PREDICTIONS_FILE")" 2>/dev/null || true

    # Try flock for atomic append, fall back to direct append
    if command -v flock >/dev/null 2>&1; then
        (
            flock -w 5 200 2>/dev/null || true
            echo "$json_line" >> "$_PREFLIGHT_PREDICTIONS_FILE"
        ) 200>"${_PREFLIGHT_PREDICTIONS_FILE}.lock" 2>/dev/null || {
            echo "$json_line" >> "$_PREFLIGHT_PREDICTIONS_FILE" 2>/dev/null || true
        }
    else
        # No flock available (e.g., some macOS versions) — direct append
        echo "$json_line" >> "$_PREFLIGHT_PREDICTIONS_FILE" 2>/dev/null || true
    fi
}
