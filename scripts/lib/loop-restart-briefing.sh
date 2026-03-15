#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  loop-restart-briefing — Intelligent session restart briefing generation  ║
# ║                                                                         ║
# ║  Analyzes git changes, error patterns, iteration history, and generates ║
# ║  context-aware recommendations for restarted build sessions.            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard - prevent double-sourcing
[[ -n "${_LOOP_RESTART_BRIEFING_LOADED:-}" ]] && return 0
_LOOP_RESTART_BRIEFING_LOADED=1

VERSION="3.2.4"

# ─── Git Diff Categorization ───────────────────────────────────────────────

briefing_categorize_changes() {
    local git_root="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo '.')}"

    local source_files test_files docs_files config_files other_files
    source_files=""
    test_files=""
    docs_files=""
    config_files=""
    other_files=""

    # Categorize modified files from git diff
    local changed_files
    changed_files=$(git -C "$git_root" diff --name-only HEAD 2>/dev/null || echo "")

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        if [[ "$file" =~ ^test/ ]] || [[ "$file" =~ \.test\. ]] || [[ "$file" =~ \.spec\. ]]; then
            test_files="${test_files}${file}"$'\n'
        elif [[ "$file" =~ \.(md|txt|rst)$ ]] || [[ "$file" =~ ^docs/ ]]; then
            docs_files="${docs_files}${file}"$'\n'
        elif [[ "$file" =~ \.(json|yaml|yml|toml|config|conf)$ ]] || [[ "$file" =~ ^\.config/ ]]; then
            config_files="${config_files}${file}"$'\n'
        elif [[ "$file" =~ \.(js|ts|tsx|jsx|py|go|rs|java|sh)$ ]]; then
            source_files="${source_files}${file}"$'\n'
        else
            other_files="${other_files}${file}"$'\n'
        fi
    done <<< "$changed_files"

    # Count files in each category (safe counting method)
    local source_count test_count docs_count config_count other_count
    source_count=$(echo "$source_files" | grep -c . 2>/dev/null || true)
    source_count=${source_count:-0}
    test_count=$(echo "$test_files" | grep -c . 2>/dev/null || true)
    test_count=${test_count:-0}
    docs_count=$(echo "$docs_files" | grep -c . 2>/dev/null || true)
    docs_count=${docs_count:-0}
    config_count=$(echo "$config_files" | grep -c . 2>/dev/null || true)
    config_count=${config_count:-0}
    other_count=$(echo "$other_files" | grep -c . 2>/dev/null || true)
    other_count=${other_count:-0}

    # Output as JSON with trimmed file lists
    local source_files_json test_files_json docs_files_json config_files_json other_files_json
    source_files_json=$(echo "$source_files" | sed '/^$/d' | jq -Rs . 2>/dev/null || echo '""')
    test_files_json=$(echo "$test_files" | sed '/^$/d' | jq -Rs . 2>/dev/null || echo '""')
    docs_files_json=$(echo "$docs_files" | sed '/^$/d' | jq -Rs . 2>/dev/null || echo '""')
    config_files_json=$(echo "$config_files" | sed '/^$/d' | jq -Rs . 2>/dev/null || echo '""')
    other_files_json=$(echo "$other_files" | sed '/^$/d' | jq -Rs . 2>/dev/null || echo '""')

    {
        printf '{\n'
        printf '  "source": {\n'
        printf '    "count": %d,\n' "$source_count"
        printf '    "files": %s\n' "$source_files_json"
        printf '  },\n'
        printf '  "test": {\n'
        printf '    "count": %d,\n' "$test_count"
        printf '    "files": %s\n' "$test_files_json"
        printf '  },\n'
        printf '  "docs": {\n'
        printf '    "count": %d,\n' "$docs_count"
        printf '    "files": %s\n' "$docs_files_json"
        printf '  },\n'
        printf '  "config": {\n'
        printf '    "count": %d,\n' "$config_count"
        printf '    "files": %s\n' "$config_files_json"
        printf '  },\n'
        printf '  "other": {\n'
        printf '    "count": %d,\n' "$other_count"
        printf '    "files": %s\n' "$other_files_json"
        printf '  },\n'
        printf '  "total": %d\n' $((source_count + test_count + docs_count + config_count + other_count))
        printf '}\n'
    }
}

