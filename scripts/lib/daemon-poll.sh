# daemon-poll.sh — Poll loop, health, scale, cleanup (for sw-daemon.sh)
# Source from sw-daemon.sh. Requires daemon-health, state, dispatch, failure, patrol.
[[ -n "${_DAEMON_POLL_LOADED:-}" ]] && return 0
_DAEMON_POLL_LOADED=1

# Defaults for variables normally set by sw-daemon.sh (safe under set -u).
DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
STATE_FILE="${STATE_FILE:-${DAEMON_DIR}/daemon-state.json}"
PAUSE_FLAG="${PAUSE_FLAG:-${DAEMON_DIR}/daemon-pause.flag}"
SHUTDOWN_FLAG="${SHUTDOWN_FLAG:-${DAEMON_DIR}/daemon.shutdown}"
EVENTS_FILE="${EVENTS_FILE:-${DAEMON_DIR}/events.jsonl}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NO_GITHUB="${NO_GITHUB:-false}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
WATCH_LABEL="${WATCH_LABEL:-shipwright}"
WATCH_MODE="${WATCH_MODE:-repo}"
PIPELINE_TEMPLATE="${PIPELINE_TEMPLATE:-autonomous}"
ISSUE_LIMIT="${ISSUE_LIMIT:-100}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
BACKOFF_SECS="${BACKOFF_SECS:-0}"
POLL_CYCLE_COUNT="${POLL_CYCLE_COUNT:-0}"

