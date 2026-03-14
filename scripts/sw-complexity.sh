#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-complexity.sh — Script Complexity Doctor Check                       ║
# ║                                                                          ║
# ║  Analyzes shell scripts for complexity metrics, anti-patterns, and       ║
# ║  provides actionable refactor suggestions.                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.2.4"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=lib/complexity-analyzer.sh
[[ -f "$SCRIPT_DIR/lib/complexity-analyzer.sh" ]] && source "$SCRIPT_DIR/lib/complexity-analyzer.sh"

# Fallbacks when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# ─── Help text ────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright complexity [OPTIONS] [<script>]

DESCRIPTION
  Analyzes shell scripts for complexity metrics and anti-pattern violations.
  Calculates LOC, cyclomatic complexity, nesting depth, function count, and
  detects Common Pitfalls documented in CLAUDE.md.

OPTIONS
  <script>              Analyze a single script
  --all                 Analyze all scripts in scripts/ directory
  --recursive <dir>     Recursively analyze a directory
  --json                Output as JSON (default: human-readable)
  --summary             Show summary only (no per-script details)
  --help, -h            Show this help text
  --version, -v         Show version

ANTI-PATTERNS DETECTED
  grep-c-pipefail       grep -c without || true (double output)
  pipe-while-read       cmd | while read (subshell variable loss)
  json-interpolation    jq with \${var} instead of --arg
  bash4-syntax          declare -A, readarray (not Bash 3.2 safe)
  missing-version       Script lacks VERSION= variable
  missing-no-github     GitHub API calls without NO_GITHUB guard
  non-atomic-write      Direct file writes without tmp+mv
  cd-in-function        Bare cd in function (changes caller dir)

EXAMPLES
  shipwright complexity scripts/sw-daemon.sh
  shipwright complexity --all
  shipwright complexity --all --json
  shipwright complexity --recursive scripts/lib/
  shipwright complexity --all --summary

EXIT CODES
  0   Success, no critical violations
  1   Error (invalid args, file not found)
  2   Violations found exceeding threshold (for CI gating)

EOF
}

# ─── Analyze a single script (human output) ───────────────────────────────
analyze_single() {
    local script_path="$1"
    local format="${2:-text}"

    if [[ ! -f "$script_path" ]]; then
        error "Script not found: $script_path"
        return 1
    fi

    local result
    result=$(complexity_analyze_script "$script_path") || {
        error "Failed to analyze: $script_path"
        return 1
    }

    if [[ "$format" == "json" ]]; then
        echo "$result"
        return 0
    fi

    # Human-readable output
    local script_name cc nesting loc funcs grade viol_count
    script_name=$(basename "$script_path")
    cc=$(echo "$result" | jq -r '.cyclomatic_complexity')
    nesting=$(echo "$result" | jq -r '.max_nesting_depth')
    loc=$(echo "$result" | jq -r '.metrics.code_lines')
    funcs=$(echo "$result" | jq -r '.metrics.function_count')
    grade=$(echo "$result" | jq -r '.grade')
    viol_count=$(echo "$result" | jq -r '.violation_count')

    echo ""
    info "Script Complexity Report: $script_name"
    echo ""
    echo "  Metrics:"
    echo "    Code Lines:             $loc"
    echo "    Functions:              $funcs"
    echo "    Avg Function Length:    $(echo "$result" | jq -r '.metrics.avg_function_length') LOC"
    echo "    Cyclomatic Complexity:  $cc"
    echo "    Max Nesting Depth:      $nesting"
    echo "    Grade:                  $grade"
    echo ""

    if [[ $viol_count -gt 0 ]]; then
        warn "Found $viol_count anti-pattern violation(s):"
        echo ""
        echo "$result" | jq -r '.violations[] | "    [\(.severity | ascii_upcase)] \(.pattern) (line \(.line_number))"'
        echo ""
        echo "  Suggestions:"
        echo "$result" | jq -r '.violations[] | "    -> \(.suggestion)"'
        echo ""
    else
        success "No anti-pattern violations found"
        echo ""
    fi

    # Generate refactor suggestion if warranted
    local suggestion
    suggestion=$(complexity_generate_suggestion "$result")
    if [[ -n "$suggestion" ]]; then
        echo "  Refactor Recommendation:"
        echo "    $(echo "$suggestion" | jq -r '.suggestion')"
        echo ""
    fi

    # Exit 2 if high-severity violations exist
    local high_count=0
    high_count=$(echo "$result" | jq '[.violations[] | select(.severity == "high")] | length')
    if [[ $high_count -gt 0 ]]; then
        return 2
    fi
    return 0
}

