#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_ITERATION_LOADED:-}" ]] && return 0
_LOOP_ITERATION_LOADED=1

# ═══════════════════════════════════════════════════════════════════════════
# lib/loop-iteration.sh — Iteration Execution & Test Gating
# ═══════════════════════════════════════════════════════════════════════════
#
# Executes Claude Code iterations, runs test gates, handles failures,
# and orchestrates quality checks. Handles:
# - Claude flag building & execution (build_claude_flags, run_claude_iteration)
# - Test gating & validation (run_test_gate, diagnose_failure)
# - Quality gates & audits (run_quality_gates, run_audit_agent, etc.)
#
# Note: Prompt composition and context management moved to loop-prompts.sh
# and loop-context.sh respectively.

# ─── Claude Execution ────────────────────────────────────────────────────────

build_claude_flags() {
    local flags=()
    flags+=("--model" "$MODEL")
    flags+=("--output-format" "json")

    if $SKIP_PERMISSIONS; then
        flags+=("--dangerously-skip-permissions")
    fi

    if [[ -n "$MAX_TURNS" ]]; then
        flags+=("--max-turns" "$MAX_TURNS")
    fi

    if [[ -n "${EFFORT_LEVEL:-}" ]]; then
        flags+=("--effort" "$EFFORT_LEVEL")
    fi

    # Only add fallback-model if it differs from primary (Claude CLI rejects same model)
    if [[ -n "${FALLBACK_MODEL:-}" ]] && [[ "${FALLBACK_MODEL}" != "$MODEL" ]]; then
        flags+=("--fallback-model" "$FALLBACK_MODEL")
    fi

    echo "${flags[*]}"
}

