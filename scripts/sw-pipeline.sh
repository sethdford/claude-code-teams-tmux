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
# shellcheck source=lib/pipeline-lifecycle.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-lifecycle.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-lifecycle.sh"
PIPELINE_COVERAGE_THRESHOLD="${PIPELINE_COVERAGE_THRESHOLD:-60}"
PIPELINE_QUALITY_GATE_THRESHOLD="${PIPELINE_QUALITY_GATE_THRESHOLD:-70}"

# ─── Intelligence Engine (optional) ──────────────────────────────────────────
# shellcheck source=sw-intelligence.sh
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    source "$SCRIPT_DIR/sw-intelligence.sh"
fi
# shellcheck source=sw-pipeline-composer.sh
if [[ -f "$SCRIPT_DIR/sw-pipeline-composer.sh" ]]; then
    source "$SCRIPT_DIR/sw-pipeline-composer.sh"
fi
# shellcheck source=sw-developer-simulation.sh
if [[ -f "$SCRIPT_DIR/sw-developer-simulation.sh" ]]; then
    source "$SCRIPT_DIR/sw-developer-simulation.sh"
fi
# shellcheck source=sw-architecture-enforcer.sh
if [[ -f "$SCRIPT_DIR/sw-architecture-enforcer.sh" ]]; then
    source "$SCRIPT_DIR/sw-architecture-enforcer.sh"
fi
# shellcheck source=sw-adversarial.sh
if [[ -f "$SCRIPT_DIR/sw-adversarial.sh" ]]; then
    source "$SCRIPT_DIR/sw-adversarial.sh"
fi
# shellcheck source=sw-pipeline-vitals.sh
if [[ -f "$SCRIPT_DIR/sw-pipeline-vitals.sh" ]]; then
    source "$SCRIPT_DIR/sw-pipeline-vitals.sh"
fi

