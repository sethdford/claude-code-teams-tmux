# pipeline-stages-build.sh — test_first, build, test stages
# Source from pipeline-stages.sh. Requires all pipeline globals and dependencies.
[[ -n "${_PIPELINE_STAGES_BUILD_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_BUILD_LOADED=1

stage_test_first() {
    CURRENT_STAGE_ID="test_first"
    info "Generating tests from requirements (TDD mode)"

    local plan_file="${ARTIFACTS_DIR}/plan.md"
    local goal_file="${PROJECT_ROOT}/.claude/goal.md"
    local requirements=""
    if [[ -f "$plan_file" ]]; then
        requirements=$(cat "$plan_file" 2>/dev/null || true)
    elif [[ -f "$goal_file" ]]; then
        requirements=$(cat "$goal_file" 2>/dev/null || true)
    else
        requirements="${GOAL:-}: ${ISSUE_BODY:-}"
    fi

    local tdd_prompt="You are writing tests BEFORE implementation (TDD).

Based on the following plan/requirements, generate test files that define the expected behavior. These tests should FAIL initially (since the implementation doesn't exist yet) but define the correct interface and behavior.

Requirements:
${requirements}

Instructions:
1. Create test files for each component mentioned in the plan
2. Tests should verify the PUBLIC interface and expected behavior
3. Include edge cases and error handling tests
4. Tests should be runnable with the project's test framework
5. Mark tests that need implementation with clear TODO comments
6. Do NOT write implementation code — only tests

Output format: For each test file, use a fenced code block with the file path as the language identifier (e.g. \`\`\`tests/auth.test.ts):
\`\`\`path/to/test.test.ts
// file content
\`\`\`

Create files in the appropriate project directories (e.g. tests/, __tests__/, src/**/*.test.ts) per project convention."

    local model="${CLAUDE_MODEL:-${MODEL:-sonnet}}"
    [[ -z "$model" || "$model" == "null" ]] && model="sonnet"

    local output=""
    output=$(echo "$tdd_prompt" | timeout 120 claude --print --model "$model" 2>/dev/null) || {
        warn "TDD test generation failed, falling back to standard build"
        return 1
    }

    # Parse output: extract fenced code blocks and write to files
    local wrote_any=false
    local block_path="" in_block=false block_content=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\`\`\`([a-zA-Z0-9_/\.\-]+)$ ]]; then
            if [[ -n "$block_path" && -n "$block_content" ]]; then
                local out_file="${PROJECT_ROOT}/${block_path}"
                local out_dir
                out_dir=$(dirname "$out_file")
                mkdir -p "$out_dir" 2>/dev/null || true
                if echo "$block_content" > "$out_file" 2>/dev/null; then
                    wrote_any=true
                    info "  Wrote: $block_path"
                fi
            fi
            block_path="${BASH_REMATCH[1]}"
            block_content=""
            in_block=true
        elif [[ "$line" == "\`\`\`" && "$in_block" == "true" ]]; then
            if [[ -n "$block_path" && -n "$block_content" ]]; then
                local out_file="${PROJECT_ROOT}/${block_path}"
                local out_dir
                out_dir=$(dirname "$out_file")
                mkdir -p "$out_dir" 2>/dev/null || true
                if echo "$block_content" > "$out_file" 2>/dev/null; then
                    wrote_any=true
                    info "  Wrote: $block_path"
                fi
            fi
            block_path=""
            block_content=""
            in_block=false
        elif [[ "$in_block" == "true" && -n "$block_path" ]]; then
            [[ -n "$block_content" ]] && block_content="${block_content}"$'\n'
            block_content="${block_content}${line}"
        fi
    done <<< "$output"

    # Flush last block if unclosed
    if [[ -n "$block_path" && -n "$block_content" ]]; then
        local out_file="${PROJECT_ROOT}/${block_path}"
        local out_dir
        out_dir=$(dirname "$out_file")
        mkdir -p "$out_dir" 2>/dev/null || true
        if echo "$block_content" > "$out_file" 2>/dev/null; then
            wrote_any=true
            info "  Wrote: $block_path"
        fi
    fi

    if [[ "$wrote_any" == "true" ]]; then
        if (cd "$PROJECT_ROOT" && git diff --name-only 2>/dev/null | grep -qE 'test|spec'); then
            git add -A 2>/dev/null || true
            git commit -m "test: TDD - define expected behavior before implementation" 2>/dev/null || true
            emit_event "tdd.tests_generated" "{\"stage\":\"test_first\"}"
        fi
        success "TDD tests generated"
    else
        warn "No test files extracted from TDD output — check format"
    fi

    return 0
}

stage_build() {
    CURRENT_STAGE_ID="build"
    # Consume retry context if this is a retry attempt
    local _retry_ctx="${ARTIFACTS_DIR}/.retry-context-build.md"
    if [[ -s "$_retry_ctx" ]]; then
        local _build_retry_hints
        _build_retry_hints=$(cat "$_retry_ctx" 2>/dev/null || true)
        rm -f "$_retry_ctx"
    fi
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local design_file="$ARTIFACTS_DIR/design.md"
    local dod_file="$ARTIFACTS_DIR/dod.md"
    local loop_args=()

    # Memory integration — inject context if memory system available
    local memory_context=""
    if type intelligence_search_memory >/dev/null 2>&1; then
        local mem_dir="${HOME}/.shipwright/memory"
        memory_context=$(intelligence_search_memory "build stage for: ${GOAL:-}" "$mem_dir" 5 2>/dev/null) || true
    fi
    if [[ -z "$memory_context" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_context=$(bash "$SCRIPT_DIR/sw-memory.sh" inject "build" 2>/dev/null) || true
    fi

    # Build enriched goal with compact context (avoids prompt bloat)
    local enriched_goal
    enriched_goal=$(_pipeline_compact_goal "$GOAL" "$plan_file" "$design_file")

    # TDD: when test_first ran, tell build to make existing tests pass
    if [[ "${TDD_ENABLED:-false}" == "true" || "${PIPELINE_TDD:-}" == "true" ]]; then
        enriched_goal="${enriched_goal}

IMPORTANT (TDD mode): Test files already exist and define the expected behavior. Write implementation code to make ALL tests pass. Do not delete or modify the test files."
    fi

    # Inject memory context
    if [[ -n "$memory_context" ]]; then
        enriched_goal="${enriched_goal}

Historical context (lessons from previous pipelines):
${memory_context}"
    fi

    # Inject cross-pipeline discoveries for build stage
    if [[ -x "$SCRIPT_DIR/sw-discovery.sh" ]]; then
        local build_discoveries
        build_discoveries=$("$SCRIPT_DIR/sw-discovery.sh" inject "src/*,*.ts,*.tsx,*.js" 2>/dev/null | head -20 || true)
        if [[ -n "$build_discoveries" ]]; then
            enriched_goal="${enriched_goal}

Discoveries from other pipelines:
${build_discoveries}"
        fi
    fi

    # Add task list context
    if [[ -s "$TASKS_FILE" ]]; then
        enriched_goal="${enriched_goal}

Task tracking (check off items as you complete them):
$(cat "$TASKS_FILE")"
    fi

    # Inject file hotspots from GitHub intelligence
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_file_change_frequency >/dev/null 2>&1; then
        local build_hotspots
        build_hotspots=$(gh_file_change_frequency 2>/dev/null | head -5 || true)
        if [[ -n "$build_hotspots" ]]; then
            enriched_goal="${enriched_goal}

File hotspots (most frequently changed — review these carefully):
${build_hotspots}"
        fi
    fi

    # Inject security alerts context
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_security_alerts >/dev/null 2>&1; then
        local build_alerts
        build_alerts=$(gh_security_alerts 2>/dev/null | head -3 || true)
        if [[ -n "$build_alerts" ]]; then
            enriched_goal="${enriched_goal}

Active security alerts (do not introduce new vulnerabilities):
${build_alerts}"
        fi
    fi

    # Inject coverage baseline
    local repo_hash_build
    repo_hash_build=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local coverage_file_build="${HOME}/.shipwright/baselines/${repo_hash_build}/coverage.json"
    if [[ -f "$coverage_file_build" ]]; then
        local coverage_baseline
        coverage_baseline=$(jq -r '.coverage_percent // empty' "$coverage_file_build" 2>/dev/null || true)
        if [[ -n "$coverage_baseline" ]]; then
            enriched_goal="${enriched_goal}

Coverage baseline: ${coverage_baseline}% — do not decrease coverage."
        fi
    fi

    # Predictive: inject prevention hints when risk/memory patterns suggest build-stage failures
    if [[ -x "$SCRIPT_DIR/sw-predictive.sh" ]]; then
        local issue_json_build="{}"
        [[ -n "${ISSUE_NUMBER:-}" ]] && issue_json_build=$(jq -n --arg title "${GOAL:-}" --arg num "${ISSUE_NUMBER:-}" '{title: $title, number: $num}')
        local prevention_text
        prevention_text=$(bash "$SCRIPT_DIR/sw-predictive.sh" inject-prevention "build" "$issue_json_build" 2>/dev/null || true)
        if [[ -n "$prevention_text" ]]; then
            enriched_goal="${enriched_goal}

${prevention_text}"
        fi
    fi

    # Inject skill prompts for build stage
    local _skill_prompts=""
    if type skill_load_from_plan >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_from_plan "build" 2>/dev/null || true)
    elif type skill_select_adaptive >/dev/null 2>&1; then
        local _skill_files
        _skill_files=$(skill_select_adaptive "${INTELLIGENCE_ISSUE_TYPE:-backend}" "build" "${ISSUE_BODY:-}" "${INTELLIGENCE_COMPLEXITY:-5}" 2>/dev/null || true)
        if [[ -n "$_skill_files" ]]; then
            _skill_prompts=$(while IFS= read -r _path; do
                [[ -z "$_path" || ! -f "$_path" ]] && continue
                cat "$_path" 2>/dev/null
            done <<< "$_skill_files")
        fi
    elif type skill_load_prompts >/dev/null 2>&1; then
        _skill_prompts=$(skill_load_prompts "${INTELLIGENCE_ISSUE_TYPE:-backend}" "build" 2>/dev/null || true)
    fi
    if [[ -n "$_skill_prompts" ]]; then
        _skill_prompts=$(prune_context_section "skills" "$_skill_prompts" 8000)
        enriched_goal="${enriched_goal}

## Skill Guidance (${INTELLIGENCE_ISSUE_TYPE:-backend} issue, AI-selected)
${_skill_prompts}
"
    fi

    loop_args+=("$enriched_goal")

    # Build loop args from pipeline config + CLI overrides
    CURRENT_STAGE_ID="build"

    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$test_cmd" == "null" ]] && test_cmd=""
    fi
    # Auto-detect if still empty
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi

    # Discover additional test commands (subdirectories, extra scripts)
    local additional_cmds=()
    if type detect_test_commands >/dev/null 2>&1; then
        while IFS= read -r _cmd; do
            [[ -n "$_cmd" ]] && additional_cmds+=("$_cmd")
        done < <(detect_test_commands 2>/dev/null | tail -n +2)
    fi

    local max_iter
    max_iter=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.max_iterations) // 20' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_iter" || "$max_iter" == "null" ]] && max_iter=20
    # CLI --max-iterations override (from CI strategy engine)
    [[ -n "${MAX_ITERATIONS_OVERRIDE:-}" ]] && max_iter="$MAX_ITERATIONS_OVERRIDE"

    local agents="${AGENTS}"
    if [[ -z "$agents" ]]; then
        agents=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.agents) // .defaults.agents // 1' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$agents" || "$agents" == "null" ]] && agents=1
    fi

    # Intelligence: suggest parallelism if design indicates independent work
    if [[ "${agents:-1}" -le 1 ]] && [[ -s "$ARTIFACTS_DIR/design.md" ]]; then
        local design_lower
        design_lower=$(tr '[:upper:]' '[:lower:]' < "$ARTIFACTS_DIR/design.md" 2>/dev/null || true)
        if echo "$design_lower" | grep -qE 'independent (files|modules|components|services)|separate (modules|packages|directories)|parallel|no shared state'; then
            info "Design mentions independent modules — consider --agents 2 for parallelism"
            emit_event "build.parallelism_suggested" "issue=${ISSUE_NUMBER:-0}" "current_agents=$agents"
        fi
    fi

    local audit
    audit=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.audit) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    local quality
    quality=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.quality_gates) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true

    local build_model="${MODEL}"
    if [[ -z "$build_model" ]]; then
        build_model=$(jq -r '.defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$build_model" || "$build_model" == "null" ]] && build_model="opus"
    fi
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        build_model="$CLAUDE_MODEL"
    fi

    # Recruit-powered model selection (when no explicit override)
    if [[ -z "$MODEL" ]] && [[ -x "$SCRIPT_DIR/sw-recruit.sh" ]]; then
        local _recruit_goal="${GOAL:-}"
        if [[ -n "$_recruit_goal" ]]; then
            local _recruit_match
            _recruit_match=$(bash "$SCRIPT_DIR/sw-recruit.sh" match --json "$_recruit_goal" 2>/dev/null) || true
            if [[ -n "$_recruit_match" ]]; then
                local _recruit_model
                _recruit_model=$(echo "$_recruit_match" | jq -r '.model // ""' 2>/dev/null) || true
                if [[ -n "$_recruit_model" && "$_recruit_model" != "null" && "$_recruit_model" != "" ]]; then
                    info "Recruit recommends model: ${CYAN}${_recruit_model}${RESET} for this task"
                    build_model="$_recruit_model"
                fi
            fi
        fi
    fi

    [[ -n "$test_cmd" && "$test_cmd" != "null" ]] && loop_args+=(--test-cmd "$test_cmd")
    for _extra_tc in "${additional_cmds[@]+"${additional_cmds[@]}"}"; do
        [[ -n "$_extra_tc" ]] && loop_args+=(--additional-test-cmds "$_extra_tc")
    done
    loop_args+=(--max-iterations "$max_iter")
    loop_args+=(--model "$build_model")
    [[ "$agents" -gt 1 ]] 2>/dev/null && loop_args+=(--agents "$agents")

    # Quality gates: always enabled in CI, otherwise from template config
    if [[ "${CI_MODE:-false}" == "true" ]]; then
        loop_args+=(--audit --audit-agent --quality-gates)
    else
        [[ "$audit" == "true" ]] && loop_args+=(--audit --audit-agent)
        [[ "$quality" == "true" ]] && loop_args+=(--quality-gates)
    fi

    # Session restart capability
    [[ -n "${MAX_RESTARTS_OVERRIDE:-}" ]] && loop_args+=(--max-restarts "$MAX_RESTARTS_OVERRIDE")
    # Fast test mode
    [[ -n "${FAST_TEST_CMD_OVERRIDE:-}" ]] && loop_args+=(--fast-test-cmd "$FAST_TEST_CMD_OVERRIDE")

    # Definition of Done: use plan-extracted DoD if available
    [[ -s "$dod_file" ]] && loop_args+=(--definition-of-done "$dod_file")

    # Checkpoint resume: when pipeline resumed from build-stage checkpoint, pass --resume to loop
    if [[ "${RESUME_FROM_CHECKPOINT:-false}" == "true" && "${checkpoint_stage:-}" == "build" ]]; then
        loop_args+=(--resume)
    fi

    # Skip permissions — pipeline runs headlessly (claude -p) and has no terminal
    # for interactive permission prompts. Without this flag, agents can't write files.
    loop_args+=(--skip-permissions)

    info "Starting build loop: ${DIM}shipwright loop${RESET} (max ${max_iter} iterations, ${agents} agent(s))"

    # Post build start to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "🔨 **Build started** — \`shipwright loop\` with ${max_iter} max iterations, ${agents} agent(s), model: ${build_model}"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-build.log"
    export PIPELINE_JOB_ID="${PIPELINE_NAME:-pipeline-$$}"
    sw loop "${loop_args[@]}" < /dev/null 2>"$_token_log" || {
        local _loop_exit=$?
        parse_claude_tokens "$_token_log"

        # Detect context exhaustion from progress file
        local _progress_file="${PWD}/.claude/loop-logs/progress.md"
        if [[ -f "$_progress_file" ]]; then
            local _prog_tests
            _prog_tests=$(grep -oE 'Tests passing: (true|false)' "$_progress_file" 2>/dev/null | awk '{print $NF}' || echo "unknown")
            if [[ "$_prog_tests" != "true" ]]; then
                warn "Build loop exhausted with failing tests (context exhaustion)"
                emit_event "pipeline.context_exhaustion" "issue=${ISSUE_NUMBER:-0}" "stage=build"
                # Write flag for daemon retry logic
                mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
                echo "context_exhaustion" > "$ARTIFACTS_DIR/failure-reason.txt" 2>/dev/null || true
            fi
        fi

        error "Build loop failed"
        return 1
    }
    parse_claude_tokens "$_token_log"

    # Read accumulated token counts from build loop (written by sw-loop.sh)
    local _loop_token_file="${PROJECT_ROOT}/.claude/loop-logs/loop-tokens.json"
    if [[ -f "$_loop_token_file" ]] && command -v jq >/dev/null 2>&1; then
        local _loop_in _loop_out _loop_cost
        _loop_in=$(jq -r '.input_tokens // 0' "$_loop_token_file" 2>/dev/null || echo "0")
        _loop_out=$(jq -r '.output_tokens // 0' "$_loop_token_file" 2>/dev/null || echo "0")
        _loop_cost=$(jq -r '.cost_usd // 0' "$_loop_token_file" 2>/dev/null || echo "0")
        TOTAL_INPUT_TOKENS=$(( TOTAL_INPUT_TOKENS + ${_loop_in:-0} ))
        TOTAL_OUTPUT_TOKENS=$(( TOTAL_OUTPUT_TOKENS + ${_loop_out:-0} ))
        if [[ -n "$_loop_cost" && "$_loop_cost" != "0" && "$_loop_cost" != "null" ]]; then
            TOTAL_COST_USD="${_loop_cost}"
        fi
        if [[ "${_loop_in:-0}" -gt 0 || "${_loop_out:-0}" -gt 0 ]]; then
            info "Build loop tokens: in=${_loop_in} out=${_loop_out} cost=\$${_loop_cost:-0}"
        fi
    fi

    # Count commits made during build
    local commit_count
    commit_count=$(_safe_base_log --oneline | wc -l | xargs)
    info "Build produced ${BOLD}$commit_count${RESET} commit(s)"

    # Commit quality evaluation when intelligence is enabled
    if type intelligence_search_memory >/dev/null 2>&1 && command -v claude >/dev/null 2>&1 && [[ "${commit_count:-0}" -gt 0 ]]; then
        local commit_msgs
        commit_msgs=$(_safe_base_log --format="%s" | head -20)
        local quality_score
        quality_score=$(claude --print --output-format text -p "Rate the quality of these git commit messages on a scale of 0-100. Consider: focus (one thing per commit), clarity (describes the why), atomicity (small logical units). Reply with ONLY a number 0-100.

Commit messages:
${commit_msgs}" --model haiku < /dev/null 2>/dev/null || true)
        quality_score=$(echo "$quality_score" | grep -oE '^[0-9]+' | head -1 || true)
        if [[ -n "$quality_score" ]]; then
            emit_event "build.commit_quality" \
                "issue=${ISSUE_NUMBER:-0}" \
                "score=$quality_score" \
                "commit_count=$commit_count"
            if [[ "$quality_score" -lt 40 ]] 2>/dev/null; then
                warn "Commit message quality low (score: ${quality_score}/100)"
            else
                info "Commit quality score: ${quality_score}/100"
            fi
        fi
    fi

    log_stage "build" "Build loop completed ($commit_count commits)"
}

stage_test() {
    CURRENT_STAGE_ID="test"
    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$test_cmd" || "$test_cmd" == "null" ]] && test_cmd=""
    fi
    # Auto-detect
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi
    if [[ -z "$test_cmd" ]]; then
        warn "No test command found — skipping test stage"
        return 0
    fi

    local coverage_min
    coverage_min=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.coverage_min) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$coverage_min" || "$coverage_min" == "null" ]] && coverage_min=0

    local test_log="$ARTIFACTS_DIR/test-results.log"

    info "Running tests: ${DIM}$test_cmd${RESET}"
    local test_exit=0
    bash -c "$test_cmd" > "$test_log" 2>&1 || test_exit=$?

    if [[ "$test_exit" -eq 0 ]]; then
        success "Tests passed"
    else
        error "Tests failed (exit code: $test_exit)"
        # Extract most relevant error section (assertion failures, stack traces)
        local relevant_output=""
        relevant_output=$(grep -A5 -E 'FAIL|AssertionError|Expected.*but.*got|Error:|panic:|assert' "$test_log" 2>/dev/null | tail -40 || true)
        if [[ -z "$relevant_output" ]]; then
            relevant_output=$(tail -40 "$test_log")
        fi
        echo "$relevant_output"

        # Post failure to GitHub with more context
        if [[ -n "$ISSUE_NUMBER" ]]; then
            local log_lines
            log_lines=$(wc -l < "$test_log" 2>/dev/null || true)
            log_lines="${log_lines:-0}"
            local log_excerpt
            if [[ "$log_lines" -lt 60 ]]; then
                log_excerpt="$(cat "$test_log" 2>/dev/null || true)"
            else
                log_excerpt="$(head -20 "$test_log" 2>/dev/null || true)
... (${log_lines} lines total, showing head + tail) ...
$(tail -30 "$test_log" 2>/dev/null || true)"
            fi
            gh_comment_issue "$ISSUE_NUMBER" "❌ **Tests failed** (exit code: $test_exit, ${log_lines} lines)
\`\`\`
${log_excerpt}
\`\`\`"
        fi
        return 1
    fi

    # Coverage check — only enforce when coverage data is actually detected
    local coverage=""
    if [[ "$coverage_min" -gt 0 ]] 2>/dev/null; then
        coverage=$(parse_coverage_from_output "$test_log")
        if [[ -z "$coverage" ]]; then
            # No coverage data found — skip enforcement (project may not have coverage tooling)
            info "No coverage data detected — skipping coverage check (min: ${coverage_min}%)"
        elif awk -v cov="$coverage" -v min="$coverage_min" 'BEGIN{exit !(cov < min)}' 2>/dev/null; then
            warn "Coverage ${coverage}% below minimum ${coverage_min}%"
            return 1
        else
            info "Coverage: ${coverage}% (min: ${coverage_min}%)"
        fi
    fi

    # Emit test.completed with coverage for adaptive learning
    if [[ -n "$coverage" ]]; then
        emit_event "test.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=test" \
            "coverage=$coverage"
    fi

    # Post test results to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local test_summary
        test_summary=$(tail -10 "$test_log" | sed 's/\x1b\[[0-9;]*m//g')
        local cov_line=""
        [[ -n "$coverage" ]] && cov_line="
**Coverage:** ${coverage}%"
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Tests passed**${cov_line}
<details>
<summary>Test output</summary>

\`\`\`
${test_summary}
\`\`\`
</details>"
    fi

    # Write coverage summary for pre-deploy gate
    local _cov_pct=0
    if [[ -f "$ARTIFACTS_DIR/test-results.log" ]]; then
        _cov_pct=$(grep -oE '[0-9]+%' "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -1 | tr -d '%' || true)
        _cov_pct="${_cov_pct:-0}"
    fi
    local _cov_tmp
    _cov_tmp=$(mktemp "${ARTIFACTS_DIR}/test-coverage.json.tmp.XXXXXX")
    printf '{"coverage_pct":%d}' "${_cov_pct:-0}" > "$_cov_tmp" && mv "$_cov_tmp" "$ARTIFACTS_DIR/test-coverage.json" || rm -f "$_cov_tmp"

    log_stage "test" "Tests passed${coverage:+ (coverage: ${coverage}%)}"
}

