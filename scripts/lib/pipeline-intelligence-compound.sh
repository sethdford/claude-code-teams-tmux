# pipeline-intelligence-compound.sh — DoD/security/compound audit for pipeline-intelligence.sh
# Source from pipeline-intelligence.sh. Requires state, ARTIFACTS_DIR.
[[ -n "${_PIPELINE_INTELLIGENCE_COMPOUND_LOADED:-}" ]] && return 0
_PIPELINE_INTELLIGENCE_COMPOUND_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.."/bin/pwd)}"
NO_GITHUB="${NO_GITHUB:-false}"

pipeline_verify_dod() {
    local artifacts_dir="${1:-$ARTIFACTS_DIR}"
    local checks_total=0 checks_passed=0
    local results=""

    # 1. Test coverage: verify changed source files have test counterparts
    local changed_files
    changed_files=$(git diff --name-only "${BASE_BRANCH:-main}...HEAD" 2>/dev/null || true)
    local missing_tests=""
    local files_checked=0

    if [[ -n "$changed_files" ]]; then
        while IFS= read -r src_file; do
            [[ -z "$src_file" ]] && continue
            # Only check source code files
            case "$src_file" in
                *.ts|*.js|*.tsx|*.jsx|*.py|*.go|*.rs|*.sh)
                    # Skip test files themselves and config files
                    case "$src_file" in
                        *test*|*spec*|*__tests__*|*.config.*|*.d.ts) continue ;;
                    esac
                    files_checked=$((files_checked + 1))
                    checks_total=$((checks_total + 1))
                    # Check for corresponding test file
                    local base_name dir_name ext
                    base_name=$(basename "$src_file")
                    dir_name=$(dirname "$src_file")
                    ext="${base_name##*.}"
                    local stem="${base_name%.*}"
                    local test_found=false
                    # Common test file patterns
                    for pattern in \
                        "${dir_name}/${stem}.test.${ext}" \
                        "${dir_name}/${stem}.spec.${ext}" \
                        "${dir_name}/__tests__/${stem}.test.${ext}" \
                        "${dir_name}/${stem}-test.${ext}" \
                        "${dir_name}/test_${stem}.${ext}" \
                        "${dir_name}/${stem}_test.${ext}"; do
                        if [[ -f "$pattern" ]]; then
                            test_found=true
                            break
                        fi
                    done
                    if $test_found; then
                        checks_passed=$((checks_passed + 1))
                    else
                        missing_tests="${missing_tests}${src_file}\n"
                    fi
                    ;;
            esac
        done <<EOF
$changed_files
EOF
    fi

    # 2. Test-added verification: if significant logic added, ensure tests were also added
    local logic_lines=0 test_lines=0
    if [[ -n "$changed_files" ]]; then
        local full_diff
        full_diff=$(git diff "${BASE_BRANCH:-main}...HEAD" 2>/dev/null || true)
        if [[ -n "$full_diff" ]]; then
            # Count added lines matching source patterns (rough heuristic)
            logic_lines=$(echo "$full_diff" | grep -cE '^\+.*(function |class |if |for |while |return |export )' 2>/dev/null || true)
            logic_lines="${logic_lines:-0}"
            # Count added lines in test files
            test_lines=$(echo "$full_diff" | grep -cE '^\+.*(it\(|test\(|describe\(|expect\(|assert|def test_|func Test)' 2>/dev/null || true)
            test_lines="${test_lines:-0}"
        fi
    fi
    checks_total=$((checks_total + 1))
    local test_ratio_passed=true
    if [[ "$logic_lines" -gt 20 && "$test_lines" -eq 0 ]]; then
        test_ratio_passed=false
        warn "DoD verification: ${logic_lines} logic lines added but no test lines detected"
    else
        checks_passed=$((checks_passed + 1))
    fi

    # 3. Behavioral verification: check DoD audit artifacts for evidence
    local dod_audit_file="$artifacts_dir/dod-audit.md"
    local dod_verified=0 dod_total_items=0
    if [[ -f "$dod_audit_file" ]]; then
        # Count items marked as passing
        dod_total_items=$(grep -cE '^\s*-\s*\[x\]' "$dod_audit_file" 2>/dev/null || true)
        dod_total_items="${dod_total_items:-0}"
        local dod_failing
        dod_failing=$(grep -cE '^\s*-\s*\[\s\]' "$dod_audit_file" 2>/dev/null || true)
        dod_failing="${dod_failing:-0}"
        dod_verified=$dod_total_items
        checks_total=$((checks_total + dod_total_items + ${dod_failing:-0}))
        checks_passed=$((checks_passed + dod_total_items))
    fi

    # Compute pass rate
    local pass_rate=100
    if [[ "$checks_total" -gt 0 ]]; then
        pass_rate=$(( (checks_passed * 100) / checks_total ))
    fi

    # Write results
    local tmp_result
    tmp_result=$(mktemp)
    jq -n \
        --argjson checks_total "$checks_total" \
        --argjson checks_passed "$checks_passed" \
        --argjson pass_rate "$pass_rate" \
        --argjson files_checked "$files_checked" \
        --arg missing_tests "$(echo -e "$missing_tests" | head -20)" \
        --argjson logic_lines "$logic_lines" \
        --argjson test_lines "$test_lines" \
        --argjson test_ratio_passed "$test_ratio_passed" \
        --argjson dod_verified "$dod_verified" \
        '{
            checks_total: $checks_total,
            checks_passed: $checks_passed,
            pass_rate: $pass_rate,
            files_checked: $files_checked,
            missing_tests: ($missing_tests | split("\n") | map(select(. != ""))),
            logic_lines: $logic_lines,
            test_lines: $test_lines,
            test_ratio_passed: $test_ratio_passed,
            dod_verified: $dod_verified
        }' > "$tmp_result" 2>/dev/null
    mv "$tmp_result" "$artifacts_dir/dod-verification.json"

    emit_event "pipeline.dod_verification" \
        "issue=${ISSUE_NUMBER:-0}" \
        "checks_total=$checks_total" \
        "checks_passed=$checks_passed" \
        "pass_rate=$pass_rate"

    # Fail if pass rate < 70%
    if [[ "$pass_rate" -lt 70 ]]; then
        warn "DoD verification: ${pass_rate}% pass rate (${checks_passed}/${checks_total} checks)"
        return 1
    fi

    success "DoD verification: ${pass_rate}% pass rate (${checks_passed}/${checks_total} checks)"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Source Code Security Scan
