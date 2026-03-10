#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_PROGRESS_LOADED:-}" ]] && return 0
_LOOP_PROGRESS_LOADED=1

# ─── Progress File Management ──────────────────────────────────────────────────

write_progress() {
    local progress_file="$LOG_DIR/progress.md"
    local recent_commits
    recent_commits=$(git -C "$PROJECT_ROOT" log --oneline -5 2>/dev/null || echo "(no commits)")
    local changed_files
    changed_files=$(git -C "$PROJECT_ROOT" diff --name-only HEAD~3 2>/dev/null | head -20 || echo "(none)")
    local last_error=""
    local prev_test_log="$LOG_DIR/tests-iter-${ITERATION}.log"
    if [[ -f "$prev_test_log" ]] && [[ "${TEST_PASSED:-}" == "false" ]]; then
        last_error=$(tail -10 "$prev_test_log" 2>/dev/null || true)
    fi

    # Use printf to avoid heredoc delimiter injection from GOAL content
    local tmp_progress="${progress_file}.tmp.$$"
    {
        printf '# Session Progress (Auto-Generated)\n\n'
        printf '## Goal\n%s\n\n' "${GOAL}"
        printf '## Status\n'
        printf -- '- Iteration: %s/%s\n' "${ITERATION}" "${MAX_ITERATIONS}"
        printf -- '- Session restart: %s/%s\n' "${RESTART_COUNT:-0}" "${MAX_RESTARTS:-0}"
        printf -- '- Tests passing: %s\n' "${TEST_PASSED:-unknown}"
        printf -- '- Status: %s\n\n' "${STATUS:-running}"
        printf '## Recent Commits\n%s\n\n' "${recent_commits}"
        printf '## Changed Files\n%s\n\n' "${changed_files}"
        if [[ -n "$last_error" ]]; then
            printf '## Last Error\n%s\n\n' "$last_error"
        fi
        printf '## Timestamp\n%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > "$tmp_progress" 2>/dev/null
    mv "$tmp_progress" "$progress_file" 2>/dev/null || rm -f "$tmp_progress" 2>/dev/null
}

append_log_entry() {
    local entry="$1"
    if [[ -n "$LOG_ENTRIES" ]]; then
        LOG_ENTRIES="${LOG_ENTRIES}
${entry}"
    else
        LOG_ENTRIES="$entry"
    fi
}

# ─── Structured Build Loop Status ─────────────────────────────────────────────
# Writes a machine-readable JSON status file for dashboard and CLI consumption.
# Called after every iteration, at loop start (initial state), and at loop end.

write_build_loop_status() {
    local status_file="${LOG_DIR:-/tmp}/build_loop_status.json"
    local tmp_file="${status_file}.tmp.$$"

    # Compute files changed count from git
    local files_changed=0
    files_changed=$(git -C "${PROJECT_ROOT:-.}" diff --name-only HEAD~3 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    [[ "$files_changed" =~ ^[0-9]+$ ]] || files_changed=0

    # Compute elapsed time
    local elapsed=0
    if [[ -n "${START_EPOCH:-}" ]]; then
        local now_ep
        now_ep=$(date +%s)
        elapsed=$(( now_ep - START_EPOCH ))
    fi

    # Determine test status string
    local test_status="unknown"
    if [[ "${TEST_PASSED:-}" == "true" ]]; then
        test_status="passing"
    elif [[ "${TEST_PASSED:-}" == "false" ]]; then
        test_status="failing"
    fi

    # Context usage estimate (percentage of max iterations consumed)
    local context_pct=0
    if [[ "${MAX_ITERATIONS:-0}" -gt 0 ]]; then
        context_pct=$(( (ITERATION * 100) / MAX_ITERATIONS ))
        [[ "$context_pct" -gt 100 ]] && context_pct=100
    fi

    # Build JSON with jq if available, otherwise printf
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --argjson iteration "${ITERATION:-0}" \
            --argjson max_iterations "${MAX_ITERATIONS:-20}" \
            --arg status "${STATUS:-running}" \
            --arg test_status "$test_status" \
            --argjson test_pass_streak "${TEST_PASS_STREAK:-0}" \
            --argjson test_fail_streak "${CONSECUTIVE_FAILURES:-0}" \
            --argjson files_changed_count "$files_changed" \
            --argjson total_commits "${TOTAL_COMMITS:-0}" \
            --argjson context_usage_percent "$context_pct" \
            --argjson time_elapsed_s "$elapsed" \
            --argjson consecutive_low_progress "${CONSECUTIVE_FAILURES:-0}" \
            --arg model "${MODEL:-opus}" \
            --arg goal "${ORIGINAL_GOAL:-${GOAL:-}}" \
            --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            '{
                iteration: $iteration,
                max_iterations: $max_iterations,
                status: $status,
                test_status: $test_status,
                test_pass_streak: $test_pass_streak,
                test_fail_streak: $test_fail_streak,
                files_changed_count: $files_changed_count,
                total_commits: $total_commits,
                context_usage_percent: $context_usage_percent,
                time_elapsed_s: $time_elapsed_s,
                consecutive_low_progress: $consecutive_low_progress,
                model: $model,
                goal: $goal,
                timestamp: $timestamp
            }' > "$tmp_file" 2>/dev/null
    else
        # Fallback: manual JSON construction (Bash 3.2 safe)
        local goal_escaped
        goal_escaped=$(printf '%s' "${ORIGINAL_GOAL:-${GOAL:-}}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | head -c 500)
        printf '{
  "iteration": %d,
  "max_iterations": %d,
  "status": "%s",
  "test_status": "%s",
  "test_pass_streak": %d,
  "test_fail_streak": %d,
  "files_changed_count": %d,
  "total_commits": %d,
  "context_usage_percent": %d,
  "time_elapsed_s": %d,
  "consecutive_low_progress": %d,
  "model": "%s",
  "goal": "%s",
  "timestamp": "%s"
}\n' \
            "${ITERATION:-0}" "${MAX_ITERATIONS:-20}" "${STATUS:-running}" \
            "$test_status" "${TEST_PASS_STREAK:-0}" "${CONSECUTIVE_FAILURES:-0}" \
            "$files_changed" "${TOTAL_COMMITS:-0}" "$context_pct" \
            "$elapsed" "${CONSECUTIVE_FAILURES:-0}" "${MODEL:-opus}" \
            "$goal_escaped" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" > "$tmp_file" 2>/dev/null
    fi

    # Atomic move
    mv "$tmp_file" "$status_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
}

# ─── CLI Status Display ───────────────────────────────────────────────────────
# Shows build loop status for `shipwright loop status` command.

loop_show_status() {
    local json_mode=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_mode=true; shift ;;
            *) shift ;;
        esac
    done

    # Find the most recent build_loop_status.json
    local state_dir="${PROJECT_ROOT:-.}/.claude"
    local status_file=""
    local log_dir="${state_dir}/loop-logs"

    if [[ -f "$log_dir/build_loop_status.json" ]]; then
        status_file="$log_dir/build_loop_status.json"
    fi

    if [[ -z "$status_file" ]] || [[ ! -f "$status_file" ]]; then
        if $json_mode; then
            echo '{"error":"no_active_loop","message":"No active build loop found"}'
        else
            echo "No active build loop found."
        fi
        return 1
    fi

    if $json_mode; then
        cat "$status_file"
        return 0
    fi

    # Parse and display formatted output
    if ! command -v jq >/dev/null 2>&1; then
        cat "$status_file"
        return 0
    fi

    local data
    data=$(cat "$status_file" 2>/dev/null)
    [[ -z "$data" ]] && { echo "No active build loop found."; return 1; }

    local iter max_iter status test_status pass_streak fail_streak
    local files_changed commits context_pct elapsed model goal timestamp

    iter=$(echo "$data" | jq -r '.iteration // 0')
    max_iter=$(echo "$data" | jq -r '.max_iterations // 20')
    status=$(echo "$data" | jq -r '.status // "unknown"')
    test_status=$(echo "$data" | jq -r '.test_status // "unknown"')
    pass_streak=$(echo "$data" | jq -r '.test_pass_streak // 0')
    fail_streak=$(echo "$data" | jq -r '.test_fail_streak // 0')
    files_changed=$(echo "$data" | jq -r '.files_changed_count // 0')
    commits=$(echo "$data" | jq -r '.total_commits // 0')
    context_pct=$(echo "$data" | jq -r '.context_usage_percent // 0')
    elapsed=$(echo "$data" | jq -r '.time_elapsed_s // 0')
    model=$(echo "$data" | jq -r '.model // "unknown"')
    goal=$(echo "$data" | jq -r '.goal // ""' | head -c 80)
    timestamp=$(echo "$data" | jq -r '.timestamp // ""')

    # Check staleness (>5 min + running = stale)
    local stale=""
    if [[ "$status" == "running" ]] && [[ -n "$timestamp" ]]; then
        local ts_epoch now_ep
        # Parse ISO timestamp to epoch (portable)
        ts_epoch=$(date -d "$timestamp" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo 0)
        now_ep=$(date +%s)
        if [[ $(( now_ep - ts_epoch )) -gt 300 ]]; then
            stale=" (stale)"
        fi
    fi

    # Format elapsed time
    local elapsed_fmt
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    if [[ $mins -gt 0 ]]; then
        elapsed_fmt="${mins}m ${secs}s"
    else
        elapsed_fmt="${secs}s"
    fi

    # Progress bar (20 chars wide)
    local bar_width=20
    local filled=0
    if [[ "$max_iter" -gt 0 ]]; then
        filled=$(( (iter * bar_width) / max_iter ))
        [[ "$filled" -gt "$bar_width" ]] && filled="$bar_width"
    fi
    local empty=$(( bar_width - filled ))
    local bar=""
    local i=0
    while [[ $i -lt $filled ]]; do bar="${bar}█"; i=$((i+1)); done
    i=0
    while [[ $i -lt $empty ]]; do bar="${bar}░"; i=$((i+1)); done

    # Trend indicator
    local trend=""
    if [[ "$pass_streak" -ge 3 ]]; then
        trend="↑ improving"
    elif [[ "$fail_streak" -ge 2 ]]; then
        trend="↓ degrading"
    else
        trend="→ stable"
    fi

    # Status badge
    local status_badge="$status"
    case "$status" in
        running)   status_badge="● running${stale}" ;;
        complete)  status_badge="✓ complete" ;;
        diverging) status_badge="✗ diverging" ;;
        error)     status_badge="✗ error" ;;
        *)         status_badge="○ $status" ;;
    esac

    # Test badge
    local test_badge="$test_status"
    case "$test_status" in
        passing) test_badge="✓ passing (streak: $pass_streak)" ;;
        failing) test_badge="✗ failing (streak: $fail_streak)" ;;
        unknown) test_badge="○ not run" ;;
    esac

    echo ""
    echo "  Build Loop Status"
    echo "  ─────────────────────────────────────"
    echo "  Goal:       ${goal}..."
    echo "  Status:     ${status_badge}"
    echo "  Progress:   ${bar} ${iter}/${max_iter}"
    echo "  Tests:      ${test_badge}"
    echo "  Trend:      ${trend}"
    echo "  Files:      ${files_changed} changed"
    echo "  Commits:    ${commits}"
    echo "  Elapsed:    ${elapsed_fmt}"
    echo "  Model:      ${model}"
    echo "  Context:    ${context_pct}%"
    echo "  Updated:    ${timestamp}"
    echo ""
}
