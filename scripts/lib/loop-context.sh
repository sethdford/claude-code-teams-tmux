#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_CONTEXT_LOADED:-}" ]] && return 0
_LOOP_CONTEXT_LOADED=1

# ═══════════════════════════════════════════════════════════════════════════
# lib/loop-context.sh — Context Window & Git Management
# ═══════════════════════════════════════════════════════════════════════════
#
# Manages the context budget for Claude prompts, injects memory/discovery
# contexts, and provides git operations for tracking work. Handles:
# - Context window trimming (manage_context_window)
# - Memory context injection (inject_memory_context)
# - Git tracking (git_commit_count, git_recent_log, git_diff_stat)
# - Auto-commit logic (git_auto_commit)
#
# Globals: CONTEXT_BUDGET_CHARS, LOG_DIR, SCRIPT_DIR, PROJECT_ROOT
# Dependencies: git, jq (optional), validate_claude_output

# ─── Context Window Management ───────────────────────────────────────────────

manage_context_window() {
    local prompt="$1"
    local budget="${CONTEXT_BUDGET_CHARS:-200000}"
    local current_len=${#prompt}

    # Read trimming tunables from config (env > daemon-config > policy > defaults.json)
    local trim_memory_chars trim_git_entries trim_hotspot_files trim_test_lines
    trim_memory_chars=$(_config_get_int "loop.context_trim_memory_chars" 20000 2>/dev/null || echo 20000)
    trim_git_entries=$(_config_get_int "loop.context_trim_git_entries" 10 2>/dev/null || echo 10)
    trim_hotspot_files=$(_config_get_int "loop.context_trim_hotspot_files" 5 2>/dev/null || echo 5)
    trim_test_lines=$(_config_get_int "loop.context_trim_test_lines" 50 2>/dev/null || echo 50)

    if [[ "$current_len" -le "$budget" ]]; then
        echo "$prompt"
        return
    fi

    # Over budget — progressively trim sections (least important first)
    local trimmed="$prompt"

    # 1. Trim DORA/Performance baselines (least critical for code generation)
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk '/^## Performance Baselines/{skip=1; next} skip && /^## [^#]/{skip=0} !skip{print}')
    fi

    # 2. Trim file hotspots to top N
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_hotspot_files" '/## File Hotspots/{p=1; c=0} p && /^- /{c++; if(c>max) next} {print}')
    fi

    # 3. Trim git log to last N entries
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_git_entries" '/## Recent Git Activity/{p=1; c=0} p && /^[a-f0-9]/{c++; if(c>max) next} {print}')
    fi

    # 4. Truncate memory context to first N chars
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_memory_chars" '
            /## Memory Context/{mem=1; skip_rest=0; chars=0; print; next}
            mem && /^## [^#]/{mem=0; print; next}
            mem{chars+=length($0)+1; if(chars>max){print "... (memory truncated for context budget)"; skip_rest=1; mem=0; next}}
            skip_rest && /^## [^#]/{skip_rest=0; print; next}
            skip_rest{next}
            {print}
        ')
    fi

    # 5. Truncate test output to last N lines
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed=$(echo "$trimmed" | awk -v max="$trim_test_lines" '
            /## Test Results/{found=1; buf=""; print; next}
            found && /^## [^#]/{found=0; n=split(buf,arr,"\n"); start=(n>max)?(n-max+1):1; for(i=start;i<=n;i++) if(arr[i]!="") print arr[i]; print; next}
            found{buf=buf $0 "\n"; next}
            {print}
        ')
    fi

    # 6. Last resort: hard truncate with notice
    if [[ "${#trimmed}" -gt "$budget" ]]; then
        trimmed="${trimmed:0:$budget}

... [CONTEXT TRUNCATED: prompt exceeded ${budget} char budget. Focus on the goal and most recent errors.]"
    fi

    # Log the trimming
    local final_len=${#trimmed}
    if [[ "$final_len" -lt "$current_len" ]]; then
        warn "Context trimmed from ${current_len} to ${final_len} chars (budget: ${budget})"
        emit_event "loop.context_trimmed" "original=$current_len" "trimmed=$final_len" "budget=$budget" 2>/dev/null || true
    fi

    echo "$trimmed"
}

# ─── Memory Context Injection ────────────────────────────────────────────────

inject_memory_context() {
    local context=""
    
    # Memory injection (failure patterns + past learnings)
    if type memory_inject_context >/dev/null 2>&1; then
        context="$(memory_inject_context "build" 2>/dev/null || true)"
    elif [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        context="$("$SCRIPT_DIR/sw-memory.sh" inject build 2>/dev/null || true)"
    fi
    
    echo "$context"
}

# ─── Git Operations ──────────────────────────────────────────────────────────

git_commit_count() {
    git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo 0
}

git_recent_log() {
    git -C "$PROJECT_ROOT" log --oneline -20 2>/dev/null || echo "(no commits)"
}

git_diff_stat() {
    git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null | tail -1 || echo ""
}

git_auto_commit() {
    local work_dir="${1:-$PROJECT_ROOT}"
    # Only commit if there are changes
    if git -C "$work_dir" diff --quiet && git -C "$work_dir" diff --cached --quiet; then
        # Check for untracked files
        local untracked
        untracked="$(git -C "$work_dir" ls-files --others --exclude-standard | head -1)"
        if [[ -z "$untracked" ]]; then
            return 1  # Nothing to commit
        fi
    fi

    git -C "$work_dir" add -A 2>/dev/null || true

    # Semantic validation before commit — skip commit if validation fails
    if ! validate_claude_output "$work_dir"; then
        warn "Validation failed — skipping commit for this iteration"
        git -C "$work_dir" reset --hard HEAD 2>/dev/null || true
        return 1
    fi

    git -C "$work_dir" commit -m "loop: iteration $ITERATION — autonomous progress" --no-verify 2>/dev/null || return 1
    return 0
}

