#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#   preflight-scope.sh — Issue Scope Hard Limit Pre-Flight Validator
#   Rejects over-scoped issues before pipeline execution begins.
#   Source guard: sourcing this file twice is a no-op.
# ═══════════════════════════════════════════════════════════════════
[[ -n "${_MODULE_PREFLIGHT_SCOPE_LOADED:-}" ]] && return 0
_MODULE_PREFLIGHT_SCOPE_LOADED=1

VERSION="3.2.4"

# Ensure helpers are available (caller should have sourced them)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo "$*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo "$*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo "$*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }
[[ "$(type -t _config_get 2>/dev/null)" == "function" ]] || _config_get() { echo "${2:-}"; }
[[ "$(type -t _config_get_int 2>/dev/null)" == "function" ]] || _config_get_int() { echo "${2:-0}"; }
[[ "$(type -t _config_get_bool 2>/dev/null)" == "function" ]] || _config_get_bool() { [[ "${2:-true}" == "true" ]]; }
[[ "$(type -t now_iso 2>/dev/null)" == "function" ]] || now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ─── File Count Estimation ───────────────────────────────────────
# Estimates number of files an issue will touch from its body text.
# Returns: integer on stdout
preflight_estimate_file_count() {
    local body="$1"
    [[ -z "$body" ]] && { echo "0"; return 0; }

    local count=0

    # Count file path patterns (e.g., src/foo.ts, scripts/bar.sh)
    local path_count=0
    path_count=$(echo "$body" | grep -oE '[a-zA-Z0-9_-]+/[a-zA-Z0-9_./-]+\.[a-zA-Z]{1,6}' | sort -u | wc -l) || true
    path_count=$(echo "$path_count" | tr -d ' ')
    count=$((count + path_count))

    # Check for explicit "N files" references
    local explicit_count=0
    explicit_count=$(echo "$body" | grep -oiE '(across|modify|change|touch|update|edit) +[0-9]+ +(files|scripts|modules)' | head -1 | grep -oE '[0-9]+' | head -1) || true
    if [[ -n "$explicit_count" && "$explicit_count" -gt "$count" ]]; then
        count="$explicit_count"
    fi

    # Fallback: long body with no explicit count suggests broad scope
    local line_count=0
    line_count=$(echo "$body" | wc -l) || true
    line_count=$(echo "$line_count" | tr -d ' ')
    if [[ "$count" -eq 0 && "$line_count" -gt 300 ]]; then
        count=10
    fi

    echo "$count"
}

# ─── Complexity Estimation ───────────────────────────────────────
# Estimates issue complexity on a 1-10 scale.
# Uses INTELLIGENCE_COMPLEXITY env var when available (from daemon triage).
# Returns: integer on stdout
preflight_estimate_complexity() {
    local body="$1"
    local labels="${2:-}"

    # Use intelligence-provided complexity if available
    if [[ -n "${INTELLIGENCE_COMPLEXITY:-}" ]]; then
        local ic="${INTELLIGENCE_COMPLEXITY}"
        # Clamp 1-10
        [[ "$ic" -lt 1 ]] && ic=1
        [[ "$ic" -gt 10 ]] && ic=10
        echo "$ic"
        return 0
    fi

    [[ -z "$body" ]] && { echo "1"; return 0; }

    # Base score from body length
    local line_count=0
    line_count=$(echo "$body" | wc -l) || true
    line_count=$(echo "$line_count" | tr -d ' ')

    local score=2
    if [[ "$line_count" -ge 500 ]]; then
        score=9
    elif [[ "$line_count" -ge 300 ]]; then
        score=7
    elif [[ "$line_count" -ge 200 ]]; then
        score=5
    elif [[ "$line_count" -ge 100 ]]; then
        score=3
    fi

    # Keyword boost (max +3)
    local boost=0
    local keyword
    for keyword in "refactor across" "breaking change" "migration" "cross-cutting" "rewrite" "redesign"; do
        if echo "$body" | grep -qi "$keyword"; then
            boost=$((boost + 1))
        fi
    done
    [[ "$boost" -gt 3 ]] && boost=3
    score=$((score + boost))

    # Label signals
    local label_lower
    label_lower=$(echo "$labels" | tr '[:upper:]' '[:lower:]')
    for keyword in "complex" "epic" "large"; do
        if echo "$label_lower" | grep -q "$keyword"; then
            score=$((score + 2))
            break
        fi
    done
    for keyword in "typo" "docs" "simple" "chore"; do
        if echo "$label_lower" | grep -q "$keyword"; then
            score=$((score - 2))
            break
        fi
    done

    # Clamp 1-10
    [[ "$score" -lt 1 ]] && score=1
    [[ "$score" -gt 10 ]] && score=10

    echo "$score"
}

