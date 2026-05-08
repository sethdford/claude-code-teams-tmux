#!/usr/bin/env bash
# loop-waste-detector.sh — Iteration waste & stuck-loop detection layer.
#
# Wraps the existing detect_stuckness() with config-driven thresholds and
# adds new signals: circular file edits, semantic similarity, zero progress.
# Emits the canonical waste_detected event and writes waste-report.json on
# early termination.
#
# Globals set by waste_detect():
#   WASTE_DETECTED       — "true" / "false"
#   WASTE_REASONS        — comma-separated reason tokens
#   WASTE_CONSECUTIVE    — running count of consecutive waste iterations
#   WASTE_CIRCULAR_FILES — comma-separated file paths
#   WASTE_DIFF_LINES     — last measured git-diff size
#   WASTE_SIMILARITY_PCT — last measured semantic similarity %
#
# Bash 3.2 compatible.

[[ -n "${_LOOP_WASTE_LOADED:-}" ]] && return 0
_LOOP_WASTE_LOADED=1

WASTE_DETECTOR_VERSION="1.0.0"

# Config defaults — overridable via daemon-config.json loop.* or SW_LOOP_*
_WASTE_DEFAULT_ENABLED=1
_WASTE_DEFAULT_MIN_PROGRESS=5
_WASTE_DEFAULT_CIRCULAR_WINDOW=4
_WASTE_DEFAULT_SEMANTIC_PCT=90
_WASTE_DEFAULT_TERMINATION_THRESHOLD=3
_WASTE_DEFAULT_AVG_ITER_COST_USD="0.50"

# Globals — initialised once, mutated by waste_detect()
WASTE_DETECTED="false"
WASTE_REASONS=""
WASTE_CONSECUTIVE=0
WASTE_CIRCULAR_FILES=""
WASTE_DIFF_LINES=0
WASTE_SIMILARITY_PCT=0

# ─── Init ─────────────────────────────────────────────────────────────────────

waste_detector_init() {
    local log_dir="${LOG_DIR:-${PROJECT_ROOT:-.}/.claude/loop-logs}"
    mkdir -p "$log_dir" 2>/dev/null || true
    WASTE_FILE_HISTORY="${log_dir}/waste-file-history-${AGENT_NUM:-1}.txt"
    : > "$WASTE_FILE_HISTORY" 2>/dev/null || true

    WASTE_DETECTION_ENABLED="$(_smart_int "loop.waste_detection_enabled" "$_WASTE_DEFAULT_ENABLED" 2>/dev/null || echo "$_WASTE_DEFAULT_ENABLED")"
    WASTE_MIN_PROGRESS="$(_smart_int "loop.min_progress_threshold" "$_WASTE_DEFAULT_MIN_PROGRESS" 2>/dev/null || echo "$_WASTE_DEFAULT_MIN_PROGRESS")"
    WASTE_CIRCULAR_WINDOW="$(_smart_int "loop.circular_edit_window" "$_WASTE_DEFAULT_CIRCULAR_WINDOW" 2>/dev/null || echo "$_WASTE_DEFAULT_CIRCULAR_WINDOW")"
    WASTE_SEMANTIC_PCT="$(_smart_int "loop.semantic_similarity_threshold" "$_WASTE_DEFAULT_SEMANTIC_PCT" 2>/dev/null || echo "$_WASTE_DEFAULT_SEMANTIC_PCT")"
    WASTE_TERMINATION_THRESHOLD="$(_smart_int "loop.waste_termination_threshold" "$_WASTE_DEFAULT_TERMINATION_THRESHOLD" 2>/dev/null || echo "$_WASTE_DEFAULT_TERMINATION_THRESHOLD")"

    WASTE_DETECTED="false"
    WASTE_REASONS=""
    WASTE_CONSECUTIVE=0
    WASTE_CIRCULAR_FILES=""
    WASTE_DIFF_LINES=0
    WASTE_SIMILARITY_PCT=0
}

# ─── File-edit history ────────────────────────────────────────────────────────

# waste_record_file_edits <iteration>
# Append "iter|file1,file2,..." line for the most recent commit.
waste_record_file_edits() {
    local iter="${1:-0}"
    [[ -z "${WASTE_FILE_HISTORY:-}" ]] && return 0
    local files
    files="$(git -C "${PROJECT_ROOT:-.}" diff --name-only HEAD~1 HEAD 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
    echo "${iter}|${files}" >> "$WASTE_FILE_HISTORY" 2>/dev/null || true
}

