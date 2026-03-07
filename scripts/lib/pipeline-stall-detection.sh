#!/usr/bin/env bash
# Pipeline Stall Detection & Auto-Abort
# Single-responsibility module: abort decision + diagnostics + memory save
# Sourced by sw-loop.sh alongside loop-convergence.sh
[[ -n "${_PIPELINE_STALL_DETECTION_LOADED:-}" ]] && return 0
_PIPELINE_STALL_DETECTION_LOADED=1

# ─── Core Detection (pure computation, no side effects) ─────────────────────

# stall_compute_score <tracking_file> <error_log> <iteration> <max_iterations>
# Returns 0-100 stall score on stdout. Returns 0 on any error (fail-open).
stall_compute_score() {
    local tracking_file="${1:-}"
    local error_log="${2:-}"
    local iteration="${3:-0}"
    local max_iterations="${4:-20}"
    local score=0

    # Guard: too early to judge (first 3 iterations are setup/analysis)
    if [[ "$iteration" -lt 4 ]]; then
        echo "0"
        return 0
    fi

    # Signal 1: Consecutive zero-change iterations (weight: 30, threshold: 3)
    if [[ -f "$tracking_file" ]]; then
        local line_count
        line_count=$(wc -l < "$tracking_file" 2>/dev/null || echo "0")
        line_count=$(echo "$line_count" | tr -d ' ')
        if [[ "$line_count" -ge 3 ]]; then
            local last_three_diffs
            last_three_diffs=$(tail -3 "$tracking_file" 2>/dev/null | cut -d'|' -f1 || true)
            local unique_diffs
            unique_diffs=$(echo "$last_three_diffs" | sort -u | grep -v '^$' | wc -l | tr -d ' ')
            if [[ "$unique_diffs" -le 1 ]] && [[ -n "$last_three_diffs" ]]; then
                score=$((score + 30))
            fi
        fi
    fi

    # Signal 2: Identical error hash repetition (weight: 30, threshold: 5 or 3 with same diff)
    if [[ -f "$tracking_file" ]]; then
        local line_count2
        line_count2=$(wc -l < "$tracking_file" 2>/dev/null || echo "0")
        line_count2=$(echo "$line_count2" | tr -d ' ')
        if [[ "$line_count2" -ge 5 ]]; then
            local last_five_errors
            last_five_errors=$(tail -5 "$tracking_file" 2>/dev/null | cut -d'|' -f2 || true)
            local unique_errors
            unique_errors=$(echo "$last_five_errors" | sort -u | grep -v '^none$' | grep -v '^$' | wc -l | tr -d ' ')
            if [[ "$unique_errors" -eq 1 ]] && [[ -n "$(echo "$last_five_errors" | grep -v '^none$' | head -1)" ]]; then
                score=$((score + 30))
            fi
        elif [[ "$line_count2" -ge 3 ]]; then
            # Relaxed: 3 identical errors + 3 identical diffs = strong deadlock signal
            local last_three_errors
            last_three_errors=$(tail -3 "$tracking_file" 2>/dev/null | cut -d'|' -f2 || true)
            local unique_err3
            unique_err3=$(echo "$last_three_errors" | sort -u | grep -v '^none$' | grep -v '^$' | wc -l | tr -d ' ')
            local last_three_d
            last_three_d=$(tail -3 "$tracking_file" 2>/dev/null | cut -d'|' -f1 || true)
            local unique_d3
            unique_d3=$(echo "$last_three_d" | sort -u | grep -v '^$' | wc -l | tr -d ' ')
            if [[ "$unique_err3" -eq 1 ]] && [[ "$unique_d3" -le 1 ]] \
                && [[ -n "$(echo "$last_three_errors" | grep -v '^none$' | head -1)" ]]; then
                score=$((score + 30))
            fi
        fi
    fi

    # Signal 3: Test pass count stagnation (weight: 20) — check error-log for repeated patterns
    if [[ -f "$error_log" ]]; then
        local recent_errors
        recent_errors=$(tail -8 "$error_log" 2>/dev/null | jq -r '.error // .message // .error_hash // empty' 2>/dev/null | sort || true)
        if [[ -n "$recent_errors" ]]; then
            local total_recent unique_recent
            total_recent=$(echo "$recent_errors" | wc -l | tr -d ' ')
            unique_recent=$(echo "$recent_errors" | sort -u | wc -l | tr -d ' ')
            # If < 30% of recent errors are unique, it's a repetition pattern
            if [[ "$total_recent" -ge 4 ]] && [[ "$unique_recent" -le 1 ]]; then
                score=$((score + 20))
            fi
        fi
    fi

    # Signal 4: Circular git diff hashes (weight: 20) — A-B-A-B pattern
    if [[ -f "$tracking_file" ]]; then
        local line_count4
        line_count4=$(wc -l < "$tracking_file" 2>/dev/null || echo "0")
        line_count4=$(echo "$line_count4" | tr -d ' ')
        if [[ "$line_count4" -ge 4 ]]; then
            local last_four
            last_four=$(tail -4 "$tracking_file" 2>/dev/null | cut -d'|' -f1 || true)
            # Check for A-B-A-B or A-A-A-A pattern
            local h1 h2 h3 h4
            h1=$(echo "$last_four" | sed -n '1p')
            h2=$(echo "$last_four" | sed -n '2p')
            h3=$(echo "$last_four" | sed -n '3p')
            h4=$(echo "$last_four" | sed -n '4p')
            if [[ "$h1" == "$h3" ]] && [[ "$h2" == "$h4" ]] && [[ -n "$h1" ]]; then
                score=$((score + 20))
            fi
        fi
    fi

    # Cap at 100
    if [[ "$score" -gt 100 ]]; then
        score=100
    fi

    echo "$score"
    return 0
}

