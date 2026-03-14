#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_CHECKPOINT_LOADED:-}" ]] && return 0
_LOOP_CHECKPOINT_LOADED=1

# ─── Goal Achievement Verification Checkpoint ────────────────────────────────
# Injects verification prompts every N iterations to detect early goal
# completion and reduce iteration waste.

# State variables (initialized by init_goal_checkpoint_system)
GOAL_CHECK_ENABLED=false
GOAL_CHECK_INTERVAL=3
GOAL_CHECK_MIN_ITERATION=2
GOAL_REACHED=false
CHECKPOINT_TRIGGERED=false

# Initialize checkpoint system from config
init_goal_checkpoint_system() {
    # Load interval: CLI flag > env var > daemon-config > default (3)
    if [[ -n "${_GOAL_CHECK_INTERVAL_CLI:-}" ]]; then
        GOAL_CHECK_INTERVAL="$_GOAL_CHECK_INTERVAL_CLI"
    elif [[ -n "${SW_GOAL_CHECK_INTERVAL:-}" ]]; then
        GOAL_CHECK_INTERVAL="$SW_GOAL_CHECK_INTERVAL"
    elif type _config_get_int >/dev/null 2>&1; then
        GOAL_CHECK_INTERVAL=$(_config_get_int "loop.goal_check_interval" 3 2>/dev/null || echo 3)
    fi

    # Validate interval (must be >= 1)
    if ! [[ "$GOAL_CHECK_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$GOAL_CHECK_INTERVAL" -lt 1 ]]; then
        if type warn >/dev/null 2>&1; then
            warn "Invalid goal_check_interval '${GOAL_CHECK_INTERVAL}' — using default 3"
        fi
        GOAL_CHECK_INTERVAL=3
    fi

    # Load min iteration
    if type _config_get_int >/dev/null 2>&1; then
        GOAL_CHECK_MIN_ITERATION=$(_config_get_int "loop.goal_check_min_iteration" 2 2>/dev/null || echo 2)
    fi

    # Load enabled flag: env var > daemon-config > default (true)
    if [[ "${SW_GOAL_CHECK_ENABLED:-}" == "false" ]]; then
        GOAL_CHECK_ENABLED=false
    elif [[ "${SW_GOAL_CHECK_ENABLED:-}" == "true" ]]; then
        GOAL_CHECK_ENABLED=true
    elif type _config_get >/dev/null 2>&1; then
        local cfg_enabled
        cfg_enabled=$(_config_get "loop.goal_check_enabled" "true" 2>/dev/null || echo "true")
        if [[ "$cfg_enabled" == "false" ]]; then
            GOAL_CHECK_ENABLED=false
        else
            GOAL_CHECK_ENABLED=true
        fi
    else
        GOAL_CHECK_ENABLED=true
    fi

    GOAL_REACHED=false
    CHECKPOINT_TRIGGERED=false
}

# Check if current iteration should trigger a checkpoint
# Returns 0 if checkpoint should fire, 1 otherwise
inject_goal_checkpoint() {
    local iteration="${1:-0}"
    local max_iterations="${2:-20}"

    CHECKPOINT_TRIGGERED=false

    # Skip if disabled
    if ! $GOAL_CHECK_ENABLED; then
        return 1
    fi

    # Skip before minimum iteration
    if [[ "$iteration" -lt "$GOAL_CHECK_MIN_ITERATION" ]]; then
        return 1
    fi

    # Skip on last iteration (will exit naturally)
    if [[ "$iteration" -ge "$max_iterations" ]]; then
        return 1
    fi

    # Check if iteration is a multiple of the interval
    if [[ $(( iteration % GOAL_CHECK_INTERVAL )) -eq 0 ]]; then
        CHECKPOINT_TRIGGERED=true
        return 0
    fi

    return 1
}

# Build the checkpoint prompt section
# Args: $1=goal, $2=iteration, $3=max_iterations, $4=test_status, $5=recent_commits, $6=files_changed
build_checkpoint_prompt() {
    local goal="${1:-}"
    local iteration="${2:-0}"
    local max_iterations="${3:-20}"
    local test_status="${4:-not run}"
    local recent_commits="${5:-none}"
    local files_changed="${6:-0}"

    cat <<CHECKPOINT_PROMPT

## Goal Achievement Checkpoint (Iteration ${iteration}/${max_iterations})

Current goal:
${goal}

Progress summary:
- Iterations completed: ${iteration}
- Files changed: ${files_changed}
- Recent commits: ${recent_commits}
- Test status: ${test_status}

CRITICAL QUESTION: Is the goal FULLY achieved?

Review carefully:
1. Is ALL required functionality implemented?
2. Do ALL tests pass?
3. Are there any remaining TODOs or edge cases?
4. Is the code production-ready?

If 100% confident goal is achieved, output: GOAL_ACHIEVED

If ANY doubt remains, continue working. Do NOT output GOAL_ACHIEVED unless certain.
CHECKPOINT_PROMPT
}

# Parse Claude's response for the GOAL_ACHIEVED signal
# Returns 0 if signal detected, 1 otherwise
parse_goal_checkpoint_response() {
    local log_file="${1:-}"

    if [[ -z "$log_file" ]] || [[ ! -f "$log_file" ]]; then
        return 1
    fi

    if grep -q "GOAL_ACHIEVED" "$log_file" 2>/dev/null; then
        GOAL_REACHED=true
        return 0
    fi

    return 1
}
