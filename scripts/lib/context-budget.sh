#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright context-budget — Context Window Budget Monitor                ║
# ║  Proactive tracking and auto-summarization to prevent context blowout     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard
[[ -n "${_CONTEXT_BUDGET_LOADED:-}" ]] && return 0
_CONTEXT_BUDGET_LOADED=1

# ─── Initialization ──────────────────────────────────────────────────────────

context_budget_init() {
    local total_budget="${1:-800000}"
    local artifacts_dir="${2:-./.claude/pipeline-artifacts}"

    # Create artifacts dir if needed
    mkdir -p "$artifacts_dir" 2>/dev/null || true

    # Calculate reserves
    local system_reserve=$(( total_budget / 10 ))        # 10% for system prompt
    local tools_reserve=$(( total_budget / 10 ))         # 10% for tool defs
    local working_memory=$(( total_budget * 6 / 10 ))    # 60% for working memory
    local output_reserve=$(( total_budget / 5 ))         # 20% for output

    # Build JSON config
    local config_json
    config_json=$(cat <<EOF
{
  "total_budget": $total_budget,
  "system_reserve": $system_reserve,
  "tools_reserve": $tools_reserve,
  "working_memory": $working_memory,
  "output_reserve": $output_reserve,
  "initialized_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "iterations_tracked": 0
}
EOF
)

    # Write atomically
    local tmp_file
    tmp_file=$(mktemp "$artifacts_dir/context-budget.json.tmp.XXXXXX" 2>/dev/null) || tmp_file="/tmp/context-budget-$$.tmp"
    echo "$config_json" > "$tmp_file" 2>/dev/null
    mv "$tmp_file" "$artifacts_dir/context-budget.json" 2>/dev/null || return 1

    return 0
}

# ─── Token Estimation ────────────────────────────────────────────────────────

