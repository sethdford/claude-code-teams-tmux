#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Loop Quality — audit agent, quality gates, DoD, holistic gate           ║
# ║                                                                         ║
# ║  This module handles all quality validation: audit agent, quality gates, ║
# ║  definition-of-done checking, guard_completion, holistic gate, and       ║
# ║  prompt composition for audit feedback.                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# Module guard — prevent double-sourcing
[[ -z "${_LOOP_QUALITY_SH_LOADED:-}" ]] || return 0
readonly _LOOP_QUALITY_SH_LOADED=1

# ─── Audit Agent ──────────────────────────────────────────────────────────
run_audit_agent() {
    if ! $AUDIT_AGENT_ENABLED; then
        return
    fi

    local log_file="$LOG_DIR/iteration-${ITERATION}.log"
    local audit_log="$LOG_DIR/audit-iter-${ITERATION}.log"

    # Gather context: tail of implementer output + cumulative diff
    local impl_tail
    impl_tail="$(tail -100 "$log_file" 2>/dev/null || echo "(no output)")"

    # Use cumulative diff from loop start so auditor sees ALL work, not just latest commit
    local diff_stat cumulative_note=""
    if [[ -n "${LOOP_START_COMMIT:-}" ]]; then
        diff_stat="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null || echo "(no changes)")"
        cumulative_note="Note: This diff shows ALL changes since the loop started (iteration 1 through ${ITERATION}), not just the latest commit."
    else
        diff_stat="$(git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null || echo "(no changes)")"
    fi

    # Include verified test status so auditor doesn't have to guess
    local test_context=""
    local evidence_file="${LOG_DIR}/test-evidence-iter-${ITERATION}.json"
    if [[ -f "$evidence_file" ]] && command -v jq >/dev/null 2>&1; then
        local cmd_count total_cmds evidence_detail
        cmd_count=$(jq 'length' "$evidence_file" 2>/dev/null || echo 0)
        total_cmds=$(jq -r '[.[].command] | join(", ")' "$evidence_file" 2>/dev/null || echo "unknown")
        evidence_detail=$(jq -r '.[] | "- \(.command): exit \(.exit_code) (\(.duration_s)s)"' "$evidence_file" 2>/dev/null || echo "")
        test_context="## Verified Test Status (from harness, not from agent)
Test commands run: ${cmd_count} (${total_cmds})
${evidence_detail}
Overall: $(if [[ "${TEST_PASSED:-}" == "true" ]]; then echo "ALL PASSING"; else echo "FAILING"; fi)"
    elif [[ -n "$TEST_CMD" ]]; then
        # Fallback to existing boolean
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            test_context="## Verified Test Status (from harness, not from agent)
Tests: ALL PASSING (command: ${TEST_CMD})"
        else
            test_context="## Verified Test Status (from harness)
Tests: FAILING (command: ${TEST_CMD})
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        fi
    fi

    local audit_prompt
    read -r -d '' audit_prompt <<AUDIT_PROMPT || true
You are an independent code auditor reviewing an autonomous coding agent's CUMULATIVE work.
This is iteration ${ITERATION}. The agent may have done most of the work in earlier iterations.

## Goal the agent was working toward
${GOAL}

## Agent Output This Iteration (last 100 lines)
${impl_tail}

## Cumulative Changes Made (git diff --stat)
${cumulative_note}
${diff_stat}

${test_context}

## Your Task
Critically review the CUMULATIVE work (not just the latest iteration):
1. Has the agent made meaningful progress toward the goal across all iterations?
2. Are there obvious bugs, logic errors, or security issues in the current codebase?
3. Did the agent leave incomplete work (TODOs, placeholder code)?
4. Are there any regressions or broken patterns?
5. Is the code quality acceptable?

IMPORTANT: If the current iteration made small or no code changes, that may be acceptable
if earlier iterations already completed the substantive work. Judge the whole body of work.

If the work is acceptable and moves toward the goal, output exactly: AUDIT_PASS
Otherwise, list the specific issues that need fixing.
AUDIT_PROMPT

    echo -e "  ${PURPLE}▸${RESET} Running audit agent..."

    # Select audit model adaptively (haiku if success rate high, else sonnet)
    local audit_model
    audit_model="$(select_audit_model)"
    local audit_flags=()
    audit_flags+=("--model" "$audit_model")
    if $SKIP_PERMISSIONS; then
        audit_flags+=("--dangerously-skip-permissions")
    fi

    # Use structured output for machine-parseable audit results
    local schema_file="${SCRIPT_DIR}/../schemas/audit-result.json"
    if [[ -f "$schema_file" ]]; then
        audit_flags+=("--json-schema" "$(cat "$schema_file")")
    fi

    local exit_code=0
    claude -p "$audit_prompt" "${audit_flags[@]}" > "$audit_log" 2>&1 || exit_code=$?

    if grep -q "AUDIT_PASS" "$audit_log" 2>/dev/null; then
        AUDIT_RESULT="pass"
        echo -e "  ${GREEN}✓${RESET} Audit: passed"
    else
        AUDIT_RESULT="$(grep -v '^$' "$audit_log" | tail -20 | head -10 2>/dev/null || echo "Audit returned no output")"
        echo -e "  ${YELLOW}⚠${RESET} Audit: issues found"
    fi
}