# ─── Analyze all scripts ──────────────────────────────────────────────────
analyze_all() {
    local format="${1:-text}"
    local summary_only="${2:-false}"
    local scripts_dir="$SCRIPT_DIR"
    local results="[]"
    local count=0
    local violation_total=0

    while IFS= read -r script; do
        [[ -z "$script" ]] && continue
        # Skip test files
        [[ "$script" == *"-test.sh" ]] && continue

        local result
        result=$(complexity_analyze_script "$script" 2>/dev/null) || continue
        results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
        count=$((count + 1))

        local v_count
        v_count=$(echo "$result" | jq '.violation_count')
        violation_total=$((violation_total + v_count))
    done < <(find "$scripts_dir" -maxdepth 1 -name 'sw-*.sh' -type f 2>/dev/null | sort)

    # Also include the CLI router
    if [[ -f "$scripts_dir/sw" ]]; then
        local result
        result=$(complexity_analyze_script "$scripts_dir/sw" 2>/dev/null) || true
        if [[ -n "$result" ]]; then
            results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
            count=$((count + 1))
        fi
    fi

    if [[ "$format" == "json" ]]; then
        echo "$results" | jq 'sort_by(.cyclomatic_complexity) | reverse'
        return 0
    fi

    # Human-readable output
    echo ""
    info "Script Complexity Analysis: $count scripts"
    echo ""

    # Top 10 most complex
    echo "  Top 10 Most Complex Scripts:"
    echo "  ─────────────────────────────────────────────────────────────────"
    printf "  %-35s %6s %5s %5s %6s %5s\n" "SCRIPT" "LOC" "CC" "NEST" "VIOLS" "GRADE"
    echo "  ─────────────────────────────────────────────────────────────────"

    echo "$results" | jq -r '
        sort_by(.cyclomatic_complexity) | reverse | .[0:10] | .[] |
        "  \(.script | split("/") | .[-1] | .[0:35] | . + (" " * (35 - length)))\(.metrics.code_lines | tostring | (" " * (6 - length)) + .)\(.cyclomatic_complexity | tostring | (" " * (5 - length)) + .)\(.max_nesting_depth | tostring | (" " * (5 - length)) + .)\(.violation_count | tostring | (" " * (6 - length)) + .)  \(.grade)"
    '
    echo ""

    if [[ "$summary_only" == "false" ]]; then
        # Scripts with violations
        local scripts_with_violations
        scripts_with_violations=$(echo "$results" | jq '[.[] | select(.violation_count > 0)] | length')

        if [[ $scripts_with_violations -gt 0 ]]; then
            warn "Scripts with anti-pattern violations: $scripts_with_violations"
            echo ""
            echo "$results" | jq -r '
                [.[] | select(.violation_count > 0)] | sort_by(.violation_count) | reverse | .[0:10] | .[] |
                "    \(.script | split("/") | .[-1]): \(.violation_count) violation(s)"
            '
            echo ""

            # Show top violations by type
            echo "  Violations by Type:"
            echo "$results" | jq -r '
                [.[].violations[]] | group_by(.pattern) | map({pattern: .[0].pattern, count: length, severity: .[0].severity}) |
                sort_by(.count) | reverse | .[] |
                "    \(.pattern): \(.count) occurrence(s) [\(.severity)]"
            '
            echo ""
        fi

        # Refactor suggestions
        local high_complexity
        high_complexity=$(echo "$results" | jq '[.[] | select(.cyclomatic_complexity > 50 or .metrics.code_lines > 1500)] | length')

        if [[ $high_complexity -gt 0 ]]; then
            echo "  Refactor Suggestions:"
            echo "  ─────────────────────────────────────────────────────────────────"
            echo "$results" | jq -r '
                [.[] | select(.cyclomatic_complexity > 50 or .metrics.code_lines > 1500)] |
                sort_by(.metrics.code_lines) | reverse | .[] |
                "    \(.script | split("/") | .[-1]): \(.metrics.code_lines) LOC, CC=\(.cyclomatic_complexity) -> Split into lib/ modules"
            '
            echo ""
        fi
    fi

    # Summary
    echo "  ─────────────────────────────────────────────────────────────────"
    local grade_a grade_b grade_c grade_d grade_f
    grade_a=$(echo "$results" | jq '[.[] | select(.grade == "A")] | length')
    grade_b=$(echo "$results" | jq '[.[] | select(.grade == "B")] | length')
    grade_c=$(echo "$results" | jq '[.[] | select(.grade == "C")] | length')
    grade_d=$(echo "$results" | jq '[.[] | select(.grade == "D")] | length')
    grade_f=$(echo "$results" | jq '[.[] | select(.grade == "F")] | length')

    echo "  Grade Distribution: A=$grade_a  B=$grade_b  C=$grade_c  D=$grade_d  F=$grade_f"
    echo "  Total Violations: $violation_total across $count scripts"
    echo ""

    success "Analysis complete. Run with --json for machine-readable output."
    echo ""

    # Exit 2 if any grade F scripts
    if [[ $grade_f -gt 0 ]]; then
        return 2
    fi
    return 0
}

