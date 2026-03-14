#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Loop Token Tracking — accumulate costs, estimate iterations, apply budgets
# ║                                                                         ║
# ║  This module handles all token counting, cost accumulation, adaptive       ║
# ║  model selection, and budget gating for the loop.                         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# Module guard — prevent double-sourcing
[[ -z "${_LOOP_TOKENS_SH_LOADED:-}" ]] || return 0
readonly _LOOP_TOKENS_SH_LOADED=1

# ─── Token Tracking Variables (exported by caller) ───────────────────────────
# LOOP_INPUT_TOKENS
# LOOP_OUTPUT_TOKENS
# LOOP_COST_MILLICENTS

# ─── Select Adaptive Model ──────────────────────────────────────────────────
# Queries learned model routing or intelligence recommendations.
select_adaptive_model() {
    local role="${1:-build}"
    local default_model="${2:-opus}"
    # If user explicitly set --model, respect it
    if [[ "$default_model" != "${SW_MODEL:-opus}" ]]; then
        echo "$default_model"
        return 0
    fi
    # Read learned model routing
    local _routing_file="${HOME}/.shipwright/optimization/model-routing.json"
    if [[ -f "$_routing_file" ]] && command -v jq >/dev/null 2>&1; then
        local _routed_model
        _routed_model=$(jq -r --arg r "$role" '.routes[$r].model // ""' "$_routing_file" 2>/dev/null) || true
        if [[ -n "${_routed_model:-}" && "${_routed_model:-}" != "null" ]]; then
            echo "${_routed_model}"
            return 0
        fi
    fi

    # Try intelligence-based recommendation
    if type intelligence_recommend_model >/dev/null 2>&1; then
        local rec
        rec=$(intelligence_recommend_model "$role" "${COMPLEXITY:-5}" "${BUDGET:-0}" 2>/dev/null || echo "")
        if [[ -n "$rec" ]]; then
            local recommended
            recommended=$(echo "$rec" | jq -r '.model // ""' 2>/dev/null || echo "")
            if [[ -n "$recommended" && "$recommended" != "null" ]]; then
                echo "$recommended"
                return 0
            fi
        fi
    fi
    echo "$default_model"
}

# ─── Select Audit Model ────────────────────────────────────────────────────
# Uses haiku if success rate is high enough, else sonnet.
select_audit_model() {
    local default_model="haiku"
    local opt_file="$HOME/.shipwright/optimization/audit-tuning.json"
    if [[ -f "$opt_file" ]] && command -v jq >/dev/null 2>&1; then
        local success_rate
        success_rate=$(jq -r '.haiku_success_rate // 100' "$opt_file" 2>/dev/null || echo "100")
        if [[ "${success_rate%%.*}" -lt 90 ]]; then
            echo "sonnet"
            return 0
        fi
    fi
    echo "$default_model"
}

