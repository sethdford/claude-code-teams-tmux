# pipeline-intelligence.sh — Skip/adaptive/audits/DoD/security/compound_quality for sw-pipeline.sh
# Source from sw-pipeline.sh. Requires pipeline-quality-checks, state, ARTIFACTS_DIR, PIPELINE_CONFIG.
[[ -n "${_PIPELINE_INTELLIGENCE_LOADED:-}" ]] && return 0
_PIPELINE_INTELLIGENCE_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NO_GITHUB="${NO_GITHUB:-false}"

# Source compound audit cascade library (fail-open)
if [[ -f "${SCRIPT_DIR}/lib/compound-audit.sh" ]]; then
    _COMPOUND_AUDIT_LOADED=""
    source "${SCRIPT_DIR}/lib/compound-audit.sh"
fi

# Source sub-modules
if [[ -f "${SCRIPT_DIR}/lib/pipeline-intelligence-skip.sh" ]]; then
    source "${SCRIPT_DIR}/lib/pipeline-intelligence-skip.sh"
fi
if [[ -f "${SCRIPT_DIR}/lib/pipeline-intelligence-scoring.sh" ]]; then
    source "${SCRIPT_DIR}/lib/pipeline-intelligence-scoring.sh"
fi
if [[ -f "${SCRIPT_DIR}/lib/pipeline-intelligence-compound.sh" ]]; then
    source "${SCRIPT_DIR}/lib/pipeline-intelligence-compound.sh"
fi

