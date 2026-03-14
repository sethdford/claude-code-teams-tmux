#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Loop Error Feedback — diagnose failures, run tests, write error summaries
# ║                                                                         ║
# ║  This module handles all error diagnosis, test execution, and error      ║
# ║  context generation for the loop.                                        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# Module guard — prevent double-sourcing
[[ -z "${_LOOP_ERROR_FEEDBACK_SH_LOADED:-}" ]] || return 0
readonly _LOOP_ERROR_FEEDBACK_SH_LOADED=1

# ─── Failure Diagnosis ──────────────────────────────────────────────────────
# Pattern-based root-cause classification for smarter retries (no Claude needed).
# Returns markdown context to inject into the next iteration's goal.
diagnose_failure() {
    local error_output="$1"
    local changed_files="$2"
    local iteration="$3"

    local diagnosis=""
    local strategy="retry_with_context"  # default

    # Pattern-based classification (fast, no Claude needed)
    if echo "$error_output" | grep -qiE 'import.*not found|cannot find module|no module named'; then
        diagnosis="missing_import"
        strategy="fix_imports"
    elif echo "$error_output" | grep -qiE 'syntax error|unexpected token|parse error'; then
        diagnosis="syntax_error"
        strategy="fix_syntax"
    elif echo "$error_output" | grep -qiE 'type.*not assignable|type error|TypeError'; then
        diagnosis="type_error"
        strategy="fix_types"
    elif echo "$error_output" | grep -qiE 'undefined.*variable|not defined|ReferenceError'; then
        diagnosis="undefined_reference"
        strategy="fix_references"
    elif echo "$error_output" | grep -qiE 'timeout|timed out|ETIMEDOUT'; then
        diagnosis="timeout"
        strategy="optimize_performance"
    elif echo "$error_output" | grep -qiE 'assertion.*fail|expect.*to|AssertionError'; then
        diagnosis="test_assertion"
        strategy="fix_logic"
    elif echo "$error_output" | grep -qiE 'permission denied|EACCES|forbidden'; then
        diagnosis="permission_error"
        strategy="fix_permissions"
    elif echo "$error_output" | grep -qiE 'out of memory|heap|OOM|ENOMEM'; then
        diagnosis="resource_error"
        strategy="reduce_resource_usage"
    else
        diagnosis="unknown"
        strategy="retry_with_context"
    fi

    # Check if we've seen this diagnosis before in this session
    local diagnosis_file="${LOG_DIR}/diagnoses.txt"
    local repeat_count=0
    if [[ -f "$diagnosis_file" ]]; then
        repeat_count=$(grep -c "^${diagnosis}$" "$diagnosis_file" 2>/dev/null || true)
        repeat_count="${repeat_count:-0}"
    fi
    echo "$diagnosis" >> "$diagnosis_file"

    # Escalate strategy if same diagnosis repeats
    if [[ "$repeat_count" -ge 2 ]]; then
        strategy="alternative_approach"
    fi

    # Try memory-based fix lookup
    local known_fix=""
    if type memory_query_fix_for_error &>/dev/null; then
        local fix_json
        fix_json=$(memory_query_fix_for_error "$error_output" 2>/dev/null || true)
        if [[ -n "$fix_json" && "$fix_json" != "null" ]]; then
            known_fix=$(echo "$fix_json" | jq -r '.fix // ""' 2>/dev/null | head -5)
        fi
    fi

    # Build diagnosis context for Claude
    local diagnosis_context="## Failure Diagnosis (Iteration $iteration)
Classification: $diagnosis
Strategy: $strategy
Repeat count: $repeat_count"

    if [[ -n "$known_fix" ]]; then
        diagnosis_context+="
Known fix from memory: $known_fix"
    fi

    # Strategy-specific guidance
    case "$strategy" in
        fix_imports)
            diagnosis_context+="
INSTRUCTION: The error is about missing imports/modules. Check that all imports are correct, packages are installed, and paths are right. Do NOT change the logic - just fix the imports."
            ;;
        fix_syntax)
            diagnosis_context+="
INSTRUCTION: This is a syntax error. Carefully check the exact line mentioned in the error. Look for missing brackets, semicolons, commas, or mismatched quotes."
            ;;
        fix_types)
            diagnosis_context+="