# stall_should_abort <score> <test_passed> <quality_passed>
# Exit 0 = abort, exit 1 = don't abort
# INVARIANT: Never abort when tests are passing
# INVARIANT: Never abort when score < 70
stall_should_abort() {
    local score="${1:-0}"
    local test_passed="${2:-false}"
    local quality_passed="${3:-false}"

    # Validate score is numeric
    if ! [[ "$score" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Never abort when tests pass
    if [[ "$test_passed" == "true" ]]; then
        return 1
    fi

    # Threshold check
    if [[ "$score" -ge 70 ]]; then
        return 0
    fi

    return 1
}

# stall_build_diagnostics <tracking_file> <error_log> <log_dir> <iteration>
# Outputs JSON diagnostics to stdout
stall_build_diagnostics() {
    local tracking_file="${1:-}"
    local error_log="${2:-}"
    local log_dir="${3:-}"
    local iteration="${4:-0}"

    # Determine stall type
    local stall_type="unknown"
    local iterations_stuck=0
    local repeated_error="null"

    if [[ -f "$tracking_file" ]]; then
        # Count consecutive identical diff hashes from the end
        local all_diffs
        all_diffs=$(cut -d'|' -f1 < "$tracking_file" 2>/dev/null || true)
        if [[ -n "$all_diffs" ]]; then
            local last_hash
            last_hash=$(echo "$all_diffs" | tail -1)
            local count=0
            while IFS= read -r h; do
                if [[ "$h" == "$last_hash" ]]; then
                    count=$((count + 1))
                else
                    break
                fi
            done < <(echo "$all_diffs" | tac 2>/dev/null || echo "$all_diffs" | tail -r 2>/dev/null || echo "$all_diffs")
            iterations_stuck=$count
        fi

        # Check error repetition
        local all_errs
        all_errs=$(cut -d'|' -f2 < "$tracking_file" 2>/dev/null | grep -v '^none$' || true)
        if [[ -n "$all_errs" ]]; then
            local last_err
            last_err=$(echo "$all_errs" | tail -1)
            local err_count=0
            while IFS= read -r e; do
                if [[ "$e" == "$last_err" ]]; then
                    err_count=$((err_count + 1))
                else
                    break
                fi
            done < <(echo "$all_errs" | tac 2>/dev/null || echo "$all_errs" | tail -r 2>/dev/null || echo "$all_errs")

            if [[ "$err_count" -ge 5 ]]; then
                stall_type="error_loop"
            elif [[ "$iterations_stuck" -ge 3 ]] && [[ "$err_count" -ge 3 ]]; then
                stall_type="deadlock"
            fi
        fi

        if [[ "$stall_type" == "unknown" ]] && [[ "$iterations_stuck" -ge 3 ]]; then
            stall_type="zero_changes"
        fi
    fi

    # Extract repeated error text from error-log
    if [[ -f "$error_log" ]]; then
        local rep_err
        rep_err=$(tail -5 "$error_log" 2>/dev/null \
            | jq -r '.error // .message // empty' 2>/dev/null \
            | sort | uniq -c | sort -rn | head -1 \
            | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//' || true)
        if [[ -n "$rep_err" ]]; then
            repeated_error="$rep_err"
        fi
    fi

    # Files attempted (from git log of recent iterations)
    local files_attempted="[]"
    local project_root="${PROJECT_ROOT:-.}"
    local recent_files
    recent_files=$(git -C "$project_root" diff --name-only HEAD~3 HEAD 2>/dev/null | head -20 || true)
    if [[ -n "$recent_files" ]]; then
        files_attempted=$(echo "$recent_files" | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo "[]")
    fi

    # Compute score for diagnostics
    local stall_score
    stall_score=$(stall_compute_score "$tracking_file" "$error_log" "$iteration" "${MAX_ITERATIONS:-20}")

    # Suggested recovery
    local recovery="[]"
    case "$stall_type" in
        zero_changes)
            recovery='["Break the problem into smaller sub-tasks","Check if a dependency or configuration issue is blocking progress","Try a completely different implementation approach"]'
            ;;
        error_loop)
            recovery='["Read the error message carefully — the root cause may differ from your assumption","Check if the test environment itself is misconfigured","Try isolating the failing test and running it independently"]'
            ;;
        deadlock)
            recovery='["The agent is alternating between two states — manual intervention needed","Review the error pattern and suggest a new approach in the issue","Consider decomposing this issue into smaller sub-issues"]'
            ;;
        *)
            recovery='["Review pipeline logs for clues","Try a different approach or decompose the task"]'
            ;;
    esac

    # Build JSON with jq for proper escaping
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg st "$stall_type" \
            --argjson is "$iterations_stuck" \
            --argjson ss "$stall_score" \
            --arg re "$repeated_error" \
            --argjson fa "$files_attempted" \
            --argjson sr "$recovery" \
            '{
                stall_type: $st,
                iterations_stuck: $is,
                stall_score: $ss,
                repeated_error: (if $re == "null" then null else $re end),
                files_attempted: $fa,
                suggested_recovery: $sr
            }'
    else
        echo '{"stall_type":"unknown"}'
    fi
}

