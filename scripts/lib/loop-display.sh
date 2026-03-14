#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Loop Display — show_help, show_banner, show_summary                     ║
# ║                                                                         ║
# ║  This module handles all user-facing display and help text.              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# Module guard — prevent double-sourcing
[[ -z "${_LOOP_DISPLAY_SH_LOADED:-}" ]] || return 0
readonly _LOOP_DISPLAY_SH_LOADED=1

# ─── Show Help ─────────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}shipwright${RESET} ${DIM}v${VERSION}${RESET} — ${BOLD}Continuous Loop${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright loop${RESET} \"<goal>\" [options]"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--repo <path>${RESET}             Change to directory before running (must be a git repo)"
    echo -e "  ${CYAN}--local${RESET}                   Disable GitHub operations (local-only mode)"
    echo -e "  ${CYAN}--max-iterations${RESET} N       Max loop iterations (default: 20)"
    echo -e "  ${CYAN}--test-cmd${RESET} \"cmd\"         Test command to run between iterations"
    echo -e "  ${CYAN}--fast-test-cmd${RESET} \"cmd\"      Fast/subset test command (alternates with full)"
    echo -e "  ${CYAN}--fast-test-interval${RESET} N       Run full tests every N iterations (default: 5)"
    echo -e "  ${CYAN}--additional-test-cmds${RESET} \"cmd\" Extra test command (repeatable)"
    echo -e "  ${CYAN}--model${RESET} MODEL             Claude model to use (default: opus)"
    echo -e "  ${CYAN}--effort${RESET} low|medium|high   Effort level for Claude reasoning (default: auto per stage)"
    echo -e "  ${CYAN}--fallback-model${RESET} MODEL      Fallback model on rate limits (default: sonnet)"
    echo -e "  ${CYAN}--agents${RESET} N                Number of parallel agents (default: 1)"
    echo -e "  ${CYAN}--roles${RESET} \"r1,r2,...\"        Role per agent: builder,reviewer,tester,optimizer,docs,security"
    echo -e "  ${CYAN}--worktree${RESET}                Use git worktrees for isolation (auto if agents > 1)"
    echo -e "  ${CYAN}--skip-permissions${RESET}        Pass --dangerously-skip-permissions to Claude"
    echo -e "  ${CYAN}--max-turns${RESET} N             Max API turns per Claude session"
    echo -e "  ${CYAN}--resume${RESET}                  Resume from existing .claude/loop-state.md"
    echo -e "  ${CYAN}--max-restarts${RESET} N          Max session restarts on exhaustion (default: 0)"
    echo -e "  ${CYAN}--verbose${RESET}                 Show full Claude output (default: summary)"
    echo -e "  ${CYAN}--help${RESET}                    Show this help"
    echo ""
    echo -e "${BOLD}AUDIT & QUALITY${RESET}"
    echo -e "  ${CYAN}--audit${RESET}                   Inject self-audit checklist into agent prompt"
    echo -e "  ${CYAN}--audit-agent${RESET}             Run separate auditor agent (haiku) after each iteration"
    echo -e "  ${CYAN}--quality-gates${RESET}           Enable automated quality gates before accepting completion"
    echo -e "  ${CYAN}--definition-of-done${RESET} FILE DoD checklist file — evaluated by AI against git diff"
    echo -e "  ${CYAN}--no-auto-extend${RESET}          Disable auto-extension when max iterations reached"
    echo -e "  ${CYAN}--extension-size${RESET} N         Additional iterations per extension (default: 5)"
    echo -e "  ${CYAN}--max-extensions${RESET} N         Max number of auto-extensions (default: 3)"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright loop \"Build user auth with JWT\"${RESET}"
    echo -e "  ${DIM}shipwright loop \"Add payment processing\" --test-cmd \"npm test\" --max-iterations 30${RESET}"
    echo -e "  ${DIM}shipwright loop \"Refactor the database layer\" --agents 3 --model sonnet${RESET}"
    echo -e "  ${DIM}shipwright loop \"Fix all lint errors\" --skip-permissions --verbose${RESET}"
    echo -e "  ${DIM}shipwright loop \"Add auth\" --audit --audit-agent --quality-gates${RESET}"
    echo -e "  ${DIM}shipwright loop \"Ship feature\" --quality-gates --definition-of-done dod.md${RESET}"
    echo ""
    echo -e "${BOLD}COMPLETION & CIRCUIT BREAKER${RESET}"
    echo -e "  The loop completes when:"
    echo -e "  ${DIM}• Claude outputs LOOP_COMPLETE and all quality gates pass${RESET}"
    echo -e "  ${DIM}• Max iterations reached (auto-extends if work is incomplete)${RESET}"
    echo -e "  The loop stops (circuit breaker) if:"
    echo -e "  ${DIM}• ${CIRCUIT_BREAKER_THRESHOLD} consecutive iterations with < ${MIN_PROGRESS_LINES} lines changed${RESET}"
    echo -e "  ${DIM}• Hard cap reached (max_iterations + max_extensions * extension_size)${RESET}"
    echo -e "  ${DIM}• Ctrl-C (graceful shutdown with summary)${RESET}"
    echo ""
    echo -e "${BOLD}STATE & LOGS${RESET}"
    echo -e "  ${DIM}State file:  .claude/loop-state.md${RESET}"
    echo -e "  ${DIM}Logs dir:    .claude/loop-logs/${RESET}"
    echo -e "  ${DIM}Resume:      shipwright loop --resume${RESET}"
}

