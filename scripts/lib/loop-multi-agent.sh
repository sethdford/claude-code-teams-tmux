#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Loop Multi-Agent — worktree setup, worker scripts, launch/wait/cleanup  ║
# ║                                                                         ║
# ║  This module handles all multi-agent orchestration: worktree setup,      ║
# ║  worker prompt composition, worker script generation, tmux-based         ║
# ║  launch, completion monitoring, and cleanup.                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# Module guard — prevent double-sourcing
[[ -z "${_LOOP_MULTI_AGENT_SH_LOADED:-}" ]] || return 0
readonly _LOOP_MULTI_AGENT_SH_LOADED=1

# ─── Worker Prompt Composition ────────────────────────────────────────────

compose_worker_prompt() {
    local agent_num="$1"
    local total_agents="$2"

    local base_prompt
    base_prompt="$(compose_prompt)"

    # Role-specific instructions
    local role_section=""
    if [[ -n "$AGENT_ROLES" ]] && [[ "${agent_num:-0}" -ge 1 ]]; then
        # Split comma-separated roles and get role for this agent
        local role=""
        local IFS_BAK="$IFS"
        IFS=',' read -ra _roles <<< "$AGENT_ROLES"
        IFS="$IFS_BAK"
        if [[ "$agent_num" -le "${#_roles[@]}" ]]; then
            role="${_roles[$((agent_num - 1))]}"
            # Trim whitespace and skip empty roles (handles trailing comma)
            role="$(echo "$role" | tr -d ' ')"
        fi

        if [[ -n "$role" ]]; then
            local role_desc=""
            # Try to pull description from recruit's roles DB first
            local recruit_roles_db="${HOME}/.shipwright/recruitment/roles.json"
            if [[ -f "$recruit_roles_db" ]] && command -v jq >/dev/null 2>&1; then
                local recruit_desc
                recruit_desc=$(jq -r --arg r "$role" '.[$r].description // ""' "$recruit_roles_db" 2>/dev/null) || true
                if [[ -n "$recruit_desc" && "$recruit_desc" != "null" ]]; then
                    role_desc="$recruit_desc"
                fi
            fi
            # Fallback to built-in role descriptions
            if [[ -z "$role_desc" ]]; then
                case "$role" in
                    builder)   role_desc="Focus on implementation — writing code, fixing bugs, building features. You are the primary builder." ;;
                    reviewer)  role_desc="Focus on code review — look for bugs, security issues, edge cases in recent commits. Make fixes via commits." ;;
                    tester)    role_desc="Focus on test coverage — write new tests, fix failing tests, improve assertions and edge case coverage." ;;
                    optimizer) role_desc="Focus on performance — profile hot paths, reduce complexity, optimize algorithms and data structures." ;;
                    docs|docs-writer) role_desc="Focus on documentation — update README, add docstrings, write usage guides for new features." ;;
                    security|security-auditor) role_desc="Focus on security — audit for vulnerabilities, fix injection risks, validate inputs, check auth boundaries." ;;
                    *)         role_desc="Focus on: ${role}. Apply your expertise in this area to advance the goal." ;;
                esac
            fi
            role_section="## Your Role: ${role}
${role_desc}
Prioritize work in your area of expertise. Coordinate with other agents via git log."
        fi
    fi

    cat <<PROMPT
${base_prompt}

## Agent Identity
You are Agent ${agent_num} of ${total_agents}. Other agents are working in parallel.
Check git log to see what they've done — avoid duplicating their work.
Focus on areas they haven't touched yet.

${role_section}
PROMPT
}

# ─── Worktree Setup ──────────────────────────────────────────────────────

setup_worktrees() {
    local branch_base="loop"
    mkdir -p "$WORKTREE_DIR"

    for i in $(seq 1 "$AGENTS"); do
        local wt_path="$WORKTREE_DIR/agent-${i}"
        local branch_name="${branch_base}/agent-${i}"

        if [[ -d "$wt_path" ]]; then
            info "Worktree agent-${i} already exists"
            continue
        fi

        # Create branch if it doesn't exist
        if ! git -C "$PROJECT_ROOT" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            git -C "$PROJECT_ROOT" branch "$branch_name" HEAD 2>/dev/null || true
        fi

        git -C "$PROJECT_ROOT" worktree add "$wt_path" "$branch_name" 2>/dev/null || {
            error "Failed to create worktree for agent-${i}"
            return 1
        }

        success "Worktree: agent-${i} → $wt_path"
    done
}

