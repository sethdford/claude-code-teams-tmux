#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-platform-hygiene — Autonomous Test Gap Filler & Platform Hygiene    ║
# ║  Agent: Scans for test gaps, technical debt, computes metrics, files    ║
# ║  issues. Runs weekly via patrol; reports observability via events.      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Fallback when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift
    mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

METRICS_DIR="${HOME}/.shipwright/hygiene"
METRICS_FILE="${METRICS_DIR}/metrics.json"
HISTORY_FILE="${METRICS_DIR}/history.jsonl"

# ─── is_sourced_only: Classify sourced-only providers ──────────────────────
# Returns 0 if sourced-only (no main() or has "do not call directly")
# Returns 1 if executable
is_sourced_only() {
    local script="$1"
    [[ -f "$script" ]] || return 2

    # Check for "do not call directly" in header
    if head -15 "$script" | grep -qiF "do not call directly"; then
        return 0
    fi

    # Check for set -euo pipefail AND main() definition
    local has_pipefail has_main
    has_pipefail=$(head -5 "$script" | grep -q "set -euo pipefail" && echo 1 || echo 0)
    has_main=$(grep -q "^main()" "$script" && echo 1 || echo 0)

    # If no pipefail AND no main, it's sourced-only
    if [[ "$has_pipefail" -eq 0 && "$has_main" -eq 0 ]]; then
        return 0
    fi

    # Otherwise, it's executable
    return 1
}