# ─── Show Banner ───────────────────────────────────────────────────────────
show_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright${RESET} ${DIM}v${VERSION}${RESET} — ${BOLD}Continuous Loop${RESET}"
    echo -e "${CYAN}═══════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Goal:${RESET}  $GOAL"
    local extend_info=""
    if $AUTO_EXTEND; then
        extend_info=" ${DIM}(auto-extend: +${EXTENSION_SIZE} x${MAX_EXTENSIONS})${RESET}"
    fi
    echo -e "  ${BOLD}Model:${RESET} $MODEL ${DIM}|${RESET} ${BOLD}Max:${RESET} $MAX_ITERATIONS iterations${extend_info} ${DIM}|${RESET} ${BOLD}Test:${RESET} ${TEST_CMD:-"(none)"}"
    if [[ "$AGENTS" -gt 1 ]]; then
        echo -e "  ${BOLD}Agents:${RESET} $AGENTS ${DIM}(parallel worktree mode)${RESET}"
    fi
    if $SKIP_PERMISSIONS; then
        echo -e "  ${YELLOW}${BOLD}⚠${RESET}  ${YELLOW}--dangerously-skip-permissions enabled${RESET}"
    fi
    if $AUDIT_ENABLED || $AUDIT_AGENT_ENABLED || $QUALITY_GATES_ENABLED; then
        echo -e "  ${BOLD}Audit:${RESET} ${AUDIT_ENABLED:+self-audit }${AUDIT_AGENT_ENABLED:+audit-agent }${QUALITY_GATES_ENABLED:+quality-gates}${DIM}${DOD_FILE:+ | DoD: $DOD_FILE}${RESET}"
    fi
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# ─── Show Summary ──────────────────────────────────────────────────────────
show_summary() {
    local end_epoch
    end_epoch="$(now_epoch)"
    local duration=$(( end_epoch - START_EPOCH ))

    local status_display
    case "$STATUS" in
        complete)         status_display="${GREEN}✓ Complete (LOOP_COMPLETE detected)${RESET}" ;;
        circuit_breaker)  status_display="${RED}✗ Circuit breaker tripped${RESET}" ;;
        max_iterations)   status_display="${YELLOW}⚠ Max iterations reached${RESET}" ;;
        budget_exhausted) status_display="${RED}✗ Budget exhausted${RESET}" ;;
        interrupted)      status_display="${YELLOW}⚠ Interrupted by user${RESET}" ;;
        error)            status_display="${RED}✗ Error${RESET}" ;;
        *)                status_display="${DIM}$STATUS${RESET}" ;;
    esac

    local test_display
    if [[ -z "$TEST_CMD" ]]; then
        test_display="${DIM}No tests configured${RESET}"
    elif [[ "$TEST_PASSED" == "true" ]]; then
        test_display="${GREEN}All passing${RESET}"
    elif [[ "$TEST_PASSED" == "false" ]]; then
        test_display="${RED}Failing${RESET}"
    else
        test_display="${DIM}Not run${RESET}"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    local status_upper
    status_upper="$(echo "$STATUS" | tr '[:lower:]' '[:upper:]')"
    echo -e "  ${BOLD}LOOP ${status_upper}${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${BOLD}Goal:${RESET}        $GOAL"
    echo -e "  ${BOLD}Status:${RESET}      $status_display"
    local ext_suffix=""
    [[ "$EXTENSION_COUNT" -gt 0 ]] && ext_suffix=" ${DIM}(${EXTENSION_COUNT} extensions)${RESET}"
    echo -e "  ${BOLD}Iterations:${RESET}  $ITERATION/$MAX_ITERATIONS${ext_suffix}"
    echo -e "  ${BOLD}Duration:${RESET}    $(format_duration "$duration")"
    echo -e "  ${BOLD}Commits:${RESET}     $TOTAL_COMMITS"
    echo -e "  ${BOLD}Tests:${RESET}       $test_display"
    if [[ "$LOOP_INPUT_TOKENS" -gt 0 || "$LOOP_OUTPUT_TOKENS" -gt 0 ]]; then
        echo -e "  ${BOLD}Tokens:${RESET}      in=${LOOP_INPUT_TOKENS} out=${LOOP_OUTPUT_TOKENS}"
    fi
    echo ""
    echo -e "  ${DIM}State: $STATE_FILE${RESET}"
    echo -e "  ${DIM}Logs:  $LOG_DIR/${RESET}"
    echo ""

    # Write token totals for pipeline cost tracking
    write_loop_tokens
}
