#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  loop-failure-modes — Failure classification and adaptive recovery       ║
# ║                                                                         ║
# ║  Analyzes build loop failures and classifies them into 5 modes:         ║
# ║  - context_exhaustion: Loop near max iterations with no progress        ║
# ║  - infinite_loop: Same error repeating across iterations                ║
# ║  - test_flakiness: Tests alternating pass/fail                          ║
# ║  - dependency_issue: Pre-test failures (npm ERR, ModuleNotFoundError)   ║
# ║  - code_error: Standard test/syntax failures (catch-all default)        ║
# ║                                                                         ║
# ║  Each mode maps to a targeted recovery strategy instead of generic      ║
# ║  retries, improving restart success rates.                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Module guard - prevent double-sourcing
[[ -n "${_LOOP_FAILURE_MODES_LOADED:-}" ]] && return 0
_LOOP_FAILURE_MODES_LOADED=1

VERSION="3.2.4"

# ─── Detection Heuristics ────────────────────────────────────────────────────

# Detect context exhaustion: loop near max iterations with stalled progress
# Returns 0 if detected, 1 otherwise
_detect_context_exhaustion() {
    local iteration="${ITERATION:-0}"
    local max_iterations="${MAX_ITERATIONS:-20}"
    local log_dir="${LOG_DIR:-}"

    # Must be at 80%+ of max iterations
    local threshold=$(( max_iterations * 80 / 100 ))
    if [[ "$iteration" -lt "$threshold" ]]; then
        return 1
    fi

    # Check for stalled progress: no new commits in last 3 iterations
    if [[ -n "$log_dir" ]] && [[ -f "$log_dir/progress.md" ]]; then
        local recent_commits=0
        local check_from=$(( iteration - 3 ))
        [[ "$check_from" -lt 0 ]] && check_from=0
        local i
        for i in $(seq "$check_from" "$iteration"); do
            if grep -q "Iteration ${i}.*commit" "$log_dir/progress.md" 2>/dev/null; then
                recent_commits=$(( recent_commits + 1 ))
            fi
        done
        # If fewer than 1 commit in last 3 iterations, likely exhausted
        if [[ "$recent_commits" -le 1 ]]; then
            return 0
        fi
    fi

    # Also check consecutive failures as a signal
    local consec="${CONSECUTIVE_FAILURES:-0}"
    if [[ "$consec" -ge 3 ]] && [[ "$iteration" -ge "$threshold" ]]; then
        return 0
    fi

    return 1
}

# Detect infinite loop: same error repeating across iterations
# Returns 0 if detected, 1 otherwise
_detect_infinite_loop() {
    local log_dir="${LOG_DIR:-}"
    local consec="${CONSECUTIVE_FAILURES:-0}"

    # Need at least 3 consecutive failures
    if [[ "$consec" -lt 3 ]]; then
        return 1
    fi

    # Check error-summary.json for repeated error signatures
    if [[ -n "$log_dir" ]] && [[ -f "$log_dir/error-summary.json" ]]; then
        local error_lines
        error_lines=$(jq -r '.error_lines[]? // empty' "$log_dir/error-summary.json" 2>/dev/null || echo "")

        if [[ -z "$error_lines" ]]; then
            return 1
        fi

        # Check progress.md for same error appearing in multiple iterations
        if [[ -f "$log_dir/progress.md" ]]; then
            local first_error
            first_error=$(echo "$error_lines" | head -1 | cut -c1-80)
            if [[ -n "$first_error" ]]; then
                local occurrences
                occurrences=$(grep -c "$first_error" "$log_dir/progress.md" 2>/dev/null) || true
                occurrences="${occurrences:-0}"
                if [[ "$occurrences" -ge 3 ]]; then
                    return 0
                fi
            fi
        fi
    fi

    # Check for git churn: same files being modified repeatedly
    if command -v git >/dev/null 2>&1 && [[ -n "${PROJECT_ROOT:-}" ]]; then
        local churned_files
        churned_files=$(git -C "$PROJECT_ROOT" log --oneline --name-only -10 2>/dev/null \
            | grep -v '^[a-f0-9]' | sort | uniq -c | sort -rn | head -1 | awk '{print $1}' || echo "0")
        churned_files="${churned_files:-0}"
        if [[ "$churned_files" -ge 5 ]] && [[ "$consec" -ge 3 ]]; then
            return 0
        fi
    fi

    return 1
}

