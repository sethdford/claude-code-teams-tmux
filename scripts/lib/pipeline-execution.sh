# pipeline-execution.sh — Stage execution mechanics: retry, self-healing, rebase
# Source from sw-pipeline.sh (after pipeline-utils.sh, pipeline-stages.sh, pipeline-state.sh).
# Depends on: classify_error (pipeline-utils), stage_${id} (pipeline-stages-*),
#   set_stage_status/mark_stage_*/record_stage_start/get_stage_timing (pipeline-state).
[[ -n "${_PIPELINE_EXECUTION_LOADED:-}" ]] && return 0
_PIPELINE_EXECUTION_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ISSUE_NUMBER="${ISSUE_NUMBER:-}"

# ─── Stage Runner ───────────────────────────────────────────────────────────

run_stage_with_retry() {
    local stage_id="$1"
    local max_retries
    max_retries=$(jq -r --arg id "$stage_id" '(.stages[] | select(.id == $id) | .config.retries) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_retries" || "$max_retries" == "null" ]] && max_retries=0

    local attempt=0
    local prev_error_class=""
    while true; do
        if "stage_${stage_id}"; then
            return 0
        fi

        # Capture error_class and error snippet for stage.failed / pipeline.completed events
        local error_class
        error_class=$(classify_error "$stage_id")
        LAST_STAGE_ERROR_CLASS="$error_class"
        LAST_STAGE_ERROR=""
        local _log_file="${ARTIFACTS_DIR}/${stage_id}-results.log"
        [[ ! -f "$_log_file" ]] && _log_file="${ARTIFACTS_DIR}/test-results.log"
        if [[ -f "$_log_file" ]]; then
            LAST_STAGE_ERROR=$(tail -20 "$_log_file" 2>/dev/null | grep -iE 'error|fail|exception|fatal' 2>/dev/null | head -1 | cut -c1-200 || true)
        fi

        attempt=$((attempt + 1))

        # Critical fix: if plan stage already has a valid artifact, skip retry
        if [[ "$stage_id" == "plan" ]]; then
            local plan_artifact="${ARTIFACTS_DIR}/plan.md"
            if [[ -s "$plan_artifact" ]]; then
                local existing_lines
                existing_lines=$(wc -l < "$plan_artifact" 2>/dev/null | xargs)
                existing_lines="${existing_lines:-0}"
                if [[ "$existing_lines" -gt 10 ]]; then
                    info "Plan already exists (${existing_lines} lines) — skipping retry, advancing"
                    emit_event "retry.skipped_existing_artifact" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "stage=$stage_id" \
                        "artifact_lines=$existing_lines"
                    return 0
                fi
            fi
        fi

        if [[ "$attempt" -gt "$max_retries" ]]; then
            return 1
        fi

        # Classify done above; decide whether retry makes sense

        emit_event "retry.classified" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "attempt=$attempt" \
            "error_class=$error_class"

        case "$error_class" in
            infrastructure)
                info "Error classified as infrastructure (timeout/network/OOM) — retry makes sense"
                ;;
            configuration)
                error "Error classified as configuration (missing env/path) — skipping retry, escalating"
                emit_event "retry.escalated" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$stage_id" \
                    "reason=configuration_error"
                return 1
                ;;
            logic)
                if [[ "$error_class" == "$prev_error_class" ]]; then
                    error "Error classified as logic (assertion/type error) with same class — retry won't help without code change"
                    emit_event "retry.skipped" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "stage=$stage_id" \
                        "reason=repeated_logic_error"
                    return 1
                fi
                warn "Error classified as logic — retrying once in case build fixes it"
                ;;
            *)
                info "Error classification: unknown — retrying"
                ;;
        esac
        prev_error_class="$error_class"

        if type db_save_reasoning_trace >/dev/null 2>&1; then
            local job_id="${SHIPWRIGHT_PIPELINE_ID:-$$}"
            local error_msg="${LAST_STAGE_ERROR:-$error_class}"
            db_save_reasoning_trace "$job_id" "retry_reasoning" \
                "stage=$stage_id error=$error_msg" \
                "Stage failed, analyzing error pattern before retry" \
                "retry_strategy=self_heal" 0.6 2>/dev/null || true
        fi

        warn "Stage $stage_id failed (attempt $attempt/$((max_retries + 1)), class: $error_class) — retrying..."
        # Exponential backoff with jitter to avoid thundering herd
        local backoff=$((2 ** attempt))
        [[ "$backoff" -gt 16 ]] && backoff=16
        local jitter=$(( RANDOM % (backoff + 1) ))
        local total_sleep=$((backoff + jitter))
        info "Backing off ${total_sleep}s before retry..."
        sleep "$total_sleep"

        # Write debugging context for the retry attempt to consume
        local _retry_ctx_file="${ARTIFACTS_DIR}/.retry-context-${stage_id}.md"
        {
            echo "## Previous Attempt Failed"
            echo ""
            echo "**Error classification:** ${error_class}"
            echo "**Attempt:** ${attempt} of $((max_retries + 1))"
            echo ""
            echo "### Error Output (last 30 lines)"
            echo '```'
            tail -30 "$_log_file" 2>/dev/null || echo "(no log available)"
            echo '```'
            echo ""
            # Check for existing artifacts that should be preserved
            local _existing_artifacts=""
            for _af in plan.md design.md test-results.log; do
                if [[ -s "${ARTIFACTS_DIR}/${_af}" ]]; then
                    local _af_lines
                    _af_lines=$(wc -l < "${ARTIFACTS_DIR}/${_af}" 2>/dev/null | xargs)
                    _existing_artifacts="${_existing_artifacts}  - ${_af} (${_af_lines} lines)\n"
                fi
            done
            if [[ -n "$_existing_artifacts" ]]; then
                echo "### Existing Artifacts (PRESERVE these)"
                echo -e "$_existing_artifacts"
                echo "These artifacts exist from previous successful stages. Use them as-is unless they are the source of the problem."
                echo ""
            fi
            # Adaptive: check if additional skills could help this retry
            if type skill_memory_get_recommendations >/dev/null 2>&1; then
                local _retry_skills
                _retry_skills=$(skill_memory_get_recommendations "${INTELLIGENCE_ISSUE_TYPE:-backend}" "$stage_id" 2>/dev/null || true)
                if [[ -n "$_retry_skills" ]]; then
                    echo "### Skills Recommended by Learning System"
                    echo "Based on historical success rates, these skills may improve the retry:"
                    echo "- $(printf '%s' "$_retry_skills" | sed 's/,/\n- /g')"
                    echo ""
                fi
            fi

            echo "### Investigation Required"
            echo "Before attempting a fix:"
            echo "1. Read the error output above carefully"
            echo "2. Identify the ROOT CAUSE — not just the symptom"
            echo "3. If previous artifacts exist and are correct, build on them"
            echo "4. If previous artifacts are flawed, explain what's wrong before fixing"
        } > "$_retry_ctx_file" 2>/dev/null || true

        emit_event "retry.context_written" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "attempt=$attempt" \
            "context_file=$_retry_ctx_file"
    done
}

