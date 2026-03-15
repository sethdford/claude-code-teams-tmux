#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop — Continuous agent loop harness for Claude Code               ║
# ║                                                                         ║
# ║  Runs Claude Code in a headless loop until a goal is achieved.          ║
# ║  Supports single-agent and multi-agent (parallel worktree) modes.       ║
# ║                                                                         ║
# ║  Inspired by Anthropic's autonomous 16-agent C compiler build.          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Allow spawning Claude CLI from within a Claude Code session (daemon, fleet, etc.)
unset CLAUDECODE 2>/dev/null || true
# Ignore SIGHUP so tmux attach/detach doesn't kill long-running agent sessions
trap '' HUP
trap '' SIGPIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
# Source DB for dual-write (emit_event → JSONL + SQLite).
# Note: do NOT call init_schema here — the pipeline (sw-pipeline.sh) owns schema
# initialization. Calling it here would create an empty DB that shadows JSON cost data.
if [[ -f "$SCRIPT_DIR/sw-db.sh" ]]; then
    source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null || true
fi
# Cross-pipeline discovery (learnings from other pipeline runs)
[[ -f "$SCRIPT_DIR/sw-discovery.sh" ]] && source "$SCRIPT_DIR/sw-discovery.sh" 2>/dev/null || true
# Source loop sub-modules for modular iteration management
[[ -f "$SCRIPT_DIR/lib/loop-iteration.sh" ]] && source "$SCRIPT_DIR/lib/loop-iteration.sh"
[[ -f "$SCRIPT_DIR/lib/loop-convergence.sh" ]] && source "$SCRIPT_DIR/lib/loop-convergence.sh"
[[ -f "$SCRIPT_DIR/lib/loop-restart.sh" ]] && source "$SCRIPT_DIR/lib/loop-restart.sh"
[[ -f "$SCRIPT_DIR/lib/loop-progress.sh" ]] && source "$SCRIPT_DIR/lib/loop-progress.sh"
[[ -f "$SCRIPT_DIR/lib/loop-tokens.sh" ]] && source "$SCRIPT_DIR/lib/loop-tokens.sh"
[[ -f "$SCRIPT_DIR/lib/loop-error-feedback.sh" ]] && source "$SCRIPT_DIR/lib/loop-error-feedback.sh"
[[ -f "$SCRIPT_DIR/lib/loop-git.sh" ]] && source "$SCRIPT_DIR/lib/loop-git.sh"
[[ -f "$SCRIPT_DIR/lib/loop-display.sh" ]] && source "$SCRIPT_DIR/lib/loop-display.sh"
[[ -f "$SCRIPT_DIR/lib/loop-quality.sh" ]] && source "$SCRIPT_DIR/lib/loop-quality.sh"
[[ -f "$SCRIPT_DIR/lib/loop-multi-agent.sh" ]] && source "$SCRIPT_DIR/lib/loop-multi-agent.sh"
# Intelligent session restart with enhanced briefings and cross-session tracking
[[ -f "$SCRIPT_DIR/lib/session-restart.sh" ]] && source "$SCRIPT_DIR/lib/session-restart.sh"
# Context window budget monitoring (issue #209)
# shellcheck source=lib/context-budget.sh
[[ -f "$SCRIPT_DIR/lib/context-budget.sh" ]] && source "$SCRIPT_DIR/lib/context-budget.sh" 2>/dev/null || true
# Convergence detection and scoring (issue #203)
[[ -f "$SCRIPT_DIR/lib/convergence.sh" ]] && source "$SCRIPT_DIR/lib/convergence.sh" 2>/dev/null || true
# Error actionability scoring and enhancement for better error context
# shellcheck source=lib/error-actionability.sh
[[ -f "$SCRIPT_DIR/lib/error-actionability.sh" ]] && source "$SCRIPT_DIR/lib/error-actionability.sh" 2>/dev/null || true
# Test execution optimization (issue #200)
# shellcheck source=lib/test-optimizer.sh
[[ -f "$SCRIPT_DIR/lib/test-optimizer.sh" ]] && source "$SCRIPT_DIR/lib/test-optimizer.sh" 2>/dev/null || true
# Audit trail for compliance-grade pipeline traceability
# shellcheck source=lib/audit-trail.sh
[[ -f "$SCRIPT_DIR/lib/audit-trail.sh" ]] && source "$SCRIPT_DIR/lib/audit-trail.sh" 2>/dev/null || true
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Defaults ─────────────────────────────────────────────────────────────────
GOAL=""
ORIGINAL_GOAL=""  # Preserved across restarts — GOAL gets appended to
MAX_ITERATIONS="${SW_MAX_ITERATIONS:-20}"
TEST_CMD=""
FAST_TEST_CMD=""
FAST_TEST_INTERVAL=5
TEST_LOG_FILE=""
MODEL="${SW_MODEL:-opus}"
AGENTS=1
AGENT_ROLES=""
USE_WORKTREE=false
SKIP_PERMISSIONS=false
MAX_TURNS=""
RESUME=false
VERBOSE=false
MAX_ITERATIONS_EXPLICIT=false
MAX_RESTARTS=$(_config_get_int "loop.max_restarts" 0 2>/dev/null || echo 0)
SESSION_RESTART=false
RESTART_COUNT=0
REPO_OVERRIDE=""
VERSION="3.2.4"