# ─── Memory, Optimization & Discovery (optional) ─────────────────────────
# shellcheck source=sw-memory.sh
if [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
    source "$SCRIPT_DIR/sw-memory.sh"
fi
# shellcheck source=sw-self-optimize.sh
if [[ -f "$SCRIPT_DIR/sw-self-optimize.sh" ]]; then
    source "$SCRIPT_DIR/sw-self-optimize.sh"
fi
# shellcheck source=sw-discovery.sh
if [[ -f "$SCRIPT_DIR/sw-discovery.sh" ]]; then
    source "$SCRIPT_DIR/sw-discovery.sh"
fi
# shellcheck source=sw-durable.sh
if [[ -f "$SCRIPT_DIR/sw-durable.sh" ]]; then
    source "$SCRIPT_DIR/sw-durable.sh"
fi
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
    echo -e "  ${DIM}--goal \"description\"${RESET}     What to build (required unless --issue)"
    echo -e "  ${DIM}--issue <number>${RESET}          Fetch goal from GitHub issue"
    echo -e "  ${DIM}--repo <path>${RESET}             Change to directory before running (must be a git repo)"
    echo -e "  ${DIM}--local${RESET}                   Alias for --no-github --no-github-label (local-only mode)"
    echo -e "  ${DIM}--pipeline <name>${RESET}         Pipeline template (default: standard)"
    echo -e "  ${DIM}--test-cmd \"command\"${RESET}     Override test command (auto-detected if omitted)"
    echo -e "  ${DIM}--model <model>${RESET}           Override AI model (opus, sonnet, haiku)"
    echo -e "  ${DIM}--agents <n>${RESET}              Override agent count"
    echo -e "  ${DIM}--skip-gates${RESET}              Auto-approve all gates (fully autonomous)"
    echo -e "  ${DIM}--headless${RESET}                Full headless mode (skip gates, no prompts)"
    echo -e "  ${DIM}--base <branch>${RESET}           Base branch for PR (default: main)"
    echo -e "  ${DIM}--reviewers \"a,b\"${RESET}        Request PR reviewers (auto-detected if omitted)"
    echo -e "  ${DIM}--labels \"a,b\"${RESET}            Add labels to PR (inherited from issue if omitted)"
    echo -e "  ${DIM}--no-github${RESET}               Disable GitHub integration"
    echo -e "  ${DIM}--no-github-label${RESET}         Don't modify issue labels"
    echo -e "  ${DIM}--ci${RESET}                      CI mode (skip gates, non-interactive)"
    echo -e "  ${DIM}--ignore-budget${RESET}           Skip budget enforcement checks"
    echo -e "  ${DIM}--worktree [=name]${RESET}         Run in isolated git worktree (parallel-safe)"
    echo -e "  ${DIM}--dry-run${RESET}                 Show what would happen without executing"
    echo -e "  ${DIM}--slack-webhook <url>${RESET}     Send notifications to Slack"
    echo -e "  ${DIM}--self-heal <n>${RESET}            Build→test retry cycles on failure (default: 2)"
    echo -e "  ${DIM}--max-iterations <n>${RESET}       Override max build loop iterations"
    echo -e "  ${DIM}--max-restarts <n>${RESET}         Max session restarts in build loop"
    echo -e "  ${DIM}--fast-test-cmd <cmd>${RESET}      Fast/subset test for build loop"
    echo -e "  ${DIM}--tdd${RESET}                     Test-first: generate tests before implementation"
    echo -e "  ${DIM}--completed-stages \"a,b\"${RESET}   Skip these stages (CI resume)"
    echo ""
    echo -e "${BOLD}STAGES${RESET}  ${DIM}(configurable per pipeline template)${RESET}"
    echo -e "  intake → plan → design → build → test → review → pr → deploy → validate → monitor"
    echo ""
    echo -e "${BOLD}GITHUB INTEGRATION${RESET}  ${DIM}(automatic when gh CLI available)${RESET}"
    echo -e "  • Issue intake: fetch metadata, labels, milestone, self-assign"
    echo -e "  • Progress tracking: live updates posted as issue comments"
    echo -e "  • Task checklist: plan posted as checkbox list on issue"
    echo -e "  • PR creation: labels, milestone, reviewers auto-propagated"
    echo -e "  • Issue lifecycle: labeled in-progress → closed on completion"
    echo ""
    echo -e "${BOLD}SELF-HEALING${RESET}  ${DIM}(autonomous error recovery)${RESET}"
    echo -e "  • Build→test feedback loop: failures feed back as build context"
    echo -e "  • Configurable retry cycles (--self-heal N, default: 2)"
    echo -e "  • Auto-rebase before PR: handles base branch drift"
    echo -e "  • Signal-safe: Ctrl+C saves state for clean resume"
    echo -e "  • Git stash/restore: protects uncommitted work"
    echo ""
    echo -e "${BOLD}AUTO-DETECTION${RESET}  ${DIM}(zero-config for common setups)${RESET}"
    echo -e "  • Test command: package.json, Makefile, Cargo.toml, go.mod, etc."
    echo -e "  • Branch prefix: feat/, fix/, refactor/ based on task type"
    echo -e "  • Reviewers: from CODEOWNERS or recent git contributors"
    echo -e "  • Project type: language and framework detection"
    echo ""
    echo -e "${BOLD}NOTIFICATIONS${RESET}  ${DIM}(team awareness)${RESET}"
    echo -e "  • Slack: --slack-webhook <url>"
    echo -e "  • Custom webhook: set SHIPWRIGHT_WEBHOOK_URL env var"
    echo -e "  • Events: start, stage complete, failure, self-heal, done"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}# From GitHub issue (fully autonomous)${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 123 --skip-gates${RESET}"
    echo ""
    echo -e "  ${DIM}# From inline goal${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --goal \"Add JWT authentication\"${RESET}"
    echo ""
    echo -e "  ${DIM}# Hotfix with custom test command${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 456 --pipeline hotfix --test-cmd \"pytest\"${RESET}"
    echo ""
    echo -e "  ${DIM}# Full deployment pipeline with 3 agents${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --goal \"Build payment flow\" --pipeline full --agents 3${RESET}"
    echo ""
    echo -e "  ${DIM}# Parallel pipeline in isolated worktree${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 42 --worktree${RESET}"
    echo ""
    echo -e "  ${DIM}# Resume / monitor / abort${RESET}"
    echo -e "  ${DIM}shipwright pipeline resume${RESET}"
    echo -e "  ${DIM}shipwright pipeline status${RESET}"
    echo -e "  ${DIM}shipwright pipeline abort${RESET}"
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