# ─── Analyze directory recursively ────────────────────────────────────────
analyze_recursive() {
    local directory="$1"
    local format="${2:-text}"

    if [[ ! -d "$directory" ]]; then
        error "Directory not found: $directory"
        return 1
    fi

    local results="[]"
    local count=0

    while IFS= read -r script; do
        [[ -z "$script" ]] && continue
        local result
        result=$(complexity_analyze_script "$script" 2>/dev/null) || continue
        results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
        count=$((count + 1))
    done < <(find "$directory" -name '*.sh' -type f 2>/dev/null | sort)

    if [[ "$format" == "json" ]]; then
        echo "$results" | jq 'sort_by(.cyclomatic_complexity) | reverse'
        return 0
    fi

    echo ""
    info "Recursive analysis: $count scripts in $directory"
    echo ""
    printf "  %-40s %6s %5s %5s\n" "SCRIPT" "LOC" "CC" "GRADE"
    echo "  ─────────────────────────────────────────────────────────────────"
    echo "$results" | jq -r '
        sort_by(.cyclomatic_complexity) | reverse | .[] |
        "  \(.script | split("/") | .[-1] | .[0:40] | . + (" " * (40 - length)))\(.metrics.code_lines | tostring | (" " * (6 - length)) + .)\(.cyclomatic_complexity | tostring | (" " * (5 - length)) + .)  \(.grade)"
    '
    echo ""
    success "Analyzed $count scripts"
}

# ─── Main ─────────────────────────────────────────────────────────────────
main() {
    local format="text"
    local summary_only="false"
    local action=""
    local target=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                echo "$VERSION"
                exit 0
                ;;
            --json)
                format="json"
                shift
                ;;
            --summary)
                summary_only="true"
                shift
                ;;
            --all)
                action="all"
                shift
                ;;
            --recursive)
                action="recursive"
                shift
                if [[ $# -eq 0 ]]; then
                    error "Missing directory argument for --recursive"
                    exit 1
                fi
                target="$1"
                shift
                ;;
            -*)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                action="single"
                target="$1"
                shift
                ;;
        esac
    done

    # Validate jq is available
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required but not installed"
        exit 1
    fi

    # Validate complexity library is loaded
    if [[ "$(type -t complexity_analyze_script 2>/dev/null)" != "function" ]]; then
        error "complexity-analyzer.sh library not loaded"
        exit 1
    fi

    case "$action" in
        single)
            analyze_single "$target" "$format"
            ;;
        all)
            analyze_all "$format" "$summary_only"
            ;;
        recursive)
            analyze_recursive "$target" "$format"
            ;;
        "")
            show_help
            exit 1
            ;;
    esac
}

main "$@"