# ─── Token Tracking ─────────────────────────────────────────────────────────
LOOP_INPUT_TOKENS=0
LOOP_OUTPUT_TOKENS=0
LOOP_COST_MILLICENTS=0

# ─── Flexible Iteration Defaults ────────────────────────────────────────────
AUTO_EXTEND=true          # Auto-extend iterations when work is incomplete
EXTENSION_SIZE=5          # Additional iterations per extension
MAX_EXTENSIONS=3          # Max number of extensions (hard cap safety net)
EXTENSION_COUNT=0         # Current number of extensions applied

# ─── Circuit Breaker Defaults ──────────────────────────────────────────────
CIRCUIT_BREAKER_THRESHOLD=3       # Consecutive low-progress iterations before stopping
MIN_PROGRESS_LINES=5              # Minimum insertions to count as progress

# ─── Audit & Quality Gate Defaults ───────────────────────────────────────────
AUDIT_ENABLED=false
AUDIT_AGENT_ENABLED=false
DOD_FILE=""
QUALITY_GATES_ENABLED=false
AUDIT_RESULT=""
COMPLETION_REJECTED=false
QUALITY_GATE_PASSED=true

# ─── Multi-Test Defaults ──────────────────────────────────────────────────
ADDITIONAL_TEST_CMDS=()   # Array of extra test commands (from --additional-test-cmds)

# ─── Context Budget ──────────────────────────────────────────────────────────
CONTEXT_BUDGET_CHARS="${CONTEXT_BUDGET_CHARS:-200000}"  # Max prompt chars before trimming

# ─── Claude CLI Flags ─────────────────────────────────────────────────────────
EFFORT_LEVEL="${SW_EFFORT_LEVEL:-}"
FALLBACK_MODEL="${SW_FALLBACK_MODEL:-sonnet}"