# ─── Heartbeat ────────────────────────────────────────────────────────────────
HEARTBEAT_PID=""

start_heartbeat() {
    local job_id="${PIPELINE_NAME:-pipeline-$$}"
    (
        while true; do
            "$SCRIPT_DIR/sw-heartbeat.sh" write "$job_id" \
                --pid $$ \
                --issue "${ISSUE_NUMBER:-0}" \
                --stage "${CURRENT_STAGE_ID:-unknown}" \
                --iteration "0" \
                --activity "$(get_stage_description "${CURRENT_STAGE_ID:-}" 2>/dev/null || echo "Running pipeline")" 2>/dev/null || true
            sleep "$(_config_get_int "pipeline.heartbeat_interval" 30 2>/dev/null || echo 30)"
        done
    ) >/dev/null 2>&1 &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [[ -n "${HEARTBEAT_PID:-}" ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true
        "$SCRIPT_DIR/sw-heartbeat.sh" clear "${PIPELINE_NAME:-pipeline-$$}" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

# ─── CI Helpers ───────────────────────────────────────────────────────────

ci_push_partial_work() {
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0

    local branch="shipwright/issue-${ISSUE_NUMBER}"

    # Only push if we have uncommitted changes
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git add -A 2>/dev/null || true
        git commit -m "WIP: partial pipeline progress for #${ISSUE_NUMBER}" --no-verify 2>/dev/null || true
    fi

    # Push branch (create if needed, force to overwrite previous WIP)
    if ! git push origin "HEAD:refs/heads/$branch" --force 2>/dev/null; then
        warn "git push failed for $branch — remote may be out of sync"
        emit_event "pipeline.push_failed" "branch=$branch"
    fi
}

ci_post_stage_event() {
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0
    [[ "${GH_AVAILABLE:-false}" != "true" ]] && return 0

    local stage="$1" status="$2" elapsed="${3:-0s}"
    local comment="<!-- SHIPWRIGHT-STAGE: ${stage}:${status}:${elapsed} -->"
    _timeout "$(_config_get_int "network.gh_timeout" 30 2>/dev/null || echo 30)" gh issue comment "$ISSUE_NUMBER" --body "$comment" 2>/dev/null || true
}

# ─── Signal Handling ───────────────────────────────────────────────────────

cleanup_on_exit() {
    [[ "${_cleanup_done:-}" == "true" ]] && return 0
    _cleanup_done=true
    local exit_code=$?

    # Stop heartbeat writer
    stop_heartbeat

    # Save state if we were running
    if [[ "$PIPELINE_STATUS" == "running" && -n "$STATE_FILE" ]]; then
        PIPELINE_STATUS="interrupted"
        UPDATED_AT="$(now_iso)"
        write_state 2>/dev/null || true
        echo ""
        warn "Pipeline interrupted — state saved."
        echo -e "  Resume: ${DIM}shipwright pipeline resume${RESET}"

        # Push partial work in CI mode so retries can pick it up
        ci_push_partial_work
    fi

    # Restore stashed changes
    if [[ "$STASHED_CHANGES" == "true" ]]; then
        git stash pop --quiet 2>/dev/null || true
    fi

    # Release durable pipeline lock
    if [[ -n "${_PIPELINE_LOCK_ID:-}" ]] && type release_lock >/dev/null 2>&1; then
        release_lock "$_PIPELINE_LOCK_ID" 2>/dev/null || true
    fi

    # Cancel lingering in_progress GitHub Check Runs
    pipeline_cancel_check_runs 2>/dev/null || true

    # Update GitHub
    if [[ -n "${ISSUE_NUMBER:-}" && "${GH_AVAILABLE:-false}" == "true" ]]; then
        if ! _timeout "$(_config_get_int "network.gh_timeout" 30 2>/dev/null || echo 30)" gh issue comment "$ISSUE_NUMBER" --body "⏸️ **Pipeline interrupted** at stage: ${CURRENT_STAGE_ID:-unknown}" 2>/dev/null; then
            warn "gh issue comment failed — status update may not have been posted"
            emit_event "pipeline.comment_failed" "issue=$ISSUE_NUMBER"
        fi
    fi

    exit "$exit_code"
}

trap cleanup_on_exit SIGINT SIGTERM

# ─── Pre-flight Validation ─────────────────────────────────────────────────

preflight_checks() {
    local errors=0

    echo -e "${PURPLE}${BOLD}━━━ Pre-flight Checks ━━━${RESET}"
    echo ""

    # 1. Required tools
    local required_tools=("git" "jq")
    local optional_tools=("gh" "claude" "bc" "curl")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${RED}✗${RESET} $tool ${RED}(required)${RESET}"
            errors=$((errors + 1))
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${DIM}○${RESET} $tool ${DIM}(optional — some features disabled)${RESET}"
        fi
    done

    # 2. Git state
    echo ""
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} Inside git repo"
    else
        echo -e "  ${RED}✗${RESET} Not inside a git repository"
        errors=$((errors + 1))
    fi

    # Check for uncommitted changes — offer to stash
    local dirty_files
    dirty_files=$(git status --porcelain 2>/dev/null | wc -l | xargs)
    if [[ "$dirty_files" -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠${RESET} $dirty_files uncommitted change(s)"
        if [[ "$SKIP_GATES" == "true" ]]; then
            info "Auto-stashing uncommitted changes..."
            git stash push -m "sw-pipeline: auto-stash before pipeline" --quiet 2>/dev/null && STASHED_CHANGES=true
            if [[ "$STASHED_CHANGES" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Changes stashed (will restore on exit)"
            fi
        else
            echo -e "    ${DIM}Tip: Use --skip-gates to auto-stash, or commit/stash manually${RESET}"
        fi
    else
        echo -e "  ${GREEN}✓${RESET} Working tree clean"
    fi

    # Check if base branch exists
    if git rev-parse --verify "$BASE_BRANCH" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} Base branch: $BASE_BRANCH"
    else
        echo -e "  ${RED}✗${RESET} Base branch not found: $BASE_BRANCH"
        errors=$((errors + 1))
    fi

    # 3. GitHub auth (if gh available and not disabled)
    if [[ "$NO_GITHUB" != "true" ]] && command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} GitHub authenticated"
        else
            echo -e "  ${YELLOW}⚠${RESET} GitHub not authenticated (features disabled)"
        fi
    fi

    # 4. Claude CLI
    if command -v claude >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} Claude CLI available"
    else
        echo -e "  ${RED}✗${RESET} Claude CLI not found — plan/build stages will fail"
        errors=$((errors + 1))
    fi

    # 5. sw loop (needed for build stage)
    if [[ -x "$SCRIPT_DIR/sw-loop.sh" ]]; then
        echo -e "  ${GREEN}✓${RESET} shipwright loop available"
    else
        echo -e "  ${RED}✗${RESET} sw-loop.sh not found at $SCRIPT_DIR"
        errors=$((errors + 1))
    fi

    # 6. Disk space check (warn if < 1GB free)
    local free_space_kb
    free_space_kb=$(df -k "$PROJECT_ROOT" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_space_kb" ]] && [[ "$free_space_kb" -lt 1048576 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}⚠${RESET} Low disk space: $(( free_space_kb / 1024 ))MB free"
    fi

    echo ""

    if [[ "$errors" -gt 0 ]]; then
        error "Pre-flight failed: $errors error(s)"
        return 1
    fi

    success "Pre-flight passed"
    echo ""
    return 0
}




run_pipeline() {
    # Rotate event log if needed (standalone mode)
    rotate_event_log_if_needed

    # Initialize audit trail for this pipeline run
    if type audit_init >/dev/null 2>&1; then
        audit_init || true
    fi

    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG")

    local stage_count enabled_count
    stage_count=$(jq '.stages | length' "$PIPELINE_CONFIG")
    enabled_count=$(jq '[.stages[] | select(.enabled == true)] | length' "$PIPELINE_CONFIG")
    local completed=0

    # Check which stages are enabled to determine if we use the self-healing loop
    local build_enabled test_enabled
    build_enabled=$(jq -r '.stages[] | select(.id == "build") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null)
    test_enabled=$(jq -r '.stages[] | select(.id == "test") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null)
    local use_self_healing=false
    if [[ "$build_enabled" == "true" && "$test_enabled" == "true" && "$BUILD_TEST_RETRIES" -gt 0 ]]; then
        use_self_healing=true
    fi

    while IFS= read -r -u 3 stage; do
        local id enabled gate
        id=$(echo "$stage" | jq -r '.id')
        enabled=$(echo "$stage" | jq -r '.enabled')
        gate=$(echo "$stage" | jq -r '.gate')

        CURRENT_STAGE_ID="$id"

        # Human intervention: check for skip-stage directive
        if [[ -f "$ARTIFACTS_DIR/skip-stage.txt" ]]; then
            local skip_list
            skip_list="$(cat "$ARTIFACTS_DIR/skip-stage.txt" 2>/dev/null || true)"
            if echo "$skip_list" | grep -qx "$id" 2>/dev/null; then
                info "Stage ${BOLD}${id}${RESET} skipped by human directive"
                emit_event "stage.skipped" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "reason=human_skip"
                # Remove this stage from the skip file
                local tmp_skip
                tmp_skip="$(mktemp)"
                # shellcheck disable=SC2064  # intentional expansion at definition time
                trap "rm -f '$tmp_skip'" RETURN
                grep -vx "$id" "$ARTIFACTS_DIR/skip-stage.txt" > "$tmp_skip" 2>/dev/null || true
                mv "$tmp_skip" "$ARTIFACTS_DIR/skip-stage.txt"
                continue
            fi
        fi

        # Human intervention: check for human message
        if [[ -f "$ARTIFACTS_DIR/human-message.txt" ]]; then
            local human_msg
            human_msg="$(cat "$ARTIFACTS_DIR/human-message.txt" 2>/dev/null || true)"
            if [[ -n "$human_msg" ]]; then
                echo ""
                echo -e "  ${PURPLE}${BOLD}💬 Human message:${RESET} $human_msg"
                emit_event "pipeline.human_message" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "message=$human_msg"
                rm -f "$ARTIFACTS_DIR/human-message.txt"
            fi
        fi

        if [[ "$enabled" != "true" ]]; then
            echo -e "  ${DIM}○ ${id} — skipped (disabled)${RESET}"
            continue
        fi

        # Intelligence: evaluate whether to skip this stage
        local skip_reason=""
        skip_reason=$(pipeline_should_skip_stage "$id" 2>/dev/null) || true
        if [[ -n "$skip_reason" ]]; then
            echo -e "  ${DIM}○ ${id} — skipped (intelligence: ${skip_reason})${RESET}"
            set_stage_status "$id" "complete"
            completed=$((completed + 1))
            continue
        fi

        local stage_status
        stage_status=$(get_stage_status "$id")
        if [[ "$stage_status" == "complete" ]]; then
            echo -e "  ${GREEN}✓ ${id}${RESET} ${DIM}— already complete${RESET}"
            completed=$((completed + 1))
            continue
        fi

        # CI resume: skip stages marked as completed from previous run
        if [[ -n "${COMPLETED_STAGES:-}" ]] && echo "$COMPLETED_STAGES" | tr ',' '\n' | grep -qx "$id"; then
            # Verify artifacts survived the merge — regenerate if missing
            if verify_stage_artifacts "$id"; then
                echo -e "  ${GREEN}✓ ${id}${RESET} ${DIM}— skipped (CI resume)${RESET}"
                set_stage_status "$id" "complete"
                completed=$((completed + 1))
                emit_event "stage.skipped" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "reason=ci_resume"
                continue
            else
                warn "Stage $id marked complete but artifacts missing — regenerating"
                emit_event "stage.artifact_miss" "issue=${ISSUE_NUMBER:-0}" "stage=$id"
            fi
        fi

        # Self-healing build→test loop: when we hit build, run both together
        if [[ "$id" == "build" && "$use_self_healing" == "true" ]]; then
            # TDD: generate tests before build when enabled
            if [[ "${TDD_ENABLED:-false}" == "true" || "${PIPELINE_TDD:-}" == "true" ]]; then
                stage_test_first || true
            fi
            # Gate check for build
            local build_gate
            build_gate=$(echo "$stage" | jq -r '.gate')
            if [[ "$build_gate" == "approve" && "$SKIP_GATES" != "true" ]]; then
                show_stage_preview "build"
                local answer=""
                if [[ -t 0 ]]; then
                    read -rp "  Proceed with build+test (self-healing)? [Y/n] " answer || true
                fi
                if [[ "$answer" =~ ^[Nn] ]]; then
                    update_status "paused" "build"
                    info "Pipeline paused. Resume with: ${DIM}shipwright pipeline resume${RESET}"
                    return 0
                fi
            fi

            if self_healing_build_test; then
                completed=$((completed + 2))  # Both build and test

                # Intelligence: reassess complexity after build+test
                local reassessment
                reassessment=$(pipeline_reassess_complexity 2>/dev/null) || true
                if [[ -n "$reassessment" && "$reassessment" != "as_expected" ]]; then
                    info "Complexity reassessment: ${reassessment}"
                fi
            else
                update_status "failed" "test"
                error "Pipeline failed: build→test self-healing exhausted"
                return 1
            fi
            continue
        fi

        # TDD: generate tests before build when enabled (non-self-healing path)
        if [[ "$id" == "build" && "$use_self_healing" != "true" ]] && [[ "${TDD_ENABLED:-false}" == "true" || "${PIPELINE_TDD:-}" == "true" ]]; then
            stage_test_first || true
        fi

        # Skip test if already handled by self-healing loop
        if [[ "$id" == "test" && "$use_self_healing" == "true" ]]; then
            stage_status=$(get_stage_status "test")
            if [[ "$stage_status" == "complete" ]]; then
                echo -e "  ${GREEN}✓ test${RESET} ${DIM}— completed in build→test loop${RESET}"
            fi
            continue
        fi

        # Gate check
        if [[ "$gate" == "approve" && "$SKIP_GATES" != "true" ]]; then
            show_stage_preview "$id"
            local answer=""
            if [[ -t 0 ]]; then
                read -rp "  Proceed with ${id}? [Y/n] " answer || true
            else
                # Non-interactive: auto-approve (shouldn't reach here if headless detection works)
                info "Non-interactive mode — auto-approving ${id}"
            fi
            if [[ "$answer" =~ ^[Nn] ]]; then
                update_status "paused" "$id"
                info "Pipeline paused at ${BOLD}$id${RESET}. Resume with: ${DIM}shipwright pipeline resume${RESET}"
                return 0
            fi
        fi

        # Budget enforcement check (skip with --ignore-budget)
        if [[ "$IGNORE_BUDGET" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
            local budget_rc=0
            bash "$SCRIPT_DIR/sw-cost.sh" check-budget 2>/dev/null || budget_rc=$?
            if [[ "$budget_rc" -eq 2 ]]; then
                warn "Daily budget exceeded — pausing pipeline before stage ${BOLD}$id${RESET}"
                warn "Resume with --ignore-budget to override, or wait until tomorrow"
                emit_event "pipeline.budget_paused" "issue=${ISSUE_NUMBER:-0}" "stage=$id"
                update_status "paused" "$id"
                return 0
            fi
        fi

        # Intelligence: per-stage model routing (UCB1 when DB has data, else A/B testing)
        local recommended_model="" from_ucb1=false
        if type ucb1_select_model >/dev/null 2>&1; then
            recommended_model=$(ucb1_select_model "$id" 2>/dev/null || echo "")
            [[ -n "$recommended_model" ]] && from_ucb1=true
        fi
        if [[ -z "$recommended_model" ]] && type intelligence_recommend_model >/dev/null 2>&1; then
            local stage_complexity="${INTELLIGENCE_COMPLEXITY:-5}"
            local budget_remaining=""
            if [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
                budget_remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
            fi
            local recommended_json
            recommended_json=$(intelligence_recommend_model "$id" "$stage_complexity" "$budget_remaining" 2>/dev/null || echo "")
            recommended_model=$(echo "$recommended_json" | jq -r '.model // empty' 2>/dev/null || echo "")
        fi
        if [[ -n "$recommended_model" && "$recommended_model" != "null" ]]; then
            if [[ "$from_ucb1" == "true" ]]; then
                # UCB1 already balances exploration/exploitation — use directly
                export CLAUDE_MODEL="$recommended_model"
                emit_event "intelligence.model_ucb1" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$id" \
                    "model=$recommended_model"
            else
                # A/B testing for intelligence recommendation
                local ab_ratio=20
                local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
                if [[ -f "$daemon_cfg" ]]; then
                    local cfg_ratio
                    cfg_ratio=$(jq -r '.intelligence.ab_test_ratio // 0.2' "$daemon_cfg" 2>/dev/null || echo "0.2")
                    ab_ratio=$(awk -v r="$cfg_ratio" 'BEGIN{printf "%d", r * 100}' 2>/dev/null || echo "20")
                fi

                local routing_file="${HOME}/.shipwright/optimization/model-routing.json"
                local use_recommended=false
                local ab_group="control"

                if [[ -f "$routing_file" ]]; then
                    local stage_samples total_samples
                    stage_samples=$(jq -r --arg s "$id" '.routes[$s].sonnet_samples // .[$s].sonnet_samples // 0' "$routing_file" 2>/dev/null || echo "0")
                    total_samples=$(jq -r --arg s "$id" '((.routes[$s].sonnet_samples // .[$s].sonnet_samples // 0) + (.routes[$s].opus_samples // .[$s].opus_samples // 0))' "$routing_file" 2>/dev/null || echo "0")
                    if [[ "${total_samples:-0}" -ge 50 ]]; then
                        use_recommended=true
                        ab_group="graduated"
                    fi
                fi

                if [[ "$use_recommended" != "true" ]]; then
                    local roll=$((RANDOM % 100))
                    if [[ "$roll" -lt "$ab_ratio" ]]; then
                        use_recommended=true
                        ab_group="experiment"
                    fi
                fi

                if [[ "$use_recommended" == "true" ]]; then
                    export CLAUDE_MODEL="$recommended_model"
                else
                    export CLAUDE_MODEL="opus"
                fi

                emit_event "intelligence.model_ab" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$id" \
                    "recommended=$recommended_model" \
                    "applied=$CLAUDE_MODEL" \
                    "ab_group=$ab_group" \
                    "ab_ratio=$ab_ratio"
            fi
        fi

        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: ${id}${RESET} ${DIM}[$((completed + 1))/${enabled_count}]${RESET}"
        update_status "running" "$id"
        record_stage_start "$id"
        local stage_start_epoch
        stage_start_epoch=$(now_epoch)
        emit_event "stage.started" "issue=${ISSUE_NUMBER:-0}" "stage=$id"

        # Mark GitHub Check Run as in-progress
        if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update >/dev/null 2>&1; then
            gh_checks_stage_update "$id" "in_progress" "" "Stage $id started" 2>/dev/null || true
        fi

        # Audit: stage start
        if type audit_emit >/dev/null 2>&1; then
            audit_emit "stage.start" "stage=$id" || true
        fi

        local stage_model_used="${CLAUDE_MODEL:-${MODEL:-opus}}"
        if run_stage_with_retry "$id"; then
            mark_stage_complete "$id"
            completed=$((completed + 1))
            # Capture project pattern after intake (for memory context in later stages)
            if [[ "$id" == "intake" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
                (cd "$REPO_DIR" && bash "$SCRIPT_DIR/sw-memory.sh" pattern "project" "{}" 2>/dev/null) || true
            fi
            local timing stage_dur_s
            timing=$(get_stage_timing "$id")
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            success "Stage ${BOLD}$id${RESET} complete ${DIM}(${timing})${RESET}"
            emit_event "stage.completed" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "duration_s=$stage_dur_s" "result=success"
            # Audit: stage complete
            if type audit_emit >/dev/null 2>&1; then
                audit_emit "stage.complete" "stage=$id" "verdict=pass" \
                    "duration_s=${stage_dur_s:-0}" || true
            fi
            # Emit vitals snapshot on every stage transition (not just build/test)
            if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "$id" "0" "0" "0" "" 2>/dev/null || true
            fi
            # Record model outcome for UCB1 learning
            type record_model_outcome >/dev/null 2>&1 && record_model_outcome "$stage_model_used" "$id" 1 "$stage_dur_s" 0 2>/dev/null || true
            # Broadcast discovery for cross-pipeline learning
            if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
                local _disc_cat _disc_patterns _disc_text
                _disc_cat="$id"
                case "$id" in
                    plan)   _disc_patterns="*.md"; _disc_text="Plan completed: ${GOAL:-goal}" ;;
                    design) _disc_patterns="*.md,*.ts,*.tsx,*.js"; _disc_text="Design completed for ${GOAL:-goal}" ;;
                    build)  _disc_patterns="src/*,*.ts,*.tsx,*.js"; _disc_text="Build completed" ;;
                    test)   _disc_patterns="*.test.*,*_test.*"; _disc_text="Tests passed" ;;
                    review) _disc_patterns="*.md,*.ts,*.tsx"; _disc_text="Review completed" ;;
                    *)      _disc_patterns="*"; _disc_text="Stage $id completed" ;;
                esac
                bash "$SCRIPT_DIR/sw-discovery.sh" broadcast "$_disc_cat" "$_disc_patterns" "$_disc_text" "" 2>/dev/null || true
            fi
            # Log model used for prediction feedback
            echo "${id}|${stage_model_used}|true" >> "${ARTIFACTS_DIR}/model-routing.log"
        else
            mark_stage_failed "$id"
            local stage_dur_s
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            error "Pipeline failed at stage: ${BOLD}$id${RESET}"
            update_status "failed" "$id"
            emit_event "stage.failed" \
                "issue=${ISSUE_NUMBER:-0}" \
                "stage=$id" \
                "duration_s=$stage_dur_s" \
                "error=${LAST_STAGE_ERROR:-unknown}" \
                "error_class=${LAST_STAGE_ERROR_CLASS:-unknown}"
            # Audit: stage failed
            if type audit_emit >/dev/null 2>&1; then
                audit_emit "stage.complete" "stage=$id" "verdict=fail" \
                    "duration_s=${stage_dur_s:-0}" || true
            fi
            # Emit vitals snapshot on failure too
            if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "$id" "0" "0" "0" "${LAST_STAGE_ERROR:-unknown}" 2>/dev/null || true
            fi
            # Log model used for prediction feedback
            echo "${id}|${stage_model_used}|false" >> "${ARTIFACTS_DIR}/model-routing.log"
            # Record model outcome for UCB1 learning
            type record_model_outcome >/dev/null 2>&1 && record_model_outcome "$stage_model_used" "$id" 0 "$stage_dur_s" 0 2>/dev/null || true
            # Cancel any remaining in_progress check runs
            pipeline_cancel_check_runs 2>/dev/null || true
            return 1
        fi
    done 3<<< "$stages"

    # Pipeline complete!
    update_status "complete" ""
    PIPELINE_STAGES_PASSED="$completed"
    PIPELINE_SLOWEST_STAGE=""
    if type get_slowest_stage >/dev/null 2>&1; then
        PIPELINE_SLOWEST_STAGE=$(get_slowest_stage 2>/dev/null || true)
    fi
    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"
    success "Pipeline complete! ${completed}/${enabled_count} stages passed in ${total_dur:-unknown}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"

    # Show summary
    echo ""
    if [[ -f "$ARTIFACTS_DIR/pr-url.txt" ]]; then
        echo -e "  ${BOLD}PR:${RESET}        $(cat "$ARTIFACTS_DIR/pr-url.txt")"
    fi
    echo -e "  ${BOLD}Branch:${RESET}    $GIT_BRANCH"
    [[ -n "${GITHUB_ISSUE:-}" ]] && echo -e "  ${BOLD}Issue:${RESET}     $GITHUB_ISSUE"
    echo -e "  ${BOLD}Duration:${RESET}  $total_dur"
    echo -e "  ${BOLD}Artifacts:${RESET} $ARTIFACTS_DIR/"
    echo ""

    # Capture learnings to memory (success or failure)
    if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
    fi

    # Final GitHub progress update
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"
    fi

    # Post-completion cleanup
    pipeline_post_completion_cleanup
}

# Lifecycle functions (pipeline_post_completion_cleanup, pipeline_cancel_check_runs,
# pipeline_setup/cleanup_worktree, run_dry_run, generate_reasoning_trace,
# pipeline_start/resume/status/abort/list/show) are in lib/pipeline-lifecycle.sh.


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
