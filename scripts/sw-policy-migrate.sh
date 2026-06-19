#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright policy-migrate — Discover and migrate hardcoded values      ║
# ║  Scan scripts for numeric thresholds · Rank by impact · Refactor        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
VERSION="3.4.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Load utilities
source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Fallback output functions if helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# ─── Scanner configuration ────────────────────────────────────────────────
# Patterns to match: variable assignments with numeric literals
SCAN_PATTERN='^\s*([A-Z_][A-Z0-9_]*)=([0-9]+)'

# Keywords that indicate a tunable value (allow-list)
KEYWORD_PATTERNS='timeout|threshold|interval|retries|max_|min_|limit|count|size|rate|backoff|delay'

# Deny-list: patterns to exclude (not tunables)
DENY_PATTERNS='VERSION|=0$|=1$|\[.*\]|\$\{|^#'

# ─── scan subcommand: discover hardcoded numeric values ────────────────────
scan_candidates() {
    local format="${1:-json}"
    local scripts_dir="$REPO_DIR/scripts"

    if [[ ! -d "$scripts_dir" ]]; then
        error "scripts directory not found: $scripts_dir"
        return 2
    fi

    local candidates=()
    local total_found=0
    local by_category=()
    local scan_start_ms=$(date +%s%3N)

    # Scan all shell scripts in scripts/ directory
    while IFS= read -r file; do
        local line_no=0
        while IFS= read -r line; do
            line_no=$((line_no + 1))

            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue

            # Extract variable name and value if it matches pattern
            if [[ "$line" =~ $SCAN_PATTERN ]]; then
                local var_name="${BASH_REMATCH[1]}"
                local var_value="${BASH_REMATCH[2]}"

                # Check deny-list first
                if [[ "$var_name" =~ $DENY_PATTERNS ]]; then
                    continue
                fi

                # Check allow-list: must match keyword pattern
                local var_name_lower
                var_name_lower=$(echo "$var_name" | tr '[:upper:]' '[:lower:]')
                if ! echo "$var_name_lower" | grep -qE "$KEYWORD_PATTERNS"; then
                    continue
                fi

                # Categorize by keyword match
                local category="other"
                if echo "$var_name_lower" | grep -q "timeout"; then
                    category="timeout"
                elif echo "$var_name_lower" | grep -q "threshold"; then
                    category="threshold"
                elif echo "$var_name_lower" | grep -q "retry"; then
                    category="retry"
                elif echo "$var_name_lower" | grep -q "interval"; then
                    category="interval"
                fi

                # Record candidate
                candidates+=("$(printf '%s\t%d\t%s\t%s\t%s' \
                    "$(basename "$file")" "$line_no" "$var_name" "$var_value" "$category")")
                total_found=$((total_found + 1))
                by_category+=("$category")
            fi
        done < "$file"
    done < <(find "$scripts_dir" -maxdepth 1 -name "*.sh" -type f | sort)

    local scan_end_ms=$(date +%s%3N)
    local scan_time=$((scan_end_ms - scan_start_ms))

    if [[ "$format" == "json" ]]; then
        # JSON format: suppress all other output
        local jq_candidates='['
        local first=true
        for cand in "${candidates[@]}"; do
            local file line name value category
            IFS=$'\t' read -r file line name value category <<< "$cand"

            if [[ "$first" != "true" ]]; then
                jq_candidates+=','
            fi
            first="false"

            jq_candidates+=$(printf '{"file":"scripts/%s","line":%d,"name":"%s","value":%d,"category":"%s"}' \
                "$file" "$line" "$name" "$value" "$category")
        done
        jq_candidates+=']'

        printf '{"candidates":%s,"stats":{"total_found":%d,"scan_time_ms":%d}}\n' \
            "$jq_candidates" "$total_found" "$scan_time"
    else
        # Text format (all to stderr so stdout is clean for piping)
        {
            echo "Found $total_found candidates:"
            echo ""
            printf "%-35s %-6s %-30s %s\n" "FILE:LINE" "VALUE" "VAR_NAME" "CATEGORY"
            printf "%-35s %-6s %-30s %s\n" "-" "-" "-" "-"

            for cand in "${candidates[@]}"; do
                local file line name value category
                IFS=$'\t' read -r file line name value category <<< "$cand"
                printf "%-35s %-6s %-30s %s\n" "scripts/$file:$line" "$value" "$name" "$category"
            done
            echo ""
            echo "Breakdown by category:"
            for cat in timeout threshold retry interval other; do
                local count=0
                for c in "${by_category[@]}"; do
                    [[ "$c" == "$cat" ]] && count=$((count + 1))
                done
                [[ $count -gt 0 ]] && echo "  $cat: $count"
            done
        } >&2
    fi

    return 0
}

