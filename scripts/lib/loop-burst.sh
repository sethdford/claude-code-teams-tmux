#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_BURST_LOADED:-}" ]] && return 0
_LOOP_BURST_LOADED=1

# ─── Burst Mode: Dynamic Cost-Performance Optimizer ──────────────────────────
# Temporarily upgrades the model when progress is high, iterations are running
# out, and budget allows it. One-shot per iteration with automatic revert on
# failure. Safe defaults everywhere — any error results in no burst.

# Compute a 0-100 progress score based on test trajectory, velocity, and commits.
# Returns integer on stdout. Safe default: 0 on any error.
burst_compute_progress_score() {
    local score=0

    # +30: tests currently passing
    if [[ "${TEST_PASSED:-}" == "true" ]]; then
        score=$(( score + 30 ))
    fi

    # +20: test trend improving (was failing, now passing)
    if [[ "${BURST_PREVIOUS_TEST:-}" == "false" && "${TEST_PASSED:-}" == "true" ]]; then
        score=$(( score + 20 ))
    fi

    # +25: velocity above threshold
    local velocity_avg=0
    if type compute_velocity_avg >/dev/null 2>&1; then
        velocity_avg=$(compute_velocity_avg 2>/dev/null || echo 0)
    fi
    velocity_avg="${velocity_avg:-0}"
    if [[ "$velocity_avg" -gt 10 ]] 2>/dev/null; then
        score=$(( score + 25 ))
    fi

    # +15: agent is making commits
    if [[ "${TOTAL_COMMITS:-0}" -gt 0 ]] 2>/dev/null; then
        score=$(( score + 15 ))
    fi

    # +10: no consecutive failures
    if [[ "${CONSECUTIVE_FAILURES:-0}" -eq 0 ]] 2>/dev/null; then
        score=$(( score + 10 ))
    fi

    echo "$score"
}

# Evaluate whether burst mode should activate this iteration.
# Sets BURST_ACTIVE, BURST_ORIGINAL_MODEL, overrides CLAUDE_MODEL.
# Safe default: BURST_ACTIVE=false on any error.
burst_evaluate() {
    BURST_ACTIVE=false

    # Compute progress score
    local score
    score=$(burst_compute_progress_score 2>/dev/null || echo 0)
    score="${score:-0}"

    # Gate 1: progress score must exceed threshold
    if [[ "$score" -le 70 ]] 2>/dev/null; then
        return 0
    fi

    # Gate 2: iterations remaining must be < 3
    local iterations_remaining=999
    if [[ "${MAX_ITERATIONS:-0}" -gt 0 && "${ITERATION:-0}" -gt 0 ]] 2>/dev/null; then
        iterations_remaining=$(( MAX_ITERATIONS - ITERATION ))
    fi
    if [[ "$iterations_remaining" -ge 3 ]] 2>/dev/null; then
        return 0
    fi

    # Gate 3: budget must be > 2x estimated cost-to-complete
    local budget_remaining=""
    if [[ -x "${SCRIPT_DIR:-}/sw-cost.sh" ]]; then
        budget_remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
    fi
    # If no budget system or unlimited, gate passes
    if [[ -n "$budget_remaining" && "$budget_remaining" != "unlimited" ]]; then
        local avg_cost_per_iter=0
        if [[ "${ITERATION:-0}" -gt 0 && "${LOOP_COST_MILLICENTS:-0}" -gt 0 ]] 2>/dev/null; then
            avg_cost_per_iter=$(( LOOP_COST_MILLICENTS / ITERATION ))
        fi
        local estimated_cost_to_complete=0
        if [[ "$avg_cost_per_iter" -gt 0 ]] 2>/dev/null; then
            # Convert millicents to dollars for comparison: budget is in dollars
            estimated_cost_to_complete=$(( avg_cost_per_iter * iterations_remaining ))
            # budget_remaining is in dollars, estimated is in millicents
            # Convert estimated to dollars: divide by 100000 (100 cents * 1000 millicents)
            # Use awk for float comparison
            local budget_ok
            budget_ok=$(awk -v budget="$budget_remaining" -v est="$estimated_cost_to_complete" \
                'BEGIN { est_dollars = est / 100000; print (budget > 2 * est_dollars) ? "1" : "0" }' 2>/dev/null || echo "1")
            if [[ "$budget_ok" != "1" ]]; then
                return 0
            fi
        fi
        # If avg_cost is 0 (early iterations), skip budget gate (let it pass)
    fi

    # Check if already on the best model — no upgrade needed
    local current_model="${MODEL:-opus}"
    case "$current_model" in
        opus|claude-opus-4-6|claude-opus-4-20250514)
            burst_log_decision "already_optimal" "$current_model" "$current_model" "$score" "already on opus" 2>/dev/null || true
            return 0
            ;;
    esac

    # All gates passed — activate burst mode
    BURST_ACTIVE=true
    BURST_ORIGINAL_MODEL="${MODEL:-}"
    MODEL="opus"
    export CLAUDE_MODEL="claude-opus-4-6"

    # Display burst banner
    local yellow='\033[38;2;251;191;36m'
    local bold='\033[1m'
    local reset='\033[0m'
    echo -e "  ${yellow}${bold}⚡ BURST MODE${reset} — upgrading ${BURST_ORIGINAL_MODEL} → opus (score: ${score}, ${iterations_remaining} iter remaining)"

    # Emit event
    if type emit_event >/dev/null 2>&1; then
        emit_event "loop.burst_activate" \
            "score=$score" \
            "model_from=${BURST_ORIGINAL_MODEL}" \
            "model_to=opus" \
            "iterations_remaining=$iterations_remaining" \
            "iteration=${ITERATION:-0}"
    fi

    burst_log_decision "activate" "$BURST_ORIGINAL_MODEL" "opus" "$score" "all gates passed" 2>/dev/null || true
}

