#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars used by sourced scripts and subshells
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline — Autonomous Feature Delivery (Idea → Production)        ║
# ║  Full GitHub integration · Auto-detection · Task tracking · Metrics    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Allow spawning Claude CLI from within a Claude Code session (daemon, fleet, etc.)
unset CLAUDECODE 2>/dev/null || true
# Ignore SIGHUP so tmux attach/detach doesn't kill long-running plan/design/review stages
trap '' HUP
trap '' SIGPIPE

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
# Policy + pipeline quality thresholds (config/policy.json via lib/pipeline-quality.sh)
[[ -f "$SCRIPT_DIR/lib/pipeline-quality.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-quality.sh"
# shellcheck source=lib/pipeline-state.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-state.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-state.sh"
# shellcheck source=lib/pipeline-github.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-github.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-github.sh"
# shellcheck source=lib/pipeline-detection.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-detection.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-detection.sh"
# shellcheck source=lib/pipeline-quality-checks.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-quality-checks.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-quality-checks.sh"
# shellcheck source=lib/pipeline-intelligence.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-intelligence.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-intelligence.sh"
# shellcheck source=lib/pipeline-stages.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-stages.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-stages.sh"
# Audit trail for compliance-grade pipeline traceability
# shellcheck source=lib/audit-trail.sh
[[ -f "$SCRIPT_DIR/lib/audit-trail.sh" ]] && source "$SCRIPT_DIR/lib/audit-trail.sh" 2>/dev/null || true
# Extracted pipeline libraries (dependency order: utils → execution → lifecycle)
# shellcheck source=lib/pipeline-utils.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-utils.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-utils.sh"
# shellcheck source=lib/pipeline-execution.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-execution.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-execution.sh"
# shellcheck source=lib/pipeline-orchestrator.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-orchestrator.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-orchestrator.sh"
# shellcheck source=lib/pipeline-lifecycle.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-lifecycle.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-lifecycle.sh"
PIPELINE_COVERAGE_THRESHOLD="${PIPELINE_COVERAGE_THRESHOLD:-60}"
PIPELINE_QUALITY_GATE_THRESHOLD="${PIPELINE_QUALITY_GATE_THRESHOLD:-70}"

# ─── Optional modules (intelligence, memory, optimization) ────────────────
for _opt_src in sw-intelligence.sh sw-pipeline-composer.sh sw-developer-simulation.sh \
    sw-architecture-enforcer.sh sw-adversarial.sh sw-pipeline-vitals.sh \
    sw-memory.sh sw-self-optimize.sh sw-discovery.sh sw-durable.sh; do
    [[ -f "$SCRIPT_DIR/$_opt_src" ]] && source "$SCRIPT_DIR/$_opt_src"
done
# shellcheck source=sw-db.sh
# for db_save_checkpoint/db_load_checkpoint (durable workflows)
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"
# Ensure DB schema exists so emit_event → db_add_event can write rows (CREATE IF NOT EXISTS is idempotent)
if type init_schema >/dev/null 2>&1 && type check_sqlite3 >/dev/null 2>&1 && check_sqlite3 2>/dev/null; then
    init_schema 2>/dev/null || true
fi
# shellcheck source=sw-cost.sh
# for cost_record persistence to costs.json + DB
[[ -f "$SCRIPT_DIR/sw-cost.sh" ]] && source "$SCRIPT_DIR/sw-cost.sh"
# shellcheck source=lib/skill-registry.sh
# for skill_analyze_outcome (AI outcome learning)
[[ -f "$SCRIPT_DIR/lib/skill-registry.sh" ]] && source "$SCRIPT_DIR/lib/skill-registry.sh"
# shellcheck source=lib/skill-memory.sh
# for skill memory operations
[[ -f "$SCRIPT_DIR/lib/skill-memory.sh" ]] && source "$SCRIPT_DIR/lib/skill-memory.sh"

# ─── GitHub API Modules (optional) ─────────────────────────────────────────
# shellcheck source=sw-github-graphql.sh
[[ -f "$SCRIPT_DIR/sw-github-graphql.sh" ]] && source "$SCRIPT_DIR/sw-github-graphql.sh"
# shellcheck source=sw-github-checks.sh
[[ -f "$SCRIPT_DIR/sw-github-checks.sh" ]] && source "$SCRIPT_DIR/sw-github-checks.sh"
# shellcheck source=sw-github-deploy.sh
[[ -f "$SCRIPT_DIR/sw-github-deploy.sh" ]] && source "$SCRIPT_DIR/sw-github-deploy.sh"

# ─── Defaults ───────────────────────────────────────────────────────────────
GOAL=""
ISSUE_NUMBER=""
PIPELINE_NAME="standard"
PIPELINE_CONFIG=""
TEST_CMD=""
MODEL=""
AGENTS=""
PIPELINE_AGENT_ID="${PIPELINE_AGENT_ID:-pipeline-$$}"
SKIP_GATES=false
HEADLESS=false
GIT_BRANCH=""
GITHUB_ISSUE=""
TASK_TYPE=""
REVIEWERS=""
LABELS=""
BASE_BRANCH="main"
NO_GITHUB=false
NO_GITHUB_LABEL=false
CI_MODE=false
DRY_RUN=false
IGNORE_BUDGET=false
COMPLETED_STAGES=""
RESUME_FROM_CHECKPOINT=false
MAX_ITERATIONS_OVERRIDE=""
MAX_RESTARTS_OVERRIDE=""
FAST_TEST_CMD_OVERRIDE=""
PR_NUMBER=""
AUTO_WORKTREE=false
WORKTREE_NAME=""
CLEANUP_WORKTREE=false
ORIGINAL_REPO_DIR=""
REPO_OVERRIDE=""
_cleanup_done=""
PIPELINE_EXIT_CODE=1  # assume failure until run_pipeline succeeds

# GitHub metadata (populated during intake)
ISSUE_LABELS=""
ISSUE_MILESTONE=""
ISSUE_ASSIGNEES=""
ISSUE_BODY=""
PROGRESS_COMMENT_ID=""
REPO_OWNER=""
REPO_NAME=""
GH_AVAILABLE=false

# Timing
PIPELINE_START_EPOCH=""
STAGE_TIMINGS=""
PIPELINE_STAGES_PASSED=""
PIPELINE_SLOWEST_STAGE=""
LAST_STAGE_ERROR_CLASS=""
LAST_STAGE_ERROR=""

PROJECT_ROOT=""
STATE_DIR=""
STATE_FILE=""
ARTIFACTS_DIR=""
TASKS_FILE=""

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright pipeline${RESET} — Autonomous Feature Delivery"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright pipeline${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}start${RESET}   --goal \"...\"    Start a new pipeline"
    echo -e "  ${CYAN}resume${RESET}                  Continue from last completed stage"
    echo -e "  ${CYAN}status${RESET}                  Show pipeline progress dashboard"
    echo -e "  ${CYAN}abort${RESET}                   Stop pipeline and mark aborted"
    echo -e "  ${CYAN}list${RESET}                    Show available pipeline templates"
    echo -e "  ${CYAN}show${RESET}    <name>          Display pipeline stages"
    echo ""
    echo -e "${BOLD}START OPTIONS${RESET}"
    echo -e "  ${DIM}--goal \"desc\"${RESET}  What to build    ${DIM}--issue <N>${RESET}  Fetch from GitHub"
    echo -e "  ${DIM}--pipeline <name>${RESET}  Template       ${DIM}--test-cmd <cmd>${RESET}  Override tests"
    echo -e "  ${DIM}--model <m>${RESET}  AI model             ${DIM}--agents <n>${RESET}  Agent count"
    echo -e "  ${DIM}--skip-gates${RESET}  Auto-approve       ${DIM}--headless${RESET}  No prompts"
    echo -e "  ${DIM}--ci${RESET}  CI mode                     ${DIM}--dry-run${RESET}  Preview only"
    echo -e "  ${DIM}--worktree [=name]${RESET}  Isolation    ${DIM}--no-github${RESET}  Offline"
    echo -e "  ${DIM}--base <branch>${RESET}  PR base          ${DIM}--reviewers \"a,b\"${RESET}  PR reviewers"
    echo -e "  ${DIM}--self-heal <n>${RESET}  Retry cycles     ${DIM}--max-iterations <n>${RESET}  Build loops"
    echo -e "  ${DIM}--tdd${RESET}  Test-first mode            ${DIM}--completed-stages \"a,b\"${RESET}  CI resume"
    echo ""
    echo -e "${BOLD}STAGES${RESET}  ${DIM}(configurable per pipeline template)${RESET}"
    echo -e "  intake → plan → design → build → test → review → pr → deploy → validate → monitor"
    echo ""
    echo -e "${BOLD}FEATURES${RESET}"
    echo -e "  ${DIM}GitHub:${RESET}      Issue intake, progress comments, PR creation, label lifecycle"
    echo -e "  ${DIM}Self-heal:${RESET}   Build→test feedback loop, auto-rebase, stash/restore"
    echo -e "  ${DIM}Auto-detect:${RESET} Test cmd, branch prefix, reviewers, project type"
    echo -e "  ${DIM}Notify:${RESET}      Slack webhook, custom webhook, event bus"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 123 --skip-gates${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --goal \"Add JWT authentication\"${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 42 --worktree${RESET}"
    echo -e "  ${DIM}shipwright pipeline resume | status | abort${RESET}"
    echo ""
}

# ─── Argument Parsing ───────────────────────────────────────────────────────

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --goal)        GOAL="$2"; shift 2 ;;
            --issue)       ISSUE_NUMBER="$2"; shift 2 ;;
            --repo)        REPO_OVERRIDE="$2"; shift 2 ;;
            --local)       NO_GITHUB=true; NO_GITHUB_LABEL=true; shift ;;
            --pipeline|--template) PIPELINE_NAME="$2"; shift 2 ;;
            --test-cmd)    TEST_CMD="$2"; shift 2 ;;
            --model)       MODEL="$2"; shift 2 ;;
            --agents)      AGENTS="$2"; shift 2 ;;
            --skip-gates)  SKIP_GATES=true; shift ;;
            --headless)    HEADLESS=true; SKIP_GATES=true; shift ;;
            --base)        BASE_BRANCH="$2"; shift 2 ;;
            --reviewers)   REVIEWERS="$2"; shift 2 ;;
            --labels)      LABELS="$2"; shift 2 ;;
            --no-github)   NO_GITHUB=true; shift ;;
            --no-github-label) NO_GITHUB_LABEL=true; shift ;;
            --ci)          CI_MODE=true; SKIP_GATES=true; shift ;;
            --ignore-budget) IGNORE_BUDGET=true; shift ;;
            --max-iterations) MAX_ITERATIONS_OVERRIDE="$2"; shift 2 ;;
            --completed-stages) COMPLETED_STAGES="$2"; shift 2 ;;
            --resume) RESUME_FROM_CHECKPOINT=true; shift ;;
            --worktree=*) AUTO_WORKTREE=true; WORKTREE_NAME="${1#--worktree=}"; WORKTREE_NAME="${WORKTREE_NAME//[^a-zA-Z0-9_-]/}"; if [[ -z "$WORKTREE_NAME" ]]; then error "Invalid worktree name (alphanumeric, hyphens, underscores only)"; exit 1; fi; shift ;;
            --worktree)   AUTO_WORKTREE=true; shift ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --slack-webhook) SLACK_WEBHOOK="$2"; shift 2 ;;
            --self-heal)   BUILD_TEST_RETRIES="${2:-3}"; shift 2 ;;
            --max-restarts)
                MAX_RESTARTS_OVERRIDE="$2"
                if ! [[ "$MAX_RESTARTS_OVERRIDE" =~ ^[0-9]+$ ]]; then
                    error "--max-restarts must be numeric (got: $MAX_RESTARTS_OVERRIDE)"
                    exit 1
                fi
                shift 2 ;;

            --fast-test-cmd) FAST_TEST_CMD_OVERRIDE="$2"; shift 2 ;;
            --tdd)         TDD_ENABLED=true; shift ;;
            --help|-h)     show_help; exit 0 ;;
            *)
                if [[ -z "$PIPELINE_NAME_ARG" ]]; then
                    PIPELINE_NAME_ARG="$1"
                fi
                shift ;;
        esac
    done
}

