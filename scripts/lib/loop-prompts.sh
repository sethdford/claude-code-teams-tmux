#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_PROMPTS_LOADED:-}" ]] && return 0
_LOOP_PROMPTS_LOADED=1

# ═══════════════════════════════════════════════════════════════════════════
# lib/loop-prompts.sh — Prompt Composition & Error Feedback
# ═══════════════════════════════════════════════════════════════════════════
#
# Composes iteration prompts for Claude Code agent(s), combining goal,
# progress, test results, memory, and audit sections. Handles:
# - Main prompt composition (compose_prompt)
# - Multi-agent role-specific prompts (compose_worker_prompt)
# - Audit checkpoints & feedback (compose_audit_section, etc.)
# - Error summary generation (write_error_summary)
#
# Globals: GOAL, LOG_DIR, ITERATION, MAX_ITERATIONS, AUDIT_ENABLED, etc.
# Dependencies: external memory/discovery systems (soft deps via type checks)

# ─── Prompt Composition ──────────────────────────────────────────────────────

compose_prompt() {
    local recent_log
    # Get last 3 iteration summaries from log entries
    recent_log="$(echo "$LOG_ENTRIES" | tail -15)"
    if [[ -z "$recent_log" ]]; then
        recent_log="(first iteration — no previous progress)"
    fi

    local git_log
    git_log="$(git_recent_log)"

    local test_section
    if [[ -z "$TEST_CMD" ]]; then
        test_section="No test command configured."
    elif [[ -z "$TEST_PASSED" ]]; then
        test_section="No test results yet (first iteration). Test command: $TEST_CMD"
    elif $TEST_PASSED; then
        test_section="$TEST_OUTPUT"
    else
        test_section="TESTS FAILED — fix these before proceeding:
$TEST_OUTPUT"
    fi

    # Structured error context (machine-readable)
    local error_summary_section=""
    local error_json="$LOG_DIR/error-summary.json"
    if [[ -f "$error_json" ]]; then
        local err_count err_lines
        err_count=$(jq -r '.error_count // 0' "$error_json" 2>/dev/null || echo "0")
        err_lines=$(jq -r '.error_lines[]? // empty' "$error_json" 2>/dev/null | head -10 || true)
        if [[ "$err_count" -gt 0 ]] && [[ -n "$err_lines" ]]; then
            error_summary_section="## Structured Error Summary (${err_count} errors detected)
${err_lines}

Fix these specific errors. Each line above is one distinct error from the test output."
        fi
    fi

    # Build audit sections (captured before heredoc to avoid nested heredoc issues)
    local audit_section
    audit_section="$(compose_audit_section)"
    local audit_feedback_section
    audit_feedback_section="$(compose_audit_feedback_section)"
    local rejection_notice_section
    rejection_notice_section="$(compose_rejection_notice_section)"

    # Memory context injection (failure patterns + past learnings)
    local memory_section=""
    if type memory_inject_context >/dev/null 2>&1; then
        memory_section="$(memory_inject_context "build" 2>/dev/null || true)"
    elif [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_section="$("$SCRIPT_DIR/sw-memory.sh" inject build 2>/dev/null || true)"
    fi

    # Cross-pipeline discovery injection (learnings from other pipeline runs)
    local discovery_section=""
    if type inject_discoveries >/dev/null 2>&1; then
        local disc_output
        disc_output="$(inject_discoveries "${GOAL:-}" 2>/dev/null || true)"
        if [[ -n "$disc_output" ]]; then
            discovery_section="$disc_output"
        fi
    fi

    # DORA baselines for context
    local dora_section=""
    if type memory_get_dora_baseline >/dev/null 2>&1; then
        local dora_json
        dora_json="$(memory_get_dora_baseline 7 2>/dev/null || echo "{}")"
        local dora_total
        dora_total=$(echo "$dora_json" | jq -r '.total // 0' 2>/dev/null || echo "0")
        if [[ "$dora_total" -gt 0 ]]; then
            local dora_df dora_cfr
            dora_df=$(echo "$dora_json" | jq -r '.deploy_freq // 0' 2>/dev/null || echo "0")
            dora_cfr=$(echo "$dora_json" | jq -r '.cfr // 0' 2>/dev/null || echo "0")
            dora_section="## Performance Baselines (Last 7 Days)
- Deploy frequency: ${dora_df}/week
- Change failure rate: ${dora_cfr}%
- Total pipeline runs: ${dora_total}"
        fi
    fi

    # Append mid-loop memory refresh if available
    local memory_refresh_file="$LOG_DIR/memory-refresh-$(( ITERATION - 1 )).txt"
    if [[ -f "$memory_refresh_file" ]]; then
        memory_section="${memory_section}

## Fresh Context (from iteration $(( ITERATION - 1 )) analysis)
$(cat "$memory_refresh_file")"
    fi

    # GitHub intelligence context (gated by availability)
    local intelligence_section=""
    if [[ "${NO_GITHUB:-}" != "true" ]]; then
        # File hotspots — top 5 most-changed files
        if type gh_file_change_frequency >/dev/null 2>&1; then
            local hotspots
            hotspots=$(gh_file_change_frequency 2>/dev/null | head -5 || true)
            if [[ -n "$hotspots" ]]; then
                intelligence_section="${intelligence_section}
## File Hotspots (most frequently changed)
${hotspots}"
            fi
        fi

        # CODEOWNERS context
        if type gh_codeowners >/dev/null 2>&1; then
            local owners
            owners=$(gh_codeowners 2>/dev/null | head -10 || true)
            if [[ -n "$owners" ]]; then
                intelligence_section="${intelligence_section}
## Code Owners
${owners}"
            fi
        fi

        # Active security alerts
        if type gh_security_alerts >/dev/null 2>&1; then
            local alerts
            alerts=$(gh_security_alerts 2>/dev/null | head -5 || true)
            if [[ -n "$alerts" ]]; then
                intelligence_section="${intelligence_section}
## Active Security Alerts
${alerts}"
            fi
        fi
    fi

    # Architecture rules (from intelligence layer)
    local repo_hash
    repo_hash=$(echo -n "$(pwd)" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local arch_file="${HOME}/.shipwright/memory/${repo_hash}/architecture.json"
    if [[ -f "$arch_file" ]]; then
        local arch_rules
        arch_rules=$(jq -r '.rules[]? // empty' "$arch_file" 2>/dev/null | head -10 || true)
        if [[ -n "$arch_rules" ]]; then
            intelligence_section="${intelligence_section}
## Architecture Rules
${arch_rules}"
        fi
    fi

    # Coverage baseline
    local coverage_file="${HOME}/.shipwright/baselines/${repo_hash}/coverage.json"
    if [[ -f "$coverage_file" ]]; then
        local coverage_pct
        coverage_pct=$(jq -r '.coverage_percent // empty' "$coverage_file" 2>/dev/null || true)
        if [[ -n "$coverage_pct" ]]; then
            intelligence_section="${intelligence_section}
## Coverage Baseline
Current coverage: ${coverage_pct}% — do not decrease this."
        fi
    fi

    # Error classification from last failure
    local error_log=".claude/pipeline-artifacts/error-log.jsonl"
    if [[ -f "$error_log" ]]; then
        local last_error
        last_error=$(tail -1 "$error_log" 2>/dev/null | jq -r '"Type: \(.type), Exit: \(.exit_code), Error: \(.error | split("\n") | first)"' 2>/dev/null || true)
        if [[ -n "$last_error" ]]; then
            intelligence_section="${intelligence_section}
## Last Error Context
${last_error}"
        fi
    fi

    # Stuckness detection — compare last 3 iteration outputs
    local stuckness_section=""
    stuckness_section="$(detect_stuckness)"
    local _stuck_ret=$?
    local stuckness_detected=false
    [[ "$_stuck_ret" -eq 0 ]] && stuckness_detected=true

    # Strategy exploration when stuck — append alternative strategy to GOAL
    if [[ "$stuckness_detected" == "true" ]]; then
        local last_error diagnosis
        last_error=$(tail -1 "${ARTIFACTS_DIR:-${PROJECT_ROOT:-.}/.claude/pipeline-artifacts}/error-log.jsonl" 2>/dev/null | jq -r '"Type: \(.type), Exit: \(.exit_code), Error: \(.error | split("\n") | first)"' 2>/dev/null || true)
        [[ -z "$last_error" || "$last_error" == "null" ]] && last_error="unknown"
        diagnosis="${STUCKNESS_DIAGNOSIS:-}"
        local alt_strategy
        alt_strategy=$(explore_alternative_strategy "$last_error" "${ITERATION:-0}" "$diagnosis")
        GOAL="${GOAL}

${alt_strategy}"

        # Handle model escalation
        if [[ "${ESCALATE_MODEL:-}" == "true" ]]; then
            if [[ -f "$SCRIPT_DIR/sw-model-router.sh" ]]; then
                source "$SCRIPT_DIR/sw-model-router.sh" 2>/dev/null || true
            fi
            if type escalate_model &>/dev/null; then
                MODEL=$(escalate_model "${MODEL:-sonnet}")
                info "Escalated to model: $MODEL"
            fi
            unset ESCALATE_MODEL
        fi
    fi

    # Session restart context — inject intelligent briefing or fallback to progress
    local restart_section=""
    if [[ "$SESSION_RESTART" == "true" ]]; then
        local briefing_file="${ARTIFACTS_DIR:-${LOG_DIR}}/restart-briefing.md"
        if [[ -f "$briefing_file" ]]; then
            # Inject intelligent briefing from session-restart.sh
            restart_section="## Session Restart Briefing
$(cat "$briefing_file")

You are starting a FRESH session after the previous one exhausted its context.
Read the briefing above carefully and continue from where the previous session left off.
Do NOT repeat work already done. Focus on what's failing and what to try next."
        elif [[ -f "$LOG_DIR/progress.md" ]]; then
            # Fallback to basic progress.md
            restart_section="## Previous Session Progress
$(cat "$LOG_DIR/progress.md")

You are starting a FRESH session after the previous one exhausted its iterations.
Read the progress above and continue from where it left off. Do NOT repeat work already done."
        fi
    fi

    # Resume-from-checkpoint context — reconstruct Claude context for meaningful resume
    local resume_section=""
    if [[ -n "${RESUMED_FROM_ITERATION:-}" && "${RESUMED_FROM_ITERATION:-0}" -gt 0 ]]; then
        local _test_tail="  (none recorded)"
        [[ -n "${RESUMED_TEST_OUTPUT:-}" ]] && _test_tail="$(echo "$RESUMED_TEST_OUTPUT" | tail -20)"
        resume_section="## RESUMING FROM ITERATION ${RESUMED_FROM_ITERATION}

Continue from where you left off. Do NOT repeat work already done.

Previous work modified these files:
${RESUMED_MODIFIED:-  (none recorded)}

Previous findings/errors from earlier iterations:
${RESUMED_FINDINGS:-  (none recorded)}

Last test output (fix any failures, tail):
${_test_tail}

---
"
        # Clear after first use so we don't keep injecting on every iteration
        RESUMED_FROM_ITERATION=""
        RESUMED_MODIFIED=""
        RESUMED_FINDINGS=""
        RESUMED_TEST_OUTPUT=""
    fi

    # Build cumulative progress summary showing all iterations' work
    local cumulative_section=""
    if [[ -n "${LOOP_START_COMMIT:-}" ]] && [[ "$ITERATION" -gt 1 ]]; then
        local cum_stat
        cum_stat="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | tail -1 || true)"
        if [[ -n "$cum_stat" ]]; then
            cumulative_section="## Cumulative Progress (all iterations combined)
${cum_stat}
"
        fi
    fi

    # Process reward context injection (from process-reward.sh)
    local reward_section=""
    if type process_reward_inject_context >/dev/null 2>&1; then
        reward_section="$(process_reward_inject_context 2>/dev/null || true)"
    fi

    # RL optimizer context injection (from rl-optimizer.sh, Phase 7)
    local rl_section=""
    if type rl_compose_prompt_section >/dev/null 2>&1; then
        rl_section="$(rl_compose_prompt_section 2>/dev/null || true)"
    fi

    # Autoresearch RL Phase 8: policy and reward feedback injection
    local policy_section=""
    if type policy_inject_into_prompt >/dev/null 2>&1; then
        policy_section="$(policy_inject_into_prompt 2>/dev/null || true)"
    fi
    local reward_feedback=""
    if type reward_inject_feedback >/dev/null 2>&1; then
        reward_feedback="$(reward_inject_feedback 2>/dev/null || true)"
    fi

    # Auto-recovery hint injection (from auto-recovery.sh)
    local recovery_section=""
    if [[ -n "${RECOVERY_HINT:-}" ]]; then
        recovery_section="## Auto-Recovery Guidance
${RECOVERY_HINT}
"
    fi
    if [[ -n "${RECOVERY_ESCALATED_MODEL:-}" ]]; then
        MODEL="${RECOVERY_ESCALATED_MODEL}"
        info "Model escalated to: ${MODEL} (auto-recovery)"
    fi

    cat <<PROMPT
You are an autonomous coding agent on iteration ${ITERATION}/${MAX_ITERATIONS} of a continuous loop.
${resume_section}
${recovery_section}
## Your Goal
${GOAL}

${cumulative_section}
## Current Progress
${recent_log}

## Recent Git Activity
${git_log}

## Test Results (Previous Iteration)
${test_section}

${error_summary_section:+$error_summary_section
}
${memory_section:+## Memory Context
$memory_section
}
${discovery_section:+## Cross-Pipeline Learnings
$discovery_section
}
${reward_section:+$reward_section
}
${rl_section:+$rl_section
}
${policy_section:+$policy_section
}
${reward_feedback:+$reward_feedback
}
${dora_section:+$dora_section
}
${intelligence_section:+$intelligence_section
}
${restart_section:+$restart_section
}
## Instructions
1. Read the codebase and understand the current state
2. Identify the highest-priority remaining work toward the goal
3. Implement ONE meaningful chunk of progress
4. Run tests if a test command exists: ${TEST_CMD:-"(none)"}
5. Commit your work with a descriptive message
6. When the goal is FULLY achieved, output exactly: LOOP_COMPLETE

## Context Efficiency
- Batch independent tool calls in parallel — avoid sequential round-trips
- Use targeted file reads (offset/limit) instead of entire large files
- Delegate large searches to subagents — only import the summary
- Filter tool results with grep/jq before reasoning over them
- Keep working memory lean — summarize completed steps, don't preserve full outputs

${audit_section}

${audit_feedback_section}

${rejection_notice_section}

${stuckness_section}

## Rules
- Focus on ONE task per iteration — do it well
- Always commit with descriptive messages
- If tests fail, fix them before ending
- If stuck on the same issue for 2+ iterations, try a different approach
- Do NOT output LOOP_COMPLETE unless the goal is genuinely achieved
PROMPT
}

# Detect stuckness by comparing iteration outputs (called in compose_prompt)
detect_stuckness() {
    if [[ "$ITERATION" -lt 3 ]]; then
        return 1  # Not enough data to detect stuckness
    fi
    
    # Compare last 3 iterations for similarity
    local iter_logs=()
    local i
    for i in $(( ITERATION - 2 )) $(( ITERATION - 1 )) "$ITERATION"; do
        local log_file="$LOG_DIR/iteration-${i}.log"
        if [[ -f "$log_file" ]]; then
            iter_logs+=("$(tail -50 "$log_file" | sha256sum | cut -d' ' -f1)")
        fi
    done
    
    # If hashes are identical across 3 iterations, we're stuck
    if [[ "${#iter_logs[@]}" -eq 3 ]] && [[ "${iter_logs[0]}" == "${iter_logs[1]}" ]] && [[ "${iter_logs[1]}" == "${iter_logs[2]}" ]]; then
        return 0  # Stuckness detected
    fi
    return 1
}

# Explore alternative strategies when stuck
explore_alternative_strategy() {
    local last_error="${1:-unknown}"
    local iteration="${2:-0}"
    local diagnosis="${3:-}"

    # Track attempted strategies to avoid repeating them
    local strategy_file="${LOG_DIR:-/tmp}/strategy-attempts.txt"
    local attempted
    attempted=$(cat "$strategy_file" 2>/dev/null || true)

    local strategy=""

    # If quality gates are passing but evaluators disagree, suggest focusing on evaluator alignment
    if [[ "${TEST_PASSED:-}" == "true" ]] && [[ "${QUALITY_GATE_PASSED:-}" == "true" || "${AUDIT_RESULT:-}" == "pass" ]]; then
        if ! echo "$attempted" | grep -q "evaluator_alignment"; then
            echo "evaluator_alignment" >> "$strategy_file"
            strategy="## Alternative Strategy: Evaluator Alignment
The code appears functionally complete (tests pass). Focus on satisfying the remaining
quality gate evaluators. Check the DoD log and audit log for specific complaints, then
address those exact points rather than adding new features."
        fi
    fi

    # If no code changes in last iteration, suggest verifying existing work
    if echo "$last_error" | grep -qi "no code changes" || [[ "$diagnosis" == *"no code"* ]]; then
        if ! echo "$attempted" | grep -q "verify_existing"; then
            echo "verify_existing" >> "$strategy_file"
            strategy="## Alternative Strategy: Verify Existing Work
Recent iterations made no code changes. The work may already be complete.
Run the full test suite, verify all features work, and if everything passes,
commit a verification message and declare LOOP_COMPLETE with evidence."
        fi
    fi

    # Generic fallback: break the problem down
    if [[ -z "$strategy" ]]; then
        if ! echo "$attempted" | grep -q "decompose"; then
            echo "decompose" >> "$strategy_file"
            strategy="## Alternative Strategy: Decompose
Break the remaining work into smaller, independent steps. Focus on one specific
file or function at a time. Read error messages literally — the root cause may
differ from your assumption."
        fi
    fi

    echo "$strategy"
}

# ─── Error Summarization ─────────────────────────────────────────────────────

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

# ─── Audit Sections ──────────────────────────────────────────────────────────

compose_audit_section() {
    if ! $AUDIT_ENABLED; then
        return
    fi

    # Try to inject audit items from past review feedback in memory
    local memory_audit_items=""
    if [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        local mem_dir_path
        mem_dir_path="$HOME/.shipwright/memory"
        # Look for review feedback in any repo memory
        local repo_hash_val
        repo_hash_val=$(git config --get remote.origin.url 2>/dev/null | shasum -a 256 2>/dev/null | cut -c1-12 || echo "")
        if [[ -n "$repo_hash_val" && -f "$mem_dir_path/$repo_hash_val/failures.json" ]]; then
            memory_audit_items=$(jq -r '.failures[] | select(.stage == "review" and .pattern != "") |
                "- Check for: \(.pattern[:100])"' \
                "$mem_dir_path/$repo_hash_val/failures.json" 2>/dev/null | head -5 || true)
        fi
    fi

    echo "## Self-Audit Checklist"
    echo "Before declaring LOOP_COMPLETE, critically evaluate your own work:"
    echo "1. Does the implementation FULLY satisfy the goal, not just partially?"
    echo "2. Are there any edge cases you haven't handled?"
    echo "3. Did you leave any TODO, FIXME, HACK, or XXX comments in new code?"
    echo "4. Are all new functions/modules tested (if a test command exists)?"
    echo "5. Would a code reviewer approve this, or would they request changes?"
    echo "6. Is the code clean, well-structured, and following project conventions?"
    if [[ -n "$memory_audit_items" ]]; then
        echo ""
        echo "Common review findings from this repo's history:"
        echo "$memory_audit_items"
    fi
    echo ""
    echo "If ANY answer is \"no\", do NOT output LOOP_COMPLETE. Instead, fix the issues first."
}

compose_audit_feedback_section() {
    if [[ -z "$AUDIT_RESULT" ]] || [[ "$AUDIT_RESULT" == "pass" ]]; then
        return
    fi
    cat <<AUDIT_FEEDBACK
## Audit Feedback (Previous Iteration)
An independent audit of your last iteration found these issues:
${AUDIT_RESULT}

Address ALL audit findings before proceeding with new work.
AUDIT_FEEDBACK
}

compose_rejection_notice_section() {
    if ! $COMPLETION_REJECTED; then
        return
    fi
    COMPLETION_REJECTED=false
    cat <<'REJECTION'
## ⚠ Completion Rejected
Your previous LOOP_COMPLETE was REJECTED because quality gates did not pass.
Review the audit feedback and test results above, fix the issues, then try again.
Do NOT output LOOP_COMPLETE until all quality checks pass.
REJECTION
}

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