# Detect test flakiness: tests alternating pass/fail
# Returns 0 if detected, 1 otherwise
_detect_test_flakiness() {
    local log_dir="${LOG_DIR:-}"
    local iteration="${ITERATION:-0}"

    [[ "$iteration" -lt 3 ]] && return 1

    if [[ -z "$log_dir" ]] || [[ ! -f "$log_dir/progress.md" ]]; then
        return 1
    fi

    # Look for alternating PASSED/FAILED pattern
    local pass_count fail_count
    pass_count=$(grep -c "PASSED" "$log_dir/progress.md" 2>/dev/null) || true
    fail_count=$(grep -c "FAILED" "$log_dir/progress.md" 2>/dev/null) || true
    pass_count="${pass_count:-0}"
    fail_count="${fail_count:-0}"

    # Both passes and fails present (alternating)
    if [[ "$pass_count" -ge 2 ]] && [[ "$fail_count" -ge 2 ]]; then
        return 0
    fi

    # Check for environment-related error keywords
    if [[ -f "$log_dir/error-summary.json" ]]; then
        local error_text
        error_text=$(jq -r '(.error_lines[]? // empty), (.error_summary // "")' "$log_dir/error-summary.json" 2>/dev/null || echo "")
        if echo "$error_text" | grep -qiE "timeout|race condition|ECONNRESET|ECONNREFUSED|flaky|intermittent|ETIMEDOUT" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Detect dependency issue: pre-test failures from missing packages
# Returns 0 if detected, 1 otherwise
_detect_dependency_issue() {
    local log_dir="${LOG_DIR:-}"
    local iteration="${ITERATION:-0}"

    # Dependency issues usually manifest early
    if [[ "$iteration" -gt 5 ]]; then
        return 1
    fi

    if [[ -z "$log_dir" ]]; then
        return 1
    fi

    # Check error-summary.json for dependency patterns
    if [[ -f "$log_dir/error-summary.json" ]]; then
        local error_text
        error_text=$(jq -r '(.error_lines[]? // empty), (.error_summary // "")' "$log_dir/error-summary.json" 2>/dev/null || echo "")

        if echo "$error_text" | grep -qiE "npm ERR|ModuleNotFoundError|Cannot find module|ImportError|no such package|go: module|cargo.*not found|ENOENT.*node_modules|package.*not found|could not resolve|missing dependency" 2>/dev/null; then
            return 0
        fi
    fi

    # Check recent iteration logs for install/resolution failures
    local latest_log="$log_dir/iteration-${iteration}.log"
    if [[ -f "$latest_log" ]]; then
        if grep -qiE "npm ERR|ModuleNotFoundError|Cannot find module|ImportError|pip install|go mod download" "$latest_log" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# ─── Primary Classification ──────────────────────────────────────────────────

# Classify the current loop failure into one of 5 modes
# Checks heuristics in priority order; first match wins
# Always succeeds — falls back to "code_error"
# Output: failure mode string on stdout
classify_loop_failure() {
    local mode="code_error"
    local confidence="low"
    local evidence=""

    # Priority 1: Dependency issue (blocks everything else)
    if _detect_dependency_issue; then
        mode="dependency_issue"
        confidence="high"
        evidence="Pre-test failure with dependency error pattern"
    # Priority 2: Infinite loop (most damaging if not caught)
    elif _detect_infinite_loop; then
        mode="infinite_loop"
        confidence="high"
        evidence="Same error repeating across ${CONSECUTIVE_FAILURES:-0} consecutive failures"
    # Priority 3: Test flakiness (wastes iterations on non-deterministic failures)
    elif _detect_test_flakiness; then
        mode="test_flakiness"
        confidence="medium"
        evidence="Tests alternating pass/fail pattern detected"
    # Priority 4: Context exhaustion (near max iterations with no progress)
    elif _detect_context_exhaustion; then
        mode="context_exhaustion"
        confidence="high"
        evidence="At iteration ${ITERATION:-0}/${MAX_ITERATIONS:-20} with stalled progress"
    fi
    # Default: code_error (standard test/syntax failures)

    # Write classification atomically
    local log_dir="${LOG_DIR:-}"
    if [[ -n "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
        local tmp_file="$log_dir/failure-classification.json.tmp.$$"
        {
            printf '{\n'
            printf '  "classified_at": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            printf '  "iteration": %s,\n' "${ITERATION:-0}"
            printf '  "failure_mode": "%s",\n' "$mode"
            printf '  "confidence": "%s",\n' "$confidence"
            printf '  "evidence": %s,\n' "$(printf '%s' "$evidence" | jq -Rs . 2>/dev/null || printf '"%s"' "$evidence")"
            printf '  "consecutive_failures": %s,\n' "${CONSECUTIVE_FAILURES:-0}"
            printf '  "max_iterations": %s\n' "${MAX_ITERATIONS:-20}"
            printf '}\n'
        } > "$tmp_file" 2>/dev/null
        mv "$tmp_file" "$log_dir/failure-classification.json" 2>/dev/null || rm -f "$tmp_file"
    fi

    echo "$mode"
    return 0
}

# ─── Recovery Strategies ─────────────────────────────────────────────────────

# Get the recovery strategy JSON for a given failure mode
# Input: failure mode string
# Output: JSON object on stdout
get_recovery_strategy() {
    local mode="${1:-code_error}"

    case "$mode" in
        context_exhaustion)
            cat <<'STRATEGY'
{"strategy":"compress_and_restart","priority":"high","actions":["reduce_max_iterations","compress_briefing","boost_restarts"],"description":"Near iteration limit with no progress — compress context and restart with focused briefing"}
STRATEGY
            ;;
        infinite_loop)
            cat <<'STRATEGY'
{"strategy":"break_cycle","priority":"critical","actions":["cap_iterations","escalate_model","force_different_approach"],"description":"Same error repeating — cap iterations, escalate model, force new approach"}
STRATEGY
            ;;
        test_flakiness)
            cat <<'STRATEGY'
{"strategy":"isolate_flaky","priority":"medium","actions":["tag_flaky_tests","no_iteration_penalty","retry_with_isolation"],"description":"Non-deterministic test failures — isolate flaky tests, no iteration penalty"}
STRATEGY
            ;;
        dependency_issue)
            cat <<'STRATEGY'
{"strategy":"fix_dependencies","priority":"high","actions":["run_package_install","clear_caches","no_iteration_penalty"],"description":"Missing dependencies — run package install, clear caches"}
STRATEGY
            ;;
        code_error|*)
            cat <<'STRATEGY'
{"strategy":"standard_restart","priority":"normal","actions":["inject_error_context","standard_restart"],"description":"Standard test/syntax failure — restart with error context injected"}
STRATEGY
            ;;
    esac
    return 0
}

