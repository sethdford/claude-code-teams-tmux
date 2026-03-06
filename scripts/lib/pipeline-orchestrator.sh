# pipeline-orchestrator.sh — Pipeline orchestration: run_pipeline, preflight, cleanup, heartbeat, CI helpers
# Source from sw-pipeline.sh (after pipeline-execution.sh, before pipeline-lifecycle.sh).
# Depends on: run_stage_with_retry/self_healing_build_test (pipeline-execution),
#   set_stage_status/mark_stage_*/record_stage_start/get_stage_timing (pipeline-state),
#   pipeline_should_skip_stage/pipeline_reassess_complexity (pipeline-intelligence),
#   update_status/write_state (pipeline-state), format_duration (pipeline-utils),
#   rotate_event_log_if_needed (pipeline-utils), verify_stage_artifacts (pipeline-detection).
[[ -n "${_PIPELINE_ORCHESTRATOR_LOADED:-}" ]] && return 0
_PIPELINE_ORCHESTRATOR_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-}"
STATE_FILE="${STATE_FILE:-}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"
CURRENT_STAGE_ID="${CURRENT_STAGE_ID:-}"
PIPELINE_CONFIG="${PIPELINE_CONFIG:-}"
PIPELINE_STATUS="${PIPELINE_STATUS:-}"
PIPELINE_START_EPOCH="${PIPELINE_START_EPOCH:-}"
PIPELINE_STAGES_PASSED="${PIPELINE_STAGES_PASSED:-}"
PIPELINE_SLOWEST_STAGE="${PIPELINE_SLOWEST_STAGE:-}"
PIPELINE_NAME="${PIPELINE_NAME:-standard}"
PIPELINE_AGENT_ID="${PIPELINE_AGENT_ID:-pipeline-$$}"
SKIP_GATES="${SKIP_GATES:-false}"
HEADLESS="${HEADLESS:-false}"
NO_GITHUB="${NO_GITHUB:-false}"
CI_MODE="${CI_MODE:-false}"
IGNORE_BUDGET="${IGNORE_BUDGET:-false}"
COMPLETED_STAGES="${COMPLETED_STAGES:-}"
GH_AVAILABLE="${GH_AVAILABLE:-false}"
GIT_BRANCH="${GIT_BRANCH:-}"
GITHUB_ISSUE="${GITHUB_ISSUE:-}"
BUILD_TEST_RETRIES="${BUILD_TEST_RETRIES:-3}"
STASHED_CHANGES="${STASHED_CHANGES:-false}"
MODEL="${MODEL:-}"
BASE_BRANCH="${BASE_BRANCH:-main}"
HEARTBEAT_PID="${HEARTBEAT_PID:-}"
_cleanup_done="${_cleanup_done:-}"
LAST_STAGE_ERROR_CLASS="${LAST_STAGE_ERROR_CLASS:-}"
LAST_STAGE_ERROR="${LAST_STAGE_ERROR:-}"
TOTAL_INPUT_TOKENS="${TOTAL_INPUT_TOKENS:-0}"
TOTAL_OUTPUT_TOKENS="${TOTAL_OUTPUT_TOKENS:-0}"
UPDATED_AT="${UPDATED_AT:-}"
TDD_ENABLED="${TDD_ENABLED:-false}"
PIPELINE_TDD="${PIPELINE_TDD:-}"

# Color/formatting fallbacks (safe when helpers.sh not loaded)
CYAN="${CYAN:-}"
GREEN="${GREEN:-}"
RED="${RED:-}"
YELLOW="${YELLOW:-}"
PURPLE="${PURPLE:-}"
DIM="${DIM:-}"
BOLD="${BOLD:-}"
RESET="${RESET:-}"

# ─── Heartbeat ────────────────────────────────────────────────────────────────

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

# ─── Pipeline Execution ───────────────────────────────────────────────────

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