# ─── Self-Healing Build→Test Feedback Loop ─────────────────────────────────
# When tests fail after a build, this captures the error and re-runs the build
# with the error context, so Claude can fix the issue automatically.

self_healing_build_test() {
    local cycle=0
    local max_cycles="$BUILD_TEST_RETRIES"
    local last_test_error=""

    # Convergence tracking
    local prev_error_sig="" consecutive_same_error=0
    local prev_fail_count=0 zero_convergence_streak=0

    # Vitals-driven adaptive limit (preferred over static BUILD_TEST_RETRIES)
    if type pipeline_adaptive_limit >/dev/null 2>&1; then
        local _vitals_json=""
        if type pipeline_compute_vitals >/dev/null 2>&1; then
            _vitals_json=$(pipeline_compute_vitals "$STATE_FILE" "$ARTIFACTS_DIR" "${ISSUE_NUMBER:-}" 2>/dev/null) || true
        fi
        local vitals_limit
        vitals_limit=$(pipeline_adaptive_limit "build_test" "$_vitals_json" 2>/dev/null) || true
        if [[ -n "$vitals_limit" && "$vitals_limit" =~ ^[0-9]+$ && "$vitals_limit" -gt 0 ]]; then
            info "Vitals-driven build-test limit: ${max_cycles} → ${vitals_limit}"
            max_cycles="$vitals_limit"
            emit_event "vitals.adaptive_limit" \
                "issue=${ISSUE_NUMBER:-0}" \
                "context=build_test" \
                "original=$BUILD_TEST_RETRIES" \
                "vitals_limit=$vitals_limit"
        fi
    # Fallback: intelligence-based adaptive limits
    elif type composer_estimate_iterations >/dev/null 2>&1; then
        local estimated
        estimated=$(composer_estimate_iterations \
            "${INTELLIGENCE_ANALYSIS:-{}}" \
            "${HOME}/.shipwright/optimization/iteration-model.json" 2>/dev/null || echo "")
        if [[ -n "$estimated" && "$estimated" =~ ^[0-9]+$ && "$estimated" -gt 0 ]]; then
            max_cycles="$estimated"
            emit_event "intelligence.adaptive_iterations" \
                "issue=${ISSUE_NUMBER:-0}" \
                "estimated=$estimated" \
                "original=$BUILD_TEST_RETRIES"
        fi
    fi

    # Fallback: adaptive cycle limits from optimization data
    if [[ "$max_cycles" == "$BUILD_TEST_RETRIES" ]]; then
        local _iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
        if [[ -f "$_iter_model" ]]; then
            local adaptive_bt_limit
            adaptive_bt_limit=$(pipeline_adaptive_cycles "$max_cycles" "build_test" "0" "-1" 2>/dev/null) || true
            if [[ -n "$adaptive_bt_limit" && "$adaptive_bt_limit" =~ ^[0-9]+$ && "$adaptive_bt_limit" -gt 0 && "$adaptive_bt_limit" != "$max_cycles" ]]; then
                info "Adaptive build-test cycles: ${max_cycles} → ${adaptive_bt_limit}"
                max_cycles="$adaptive_bt_limit"
            fi
        fi
    fi

    while [[ "$cycle" -le "$max_cycles" ]]; do
        cycle=$((cycle + 1))

        if [[ "$cycle" -gt 1 ]]; then
            SELF_HEAL_COUNT=$((SELF_HEAL_COUNT + 1))
            echo ""
            echo -e "${YELLOW}${BOLD}━━━ Self-Healing Cycle ${cycle}/$((max_cycles + 1)) ━━━${RESET}"
            info "Feeding test failure back to build loop..."

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "🔄 **Self-healing cycle ${cycle}** — rebuilding with error context" 2>/dev/null || true
            fi

            # Reset build/test stage statuses for retry
            set_stage_status "build" "retrying"
            set_stage_status "test" "pending"
        fi

        # ── Run Build Stage ──
        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: build${RESET} ${DIM}[cycle ${cycle}]${RESET}"
        CURRENT_STAGE_ID="build"

        # Inject error context on retry cycles
        if [[ "$cycle" -gt 1 && -n "$last_test_error" ]]; then
            # Query memory for known fixes
            local _memory_fix=""
            if type memory_closed_loop_inject >/dev/null 2>&1; then
                local _error_sig_short
                _error_sig_short=$(echo "$last_test_error" | head -3 || echo "")
                _memory_fix=$(memory_closed_loop_inject "$_error_sig_short" 2>/dev/null) || true
            fi

            local memory_prefix=""
            if [[ -n "$_memory_fix" ]]; then
                info "Memory suggests fix: $(echo "$_memory_fix" | head -1)"
                memory_prefix="KNOWN FIX (from past success): ${_memory_fix}

"
            fi

            # Temporarily augment the goal with error context
            local original_goal="$GOAL"
            GOAL="$GOAL

${memory_prefix}IMPORTANT — Previous build attempt failed tests. Fix these errors:
$last_test_error

Focus on fixing the failing tests while keeping all passing tests working."

            update_status "running" "build"
            record_stage_start "build"
            type audit_emit >/dev/null 2>&1 && audit_emit "stage.start" "stage=build" || true

            local build_start_epoch
            build_start_epoch=$(date +%s)
            if run_stage_with_retry "build"; then
                mark_stage_complete "build"
                local timing
                timing=$(get_stage_timing "build")
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=pass" "duration_s=${build_dur_s}" || true
                success "Stage ${BOLD}build${RESET} complete ${DIM}(${timing})${RESET}"
                if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                    local _diff_count
                    _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                    local _snap_files _snap_error
                    _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                    _snap_files="${_snap_files:-0}"
                    _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                    _snap_error="${_snap_error:-}"
                    pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-build}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
                fi
            else
                mark_stage_failed "build"
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=fail" "duration_s=${build_dur_s}" || true
                GOAL="$original_goal"
                return 1
            fi
            GOAL="$original_goal"
        else
            update_status "running" "build"
            record_stage_start "build"
            type audit_emit >/dev/null 2>&1 && audit_emit "stage.start" "stage=build" || true

            local build_start_epoch
            build_start_epoch=$(date +%s)
            if run_stage_with_retry "build"; then
                mark_stage_complete "build"
                local timing
                timing=$(get_stage_timing "build")
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=pass" "duration_s=${build_dur_s}" || true
                success "Stage ${BOLD}build${RESET} complete ${DIM}(${timing})${RESET}"
                if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                    local _diff_count
                    _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                    local _snap_files _snap_error
                    _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                    _snap_files="${_snap_files:-0}"
                    _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                    _snap_error="${_snap_error:-}"
                    pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-build}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
                fi
            else
                mark_stage_failed "build"
                local build_dur_s=$(( $(date +%s) - build_start_epoch ))
                type audit_emit >/dev/null 2>&1 && audit_emit "stage.complete" "stage=build" "verdict=fail" "duration_s=${build_dur_s}" || true
                return 1
            fi
        fi

        # ── Run Test Stage ──
        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: test${RESET} ${DIM}[cycle ${cycle}]${RESET}"
        CURRENT_STAGE_ID="test"
        update_status "running" "test"
        record_stage_start "test"

        if run_stage_with_retry "test"; then
            mark_stage_complete "test"
            local timing
            timing=$(get_stage_timing "test")
            success "Stage ${BOLD}test${RESET} complete ${DIM}(${timing})${RESET}"
            emit_event "convergence.tests_passed" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle"
            if type pipeline_emit_progress_snapshot >/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                local _diff_count
                _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                local _snap_files _snap_error
                _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                _snap_files="${_snap_files:-0}"
                _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                _snap_error="${_snap_error:-}"
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-test}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
            fi
            # Record fix outcome when tests pass after a retry with memory injection (pipeline path)
            if [[ "$cycle" -gt 1 && -n "${last_test_error:-}" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
                local _sig
                _sig=$(echo "$last_test_error" | head -3 | tr '\n' ' ' | sed 's/^ *//;s/ *$//')
                [[ -n "$_sig" ]] && bash "$SCRIPT_DIR/sw-memory.sh" fix-outcome "$_sig" "true" "true" 2>/dev/null || true
            fi
            return 0  # Tests passed!
        fi

        # Tests failed — capture error for next cycle
        local test_log="$ARTIFACTS_DIR/test-results.log"
        last_test_error=$(tail -30 "$test_log" 2>/dev/null || echo "Test command failed with no output")
        mark_stage_failed "test"

        # ── Convergence Detection ──
        # Hash the error output to detect repeated failures
        local error_sig
        error_sig=$(echo "$last_test_error" | shasum -a 256 2>/dev/null | cut -c1-16 || echo "unknown")

        # Count failing tests (extract from common patterns)
        local current_fail_count=0
        current_fail_count=$(grep -ciE 'fail|error|FAIL' "$test_log" 2>/dev/null || true)
        current_fail_count="${current_fail_count:-0}"

        if [[ "$error_sig" == "$prev_error_sig" ]]; then
            consecutive_same_error=$((consecutive_same_error + 1))
        else
            consecutive_same_error=1
        fi
        prev_error_sig="$error_sig"

        # Check: same error 3 times consecutively → stuck
        if [[ "$consecutive_same_error" -ge 3 ]]; then
            error "Convergence: stuck on same error for 3 consecutive cycles — exiting early"
            emit_event "convergence.stuck" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle" \
                "error_sig=$error_sig" \
                "consecutive=$consecutive_same_error"
            notify "Build Convergence" "Stuck on unfixable error after ${cycle} cycles" "error"
            return 1
        fi

        # Track convergence rate: did we reduce failures?
        if [[ "$cycle" -gt 1 && "$prev_fail_count" -gt 0 ]]; then
            if [[ "$current_fail_count" -ge "$prev_fail_count" ]]; then
                zero_convergence_streak=$((zero_convergence_streak + 1))
            else
                zero_convergence_streak=0
            fi

            # Check: zero convergence for 2 consecutive iterations → plateau
            if [[ "$zero_convergence_streak" -ge 2 ]]; then
                error "Convergence: no progress for 2 consecutive cycles (${current_fail_count} failures remain) — exiting early"
                emit_event "convergence.plateau" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "cycle=$cycle" \
                    "fail_count=$current_fail_count" \
                    "streak=$zero_convergence_streak"
                notify "Build Convergence" "No progress after ${cycle} cycles — plateau reached" "error"
                return 1
            fi
        fi
        prev_fail_count="$current_fail_count"

        info "Convergence: error_sig=${error_sig:0:8} repeat=${consecutive_same_error} failures=${current_fail_count} no_progress=${zero_convergence_streak}"

        if [[ "$cycle" -le "$max_cycles" ]]; then
            warn "Tests failed — will attempt self-healing (cycle $((cycle + 1))/$((max_cycles + 1)))"
            notify "Self-Healing" "Tests failed on cycle ${cycle}, retrying..." "warn"
        fi
    done

    error "Self-healing exhausted after $((max_cycles + 1)) cycles"
    notify "Self-Healing Failed" "Tests still failing after $((max_cycles + 1)) build-test cycles" "error"
    return 1
}

# ─── Auto-Rebase ──────────────────────────────────────────────────────────

auto_rebase() {
    info "Syncing with ${BASE_BRANCH}..."

    # Fetch latest
    git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || {
        warn "Could not fetch origin/${BASE_BRANCH}"
        return 0
    }

    # Check if rebase is needed
    local behind
    behind=$(git rev-list --count "HEAD..origin/${BASE_BRANCH}" 2>/dev/null || echo "0")

    if [[ "$behind" -eq 0 ]]; then
        success "Already up to date with ${BASE_BRANCH}"
        return 0
    fi

    info "Rebasing onto origin/${BASE_BRANCH} ($behind commits behind)..."
    if git rebase "origin/${BASE_BRANCH}" --quiet 2>/dev/null; then
        success "Rebase successful"
    else
        warn "Rebase conflict detected — aborting rebase"
        git rebase --abort 2>/dev/null || true
        warn "Falling back to merge..."
        if git merge "origin/${BASE_BRANCH}" --no-edit --quiet 2>/dev/null; then
            success "Merge successful"
        else
            git merge --abort 2>/dev/null || true
            error "Both rebase and merge failed — manual intervention needed"
            return 1
        fi
    fi
}
