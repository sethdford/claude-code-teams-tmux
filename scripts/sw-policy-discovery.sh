#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright policy-discovery — Systematic Hardcoded Policy Discovery      ║
# ║  Identify and migrate hardcoded policies to config files                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -eo pipefail

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Paths ─────────────────────────────────────────────────────────────────
REPO_DIR="${PWD}"
ARTIFACTS_DIR="${REPO_DIR}/.claude/pipeline-artifacts"
REPORT_FILE="${ARTIFACTS_DIR}/discovery-report.json"
FINDINGS_FILE="${ARTIFACTS_DIR}/findings.jsonl"

# ─── Output helpers ──────────────────────────────────────────────────────────
info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ─── Main scanner using find + sed + awk ──────────────────────────────────
cmd_scan() {
    info "Scanning for hardcoded values..."

    mkdir -p "$ARTIFACTS_DIR"
    rm -f "$FINDINGS_FILE"

    local count=0

    # Scan each script file for hardcoded values
    find "$SCRIPT_DIR" -name "*.sh" -type f ! -name "*-test.sh" | while read -r file; do
        relfile="${file#$REPO_DIR/}"

        # Scan for assignments, timeouts, comparisons
        # Use sed to prepend filename:line, then awk to extract values
        {
            # Assignments: VAR=123
            grep -nE "^[[:space:]]*(local[[:space:]]+)?[A-Z_][A-Z0-9_]*=[0-9]+" "$file" 2>/dev/null | \
            while IFS= read -r line; do
                linenum="${line%%:*}"
                content="${line#*:}"
                value=$(echo "$content" | grep -oE "[0-9]+" | head -1)
                [[ -n "$value" ]] && echo -e "$relfile\t$linenum\t$value\tassignment\t4"
            done

            # Timeouts: sleep N, timeout N
            grep -nE "(sleep|timeout)[[:space:]]+[0-9]+" "$file" 2>/dev/null | \
            while IFS= read -r line; do
                linenum="${line%%:*}"
                content="${line#*:}"
                value=$(echo "$content" | grep -oE "[0-9]+" | head -1)
                [[ -n "$value" ]] && echo -e "$relfile\t$linenum\t$value\ttimeout\t5"
            done

            # Comparisons: -gt 100
            grep -nE "[[:space:]](-gt|-lt|-ge|-le)[[:space:]]+[0-9]+" "$file" 2>/dev/null | \
            while IFS= read -r line; do
                linenum="${line%%:*}"
                content="${line#*:}"
                value=$(echo "$content" | grep -oE "[0-9]+" | head -1)
                [[ -n "$value" ]] && echo -e "$relfile\t$linenum\t$value\tcomparison\t3"
            done
        } >> "$FINDINGS_FILE"
    done

    # Count findings
    local count=$(wc -l < "$FINDINGS_FILE" 2>/dev/null || echo 0)
    success "Scanned $count hardcoded values"
    [[ $count -eq 0 ]] && warn "No findings detected"
}

# ─── Report Generator ──────────────────────────────────────────────────────
cmd_report() {
    info "Generating discovery report..."

    [[ ! -f "$FINDINGS_FILE" ]] && {
        error "No scan results found. Run 'scan' subcommand first."
        return 1
    }

    mkdir -p "$ARTIFACTS_DIR"

    # Count findings
    local total=$(wc -l < "$FINDINGS_FILE" 2>/dev/null || echo 0)

    # Generate JSON report
    {
        echo "{"
        echo "  \"generated_at\": \"$(now_iso)\","
        echo "  \"version\": \"1\","
        echo "  \"summary\": {"
        echo "    \"total_hardcoded\": $total,"
        echo "    \"total_fallbacks\": 0,"
        echo "    \"already_migrated\": 0,"
        echo "    \"migration_candidates\": 0"
        echo "  },"
        echo "  \"findings\": ["

        local first=true
        while IFS=$'\t' read -r relfile linenum value type priority; do
            [[ -z "$value" ]] && continue

            [[ "$first" == "true" ]] || echo ","
            first=false

            cat <<EOF
    {
      "file": "$relfile",
      "line": $linenum,
      "value": "$value",
      "type": "$type",
      "priority": $priority,
      "adaptive_candidate": true
    }
EOF
        done < "$FINDINGS_FILE"

        echo "  ]"
        echo "}"
    } > "$REPORT_FILE"

    success "Report written to $REPORT_FILE ($total findings)"
}

