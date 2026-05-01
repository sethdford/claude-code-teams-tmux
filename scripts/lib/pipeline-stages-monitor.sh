# pipeline-stages-monitor.sh — validate, monitor stages
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
[[ -n "${_PIPELINE_STAGES_MONITOR_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_MONITOR_LOADED=1

# Resolve the merge commit SHA to validate against. Order of precedence:
#   1. $POST_MERGE_VALIDATE_SHA env override (test hook)
#   2. .claude/pipeline-artifacts/merge-commit.sha (written by merge stage)
#   3. git rev-parse HEAD (best effort fallback)
_validate_resolve_merge_sha() {
    if [[ -n "${POST_MERGE_VALIDATE_SHA:-}" ]]; then
        echo "$POST_MERGE_VALIDATE_SHA"; return 0
    fi
    local f="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}/merge-commit.sha"
    if [[ -s "$f" ]]; then
        head -n1 "$f" | tr -d '[:space:]'; return 0
    fi
    git rev-parse HEAD 2>/dev/null || true
}

# Run post-merge gate: poll Checks API on merge commit, auto-revert on failure,
# reopen the source issue, log to memory. Returns:
#   0 = validation passed (or no-op when disabled / fail-open)
#   1 = validation failed AND revert succeeded (caller should treat as recoverable)
#   2 = validation failed AND revert failed/skipped (caller should escalate)
post_merge_validate_and_revert() {
    if ! type validation_state_init >/dev/null 2>&1; then
        return 0  # libs not loaded — silently no-op
    fi

    # Feature flag: explicit opt-out via env or config
    if [[ "${POST_MERGE_VALIDATE_ENABLED:-true}" == "false" ]]; then
        return 0
    fi

    local merge_sha
    merge_sha=$(_validate_resolve_merge_sha)
    if [[ -z "$merge_sha" ]]; then
        info "Post-merge validation: no merge SHA available, skipping"
        return 0
    fi

    if ! validation_lock_acquire; then
        info "Post-merge validation: another validation in progress, skipping"
        return 0
    fi
    # shellcheck disable=SC2064
    trap 'validation_lock_release' RETURN

    local start_epoch; start_epoch=$(_mv_now_epoch 2>/dev/null || date +%s)
    validation_state_init "$merge_sha" "${ISSUE_NUMBER:-}" || {
        warn "Post-merge validation: state init failed, continuing fail-open"
        return 0
    }

    # Drain any previously-queued issue reopens before doing new work
    issue_reopen_process_queue 2>/dev/null || true

    # Poll required GitHub checks (fail-open on timeout)
    local owner_repo classification="passed"
    if [[ "${NO_GITHUB:-}" != "true" && "${NO_GITHUB:-}" != "1" ]]; then
        owner_repo=$(checks_detect_owner_repo 2>/dev/null || true)
        if [[ -n "$owner_repo" ]]; then
            local owner repo
            owner="${owner_repo%/*}"; repo="${owner_repo#*/}"
            local timeout_s="${POST_MERGE_VALIDATE_TIMEOUT:-180}"
            classification=$(checks_poll_required_checks "$owner" "$repo" "$merge_sha" "$timeout_s")
        fi
    fi

    case "$classification" in
        passed|timeout|empty)
            validation_state_transition "$MV_STATE_SUCCESS" \
                "$(jq -cn --arg c "$classification" '{checks_classification: $c}')" 2>/dev/null || true
            local detect_s=$(( $(date +%s) - start_epoch ))
            validation_memory_log "$merge_sha" "passed" "checks_${classification}" "" "$detect_s" 2>/dev/null || true
            success "Post-merge validation passed (checks: ${classification})"
            return 0
            ;;
        failed)
            warn "Post-merge validation: required checks failed for $merge_sha"
            ;;
        *)
            warn "Post-merge validation: unknown classification '$classification', failing-open"
            return 0
            ;;
    esac

    # Failed path: transition state, attempt revert, reopen issue, log memory
    validation_state_transition "$MV_STATE_FAILED" \
        '{"failure_reason":"required_checks_failed"}' 2>/dev/null || true
    validation_state_transition "$MV_STATE_REVERTING" '{}' 2>/dev/null || true

    local revert_sha rc
    revert_sha=$(revert_commit "$merge_sha" 2>/dev/null); rc=$?
    local detect_s=$(( $(date +%s) - start_epoch ))

    case "$rc" in
        0)
            validation_state_transition "$MV_STATE_REVERTED" \
                "$(jq -cn --arg r "$revert_sha" '{revert_commit_sha:$r}')" 2>/dev/null || true
            success "Reverted merge commit $merge_sha → $revert_sha"
            issue_reopen_with_context "${ISSUE_NUMBER:-}" "$merge_sha" "$revert_sha" \
                "Post-merge required checks failed; merge automatically reverted." 2>/dev/null || true
            validation_memory_log "$merge_sha" "failed_reverted" "required_checks_failed" \
                "$revert_sha" "$detect_s" 2>/dev/null || true
            return 1
            ;;
        2)
            validation_state_transition "$MV_STATE_REVERT_FAILED" \
                '{"revert_skipped":true}' 2>/dev/null || true
            warn "Revert skipped (idempotent / head-moved / circuit-breaker)"
            issue_reopen_with_context "${ISSUE_NUMBER:-}" "$merge_sha" "" \
                "Post-merge checks failed; revert skipped — manual intervention required." 2>/dev/null || true
            validation_memory_log "$merge_sha" "failed_revert_skipped" "required_checks_failed" \
                "" "$detect_s" 2>/dev/null || true
            return 2
            ;;
        *)
            validation_state_transition "$MV_STATE_REVERT_FAILED" \
                '{"revert_error":"conflict_or_failure"}' 2>/dev/null || true
            error "Revert FAILED — manual intervention required for $merge_sha"
            issue_reopen_with_context "${ISSUE_NUMBER:-}" "$merge_sha" "" \
                "Post-merge checks failed AND auto-revert failed (conflict). Manual rollback required." 2>/dev/null || true
            validation_memory_log "$merge_sha" "revert_failed" "revert_conflict" \
                "" "$detect_s" 2>/dev/null || true
            return 2
            ;;
    esac
}