# ─── Recovery Application ────────────────────────────────────────────────────

# Apply recovery for context exhaustion
apply_recovery_context_exhaustion() {
    local log_dir="${LOG_DIR:-}"

    # Reduce max iterations by 20% to avoid hitting same wall
    local new_max=$(( MAX_ITERATIONS * 80 / 100 ))
    [[ "$new_max" -lt 5 ]] && new_max=5
    MAX_ITERATIONS="$new_max"

    # Boost restart count if not already high
    if [[ "${MAX_RESTARTS:-0}" -lt 2 ]]; then
        MAX_RESTARTS=2
    fi

    info "Recovery [context_exhaustion]: reduced MAX_ITERATIONS to $MAX_ITERATIONS, ensured MAX_RESTARTS >= 2"
    return 0
}

# Apply recovery for infinite loop
apply_recovery_infinite_loop() {
    # Cap iterations to prevent further waste
    MAX_ITERATIONS=5

    # Escalate model if not already on opus
    if [[ "${MODEL:-}" != "opus" ]]; then
        MODEL="opus"
        info "Recovery [infinite_loop]: escalated model to opus"
    fi

    info "Recovery [infinite_loop]: capped MAX_ITERATIONS to 5, forcing different approach"
    return 0
}

# Apply recovery for test flakiness
apply_recovery_test_flakiness() {
    local log_dir="${LOG_DIR:-}"

    # Reset consecutive failures — flaky tests shouldn't count
    CONSECUTIVE_FAILURES=0

    # Write a flaky-tests marker for the agent to read
    if [[ -n "$log_dir" ]]; then
        local marker="$log_dir/flaky-tests-detected.marker"
        printf '%s\n' "Flaky tests detected at iteration ${ITERATION:-0}" > "$marker" 2>/dev/null || true
    fi

    info "Recovery [test_flakiness]: reset consecutive failures, marked flaky tests"
    return 0
}

# Apply recovery for dependency issue
apply_recovery_dependency_issue() {
    local project_root="${PROJECT_ROOT:-$(pwd)}"

    # Reset consecutive failures — dependency issues aren't code errors
    CONSECUTIVE_FAILURES=0

    # Attempt to install dependencies based on project type
    local installed=false
    if [[ -f "$project_root/package.json" ]] && command -v npm >/dev/null 2>&1; then
        info "Recovery [dependency_issue]: running npm install..."
        (cd "$project_root" && npm install --no-audit --no-fund 2>/dev/null) && installed=true
    elif [[ -f "$project_root/requirements.txt" ]] && command -v pip >/dev/null 2>&1; then
        info "Recovery [dependency_issue]: running pip install..."
        (cd "$project_root" && pip install -r requirements.txt 2>/dev/null) && installed=true
    elif [[ -f "$project_root/go.mod" ]] && command -v go >/dev/null 2>&1; then
        info "Recovery [dependency_issue]: running go mod download..."
        (cd "$project_root" && go mod download 2>/dev/null) && installed=true
    fi

    if $installed; then
        success "Recovery [dependency_issue]: dependencies installed"
    else
        warn "Recovery [dependency_issue]: could not auto-install dependencies"
    fi

    return 0
}

# Apply recovery for standard code errors
apply_recovery_code_error() {
    # Standard restart — no special adjustments needed
    # Error context is already injected by the restart briefing system
    info "Recovery [code_error]: standard restart with error context"
    return 0
}

# ─── Main Recovery Dispatcher ────────────────────────────────────────────────

# Apply the recovery strategy for a classified failure mode
# Input: failure mode string
# Returns: 0 on success, 1 on failure
apply_loop_recovery() {
    local mode="${1:-code_error}"

    case "$mode" in
        context_exhaustion)  apply_recovery_context_exhaustion ;;
        infinite_loop)       apply_recovery_infinite_loop ;;
        test_flakiness)      apply_recovery_test_flakiness ;;
        dependency_issue)    apply_recovery_dependency_issue ;;
        code_error|*)        apply_recovery_code_error ;;
    esac
}