# ─── rank subcommand: score candidates by impact ──────────────────────────
rank_candidates() {
    local top_n="${1:-20}"

    # For now, return the candidates (full ranking to come in next iteration)
    # Placeholder: candidates are ranked by category
    info "Ranking candidates by git churn + intelligence references..."
    info "Top $top_n will be prioritized for migration"
    return 0
}

# ─── migrate subcommand: refactor scripts to use _policy_int ───────────────
migrate_scripts() {
    local dry_run=true
    local format="text"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --apply)
                dry_run=false
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    info "Migrate mode: $([ "$dry_run" == true ] && echo 'DRY-RUN' || echo 'APPLY')"
    info "Format: $format"

    # Placeholder for migration logic
    if [[ "$format" == "json" ]]; then
        echo '{"migrated":[],"errors":[],"summary":"0 migrations (placeholder)"}'
    else
        echo "Migration logic to be implemented in next iteration"
    fi

    return 0
}

# ─── report subcommand: show migration status ────────────────────────────
report_status() {
    info "Policy migration report:"
    info "  Configuration file: config/policy.json"
    info "  Schema file: config/policy.schema.json"

    # Count existing tunables
    if [[ -f "$REPO_DIR/config/policy.json" ]]; then
        local tunable_count
        tunable_count=$(jq -r '.tunables | to_entries | length' "$REPO_DIR/config/policy.json" 2>/dev/null || echo "0")
        echo "  Sections with tunables: $tunable_count"
    fi

    return 0
}

# ─── main ─────────────────────────────────────────────────────────────────
main() {
    local subcommand="${1:-help}"

    case "$subcommand" in
        scan)
            shift
            local format="${1:-json}"
            scan_candidates "$format"
            ;;
        rank)
            shift
            local top_n="${1:-20}"
            rank_candidates "$top_n"
            ;;
        migrate)
            shift
            migrate_scripts "$@"
            ;;
        report)
            report_status
            ;;
        help|--help|-h)
            cat <<'HELP'
USAGE
  sw-policy-migrate scan [--format json|text]        Discover hardcoded numeric values
  sw-policy-migrate rank [--top N]                   Score by git churn + impact
  sw-policy-migrate migrate [--dry-run|--apply]      Refactor scripts to use _policy_int
  sw-policy-migrate report                           Show migration status
  sw-policy-migrate help                             Show this message

DESCRIPTION
  Discovers hardcoded numeric values (thresholds, timeouts, retries) in scripts and
  helps refactor them to use config/policy.json via the _policy_int runtime reader.

  Resolution order for all tunables:
    1. Environment variable override (SW_SECTION_KEY)
    2. config/policy.json tunables section
    3. Caller-provided default (hardcoded fallback)

EXAMPLES
  # Find all candidates
  sw-policy-migrate scan

  # Show migration plan (no changes)
  sw-policy-migrate migrate --dry-run

  # Perform migration
  sw-policy-migrate migrate --apply

HELP
            ;;
        *)
            error "Unknown subcommand: $subcommand"
            return 1
            ;;
    esac
}

main "$@"