PIPELINE_NAME_ARG=""
parse_args "$@"

# ─── Non-Interactive Detection ──────────────────────────────────────────────
# When stdin is not a terminal (background, pipe, nohup, tmux send-keys),
# auto-enable headless mode to prevent read prompts from killing the script.
if [[ ! -t 0 ]]; then
    HEADLESS=true
    if [[ "$SKIP_GATES" != "true" ]]; then
        SKIP_GATES=true
    fi
fi
# --worktree implies headless when stdin is not a terminal
if [[ "$AUTO_WORKTREE" == "true" && "$SKIP_GATES" != "true" && ! -t 0 ]]; then
    SKIP_GATES=true
fi

# ─── Directory Setup ────────────────────────────────────────────────────────

setup_dirs() {
    PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    STATE_DIR="$PROJECT_ROOT/.claude"
    STATE_FILE="$STATE_DIR/pipeline-state.md"
    ARTIFACTS_DIR="$STATE_DIR/pipeline-artifacts"
    export ARTIFACTS_DIR  # Export so child processes (sw-loop.sh) can write audit events
    TASKS_FILE="$STATE_DIR/pipeline-tasks.md"
    mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
    export SHIPWRIGHT_PIPELINE_ID="pipeline-$$-${ISSUE_NUMBER:-0}"
}