# waste_detect_circular_edits
# Scans the last $WASTE_CIRCULAR_WINDOW lines of WASTE_FILE_HISTORY for files
# appearing in 3+ iterations within the window. Sets WASTE_CIRCULAR_FILES.
# Returns 0 when circular pattern detected, 1 otherwise.
waste_detect_circular_edits() {
    WASTE_CIRCULAR_FILES=""
    [[ -f "${WASTE_FILE_HISTORY:-}" ]] || return 1
    local window="${WASTE_CIRCULAR_WINDOW:-$_WASTE_DEFAULT_CIRCULAR_WINDOW}"
    local lines
    lines=$(wc -l < "$WASTE_FILE_HISTORY" 2>/dev/null | tr -d ' ' || echo 0)
    [[ "${lines:-0}" -lt "$window" ]] && return 1

    # Extract all file paths from the window, count occurrences, keep those >= 3
    local circulars
    circulars=$(tail -n "$window" "$WASTE_FILE_HISTORY" 2>/dev/null \
        | cut -d'|' -f2 \
        | tr ',' '\n' \
        | grep -v '^$' \
        | sort \
        | uniq -c \
        | awk '$1 >= 3 { sub(/^[ \t]+[0-9]+[ \t]+/, ""); print }' \
        | head -10 \
        | tr '\n' ',' \
        | sed 's/,$//' || true)

    if [[ -n "$circulars" ]]; then
        WASTE_CIRCULAR_FILES="$circulars"
        return 0
    fi
    return 1
}

# ─── Semantic similarity ──────────────────────────────────────────────────────