# ─── Scope Validation ─────────────────────────────────────────────
# Main validator: checks issue against configured scope limits.
# Returns 0 on pass, 1 on rejection.
preflight_scope_validate() {
    local issue_number="${1:-}"
    local issue_body="${2:-}"
    local issue_labels="${3:-}"

    # Load config
    local enabled max_files max_complexity max_body_lines
    enabled=$(_config_get "preflight_scope.enabled" "true")
    max_files=$(_config_get_int "preflight_scope.max_files_changed" 15)
    max_complexity=$(_config_get_int "preflight_scope.max_complexity_score" 8)
    max_body_lines=$(_config_get_int "preflight_scope.max_body_lines" 500)

    # Short-circuit if disabled
    if [[ "$enabled" == "false" ]]; then
        return 0
    fi

    # Short-circuit if no body to analyze
    if [[ -z "$issue_body" ]]; then
        return 0
    fi

    # Run estimations
    local est_files est_complexity body_lines
    est_files=$(preflight_estimate_file_count "$issue_body")
    est_complexity=$(preflight_estimate_complexity "$issue_body" "$issue_labels")
    body_lines=$(echo "$issue_body" | wc -l)
    body_lines=$(echo "$body_lines" | tr -d ' ')

    # Check limits (skip when limit is 0)
    local violations=""
    local violation_count=0

    if [[ "$max_files" -gt 0 && "$est_files" -gt "$max_files" ]]; then
        violations="${violations}files_changed: estimated ${est_files} > limit ${max_files}; "
        violation_count=$((violation_count + 1))
    fi

    if [[ "$max_complexity" -gt 0 && "$est_complexity" -gt "$max_complexity" ]]; then
        violations="${violations}complexity_score: estimated ${est_complexity} > limit ${max_complexity}; "
        violation_count=$((violation_count + 1))
    fi

    if [[ "$max_body_lines" -gt 0 && "$body_lines" -gt "$max_body_lines" ]]; then
        violations="${violations}body_lines: ${body_lines} > limit ${max_body_lines}; "
        violation_count=$((violation_count + 1))
    fi

    if [[ "$violation_count" -gt 0 ]]; then
        # Build rejection JSON
        local rejection_json
        rejection_json=$(jq -n \
            --arg issue "$issue_number" \
            --arg ts "$(now_iso)" \
            --argjson est_files "$est_files" \
            --argjson est_complexity "$est_complexity" \
            --argjson body_lines "$body_lines" \
            --argjson max_files "$max_files" \
            --argjson max_complexity "$max_complexity" \
            --argjson max_body_lines "$max_body_lines" \
            --arg violations "$violations" \
            '{
                issue: $issue,
                timestamp: $ts,
                result: "rejected",
                estimated_files: $est_files,
                estimated_complexity: $est_complexity,
                body_lines: $body_lines,
                limits: {
                    max_files_changed: $max_files,
                    max_complexity_score: $max_complexity,
                    max_body_lines: $max_body_lines
                },
                violations: $violations
            }') || rejection_json="{\"issue\":\"$issue_number\",\"result\":\"rejected\"}"

        # Call rejection handler
        preflight_scope_reject "$issue_number" "$rejection_json"
        return 1
    fi

    # Pass
    emit_event "pipeline.preflight_scope_passed" \
        "issue=$issue_number" \
        "est_files=$est_files" \
        "complexity=$est_complexity" \
        "body_lines=$body_lines"
    return 0
}