# ─── Quality Gates ───────────────────────────────────────────────────────────

run_quality_gates() {
    if ! $QUALITY_GATES_ENABLED; then
        QUALITY_GATE_PASSED=true
        return
    fi

    QUALITY_GATE_PASSED=true
    local gate_failures=()

    echo -e "  ${PURPLE}▸${RESET} Running quality gates..."

    # Gate 1: Tests pass (if TEST_CMD set)
    if [[ -n "$TEST_CMD" ]] && [[ "$TEST_PASSED" == "false" ]]; then
        gate_failures+=("tests failing")
    fi

    # Gate 2: No uncommitted changes
    if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || \
       ! git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null; then
        gate_failures+=("uncommitted changes present")
    fi

    # Gate 3: No TODO/FIXME/HACK/XXX in new source code
    # Exclude .claude/, docs/plans/, and markdown files (which legitimately contain task markers)
    local todo_count
    todo_count="$(git -C "$PROJECT_ROOT" diff HEAD~1 -- ':!.claude/' ':!docs/plans/' ':!*.md' 2>/dev/null \
        | grep -cE '^\+.*(TODO|FIXME|HACK|XXX)' || true)"
    todo_count="${todo_count:-0}"
    if [[ "${todo_count:-0}" -gt 0 ]]; then
        gate_failures+=("${todo_count} TODO/FIXME/HACK/XXX markers in new code")
    fi

    # Gate 4: Definition of Done (if DOD_FILE set)
    if [[ -n "$DOD_FILE" ]]; then
        if ! check_definition_of_done; then
            gate_failures+=("definition of done not satisfied")
        fi
    fi

    if [[ ${#gate_failures[@]} -gt 0 ]]; then
        QUALITY_GATE_PASSED=false
        local failures_str
        failures_str="$(printf ', %s' "${gate_failures[@]}")"
        failures_str="${failures_str:2}"  # trim leading ", "
        echo -e "  ${RED}✗${RESET} Quality gates: FAILED (${failures_str})"
    else
        echo -e "  ${GREEN}✓${RESET} Quality gates: all passed"
    fi
}

check_definition_of_done() {
    if [[ ! -f "$DOD_FILE" ]]; then
        warn "Definition of done file not found: $DOD_FILE"
        return 1
    fi

    local dod_content
    dod_content="$(cat "$DOD_FILE")"

    # Use cumulative diff from loop start (not just HEAD~1) so the evaluator
    # can see ALL work done across every iteration, not just the latest commit.
    local diff_content
    if [[ -n "${LOOP_START_COMMIT:-}" ]]; then
        diff_content="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null || echo "(no diff)")"
        diff_content="${diff_content}

## Detailed Changes (cumulative diff, truncated to 200 lines)
$(git -C "$PROJECT_ROOT" diff "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | head -200 || echo "(no diff)")"
    else
        diff_content="$(git -C "$PROJECT_ROOT" diff HEAD~1 2>/dev/null || echo "(no diff)")"
    fi

    # Inject verified runtime facts so the evaluator doesn't have to guess
    local runtime_facts=""
    if [[ -n "$TEST_CMD" ]]; then
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            runtime_facts="## Verified Runtime Facts (from the loop harness, not from the agent)
- Tests: ALL PASSING (verified by running '${TEST_CMD}' after this iteration)
- Test output (last 10 lines):
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        else
            runtime_facts="## Verified Runtime Facts
- Tests: FAILING (verified by running '${TEST_CMD}')
- Test output (last 10 lines):
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        fi
    fi

    local dod_prompt
    read -r -d '' dod_prompt <<DOD_PROMPT || true
You are evaluating whether a project satisfies a Definition of Done checklist.
You are reviewing the CUMULATIVE work across all iterations, not just the latest commit.

## Definition of Done
${dod_content}

${runtime_facts}

## Cumulative Changes Made (git diff from start of loop to now)
${diff_content}

## Your Task
For each item in the Definition of Done, determine if the project satisfies it.
The runtime facts above are verified by the harness — trust them as ground truth.
If ALL items are satisfied, output exactly: DOD_PASS
Otherwise, list which items are NOT satisfied and why.
DOD_PROMPT

    local dod_log="$LOG_DIR/dod-iter-${ITERATION}.log"
    local dod_model
    dod_model="$(select_audit_model)"
    local dod_flags=()
    dod_flags+=("--model" "$dod_model")
    if $SKIP_PERMISSIONS; then
        dod_flags+=("--dangerously-skip-permissions")
    fi

    claude -p "$dod_prompt" "${dod_flags[@]}" > "$dod_log" 2>&1 || true

    if grep -q "DOD_PASS" "$dod_log" 2>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Definition of Done: satisfied"
        return 0
    else
        echo -e "  ${YELLOW}⚠${RESET} Definition of Done: not satisfied"
        return 1
    fi
}

# ─── Guarded Completion ──────────────────────────────────────────────────────

guard_completion() {
    local log_file="$LOG_DIR/iteration-${ITERATION}.log"

    # Check if LOOP_COMPLETE is in the log
    if ! grep -q "LOOP_COMPLETE" "$log_file" 2>/dev/null; then
        return 1  # No completion claim
    fi

    echo -e "  ${CYAN}▸${RESET} LOOP_COMPLETE detected — validating..."

    local rejection_reasons=()

    # Check quality gates
    if ! $QUALITY_GATE_PASSED; then
        rejection_reasons+=("quality gates failed")
    fi

    # Check audit agent
    if $AUDIT_AGENT_ENABLED && [[ "$AUDIT_RESULT" != "pass" ]]; then
        rejection_reasons+=("audit agent found issues")
    fi

    # Check tests
    if [[ -n "$TEST_CMD" ]] && [[ "$TEST_PASSED" == "false" ]]; then
        rejection_reasons+=("tests failing")
    fi

    # Holistic final gate: when all other gates pass, run a project-level assessment
    # that evaluates the entire codebase against the goal (not just the latest diff)
    if [[ ${#rejection_reasons[@]} -eq 0 ]]; then
        if ! run_holistic_gate; then
            rejection_reasons+=("holistic project assessment found gaps")
        fi
    fi

    if [[ ${#rejection_reasons[@]} -gt 0 ]]; then
        local reasons_str
        reasons_str="$(printf ', %s' "${rejection_reasons[@]}")"
        reasons_str="${reasons_str:2}"
        echo -e "  ${RED}✗${RESET} Completion REJECTED: ${reasons_str}"
        COMPLETION_REJECTED=true
        return 1
    fi

    echo -e "  ${GREEN}${BOLD}✓ LOOP_COMPLETE accepted — all gates passed!${RESET}"
    return 0
}

# Holistic gate: evaluates the full project against the original goal.
# Only runs when all other gates pass (final checkpoint before acceptance).
run_holistic_gate() {
    # Skip if no starting commit (can't compute cumulative diff)
    [[ -z "${LOOP_START_COMMIT:-}" ]] && return 0

    local holistic_log="$LOG_DIR/holistic-iter-${ITERATION}.log"

    # Build a project summary: file tree, test count, cumulative diff stats
    local file_count
    file_count=$(git -C "$PROJECT_ROOT" ls-files | wc -l | tr -d ' ')
    local cumulative_stat
    cumulative_stat="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | tail -1 || echo "(no changes)")"
    local test_summary=""
    if [[ -n "${TEST_OUTPUT:-}" ]]; then
        test_summary="$(echo "$TEST_OUTPUT" | tail -5)"
    fi

    local holistic_prompt
    read -r -d '' holistic_prompt <<HOLISTIC_PROMPT || true
You are a final quality gate evaluating whether an autonomous coding agent has FULLY achieved its goal.

## Original Goal
${GOAL}

## Project Stats
- Files in repo: ${file_count}
- Iterations completed: ${ITERATION}
- Cumulative changes: ${cumulative_stat}
- Tests: ${TEST_PASSED:-unknown} (command: ${TEST_CMD:-none})
${test_summary:+- Test output: ${test_summary}}

## Cumulative Git Changes (diff --stat from start)
$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | head -40 || echo "(none)")

## Your Task
Based on the goal and the cumulative work done:
1. Has the goal been FULLY achieved (not partially)?
2. Is there any critical gap that would make this unacceptable for production?

If the goal is fully achieved, output exactly: HOLISTIC_PASS
Otherwise, list the specific gaps remaining.
HOLISTIC_PROMPT

    echo -e "  ${PURPLE}▸${RESET} Running holistic project assessment..."

    local hol_model
    hol_model="$(select_audit_model)"
    local hol_flags=("--model" "$hol_model")
    if $SKIP_PERMISSIONS; then
        hol_flags+=("--dangerously-skip-permissions")
    fi

    claude -p "$holistic_prompt" "${hol_flags[@]}" > "$holistic_log" 2>&1 || true

    if grep -q "HOLISTIC_PASS" "$holistic_log" 2>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Holistic assessment: passed"
        return 0
    else
        echo -e "  ${YELLOW}⚠${RESET} Holistic assessment: gaps found"
        return 1
    fi
}

# ─── Audit Prompt Composition ────────────────────────────────────────────────

compose_audit_section() {
    if ! $AUDIT_ENABLED; then
        return
    fi

    # Try to inject audit items from past review feedback in memory
    local memory_audit_items=""
    if [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        local mem_dir_path
        mem_dir_path="$HOME/.shipwright/memory"
        # Look for review feedback in any repo memory
        local repo_hash_val
        repo_hash_val=$(git config --get remote.origin.url 2>/dev/null | shasum -a 256 2>/dev/null | cut -c1-12 || echo "")
        if [[ -n "$repo_hash_val" && -f "$mem_dir_path/$repo_hash_val/failures.json" ]]; then
            memory_audit_items=$(jq -r '.failures[] | select(.stage == "review" and .pattern != "") |
                "- Check for: \(.pattern[:100])"' \
                "$mem_dir_path/$repo_hash_val/failures.json" 2>/dev/null | head -5 || true)
        fi
    fi

    echo "## Self-Audit Checklist"
    echo "Before declaring LOOP_COMPLETE, critically evaluate your own work:"
    echo "1. Does the implementation FULLY satisfy the goal, not just partially?"
    echo "2. Are there any edge cases you haven't handled?"
    echo "3. Did you leave any TODO, FIXME, HACK, or XXX comments in new code?"
    echo "4. Are all new functions/modules tested (if a test command exists)?"
    echo "5. Would a code reviewer approve this, or would they request changes?"
    echo "6. Is the code clean, well-structured, and following project conventions?"
    if [[ -n "$memory_audit_items" ]]; then
        echo ""
        echo "Common review findings from this repo's history:"
        echo "$memory_audit_items"
    fi
    echo ""
    echo "If ANY answer is \"no\", do NOT output LOOP_COMPLETE. Instead, fix the issues first."
}

compose_audit_feedback_section() {
    if [[ -z "$AUDIT_RESULT" ]] || [[ "$AUDIT_RESULT" == "pass" ]]; then
        return
    fi
    cat <<AUDIT_FEEDBACK
## Audit Feedback (Previous Iteration)
An independent audit of your last iteration found these issues:
${AUDIT_RESULT}

Address ALL audit findings before proceeding with new work.
AUDIT_FEEDBACK
}

compose_rejection_notice_section() {
    if ! $COMPLETION_REJECTED; then
        return
    fi
    COMPLETION_REJECTED=false
    cat <<'REJECTION'
## ⚠ Completion Rejected
Your previous LOOP_COMPLETE was REJECTED because quality gates did not pass.
Review the audit feedback and test results above, fix the issues, then try again.
Do NOT output LOOP_COMPLETE until all quality checks pass.
REJECTION
}