# Grep-based vulnerability pattern matching on changed files.

pipeline_security_source_scan() {
    local base_branch="${1:-${BASE_BRANCH:-main}}"
    local findings="[]"
    local finding_count=0

    local changed_files
    changed_files=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || true)
    [[ -z "$changed_files" ]] && { echo "[]"; return 0; }

    local tmp_findings
    tmp_findings=$(mktemp)
    echo "[]" > "$tmp_findings"

    while IFS= read -r file; do
        [[ -z "$file" || ! -f "$file" ]] && continue
        # Only scan code files
        case "$file" in
            *.ts|*.js|*.tsx|*.jsx|*.py|*.go|*.rs|*.java|*.rb|*.php|*.sh) ;;
            *) continue ;;
        esac

        # SQL injection patterns
        local sql_matches
        sql_matches=$(grep -nE '(query|execute|sql)\s*\(?\s*[`"'"'"']\s*.*\$\{|\.query\s*\(\s*[`"'"'"'].*\+' "$file" 2>/dev/null || true)
        if [[ -n "$sql_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "sql_injection" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential SQL injection via string concatenation"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<SQLEOF
$sql_matches
SQLEOF
        fi

        # XSS patterns
        local xss_matches
        xss_matches=$(grep -nE 'innerHTML\s*=|document\.write\s*\(|dangerouslySetInnerHTML' "$file" 2>/dev/null || true)
        if [[ -n "$xss_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "xss" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential XSS via unsafe DOM manipulation"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<XSSEOF
$xss_matches
XSSEOF
        fi

        # Command injection patterns
        local cmd_matches
        cmd_matches=$(grep -nE 'eval\s*\(|child_process|os\.system\s*\(|subprocess\.(call|run|Popen)\s*\(' "$file" 2>/dev/null || true)
        if [[ -n "$cmd_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "command_injection" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential command injection via unsafe execution"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<CMDEOF
$cmd_matches
CMDEOF
        fi

        # Hardcoded secrets patterns
        local secret_matches
        secret_matches=$(grep -nEi '(password|api_key|secret|token)\s*=\s*['"'"'"][A-Za-z0-9+/=]{8,}['"'"'"]' "$file" 2>/dev/null || true)
        if [[ -n "$secret_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "hardcoded_secret" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential hardcoded secret or credential"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<SECEOF
$secret_matches
SECEOF
        fi

        # Insecure crypto patterns
        local crypto_matches
        crypto_matches=$(grep -nE '(md5|MD5|sha1|SHA1)\s*\(' "$file" 2>/dev/null || true)
        if [[ -n "$crypto_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "insecure_crypto" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"major","description":"Weak cryptographic function (consider SHA-256+)"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<CRYEOF
$crypto_matches
CRYEOF
        fi
    done <<FILESEOF
$changed_files
FILESEOF

    # Write to artifacts and output
    findings=$(cat "$tmp_findings")
    rm -f "$tmp_findings"

    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        local tmp_scan
        tmp_scan=$(mktemp)
        echo "$findings" > "$tmp_scan"
        mv "$tmp_scan" "$ARTIFACTS_DIR/security-source-scan.json"
    fi

    emit_event "pipeline.security_source_scan" \
        "issue=${ISSUE_NUMBER:-0}" \
        "findings=$finding_count"

    echo "$finding_count"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Quality Score Recording
# Writes quality scores to JSONL for learning.

compound_rebuild_with_feedback() {
    local feedback_file="$ARTIFACTS_DIR/quality-feedback.md"

    # ── Intelligence: classify findings and determine routing ──
    local route="correctness"
    route=$(classify_quality_findings 2>/dev/null) || route="correctness"

    # ── Build structured findings JSON alongside markdown ──
    local structured_findings="[]"
    local s_total_critical=0 s_total_major=0 s_total_minor=0

    if [[ -f "$ARTIFACTS_DIR/classified-findings.json" ]]; then
        s_total_critical=$(jq -r '.security // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
        s_total_major=$(jq -r '.correctness // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
        s_total_minor=$(jq -r '.style // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
    fi

    local tmp_qf
    tmp_qf="$(mktemp)"
    jq -n \
        --arg route "$route" \
        --argjson total_critical "$s_total_critical" \
        --argjson total_major "$s_total_major" \
        --argjson total_minor "$s_total_minor" \
        '{route: $route, total_critical: $total_critical, total_major: $total_major, total_minor: $total_minor}' \
        > "$tmp_qf" 2>/dev/null && mv "$tmp_qf" "$ARTIFACTS_DIR/quality-findings.json" || rm -f "$tmp_qf"

    # ── Architecture route: backtrack to design instead of rebuild ──
    if [[ "$route" == "architecture" ]]; then
        info "Architecture-level findings detected — attempting backtrack to design"
        if pipeline_backtrack_to_stage "design" "architecture_violation" 2>/dev/null; then
            return 0
        fi
        # Backtrack failed or already used — fall through to standard rebuild
        warn "Backtrack unavailable — falling through to standard rebuild"
    fi

    # Collect all findings (prioritized by classification)
    {
        echo "# Quality Feedback — Issues to Fix"
        echo ""

        # Security findings first (highest priority)
        if [[ "$route" == "security" || -f "$ARTIFACTS_DIR/security-audit.log" ]] && grep -qiE 'critical|high' "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null; then
            echo "## 🔴 PRIORITY: Security Findings (fix these first)"
            cat "$ARTIFACTS_DIR/security-audit.log"
            echo ""
            echo "Security issues MUST be resolved before any other changes."
            echo ""
        fi

        # Correctness findings
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
            echo "## Adversarial Review Findings"
            cat "$ARTIFACTS_DIR/adversarial-review.md"
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/negative-review.md" ]]; then
            echo "## Negative Prompting Concerns"
            cat "$ARTIFACTS_DIR/negative-review.md"
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/dod-audit.md" ]]; then
            echo "## DoD Audit Failures"
            grep "❌" "$ARTIFACTS_DIR/dod-audit.md" 2>/dev/null || true
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/api-compat.log" ]] && grep -qi 'BREAKING' "$ARTIFACTS_DIR/api-compat.log" 2>/dev/null; then
            echo "## API Breaking Changes"
            cat "$ARTIFACTS_DIR/api-compat.log"
            echo ""
        fi

        # Style findings last (deprioritized, informational)
        if [[ -f "$ARTIFACTS_DIR/classified-findings.json" ]]; then
            local style_count
            style_count=$(jq -r '.style // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
            if [[ "$style_count" -gt 0 ]]; then
                echo "## Style Notes (non-blocking, address if time permits)"
                echo "${style_count} style suggestions found. These do not block the build."
                echo ""
            fi
        fi
    } > "$feedback_file"

    # Validate feedback file has actual content
    if [[ ! -s "$feedback_file" ]]; then
        warn "No quality feedback collected — skipping rebuild"
        return 1
    fi

    # Reset build/test stages
    set_stage_status "build" "pending"
    set_stage_status "test" "pending"
    set_stage_status "review" "pending"

    # Augment GOAL with quality feedback (route-specific instructions)
    local original_goal="$GOAL"
    local feedback_content
    feedback_content=$(cat "$feedback_file")

    local route_instruction=""
    case "$route" in
        security)
            route_instruction="SECURITY PRIORITY: Fix all security vulnerabilities FIRST, then address other issues. Security issues are BLOCKING."
            ;;
        performance)
            route_instruction="PERFORMANCE PRIORITY: Address performance regressions and optimizations. Check for N+1 queries, memory leaks, and algorithmic complexity."
            ;;
        testing)
            route_instruction="TESTING PRIORITY: Add missing test coverage and fix flaky tests before addressing other issues."
            ;;
        correctness)
            route_instruction="Fix every issue listed above while keeping all existing functionality working."
            ;;
        architecture)
            route_instruction="ARCHITECTURE: Fix structural issues. Check dependency direction, layer boundaries, and separation of concerns."
            ;;
        *)
            route_instruction="Fix every issue listed above while keeping all existing functionality working."
            ;;
    esac

    GOAL="$GOAL

IMPORTANT — Compound quality review found issues (route: ${route}). Fix ALL of these:
$feedback_content

${route_instruction}"

    # Re-run self-healing build→test
    info "Rebuilding with quality feedback (route: ${route})..."
    if self_healing_build_test; then
        GOAL="$original_goal"
        return 0
    else
        GOAL="$original_goal"
        return 1
    fi
}