# ─── Pipeline Config Loading ───────────────────────────────────────────────

find_pipeline_config() {
    local name="$1"
    local locations=(
        "$REPO_DIR/templates/pipelines/${name}.json"
        "${PROJECT_ROOT:-}/templates/pipelines/${name}.json"
        "$HOME/.shipwright/pipelines/${name}.json"
    )
    for loc in "${locations[@]}"; do
        if [[ -n "$loc" && -f "$loc" ]]; then
            echo "$loc"
            return 0
        fi
    done
    return 1
}

load_pipeline_config() {
    # Check for intelligence-composed pipeline first
    local composed_pipeline="${ARTIFACTS_DIR}/composed-pipeline.json"
    if [[ -f "$composed_pipeline" ]] && type composer_validate_pipeline >/dev/null 2>&1; then
        # Use composed pipeline if fresh (within cache TTL)
        local composed_cache_ttl
        composed_cache_ttl=$(_config_get_int "pipeline.composed_cache_ttl" 3600 2>/dev/null || echo 3600)
        local composed_age=99999
        local composed_mtime
        composed_mtime=$(file_mtime "$composed_pipeline")
        if [[ "$composed_mtime" -gt 0 ]]; then
            composed_age=$(( $(now_epoch) - composed_mtime ))
        fi
        if [[ "$composed_age" -lt "$composed_cache_ttl" ]]; then
            local validate_json
            validate_json=$(cat "$composed_pipeline" 2>/dev/null || echo "")
            if [[ -n "$validate_json" ]] && composer_validate_pipeline "$validate_json" 2>/dev/null; then
                PIPELINE_CONFIG="$composed_pipeline"
                info "Pipeline: ${BOLD}composed${RESET} ${DIM}(intelligence-driven)${RESET}"
                emit_event "pipeline.composed_loaded" "issue=${ISSUE_NUMBER:-0}"
                return
            fi
        fi
    fi

    PIPELINE_CONFIG=$(find_pipeline_config "$PIPELINE_NAME") || {
        error "Pipeline template not found: $PIPELINE_NAME"
        echo -e "  Available templates: ${DIM}shipwright pipeline list${RESET}"
        exit 1
    }
    info "Pipeline: ${BOLD}$PIPELINE_NAME${RESET} ${DIM}($PIPELINE_CONFIG)${RESET}"
    # TDD from template (overridable by --tdd)
    [[ "$(jq -r '.tdd // false' "$PIPELINE_CONFIG" 2>/dev/null)" == "true" ]] && PIPELINE_TDD=true
    return 0
}