# ─── Orchestrator (has side effects) ────────────────────────────────────────

# stall_check_and_abort <tracking_file> <error_log> <log_dir> <iteration>
#                        <max_iter> <test_passed> <quality_passed>
# Exit 0 = abort, exit 1 = continue
stall_check_and_abort() {
    local tracking_file="${1:-}"
    local error_log="${2:-}"
    local log_dir="${3:-}"
    local iteration="${4:-0}"
    local max_iter="${5:-20}"
    local test_passed="${6:-false}"
    local quality_passed="${7:-false}"

    # Compute score (fail-open on error)
    local score
    score=$(stall_compute_score "$tracking_file" "$error_log" "$iteration" "$max_iter" 2>/dev/null) || score=0
    if ! [[ "$score" =~ ^[0-9]+$ ]]; then
        score=0
    fi

    # Emit detection event when score > 0
    if [[ "$score" -gt 0 ]]; then
        if type emit_event >/dev/null 2>&1; then
            emit_event "stall.detect" "score=$score" "iteration=$iteration" "test_passed=$test_passed"
        fi
    fi

    # Should we abort?
    if ! stall_should_abort "$score" "$test_passed" "$quality_passed"; then
        return 1
    fi

    # ── Abort path: build diagnostics, save to memory, emit event ──
    local diagnostics
    diagnostics=$(stall_build_diagnostics "$tracking_file" "$error_log" "$log_dir" "$iteration" 2>/dev/null) || diagnostics='{"stall_type":"unknown"}'

    # Write diagnostics file
    if [[ -n "$log_dir" ]]; then
        local tmp_diag
        tmp_diag=$(mktemp "${log_dir}/stall-diag.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/stall-diag.XXXXXX")
        echo "$diagnostics" > "$tmp_diag"
        mv "$tmp_diag" "$log_dir/stall-diagnostics.json" 2>/dev/null || true
    fi

    # Save to memory
    stall_save_to_memory "$diagnostics" 2>/dev/null || true

    # Emit abort event
    local stall_type
    stall_type=$(echo "$diagnostics" | jq -r '.stall_type // "unknown"' 2>/dev/null || echo "unknown")
    if type emit_event >/dev/null 2>&1; then
        emit_event "stall.abort" "score=$score" "iteration=$iteration" "stall_type=$stall_type" "test_passed=$test_passed"
    fi

    return 0
}