daemon_poll_issues() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        daemon_log INFO "Polling skipped (--no-github)"
        return
    fi

    # Check for pause flag (set by dashboard, disk_low, or consecutive-failure backoff)
    local pause_file="${PAUSE_FLAG:-$HOME/.shipwright/daemon-pause.flag}"
    if [[ -f "$pause_file" ]]; then
        local resume_after
        resume_after=$(jq -r '.resume_after // empty' "$pause_file" 2>/dev/null || true)
        if [[ -n "$resume_after" ]]; then
            local now_epoch resume_epoch
            now_epoch=$(date +%s)
            resume_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$resume_after" +%s 2>/dev/null || \
                date -d "$resume_after" +%s 2>/dev/null || echo 0)
            if [[ "$resume_epoch" -gt 0 ]] && [[ "$now_epoch" -ge "$resume_epoch" ]]; then
                rm -f "$pause_file"
                daemon_log INFO "Auto-resuming after backoff (resume_after passed)"
            else
                daemon_log INFO "Daemon paused until ${resume_after} — skipping poll"
                return
            fi
        else
            daemon_log INFO "Daemon paused — skipping poll"
            return
        fi
    fi

    # Circuit breaker: skip poll if in backoff window
    if gh_rate_limited; then
        daemon_log INFO "Polling skipped (rate-limit backoff until $(epoch_to_iso "$GH_BACKOFF_UNTIL"))"
        return
    fi

    local issues_json

    # Select gh command wrapper: gh_retry for critical poll calls when enabled
    local gh_cmd="gh"
    if [[ "${GH_RETRY_ENABLED:-true}" == "true" ]]; then
        gh_cmd="gh_retry gh"
    fi

    if [[ "$WATCH_MODE" == "org" && -n "$ORG" ]]; then
        # Org-wide mode: search issues across all org repos
        issues_json=$($gh_cmd search issues \
            --label "$WATCH_LABEL" \
            --owner "$ORG" \
            --state open \
            --json repository,number,title,labels,body,createdAt \
            --limit "${ISSUE_LIMIT:-100}" 2>/dev/null) || {
            # Handle rate limiting with exponential backoff
            if [[ $BACKOFF_SECS -eq 0 ]]; then
                BACKOFF_SECS=30
            elif [[ $BACKOFF_SECS -lt 300 ]]; then
                BACKOFF_SECS=$((BACKOFF_SECS * 2))
                if [[ $BACKOFF_SECS -gt 300 ]]; then
                    BACKOFF_SECS=300
                fi
            fi
            daemon_log WARN "GitHub API error (org search) — backing off ${BACKOFF_SECS}s"
            gh_record_failure
            sleep "$BACKOFF_SECS"
            return
        }

        # Filter by repo_filter regex if set
        if [[ -n "$REPO_FILTER" ]]; then
            issues_json=$(echo "$issues_json" | jq -c --arg filter "$REPO_FILTER" \
                '[.[] | select(.repository.nameWithOwner | test($filter))]')
        fi
    else
        # Standard single-repo mode
        issues_json=$($gh_cmd issue list \
            --label "$WATCH_LABEL" \
            --state open \
            --json number,title,labels,body,createdAt \
            --limit 100 2>/dev/null) || {
            # Handle rate limiting with exponential backoff
            if [[ $BACKOFF_SECS -eq 0 ]]; then
                BACKOFF_SECS=30
            elif [[ $BACKOFF_SECS -lt 300 ]]; then
                BACKOFF_SECS=$((BACKOFF_SECS * 2))
                if [[ $BACKOFF_SECS -gt 300 ]]; then
                    BACKOFF_SECS=300
                fi
            fi
            daemon_log WARN "GitHub API error — backing off ${BACKOFF_SECS}s"
            gh_record_failure
            sleep "$BACKOFF_SECS"
            return
        }
    fi

    # Reset backoff on success
    BACKOFF_SECS=0
    gh_record_success

    local issue_count
    issue_count=$(echo "$issues_json" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$issue_count" -eq 0 ]]; then
        return
    fi

    local mode_label="repo"
    [[ "$WATCH_MODE" == "org" ]] && mode_label="org:${ORG}"
    daemon_log INFO "Found ${issue_count} issue(s) with label '${WATCH_LABEL}' (${mode_label})"
    emit_event "daemon.poll" "issues_found=$issue_count" "active=$(get_active_count)" "mode=$WATCH_MODE"

    # Score each issue using intelligent triage and sort by descending score
    local scored_issues=()
    local dep_graph=""  # "issue:dep1,dep2" entries for dependency ordering
    while IFS= read -r issue; do
        local num score
        num=$(echo "$issue" | jq -r '.number')
        score=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
        score=$(printf '%s' "$score" | tr -cd '[:digit:]')
        [[ -z "$score" ]] && score=50
        # For org mode, include repo name in the scored entry
        local repo_name=""
        if [[ "$WATCH_MODE" == "org" ]]; then
            repo_name=$(echo "$issue" | jq -r '.repository.nameWithOwner // ""')
        fi
        scored_issues+=("${score}|${num}|${repo_name}")

        # Issue dependency detection (adaptive: extract "depends on #X", "blocked by #X")
        if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" == "true" ]]; then
            local issue_text
            issue_text=$(echo "$issue" | jq -r '(.title // "") + " " + (.body // "")')
            local deps
            deps=$(extract_issue_dependencies "$issue_text")
            if [[ -n "$deps" ]]; then
                local dep_nums
                dep_nums=$(echo "$deps" | tr -d '#' | tr '\n' ',' | sed 's/,$//')
                dep_graph="${dep_graph}${num}:${dep_nums}\n"
                daemon_log INFO "Issue #${num} depends on: ${deps//$'\n'/, }"
            fi
        fi
    done < <(echo "$issues_json" | jq -c '.[]')

    # Sort by score — strategy determines ascending vs descending
    local sorted_order
    if [[ "${PRIORITY_STRATEGY:-quick-wins-first}" == "complex-first" ]]; then
        # Complex-first: lower score (more complex) first
        sorted_order=$(printf '%s\n' "${scored_issues[@]}" | sort -t'|' -k1,1 -n -k2,2 -n)
    else
        # Quick-wins-first (default): higher score (simpler) first, lowest issue# first on ties
        sorted_order=$(printf '%s\n' "${scored_issues[@]}" | sort -t'|' -k1,1 -rn -k2,2 -n)
    fi

    # Dependency-aware reordering: move dependencies before dependents
    if [[ -n "$dep_graph" && "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" == "true" ]]; then
        local reordered=""
        local scheduled=""
        # Multiple passes to resolve transitive dependencies (max 3)
        local pass=0
        while [[ $pass -lt 3 ]]; do
            local changed=false
            local new_order=""
            while IFS='|' read -r s_score s_num s_repo; do
                [[ -z "$s_num" ]] && continue
                # Check if this issue has unscheduled dependencies
                local issue_deps
                issue_deps=$(echo -e "$dep_graph" | grep "^${s_num}:" | head -1 | cut -d: -f2 || true)
                if [[ -n "$issue_deps" ]]; then
                    # Check if all deps are scheduled (or not in our issue set)
                    local all_deps_ready=true
                    local IFS_SAVE="$IFS"
                    IFS=','
                    for dep in $issue_deps; do
                        dep="${dep## }"
                        dep="${dep%% }"
                        # Is this dep in our scored set and not yet scheduled?
                        if echo "$sorted_order" | grep -q "|${dep}|" && ! echo "$scheduled" | grep -q "|${dep}|"; then
                            all_deps_ready=false
                            break
                        fi
                    done
                    IFS="$IFS_SAVE"
                    if [[ "$all_deps_ready" == "false" ]]; then
                        # Defer this issue — append at end
                        new_order="${new_order}${s_score}|${s_num}|${s_repo}\n"
                        changed=true
                        continue
                    fi
                fi
                reordered="${reordered}${s_score}|${s_num}|${s_repo}\n"
                scheduled="${scheduled}|${s_num}|"
            done <<< "$sorted_order"
            # Append deferred issues
            reordered="${reordered}${new_order}"
            sorted_order=$(echo -e "$reordered" | grep -v '^$')
            reordered=""
            scheduled=""
            if [[ "$changed" == "false" ]]; then
                break
            fi
            pass=$((pass + 1))
        done
    fi

    local active_count
    active_count=$(locked_get_active_count)

    # Process each issue in triage order (process substitution keeps state in current shell)
    while IFS='|' read -r score issue_num repo_name; do
        [[ -z "$issue_num" ]] && continue

        local issue_key
        issue_key="$issue_num"
        [[ -n "$repo_name" ]] && issue_key="${repo_name}:${issue_num}"

        local issue_title labels_csv
        issue_title=$(echo "$issues_json" | jq -r --argjson n "$issue_num" --arg repo "$repo_name" '.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo) | .title')
        labels_csv=$(echo "$issues_json" | jq -r --argjson n "$issue_num" --arg repo "$repo_name" '.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo) | [.labels[].name] | join(",")')

        # Cache title in state for dashboard visibility (use issue_key for org mode)
        if [[ -n "$issue_title" ]]; then
            locked_state_update --arg num "$issue_key" --arg title "$issue_title" \
                '.titles[$num] = $title'
        fi

        # Skip if already inflight
        if daemon_is_inflight "$issue_key"; then
            continue
        fi

        # Distributed claim (skip if no machines registered)
        if [[ -f "$HOME/.shipwright/machines.json" ]]; then
            local machine_name
            machine_name=$(jq -r '.machines[] | select(.role == "primary") | .name' "$HOME/.shipwright/machines.json" 2>/dev/null || hostname -s)
            if ! claim_issue "$issue_num" "$machine_name"; then
                daemon_log INFO "Issue #${issue_num} claimed by another machine — skipping"
                continue
            fi
        fi

        # Priority lane: bypass queue for critical issues
        if [[ "$PRIORITY_LANE" == "true" ]]; then
            local priority_active
            priority_active=$(get_priority_active_count)
            if is_priority_issue "$labels_csv" && [[ "$priority_active" -lt "$PRIORITY_LANE_MAX" ]]; then
                daemon_log WARN "PRIORITY LANE: issue #${issue_num} bypassing queue (${labels_csv})"
                emit_event "daemon.priority_lane" "issue=$issue_num" "score=$score"

                local template
                template=$(select_pipeline_template "$labels_csv" "$score" 2>/dev/null | tail -1)
                template=$(printf '%s' "$template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
                [[ -z "$template" ]] && template="$PIPELINE_TEMPLATE"
                daemon_log INFO "Triage: issue #${issue_num} scored ${score}, template=${template} [PRIORITY]"

                local orig_template="$PIPELINE_TEMPLATE"
                PIPELINE_TEMPLATE="$template"
                daemon_spawn_pipeline "$issue_num" "$issue_title" "$repo_name"
                PIPELINE_TEMPLATE="$orig_template"
                track_priority_job "$issue_num"
                continue
            fi
        fi

        # Check capacity
        active_count=$(locked_get_active_count)
        if [[ "$active_count" -ge "$MAX_PARALLEL" ]]; then
            enqueue_issue "$issue_key"
            continue
        fi

        # Auto-select pipeline template: PM recommendation (if available) else labels + triage score
        local template
        if [[ "$NO_GITHUB" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-pm.sh" ]]; then
            local pm_rec
            pm_rec=$(bash "$SCRIPT_DIR/sw-pm.sh" recommend --json "$issue_num" 2>/dev/null) || true
            if [[ -n "$pm_rec" ]]; then
                template=$(echo "$pm_rec" | jq -r '.team_composition.template // empty' 2>/dev/null) || true
                # Capability self-assessment: low confidence → upgrade to full template
                local confidence
                confidence=$(echo "$pm_rec" | jq -r '.team_composition.confidence_percent // 100' 2>/dev/null) || true
                if [[ -n "$confidence" && "$confidence" != "null" && "$confidence" -lt 60 ]]; then
                    daemon_log INFO "Low PM confidence (${confidence}%) — upgrading to full template"
                    template="full"
                fi
            fi
        fi
        if [[ -z "$template" ]]; then
            template=$(select_pipeline_template "$labels_csv" "$score" 2>/dev/null | tail -1)
        fi
        template=$(printf '%s' "$template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
        [[ -z "$template" ]] && template="$PIPELINE_TEMPLATE"
        daemon_log INFO "Triage: issue #${issue_num} scored ${score}, template=${template}"

        # Spawn pipeline (template selection applied via PIPELINE_TEMPLATE override)
        local orig_template="$PIPELINE_TEMPLATE"
        PIPELINE_TEMPLATE="$template"
        daemon_spawn_pipeline "$issue_num" "$issue_title" "$repo_name"
        PIPELINE_TEMPLATE="$orig_template"

        # Stagger delay between spawns to avoid API contention
        local stagger_delay="${SPAWN_STAGGER_SECONDS:-15}"
        if [[ "$stagger_delay" -gt 0 ]]; then
            sleep "$stagger_delay"
        fi
    done <<< "$sorted_order"

    # ── Drain queue if we have capacity (prevents deadlock when queue is
    #    populated but no active jobs exist to trigger dequeue) ──
    local drain_active
    drain_active=$(locked_get_active_count)
    while [[ "$drain_active" -lt "$MAX_PARALLEL" ]]; do
        local drain_issue_key
        drain_issue_key=$(dequeue_next)
        [[ -z "$drain_issue_key" ]] && break
        local drain_issue_num="$drain_issue_key" drain_repo=""
        [[ "$drain_issue_key" == *:* ]] && drain_repo="${drain_issue_key%%:*}" && drain_issue_num="${drain_issue_key##*:}"
        local drain_title
        drain_title=$(jq -r --arg n "$drain_issue_key" '.titles[$n] // ""' "$STATE_FILE" 2>/dev/null || true)

        local drain_labels drain_score drain_template
        drain_labels=$(echo "$issues_json" | jq -r --argjson n "$drain_issue_num" --arg repo "$drain_repo" \
            '.[] | select(.number == $n) | select($repo == "" or (.repository.nameWithOwner // "") == $repo) | [.labels[].name] | join(",")' 2>/dev/null || echo "")
        drain_score=$(echo "$sorted_order" | grep "|${drain_issue_num}|" | cut -d'|' -f1 || echo "50")
        drain_template=$(select_pipeline_template "$drain_labels" "${drain_score:-50}" 2>/dev/null | tail -1)
        drain_template=$(printf '%s' "$drain_template" | sed $'s/\x1b\\[[0-9;]*m//g' | tr -cd '[:alnum:]-_')
        [[ -z "$drain_template" ]] && drain_template="$PIPELINE_TEMPLATE"

        daemon_log INFO "Draining queue: issue #${drain_issue_num}${drain_repo:+, repo=${drain_repo}}, template=${drain_template}"
        local orig_template="$PIPELINE_TEMPLATE"
        PIPELINE_TEMPLATE="$drain_template"
        daemon_spawn_pipeline "$drain_issue_num" "$drain_title" "$drain_repo"
        PIPELINE_TEMPLATE="$orig_template"
        drain_active=$(locked_get_active_count)
    done

    # Update last poll
    update_state_field "last_poll" "$(now_iso)"
}

# ─── Health Check ─────────────────────────────────────────────────────────────

daemon_health_check() {
    local findings=0
    local now_e
    now_e=$(now_epoch)

    if [[ -f "$STATE_FILE" ]]; then
        # ── Intelligent Health Monitoring ──
        # Instead of killing after a countdown, sense what the agent is doing.
        # Agents think for long stretches — that's normal and expected.
        # Strategy: sense → understand → be patient → nudge → only kill as last resort.

        local hard_limit="${PROGRESS_HARD_LIMIT_S:-0}"
        local use_progress="${PROGRESS_MONITORING:-true}"
        local nudge_enabled="${NUDGE_ENABLED:-true}"
        local nudge_after="${NUDGE_AFTER_CHECKS:-40}"

        while IFS= read -r job; do
            local pid started_at issue_num worktree
            pid=$(echo "$job" | jq -r '.pid')
            started_at=$(echo "$job" | jq -r '.started_at // empty')
            issue_num=$(echo "$job" | jq -r '.issue')
            worktree=$(echo "$job" | jq -r '.worktree // ""')

            # Skip dead processes
            if ! kill -0 "$pid" 2>/dev/null; then
                continue
            fi

            local elapsed=0
            if [[ -n "$started_at" ]]; then
                local start_e
                start_e=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null || date -d "$started_at" +%s 2>/dev/null || echo "0")
                elapsed=$(( now_e - start_e ))
            fi

            # Hard wall-clock limit — disabled by default (0 = off)
            if [[ "$hard_limit" -gt 0 && "$elapsed" -gt "$hard_limit" ]]; then
                daemon_log WARN "Hard limit exceeded: issue #${issue_num} (${elapsed}s > ${hard_limit}s, PID $pid) — killing"
                emit_event "daemon.hard_limit" "issue=$issue_num" "elapsed_s=$elapsed" "limit_s=$hard_limit" "pid=$pid"
                kill "$pid" 2>/dev/null || true
                daemon_clear_progress "$issue_num"
                findings=$((findings + 1))
                continue
            fi

            # ── Intelligent Progress Sensing ──
            if [[ "$use_progress" == "true" && -n "$worktree" ]]; then
                local snapshot verdict
                snapshot=$(daemon_collect_snapshot "$issue_num" "$worktree" "$pid" 2>/dev/null || echo '{}')

                if [[ "$snapshot" != "{}" ]]; then
                    verdict=$(daemon_assess_progress "$issue_num" "$snapshot" 2>/dev/null || echo "healthy")

                    local no_progress_count=0
                    no_progress_count=$(jq -r '.no_progress_count // 0' "$PROGRESS_DIR/issue-${issue_num}.json" 2>/dev/null || echo 0)
                    local cur_stage
                    cur_stage=$(echo "$snapshot" | jq -r '.stage // "unknown"')

                    case "$verdict" in
                        healthy)
                            # All good — agent is making progress
                            ;;
                        slowing)
                            daemon_log INFO "Issue #${issue_num} slowing (no visible changes for ${no_progress_count} checks, ${elapsed}s elapsed, stage=${cur_stage})"
                            ;;
                        stalled)
                            # Check if agent subprocess is alive and consuming CPU
                            local agent_alive=false
                            local child_cpu=0
                            child_cpu=$(pgrep -P "$pid" 2>/dev/null | xargs -I{} ps -o pcpu= -p {} 2>/dev/null | awk '{sum+=$1} END{printf "%d", sum+0}' || echo "0")
                            if [[ "${child_cpu:-0}" -gt 0 ]]; then
                                agent_alive=true
                            fi

                            if [[ "$agent_alive" == "true" ]]; then
                                daemon_log INFO "Issue #${issue_num} no visible progress (${no_progress_count} checks) but agent is alive (CPU: ${child_cpu}%, stage=${cur_stage}, ${elapsed}s) — being patient"
                            else
                                daemon_log WARN "Issue #${issue_num} stalled: no progress for ${no_progress_count} checks, no CPU activity (${elapsed}s elapsed, PID $pid)"
                                emit_event "daemon.stalled" "issue=$issue_num" "no_progress=$no_progress_count" "elapsed_s=$elapsed" "pid=$pid"
                            fi
                            ;;
                        stuck)
                            local repeated_errors
                            repeated_errors=$(jq -r '.repeated_error_count // 0' "$PROGRESS_DIR/issue-${issue_num}.json" 2>/dev/null || echo 0)

                            # Even "stuck" — check if the process tree is alive first
                            local agent_alive=false
                            local child_cpu=0
                            child_cpu=$(pgrep -P "$pid" 2>/dev/null | xargs -I{} ps -o pcpu= -p {} 2>/dev/null | awk '{sum+=$1} END{printf "%d", sum+0}' || echo "0")
                            if [[ "${child_cpu:-0}" -gt 0 ]]; then
                                agent_alive=true
                            fi

                            if [[ "$agent_alive" == "true" && "$repeated_errors" -lt 3 ]]; then
                                # Agent is alive — nudge instead of kill
                                if [[ "$nudge_enabled" == "true" && "$no_progress_count" -ge "$nudge_after" ]]; then
                                    local nudge_file="${worktree}/.claude/nudge.md"
                                    if [[ ! -f "$nudge_file" ]]; then
                                        cat > "$nudge_file" <<NUDGE_EOF