cleanup_worktrees() {
    for i in $(seq 1 "$AGENTS"); do
        local wt_path="$WORKTREE_DIR/agent-${i}"
        if [[ -d "$wt_path" ]]; then
            git -C "$PROJECT_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        fi
    done
    rmdir "$WORKTREE_DIR" 2>/dev/null || true
}

# ─── Worker Script Generation ────────────────────────────────────────────

generate_worker_script() {
    local agent_num="$1"
    local total_agents="$2"
    local wt_path="$WORKTREE_DIR/agent-${agent_num}"
    local worker_script="$LOG_DIR/worker-${agent_num}.sh"

    local claude_flags
    claude_flags="$(build_claude_flags)"

    cat > "$worker_script" <<'WORKEREOF'
#!/usr/bin/env bash
set -euo pipefail

AGENT_NUM="__AGENT_NUM__"
TOTAL_AGENTS="__TOTAL_AGENTS__"
WORK_DIR="__WORK_DIR__"
LOG_DIR="__LOG_DIR__"
MAX_ITERATIONS="__MAX_ITERATIONS__"
GOAL="__GOAL__"
TEST_CMD="__TEST_CMD__"
CLAUDE_FLAGS="__CLAUDE_FLAGS__"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

cd "$WORK_DIR" || { echo "ERROR: Cannot cd to WORK_DIR: $WORK_DIR" >&2; exit 1; }
ITERATION=0
CONSECUTIVE_FAILURES=0

echo -e "${CYAN}${BOLD}▸${RESET} Agent ${AGENT_NUM}/${TOTAL_AGENTS} starting in ${WORK_DIR}"

while [[ "$ITERATION" -lt "$MAX_ITERATIONS" ]]; do
    # Budget gate: stop if daily budget exhausted
    if [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
        budget_remaining=$("$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
        if [[ -n "$budget_remaining" && "$budget_remaining" != "unlimited" ]]; then
            if awk -v r="$budget_remaining" 'BEGIN { exit !(r <= 0) }' 2>/dev/null; then
                echo -e "  ${RED}✗${RESET} Budget exhausted (\$${budget_remaining}) — stopping agent ${AGENT_NUM}"
                break
            fi
        fi
    fi

    ITERATION=$(( ITERATION + 1 ))
    echo -e "\n${CYAN}${BOLD}▸${RESET} Agent ${AGENT_NUM} — Iteration ${ITERATION}/${MAX_ITERATIONS}"

    # Pull latest from other agents
    git fetch origin main 2>/dev/null && git merge origin/main --no-edit 2>/dev/null || true

    # Build prompt
    GIT_LOG="$(git log --oneline -20 2>/dev/null || echo '(no commits)')"
    TEST_SECTION="No test results yet."
    if [[ -n "$TEST_CMD" ]]; then
        TEST_SECTION="Test command: $TEST_CMD"
    fi

    PROMPT="$(cat <<PROMPT
You are an autonomous coding agent on iteration ${ITERATION}/${MAX_ITERATIONS} of a continuous loop.

## Your Goal
${GOAL}

## Recent Git Activity
${GIT_LOG}

## Test Results
${TEST_SECTION}

## Agent Identity
You are Agent ${AGENT_NUM} of ${TOTAL_AGENTS}. Other agents are working in parallel.
Check git log to see what they've done — avoid duplicating their work.
Focus on areas they haven't touched yet.

## Instructions
1. Read the codebase and understand the current state
2. Identify the highest-priority remaining work toward the goal
3. Implement ONE meaningful chunk of progress
4. Commit your work with a descriptive message
5. When the goal is FULLY achieved, output exactly: LOOP_COMPLETE

## Rules
- Focus on ONE task per iteration — do it well
- Always commit with descriptive messages
- If stuck on the same issue for 2+ iterations, try a different approach
- Do NOT output LOOP_COMPLETE unless the goal is genuinely achieved
PROMPT
)"

    # Run Claude (output is JSON due to --output-format json in CLAUDE_FLAGS)
    local JSON_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.json"
    local ERR_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.stderr"
    LOG_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.log"
    # shellcheck disable=SC2086
    claude -p "$PROMPT" $CLAUDE_FLAGS > "$JSON_FILE" 2>"$ERR_FILE" || true

    # Extract text result from JSON into .log for backwards compat
    _extract_text_from_json "$JSON_FILE" "$LOG_FILE" "$ERR_FILE"

    echo -e "  ${GREEN}✓${RESET} Claude session completed"

    # Check completion
    if grep -q "LOOP_COMPLETE" "$LOG_FILE" 2>/dev/null; then
        echo -e "  ${GREEN}${BOLD}✓ LOOP_COMPLETE detected!${RESET}"
        # Signal completion
        touch "$LOG_DIR/.agent-${AGENT_NUM}-complete"
        break
    fi

    # Auto-commit — stage only source files, exclude build artifacts
    git add -A 2>/dev/null || true
    git reset -- .claude/loop-logs/ .claude/loop-state.md .claude/intelligence-cache.json \
        .claude/platform-hygiene.json .claude/pipeline-artifacts/ .claude/code-review.json \
        .claude/hygiene-report.json .claude/pr-draft.md 2>/dev/null || true
    if git commit -m "agent-${AGENT_NUM}: iteration ${ITERATION}" --no-verify 2>/dev/null; then
        if ! git push origin "loop/agent-${AGENT_NUM}" 2>/dev/null; then
            echo -e "  ${YELLOW}⚠${RESET} git push failed for loop/agent-${AGENT_NUM} — remote may be out of sync"
            type emit_event >/dev/null 2>&1 && emit_event "loop.push_failed" "branch=loop/agent-${AGENT_NUM}"
        else
            echo -e "  ${GREEN}✓${RESET} Committed and pushed"
        fi
    fi

    # Circuit breaker: check for progress
    CHANGES="$(git diff --stat HEAD~1 2>/dev/null | tail -1 || echo '')"
    INSERTIONS="$(echo "$CHANGES" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    if [[ "${INSERTIONS:-0}" -lt 5 ]]; then
        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
        echo -e "  ${YELLOW}⚠${RESET} Low progress (${CONSECUTIVE_FAILURES}/3)"
    else
        CONSECUTIVE_FAILURES=0
    fi

    if [[ "$CONSECUTIVE_FAILURES" -ge 3 ]]; then
        echo -e "  ${RED}✗${RESET} Circuit breaker — stopping agent ${AGENT_NUM}"
        break
    fi

    sleep __SLEEP_BETWEEN_ITERATIONS__
done

echo -e "\n${DIM}Agent ${AGENT_NUM} finished after ${ITERATION} iterations${RESET}"
WORKEREOF

    # Replace placeholders — use awk for all values to avoid sed injection
    # (sed breaks on & | \ in paths and test commands)
    sed_i "s|__AGENT_NUM__|${agent_num}|g" "$worker_script"
    sed_i "s|__TOTAL_AGENTS__|${total_agents}|g" "$worker_script"
    sed_i "s|__MAX_ITERATIONS__|${MAX_ITERATIONS}|g" "$worker_script"
    sed_i "s|__SLEEP_BETWEEN_ITERATIONS__|$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)|g" "$worker_script"
    # Paths and commands may contain sed-special chars — use awk
    awk -v val="$wt_path" '{gsub(/__WORK_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$LOG_DIR" '{gsub(/__LOG_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$SCRIPT_DIR" '{gsub(/__SCRIPT_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$TEST_CMD" '{gsub(/__TEST_CMD__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$claude_flags" '{gsub(/__CLAUDE_FLAGS__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$GOAL" '{gsub(/__GOAL__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    chmod +x "$worker_script"
    echo "$worker_script"
}

# ─── Multi-Agent: Launch ─────────────────────────────────────────────────

MULTI_WINDOW_NAME=""

launch_multi_agent() {
    info "Setting up multi-agent mode ($AGENTS agents)..."

    # Setup worktrees
    setup_worktrees || { error "Failed to setup worktrees"; exit 1; }

    # Create tmux window for workers
    MULTI_WINDOW_NAME="sw-loop-$(date +%s)"
    tmux new-window -n "$MULTI_WINDOW_NAME" -c "$PROJECT_ROOT"

    # Capture the first pane's ID (stable regardless of pane-base-index)
    local monitor_pane_id
    monitor_pane_id="$(tmux list-panes -t "$MULTI_WINDOW_NAME" -F '#{pane_id}' 2>/dev/null | head -1)"

    # First pane becomes monitor
    tmux send-keys -t "$monitor_pane_id" "printf '\\033]2;loop-monitor\\033\\\\'" Enter
    sleep 0.2
    tmux send-keys -t "$monitor_pane_id" "clear && echo 'Loop Monitor — watching agent logs...'" Enter

    # Create worker panes
    for i in $(seq 1 "$AGENTS"); do
        local worker_script
        worker_script="$(generate_worker_script "$i" "$AGENTS")"

        local worker_pane_id
        worker_pane_id="$(tmux split-window -t "$MULTI_WINDOW_NAME" -c "$PROJECT_ROOT" -P -F '#{pane_id}')"
        sleep 0.1
        tmux send-keys -t "$worker_pane_id" "printf '\\033]2;agent-${i}\\033\\\\'" Enter
        sleep 0.1
        tmux send-keys -t "$worker_pane_id" "bash '$worker_script'" Enter
    done

    # Layout: monitor pane on top (35%), worker agents tile below
    tmux select-layout -t "$MULTI_WINDOW_NAME" main-vertical 2>/dev/null || true
    tmux resize-pane -t "$monitor_pane_id" -y 35% 2>/dev/null || true

    # In the monitor pane, tail all agent logs
    tmux select-pane -t "$monitor_pane_id"
    sleep 0.5
    tmux send-keys -t "$monitor_pane_id" "clear && tail -f $LOG_DIR/agent-*-iter-*.log 2>/dev/null || echo 'Waiting for agent logs...'" Enter

    success "Launched $AGENTS worker agents in window: $MULTI_WINDOW_NAME"
    echo ""

    # Wait for completion
    info "Monitoring agents... (Ctrl-C to stop all)"
    wait_for_multi_completion
}

wait_for_multi_completion() {
    while true; do
        # Check if any agent signaled completion
        for i in $(seq 1 "$AGENTS"); do
            if [[ -f "$LOG_DIR/.agent-${i}-complete" ]]; then
                success "Agent $i signaled LOOP_COMPLETE!"
                STATUS="complete"
                write_state
                return 0
            fi
        done

        # Check if all worker panes are still running
        local running=0
        for i in $(seq 1 "$AGENTS"); do
            # Check if the worker log is still being written to
            local latest_log
            latest_log="$(ls -t "$LOG_DIR"/agent-"${i}"-iter-*.log 2>/dev/null | head -1)"
            if [[ -n "$latest_log" ]]; then
                local age
                age=$(( $(now_epoch) - $(file_mtime "$latest_log") ))
                if [[ $age -lt 300 ]]; then  # Active within 5 minutes
                    running=$(( running + 1 ))
                fi
            fi
        done

        if [[ $running -eq 0 ]]; then
            # Check if we have any logs at all (might still be starting)
            local total_logs
            total_logs="$(ls "$LOG_DIR"/agent-*-iter-*.log 2>/dev/null | wc -l | tr -d ' ')"
            if [[ "${total_logs:-0}" -gt 0 ]]; then
                warn "All agents appear to have stopped."
                STATUS="complete"
                write_state
                return 0
            fi
        fi

        sleep "$(_config_get_int "loop.multi_agent_sleep" 5 2>/dev/null || echo 5)"
    done
}

cleanup_multi_agent() {
    if [[ -n "$MULTI_WINDOW_NAME" ]]; then
        # Send Ctrl-C to all panes using stable pane IDs (not indices)
        # Pane IDs (%0, %1, ...) are unaffected by pane-base-index setting
        local pane_id
        while IFS= read -r pane_id; do
            [[ -z "$pane_id" ]] && continue
            tmux send-keys -t "$pane_id" C-c 2>/dev/null || true
        done < <(tmux list-panes -t "$MULTI_WINDOW_NAME" -F '#{pane_id}' 2>/dev/null || true)
        sleep 1
        tmux kill-window -t "$MULTI_WINDOW_NAME" 2>/dev/null || true
    fi

    # Clean up completion markers
    rm -f "$LOG_DIR"/.agent-*-complete 2>/dev/null || true
}