INSTRUCTION: Type mismatch error. Check the types at the error location. Ensure function signatures match their usage."
            ;;
        fix_logic)
            diagnosis_context+="
INSTRUCTION: Test assertion failure. The code logic is wrong, not the syntax. Re-read the test expectations and fix the implementation to match."
            ;;
        alternative_approach)
            diagnosis_context+="
INSTRUCTION: This error has occurred $repeat_count times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements"
            ;;
    esac

    echo "$diagnosis_context"
}

# ─── Test Gate ────────────────────────────────────────────────────────────
run_test_gate() {
    if [[ -z "$TEST_CMD" ]] && [[ ${#ADDITIONAL_TEST_CMDS[@]} -eq 0 ]]; then
        TEST_PASSED=""
        TEST_OUTPUT=""
        return
    fi

    # Determine which test command to use this iteration
    local active_test_cmd="$TEST_CMD"
    local test_mode="full"
    if [[ -n "$FAST_TEST_CMD" ]]; then
        # Use full test every FAST_TEST_INTERVAL iterations, on first iteration, and on final iteration
        if [[ "$ITERATION" -eq 1 ]] || [[ $(( ITERATION % FAST_TEST_INTERVAL )) -eq 0 ]] || [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
            active_test_cmd="$TEST_CMD"
            test_mode="full"
        else
            active_test_cmd="$FAST_TEST_CMD"
            test_mode="fast"
        fi
    fi

    local all_passed=true
    local test_results="[]"
    local combined_output=""
    local test_timeout="${SW_TEST_TIMEOUT:-900}"

    # Run primary test command
    if [[ -n "$active_test_cmd" ]]; then
        local test_log="$LOG_DIR/tests-iter-${ITERATION}.log"
        TEST_LOG_FILE="$test_log"
        echo -e "  ${DIM}Running ${test_mode} tests...${RESET}"

        local test_wrapper="$active_test_cmd"
        if command -v timeout >/dev/null 2>&1; then
            test_wrapper="timeout ${test_timeout} bash -c $(printf '%q' "$active_test_cmd")"
        elif command -v gtimeout >/dev/null 2>&1; then
            test_wrapper="gtimeout ${test_timeout} bash -c $(printf '%q' "$active_test_cmd")"
        fi

        local start_ts exit_code=0
        start_ts=$(date +%s)
        bash -c "$test_wrapper" > "$test_log" 2>&1 || exit_code=$?
        local duration=$(( $(date +%s) - start_ts ))

        if command -v jq >/dev/null 2>&1; then
            test_results=$(echo "$test_results" | jq --arg cmd "$active_test_cmd" \
                --argjson exit "$exit_code" --argjson dur "$duration" \
                '. + [{"command": $cmd, "exit_code": $exit, "duration_s": $dur}]')
        fi

        [[ "$exit_code" -ne 0 ]] && all_passed=false
        combined_output+="$(cat "$test_log" 2>/dev/null)"$'\n'
    fi

    # Run additional test commands (discovered or explicit)
    # Mid-build discovery: find test files created since loop start
    local mid_build_cmds=()
    if [[ -n "${LOOP_START_COMMIT:-}" ]] && type detect_created_test_files >/dev/null 2>&1; then
        while IFS= read -r _cmd; do
            [[ -n "$_cmd" ]] && mid_build_cmds+=("$_cmd")
        done < <(detect_created_test_files "$LOOP_START_COMMIT" 2>/dev/null || true)
    fi
    local all_extra=("${ADDITIONAL_TEST_CMDS[@]+"${ADDITIONAL_TEST_CMDS[@]}"}" "${mid_build_cmds[@]+"${mid_build_cmds[@]}"}")

    for extra_cmd in "${all_extra[@]+"${all_extra[@]}"}"; do
        [[ -z "$extra_cmd" ]] && continue
        local extra_log="${LOG_DIR}/tests-extra-iter-${ITERATION}.log"
        echo -e "  ${DIM}Running additional: ${extra_cmd}${RESET}"

        local extra_wrapper="$extra_cmd"
        if command -v timeout >/dev/null 2>&1; then
            extra_wrapper="timeout ${test_timeout} bash -c $(printf '%q' "$extra_cmd")"
        elif command -v gtimeout >/dev/null 2>&1; then
            extra_wrapper="gtimeout ${test_timeout} bash -c $(printf '%q' "$extra_cmd")"
        fi

        local start_ts exit_code=0
        start_ts=$(date +%s)
        bash -c "$extra_wrapper" >> "$extra_log" 2>&1 || exit_code=$?
        local duration=$(( $(date +%s) - start_ts ))

        if command -v jq >/dev/null 2>&1; then
            test_results=$(echo "$test_results" | jq --arg cmd "$extra_cmd" \
                --argjson exit "$exit_code" --argjson dur "$duration" \
                '. + [{"command": $cmd, "exit_code": $exit, "duration_s": $dur}]')
        fi

        [[ "$exit_code" -ne 0 ]] && all_passed=false
        combined_output+="$(cat "$extra_log" 2>/dev/null)"$'\n'
    done

    # Write structured test evidence
    if command -v jq >/dev/null 2>&1; then
        echo "$test_results" > "${LOG_DIR}/test-evidence-iter-${ITERATION}.json"
    fi

    # Audit: emit test gate event
    if type audit_emit >/dev/null 2>&1; then
        local cmd_count=0
        command -v jq >/dev/null 2>&1 && cmd_count=$(echo "$test_results" | jq 'length' 2>/dev/null || echo 0)
        audit_emit "loop.test_gate" "iteration=$ITERATION" "commands=$cmd_count" \
            "all_passed=$all_passed" "evidence_path=test-evidence-iter-${ITERATION}.json" || true
    fi

    TEST_PASSED=$all_passed
    TEST_OUTPUT="$(echo "$combined_output" | tail -50)"
}

# ─── Write Error Summary ────────────────────────────────────────────────────
write_error_summary() {
    local error_json="$LOG_DIR/error-summary.json"

    # Write on test failure OR build failure (non-zero exit from Claude iteration)
    local build_log="$LOG_DIR/iteration-${ITERATION}.log"
    if [[ "${TEST_PASSED:-}" != "false" ]]; then
        # Check for build-level failures (Claude iteration exited non-zero or produced errors)
        local build_had_errors=false
        if [[ -f "$build_log" ]]; then
            local build_err_count
            build_err_count=$(tail -30 "$build_log" 2>/dev/null | grep -ciE '(error|fail|exception|panic|FATAL)' || true)
            [[ "${build_err_count:-0}" -gt 0 ]] && build_had_errors=true
        fi
        if [[ "$build_had_errors" != "true" ]]; then
            # Clear previous error summary on success
            rm -f "$error_json" 2>/dev/null || true
            return
        fi
    fi

    # Prefer test log, fall back to build log
    local test_log="${TEST_LOG_FILE:-$LOG_DIR/tests-iter-${ITERATION}.log}"
    local source_log="$test_log"
    if [[ ! -f "$source_log" ]]; then
        source_log="$build_log"
    fi
    [[ ! -f "$source_log" ]] && return

    # Extract error lines (last 30 lines, grep for error patterns)
    local error_lines_raw
    error_lines_raw=$(tail -30 "$source_log" 2>/dev/null | grep -iE '(error|fail|assert|exception|panic|FAIL|TypeError|ReferenceError|SyntaxError)' | head -10 || true)

    local error_count=0
    if [[ -n "$error_lines_raw" ]]; then
        error_count=$(echo "$error_lines_raw" | wc -l | tr -d ' ')
    fi

    local tmp_json="${error_json}.tmp.$$"

    # Build JSON with jq (preferred) or plain-text fallback
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --argjson iteration "${ITERATION:-0}" \
            --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --argjson error_count "${error_count:-0}" \
            --arg error_lines "$error_lines_raw" \
            --arg test_cmd "${TEST_CMD:-}" \
            '{
                iteration: $iteration,
                timestamp: $timestamp,
                error_count: $error_count,
                error_lines: ($error_lines | split("\n") | map(select(length > 0))),
                test_cmd: $test_cmd
            }' > "$tmp_json" 2>/dev/null && mv "$tmp_json" "$error_json" || rm -f "$tmp_json" 2>/dev/null
    else
        # Fallback: write plain-text error summary (still machine-parseable)
        cat > "$tmp_json" <<ERRJSON
{"iteration":${ITERATION:-0},"error_count":${error_count:-0},"error_lines":[],"test_cmd":"test"}
ERRJSON
        mv "$tmp_json" "$error_json" 2>/dev/null || rm -f "$tmp_json" 2>/dev/null
    fi
}