CURRENT_STAGE_ID=""

# Notification / webhook
SLACK_WEBHOOK=""
NOTIFICATION_ENABLED=false

# Self-healing
BUILD_TEST_RETRIES=$(_config_get_int "pipeline.build_test_retries" 3 2>/dev/null || echo 3)
STASHED_CHANGES=false
SELF_HEAL_COUNT=0

# ─── Cost Tracking ───────────────────────────────────────────────────────
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
COST_MODEL_RATES='{"opus":{"input":15,"output":75},"sonnet":{"input":3,"output":15},"haiku":{"input":0.25,"output":1.25}}'

HEARTBEAT_PID=""

# Orchestration (run_pipeline, preflight_checks, cleanup_on_exit, heartbeat, CI helpers)
# → lib/pipeline-orchestrator.sh
# Lifecycle (pipeline_start/resume/status/abort/list/show, worktree, dry-run)
# → lib/pipeline-lifecycle.sh
trap cleanup_on_exit SIGINT SIGTERM

# ─── Main ───────────────────────────────────────────────────────────────────

case "$SUBCOMMAND" in
    start)          pipeline_start ;;
    resume)         pipeline_resume ;;
    status)         pipeline_status ;;
    abort)          pipeline_abort ;;
    list)           pipeline_list ;;
    show)           pipeline_show ;;
    test)
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        exec "$SCRIPT_DIR/sw-pipeline-test.sh" "$@"
        ;;
    help|--help|-h) show_help ;;
    *)
        error "Unknown pipeline command: $SUBCOMMAND"
        echo ""
        show_help
        exit 1
        ;;
esac