# ─── Accumulate Loop Tokens ────────────────────────────────────────────────
# Parse token counts from Claude CLI JSON output and accumulate running totals.
# With --output-format json, the output is a JSON array containing a "result"
# object with usage.input_tokens, usage.output_tokens, and total_cost_usd.
accumulate_loop_tokens() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return 0

    # If jq is available and the file looks like JSON, parse structured output
    if command -v jq >/dev/null 2>&1 && head -c1 "$log_file" 2>/dev/null | grep -q '\['; then
        local input_tok output_tok cache_read cache_create cost_usd
        # The result object is the last element in the JSON array
        input_tok=$(jq -r '.[-1].usage.input_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        output_tok=$(jq -r '.[-1].usage.output_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        cache_read=$(jq -r '.[-1].usage.cache_read_input_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        cache_create=$(jq -r '.[-1].usage.cache_creation_input_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        cost_usd=$(jq -r '.[-1].total_cost_usd // 0' "$log_file" 2>/dev/null || echo "0")

        LOOP_INPUT_TOKENS=$(( LOOP_INPUT_TOKENS + ${input_tok:-0} + ${cache_read:-0} + ${cache_create:-0} ))
        LOOP_OUTPUT_TOKENS=$(( LOOP_OUTPUT_TOKENS + ${output_tok:-0} ))
        # Accumulate cost in millicents for integer arithmetic
        if [[ -n "$cost_usd" && "$cost_usd" != "0" && "$cost_usd" != "null" ]]; then
            local cost_millicents
            cost_millicents=$(echo "$cost_usd" | awk '{printf "%.0f", $1 * 100000}' 2>/dev/null || echo "0")
            LOOP_COST_MILLICENTS=$(( ${LOOP_COST_MILLICENTS:-0} + ${cost_millicents:-0} ))
        else
            # Estimate cost from tokens when Claude doesn't provide it (rates per million tokens)
            local total_in total_out
            total_in=$(( ${input_tok:-0} + ${cache_read:-0} + ${cache_create:-0} ))
            total_out=${output_tok:-0}
            local cost=0
            case "${MODEL:-${CLAUDE_MODEL:-sonnet}}" in
                *opus*)   cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 15 + o * 75) / 1000000}') ;;
                *sonnet*) cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 3 + o * 15) / 1000000}') ;;
                *haiku*)  cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 0.25 + o * 1.25) / 1000000}') ;;
                *)       cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 3 + o * 15) / 1000000}') ;;
            esac
            cost_millicents=$(echo "$cost" | awk '{printf "%.0f", $1 * 100000}' 2>/dev/null || echo "0")
            LOOP_COST_MILLICENTS=$(( ${LOOP_COST_MILLICENTS:-0} + ${cost_millicents:-0} ))
        fi
    else
        # Fallback: regex-based parsing for non-JSON output
        local input_tok output_tok
        input_tok=$(grep -oE 'input[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")
        output_tok=$(grep -oE 'output[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")

        LOOP_INPUT_TOKENS=$(( LOOP_INPUT_TOKENS + ${input_tok:-0} ))
        LOOP_OUTPUT_TOKENS=$(( LOOP_OUTPUT_TOKENS + ${output_tok:-0} ))
    fi
}

# ─── Extract Text from JSON ────────────────────────────────────────────────
# Extract plain text from Claude's --output-format json response.
# Handles: valid JSON arrays, malformed JSON, non-JSON output, empty output.
_extract_text_from_json() {
    local json_file="$1" log_file="$2" err_file="${3:-}"

    # Case 1: File doesn't exist or is empty
    if [[ ! -s "$json_file" ]]; then
        # Check stderr for error messages
        if [[ -s "$err_file" ]]; then
            cp "$err_file" "$log_file"
        else
            echo "(no output)" > "$log_file"
        fi
        return 0
    fi

    local first_char
    first_char=$(head -c1 "$json_file" 2>/dev/null || true)

    # Case 2: Valid JSON array — extract .result from last element
    if [[ "$first_char" == "[" ]] && command -v jq >/dev/null 2>&1; then
        local extracted
        extracted=$(jq -r '.[-1].result // empty' "$json_file" 2>/dev/null) || true
        if [[ -n "$extracted" ]]; then
            echo "$extracted" > "$log_file"
            return 0
        fi
        # jq succeeded but result was null/empty — try .content or raw text
        extracted=$(jq -r '.[].content // empty' "$json_file" 2>/dev/null | head -500) || true
        if [[ -n "$extracted" ]]; then
            echo "$extracted" > "$log_file"
            return 0
        fi
        # JSON parsed but no text found — write placeholder
        warn "JSON output has no .result field — check $json_file"
        echo "(no text result in JSON output)" > "$log_file"
        return 0
    fi

    # Case 3: Looks like JSON but no jq — can't parse, use raw
    if [[ "$first_char" == "[" || "$first_char" == "{" ]]; then
        warn "JSON output but jq not available — using raw output"
        cp "$json_file" "$log_file"
        return 0
    fi

    # Case 4: Not JSON at all (plain text, error message, etc.) — use as-is
    cp "$json_file" "$log_file"
    return 0
}

# ─── Write Loop Tokens ──────────────────────────────────────────────────────
# Write accumulated token totals to a JSON file for the pipeline to read.
write_loop_tokens() {
    local token_file="$LOG_DIR/loop-tokens.json"
    local cost_usd="0"
    if [[ "${LOOP_COST_MILLICENTS:-0}" -gt 0 ]]; then
        cost_usd=$(awk "BEGIN {printf \"%.6f\", ${LOOP_COST_MILLICENTS} / 100000}" 2>/dev/null || echo "0")
    fi
    local tmp_file
    tmp_file=$(mktemp "${token_file}.XXXXXX" 2>/dev/null || mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN
    cat > "$tmp_file" <<TOKJSON
{"input_tokens":${LOOP_INPUT_TOKENS},"output_tokens":${LOOP_OUTPUT_TOKENS},"cost_usd":${cost_usd},"iterations":${ITERATION:-0}}
TOKJSON
    mv "$tmp_file" "$token_file"
}

# ─── Apply Adaptive Budget ──────────────────────────────────────────────────
# Reads tuning config for smarter iteration/circuit-breaker thresholds.
apply_adaptive_budget() {
    local tuning_file="$HOME/.shipwright/optimization/loop-tuning.json"
    if [[ -f "$tuning_file" ]] && command -v jq >/dev/null 2>&1; then
        local tuned_max tuned_ext tuned_ext_count tuned_cb
        tuned_max=$(jq -r '.max_iterations // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_ext=$(jq -r '.extension_size // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_ext_count=$(jq -r '.max_extensions // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_cb=$(jq -r '.circuit_breaker_threshold // ""' "$tuning_file" 2>/dev/null || echo "")

        # Only apply tuned values if user didn't explicitly set them
        if ! $MAX_ITERATIONS_EXPLICIT && [[ -n "$tuned_max" && "$tuned_max" != "null" ]]; then
            MAX_ITERATIONS="$tuned_max"
        fi
        [[ -n "$tuned_ext" && "$tuned_ext" != "null" ]] && EXTENSION_SIZE="$tuned_ext"
        [[ -n "$tuned_ext_count" && "$tuned_ext_count" != "null" ]] && MAX_EXTENSIONS="$tuned_ext_count"
        [[ -n "$tuned_cb" && "$tuned_cb" != "null" ]] && CIRCUIT_BREAKER_THRESHOLD="$tuned_cb"
    fi

    # Read learned iteration model
    local _iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
    if [[ -f "$_iter_model" ]] && ! $MAX_ITERATIONS_EXPLICIT && command -v jq >/dev/null 2>&1; then
        local _complexity="${ISSUE_COMPLEXITY:-${COMPLEXITY:-medium}}"
        local _predicted_max
        _predicted_max=$(jq -r --arg c "$_complexity" '.predictions[$c].max_iterations // ""' "$_iter_model" 2>/dev/null) || true
        if [[ -n "${_predicted_max:-}" && "${_predicted_max:-}" != "null" && "${_predicted_max:-0}" -gt 0 ]]; then
            MAX_ITERATIONS="${_predicted_max}"
            info "Iteration model: ${_complexity} complexity → max ${_predicted_max} iterations"
        fi
    fi

    # Try intelligence-based iteration estimate
    if type intelligence_estimate_iterations >/dev/null 2>&1 && ! $MAX_ITERATIONS_EXPLICIT; then
        local est
        est=$(intelligence_estimate_iterations "${GOAL:-}" "${COMPLEXITY:-5}" 2>/dev/null || echo "")
        if [[ -n "$est" && "$est" =~ ^[0-9]+$ ]]; then
            MAX_ITERATIONS="$est"
        fi
    fi
}

# ─── Format Duration Helper ────────────────────────────────────────────────
format_duration() {
    local secs="$1"
    local mins=$(( secs / 60 ))
    local remaining_secs=$(( secs % 60 ))
    if [[ $mins -gt 0 ]]; then
        printf "%dm %ds" "$mins" "$remaining_secs"
    else
        printf "%ds" "$remaining_secs"
    fi
}

# ─── Budget Gate (hard stop when exhausted) ────────────────────────────────
check_budget_gate() {
    local script_dir="${SCRIPT_DIR:-.}"
    [[ ! -x "$script_dir/sw-cost.sh" ]] && return 0
    local remaining
    remaining=$(bash "$script_dir/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
    [[ -z "$remaining" ]] && return 0
    [[ "$remaining" == "unlimited" ]] && return 0

    # Parse remaining as float, check if <= 0
    if awk -v r="$remaining" 'BEGIN { exit !(r <= 0) }' 2>/dev/null; then
        error "Budget exhausted (remaining: \$${remaining}) — stopping pipeline"
        emit_event "pipeline.budget_exhausted" "remaining=$remaining"
        return 1
    fi

    # Warn at 10% threshold (remaining < 1.0 when typical job ~$5+)
    if awk -v r="$remaining" 'BEGIN { exit !(r < 1.0) }' 2>/dev/null; then
        warn "Budget low: \$${remaining} remaining"
    fi

    return 0
}