# ─── Error Pattern Extraction ──────────────────────────────────────────────

briefing_extract_error_patterns() {
    local error_summary="${1:-error-summary.json}"

    [[ ! -f "$error_summary" ]] && {
        echo "{\"patterns\": [], \"error_count\": 0, \"top_errors\": []}"
        return 0
    }

    local error_data patterns_json error_count top_errors

    # Read error summary
    error_data=$(cat "$error_summary" 2>/dev/null || echo "{}")
    error_count=$(echo "$error_data" | jq '.error_count // 0' 2>/dev/null || echo 0)

    # Extract error messages and rank by frequency
    local error_list
    error_list=$(echo "$error_data" | jq -r '.errors[]? | .message // ""' 2>/dev/null | sort | uniq -c | sort -rn | head -5)

    # Format as JSON array
    local formatted_errors="[]"
    if [[ -n "$error_list" ]]; then
        formatted_errors=$(echo "$error_list" | jq -s '[.[] | {count: (.count // 0), message: .message}]' 2>/dev/null || echo "[]")
    fi

    # Extract patterns (e.g., type mismatches, import errors, syntax errors)
    local patterns="[]"
    if [[ -n "$error_data" ]]; then
        patterns=$(echo "$error_data" | jq '.patterns // []' 2>/dev/null || echo "[]")
    fi

    # Output categorized errors
    {
        printf '{\n'
        printf '  "error_count": %d,\n' "$error_count"
        printf '  "patterns": %s,\n' "$patterns"
        printf '  "top_errors": %s,\n' "$formatted_errors"
        printf '  "primary_issue": %s\n' "$(echo "$error_list" | head -1 | jq -Rs .)"
        printf '}\n'
    }
}

# ─── Iteration History Summarization ───────────────────────────────────────

briefing_summarize_iterations() {
    local log_dir="${1:-.}"
    local progress_file="${log_dir}/progress.md"
    local restart_history="${log_dir}/restart-history.json"

    local summary_json attempts_count successes failures last_attempt
    attempts_count=0
    successes=0
    failures=0

    # Count iterations from progress file
    if [[ -f "$progress_file" ]]; then
        attempts_count=$(grep -c "^##" "$progress_file" 2>/dev/null || echo 0)
        successes=$(grep -c "✓ PASSED" "$progress_file" 2>/dev/null || echo 0)
        failures=$(grep -c "✗ FAILED" "$progress_file" 2>/dev/null || echo 0)
    fi

    # Get last attempt details
    if [[ -f "$restart_history" ]]; then
        last_attempt=$(jq '.[-1] // {}' "$restart_history" 2>/dev/null || echo '{}')
    else
        last_attempt="{}"
    fi

    # Read restart count
    local restart_count=0
    [[ -f "$restart_history" ]] && restart_count=$(jq 'length' "$restart_history" 2>/dev/null || echo 0)

    # Build summary
    {
        printf '{\n'
        printf '  "total_attempts": %d,\n' "$attempts_count"
        printf '  "successes": %d,\n' "$successes"
        printf '  "failures": %d,\n' "$failures"
        printf '  "restart_count": %d,\n' "$restart_count"
        printf '  "last_attempt": %s,\n' "$last_attempt"
        printf '  "success_rate": %.1f\n' "$(( successes > 0 ? (successes * 100 / attempts_count) : 0 ))"
        printf '}\n'
    }
}

# ─── Next Steps Recommendation ────────────────────────────────────────────