stage_validate() {
    CURRENT_STAGE_ID="validate"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-validate.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _validate_retry_hints
        _validate_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    # Load validation thoroughness skills
    if type skill_load_prompts >/dev/null 2>&1; then
        local _validate_skills
        _validate_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "validate" 2>/dev/null || true)
        if [[ -n "$_validate_skills" ]]; then
            echo "$_validate_skills" > "${ARTIFACTS_DIR}/.validation-skills.md" 2>/dev/null || true
        fi
    fi
    local smoke_cmd
    smoke_cmd=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.smoke_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$smoke_cmd" == "null" ]] && smoke_cmd=""

    local health_url
    health_url=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""

    local close_issue
    close_issue=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.close_issue) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true

    # Post-merge gate: poll Checks API, auto-revert + reopen issue on failure.
    # Only runs when libs are loaded; fail-open on infrastructure errors.
    if type post_merge_validate_and_revert >/dev/null 2>&1; then
        local _pm_rc=0
        post_merge_validate_and_revert || _pm_rc=$?
        case "$_pm_rc" in
            1)
                # Validation failed but revert succeeded — recoverable.
                # Skip the rest of validate (smoke/close/wiki) since merge is undone.
                log_stage "validate" "Post-merge revert applied"
                return 1
                ;;
            2)
                # Validation failed and revert did NOT succeed — escalate.
                error "Post-merge validation failed AND revert did not succeed"
                return 1
                ;;
        esac
    fi

    # Smoke tests
    if [[ -n "$smoke_cmd" ]]; then
        info "Running smoke tests..."
        bash -c "$smoke_cmd" > "$ARTIFACTS_DIR/smoke.log" 2>&1 || {
            error "Smoke tests failed"
            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh issue create --title "Deploy validation failed: $GOAL" \
                    --label "incident" --body "Pipeline smoke tests failed after deploy.

Related issue: ${GITHUB_ISSUE}
Branch: ${GIT_BRANCH}
PR: $(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo 'unknown')" 2>/dev/null || true
            fi
            return 1
        }
        success "Smoke tests passed"
    fi

    # Health check with retry
    if [[ -n "$health_url" ]]; then
        info "Health check: $health_url"
        local attempts=0
        while [[ $attempts -lt 5 ]]; do
            if curl -sf "$health_url" >/dev/null 2>&1; then
                success "Health check passed"
                break
            fi
            attempts=$((attempts + 1))
            [[ $attempts -lt 5 ]] && { info "Retry ${attempts}/5..."; sleep "$(_exponential_backoff "$attempts" 5 60)"; }
        done
        if [[ $attempts -ge 5 ]]; then
            error "Health check failed after 5 attempts"
            return 1
        fi
    fi

    # Compute total duration once for both issue close and wiki report
    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    # Close original issue with comprehensive summary
    if [[ "$close_issue" == "true" && -n "$ISSUE_NUMBER" ]]; then
        gh issue close "$ISSUE_NUMBER" --comment "## ✅ Complete — Deployed & Validated

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Branch | \`${GIT_BRANCH}\` |
| PR | $(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo 'N/A') |
| Duration | ${total_dur:-unknown} |

_Closed automatically by \`shipwright pipeline\`_" 2>/dev/null || true

        gh_remove_label "$ISSUE_NUMBER" "pipeline/pr-created"
        gh_add_labels "$ISSUE_NUMBER" "pipeline/complete"
        success "Issue #$ISSUE_NUMBER closed"
    fi

    # Push pipeline report to wiki
    local report="# Pipeline Report — ${GOAL}

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Branch | \`${GIT_BRANCH}\` |
| PR | $(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo 'N/A') |
| Duration | ${total_dur:-unknown} |
| Stages | $(echo "$STAGE_TIMINGS" | tr '|' '\n' | wc -l | xargs) completed |

## Stage Timings
$(echo "$STAGE_TIMINGS" | tr '|' '\n' | sed 's/^/- /')

## Artifacts
$(ls -1 "$ARTIFACTS_DIR" 2>/dev/null | sed 's/^/- /')

---
_Generated by \`shipwright pipeline\` at $(now_iso)_"
    gh_wiki_page "Pipeline-Report-${ISSUE_NUMBER:-inline}" "$report"

    log_stage "validate" "Validation complete"
}

stage_monitor() {
    CURRENT_STAGE_ID="monitor"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-monitor.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _monitor_retry_hints
        _monitor_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    # Load observability skills
    if type skill_load_prompts >/dev/null 2>&1; then
        local _monitor_skills
        _monitor_skills=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "monitor" 2>/dev/null || true)
        if [[ -n "$_monitor_skills" ]]; then
            echo "$_monitor_skills" > "${ARTIFACTS_DIR}/.monitoring-skills.md" 2>/dev/null || true
        fi
    fi

    # Read config from pipeline template
    local duration_minutes health_url error_threshold log_pattern log_cmd rollback_cmd auto_rollback
    duration_minutes=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.duration_minutes) // 5' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$duration_minutes" || "$duration_minutes" == "null" ]] && duration_minutes=5
    health_url=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""
    error_threshold=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.error_threshold) // 5' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$error_threshold" || "$error_threshold" == "null" ]] && error_threshold=5

    # Adaptive monitor: use historical baselines if available
    local repo_hash
    repo_hash=$(echo "${PROJECT_ROOT:-$(pwd)}" | cksum | awk '{print $1}')
    local baseline_file="${HOME}/.shipwright/baselines/${repo_hash}/deploy-monitor.json"
    if [[ -f "$baseline_file" ]]; then
        local hist_duration hist_threshold
        hist_duration=$(jq -r '.p90_stabilization_minutes // empty' "$baseline_file" 2>/dev/null || true)
        hist_threshold=$(jq -r '.p90_error_threshold // empty' "$baseline_file" 2>/dev/null || true)
        if [[ -n "$hist_duration" && "$hist_duration" != "null" ]]; then
            duration_minutes="$hist_duration"
            info "Monitor duration: ${duration_minutes}m ${DIM}(from baseline)${RESET}"
        fi
        if [[ -n "$hist_threshold" && "$hist_threshold" != "null" ]]; then
            error_threshold="$hist_threshold"
            info "Error threshold: ${error_threshold} ${DIM}(from baseline)${RESET}"
        fi
    fi
    log_pattern=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.log_pattern) // "ERROR|FATAL|PANIC"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$log_pattern" || "$log_pattern" == "null" ]] && log_pattern="ERROR|FATAL|PANIC"
    log_cmd=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.log_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$log_cmd" == "null" ]] && log_cmd=""
    rollback_cmd=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.rollback_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$rollback_cmd" == "null" ]] && rollback_cmd=""
    auto_rollback=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.auto_rollback) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_rollback" || "$auto_rollback" == "null" ]] && auto_rollback="false"

    if [[ -z "$health_url" && -z "$log_cmd" ]]; then
        warn "No health_url or log_cmd configured — skipping monitor stage"
        log_stage "monitor" "Skipped (no monitoring configured)"
        return 0
    fi

    local report_file="$ARTIFACTS_DIR/monitor-report.md"
    local deploy_log_file="$ARTIFACTS_DIR/deploy-logs.txt"
    : > "$deploy_log_file"
    local total_errors=0
    local poll_interval=30  # seconds between polls
    local total_polls=$(( (duration_minutes * 60) / poll_interval ))
    [[ "$total_polls" -lt 1 ]] && total_polls=1

    info "Post-deploy monitoring: ${duration_minutes}m (${total_polls} polls, threshold: ${error_threshold} errors)"

    emit_event "monitor.started" \
        "issue=${ISSUE_NUMBER:-0}" \
        "duration_minutes=$duration_minutes" \
        "error_threshold=$error_threshold"

    {
        echo "# Post-Deploy Monitor Report"
        echo ""
        echo "- Duration: ${duration_minutes} minutes"
        echo "- Health URL: ${health_url:-none}"
        echo "- Log command: ${log_cmd:-none}"
        echo "- Error threshold: ${error_threshold}"
        echo "- Auto-rollback: ${auto_rollback}"
        echo ""
        echo "## Poll Results"
        echo ""
    } > "$report_file"

    local poll=0
    local health_failures=0
    local log_errors=0
    while [[ "$poll" -lt "$total_polls" ]]; do
        poll=$((poll + 1))
        local poll_time
        poll_time=$(now_iso)

        # Health URL check
        if [[ -n "$health_url" ]]; then
            local http_status
            http_status=$(curl -sf -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "000")
            if [[ "$http_status" -ge 200 && "$http_status" -lt 400 ]]; then
                echo "- [${poll_time}] Health: ✅ (HTTP ${http_status})" >> "$report_file"
            else
                health_failures=$((health_failures + 1))
                total_errors=$((total_errors + 1))
                echo "- [${poll_time}] Health: ❌ (HTTP ${http_status})" >> "$report_file"
                warn "Health check failed: HTTP ${http_status}"
            fi
        fi

        # Log command check (accumulate deploy logs for feedback collect)
        if [[ -n "$log_cmd" ]]; then
            local log_output
            log_output=$(bash -c "$log_cmd" 2>/dev/null || true)
            [[ -n "$log_output" ]] && echo "$log_output" >> "$deploy_log_file"
            local error_count=0
            if [[ -n "$log_output" ]]; then
                error_count=$(echo "$log_output" | grep -cE "$log_pattern" 2>/dev/null || true)
                error_count="${error_count:-0}"
            fi
            if [[ "$error_count" -gt 0 ]]; then
                log_errors=$((log_errors + error_count))
                total_errors=$((total_errors + error_count))
                echo "- [${poll_time}] Logs: ⚠️ ${error_count} error(s) matching '${log_pattern}'" >> "$report_file"
                warn "Log errors detected: ${error_count}"
            else
                echo "- [${poll_time}] Logs: ✅ clean" >> "$report_file"
            fi
        fi

        emit_event "monitor.check" \
            "issue=${ISSUE_NUMBER:-0}" \
            "poll=$poll" \
            "total_errors=$total_errors" \
            "health_failures=$health_failures"

        # Check threshold
        if [[ "$total_errors" -ge "$error_threshold" ]]; then
            error "Error threshold exceeded: ${total_errors} >= ${error_threshold}"

            echo "" >> "$report_file"
            echo "## ❌ THRESHOLD EXCEEDED" >> "$report_file"
            echo "Total errors: ${total_errors} (threshold: ${error_threshold})" >> "$report_file"

            emit_event "monitor.alert" \
                "issue=${ISSUE_NUMBER:-0}" \
                "total_errors=$total_errors" \
                "threshold=$error_threshold"

            # Feedback loop: collect deploy logs and optionally create issue
            if [[ -f "$deploy_log_file" ]] && [[ -s "$deploy_log_file" ]] && [[ -x "$SCRIPT_DIR/sw-feedback.sh" ]]; then
                (cd "$PROJECT_ROOT" && ARTIFACTS_DIR="$ARTIFACTS_DIR" bash "$SCRIPT_DIR/sw-feedback.sh" collect "$deploy_log_file" 2>/dev/null) || true
                (cd "$PROJECT_ROOT" && ARTIFACTS_DIR="$ARTIFACTS_DIR" bash "$SCRIPT_DIR/sw-feedback.sh" create-issue 2>/dev/null) || true
            fi

            # Auto-rollback: feedback rollback (GitHub Deployments API) and/or config rollback_cmd
            if [[ "$auto_rollback" == "true" ]]; then
                warn "Auto-rolling back..."
                echo "" >> "$report_file"
                echo "## Rollback" >> "$report_file"

                # Trigger feedback rollback (calls sw-github-deploy.sh rollback)
                if [[ -x "$SCRIPT_DIR/sw-feedback.sh" ]]; then
                    (cd "$PROJECT_ROOT" && ARTIFACTS_DIR="$ARTIFACTS_DIR" bash "$SCRIPT_DIR/sw-feedback.sh" rollback production "Monitor threshold exceeded (${total_errors} errors)" >> "$report_file" 2>&1) || true
                fi

                if [[ -n "$rollback_cmd" ]] && bash -c "$rollback_cmd" >> "$report_file" 2>&1; then
                    success "Rollback executed"
                    echo "Rollback: ✅ success" >> "$report_file"

                    # Post-rollback smoke test verification
                    local smoke_cmd
                    smoke_cmd=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.smoke_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
                    [[ "$smoke_cmd" == "null" ]] && smoke_cmd=""

                    if [[ -n "$smoke_cmd" ]]; then
                        info "Verifying rollback with smoke tests..."
                        if bash -c "$smoke_cmd" > "$ARTIFACTS_DIR/rollback-smoke.log" 2>&1; then
                            success "Rollback verified — smoke tests pass"
                            echo "Rollback verification: ✅ smoke tests pass" >> "$report_file"
                            emit_event "monitor.rollback_verified" \
                                "issue=${ISSUE_NUMBER:-0}" \
                                "status=pass"
                        else
                            error "Rollback verification FAILED — smoke tests still failing"
                            echo "Rollback verification: ❌ smoke tests FAILED — manual intervention required" >> "$report_file"
                            emit_event "monitor.rollback_verified" \
                                "issue=${ISSUE_NUMBER:-0}" \
                                "status=fail"
                            if [[ -n "$ISSUE_NUMBER" ]]; then
                                gh_comment_issue "$ISSUE_NUMBER" "🚨 **Rollback executed but verification failed** — smoke tests still failing after rollback. Manual intervention required.

Smoke command: \`${smoke_cmd}\`
Log: see \`pipeline-artifacts/rollback-smoke.log\`" 2>/dev/null || true
                            fi
                        fi
                    fi
                else
                    error "Rollback failed!"
                    echo "Rollback: ❌ failed" >> "$report_file"
                fi

                emit_event "monitor.rollback" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "total_errors=$total_errors"

                # Post to GitHub
                if [[ -n "$ISSUE_NUMBER" ]]; then
                    gh_comment_issue "$ISSUE_NUMBER" "🚨 **Auto-rollback triggered** — ${total_errors} errors exceeded threshold (${error_threshold})

Rollback command: \`${rollback_cmd}\`" 2>/dev/null || true

                    # Create hotfix issue
                    if [[ "$GH_AVAILABLE" == "true" ]]; then
                        gh issue create \
                            --title "Hotfix: Deploy regression for ${GOAL}" \
                            --label "hotfix,incident" \
                            --body "Auto-rollback triggered during post-deploy monitoring.

**Original issue:** ${GITHUB_ISSUE:-N/A}
**Errors detected:** ${total_errors}
**Threshold:** ${error_threshold}
**Branch:** ${GIT_BRANCH}

## Monitor Report
$(cat "$report_file")

---
_Created automatically by \`shipwright pipeline\` monitor stage_" 2>/dev/null || true
                    fi
                fi
            fi

            log_stage "monitor" "Failed — ${total_errors} errors (threshold: ${error_threshold})"
            return 1
        fi

        # Sleep between polls (skip on last poll)
        if [[ "$poll" -lt "$total_polls" ]]; then
            sleep "$poll_interval"
        fi
    done

    # Monitoring complete — all clear
    echo "" >> "$report_file"
    echo "## ✅ Monitoring Complete" >> "$report_file"
    echo "Total errors: ${total_errors} (threshold: ${error_threshold})" >> "$report_file"
    echo "Health failures: ${health_failures}" >> "$report_file"
    echo "Log errors: ${log_errors}" >> "$report_file"

    success "Post-deploy monitoring clean (${total_errors} errors in ${duration_minutes}m)"

    # Proactive feedback collection: always collect deploy logs for trend analysis
    if [[ -f "$deploy_log_file" ]] && [[ -s "$deploy_log_file" ]] && [[ -x "$SCRIPT_DIR/sw-feedback.sh" ]]; then
        (cd "$PROJECT_ROOT" && ARTIFACTS_DIR="$ARTIFACTS_DIR" bash "$SCRIPT_DIR/sw-feedback.sh" collect "$deploy_log_file" 2>/dev/null) || true
    fi

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Post-deploy monitoring passed** — ${duration_minutes}m, ${total_errors} errors" 2>/dev/null || true
    fi

    log_stage "monitor" "Clean — ${total_errors} errors in ${duration_minutes}m"

    # Record baseline for adaptive monitoring on future runs
    local baseline_dir="${HOME}/.shipwright/baselines/${repo_hash}"
    mkdir -p "$baseline_dir" 2>/dev/null || true
    local baseline_tmp
    baseline_tmp="$(mktemp)"
    if [[ -f "${baseline_dir}/deploy-monitor.json" ]]; then
        # Append to history and recalculate p90
        jq --arg dur "$duration_minutes" --arg errs "$total_errors" \
            '.history += [{"duration_minutes": ($dur | tonumber), "errors": ($errs | tonumber)}] |
             .p90_stabilization_minutes = ([.history[].duration_minutes] | sort | .[length * 9 / 10 | floor]) |
             .p90_error_threshold = (([.history[].errors] | sort | .[length * 9 / 10 | floor]) + 2) |
             .updated_at = now' \
            "${baseline_dir}/deploy-monitor.json" > "$baseline_tmp" 2>/dev/null && \
            mv "$baseline_tmp" "${baseline_dir}/deploy-monitor.json" || rm -f "$baseline_tmp"
    else
        jq -n --arg dur "$duration_minutes" --arg errs "$total_errors" \
            '{history: [{"duration_minutes": ($dur | tonumber), "errors": ($errs | tonumber)}],
              p90_stabilization_minutes: ($dur | tonumber),
              p90_error_threshold: (($errs | tonumber) + 2),
              updated_at: now}' \
            > "$baseline_tmp" 2>/dev/null && \
            mv "$baseline_tmp" "${baseline_dir}/deploy-monitor.json" || rm -f "$baseline_tmp"
    fi
}

# ─── Multi-Dimensional Quality Checks ─────────────────────────────────────
# Beyond tests: security, bundle size, perf regression, API compat, coverage