# ─── Parse Arguments ──────────────────────────────────────────────────────────
# NOTE: show_help() is now in lib/loop-display.sh

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO_OVERRIDE="${2:-}"
            [[ -z "$REPO_OVERRIDE" ]] && { error "Missing value for --repo"; exit 1; }
            shift 2
            ;;
        --repo=*) REPO_OVERRIDE="${1#--repo=}"; shift ;;
        --local)
            # Skip GitHub operations in loop
            export NO_GITHUB=true
            shift ;;
        --max-iterations)
            MAX_ITERATIONS="${2:-}"
            MAX_ITERATIONS_EXPLICIT=true
            [[ -z "$MAX_ITERATIONS" ]] && { error "Missing value for --max-iterations"; exit 1; }
            shift 2
            ;;
        --max-iterations=*) MAX_ITERATIONS="${1#--max-iterations=}"; MAX_ITERATIONS_EXPLICIT=true; shift ;;
        --test-cmd)
            TEST_CMD="${2:-}"
            [[ -z "$TEST_CMD" ]] && { error "Missing value for --test-cmd"; exit 1; }
            shift 2
            ;;
        --test-cmd=*) TEST_CMD="${1#--test-cmd=}"; shift ;;
        --model)
            MODEL="${2:-}"
            [[ -z "$MODEL" ]] && { error "Missing value for --model"; exit 1; }
            shift 2
            ;;
        --model=*) MODEL="${1#--model=}"; shift ;;
        --effort)
            EFFORT_LEVEL="${2:-}"
            [[ -z "$EFFORT_LEVEL" ]] && { error "Missing value for --effort"; exit 1; }
            shift 2
            ;;
        --effort=*) EFFORT_LEVEL="${1#--effort=}"; shift ;;
        --fallback-model)
            FALLBACK_MODEL="${2:-}"
            [[ -z "$FALLBACK_MODEL" ]] && { error "Missing value for --fallback-model"; exit 1; }
            shift 2
            ;;
        --fallback-model=*) FALLBACK_MODEL="${1#--fallback-model=}"; shift ;;
        --agents)
            AGENTS="${2:-}"
            [[ -z "$AGENTS" ]] && { error "Missing value for --agents"; exit 1; }
            shift 2
            ;;
        --agents=*) AGENTS="${1#--agents=}"; shift ;;
        --worktree) USE_WORKTREE=true; shift ;;
        --skip-permissions) SKIP_PERMISSIONS=true; shift ;;
        --max-turns)
            MAX_TURNS="${2:-}"
            [[ -z "$MAX_TURNS" ]] && { error "Missing value for --max-turns"; exit 1; }
            shift 2
            ;;
        --max-turns=*) MAX_TURNS="${1#--max-turns=}"; shift ;;
        --resume) RESUME=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --audit) AUDIT_ENABLED=true; shift ;;
        --audit-agent) AUDIT_AGENT_ENABLED=true; shift ;;
        --definition-of-done)
            DOD_FILE="${2:-}"
            [[ -z "$DOD_FILE" ]] && { error "Missing value for --definition-of-done"; exit 1; }
            shift 2
            ;;
        --definition-of-done=*) DOD_FILE="${1#--definition-of-done=}"; shift ;;
        --quality-gates) QUALITY_GATES_ENABLED=true; shift ;;
        --no-auto-extend) AUTO_EXTEND=false; shift ;;
        --extension-size)
            EXTENSION_SIZE="${2:-}"
            [[ -z "$EXTENSION_SIZE" ]] && { error "Missing value for --extension-size"; exit 1; }
            shift 2
            ;;
        --extension-size=*) EXTENSION_SIZE="${1#--extension-size=}"; shift ;;
        --max-extensions)
            MAX_EXTENSIONS="${2:-}"
            [[ -z "$MAX_EXTENSIONS" ]] && { error "Missing value for --max-extensions"; exit 1; }
            shift 2
            ;;
        --max-extensions=*) MAX_EXTENSIONS="${1#--max-extensions=}"; shift ;;
        --fast-test-cmd)
            FAST_TEST_CMD="${2:-}"
            [[ -z "$FAST_TEST_CMD" ]] && { error "Missing value for --fast-test-cmd"; exit 1; }
            shift 2
            ;;
        --fast-test-cmd=*) FAST_TEST_CMD="${1#--fast-test-cmd=}"; shift ;;
        --fast-test-interval)
            FAST_TEST_INTERVAL="${2:-}"
            [[ -z "$FAST_TEST_INTERVAL" ]] && { error "Missing value for --fast-test-interval"; exit 1; }
            shift 2
            ;;
        --fast-test-interval=*) FAST_TEST_INTERVAL="${1#--fast-test-interval=}"; shift ;;
        --additional-test-cmds)
            ADDITIONAL_TEST_CMDS+=("${2:-}")
            [[ -z "${2:-}" ]] && { error "Missing value for --additional-test-cmds"; exit 1; }
            shift 2
            ;;
        --additional-test-cmds=*) ADDITIONAL_TEST_CMDS+=("${1#--additional-test-cmds=}"); shift ;;
        --max-restarts)
            MAX_RESTARTS="${2:-}"
            [[ -z "$MAX_RESTARTS" ]] && { error "Missing value for --max-restarts"; exit 1; }
            shift 2
            ;;
        --max-restarts=*) MAX_RESTARTS="${1#--max-restarts=}"; shift ;;
        --roles)
            AGENT_ROLES="${2:-}"
            [[ -z "$AGENT_ROLES" ]] && { error "Missing value for --roles"; exit 1; }
            shift 2
            ;;
        --roles=*) AGENT_ROLES="${1#--roles=}"; shift ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            echo ""
            show_help
            exit 1
            ;;
        *)
            # Positional: goal
            if [[ -z "$GOAL" ]]; then
                GOAL="$1"
            else
                error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Auto-enable worktree for multi-agent
if [[ "$AGENTS" -gt 1 ]]; then
    # shellcheck disable=SC2034
    USE_WORKTREE=true
fi

# Recruit-powered auto-role assignment when multi-agent but no roles specified
if [[ "$AGENTS" -gt 1 ]] && [[ -z "$AGENT_ROLES" ]] && [[ -x "${SCRIPT_DIR:-}/sw-recruit.sh" ]]; then
    _recruit_goal="${GOAL:-}"
    if [[ -n "$_recruit_goal" ]]; then
        _recruit_team=$(bash "$SCRIPT_DIR/sw-recruit.sh" team --json "$_recruit_goal" 2>/dev/null) || true
        if [[ -n "$_recruit_team" ]]; then
            _recruit_roles=$(echo "$_recruit_team" | jq -r '.team | join(",")' 2>/dev/null) || true
            if [[ -n "$_recruit_roles" && "$_recruit_roles" != "null" ]]; then
                AGENT_ROLES="$_recruit_roles"
                info "Recruit assigned roles: ${AGENT_ROLES}"
            fi
        fi
    fi
fi

# Warn if --roles without --agents
if [[ -n "$AGENT_ROLES" ]] && [[ "$AGENTS" -le 1 ]]; then
    warn "--roles requires --agents > 1 (roles are ignored in single-agent mode)"