briefing_recommend_next_steps() {
    local restart_reason="${1:-unknown}"
    local error_patterns="${2:-{}}"
    local iteration_summary="${3:-{}}"
    local changes_summary="${4:-{}}"

    local recommendations priority focus
    recommendations=()
    priority="normal"
    focus=""

    # Extract key data
    local error_count restart_count total_attempts
    error_count=$(echo "$error_patterns" | jq '.error_count // 0' 2>/dev/null || echo 0)
    restart_count=$(echo "$iteration_summary" | jq '.restart_count // 0' 2>/dev/null || echo 0)
    total_attempts=$(echo "$iteration_summary" | jq '.total_attempts // 0' 2>/dev/null || echo 0)

    local source_changed test_changed
    source_changed=$(echo "$changes_summary" | jq '.source.count // 0' 2>/dev/null || echo 0)
    test_changed=$(echo "$changes_summary" | jq '.test.count // 0' 2>/dev/null || echo 0)

    case "$restart_reason" in
        context_exhaustion)
            priority="high"
            focus="Most critical remaining work"
            recommendations=("Skip re-reading already-committed source files")
            recommendations+=("Focus on failing tests only")
            recommendations+=("Use git log for context instead of reading full files")
            recommendations+=("Commit frequently to preserve progress")
            ;;
        stuck_loop)
            priority="critical"
            focus="Root cause analysis and fresh approach"
            recommendations=("Analyze the stuck error pattern with fresh perspective")
            recommendations+=("Try a fundamentally different implementation approach")
            recommendations+=("Break the problem into smaller steps")
            recommendations+=("Ask for help or review existing patterns in the codebase")
            ;;
        iteration_limit)
            priority="high"
            focus="Highest-impact remaining work"
            recommendations=("Prioritize incomplete features over refactoring")
            recommendations+=("Cut low-value work and focus on core goal")
            recommendations+=("Use existing patterns to speed up implementation")
            ;;
        manual)
            priority="normal"
            focus="Continuing normal development"
            recommendations=("Review what was accomplished before restart")
            recommendations+=("Continue from progress.md with fresh context")
            recommendations+=("Maintain consistent commit messages")
            ;;
        *)
            priority="normal"
            focus="Steady progress on goal"
            recommendations=("Analyze progress and next logical step")
            recommendations+=("Follow existing patterns and conventions")
            ;;
    esac

    # Add context-specific recommendations
    if [[ "$error_count" -gt 5 ]]; then
        recommendations+=("Multiple error patterns detected — start with the most common one")
    fi

    if [[ "$restart_count" -ge 2 && "$source_changed" -gt 10 ]]; then
        recommendations+=("Many file changes across restarts — consider breaking work into smaller commits")
    fi

    if [[ "$test_changed" -eq 0 && "$source_changed" -gt 0 ]]; then
        recommendations+=("Source files modified but no test changes — add/update tests")
    fi

    # Format output
    local rec_json="["
    local first=true
    for rec in "${recommendations[@]}"; do
        [[ "$first" == true ]] && first=false || rec_json="$rec_json,"
        rec_json="$rec_json$(echo "$rec" | jq -Rs .)"
    done
    rec_json="$rec_json]"

    {
        printf '{\n'
        printf '  "reason": %s,\n' "$(echo "$restart_reason" | jq -Rs .)"
        printf '  "priority": %s,\n' "$(echo "$priority" | jq -Rs .)"
        printf '  "focus": %s,\n' "$(echo "$focus" | jq -Rs .)"
        printf '  "recommendations": %s\n' "$rec_json"
        printf '}\n'
    }
}

# ─── Enhanced Briefing Generation ─────────────────────────────────────────