# ─── Rejection Handler ─────────────────────────────────────────────
# Side effects: writes artifact, emits event, optionally comments on GitHub issue.
preflight_scope_reject() {
    local issue_number="$1"
    local rejection_json="$2"

    local est_files est_complexity body_lines violations
    est_files=$(echo "$rejection_json" | jq -r '.estimated_files // 0') || est_files=0
    est_complexity=$(echo "$rejection_json" | jq -r '.estimated_complexity // 0') || est_complexity=0
    body_lines=$(echo "$rejection_json" | jq -r '.body_lines // 0') || body_lines=0
    violations=$(echo "$rejection_json" | jq -r '.violations // ""') || violations=""

    # Write rejection artifact atomically
    local artifacts_dir="${ARTIFACTS_DIR:-${STATE_DIR:-.claude}/pipeline-artifacts}"
    mkdir -p "$artifacts_dir" 2>/dev/null || true
    local tmp_file
    tmp_file=$(mktemp "${artifacts_dir}/preflight-rejection.XXXXXX") || true
    if [[ -n "$tmp_file" ]]; then
        echo "$rejection_json" > "$tmp_file"
        mv "$tmp_file" "${artifacts_dir}/preflight-rejection.json" 2>/dev/null || true
    fi

    error "Issue #${issue_number} exceeds scope limits — auto-rejected"
    error "  Violations: $violations"
    error "  Estimated files: $est_files | Complexity: $est_complexity/10 | Body lines: $body_lines"
    error "  Bypass: --skip-preflight or set preflight_scope.enabled=false"

    # Emit rejection event
    emit_event "pipeline.preflight_scope_rejected" \
        "issue=$issue_number" \
        "est_files=$est_files" \
        "complexity=$est_complexity" \
        "body_lines=$body_lines" \
        "violations=$violations"

    # GitHub feedback (best-effort)
    if [[ "${NO_GITHUB:-false}" != "true" ]] && command -v gh >/dev/null 2>&1 && [[ -n "$issue_number" ]]; then
        local comment_body
        comment_body=$(cat <<GHEOF
## Preflight Scope Check: Rejected

This issue **exceeds automated scope limits** and cannot be processed by the pipeline without decomposition.

| Metric | Estimated | Limit |
|--------|-----------|-------|
| Files changed | $est_files | $(_config_get_int "preflight_scope.max_files_changed" 15) |
| Complexity | $est_complexity/10 | $(_config_get_int "preflight_scope.max_complexity_score" 8)/10 |
| Body lines | $body_lines | $(_config_get_int "preflight_scope.max_body_lines" 500) |

**Violations:** $violations

### Next Steps
1. Use \`shipwright decompose --issue $issue_number\` to split into smaller tasks
2. Or override with \`shipwright pipeline start --issue $issue_number --skip-preflight\`
3. Or adjust limits in \`daemon-config.json\` under \`preflight_scope\`
GHEOF
)
        gh issue comment "$issue_number" --body "$comment_body" 2>/dev/null || true
        gh issue edit "$issue_number" --add-label "preflight-rejected" 2>/dev/null || true
        gh issue edit "$issue_number" --remove-label "shipwright" 2>/dev/null || true
    fi

    # Update pipeline state if available
    if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE:-/dev/null}" ]]; then
        local tmp_state
        tmp_state=$(mktemp) || true
        if [[ -n "$tmp_state" ]]; then
            sed 's/^status: .*/status: rejected/' "$STATE_FILE" > "$tmp_state" 2>/dev/null || true
            mv "$tmp_state" "$STATE_FILE" 2>/dev/null || true
        fi
    fi
}