# ─── scan_tests: Find untested executable scripts ──────────────────────────
scan_tests() {
    local script_dir="${SCRIPT_DIR:-./scripts}"
    local tested=0 untested=0 total=0
    local untested_list=""

    for script in "$script_dir"/sw-*.sh; do
        [[ -f "$script" ]] || continue

        # Skip test files themselves
        [[ "$script" =~ -test\.sh$ ]] && continue

        local base_name
        base_name=$(basename "$script")

        # Check if it's sourced-only (skip from count)
        if is_sourced_only "$script"; then
            continue
        fi

        total=$((total + 1))

        # Check if test file exists
        local test_file="${script%-test.sh}-test.sh"
        test_file="${script%*.sh}-test.sh"

        if [[ -f "$test_file" ]]; then
            tested=$((tested + 1))
        else
            untested=$((untested + 1))
            untested_list="${untested_list}${base_name}
"
        fi
    done

    # Report results
    echo "Total executable scripts: $total"
    if [[ $total -gt 0 ]]; then
        local pct=$((tested * 100 / total))
        echo "Test coverage: ${pct}% (${tested} tested, ${untested} untested)"
    else
        echo "Test coverage: N/A (no executable scripts found)"
    fi

    if [[ -n "$untested_list" ]]; then
        echo "Untested scripts:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && echo "  ./$line"
        done <<< "$untested_list"
    fi

    # Emit event
    emit_event "hygiene.test_scan" "untested=$untested" "coverage=$([[ $total -gt 0 ]] && echo $((tested * 100 / total)) || echo 0)" "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# ─── scan_debt: Find TODO/FIXME/HACK/KLUDGE markers ────────────────────────
scan_debt() {
    local script_dir="${SCRIPT_DIR:-./scripts}"
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/hygiene-debt.XXXXXX")
    trap "rm -f '$tmpfile'" RETURN

    # Find all debt markers with line numbers and context
    # Format: file:line:marker context
    for script in "$script_dir"/sw-*.sh; do
        [[ -f "$script" ]] || continue
        [[ "$script" =~ -test\.sh$ ]] && continue

        grep -n "TODO\|FIXME\|HACK\|KLUDGE" "$script" 2>/dev/null || true
    done | while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        # Parse: file:lineno:content
        local file lineno content marker weight
        file=$(echo "$line" | cut -d: -f1)
        lineno=$(echo "$line" | cut -d: -f2)
        content=$(echo "$line" | cut -d: -f3-)

        # Extract marker type
        if echo "$content" | grep -q "FIXME\|HACK\|KLUDGE"; then
            weight=2
        else
            weight=1
        fi

        # Extract marker type for sorting
        marker=$(echo "$content" | grep -oE "FIXME|HACK|KLUDGE|TODO" | head -1)

        # Output: weight file line marker content
        echo "$weight|$(basename "$file")|$lineno|$marker|$content" >> "$tmpfile"
    done

    # Sort by weight descending, then by file/line
    local count=0
    local total_debt=0
    if [[ -f "$tmpfile" ]]; then
        sort -t'|' -k1nr -k2 -k3n "$tmpfile" | while IFS='|' read -r weight file line marker content; do
            [[ -n "$weight" ]] || continue
            count=$((count + 1))
            total_debt=$((total_debt + 1))

            if [[ $count -le 25 ]]; then
                echo "$file:$line: [$marker] $content"
            fi
        done

        # Count total
        if [[ $total_debt -gt 25 ]]; then
            local omitted=$((total_debt - 25))
            echo ""
            echo "[$omitted more debt items omitted from output — see metrics]"
        fi
    fi

    emit_event "hygiene.scan_debt" "debt_count=$total_debt" "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# ─── metrics: Compute and persist metrics snapshots ────────────────────────
metrics() {
    mkdir -p "$METRICS_DIR"

    # Get current test coverage
    local script_dir="${SCRIPT_DIR:-./scripts}"
    local tested=0 untested=0 total=0
    for script in "$script_dir"/sw-*.sh; do
        [[ -f "$script" ]] || continue
        [[ "$script" =~ -test\.sh$ ]] && continue
        if is_sourced_only "$script"; then
            continue
        fi
        total=$((total + 1))
        local test_file="${script%*.sh}-test.sh"
        if [[ -f "$test_file" ]]; then
            tested=$((tested + 1))
        else
            untested=$((untested + 1))
        fi
    done

    # Get current debt count — count raw markers directly (accurate, not capped
    # at scan_debt's 25-item display limit). Avoids the `grep -c || echo 0`
    # double-output pitfall by using `|| true` + ${var:-0} per-file.
    local debt_count=0
    for script in "$script_dir"/sw-*.sh; do
        [[ -f "$script" ]] || continue
        [[ "$script" =~ -test\.sh$ ]] && continue
        local marker_count
        marker_count=$(grep -c "TODO\|FIXME\|HACK\|KLUDGE" "$script" 2>/dev/null || true)
        debt_count=$((debt_count + ${marker_count:-0}))
    done

    # Calculate coverage percentage
    local coverage_pct=0
    [[ $total -gt 0 ]] && coverage_pct=$((tested * 100 / total))

    # Read previous metrics for delta
    local prev_coverage=0 prev_debt=0
    if [[ -f "$METRICS_FILE" ]]; then
        prev_coverage=$(grep -o '"coverage_pct":[0-9]*' "$METRICS_FILE" | cut -d: -f2 || echo 0)
        prev_debt=$(grep -o '"debt_count":[0-9]*' "$METRICS_FILE" | cut -d: -f2 || echo 0)
    fi

    local coverage_delta=0 debt_delta=0
    coverage_delta=$((coverage_pct - prev_coverage))
    debt_delta=$((debt_count - prev_debt))

    # Write metrics atomically
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/metrics.XXXXXX")
    trap "rm -f '$tmpfile'" RETURN

    cat > "$tmpfile" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "coverage_pct": $coverage_pct,
  "coverage_delta": $coverage_delta,
  "debt_count": $debt_count,
  "debt_delta": $debt_delta,
  "tested_count": $tested,
  "untested_count": $untested,
  "total_count": $total
}
EOF

    if mv "$tmpfile" "$METRICS_FILE" 2>/dev/null; then
        # Append to history
        local trend_direction="stable"
        [[ $coverage_delta -gt 0 ]] && trend_direction="improving"
        [[ $coverage_delta -lt 0 ]] && trend_direction="degrading"

        echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"coverage\":$coverage_pct,\"debt\":$debt_count,\"trend\":\"$trend_direction\"}" >> "$HISTORY_FILE"

        emit_event "hygiene.metrics" "coverage=$coverage_pct" "debt_count=$debt_count" "trend_direction=$trend_direction"
        return 0
    else
        error "Failed to write metrics file"
        return 2
    fi
}

# ─── file_issues: Create deduped GitHub issues ─────────────────────────────
file_issues() {
    [[ "$NO_GITHUB" != "true" ]] || {
        info "NO_GITHUB mode: would create hygiene issues (dry-run)"
        return 0
    }

    # Check GitHub auth
    if ! gh auth status &>/dev/null; then
        warn "GitHub not authenticated; skipping issue creation"
        return 0
    fi

    local script_dir="${SCRIPT_DIR:-./scripts}"

    # Find untested scripts and create issues
    for script in "$script_dir"/sw-*.sh; do
        [[ -f "$script" ]] || continue
        [[ "$script" =~ -test\.sh$ ]] && continue

        if is_sourced_only "$script"; then
            continue
        fi

        local base_name
        base_name=$(basename "$script")
        local test_file="${script%*.sh}-test.sh"

        if [[ ! -f "$test_file" ]]; then
            # Check for existing issue
            local title="[Meta] Add tests for $base_name"
            if gh issue list --search "$title" --state open --json title --jq '.[].title' 2>/dev/null | grep -qF "$title"; then
                info "[dedup] Issue already exists for $base_name"
            else
                # Create issue
                local body="Script \`$base_name\` lacks a test suite.

**File:** \`${script#$REPO_DIR/}\`

**Action:** Write \`${test_file#$REPO_DIR/}\` following existing test patterns.

**Acceptance criteria:**
- [ ] Test covers happy path and at least 1 error case
- [ ] Test suite integrates into \`npm test\`
- [ ] 70%+ line coverage on tested functions"

                if gh issue create --title "$title" --body "$body" --label "auto-patrol,meta-improvement" 2>/dev/null; then
                    success "Created issue for $base_name"
                    emit_event "hygiene.issue_created" "script=$base_name"
                else
                    warn "Failed to create issue for $base_name"
                fi
            fi
        fi
    done
}

# ─── report: Human-readable summary ────────────────────────────────────────
report() {
    info "Platform Hygiene Report"
    echo ""

    # Read current metrics
    if [[ -f "$METRICS_FILE" ]]; then
        local coverage debt trend
        coverage=$(grep -o '"coverage_pct":[0-9]*' "$METRICS_FILE" | cut -d: -f2 || echo 0)
        debt=$(grep -o '"debt_count":[0-9]*' "$METRICS_FILE" | cut -d: -f2 || echo 0)
        local delta
        delta=$(grep -o '"coverage_delta":-\?[0-9]*' "$METRICS_FILE" | cut -d: -f2 || echo 0)

        if [[ $delta -gt 0 ]]; then
            trend="improving"
        elif [[ $delta -lt 0 ]]; then
            trend="degrading"
        else
            trend="stable"
        fi

        echo "Test Coverage: ${coverage}% (trend: ${trend} ${delta:+($delta)})"
        echo "Technical Debt: ${debt} items"
        echo ""
    fi

    # Show top debt
    info "Top debt items:"
    scan_debt | head -5
}

# ─── auto: Orchestrate all operations ──────────────────────────────────────
auto() {
    info "Running platform hygiene checks..."
    echo ""

    scan_tests
    echo ""

    scan_debt
    echo ""

    metrics
    echo ""

    report
    echo ""

    [[ "$NO_GITHUB" != "true" ]] && file_issues
}

# ─── help ──────────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
${CYAN}${BOLD}sw-platform-hygiene${RESET} v${VERSION} — Test Gap Filler & Platform Hygiene Agent

${BOLD}USAGE${RESET}
  sw-platform-hygiene <subcommand> [options]

${BOLD}SUBCOMMANDS${RESET}
  scan-tests        Find scripts without test suites
  scan-debt         Detect TODO/FIXME/HACK/KLUDGE markers
  metrics           Compute and persist coverage metrics
  report            Human-readable hygiene summary
  auto              Run all checks (scan → metrics → issues)
  help              Show this help
  --version         Show version

${BOLD}EXAMPLES${RESET}
  sw-platform-hygiene scan-tests
  sw-platform-hygiene auto
  NO_GITHUB=true sw-platform-hygiene auto

${BOLD}ENVIRONMENT${RESET}
  NO_GITHUB=true    Disable GitHub API calls (dry-run mode)
  SCRIPT_DIR        Scripts directory to scan (default: ./scripts)

EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN DISPATCH
# ═══════════════════════════════════════════════════════════════════════════════

case "${1:-auto}" in
    scan-tests)
        scan_tests
        ;;
    scan-debt)
        scan_debt
        ;;
    metrics)
        metrics
        ;;
    report)
        report
        ;;
    auto)
        auto
        ;;
    help)
        show_help
        ;;
    --version)
        echo "sw-platform-hygiene $VERSION"
        ;;
    *)
        error "Unknown subcommand: $1"
        show_help
        exit 1
        ;;
esac