stage_compound_quality() {
    CURRENT_STAGE_ID="compound_quality"

    # Pre-check: verify meaningful changes exist before running expensive quality checks
    local _cq_real_changes
    _cq_real_changes=$(git diff --name-only "origin/${BASE_BRANCH:-main}...HEAD" \
        -- . ':!.claude/loop-state.md' ':!.claude/pipeline-state.md' \
        ':!.claude/pipeline-artifacts/*' ':!**/progress.md' \
        ':!**/error-summary.json' 2>/dev/null | wc -l || true)
    _cq_real_changes="${_cq_real_changes:-0}"
    _cq_real_changes=$(echo "$_cq_real_changes" | tr -d '[:space:]')
    [[ -z "$_cq_real_changes" ]] && _cq_real_changes=0
    # Fallback: if no remote, compare against first commit
    if [[ "$_cq_real_changes" -eq 0 ]] 2>/dev/null; then
        _cq_real_changes=$(git diff --name-only "$(git rev-list --max-parents=0 HEAD 2>/dev/null)...HEAD" \
            -- . ':!.claude/*' ':!**/progress.md' ':!**/error-summary.json' 2>/dev/null | wc -l || true)
        _cq_real_changes="${_cq_real_changes:-0}"
        _cq_real_changes=$(echo "$_cq_real_changes" | tr -d '[:space:]')
        [[ -z "$_cq_real_changes" ]] && _cq_real_changes=0
    fi
    if [[ "${_cq_real_changes:-0}" -eq 0 ]]; then
        error "Compound quality: no meaningful code changes found — failing quality gate"
        return 1
    fi

    # Read config
    local max_cycles adversarial_enabled negative_enabled e2e_enabled dod_enabled strict_quality
    max_cycles=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.max_cycles) // 3' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_cycles" || "$max_cycles" == "null" ]] && max_cycles=3
    adversarial_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.adversarial) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    negative_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.negative) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    e2e_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.e2e) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    dod_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.dod_audit) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    strict_quality=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.strict_quality) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$strict_quality" || "$strict_quality" == "null" ]] && strict_quality="false"

    # Intelligent audit selection
    local audit_plan='{"adversarial":"targeted","architecture":"targeted","simulation":"targeted","security":"targeted","dod":"targeted"}'
    if type pipeline_select_audits >/dev/null 2>&1; then
        local _selected
        _selected=$(pipeline_select_audits 2>/dev/null) || true
        if [[ -n "$_selected" && "$_selected" != "null" ]]; then
            audit_plan="$_selected"
            info "Audit plan: $(echo "$audit_plan" | jq -c '.' 2>/dev/null || echo "$audit_plan")"
        fi
    fi

    # Track findings for quality score
    local total_critical=0 total_major=0 total_minor=0
    local audits_run_list=""

    # ── HARDENED QUALITY GATES (RUN BEFORE CYCLES) ──
    # These checks must pass before we even start the audit cycles
    echo ""
    info "Running hardened quality gate checks..."

    # 1. Bash 3.2 compatibility check
    local bash_violations=0
    bash_violations=$(run_bash_compat_check 2>/dev/null) || bash_violations=0
    bash_violations="${bash_violations:-0}"

    if [[ "$strict_quality" == "true" && "$bash_violations" -gt 0 ]]; then
        error "STRICT QUALITY: Bash 3.2 incompatibilities found — blocking"
        emit_event "quality.bash_compat_failed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "violations=$bash_violations"
        return 1
    fi

    if [[ "$bash_violations" -gt 0 ]]; then
        warn "Bash 3.2 incompatibilities detected: ${bash_violations} (will impact quality score)"
        total_minor=$((total_minor + bash_violations))
    else
        success "Bash 3.2 compatibility: clean"
    fi

    # 2. Test coverage check
    local coverage_pct=0
    coverage_pct=$(run_test_coverage_check 2>/dev/null | tr -d '[:space:][:cntrl:]') || coverage_pct=0
    coverage_pct="${coverage_pct:-0}"
    # Sanitize: strip anything non-numeric (ANSI codes, whitespace, etc.)
    coverage_pct=$(echo "$coverage_pct" | sed 's/[^0-9]//g')
    [[ -z "$coverage_pct" ]] && coverage_pct=0

    if [[ "$coverage_pct" != "skip" ]]; then
        if [[ "$coverage_pct" -lt "${PIPELINE_COVERAGE_THRESHOLD:-60}" ]]; then
            if [[ "$strict_quality" == "true" ]]; then
                error "STRICT QUALITY: Test coverage below ${PIPELINE_COVERAGE_THRESHOLD:-60}% (${coverage_pct}%) — blocking"
                emit_event "quality.coverage_failed" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "coverage=$coverage_pct"
                return 1
            else
                warn "Test coverage below ${PIPELINE_COVERAGE_THRESHOLD:-60}% threshold (${coverage_pct}%) — quality penalty applied"
                total_major=$((total_major + 2))
            fi
        fi
    fi

    # 3. New functions without tests check
    local untested_functions=0
    untested_functions=$(run_new_function_test_check 2>/dev/null) || untested_functions=0
    untested_functions="${untested_functions:-0}"

    if [[ "$untested_functions" -gt 0 ]]; then
        if [[ "$strict_quality" == "true" ]]; then
            error "STRICT QUALITY: ${untested_functions} new function(s) without tests — blocking"
            emit_event "quality.untested_functions" \
                "issue=${ISSUE_NUMBER:-0}" \
                "count=$untested_functions"
            return 1
        else
            warn "New functions without corresponding tests: ${untested_functions}"
            total_major=$((total_major + untested_functions))
        fi
    fi

    # 4. Atomic write violations (optional, informational in most modes)
    local atomic_violations=0
    atomic_violations=$(run_atomic_write_check 2>/dev/null) || atomic_violations=0
    atomic_violations="${atomic_violations:-0}"

    if [[ "$atomic_violations" -gt 0 ]]; then
        warn "Atomic write violations: ${atomic_violations} (state/config file patterns)"
        total_minor=$((total_minor + atomic_violations))
    fi

    # Vitals-driven adaptive cycle limit (preferred)
    # Respect the template's max_cycles as a ceiling — vitals can only reduce, not inflate
    local base_max_cycles="$max_cycles"
    local template_max_cycles="$max_cycles"
    if type pipeline_adaptive_limit >/dev/null 2>&1; then
        local _cq_vitals=""
        if type pipeline_compute_vitals >/dev/null 2>&1; then
            _cq_vitals=$(pipeline_compute_vitals "$STATE_FILE" "$ARTIFACTS_DIR" "${ISSUE_NUMBER:-}" 2>/dev/null) || true
        fi
        local vitals_cq_limit
        vitals_cq_limit=$(pipeline_adaptive_limit "compound_quality" "$_cq_vitals" 2>/dev/null) || true
        if [[ -n "$vitals_cq_limit" && "$vitals_cq_limit" =~ ^[0-9]+$ && "$vitals_cq_limit" -gt 0 ]]; then
            # Cap at template max — don't let vitals override the pipeline template's intent
            if [[ "$vitals_cq_limit" -le "$template_max_cycles" ]]; then
                max_cycles="$vitals_cq_limit"
            fi
            if [[ "$max_cycles" != "$base_max_cycles" ]]; then
                info "Vitals-driven cycles: ${base_max_cycles} → ${max_cycles} (compound_quality)"
            fi
        fi
    else
        # Fallback: adaptive cycle limits from optimization data
        local _cq_iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
        if [[ -f "$_cq_iter_model" ]]; then
            local adaptive_limit
            adaptive_limit=$(pipeline_adaptive_cycles "$max_cycles" "compound_quality" "0" "-1" 2>/dev/null) || true
            if [[ -n "$adaptive_limit" && "$adaptive_limit" =~ ^[0-9]+$ && "$adaptive_limit" -gt 0 ]]; then
                max_cycles="$adaptive_limit"
                if [[ "$max_cycles" != "$base_max_cycles" ]]; then
                    info "Adaptive cycles: ${base_max_cycles} → ${max_cycles} (compound_quality)"
                fi
            fi
        fi
    fi

    # Convergence tracking
    local prev_issue_count=-1

    # Compound audit cascade state (persists across cycles)
    local _cascade_all_findings="[]"
    local _cascade_active_agents="logic integration completeness"
    local _cascade_diff=""
    _cascade_diff=$(git diff "${BASE_BRANCH:-main}...HEAD" 2>/dev/null | head -5000) || _cascade_diff=""
    local _cascade_plan=""
    if [[ -f "$ARTIFACTS_DIR/plan.md" ]]; then
        _cascade_plan=$(head -200 "$ARTIFACTS_DIR/plan.md" 2>/dev/null) || true
    fi

    local cycle=0
    while [[ "$cycle" -lt "$max_cycles" ]]; do
        cycle=$((cycle + 1))
        local all_passed=true

        echo ""
        echo -e "${PURPLE}${BOLD}━━━ Compound Quality — Cycle ${cycle}/${max_cycles} ━━━${RESET}"

        if [[ -n "$ISSUE_NUMBER" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "🔬 **Compound quality** — cycle ${cycle}/${max_cycles}" 2>/dev/null || true
        fi

        # 1. Adversarial Review
        local _adv_intensity
        _adv_intensity=$(echo "$audit_plan" | jq -r '.adversarial // "targeted"' 2>/dev/null || echo "targeted")
        if [[ "$adversarial_enabled" == "true" && "$_adv_intensity" != "off" ]]; then
            echo ""
            info "Running adversarial review (${_adv_intensity})..."
            audits_run_list="${audits_run_list:+${audits_run_list},}adversarial"
            if ! run_adversarial_review; then
                all_passed=false
            fi
        fi

        # 2. Negative Prompting
        if [[ "$negative_enabled" == "true" ]]; then
            echo ""
            info "Running negative prompting..."
            if ! run_negative_prompting; then
                all_passed=false
            fi
        fi

        # 3. Developer Simulation (intelligence module)
        if type simulation_review >/dev/null 2>&1; then
            local sim_enabled
            sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
            local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
            if [[ "$sim_enabled" != "true" && -f "$daemon_cfg" ]]; then
                sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
            fi
            if [[ "$sim_enabled" == "true" ]]; then
                echo ""
                info "Running developer simulation review..."
                local sim_diff
                sim_diff=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
                if [[ -n "$sim_diff" ]]; then
                    local sim_result
                    sim_result=$(simulation_review "$sim_diff" "${GOAL:-}" 2>/dev/null || echo "[]")
                    if [[ -n "$sim_result" && "$sim_result" != "[]" && "$sim_result" != *'"error"'* ]]; then
                        echo "$sim_result" > "$ARTIFACTS_DIR/compound-simulation-review.json"
                        local sim_critical
                        sim_critical=$(echo "$sim_result" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                        local sim_total
                        sim_total=$(echo "$sim_result" | jq 'length' 2>/dev/null || echo "0")
                        if [[ "$sim_critical" -gt 0 ]]; then
                            warn "Developer simulation: ${sim_critical} critical/high concerns (${sim_total} total)"
                            all_passed=false
                        else
                            success "Developer simulation: ${sim_total} concerns (none critical/high)"
                        fi
                        emit_event "compound.simulation" \
                            "issue=${ISSUE_NUMBER:-0}" \
                            "cycle=$cycle" \
                            "total=$sim_total" \
                            "critical=$sim_critical"
                    else
                        success "Developer simulation: no concerns"
                    fi
                fi
            fi
        fi

        # 4. Architecture Enforcer (intelligence module)
        if type architecture_validate_changes >/dev/null 2>&1; then
            local arch_enabled
            arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
            local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
            if [[ "$arch_enabled" != "true" && -f "$daemon_cfg" ]]; then
                arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
            fi
            if [[ "$arch_enabled" == "true" ]]; then
                echo ""
                info "Running architecture validation..."
                local arch_diff
                arch_diff=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
                if [[ -n "$arch_diff" ]]; then
                    local arch_result
                    arch_result=$(architecture_validate_changes "$arch_diff" "" 2>/dev/null || echo "[]")
                    if [[ -n "$arch_result" && "$arch_result" != "[]" && "$arch_result" != *'"error"'* ]]; then
                        echo "$arch_result" > "$ARTIFACTS_DIR/compound-architecture-validation.json"
                        local arch_violations
                        arch_violations=$(echo "$arch_result" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                        local arch_total
                        arch_total=$(echo "$arch_result" | jq 'length' 2>/dev/null || echo "0")
                        if [[ "$arch_violations" -gt 0 ]]; then
                            warn "Architecture validation: ${arch_violations} critical/high violations (${arch_total} total)"
                            all_passed=false
                        else
                            success "Architecture validation: ${arch_total} violations (none critical/high)"
                        fi
                        emit_event "compound.architecture" \
                            "issue=${ISSUE_NUMBER:-0}" \
                            "cycle=$cycle" \
                            "total=$arch_total" \
                            "violations=$arch_violations"
                    else
                        success "Architecture validation: no violations"
                    fi
                fi
            fi
        fi

        # 5. E2E Validation
        if [[ "$e2e_enabled" == "true" ]]; then
            echo ""
            info "Running E2E validation..."
            if ! run_e2e_validation; then
                all_passed=false
            fi
        fi

        # 6. DoD Audit
        local _dod_intensity
        _dod_intensity=$(echo "$audit_plan" | jq -r '.dod // "targeted"' 2>/dev/null || echo "targeted")
        if [[ "$dod_enabled" == "true" && "$_dod_intensity" != "off" ]]; then
            echo ""
            info "Running Definition of Done audit (${_dod_intensity})..."
            audits_run_list="${audits_run_list:+${audits_run_list},}dod"
            if ! run_dod_audit; then
                all_passed=false
            fi
        fi

        # 6b. Security Source Scan
        local _sec_intensity
        _sec_intensity=$(echo "$audit_plan" | jq -r '.security // "targeted"' 2>/dev/null || echo "targeted")
        if [[ "$_sec_intensity" != "off" ]]; then
            echo ""
            info "Running security source scan (${_sec_intensity})..."
            audits_run_list="${audits_run_list:+${audits_run_list},}security"
            local sec_finding_count=0
            sec_finding_count=$(pipeline_security_source_scan 2>/dev/null) || true
            sec_finding_count="${sec_finding_count:-0}"
            if [[ "$sec_finding_count" -gt 0 ]]; then
                warn "Security source scan: ${sec_finding_count} finding(s)"
                total_critical=$((total_critical + sec_finding_count))
                all_passed=false
            else
                success "Security source scan: clean"
            fi
        fi

        # 7. Multi-dimensional quality checks
        echo ""
        info "Running multi-dimensional quality checks..."
        local quality_failures=0

        if ! quality_check_security; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_coverage; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_perf_regression; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_bundle_size; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_api_compat; then
            quality_failures=$((quality_failures + 1))
        fi

        if [[ "$quality_failures" -gt 0 ]]; then
            if [[ "$strict_quality" == "true" ]]; then
                warn "Multi-dimensional quality: ${quality_failures} check(s) failed (strict mode — blocking)"
                all_passed=false
            else
                warn "Multi-dimensional quality: ${quality_failures} check(s) failed (non-blocking)"
            fi
        else
            success "Multi-dimensional quality: all checks passed"
        fi

        # 8. Compound Audit Cascade (adaptive multi-agent probing)
        if type compound_audit_run_cycle >/dev/null 2>&1; then
            echo ""
            info "Running compound audit cascade (agents: $_cascade_active_agents)..."

            local cascade_findings
            cascade_findings=$(compound_audit_run_cycle "$_cascade_active_agents" "$_cascade_diff" "$_cascade_plan" "$_cascade_all_findings" "$cycle") || cascade_findings="[]"

            # Dedup within this cycle
            if type compound_audit_dedup_structural >/dev/null 2>&1; then
                cascade_findings=$(compound_audit_dedup_structural "$cascade_findings") || cascade_findings="[]"
            fi

            local cascade_count
            cascade_count=$(echo "$cascade_findings" | jq 'length' 2>/dev/null || echo "0")
            local cascade_crit
            cascade_crit=$(echo "$cascade_findings" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")

            if [[ "$cascade_count" -gt 0 ]]; then
                warn "Compound audit: ${cascade_count} findings (${cascade_crit} critical/high)"
                total_critical=$((total_critical + $(echo "$cascade_findings" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo "0")))
                total_major=$((total_major + $(echo "$cascade_findings" | jq '[.[] | select(.severity == "high")] | length' 2>/dev/null || echo "0")))
                total_minor=$((total_minor + $(echo "$cascade_findings" | jq '[.[] | select(.severity == "medium" or .severity == "low")] | length' 2>/dev/null || echo "0")))
                [[ "$cascade_crit" -gt 0 ]] && all_passed=false
            else
                success "Compound audit: no findings"
            fi

            # Check cascade convergence
            local cascade_converge=""
            if type compound_audit_converged >/dev/null 2>&1; then
                cascade_converge=$(compound_audit_converged "$cascade_findings" "$_cascade_all_findings" "$cycle" "$max_cycles") || cascade_converge=""
            fi

            type audit_emit >/dev/null 2>&1 && \
                audit_emit "compound.cycle_complete" "cycle=$cycle" "findings=$cascade_count" \
                    "critical_high=$cascade_crit" "converged=$cascade_converge" || true

            if [[ -n "$cascade_converge" ]]; then
                success "Compound audit converged: $cascade_converge"
                type audit_emit >/dev/null 2>&1 && \
                    audit_emit "compound.converged" "reason=$cascade_converge" "total_cycles=$cycle" || true
            fi

            # Merge findings for next cycle's context
            _cascade_all_findings=$(echo "$_cascade_all_findings" "$cascade_findings" | jq -s '.[0] + .[1]' 2>/dev/null || echo "$_cascade_all_findings")

            # Escalate: trigger specialists for next cycle
            if type compound_audit_escalate >/dev/null 2>&1; then
                local cascade_specialists
                cascade_specialists=$(compound_audit_escalate "$cascade_findings") || cascade_specialists=""
                if [[ -n "$cascade_specialists" ]]; then
                    info "Compound audit escalation: adding $cascade_specialists"
                    _cascade_active_agents="logic integration completeness $cascade_specialists"
                fi
            fi

            # Save all findings to artifact
            echo "$_cascade_all_findings" > "$ARTIFACTS_DIR/compound-audit-findings.json" 2>/dev/null || true
        fi

        # ── Convergence Detection ──
        # Count critical/high issues from all review artifacts
        local current_issue_count=0
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
            local adv_issues
            adv_issues=$(grep -ciE '\*\*\[?(Critical|Bug|critical|high)\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
            current_issue_count=$((current_issue_count + ${adv_issues:-0}))
        fi
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.json" ]]; then
            local adv_json_issues
            adv_json_issues=$(jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
            current_issue_count=$((current_issue_count + ${adv_json_issues:-0}))
        fi
        if [[ -f "$ARTIFACTS_DIR/negative-review.md" ]]; then
            local neg_issues
            neg_issues=$(grep -ciE '\[Critical\]' "$ARTIFACTS_DIR/negative-review.md" 2>/dev/null || true)
            current_issue_count=$((current_issue_count + ${neg_issues:-0}))
        fi
        current_issue_count=$((current_issue_count + quality_failures))

        # Add compound audit cascade findings to convergence count
        if [[ -f "$ARTIFACTS_DIR/compound-audit-findings.json" ]]; then
            local cascade_crit_count
            cascade_crit_count=$(jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' \
                "$ARTIFACTS_DIR/compound-audit-findings.json" 2>/dev/null || echo "0")
            current_issue_count=$((current_issue_count + ${cascade_crit_count:-0}))
        fi

        emit_event "compound.cycle" \
            "issue=${ISSUE_NUMBER:-0}" \
            "cycle=$cycle" \
            "max_cycles=$max_cycles" \
            "passed=$all_passed" \
            "critical_issues=$current_issue_count" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Early exit: zero critical/high issues
        if [[ "$current_issue_count" -eq 0 ]] && $all_passed; then
            success "Compound quality passed on cycle ${cycle} — zero critical/high issues"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "✅ **Compound quality passed** — cycle ${cycle}/${max_cycles}

All quality checks clean:
- Adversarial review: ✅
- Negative prompting: ✅
- Developer simulation: ✅
- Architecture validation: ✅
- E2E validation: ✅
- DoD audit: ✅
- Security audit: ✅
- Coverage: ✅
- Performance: ✅
- Bundle size: ✅
- API compat: ✅" 2>/dev/null || true
            fi

            log_stage "compound_quality" "Passed on cycle ${cycle}/${max_cycles}"

            # DoD verification on successful pass
            local _dod_pass_rate=100
            if type pipeline_verify_dod >/dev/null 2>&1; then
                pipeline_verify_dod "$ARTIFACTS_DIR" 2>/dev/null || true
                if [[ -f "$ARTIFACTS_DIR/dod-verification.json" ]]; then
                    _dod_pass_rate=$(jq -r '.pass_rate // 100' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null || echo "100")
                fi
            fi

            pipeline_record_quality_score 100 0 0 0 "$_dod_pass_rate" "$audits_run_list" 2>/dev/null || true
            return 0
        fi

        if $all_passed; then
            success "Compound quality passed on cycle ${cycle}"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "✅ **Compound quality passed** — cycle ${cycle}/${max_cycles}" 2>/dev/null || true
            fi

            log_stage "compound_quality" "Passed on cycle ${cycle}/${max_cycles}"

            # DoD verification on successful pass
            local _dod_pass_rate=100
            if type pipeline_verify_dod >/dev/null 2>&1; then
                pipeline_verify_dod "$ARTIFACTS_DIR" 2>/dev/null || true
                if [[ -f "$ARTIFACTS_DIR/dod-verification.json" ]]; then
                    _dod_pass_rate=$(jq -r '.pass_rate // 100' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null || echo "100")
                fi
            fi

            pipeline_record_quality_score 95 0 "$total_major" "$total_minor" "$_dod_pass_rate" "$audits_run_list" 2>/dev/null || true
            return 0
        fi

        # Check for plateau: issue count unchanged between cycles
        if [[ "$prev_issue_count" -ge 0 && "$current_issue_count" -eq "$prev_issue_count" && "$cycle" -gt 1 ]]; then
            warn "Convergence: quality plateau — ${current_issue_count} issues unchanged between cycles"
            emit_event "compound.plateau" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle" \
                "issue_count=$current_issue_count"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "⚠️ **Compound quality plateau** — ${current_issue_count} issues unchanged after cycle ${cycle}. Stopping early." 2>/dev/null || true
            fi

            log_stage "compound_quality" "Plateau at cycle ${cycle}/${max_cycles} (${current_issue_count} issues)"
            return 1
        fi
        prev_issue_count="$current_issue_count"

        info "Convergence: ${current_issue_count} critical/high issues remaining"

        # Intelligence: re-evaluate adaptive cycle limit based on convergence (only after first cycle)
        if [[ "$prev_issue_count" -ge 0 ]]; then
            local updated_limit
            updated_limit=$(pipeline_adaptive_cycles "$max_cycles" "compound_quality" "$current_issue_count" "$prev_issue_count" 2>/dev/null) || true
            if [[ -n "$updated_limit" && "$updated_limit" =~ ^[0-9]+$ && "$updated_limit" -gt 0 && "$updated_limit" != "$max_cycles" ]]; then
                info "Adaptive cycles: ${max_cycles} → ${updated_limit} (convergence signal)"
                max_cycles="$updated_limit"
            fi
        fi

        # Not all passed — rebuild if we have cycles left
        if [[ "$cycle" -lt "$max_cycles" ]]; then
            warn "Quality checks failed — rebuilding with feedback (cycle $((cycle + 1))/${max_cycles})"

            if ! compound_rebuild_with_feedback; then
                error "Rebuild with feedback failed"
                log_stage "compound_quality" "Rebuild failed on cycle ${cycle}"
                return 1
            fi

            # Re-run review stage too (since code changed)
            info "Re-running review after rebuild..."
            stage_review 2>/dev/null || true
        fi
    done

    # ── Quality Score Computation ──
    # Starting score: 100, deductions based on findings
    local quality_score=100

    # Count findings from artifact files
    if [[ -f "$ARTIFACTS_DIR/security-source-scan.json" ]]; then
        local _sec_critical
        _sec_critical=$(jq '[.[] | select(.severity == "critical")] | length' "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || echo "0")
        local _sec_major
        _sec_major=$(jq '[.[] | select(.severity == "major")] | length' "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || echo "0")
        total_critical=$((total_critical + ${_sec_critical:-0}))
        total_major=$((total_major + ${_sec_major:-0}))
    fi
    if [[ -f "$ARTIFACTS_DIR/adversarial-review.json" ]]; then
        local _adv_crit
        _adv_crit=$(jq '[.[] | select(.severity == "critical")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
        local _adv_major
        _adv_major=$(jq '[.[] | select(.severity == "high" or .severity == "major")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
        local _adv_minor
        _adv_minor=$(jq '[.[] | select(.severity == "low" or .severity == "minor")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
        total_critical=$((total_critical + ${_adv_crit:-0}))
        total_major=$((total_major + ${_adv_major:-0}))
        total_minor=$((total_minor + ${_adv_minor:-0}))
    fi
    if [[ -f "$ARTIFACTS_DIR/compound-architecture-validation.json" ]]; then
        local _arch_crit
        _arch_crit=$(jq '[.[] | select(.severity == "critical")] | length' "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || echo "0")
        local _arch_major
        _arch_major=$(jq '[.[] | select(.severity == "high" or .severity == "major")] | length' "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || echo "0")
        total_major=$((total_major + ${_arch_crit:-0} + ${_arch_major:-0}))
    fi

    # Apply deductions
    quality_score=$((quality_score - (total_critical * 20) - (total_major * 10) - (total_minor * 2)))
    [[ "$quality_score" -lt 0 ]] && quality_score=0

    # DoD verification
    local _dod_pass_rate=0
    if type pipeline_verify_dod >/dev/null 2>&1; then
        pipeline_verify_dod "$ARTIFACTS_DIR" 2>/dev/null || true
        if [[ -f "$ARTIFACTS_DIR/dod-verification.json" ]]; then
            _dod_pass_rate=$(jq -r '.pass_rate // 0' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null || echo "0")
        fi
    fi

    # Record quality score
    pipeline_record_quality_score "$quality_score" "$total_critical" "$total_major" "$total_minor" "$_dod_pass_rate" "$audits_run_list" 2>/dev/null || true

    # ── Quality Gate (HARDENED) ──
    local compound_quality_blocking
    compound_quality_blocking=$(jq -r --arg id "compound_quality" \
        '(.stages[] | select(.id == $id) | .config.compound_quality_blocking) // true' \
        "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$compound_quality_blocking" || "$compound_quality_blocking" == "null" ]] && compound_quality_blocking="true"

    # HARDENED THRESHOLD: quality_score must be >= 60 (non-strict) or policy threshold (strict) to pass
    local min_threshold=60
    if [[ "$strict_quality" == "true" ]]; then
        min_threshold="${PIPELINE_QUALITY_GATE_THRESHOLD:-70}"
        # Strict mode: require score >= threshold and ZERO critical issues
        if [[ "$total_critical" -gt 0 ]]; then
            error "STRICT QUALITY: ${total_critical} critical issue(s) found — BLOCKING (strict mode)"
            emit_event "pipeline.quality_gate_failed_strict" \
                "issue=${ISSUE_NUMBER:-0}" \
                "reason=critical_issues" \
                "critical=$total_critical"
            log_stage "compound_quality" "Quality gate failed (strict mode): critical issues"
            return 1
        fi
        min_threshold=70
    fi

    # Hard floor: score must be >= 40, regardless of other settings
    if [[ "$quality_score" -lt 40 ]]; then
        error "HARDENED GATE: Quality score ${quality_score}/100 below hard floor (40) — BLOCKING"
        emit_event "quality.hard_floor_failed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "quality_score=$quality_score"
        log_stage "compound_quality" "Quality gate failed: score below hard floor (40)"
        return 1
    fi

    if [[ "$quality_score" -lt "$min_threshold" && "$compound_quality_blocking" == "true" ]]; then
        emit_event "pipeline.quality_gate_failed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "quality_score=$quality_score" \
            "threshold=$min_threshold" \
            "critical=$total_critical" \
            "major=$total_major"

        error "Quality gate FAILED: score ${quality_score}/100 (threshold: ${min_threshold}/100, critical: ${total_critical}, major: ${total_major}, minor: ${total_minor})"

        if [[ -n "$ISSUE_NUMBER" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "❌ **Quality gate failed** — score ${quality_score}/${min_threshold}

| Finding Type | Count | Deduction |
|---|---|---|
| Critical | ${total_critical} | -$((total_critical * 20)) |
| Major | ${total_major} | -$((total_major * 10)) |
| Minor | ${total_minor} | -$((total_minor * 2)) |

DoD pass rate: ${_dod_pass_rate}%
Quality issues remain after ${max_cycles} cycles. Check artifacts for details." 2>/dev/null || true
        fi

        log_stage "compound_quality" "Quality gate failed: ${quality_score}/${min_threshold} after ${max_cycles} cycles"
        return 1
    fi

    # Exhausted all cycles but quality score is at or above threshold
    if [[ "$quality_score" -ge "$min_threshold" ]]; then
        if [[ "$quality_score" -eq 100 ]]; then
            success "Compound quality PERFECT: 100/100"
        elif [[ "$quality_score" -ge 80 ]]; then
            success "Compound quality EXCELLENT: ${quality_score}/100"
        elif [[ "$quality_score" -ge 70 ]]; then
            success "Compound quality GOOD: ${quality_score}/100"
        else
            warn "Compound quality ACCEPTABLE: ${quality_score}/${min_threshold} after ${max_cycles} cycles"
        fi

        if [[ -n "$ISSUE_NUMBER" ]]; then
            local quality_emoji="✅"
            [[ "$quality_score" -lt 70 ]] && quality_emoji="⚠️"
            gh_comment_issue "$ISSUE_NUMBER" "${quality_emoji} **Compound quality passed** — score ${quality_score}/${min_threshold} after ${max_cycles} cycles

| Finding Type | Count |
|---|---|
| Critical | ${total_critical} |
| Major | ${total_major} |
| Minor | ${total_minor} |

DoD pass rate: ${_dod_pass_rate}%" 2>/dev/null || true
        fi

        log_stage "compound_quality" "Passed with score ${quality_score}/${min_threshold} after ${max_cycles} cycles"
        return 0
    fi

    error "Compound quality exhausted after ${max_cycles} cycles with insufficient score"

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "❌ **Compound quality failed** after ${max_cycles} cycles

Quality issues remain. Check artifacts for details." 2>/dev/null || true
    fi

    log_stage "compound_quality" "Failed after ${max_cycles} cycles"
    return 1
}

# ─── Error Classification ──────────────────────────────────────────────────