# waste_detect_semantic_dup <iteration>
# Returns 0 when overlap pct between iter-1 and iter-2 logs >= threshold.
waste_detect_semantic_dup() {
    local iter="${1:-0}"
    WASTE_SIMILARITY_PCT=0
    [[ "$iter" -ge 3 ]] || return 1
    local log_dir="${LOG_DIR:-}"
    [[ -z "$log_dir" ]] && return 1
    local log1="$log_dir/iteration-$(( iter - 1 )).log"
    local log2="$log_dir/iteration-$(( iter - 2 )).log"
    [[ -f "$log1" && -f "$log2" ]] || return 1

    local lines1 lines2 total common pct
    lines1=$(tail -50 "$log1" 2>/dev/null | grep -v '^$' | sort || true)
    lines2=$(tail -50 "$log2" 2>/dev/null | grep -v '^$' | sort || true)
    [[ -n "$lines1" && -n "$lines2" ]] || return 1

    total=$(echo "$lines1" | wc -l | tr -d ' ')
    common=$(comm -12 <(echo "$lines1") <(echo "$lines2") 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    common="${common:-0}"
    if [[ "${total:-0}" -gt 0 ]]; then
        pct=$(( common * 100 / total ))
    else
        pct=0
    fi
    WASTE_SIMILARITY_PCT="$pct"
    local threshold="${WASTE_SEMANTIC_PCT:-$_WASTE_DEFAULT_SEMANTIC_PCT}"
    [[ "$pct" -ge "$threshold" ]] && return 0
    return 1
}

# ─── Zero-progress signal ─────────────────────────────────────────────────────

# waste_detect_zero_progress
# Returns 0 when the working-tree diff is below min_progress_threshold.
waste_detect_zero_progress() {
    local diff_out diff_lines
    diff_out="$(git -C "${PROJECT_ROOT:-.}" diff HEAD 2>/dev/null || true)"
    diff_lines=$(printf '%s' "$diff_out" | wc -l | tr -d ' ')
    diff_lines="${diff_lines:-0}"
    [[ "$diff_lines" =~ ^[0-9]+$ ]] || diff_lines=0
    WASTE_DIFF_LINES="$diff_lines"
    local threshold="${WASTE_MIN_PROGRESS:-$_WASTE_DEFAULT_MIN_PROGRESS}"
    [[ "$diff_lines" -lt "$threshold" ]] && return 0
    return 1
}

# ─── Cost estimation ──────────────────────────────────────────────────────────

# waste_estimate_cost_saved
# Echoes USD estimate as a float string.
waste_estimate_cost_saved() {
    local iter="${ITERATION:-0}"
    local max="${MAX_ITERATIONS:-20}"
    local remaining=$(( max > iter ? max - iter : 0 ))
    local avg
    avg="${SW_LOOP_AVG_ITER_COST_USD:-$_WASTE_DEFAULT_AVG_ITER_COST_USD}"
    awk -v r="$remaining" -v a="$avg" 'BEGIN { printf "%.2f", r * a }'
}

# ─── Orchestrator ─────────────────────────────────────────────────────────────

# waste_detect <iteration>
# Returns 0 when waste detected for this iteration, 1 otherwise.
# Updates WASTE_* globals and emits waste_detected event when triggered.
waste_detect() {
    local iter="${1:-${ITERATION:-0}}"
    WASTE_DETECTED="false"
    WASTE_REASONS=""

    if [[ "${WASTE_DETECTION_ENABLED:-1}" != "1" ]]; then
        return 1
    fi

    local reasons=()
    local signals=0

    if waste_detect_zero_progress; then
        reasons+=("zero_progress")
        signals=$((signals + 1))
    fi

    if waste_detect_circular_edits; then
        reasons+=("circular_edits")
        signals=$((signals + 1))
    fi

    if waste_detect_semantic_dup "$iter"; then
        reasons+=("semantic_dup_${WASTE_SIMILARITY_PCT}pct")
        signals=$((signals + 1))
    fi

    # Defer to legacy detect_stuckness when available — reuses 7 existing signals
    if type detect_stuckness >/dev/null 2>&1; then
        local stuck_out
        stuck_out="$(detect_stuckness 2>/dev/null || true)"
        if [[ -n "$stuck_out" ]]; then
            reasons+=("stuckness_signals")
            signals=$((signals + 1))
        fi
    fi

    if [[ "$signals" -ge 1 ]]; then
        WASTE_DETECTED="true"
        WASTE_CONSECUTIVE=$(( WASTE_CONSECUTIVE + 1 ))
        local IFS=','
        WASTE_REASONS="${reasons[*]}"
        unset IFS
        if type emit_event >/dev/null 2>&1; then
            local cost
            cost="$(waste_estimate_cost_saved)"
            emit_event "waste_detected" \
                "iteration=$iter" \
                "consecutive_waste=$WASTE_CONSECUTIVE" \
                "signals=$signals" \
                "reasons=$WASTE_REASONS" \
                "files_circular=$WASTE_CIRCULAR_FILES" \
                "similarity_pct=$WASTE_SIMILARITY_PCT" \
                "diff_lines=$WASTE_DIFF_LINES" \
                "estimated_cost_saved_usd=$cost"
        fi
        return 0
    fi

    # No waste this iteration — reset streak
    WASTE_CONSECUTIVE=0
    return 1
}

# ─── Report writer ────────────────────────────────────────────────────────────

# waste_write_report <iteration>
# Atomic write of waste-report.json.
waste_write_report() {
    local iter="${1:-${ITERATION:-0}}"
    local artifacts_dir="${ARTIFACTS_DIR:-${PROJECT_ROOT:-.}/.claude/pipeline-artifacts}"
    mkdir -p "$artifacts_dir" 2>/dev/null || true
    local report="$artifacts_dir/waste-report.json"
    local tmp="${report}.tmp.$$"

    local cost reasons_json circ_json
    cost="$(waste_estimate_cost_saved)"
    reasons_json=$(printf '%s' "${WASTE_REASONS:-}" | tr ',' '\n' | grep -v '^$' \
        | jq -R . | jq -s . 2>/dev/null || echo '[]')
    circ_json=$(printf '%s' "${WASTE_CIRCULAR_FILES:-}" | tr ',' '\n' | grep -v '^$' \
        | jq -R . | jq -s . 2>/dev/null || echo '[]')

    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"

    jq -n \
        --arg version "$WASTE_DETECTOR_VERSION" \
        --arg terminated_at "$now" \
        --argjson iteration "${iter:-0}" \
        --argjson max_iterations "${MAX_ITERATIONS:-0}" \
        --argjson consecutive "${WASTE_CONSECUTIVE:-0}" \
        --argjson diff_lines "${WASTE_DIFF_LINES:-0}" \
        --argjson similarity_pct "${WASTE_SIMILARITY_PCT:-0}" \
        --argjson reasons "$reasons_json" \
        --argjson circular_files "$circ_json" \
        --arg cost "$cost" \
        '{
            version: $version,
            terminated_at: $terminated_at,
            iteration: $iteration,
            max_iterations: $max_iterations,
            consecutive_waste_iterations: $consecutive,
            reasons: $reasons,
            circular_files: $circular_files,
            last_diff_lines: $diff_lines,
            last_similarity_pct: $similarity_pct,
            estimated_cost_saved_usd: ($cost | tonumber),
            recommendations: [
                "Review the failing test output and try a fundamentally different approach",
                "Inspect the circular files for edit-and-revert oscillation",
                "Consider increasing min_progress_threshold or investigating root cause"
            ]
        }' > "$tmp" 2>/dev/null && mv "$tmp" "$report" || rm -f "$tmp"

    echo "$report"
}

# waste_should_terminate
# Returns 0 when consecutive waste iterations meet termination threshold.
waste_should_terminate() {
    local threshold="${WASTE_TERMINATION_THRESHOLD:-$_WASTE_DEFAULT_TERMINATION_THRESHOLD}"
    [[ "${WASTE_CONSECUTIVE:-0}" -ge "$threshold" ]]
}