# ─── Dashboard ─────────────────────────────────────────────────────────────
cmd_dashboard() {
    [[ ! -f "$REPORT_FILE" ]] && {
        warn "No discovery report found. Run 'scan' and 'report' first."
        return 1
    }

    info "Policy Discovery Dashboard"
    echo ""

    local total=$(jq '.summary.total_hardcoded' "$REPORT_FILE" 2>/dev/null || echo 0)
    local p5=$(jq '[.findings[] | select(.priority==5)] | length' "$REPORT_FILE" 2>/dev/null || echo 0)
    local p4=$(jq '[.findings[] | select(.priority==4)] | length' "$REPORT_FILE" 2>/dev/null || echo 0)
    local p3=$(jq '[.findings[] | select(.priority==3)] | length' "$REPORT_FILE" 2>/dev/null || echo 0)

    success "Total hardcoded values: $total"
    echo ""
    success "By Priority:"
    echo "  Priority 5 (High ROI, Timeouts): $p5"
    echo "  Priority 4 (Assignments): $p4"
    echo "  Priority 3 (Comparisons): $p3"
    echo ""

    # Show top 5 by priority
    success "Top 5 Migration Candidates:"
    jq -r '.findings | sort_by(.priority) | reverse | .[0:5] | .[] | "  \(.file):\(.line) = \(.value) (\(.type), priority \(.priority))"' "$REPORT_FILE" 2>/dev/null || true
}

# ─── Plan Generator ───────────────────────────────────────────────────────
cmd_plan() {
    [[ ! -f "$REPORT_FILE" ]] && {
        error "No discovery report found. Run 'scan' and 'report' first."
        return 1
    }

    info "Generating migration plan..."

    local plan_file="${ARTIFACTS_DIR}/migration-plan.json"

    # Generate plan listing top 5 candidates
    {
        echo "{"
        echo "  \"migration_candidates\": ["

        jq -r '.findings | sort_by(.priority) | reverse | .[0:5][] | @json' "$REPORT_FILE" 2>/dev/null | {
            local first=true
            while read -r json_line; do
                [[ -z "$json_line" ]] && continue
                [[ "$first" == "true" ]] || echo ","
                first=false
                echo "    $(echo "$json_line" | jq '.')"
            done
        }

        echo "  ],"
        echo "  \"schema_additions\": {},"
        echo "  \"defaults_additions\": {}"
        echo "}"
    } > "$plan_file"

    success "Plan written to $plan_file"
}

# ─── Help message ──────────────────────────────────────────────────────────
cmd_help() {
    cat <<EOF
shipwright policy-discovery — Systematic Hardcoded Policy Discovery

USAGE
  shipwright policy-discovery <subcommand> [options]

SUBCOMMANDS
  scan              Scan scripts for hardcoded numeric values
  report            Generate JSON report from scan results
  plan              Generate migration plan with config structure
  dashboard         Show discovery progress dashboard
  help              Show this help message

EXAMPLES
  shipwright policy-discovery scan
  shipwright policy-discovery report
  shipwright policy-discovery dashboard

EOF
}

# ─── Main dispatcher ───────────────────────────────────────────────────────
main() {
    local subcmd="${1:-help}"
    shift 2>/dev/null || true

    case "$subcmd" in
        scan)
            cmd_scan
            ;;
        report)
            cmd_report
            ;;
        plan)
            cmd_plan
            ;;
        dashboard)
            cmd_dashboard
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown subcommand: $subcmd"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