context_budget_estimate() {
    local prompt_content="${1:-}"
    local context_dir="${2:-./.claude/pipeline-artifacts}"

    # Estimate tokens from prompt (rough: chars / 4 = tokens)
    local prompt_chars=${#prompt_content}
    local prompt_tokens=$(( (prompt_chars + 3) / 4 ))

    # Count context injections from various sources
    local context_tokens=0
    local injected_tokens=0

    # Count memory context if present
    if [[ -f "$context_dir/iteration-summaries.json" ]]; then
        local mem_chars
        mem_chars=$(wc -c < "$context_dir/iteration-summaries.json" 2>/dev/null || echo 0)
        context_tokens=$(( context_tokens + mem_chars / 4 ))
    fi

    # Count progress.md
    if [[ -f "$context_dir/progress.md" ]]; then
        local prog_chars
        prog_chars=$(wc -c < "$context_dir/progress.md" 2>/dev/null || echo 0)
        injected_tokens=$(( injected_tokens + prog_chars / 4 ))
    fi

    # Count error summaries
    if [[ -f "$context_dir/error-summary.json" ]]; then
        local err_chars
        err_chars=$(wc -c < "$context_dir/error-summary.json" 2>/dev/null || echo 0)
        injected_tokens=$(( injected_tokens + err_chars / 4 ))
    fi

    # Load budget config
    local total_budget=800000
    if [[ -f "$context_dir/context-budget.json" ]] && command -v jq >/dev/null 2>&1; then
        total_budget=$(jq -r '.total_budget // 800000' "$context_dir/context-budget.json" 2>/dev/null || echo 800000)
    fi

    local total_used=$(( prompt_tokens + context_tokens + injected_tokens ))
    local remaining=$(( total_budget - total_used ))

    # Build estimate JSON
    cat <<EOF
{
  "prompt_tokens": $prompt_tokens,
  "context_tokens": $context_tokens,
  "injected_tokens": $injected_tokens,
  "total_used": $total_used,
  "remaining_tokens": $remaining,
  "budget": $total_budget,
  "utilization_percent": $(( (total_used * 100) / total_budget ))
}
EOF
}

# ─── Status Checking ────────────────────────────────────────────────────────

context_budget_check() {
    local estimate="${1:-}"

    if [[ -z "$estimate" ]]; then
        echo "{\"status\":\"error\",\"message\":\"No estimate provided\"}"
        return 1
    fi

    local utilization
    utilization=$(echo "$estimate" | jq -r '.utilization_percent // 0' 2>/dev/null || echo 0)

    local status="green"
    local action="continue"
    local message="Context usage normal"

    if [[ "$utilization" -ge 90 ]]; then
        status="critical"
        action="restart_session"
        message="Context at critical level — prepare for session restart"
    elif [[ "$utilization" -ge 80 ]]; then
        status="red"
        action="aggressive_trim"
        message="Context usage high — trim non-essential context"
    elif [[ "$utilization" -ge 60 ]]; then
        status="yellow"
        action="trim"
        message="Context usage moderate — begin trimming"
    fi

    cat <<EOF
{
  "status": "$status",
  "utilization_percent": $utilization,
  "action": "$action",
  "message": "$message",
  "estimate": $estimate
}
EOF
}

# ─── Context Trimming ────────────────────────────────────────────────────────

context_budget_trim() {
    local content="${1:-}"
    local status="${2:-green}"
    local max_size="${3:-100000}"

    local trimmed="$content"

    # Green: no trimming
    if [[ "$status" == "green" ]]; then
        echo "$trimmed"
        return 0
    fi

    # Yellow: remove duplicate errors, truncate memory
    if [[ "$status" == "yellow" ]]; then
        # Remove duplicate error lines (keep latest only)
        trimmed=$(echo "$trimmed" | awk '
            /Error:|ERROR:/{
                if (seen[$0]) next
                seen[$0] = 1
            }
            {print}
        ')

        # Truncate memory section to first 20K chars
        trimmed=$(echo "$trimmed" | awk '
            /## Memory Context/{mem=1; chars=0; print; next}
            mem && /^## [^#]/{mem=0; print; next}
            mem{chars+=length($0)+1; if(chars>20000){print "... (memory truncated)"; mem=0; next}}
            {print}
        ')
    fi

    # Red: aggressive trimming
    if [[ "$status" == "red" ]]; then
        # Remove DORA/performance baselines
        trimmed=$(echo "$trimmed" | awk '/^## Performance Baselines/{skip=1; next} skip && /^## [^#]/{skip=0} !skip{print}')

        # Remove old git log entries (keep last 5)
        trimmed=$(echo "$trimmed" | awk '/^## Recent Git Activity/{p=1; c=0; next} p && /^## [^#]/{p=0; next} p{c++; if(c>5) next} {print}')

        # Remove file hotspots (keep last 3)
        trimmed=$(echo "$trimmed" | awk '/^## File Hotspots/{p=1; c=0; next} p && /^## [^#]/{p=0; next} p{c++; if(c>3) next} {print}')

        # Truncate memory to first 10K chars
        trimmed=$(echo "$trimmed" | awk '
            /## Memory Context/{mem=1; chars=0; print; next}
            mem && /^## [^#]/{mem=0; print; next}
            mem{chars+=length($0)+1; if(chars>10000){print "... (memory heavily truncated)"; mem=0; next}}
            {print}
        ')

        # Truncate test output to last 30 lines
        trimmed=$(echo "$trimmed" | awk '
            /^## Test Results/{found=1; buf=""; print; next}
            found && /^## [^#]/{found=0; n=split(buf,arr,"\n"); start=(n>30)?(n-29):1; for(i=start;i<=n;i++) if(arr[i]!="") print arr[i]; print; next}
            found{buf=buf $0 "\n"; next}
            {print}
        ')
    fi

    # Critical: hard truncate if still over budget
    if [[ "${#trimmed}" -gt "$max_size" ]]; then
        trimmed="${trimmed:0:$max_size}

... [CONTEXT TRUNCATED FOR BUDGET]"
    fi

    echo "$trimmed"
}

# ─── Iteration Summarization ─────────────────────────────────────────────────

context_budget_summarize_iteration() {
    local iteration_num="${1:-0}"
    local log_file="${2:-}"
    local test_result="${3:-}"
    local artifacts_dir="${4:-./.claude/pipeline-artifacts}"

    if [[ -z "$log_file" ]] || [[ ! -f "$log_file" ]]; then
        return 1
    fi

    # Extract key info from iteration
    local summary=""
    local changes_made
    changes_made=$(git diff --stat HEAD~1 2>/dev/null | tail -1 || echo "no changes")

    # Get test status
    local test_status="skipped"
    if [[ -n "$test_result" ]]; then
        if grep -q "FAILED\|failed\|✗" <<< "$test_result" 2>/dev/null; then
            test_status="failed"
        elif grep -q "PASSED\|passed\|✓" <<< "$test_result" 2>/dev/null; then
            test_status="passed"
        fi
    fi

    # Extract errors if any
    local errors=""
    if [[ "$test_status" == "failed" ]]; then
        errors=$(grep -E "Error:|ERROR:|FAIL" "$log_file" 2>/dev/null | head -3 || true)
    fi

    # Build summary (keep under 500 chars)
    summary="Iteration ${iteration_num}: $(echo "$changes_made" | tr '\n' ' ') | Tests: ${test_status}"
    if [[ -n "$errors" ]]; then
        summary="${summary} | Errors: $(echo "$errors" | cut -c1-100)"
    fi

    # Append to iteration-summaries.json
    local summaries_file="$artifacts_dir/iteration-summaries.json"
    local tmp_file
    tmp_file=$(mktemp "$artifacts_dir/iteration-summaries.json.tmp.XXXXXX" 2>/dev/null) || tmp_file="/tmp/iteration-summaries-$$.tmp"

    if [[ -f "$summaries_file" ]] && command -v jq >/dev/null 2>&1; then
        # Append to existing array
        jq --arg num "$iteration_num" \
           --arg sum "$summary" \
           --arg status "$test_status" \
           '.iterations += [{iteration: ($num | tonumber), summary: $sum, test_status: $status, timestamp: now}]' \
           "$summaries_file" > "$tmp_file" 2>/dev/null || echo "[]" > "$tmp_file"
    else
        # Create new array
        cat > "$tmp_file" <<EOF
{
  "iterations": [
    {
      "iteration": $iteration_num,
      "summary": "$summary",
      "test_status": "$test_status",
      "timestamp": $(date +%s)
    }
  ]
}
EOF
    fi

    mv "$tmp_file" "$summaries_file" 2>/dev/null || return 1
    return 0
}

# ─── Budget Report ──────────────────────────────────────────────────────────

context_budget_report() {
    local artifacts_dir="${1:-./.claude/pipeline-artifacts}"

    # Load budget config
    local budget_json=""
    if [[ -f "$artifacts_dir/context-budget.json" ]]; then
        budget_json=$(cat "$artifacts_dir/context-budget.json" 2>/dev/null || echo "{}")
    else
        budget_json="{}"
    fi

    # Load iteration summaries
    local summaries_json=""
    if [[ -f "$artifacts_dir/iteration-summaries.json" ]] && command -v jq >/dev/null 2>&1; then
        summaries_json=$(cat "$artifacts_dir/iteration-summaries.json" 2>/dev/null || echo "{}")
    else
        summaries_json="{\"iterations\":[]}"
    fi

    # Generate report
    cat <<EOF
{
  "budget_config": $budget_json,
  "iteration_summaries": $summaries_json,
  "report_generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

# ─── Integration Helpers ────────────────────────────────────────────────────

# Export a summary of context state for logging
context_budget_log_state() {
    local estimate="${1:-}"
    local status="${2:-}"
    local artifacts_dir="${3:-./.claude/pipeline-artifacts}"

    if [[ -z "$estimate" || -z "$status" ]]; then
        return 1
    fi

    local utilization
    utilization=$(echo "$estimate" | jq -r '.utilization_percent // 0' 2>/dev/null || echo 0)

    local used_tokens
    used_tokens=$(echo "$estimate" | jq -r '.total_used // 0' 2>/dev/null || echo 0)

    local remaining
    remaining=$(echo "$estimate" | jq -r '.remaining_tokens // 0' 2>/dev/null || echo 0)

    # Log to context-budget-log.jsonl
    local log_file="$artifacts_dir/context-budget-log.jsonl"
    local tmp_file
    tmp_file=$(mktemp "$artifacts_dir/context-budget-log.jsonl.tmp.XXXXXX" 2>/dev/null) || tmp_file="/tmp/context-budget-log-$$.tmp"

    cat >> "$tmp_file" <<EOF
{"timestamp":"$(date -u +"%Y-%m-%dT%H:%M:%SZ")","status":"$(echo "$status" | jq -r '.status // "unknown"' 2>/dev/null)","utilization_percent":$utilization,"used_tokens":$used_tokens,"remaining_tokens":$remaining}
EOF

    cat "$log_file" 2>/dev/null >> "$tmp_file" || true
    mv "$tmp_file" "$log_file" 2>/dev/null || true
}

return 0