# stall_save_to_memory <diagnostics_json>
# Delegates to memory_capture_failure with stage="stall_deadlock"
stall_save_to_memory() {
    local diagnostics="${1:-}"
    if [[ -z "$diagnostics" ]]; then
        return 0
    fi

    local summary
    summary=$(echo "$diagnostics" | jq -r '
        "Stall type: \(.stall_type), iterations stuck: \(.iterations_stuck), score: \(.stall_score)" +
        (if .repeated_error then ", error: \(.repeated_error)" else "" end)
    ' 2>/dev/null || echo "Stall detected (details unavailable)")

    if type memory_capture_failure >/dev/null 2>&1; then
        memory_capture_failure "stall_deadlock" "$summary" || true
    fi
}

# stall_get_statistics
# Reads events.jsonl for stall.* events. Outputs JSON summary.
stall_get_statistics() {
    local events_file="${HOME}/.shipwright/events.jsonl"
    if [[ ! -f "$events_file" ]]; then
        echo '{"total_stalls":0,"total_aborts":0,"avg_iterations_before_abort":0,"common_stall_types":{}}'
        return 0
    fi

    local total_stalls total_aborts
    total_stalls=$(grep -c '"stall\.detect"' "$events_file" 2>/dev/null || echo "0")
    total_aborts=$(grep -c '"stall\.abort"' "$events_file" 2>/dev/null || echo "0")

    local avg_iter=0
    if [[ "$total_aborts" -gt 0 ]]; then
        local iter_sum
        iter_sum=$(grep '"stall\.abort"' "$events_file" 2>/dev/null \
            | jq -r '.iteration // "0"' 2>/dev/null \
            | awk '{s+=$1} END {print s+0}' || echo "0")
        if [[ "$total_aborts" -gt 0 ]] && [[ "$iter_sum" -gt 0 ]]; then
            avg_iter=$((iter_sum / total_aborts))
        fi
    fi

    local stall_types="{}"
    if [[ "$total_aborts" -gt 0 ]]; then
        stall_types=$(grep '"stall\.abort"' "$events_file" 2>/dev/null \
            | jq -r '.stall_type // "unknown"' 2>/dev/null \
            | sort | uniq -c | sort -rn \
            | awk '{printf "%s\"%s\":%d", (NR>1?",":""), $2, $1}' \
            | awk '{print "{"$0"}"}' || echo "{}")
        if [[ -z "$stall_types" ]] || [[ "$stall_types" == "{}" ]]; then
            stall_types="{}"
        fi
    fi

    jq -n \
        --argjson ts "$total_stalls" \
        --argjson ta "$total_aborts" \
        --argjson ai "$avg_iter" \
        --argjson ct "$stall_types" \
        '{total_stalls:$ts, total_aborts:$ta, avg_iterations_before_abort:$ai, common_stall_types:$ct}'
}