# Nudge from Daemon Health Monitor

The daemon has noticed no visible progress for $(( no_progress_count * 30 / 60 )) minutes.
Current stage: ${cur_stage}

If you're stuck, consider:
- Breaking the task into smaller steps
- Committing partial progress
- Running tests to validate current state

This is just a gentle check-in — take your time if you're working through a complex problem.
NUDGE_EOF
                                        daemon_log INFO "Issue #${issue_num} nudged (${no_progress_count} checks, stage=${cur_stage}, CPU=${child_cpu}%) — file written to worktree"
                                        emit_event "daemon.nudge" "issue=$issue_num" "no_progress=$no_progress_count" "stage=$cur_stage" "elapsed_s=$elapsed"
                                    fi
                                else
                                    daemon_log INFO "Issue #${issue_num} no visible progress (${no_progress_count} checks) but agent is alive (CPU: ${child_cpu}%, stage=${cur_stage}) — waiting"
                                fi
                            elif [[ "$repeated_errors" -ge 5 ]]; then
                                # Truly stuck in an error loop — kill as last resort
                                daemon_log WARN "Issue #${issue_num} in error loop: ${repeated_errors} repeated errors (stage=${cur_stage}, ${elapsed}s, PID $pid) — killing"
                                emit_event "daemon.stuck_kill" "issue=$issue_num" "no_progress=$no_progress_count" "repeated_errors=$repeated_errors" "stage=$cur_stage" "elapsed_s=$elapsed" "pid=$pid" "reason=error_loop"
                                kill "$pid" 2>/dev/null || true
                                daemon_clear_progress "$issue_num"
                                findings=$((findings + 1))
                            elif [[ "$agent_alive" != "true" && "$no_progress_count" -ge "$((PROGRESS_CHECKS_BEFORE_KILL * 2))" ]]; then
                                # Process tree is dead AND no progress for very long time
                                daemon_log WARN "Issue #${issue_num} appears dead: no CPU, no progress for ${no_progress_count} checks (${elapsed}s, PID $pid) — killing"
                                emit_event "daemon.stuck_kill" "issue=$issue_num" "no_progress=$no_progress_count" "repeated_errors=$repeated_errors" "stage=$cur_stage" "elapsed_s=$elapsed" "pid=$pid" "reason=dead_process"
                                kill "$pid" 2>/dev/null || true
                                daemon_clear_progress "$issue_num"
                                findings=$((findings + 1))
                            else
                                daemon_log WARN "Issue #${issue_num} struggling (${no_progress_count} checks, ${repeated_errors} errors, CPU=${child_cpu}%, stage=${cur_stage}) — monitoring"
                            fi
                            ;;
                    esac
                fi
            else
                # Fallback: legacy time-based detection when progress monitoring is off
                local stale_timeout
                stale_timeout=$(get_adaptive_stale_timeout "$PIPELINE_TEMPLATE")
                if [[ "$elapsed" -gt "$stale_timeout" ]]; then
                    # Check if process is still alive
                    if kill -0 "$pid" 2>/dev/null; then
                        # Kill at 2x stale timeout — the process is truly hung
                        local kill_threshold=$(( stale_timeout * 2 ))
                        if [[ "$elapsed" -gt "$kill_threshold" ]]; then
                            daemon_log WARN "Killing stale job (legacy): issue #${issue_num} (${elapsed}s > ${kill_threshold}s kill threshold, PID $pid)"
                            emit_event "daemon.stale_kill" "issue=$issue_num" "elapsed_s=$elapsed" "pid=$pid"
                            kill "$pid" 2>/dev/null || true
                            sleep 2
                            kill -9 "$pid" 2>/dev/null || true
                        else
                            daemon_log WARN "Stale job (legacy): issue #${issue_num} (${elapsed}s > ${stale_timeout}s, PID $pid) — will kill at ${kill_threshold}s"
                            emit_event "daemon.stale_warning" "issue=$issue_num" "elapsed_s=$elapsed" "pid=$pid"
                        fi
                    else
                        daemon_log WARN "Stale job with dead process: issue #${issue_num} (PID $pid no longer exists)"
                        emit_event "daemon.stale_dead" "issue=$issue_num" "pid=$pid"
                    fi
                    findings=$((findings + 1))
                fi
            fi
        done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)
    fi

    # Disk space warning (check both repo dir and ~/.shipwright)
    local free_kb
    free_kb=$(df -k "." 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_kb" ]] && [[ "$free_kb" -lt 1048576 ]] 2>/dev/null; then
        daemon_log WARN "Low disk space: $(( free_kb / 1024 ))MB free"
        findings=$((findings + 1))
    fi

    # Critical disk space on ~/.shipwright — pause spawning
    local sw_free_kb
    sw_free_kb=$(df -k "$HOME/.shipwright" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$sw_free_kb" ]] && [[ "$sw_free_kb" -lt 512000 ]] 2>/dev/null; then
        daemon_log WARN "Critical disk space on ~/.shipwright: $(( sw_free_kb / 1024 ))MB — pausing spawns"
        emit_event "daemon.disk_low" "free_mb=$(( sw_free_kb / 1024 ))"
        mkdir -p "$HOME/.shipwright"
        echo '{"paused":true,"reason":"disk_low"}' > "$HOME/.shipwright/daemon-pause.flag"
        findings=$((findings + 1))
    fi

    # Events file size warning
    if [[ -f "$EVENTS_FILE" ]]; then
        local events_size
        events_size=$(wc -c < "$EVENTS_FILE" 2>/dev/null || echo 0)
        if [[ "$events_size" -gt 104857600 ]]; then  # 100MB
            daemon_log WARN "Events file large ($(( events_size / 1048576 ))MB) — consider rotating"
            findings=$((findings + 1))
        fi
    fi

    if [[ "$findings" -gt 0 ]]; then
        emit_event "daemon.health" "findings=$findings"
    fi
}

# ─── Degradation Alerting ─────────────────────────────────────────────────────

daemon_check_degradation() {
    if [[ ! -f "$EVENTS_FILE" ]]; then return; fi

    local window="${DEGRADATION_WINDOW:-5}"
    local cfr_threshold="${DEGRADATION_CFR_THRESHOLD:-30}"
    local success_threshold="${DEGRADATION_SUCCESS_THRESHOLD:-50}"

    # Get last N pipeline completions
    local recent
    recent=$(tail -200 "$EVENTS_FILE" | jq -s "[.[] | select(.type == \"pipeline.completed\")] | .[-${window}:]" 2>/dev/null)
    local count
    count=$(echo "$recent" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$count" -lt "$window" ]]; then return; fi

    local failures successes
    failures=$(echo "$recent" | jq '[.[] | select(.result == "failure")] | length')
    successes=$(echo "$recent" | jq '[.[] | select(.result == "success")] | length')
    local cfr_pct=0 success_pct=0
    if [[ "${count:-0}" -gt 0 ]]; then
        cfr_pct=$(( failures * 100 / count ))
        success_pct=$(( successes * 100 / count ))
    fi

    local alerts=""
    if [[ "$cfr_pct" -gt "$cfr_threshold" ]]; then
        alerts="CFR ${cfr_pct}% exceeds threshold ${cfr_threshold}%"
        daemon_log WARN "DEGRADATION: $alerts"
    fi
    if [[ "$success_pct" -lt "$success_threshold" ]]; then
        local msg="Success rate ${success_pct}% below threshold ${success_threshold}%"
        [[ -n "$alerts" ]] && alerts="$alerts; $msg" || alerts="$msg"
        daemon_log WARN "DEGRADATION: $msg"
    fi

    if [[ -n "$alerts" ]]; then
        emit_event "daemon.alert" "alerts=$alerts" "cfr_pct=$cfr_pct" "success_pct=$success_pct"

        # Slack notification
        if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
            notify "Pipeline Degradation Alert" "$alerts" "warn"
        fi
    fi
}

# ─── Auto-Scaling ─────────────────────────────────────────────────────────
# Dynamically adjusts MAX_PARALLEL based on CPU, memory, budget, and queue depth

daemon_auto_scale() {
    if [[ "${AUTO_SCALE:-false}" != "true" ]]; then
        return
    fi

    local prev_max="$MAX_PARALLEL"

    # ── Learn worker memory from actual RSS (adaptive) ──
    learn_worker_memory

    # ── Adaptive cost estimate per template ──
    local effective_cost_per_job
    effective_cost_per_job=$(get_adaptive_cost_estimate "$PIPELINE_TEMPLATE")

    # ── CPU cores ──
    local cpu_cores=2
    if [[ "$(uname -s)" == "Darwin" ]]; then
        cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
    else
        cpu_cores=$(nproc 2>/dev/null || echo 2)
    fi
    local max_by_cpu=$(( (cpu_cores * 3) / 4 ))  # 75% utilization cap
    [[ "$max_by_cpu" -lt 1 ]] && max_by_cpu=1

    # ── Load average check — gradual scaling curve (replaces 90% cliff) ──
    local load_avg
    load_avg=$(uptime | awk -F'load averages?: ' '{print $2}' | awk -F'[, ]+' '{print $1}' 2>/dev/null || echo "0")
    if [[ ! "$load_avg" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        load_avg="0"
    fi
    local load_ratio=0
    if [[ "$cpu_cores" -gt 0 ]]; then
        load_ratio=$(awk -v load="$load_avg" -v cores="$cpu_cores" 'BEGIN { printf "%.0f", (load / cores) * 100 }')
    fi
    # Gradual load scaling curve (replaces binary 90% cliff)
    if [[ "$load_ratio" -gt 95 ]]; then
        # 95%+: minimum workers only
        max_by_cpu="$MIN_WORKERS"
        daemon_log WARN "Auto-scale: critical load (${load_ratio}%) — minimum workers only"
    elif [[ "$load_ratio" -gt 85 ]]; then
        # 85-95%: reduce by 50%
        max_by_cpu=$(( max_by_cpu / 2 ))
        [[ "$max_by_cpu" -lt "$MIN_WORKERS" ]] && max_by_cpu="$MIN_WORKERS"
        daemon_log WARN "Auto-scale: high load (${load_ratio}%) — reducing capacity 50%"
    elif [[ "$load_ratio" -gt 70 ]]; then
        # 70-85%: reduce by 25%
        max_by_cpu=$(( (max_by_cpu * 3) / 4 ))
        [[ "$max_by_cpu" -lt "$MIN_WORKERS" ]] && max_by_cpu="$MIN_WORKERS"
        daemon_log INFO "Auto-scale: moderate load (${load_ratio}%) — reducing capacity 25%"
    fi
    # 0-70%: full capacity (no change)

    # ── Available memory ──
    local avail_mem_gb=8
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local page_size free_pages inactive_pages purgeable_pages speculative_pages
        page_size=$(vm_stat | awk '/page size of/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) print $i}')
        page_size="${page_size:-16384}"
        free_pages=$(vm_stat | awk '/^Pages free:/ {gsub(/\./, "", $NF); print $NF}')
        free_pages="${free_pages:-0}"
        speculative_pages=$(vm_stat | awk '/^Pages speculative:/ {gsub(/\./, "", $NF); print $NF}')
        speculative_pages="${speculative_pages:-0}"
        inactive_pages=$(vm_stat | awk '/^Pages inactive:/ {gsub(/\./, "", $NF); print $NF}')
        inactive_pages="${inactive_pages:-0}"
        purgeable_pages=$(vm_stat | awk '/^Pages purgeable:/ {gsub(/\./, "", $NF); print $NF}')
        purgeable_pages="${purgeable_pages:-0}"
        local avail_pages=$(( free_pages + speculative_pages + inactive_pages + purgeable_pages ))
        if [[ "$avail_pages" -gt 0 && "$page_size" -gt 0 ]]; then
            local free_bytes=$(( avail_pages * page_size ))
            avail_mem_gb=$(( free_bytes / 1073741824 ))
        fi
    else
        local avail_kb
        avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "8388608")
        avail_mem_gb=$(( avail_kb / 1048576 ))
    fi
    [[ "$avail_mem_gb" -lt 1 ]] && avail_mem_gb=1
    local max_by_mem=$(( avail_mem_gb / WORKER_MEM_GB ))
    [[ "$max_by_mem" -lt 1 ]] && max_by_mem=1

    # ── Budget remaining (adaptive cost estimate) ──
    local max_by_budget="$MAX_WORKERS"
    local remaining_usd
    remaining_usd=$("$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "unlimited")
    if [[ "$remaining_usd" != "unlimited" && -n "$remaining_usd" ]]; then
        if awk -v r="$remaining_usd" -v c="$effective_cost_per_job" 'BEGIN { exit !(r > 0 && c > 0) }'; then
            max_by_budget=$(awk -v r="$remaining_usd" -v c="$effective_cost_per_job" 'BEGIN { printf "%.0f", r / c }')
            [[ "$max_by_budget" -lt 0 ]] && max_by_budget=0
        else
            max_by_budget=0
        fi
    fi

    # ── Queue depth (don't over-provision) ──
    local queue_depth active_count
    queue_depth=$(jq -r '.queued | length' "$STATE_FILE" 2>/dev/null || echo 0)
    queue_depth="${queue_depth:-0}"
    [[ ! "$queue_depth" =~ ^[0-9]+$ ]] && queue_depth=0
    active_count=$(get_active_count)
    active_count="${active_count:-0}"
    [[ ! "$active_count" =~ ^[0-9]+$ ]] && active_count=0
    local max_by_queue=$(( queue_depth + active_count ))
    [[ "$max_by_queue" -lt 1 ]] && max_by_queue=1

    # ── Vitals-driven scaling factor ──
    local max_by_vitals="$MAX_WORKERS"
    if type pipeline_compute_vitals >/dev/null 2>&1 && [[ -f "$STATE_FILE" ]]; then
        local _total_health=0 _health_count=0
        while IFS= read -r _job; do
            local _job_issue _job_worktree
            _job_issue=$(echo "$_job" | jq -r '.issue // 0')
            _job_worktree=$(echo "$_job" | jq -r '.worktree // ""')
            if [[ -n "$_job_worktree" && -d "$_job_worktree/.claude" ]]; then
                local _job_vitals _job_health
                _job_vitals=$(pipeline_compute_vitals "$_job_worktree/.claude/pipeline-state.md" "$_job_worktree/.claude/pipeline-artifacts" "$_job_issue" 2>/dev/null) || true
                if [[ -n "$_job_vitals" && "$_job_vitals" != "{}" ]]; then
                    _job_health=$(echo "$_job_vitals" | jq -r '.health_score // 50' 2>/dev/null || echo "50")
                    _total_health=$((_total_health + _job_health))
                    _health_count=$((_health_count + 1))
                fi
            fi
        done < <(jq -c '.active_jobs[]' "$STATE_FILE" 2>/dev/null || true)

        if [[ "$_health_count" -gt 0 ]]; then
            local _avg_health=$((_total_health / _health_count))
            if [[ "$_avg_health" -lt 50 ]]; then
                # Pipelines struggling — reduce workers to give each more resources
                max_by_vitals=$(( MAX_WORKERS * _avg_health / 100 ))
                [[ "$max_by_vitals" -lt "$MIN_WORKERS" ]] && max_by_vitals="$MIN_WORKERS"
                daemon_log INFO "Auto-scale: vitals avg health ${_avg_health}% — capping at ${max_by_vitals} workers"
            fi
            # avg_health > 70: no reduction (full capacity available)
        fi
    fi

    # ── Compute final value ──
    local computed="$max_by_cpu"
    [[ "$max_by_mem" -lt "$computed" ]] && computed="$max_by_mem"
    [[ "$max_by_budget" -lt "$computed" ]] && computed="$max_by_budget"
    [[ "$max_by_queue" -lt "$computed" ]] && computed="$max_by_queue"
    [[ "$max_by_vitals" -lt "$computed" ]] && computed="$max_by_vitals"
    [[ "$MAX_WORKERS" -lt "$computed" ]] && computed="$MAX_WORKERS"

    # Respect fleet-assigned ceiling if set
    if [[ -n "${FLEET_MAX_PARALLEL:-}" && "$FLEET_MAX_PARALLEL" -lt "$computed" ]]; then
        computed="$FLEET_MAX_PARALLEL"
    fi

    # Clamp to min_workers
    [[ "$computed" -lt "$MIN_WORKERS" ]] && computed="$MIN_WORKERS"

    # ── Gradual scaling: change by at most 1 at a time (adaptive) ──
    if [[ "${ADAPTIVE_THRESHOLDS_ENABLED:-false}" == "true" ]]; then
        if [[ "$computed" -gt "$prev_max" ]]; then
            # Check success rate at target parallelism before scaling up
            local target_rate
            target_rate=$(get_success_rate_at_parallelism "$((prev_max + 1))")
            if [[ "$target_rate" -lt 50 ]]; then
                # Poor success rate at higher parallelism — hold steady
                computed="$prev_max"
                daemon_log INFO "Auto-scale: holding at ${prev_max} (success rate ${target_rate}% at $((prev_max + 1)))"
            else
                # Scale up by 1, not jump to target
                computed=$((prev_max + 1))
            fi
        elif [[ "$computed" -lt "$prev_max" ]]; then
            # Scale down by 1, not drop to minimum
            computed=$((prev_max - 1))
            [[ "$computed" -lt "$MIN_WORKERS" ]] && computed="$MIN_WORKERS"
        fi
    fi

    MAX_PARALLEL="$computed"

    if [[ "$MAX_PARALLEL" -ne "$prev_max" ]]; then
        daemon_log INFO "Auto-scale: ${prev_max} → ${MAX_PARALLEL} (cpu=${max_by_cpu} mem=${max_by_mem} budget=${max_by_budget} queue=${max_by_queue} load=${load_ratio}%)"
        emit_event "daemon.scale" \
            "from=$prev_max" \
            "to=$MAX_PARALLEL" \
            "max_by_cpu=$max_by_cpu" \
            "max_by_mem=$max_by_mem" \
            "max_by_budget=$max_by_budget" \
            "max_by_queue=$max_by_queue" \
            "cpu_cores=$cpu_cores" \
            "avail_mem_gb=$avail_mem_gb" \
            "remaining_usd=$remaining_usd" \
            "load_ratio=$load_ratio"
    fi
}

# ─── Fleet Config Reload ──────────────────────────────────────────────────
# Checks for fleet-reload.flag and reloads MAX_PARALLEL from fleet-managed config

daemon_reload_config() {
    local reload_flag="$HOME/.shipwright/fleet-reload.flag"
    if [[ ! -f "$reload_flag" ]]; then
        return
    fi

    local fleet_config=".claude/.fleet-daemon-config.json"
    if [[ -f "$fleet_config" ]]; then
        local new_max
        new_max=$(jq -r '.max_parallel // empty' "$fleet_config" 2>/dev/null || true)
        if [[ -n "$new_max" && "$new_max" != "null" ]]; then
            local prev="$MAX_PARALLEL"
            FLEET_MAX_PARALLEL="$new_max"
            MAX_PARALLEL="$new_max"
            daemon_log INFO "Fleet reload: max_parallel ${prev} → ${MAX_PARALLEL} (fleet ceiling: ${FLEET_MAX_PARALLEL})"
            emit_event "daemon.fleet_reload" "from=$prev" "to=$MAX_PARALLEL"
        fi
    fi

    rm -f "$reload_flag"
}

# ─── Self-Optimizing Metrics Loop ──────────────────────────────────────────

daemon_self_optimize() {
    if [[ "${SELF_OPTIMIZE:-false}" != "true" ]]; then
        return
    fi

    if [[ ! -f "$EVENTS_FILE" ]]; then
        return
    fi

    # ── Intelligence-powered optimization (if enabled) ──
    if [[ "${OPTIMIZATION_ENABLED:-false}" == "true" ]] && type optimize_full_analysis >/dev/null 2>&1; then
        daemon_log INFO "Running intelligence-powered optimization"
        optimize_full_analysis 2>/dev/null || {
            daemon_log WARN "Intelligence optimization failed — falling back to DORA-based tuning"
        }
        # Still run DORA-based tuning below as a complement
    fi

    daemon_log INFO "Running self-optimization check"

    # Read DORA metrics from recent events (last 7 days)
    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (7 * 86400) ))

    local period_events
    period_events=$(jq -c "select(.ts_epoch >= $cutoff_epoch)" "$EVENTS_FILE" 2>/dev/null || true)

    if [[ -z "$period_events" ]]; then
        daemon_log INFO "No recent events for optimization"
        return
    fi

    local total_completed successes failures
    total_completed=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed")] | length')
    successes=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success")] | length')
    failures=$(echo "$period_events" | jq -s '[.[] | select(.type == "pipeline.completed" and .result == "failure")] | length')

    # Change Failure Rate
    local cfr=0
    if [[ "$total_completed" -gt 0 ]]; then
        cfr=$(echo "$failures $total_completed" | awk '{printf "%.0f", ($1 / $2) * 100}')
    fi

    # Cycle time (median, in seconds)
    local cycle_time_median
    cycle_time_median=$(echo "$period_events" | \
        jq -s '[.[] | select(.type == "pipeline.completed" and .result == "success") | .duration_s // 0] | sort | if length > 0 then .[length/2 | floor] else 0 end')

    # Deploy frequency (per week)
    local deploy_freq
    deploy_freq=$(echo "$successes" | awk '{printf "%.1f", $1 / 1}')  # Already 7 days

    # MTTR
    local mttr
    mttr=$(echo "$period_events" | \
        jq -s '
            [.[] | select(.type == "pipeline.completed")] | sort_by(.ts_epoch // 0) |
            [range(length) as $i |
                if .[$i].result == "failure" then
                    [.[$i+1:][] | select(.result == "success")][0] as $next |
                    if $next and $next.ts_epoch and .[$i].ts_epoch then
                        ($next.ts_epoch - .[$i].ts_epoch)
                    else null end
                else null end
            ] | map(select(. != null)) |
            if length > 0 then (add / length | floor) else 0 end
        ')

    local adjustments=()

    # ── CFR > 20%: enable compound_quality, increase max_cycles ──
    if [[ "$cfr" -gt 40 ]]; then
        PIPELINE_TEMPLATE="full"
        adjustments+=("template→full (CFR ${cfr}% > 40%)")
        daemon_log WARN "Self-optimize: CFR ${cfr}% critical — switching to full template"
    elif [[ "$cfr" -gt 20 ]]; then
        adjustments+=("compound_quality enabled (CFR ${cfr}% > 20%)")
        daemon_log WARN "Self-optimize: CFR ${cfr}% elevated — enabling compound quality"
    fi

    # ── Lead time > 4hrs: increase max_parallel, reduce poll_interval ──
    if [[ "$cycle_time_median" -gt 14400 ]]; then
        MAX_PARALLEL=$((MAX_PARALLEL + 1))
        if [[ "$POLL_INTERVAL" -gt 30 ]]; then
            POLL_INTERVAL=$((POLL_INTERVAL / 2))
        fi
        adjustments+=("max_parallel→${MAX_PARALLEL}, poll_interval→${POLL_INTERVAL}s (lead time > 4hrs)")
        daemon_log WARN "Self-optimize: lead time $(format_duration "$cycle_time_median") — increasing parallelism"
    elif [[ "$cycle_time_median" -gt 7200 ]]; then
        # ── Lead time > 2hrs: enable auto_template for fast-pathing ──
        AUTO_TEMPLATE="true"
        adjustments+=("auto_template enabled (lead time > 2hrs)")
        daemon_log INFO "Self-optimize: lead time $(format_duration "$cycle_time_median") — enabling adaptive templates"
    fi

    # ── Deploy freq < 1/day (< 7/week): enable merge stage ──
    if [[ "$(echo "$deploy_freq < 7" | bc -l 2>/dev/null || echo 0)" == "1" ]]; then
        adjustments+=("merge stage recommended (deploy freq ${deploy_freq}/week)")
        daemon_log INFO "Self-optimize: low deploy frequency — consider enabling merge stage"
    fi

    # ── MTTR > 2hrs: enable auto_rollback ──
    if [[ "$mttr" -gt 7200 ]]; then
        adjustments+=("auto_rollback recommended (MTTR $(format_duration "$mttr"))")
        daemon_log WARN "Self-optimize: high MTTR $(format_duration "$mttr") — consider enabling auto-rollback"
    fi

    # Write adjustments to state and persist to config
    if [[ ${#adjustments[@]} -gt 0 ]]; then
        local adj_str
        adj_str=$(printf '%s; ' "${adjustments[@]}")

        locked_state_update \
            --arg adj "$adj_str" \
            --arg ts "$(now_iso)" \
            '.last_optimization = {timestamp: $ts, adjustments: $adj}'

        # ── Persist adjustments to daemon-config.json (survives restart) ──
        local config_file="${CONFIG_PATH:-.claude/daemon-config.json}"
        if [[ -f "$config_file" ]]; then
            local tmp_config
            tmp_config=$(jq \
                --argjson max_parallel "$MAX_PARALLEL" \
                --argjson poll_interval "$POLL_INTERVAL" \
                --arg template "$PIPELINE_TEMPLATE" \
                --arg auto_template "${AUTO_TEMPLATE:-false}" \
                --arg ts "$(now_iso)" \
                --arg adj "$adj_str" \
                '.max_parallel = $max_parallel |
                 .poll_interval = $poll_interval |
                 .pipeline_template = $template |
                 .auto_template = ($auto_template == "true") |
                 .last_optimization = {timestamp: $ts, adjustments: $adj}' \
                "$config_file")
            # Atomic write: tmp file + mv
            local tmp_cfg_file="${config_file}.tmp.$$"
            echo "$tmp_config" > "$tmp_cfg_file"
            mv "$tmp_cfg_file" "$config_file"
            daemon_log INFO "Self-optimize: persisted adjustments to ${config_file}"
        fi

        emit_event "daemon.optimize" "adjustments=${adj_str}" "cfr=$cfr" "cycle_time=$cycle_time_median" "deploy_freq=$deploy_freq" "mttr=$mttr"
        daemon_log SUCCESS "Self-optimization applied ${#adjustments[@]} adjustment(s)"
    else
        daemon_log INFO "Self-optimization: all metrics within thresholds"
    fi
}

# ─── Stale State Reaper ──────────────────────────────────────────────────────
# Cleans old worktrees, pipeline artifacts, and completed state entries.
# Called every N poll cycles (configurable via stale_reaper_interval).

daemon_cleanup_stale() {
    if [[ "${STALE_REAPER_ENABLED:-true}" != "true" ]]; then
        return
    fi

    daemon_log INFO "Running stale state reaper"
    local cleaned=0
    local age_days="${STALE_REAPER_AGE_DAYS:-7}"
    local age_secs=$((age_days * 86400))
    local now_e
    now_e=$(now_epoch)

    # ── 1. Clean old git worktrees ──
    if command -v git >/dev/null 2>&1; then
        while IFS= read -r line; do
            local wt_path
            wt_path=$(echo "$line" | awk '{print $1}')
            # Only clean daemon-created worktrees
            [[ "$wt_path" == *"daemon-issue-"* ]] || continue
            # Check worktree age via directory mtime
            local mtime
            mtime=$(file_mtime "$wt_path")
            if [[ $((now_e - mtime)) -gt $age_secs ]]; then
                daemon_log INFO "Removing stale worktree: ${wt_path}"
                git worktree remove "$wt_path" --force 2>/dev/null || true
                cleaned=$((cleaned + 1))
            fi
        done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //')
    fi

    # ── 2. Expire old checkpoints ──
    if [[ -x "$SCRIPT_DIR/sw-checkpoint.sh" ]]; then
        local expired_output
        expired_output=$(bash "$SCRIPT_DIR/sw-checkpoint.sh" expire --hours "$((age_days * 24))" 2>/dev/null || true)
        if [[ -n "$expired_output" ]] && echo "$expired_output" | grep -q "Expired"; then
            local expired_count
            expired_count=$(echo "$expired_output" | grep -c "Expired" || true)
            cleaned=$((cleaned + ${expired_count:-0}))
            daemon_log INFO "Expired ${expired_count:-0} old checkpoint(s)"
        fi
    fi

    # ── 3. Clean old pipeline artifacts (subdirectories only) ──
    local artifacts_dir=".claude/pipeline-artifacts"
    if [[ -d "$artifacts_dir" ]]; then
        while IFS= read -r artifact_dir; do
            [[ -d "$artifact_dir" ]] || continue
            local mtime
            mtime=$(file_mtime "$artifact_dir")
            if [[ $((now_e - mtime)) -gt $age_secs ]]; then
                daemon_log INFO "Removing stale artifact: ${artifact_dir}"
                rm -rf "$artifact_dir"
                cleaned=$((cleaned + 1))
            fi
        done < <(find "$artifacts_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi

    # ── 3. Clean orphaned daemon/* branches (no matching worktree or active job) ──
    if command -v git >/dev/null 2>&1; then
        while IFS= read -r branch; do
            [[ -z "$branch" ]] && continue
            branch="${branch## }"  # trim leading spaces
            # Only clean daemon-created branches
            [[ "$branch" == daemon/issue-* ]] || continue
            # Extract issue number
            local branch_issue_num="${branch#daemon/issue-}"
            # Skip if there's an active job for this issue
            if daemon_is_inflight "$branch_issue_num" 2>/dev/null; then
                continue
            fi
            daemon_log INFO "Removing orphaned branch: ${branch}"
            git branch -D "$branch" 2>/dev/null || true
            cleaned=$((cleaned + 1))
        done < <(git branch --list 'daemon/issue-*' 2>/dev/null)
    fi

    # ── 4. Prune completed/failed state entries older than age_days ──
    if [[ -f "$STATE_FILE" ]]; then
        local cutoff_iso
        cutoff_iso=$(epoch_to_iso $((now_e - age_secs)))
        local before_count
        before_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo 0)
        locked_state_update --arg cutoff "$cutoff_iso" \
            '.completed = [.completed[] | select(.completed_at > $cutoff)]' 2>/dev/null || true
        local after_count
        after_count=$(jq '.completed | length' "$STATE_FILE" 2>/dev/null || echo 0)
        local pruned=$((before_count - after_count))
        if [[ "$pruned" -gt 0 ]]; then
            daemon_log INFO "Pruned ${pruned} old completed state entries"
            cleaned=$((cleaned + pruned))
        fi
    fi

    # ── 5. Prune stale retry_counts (issues no longer in flight or queued) ──
    if [[ -f "$STATE_FILE" ]]; then
        local retry_keys
        retry_keys=$(jq -r '.retry_counts // {} | keys[]' "$STATE_FILE" 2>/dev/null || true)
        local stale_keys=()
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            if ! daemon_is_inflight "$key" 2>/dev/null; then
                stale_keys+=("$key")
            fi
        done <<< "$retry_keys"
        if [[ ${#stale_keys[@]} -gt 0 ]]; then
            for sk in "${stale_keys[@]}"; do
                locked_state_update --arg k "$sk" 'del(.retry_counts[$k])' 2>/dev/null || continue
            done
            daemon_log INFO "Pruned ${#stale_keys[@]} stale retry count(s)"
            cleaned=$((cleaned + ${#stale_keys[@]}))
        fi
    fi

    # ── 6. Detect stale pipeline-state.md stuck in "running" ──
    local pipeline_state=".claude/pipeline-state.md"
    if [[ -f "$pipeline_state" ]]; then
        local ps_status=""
        ps_status=$(sed -n 's/^status: *//p' "$pipeline_state" 2>/dev/null | head -1 | tr -d ' ')
        if [[ "$ps_status" == "running" ]]; then
            local ps_mtime
            ps_mtime=$(file_mtime "$pipeline_state")
            local ps_age=$((now_e - ps_mtime))
            # If pipeline-state.md has been "running" for more than 2 hours and no active job
            if [[ "$ps_age" -gt 7200 ]]; then
                local has_active=false
                if [[ -f "$STATE_FILE" ]]; then
                    local active_count
                    active_count=$(jq '.active_jobs | length' "$STATE_FILE" 2>/dev/null || echo "0")
                    [[ "${active_count:-0}" -gt 0 ]] && has_active=true
                fi
                if [[ "$has_active" == "false" ]]; then
                    daemon_log WARN "Stale pipeline-state.md stuck in 'running' for ${ps_age}s with no active jobs — marking failed"
                    # Atomically update status to failed
                    local tmp_ps="${pipeline_state}.tmp.$$"
                    sed 's/^status: *running/status: failed (stale — cleaned by daemon)/' "$pipeline_state" > "$tmp_ps" 2>/dev/null && mv "$tmp_ps" "$pipeline_state" || rm -f "$tmp_ps"
                    emit_event "daemon.stale_pipeline_state" "age_s=$ps_age"
                    cleaned=$((cleaned + 1))
                fi
            fi
        fi
    fi

    # ── 7. Clean remote branches for merged pipeline/* branches ──
    if command -v git >/dev/null 2>&1 && [[ "${NO_GITHUB:-}" != "true" ]]; then
        while IFS= read -r branch; do
            [[ -z "$branch" ]] && continue
            branch="${branch## }"
            [[ "$branch" == pipeline/* ]] || continue
            local br_issue="${branch#pipeline/pipeline-issue-}"
            if ! daemon_is_inflight "$br_issue" 2>/dev/null; then
                daemon_log INFO "Removing orphaned pipeline branch: ${branch}"
                git branch -D "$branch" 2>/dev/null || true
                git push origin --delete "$branch" 2>/dev/null || true
                cleaned=$((cleaned + 1))
            fi
        done < <(git branch --list 'pipeline/*' 2>/dev/null)
    fi

    if [[ "$cleaned" -gt 0 ]]; then
        emit_event "daemon.cleanup" "cleaned=$cleaned" "age_days=$age_days"
        daemon_log SUCCESS "Stale reaper cleaned ${cleaned} item(s)"
    else
        daemon_log INFO "Stale reaper: nothing to clean"
    fi
}

# ─── Poll Loop ───────────────────────────────────────────────────────────────

POLL_CYCLE_COUNT=0

daemon_poll_loop() {
    daemon_log INFO "Entering poll loop (interval: ${POLL_INTERVAL}s, max_parallel: ${MAX_PARALLEL})"
    daemon_log INFO "Watching for label: ${CYAN}${WATCH_LABEL}${RESET}"

    while [[ ! -f "$SHUTDOWN_FLAG" ]]; do
        # All poll loop calls are error-guarded to prevent set -e from killing the daemon.
        # The || operator disables set -e for the entire call chain, so transient failures
        # (GitHub API timeouts, jq errors, intelligence failures) are logged and skipped.
        daemon_preflight_auth_check || daemon_log WARN "Auth check failed — daemon may be paused"
        daemon_poll_issues || daemon_log WARN "daemon_poll_issues failed — continuing"
        daemon_reap_completed || daemon_log WARN "daemon_reap_completed failed — continuing"
        daemon_health_check || daemon_log WARN "daemon_health_check failed — continuing"

        # Fleet failover: re-queue work from offline machines
        if [[ -f "$HOME/.shipwright/machines.json" ]]; then
            [[ -f "$SCRIPT_DIR/lib/fleet-failover.sh" ]] && source "$SCRIPT_DIR/lib/fleet-failover.sh" 2>/dev/null || true
            fleet_failover_check 2>/dev/null || true
        fi

        # Increment cycle counter (must be before all modulo checks)
        POLL_CYCLE_COUNT=$((POLL_CYCLE_COUNT + 1))

        # Fleet config reload every 3 cycles
        if [[ $((POLL_CYCLE_COUNT % 3)) -eq 0 ]]; then
            daemon_reload_config || daemon_log WARN "daemon_reload_config failed — continuing"
        fi

        # Check degradation every 5 poll cycles
        if [[ $((POLL_CYCLE_COUNT % 5)) -eq 0 ]]; then
            daemon_check_degradation || daemon_log WARN "daemon_check_degradation failed — continuing"
        fi

        # Auto-scale every N cycles (default: 5)
        if [[ $((POLL_CYCLE_COUNT % ${AUTO_SCALE_INTERVAL:-5})) -eq 0 ]]; then
            daemon_auto_scale || daemon_log WARN "daemon_auto_scale failed — continuing"
        fi

        # Self-optimize every N cycles (default: 10)
        if [[ $((POLL_CYCLE_COUNT % ${OPTIMIZE_INTERVAL:-10})) -eq 0 ]]; then
            daemon_self_optimize || daemon_log WARN "daemon_self_optimize failed — continuing"
        fi

        # Stale state reaper every N cycles (default: 10)
        if [[ $((POLL_CYCLE_COUNT % ${STALE_REAPER_INTERVAL:-10})) -eq 0 ]]; then
            daemon_cleanup_stale || daemon_log WARN "daemon_cleanup_stale failed — continuing"
        fi

        # Adaptive timeout adjustment every 10 cycles
        if [[ $((POLL_CYCLE_COUNT % 10)) -eq 0 ]]; then
            if type should_adjust_timeouts >/dev/null 2>&1; then
                if should_adjust_timeouts 2>/dev/null; then
                    daemon_log INFO "Triggering adaptive timeout adjustment"
                    trigger_timeout_adjustment 2>/dev/null || daemon_log WARN "timeout adjustment failed — continuing"
                fi
            fi
        fi

        # Rotate event log every 10 cycles (~10 min with 60s interval)
        if [[ $((POLL_CYCLE_COUNT % 10)) -eq 0 ]]; then
            rotate_event_log || true
        fi

        # Proactive patrol during quiet periods (with adaptive limits)
        local issue_count_now active_count_now
        issue_count_now=$(jq -r '.queued | length' "$STATE_FILE" 2>/dev/null || echo 0)
        active_count_now=$(get_active_count || echo 0)
        if [[ "$issue_count_now" -eq 0 ]] && [[ "$active_count_now" -eq 0 ]]; then
            local now_e
            now_e=$(now_epoch || date +%s)
            if [[ $((now_e - LAST_PATROL_EPOCH)) -ge "$PATROL_INTERVAL" ]]; then
                load_adaptive_patrol_limits || true
                daemon_log INFO "No active work — running patrol"
                daemon_patrol --once || daemon_log WARN "daemon_patrol failed — continuing"
                LAST_PATROL_EPOCH=$now_e
            fi

            # Decision engine cycle (if enabled)
            local _decision_enabled
            _decision_enabled=$(policy_get ".decision.enabled" "false" 2>/dev/null || echo "false")
            if [[ "$_decision_enabled" == "true" ]]; then
                local _decision_interval
                _decision_interval=$(policy_get ".decision.cycle_interval_seconds" "1800" 2>/dev/null || echo "1800")
                local _last_decision_epoch="${_LAST_DECISION_EPOCH:-0}"
                if [[ $((now_e - _last_decision_epoch)) -ge "$_decision_interval" ]]; then
                    daemon_log INFO "Running decision engine cycle"
                    if [[ -f "$SCRIPT_DIR/sw-decide.sh" ]]; then
                        DECISION_ENGINE_ENABLED=true bash "$SCRIPT_DIR/sw-decide.sh" run --once 2>/dev/null || \
                            daemon_log WARN "Decision engine cycle failed — continuing"
                    fi
                    _LAST_DECISION_EPOCH=$now_e
                fi
            fi
        fi

        # ── Adaptive poll interval: adjust sleep based on queue state ──
        local effective_interval
        effective_interval=$(get_adaptive_poll_interval "$issue_count_now" "$active_count_now" || echo "${POLL_INTERVAL:-30}")

        # Sleep in 1s intervals so we can catch shutdown quickly
        local i=0
        while [[ $i -lt $effective_interval ]] && [[ ! -f "$SHUTDOWN_FLAG" ]]; do
            sleep 1 || true  # Guard against signal interruption under set -e
            i=$((i + 1))
        done
    done

    daemon_log INFO "Shutdown flag detected — exiting poll loop"
}