run_claude_iteration() {
    local log_file="$LOG_DIR/iteration-${ITERATION}.log"
    local json_file="$LOG_DIR/iteration-${ITERATION}.json"
    local prompt
    prompt="$(compose_prompt)"

    # Context budget monitoring and proactive trimming (issue #209)
    local budget_estimate=""
    local budget_status=""
    if type context_budget_estimate >/dev/null 2>&1; then
        budget_estimate=$(context_budget_estimate "$prompt" "${ARTIFACTS_DIR:-./.claude/pipeline-artifacts}" 2>/dev/null || echo "{}")
        if [[ -n "$budget_estimate" ]]; then
            budget_status=$(context_budget_check "$budget_estimate" 2>/dev/null || echo "{}")
            local status_val=$(echo "$budget_status" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

            # Log budget state
            if type context_budget_log_state >/dev/null 2>&1; then
                context_budget_log_state "$budget_estimate" "$budget_status" "${ARTIFACTS_DIR:-./.claude/pipeline-artifacts}" 2>/dev/null || true
            fi

            # Warn if approaching limits
            if [[ "$status_val" == "yellow" ]] || [[ "$status_val" == "red" ]] || [[ "$status_val" == "critical" ]]; then
                local msg=$(echo "$budget_status" | jq -r '.message // "context budget alert"' 2>/dev/null || echo "")
                if [[ -n "$msg" ]]; then
                    warn "$msg"
                fi
            fi
        fi
    fi

    local final_prompt
    final_prompt=$(manage_context_window "$prompt")

    # Apply proactive trimming if budget is tight
    if [[ -n "$budget_status" ]]; then
        local action=$(echo "$budget_status" | jq -r '.action // "continue"' 2>/dev/null || echo "continue")
        if [[ "$action" != "continue" ]] && type context_budget_trim >/dev/null 2>&1; then
            local trim_status=$(echo "$budget_status" | jq -r '.status // "green"' 2>/dev/null || echo "green")
            final_prompt=$(context_budget_trim "$final_prompt" "$trim_status" 200000 2>/dev/null || echo "$final_prompt")
        fi
    fi

    local raw_prompt_chars=${#prompt}
    local prompt_chars=${#final_prompt}
    local approx_tokens=$((prompt_chars / 4))
    info "Prompt: ~${approx_tokens} tokens (${prompt_chars} chars)"

    # Audit: save full prompt to disk for traceability
    if type audit_save_prompt >/dev/null 2>&1; then
        audit_save_prompt "$final_prompt" "$ITERATION" || true
    fi
    if type audit_emit >/dev/null 2>&1; then
        audit_emit "loop.prompt" "iteration=$ITERATION" "chars=$prompt_chars" \
            "raw_chars=$raw_prompt_chars" "path=iteration-${ITERATION}.prompt.txt" || true
    fi

    # Emit context efficiency metrics
    if type emit_event >/dev/null 2>&1; then
        local trim_ratio=0
        local budget_utilization=0
        if [[ "$raw_prompt_chars" -gt 0 ]]; then
            trim_ratio=$(awk -v raw="$raw_prompt_chars" -v trimmed="$prompt_chars" \
                'BEGIN { printf "%.1f", ((raw - trimmed) / raw) * 100 }')
        fi
        if [[ "${CONTEXT_BUDGET_CHARS:-0}" -gt 0 ]]; then
            budget_utilization=$(awk -v used="$prompt_chars" -v budget="${CONTEXT_BUDGET_CHARS}" \
                'BEGIN { printf "%.1f", (used / budget) * 100 }')
        fi
        emit_event "loop.context_efficiency" \
            "iteration=$ITERATION" \
            "raw_prompt_chars=$raw_prompt_chars" \
            "trimmed_prompt_chars=$prompt_chars" \
            "trim_ratio=$trim_ratio" \
            "budget_utilization=$budget_utilization" \
            "budget_chars=${CONTEXT_BUDGET_CHARS:-0}" \
            "job_id=${PIPELINE_JOB_ID:-loop-$$}" 2>/dev/null || true
    fi

    local flags
    flags="$(build_claude_flags)"

    local iter_start
    iter_start="$(now_epoch)"

    echo -e "\n${CYAN}${BOLD}▸${RESET} ${BOLD}Iteration ${ITERATION}/${MAX_ITERATIONS}${RESET} — Starting..."

    # Run Claude headless (with timeout + PID capture for signal handling)
    # Output goes to .json first, then we extract text into .log for compat
    local exit_code=0
    # shellcheck disable=SC2086
    local err_file="${json_file%.json}.stderr"
    if [[ -n "$TIMEOUT_CMD" ]]; then
        $TIMEOUT_CMD "$CLAUDE_TIMEOUT" claude -p "$final_prompt" $flags > "$json_file" 2>"$err_file" &
    else
        claude -p "$final_prompt" $flags > "$json_file" 2>"$err_file" &
    fi
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || exit_code=$?
    CHILD_PID=""
    if [[ "$exit_code" -eq 124 ]]; then
        warn "Claude CLI timed out after ${CLAUDE_TIMEOUT}s"
    fi

    # Extract text result from JSON into .log for backwards compatibility
    # With --output-format json, stdout is a JSON array; .[-1].result has the text
    _extract_text_from_json "$json_file" "$log_file" "$err_file"

    local iter_end
    iter_end="$(now_epoch)"
    local iter_duration=$(( iter_end - iter_start ))

    echo -e "  ${GREEN}✓${RESET} Claude session completed ($(format_duration "$iter_duration"), exit $exit_code)"

    # Accumulate token usage from this iteration's JSON output
    accumulate_loop_tokens "$json_file"

    # Audit: record response metadata
    if type audit_emit >/dev/null 2>&1; then
        local response_chars=0
        [[ -f "$log_file" ]] && response_chars=$(wc -c < "$log_file" | tr -d ' ')
        audit_emit "loop.response" "iteration=$ITERATION" "chars=$response_chars" \
            "exit_code=$exit_code" "duration_s=$iter_duration" \
            "path=iteration-${ITERATION}.json" || true
    fi

    # Context budget: record iteration summary for context compression (issue #209)
    if type context_budget_summarize_iteration >/dev/null 2>&1; then
        # Extract test result from log or TEST_PASSED variable
        local test_result="${TEST_OUTPUT:-}"
        [[ -z "$test_result" && -n "${TEST_PASSED:-}" ]] && test_result=$([ "$TEST_PASSED" = true ] && echo "PASSED" || echo "FAILED")
        context_budget_summarize_iteration "$ITERATION" "$log_file" "$test_result" "${ARTIFACTS_DIR:-./.claude/pipeline-artifacts}" 2>/dev/null || true
    fi

    # Show verbose output if requested
    if $VERBOSE; then
        echo -e "  ${DIM}─── Claude Output ───${RESET}"
        sed 's/^/  /' "$log_file" | head -100
        echo -e "  ${DIM}─────────────────────${RESET}"
    fi

    return $exit_code
}

# ─── Iteration Summary Extraction ────────────────────────────────────────────

extract_summary() {
    local log_file="$1"
    # Grab last meaningful lines from Claude output, skipping empty lines
    local summary
    summary="$(grep -v '^$' "$log_file" | tail -5 | head -3 2>/dev/null || echo "(no output)")"
    # Truncate long lines
    summary="$(echo "$summary" | cut -c1-120)"

    # Sanitize: if summary is just a CLI/API error, replace with generic text
    if echo "$summary" | grep -qiE 'Invalid API key|authentication_error|rate_limit|API key expired|ANTHROPIC_API_KEY'; then
        summary="(CLI error — no useful output this iteration)"
    fi

    echo "$summary"
}