briefing_generate_enhanced() {
    local state_file="${1:-restart-state.json}"
    local restart_reason="${2:-unknown}"
    local output_file="${3:-restart-briefing-enhanced.md}"

    [[ ! -f "$state_file" ]] && {
        echo "restart briefing NOT generated (missing state file)"
        return 1
    }

    # Gather analysis data
    local git_root changes_json error_json iter_json recs_json
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || echo '.')"

    changes_json=$(briefing_categorize_changes "$git_root" 2>/dev/null || echo '{}')
    error_json=$(briefing_extract_error_patterns "error-summary.json" 2>/dev/null || echo '{}')
    iter_json=$(briefing_summarize_iterations "." 2>/dev/null || echo '{}')
    recs_json=$(briefing_recommend_next_steps "$restart_reason" "$error_json" "$iter_json" "$changes_json" 2>/dev/null || echo '{}')

    # Extract key values for briefing
    local goal iteration max_iter test_status
    goal=$(jq -r '.goal // ""' "$state_file" 2>/dev/null || echo "")
    iteration=$(jq -r '.progress.iteration // 0' "$state_file" 2>/dev/null || echo "0")
    max_iter=$(jq -r '.progress.max_iterations // 0' "$state_file" 2>/dev/null || echo "0")
    test_status=$(jq -r '.progress.test_status // "unknown"' "$state_file" 2>/dev/null || echo "unknown")

    # Extract analysis results
    local source_count test_count total_changed error_count restart_count
    local recs_priority recs_focus
    source_count=$(echo "$changes_json" | jq '.source.count // 0' 2>/dev/null || echo 0)
    test_count=$(echo "$changes_json" | jq '.test.count // 0' 2>/dev/null || echo 0)
    total_changed=$(echo "$changes_json" | jq '.total // 0' 2>/dev/null || echo 0)
    error_count=$(echo "$error_json" | jq '.error_count // 0' 2>/dev/null || echo 0)
    restart_count=$(echo "$iter_json" | jq '.restart_count // 0' 2>/dev/null || echo 0)
    recs_priority=$(echo "$recs_json" | jq -r '.priority // "normal"' 2>/dev/null || echo "normal")
    recs_focus=$(echo "$recs_json" | jq -r '.focus // ""' 2>/dev/null || echo "")

    # Generate markdown briefing
    local tmp_file="${output_file}.tmp.$$"
    {
        printf '# Intelligent Session Restart Briefing\n\n'
        printf '**Restart #%d** | Priority: %s | Reason: %s\n\n' "$restart_count" "$recs_priority" "$restart_reason"

        printf '## Progress Summary\n'
        printf '- Goal: %s\n' "$goal"
        printf '- Iteration: %d/%d\n' "$iteration" "$max_iter"
        printf '- Test Status: %s\n' "$test_status"
        printf '\n'

        printf '## Changes Analyzed\n'
        printf '- Source files: %d modified\n' "$source_count"
        printf '- Test files: %d modified\n' "$test_count"
        printf '- Total changes: %d files\n' "$total_changed"
        printf '\n'

        if [[ "$error_count" -gt 0 ]]; then
            printf '## Error Patterns (%d total)\n' "$error_count"
            local primary_issue
            primary_issue=$(echo "$error_json" | jq -r '.primary_issue // ""' 2>/dev/null || echo "")
            if [[ -n "$primary_issue" && "$primary_issue" != "null" ]]; then
                printf '- Primary: %s\n' "$primary_issue"
            fi
            printf '\n'
        fi

        printf '## Focus for This Session\n'
        printf '%s\n\n' "$recs_focus"

        local recs
        recs=$(echo "$recs_json" | jq -r '.recommendations[]? // ""' 2>/dev/null)
        if [[ -n "$recs" ]]; then
            printf '## Recommended Actions\n'
            echo "$recs" | while read -r rec; do
                [[ -z "$rec" ]] && continue
                printf '- %s\n' "$rec"
            done
            printf '\n'
        fi

        printf '---\n'
        printf '_Generated at %s for iteration %d_\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$iteration"

    } > "$tmp_file" 2>/dev/null

    if mv "$tmp_file" "$output_file" 2>/dev/null; then
        emit_event "briefing.enhanced_generated" "reason=$restart_reason" "restart=$restart_count" "output=$output_file" 2>/dev/null || true
        echo "$output_file"
        return 0
    else
        warn "Failed to write enhanced briefing"
        rm -f "$tmp_file"
        return 1
    fi
}