# Called at iteration start. Reverts model if previous burst failed.
# Always resets BURST_ACTIVE=false (burst is one-shot per iteration).
burst_check_revert() {
    # Only act if burst was active in previous iteration
    if [[ "${BURST_ACTIVE:-false}" != "true" ]]; then
        return 0
    fi

    local previous_model="${BURST_ORIGINAL_MODEL:-}"
    local outcome=""

    if [[ "${TEST_PASSED:-}" == "true" ]]; then
        outcome="success"
        # Burst succeeded — revert model anyway (burst is one-shot)
        if [[ -n "$previous_model" ]]; then
            MODEL="$previous_model"
            export CLAUDE_MODEL="${SAVED_CLAUDE_MODEL:-}"
        fi
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.burst_success" \
                "model_from=opus" \
                "model_to=${previous_model}" \
                "iteration=${ITERATION:-0}"
        fi
    else
        outcome="failure"
        # Burst failed — revert model
        if [[ -n "$previous_model" ]]; then
            MODEL="$previous_model"
            export CLAUDE_MODEL="${SAVED_CLAUDE_MODEL:-}"
        fi
        local yellow='\033[38;2;251;191;36m'
        local reset='\033[0m'
        echo -e "  ${yellow}⚠${reset} Burst revert — tests failed, restoring ${previous_model}"
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.burst_revert" \
                "model_from=opus" \
                "model_to=${previous_model}" \
                "reason=test_failure" \
                "iteration=${ITERATION:-0}"
        fi
    fi

    burst_log_decision "revert_${outcome}" "opus" "${previous_model}" "0" "${outcome}" 2>/dev/null || true

    # Reset burst state (one-shot per iteration)
    BURST_ACTIVE=false
    BURST_ORIGINAL_MODEL=""
}

# Log burst decision to ~/.shipwright/costs.json for learning.
# Fire-and-forget — errors suppressed.
# Args: type model_from model_to score reason
burst_log_decision() {
    local type="${1:-}" model_from="${2:-}" model_to="${3:-}" score="${4:-0}" reason="${5:-}"
    local costs_dir="${HOME}/.shipwright"
    local costs_file="${costs_dir}/costs.json"

    mkdir -p "$costs_dir" 2>/dev/null || return 0

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"

    local entry
    entry=$(jq -n \
        --arg type "$type" \
        --arg model_from "$model_from" \
        --arg model_to "$model_to" \
        --arg score "$score" \
        --arg iterations_remaining "$(( ${MAX_ITERATIONS:-0} - ${ITERATION:-0} ))" \
        --arg reason "$reason" \
        --arg ts "$ts" \
        '{type: $type, model_from: $model_from, model_to: $model_to, progress_score: ($score | tonumber), iterations_remaining: ($iterations_remaining | tonumber), reason: $reason, ts: $ts}' \
        2>/dev/null) || return 0

    # Atomic append using tmp + mv
    local tmp_file="${costs_file}.burst.tmp.$$"
    if [[ -f "$costs_file" ]]; then
        jq --argjson entry "$entry" \
            '.burst_decisions = ((.burst_decisions // []) + [$entry])' \
            "$costs_file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$costs_file" 2>/dev/null
    else
        echo "{\"burst_decisions\":[$entry]}" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$costs_file" 2>/dev/null
    fi
    # Clean up on failure
    rm -f "$tmp_file" 2>/dev/null
    return 0
}