fi

# max-restarts is supported in both single-agent and multi-agent mode
# In multi-agent mode, restarts apply per-agent (agent can be respawned up to MAX_RESTARTS)

# Validate numeric flags
if ! [[ "$FAST_TEST_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    error "--fast-test-interval must be a positive integer (got: $FAST_TEST_INTERVAL)"
    exit 1
fi
if ! [[ "$MAX_RESTARTS" =~ ^[0-9]+$ ]]; then
    error "--max-restarts must be a non-negative integer (got: $MAX_RESTARTS)"
    exit 1
fi

# Validate effort level
if [[ -n "$EFFORT_LEVEL" ]] && [[ "$EFFORT_LEVEL" != "low" && "$EFFORT_LEVEL" != "medium" && "$EFFORT_LEVEL" != "high" ]]; then
    error "--effort must be low, medium, or high (got: $EFFORT_LEVEL)"
    exit 1
fi

# ─── Validate Inputs ─────────────────────────────────────────────────────────

if ! $RESUME && [[ -z "$GOAL" ]]; then
    error "Missing goal. Usage: shipwright loop \"<goal>\" [options]"
    echo ""
    echo -e "  ${DIM}shipwright loop \"Build user auth with JWT\"${RESET}"
    echo -e "  ${DIM}shipwright loop --resume${RESET}"
    exit 1
fi

# Handle --repo flag: change to directory before running
if [[ -n "$REPO_OVERRIDE" ]]; then
    if [[ ! -d "$REPO_OVERRIDE" ]]; then
        error "Directory does not exist: $REPO_OVERRIDE"
        exit 1
    fi
    if ! cd "$REPO_OVERRIDE" 2>/dev/null; then
        error "Cannot cd to: $REPO_OVERRIDE"
        exit 1
    fi
    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        error "Not a git repository: $REPO_OVERRIDE"
        exit 1
    fi
    info "Using repository: $(pwd)"
fi

if ! command -v claude >/dev/null 2>&1; then
    error "Claude Code CLI not found. Install it first:"
    echo -e "  ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    error "Not inside a git repository. The loop requires git for progress tracking."
    exit 1
fi

# Preserve original goal before any appending (memory fixes, human feedback)
ORIGINAL_GOAL="$GOAL"

# ─── Timeout Detection ────────────────────────────────────────────────────────
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-$(_config_get_int "loop.claude_timeout" 1800 2>/dev/null || echo 1800)}"  # 30 min default

if [[ "$AGENTS" -gt 1 ]]; then
    if ! command -v tmux >/dev/null 2>&1; then
        error "tmux is required for multi-agent mode."
        echo -e "  ${DIM}brew install tmux${RESET}  (macOS)"
        exit 1
    fi
    if [[ -z "${TMUX:-}" ]]; then
        error "Multi-agent mode requires running inside tmux."
        echo -e "  ${DIM}tmux new -s work${RESET}"
        exit 1
    fi
fi

# ─── Directory Setup ─────────────────────────────────────────────────────────

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="$PROJECT_ROOT/.claude"
STATE_FILE="$STATE_DIR/loop-state.md"
LOG_DIR="$STATE_DIR/loop-logs"
WORKTREE_DIR="$PROJECT_ROOT/.worktrees"

mkdir -p "$STATE_DIR" "$LOG_DIR"

# ─── Context Budget Initialization ────────────────────────────────────────────
# Initialize context window budget tracker (issue #209)
ARTIFACTS_DIR="${STATE_DIR}/pipeline-artifacts"
mkdir -p "$ARTIFACTS_DIR"
if type context_budget_init >/dev/null 2>&1; then
    # Set total budget (default 800K, configurable via env/config)
    CONTEXT_BUDGET="${CONTEXT_BUDGET_TOKENS:-800000}"
    context_budget_init "$CONTEXT_BUDGET" "$ARTIFACTS_DIR" 2>/dev/null || true
fi

# ─── Stuckness Detection State ───────────────────────────────────────────────
STUCKNESS_COUNT=0
STUCKNESS_TRACKING_FILE=""

# ─── Signal Handling ──────────────────────────────────────────────────────────

CHILD_PID=""

cleanup() {
    echo ""
    warn "Loop interrupted at iteration $ITERATION"

    # Kill any running Claude process
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi

    # If multi-agent, kill worker panes
    if [[ "$AGENTS" -gt 1 ]]; then
        cleanup_multi_agent
    fi

    STATUS="interrupted"
    write_state

    # Save checkpoint on interruption
    "$SCRIPT_DIR/sw-checkpoint.sh" save \
        --stage "build" \
        --iteration "$ITERATION" \
        --git-sha "$(git rev-parse HEAD 2>/dev/null || echo unknown)" 2>/dev/null || true

    # Save Claude context for meaningful resume (goal, findings, test output)
    export SW_LOOP_GOAL="$GOAL"
    export SW_LOOP_ITERATION="$ITERATION"
    export SW_LOOP_STATUS="$STATUS"
    export SW_LOOP_TEST_OUTPUT="${TEST_OUTPUT:-}"
    export SW_LOOP_FINDINGS="${LOG_ENTRIES:-}"
    # shellcheck disable=SC2155
    export SW_LOOP_MODIFIED="$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')"
    "$SCRIPT_DIR/sw-checkpoint.sh" save-context --stage build 2>/dev/null || true

    # Clear heartbeat
    "$SCRIPT_DIR/sw-heartbeat.sh" clear "${PIPELINE_JOB_ID:-loop-$$}" 2>/dev/null || true

    show_summary
    exit 130
}

trap cleanup SIGINT SIGTERM


# ─── Main: Single-Agent Loop ─────────────────────────────────────────────────

run_single_agent_loop() {
    # Save original environment variables before loop starts
    local SAVED_CLAUDE_MODEL="${CLAUDE_MODEL:-}"
    local SAVED_ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

    if [[ "$SESSION_RESTART" == "true" ]]; then
        # Restart: state already reset by run_loop_with_restarts, skip init
        # Restore environment variables for clean iteration state
        [[ -n "$SAVED_CLAUDE_MODEL" ]] && export CLAUDE_MODEL="$SAVED_CLAUDE_MODEL"
        info "Session restart ${RESTART_COUNT}/${MAX_RESTARTS} — fresh context, reading progress"
    elif $RESUME; then
        resume_state
    else
        initialize_state
    fi

    # Ensure LOOP_START_COMMIT is set (may not be on resume/restart)
    if [[ -z "${LOOP_START_COMMIT:-}" ]]; then
        LOOP_START_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
    fi

    # Apply adaptive budget/model before showing banner
    apply_adaptive_budget
    MODEL="$(select_adaptive_model "build" "$MODEL")"

    # Track applied memory fix patterns for outcome recording
    _applied_fix_pattern=""
    STUCKNESS_COUNT=0
    STUCKNESS_TRACKING_FILE="$LOG_DIR/stuckness-tracking.txt"
    : > "$STUCKNESS_TRACKING_FILE" 2>/dev/null || true
    : > "${LOG_DIR}/strategy-attempts.txt" 2>/dev/null || true

    show_banner

    while true; do
        # Reset environment variables at start of each iteration
        # Prevents previous iterations from affecting model selection or API keys
        [[ -n "$SAVED_CLAUDE_MODEL" ]] && export CLAUDE_MODEL="$SAVED_CLAUDE_MODEL"
        [[ -n "$SAVED_ANTHROPIC_API_KEY" ]] && export ANTHROPIC_API_KEY="$SAVED_ANTHROPIC_API_KEY"

        # Pre-checks (before incrementing — ITERATION tracks completed count)
        check_circuit_breaker || break
        check_max_iterations || break
        check_budget_gate || {
            STATUS="budget_exhausted"
            write_state
            write_progress
            error "Budget exhausted — stopping pipeline"
            show_summary
            return 1
        }
        ITERATION=$(( ITERATION + 1 ))

        # Emit iteration start event for pipeline visibility
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.iteration_start" \
                "iteration=$ITERATION" \
                "max=$MAX_ITERATIONS" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}" \
                "agent=${AGENT_NUM:-1}" \
                "test_passed=${TEST_PASSED:-unknown}"
        fi

        # Root-cause diagnosis and memory-based fix on retry after test failure
        if [[ "${TEST_PASSED:-}" == "false" ]]; then
            # Source memory module for diagnosis and fix lookup
            [[ -f "$SCRIPT_DIR/sw-memory.sh" ]] && source "$SCRIPT_DIR/sw-memory.sh" 2>/dev/null || true

            # Capture failure for memory (enables memory_analyze_failure and future fix lookup)
            if type memory_capture_failure &>/dev/null && [[ -n "${TEST_OUTPUT:-}" ]]; then
                memory_capture_failure "test" "$TEST_OUTPUT" 2>/dev/null || true
            fi

            # Pattern-based diagnosis (no Claude needed) — inject into goal for smarter retry
            local _changed_files=""
            _changed_files=$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')
            local _diagnosis
            _diagnosis=$(diagnose_failure "${TEST_OUTPUT:-}" "$_changed_files" "$ITERATION" 2>/dev/null || true)

            if [[ -n "$_diagnosis" ]]; then
                GOAL="${GOAL}

${_diagnosis}"
                info "Failure diagnosis injected (classification from error pattern)"
            fi

            # Memory-based fix suggestion (from past successful fixes)
            local _last_error=""
            local _prev_log="$LOG_DIR/iteration-$(( ITERATION - 1 )).log"
            if [[ -f "$_prev_log" ]]; then
                _last_error=$(tail -20 "$_prev_log" 2>/dev/null | grep -iE '(error|fail|exception)' | head -1 || true)
            fi
            [[ -z "$_last_error" ]] && _last_error=$(echo "${TEST_OUTPUT:-}" | head -3 | tr '\n' ' ')
            local _fix_suggestion=""
            if type memory_closed_loop_inject >/dev/null 2>&1 && [[ -n "${_last_error:-}" ]]; then
                _fix_suggestion=$(memory_closed_loop_inject "$_last_error" 2>/dev/null) || true
            fi
            if [[ -n "${_fix_suggestion:-}" ]]; then
                _applied_fix_pattern="${_last_error}"
                GOAL="KNOWN FIX (from past success): ${_fix_suggestion}

${GOAL}"
                info "Memory fix injected: ${_fix_suggestion:0:80}"
            fi

            # Analyze failure via Claude (background, non-blocking) for richer root_cause/fix in memory
            if type memory_analyze_failure &>/dev/null && [[ "${INTELLIGENCE_ENABLED:-auto}" != "false" ]]; then
                local _test_log="${TEST_LOG_FILE:-$LOG_DIR/tests-iter-$(( ITERATION - 1 )).log}"
                if [[ -f "$_test_log" ]]; then
                    memory_analyze_failure "$_test_log" "test" 2>/dev/null &
                fi
            fi
        fi

        # Run Claude
        local exit_code=0
        run_claude_iteration || exit_code=$?

        local log_file="$LOG_DIR/iteration-${ITERATION}.log"

        # Record iteration data for stuckness detection (diff hash, error hash, exit code)
        record_iteration_stuckness_data "$exit_code"

        # Detect fatal CLI errors (API key, auth, network) — abort immediately
        if check_fatal_error "$log_file" "$exit_code"; then
            STATUS="error"
            write_state
            write_progress
            error "Fatal CLI error detected — aborting loop (see iteration log)"
            show_summary
            return 1
        fi

        # Mid-loop memory refresh — re-query with current error context after iteration 3
        if [[ "$ITERATION" -ge 3 ]] && type memory_inject_context >/dev/null 2>&1; then
            local refresh_ctx
            refresh_ctx=$(tail -20 "$log_file" 2>/dev/null || true)
            if [[ -n "$refresh_ctx" ]]; then
                local refreshed_memory
                refreshed_memory=$(memory_inject_context "build" "$refresh_ctx" 2>/dev/null | head -5 || true)
                if [[ -n "$refreshed_memory" ]]; then
                    # Append to next iteration's memory context
                    local memory_refresh_file="$LOG_DIR/memory-refresh-${ITERATION}.txt"
                    echo "$refreshed_memory" > "$memory_refresh_file"
                fi
            fi
        fi

        # Auto-commit if Claude didn't
        local commits_before
        commits_before="$(git_commit_count)"
        git_auto_commit "$PROJECT_ROOT" || true
        local commits_after
        commits_after="$(git_commit_count)"
        local new_commits=$(( commits_after - commits_before ))
        TOTAL_COMMITS=$(( TOTAL_COMMITS + new_commits ))

        # Git diff stats
        local diff_stat
        diff_stat="$(git_diff_stat)"
        if [[ -n "$diff_stat" ]]; then
            echo -e "  ${GREEN}✓${RESET} Git: $diff_stat"
        fi

        # Track velocity for adaptive extension budget
        track_iteration_velocity

        # Test gate
        run_test_gate
        write_error_summary
        if [[ -n "$TEST_CMD" ]]; then
            if [[ "$TEST_PASSED" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Tests: passed"
            else
                echo -e "  ${RED}✗${RESET} Tests: failed"
            fi
        fi

        # Track fix outcome for memory effectiveness
        if [[ -n "${_applied_fix_pattern:-}" ]]; then
            if type memory_record_fix_outcome >/dev/null 2>&1; then
                if [[ "${TEST_PASSED:-}" == "true" ]]; then
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "true" 2>/dev/null || true
                else
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "false" 2>/dev/null || true
                fi
            fi
            _applied_fix_pattern=""
        fi

        # Save Claude context for checkpoint resume (goal, findings, test output)
        export SW_LOOP_GOAL="$GOAL"
        export SW_LOOP_ITERATION="$ITERATION"
        export SW_LOOP_STATUS="${STATUS:-running}"
        export SW_LOOP_TEST_OUTPUT="${TEST_OUTPUT:-}"
        export SW_LOOP_FINDINGS="${LOG_ENTRIES:-}"
        # shellcheck disable=SC2155
        export SW_LOOP_MODIFIED="$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')"
        "$SCRIPT_DIR/sw-checkpoint.sh" save-context --stage build 2>/dev/null || true

        # Audit agent (reviews implementer's work)
        run_audit_agent

        # Verification gap detection: audit failed but tests passed
        # Instead of a full retry (which causes context bloat/timeout), run targeted verification
        if [[ "${AUDIT_RESULT:-}" != "pass" ]] && [[ "${TEST_PASSED:-}" == "true" ]]; then
            echo -e "  ${YELLOW}▸${RESET} Verification gap detected (tests pass, audit disagrees)"

            local verification_passed=true

            # 1. Re-run ALL test commands to double-check
            local recheck_log="${LOG_DIR}/verification-iter-${ITERATION}.log"
            if [[ -n "$TEST_CMD" ]]; then
                eval "$TEST_CMD" > "$recheck_log" 2>&1 || verification_passed=false
            fi
            for _vg_cmd in "${ADDITIONAL_TEST_CMDS[@]+"${ADDITIONAL_TEST_CMDS[@]}"}"; do
                [[ -z "$_vg_cmd" ]] && continue
                eval "$_vg_cmd" >> "$recheck_log" 2>&1 || verification_passed=false
            done

            # 2. Check for uncommitted changes (quality gate)
            if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null; then
                echo -e "  ${YELLOW}⚠${RESET} Uncommitted changes detected"
                verification_passed=false
            fi

            if [[ "$verification_passed" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Verification passed — overriding audit"
                AUDIT_RESULT="pass"
                emit_event "loop.verification_gap_resolved" \
                    "iteration=$ITERATION" "action=override_audit"
                if type audit_emit >/dev/null 2>&1; then
                    audit_emit "loop.verification_gap" "iteration=$ITERATION" \
                        "resolution=override" "tests_recheck=pass" || true
                fi
            else
                echo -e "  ${RED}✗${RESET} Verification failed — audit stands"
                emit_event "loop.verification_gap_confirmed" \
                    "iteration=$ITERATION" "action=retry"
                if type audit_emit >/dev/null 2>&1; then
                    audit_emit "loop.verification_gap" "iteration=$ITERATION" \
                        "resolution=retry" "tests_recheck=fail" || true
                fi
            fi
        fi

        # Auto-commit any remaining changes before quality gates
        # (audit agent, verification handler, or test evidence may create files)
        if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || \
           ! git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null || \
           [[ -n "$(git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]; then
            git -C "$PROJECT_ROOT" add -A 2>/dev/null || true
            git -C "$PROJECT_ROOT" commit -m "loop: iteration $ITERATION — post-audit cleanup" --no-verify 2>/dev/null || true
        fi

        # Quality gates (automated checks)
        run_quality_gates

        # Convergence detection (issue #203) — score iteration progress and detect convergence
        if type convergence_integrate >/dev/null 2>&1; then
            local conv_exit=0
            convergence_integrate || conv_exit=$?
            case "$conv_exit" in
                1)
                    # Converged — stop successfully
                    info "Build loop converged — stopping"
                    STATUS="complete"
                    write_state
                    write_progress
                    show_summary
                    return 0
                    ;;
                2)
                    # Diverging — stop with failure
                    warn "Build loop diverging — stopping (scores declining consistently)"
                    STATUS="diverging"
                    write_state
                    write_progress
                    show_summary
                    return 1
                    ;;
                3)
                    # Oscillating — escalate to manual review
                    warn "Build loop oscillating — consider manual review or model escalation"
                    ;;
            esac
        fi

        # Guarded completion (replaces naive grep check)
        if guard_completion; then
            STATUS="complete"
            write_state
            write_progress
            show_summary
            return 0
        fi

        # Check progress (circuit breaker)
        if check_progress; then
            CONSECUTIVE_FAILURES=0
            echo -e "  ${GREEN}✓${RESET} Progress detected — continuing"
        else
            CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
            echo -e "  ${YELLOW}⚠${RESET} Low progress (${CONSECUTIVE_FAILURES}/${CIRCUIT_BREAKER_THRESHOLD} before circuit breaker)"
        fi

        # Extract summary and update state
        local summary
        summary="$(extract_summary "$log_file")"
        append_log_entry "### Iteration $ITERATION ($(now_iso))
$summary
"
        write_state
        write_progress

        # Emit iteration complete event for pipeline visibility
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.iteration_complete" \
                "iteration=$ITERATION" \
                "max=$MAX_ITERATIONS" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}" \
                "agent=${AGENT_NUM:-1}" \
                "test_passed=${TEST_PASSED:-unknown}" \
                "commits=$TOTAL_COMMITS" \
                "status=${STATUS:-running}"
        fi

        # Update heartbeat
        "$SCRIPT_DIR/sw-heartbeat.sh" write "${PIPELINE_JOB_ID:-loop-$$}" \
            --pid $$ \
            --stage "build" \
            --iteration "$ITERATION" \
            --activity "Loop iteration $ITERATION" 2>/dev/null || true

        # Human intervention: check for human message between iterations
        local human_msg_file="$STATE_DIR/pipeline-artifacts/human-message.txt"
        if [[ -f "$human_msg_file" ]]; then
            local human_msg
            human_msg="$(cat "$human_msg_file" 2>/dev/null || true)"
            if [[ -n "$human_msg" ]]; then
                echo -e "  ${PURPLE}${BOLD}💬 Human message:${RESET} $human_msg"
                # Inject human message as additional context for next iteration
                GOAL="${GOAL}

HUMAN FEEDBACK (received after iteration $ITERATION): $human_msg"
                rm -f "$human_msg_file"
            fi
        fi

        # Stuckness-triggered restart: if detected 3+ times, break to allow session restart
        if [[ "${STUCKNESS_COUNT:-0}" -ge 3 ]]; then
            STATUS="stuck_restart"
            write_state
            write_progress
            warn "Stuckness detected 3+ times — triggering session restart"
            break
        fi

        sleep "$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)"
    done

    # Write final state after loop exits
    write_state
    write_progress
    show_summary
}

# ─── Session Restart Wrapper ─────────────────────────────────────────────────

run_loop_with_restarts() {
    while true; do
        local loop_exit=0
        run_single_agent_loop || loop_exit=$?

        # If completed successfully or no restarts configured, exit
        if [[ "$STATUS" == "complete" ]]; then
            return 0
        fi
        if [[ "$MAX_RESTARTS" -le 0 ]]; then
            return "$loop_exit"
        fi
        if [[ "$RESTART_COUNT" -ge "$MAX_RESTARTS" ]]; then
            warn "Max restarts ($MAX_RESTARTS) reached — stopping"
            return "$loop_exit"
        fi
        # Hard cap safety net
        if [[ "$RESTART_COUNT" -ge 5 ]]; then
            warn "Hard restart cap (5) reached — stopping"
            return "$loop_exit"
        fi

        # Check if tests are still failing (worth restarting)
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            info "Tests passing but loop incomplete — restarting session"
        else
            info "Tests failing and loop exhausted — restarting with fresh context"
        fi

        RESTART_COUNT=$(( RESTART_COUNT + 1 ))

        # Capture comprehensive state and generate briefing before restart
        if type restart_before_restart >/dev/null 2>&1; then
            restart_before_restart || warn "Failed to prepare restart briefing (continuing anyway)"
        fi

        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.restart" "restart=$RESTART_COUNT" "max=$MAX_RESTARTS" "iteration=$ITERATION"
        fi
        info "Session restart ${RESTART_COUNT}/${MAX_RESTARTS} — resetting iteration counter"

        # Reset ALL iteration-level state for the new session
        # SESSION_RESTART tells run_single_agent_loop to skip init/resume
        SESSION_RESTART=true
        ITERATION=0
        CONSECUTIVE_FAILURES=0
        EXTENSION_COUNT=0
        STUCKNESS_COUNT=0
        STATUS="running"
        LOG_ENTRIES=""
        TEST_PASSED=""
        TEST_OUTPUT=""
        TEST_LOG_FILE=""
        # Reset GOAL to original — prevent unbounded growth from memory/human injections
        GOAL="$ORIGINAL_GOAL"

        # Archive old artifacts so they don't get overwritten or pollute new session
        local restart_archive="$LOG_DIR/restart-${RESTART_COUNT}"
        mkdir -p "$restart_archive"
        for old_log in "$LOG_DIR"/iteration-*.log "$LOG_DIR"/tests-iter-*.log; do
            [[ -f "$old_log" ]] && mv "$old_log" "$restart_archive/" 2>/dev/null || true
        done
        # Archive progress.md and error-summary.json from previous session
        # IMPORTANT: copy (not move) error-summary.json so the fresh session can still read it
        [[ -f "$LOG_DIR/progress.md" ]] && cp "$LOG_DIR/progress.md" "$restart_archive/progress.md" 2>/dev/null || true
        [[ -f "$LOG_DIR/error-summary.json" ]] && cp "$LOG_DIR/error-summary.json" "$restart_archive/" 2>/dev/null || true

        write_state

        sleep "$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)"
    done
}

# ─── Main: Entry Point ───────────────────────────────────────────────────────

main() {
    if [[ "$AGENTS" -gt 1 ]]; then
        if $RESUME; then
            resume_state
        else
            initialize_state
        fi
        show_banner
        launch_multi_agent
        show_summary
    else
        run_loop_with_restarts
    fi
}

main
