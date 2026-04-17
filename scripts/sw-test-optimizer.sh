#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-test-optimizer — CLI wrapper around lib/test-optimizer.sh            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Subcommands:
#   discover [root]          List discovered test files
#   smoke [--max-workers=N]  Run prioritized affected tests with fast-fail
#   full [--max-workers=N]   Run all discovered tests in parallel
#   stats                    Print historical stats as JSON
#   report                   Print human-readable execution report
#   track <file> <pass|fail> <duration_s> [changed...]
#                            Record a test run into history
#   help                     Show this help
#
set -euo pipefail

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/test-optimizer.sh
source "$SCRIPT_DIR/lib/test-optimizer.sh"

usage() {
    cat <<EOF
sw-test-optimizer $VERSION — Adaptive test execution optimizer

Usage: shipwright test-optimizer <subcommand> [args]

Subcommands:
  discover [ROOT]                     List discovered test files (default: .)
  smoke [--max-workers=N] [ROOT]      Prioritized affected tests, fast-fail
  full  [--max-workers=N] [ROOT]      All discovered tests, parallel
  stats                               Historical stats as JSON
  report                              Human-readable report
  track FILE pass|fail DURATION_S     Record a test run into history
  help                                Show this help

Environment:
  SW_TEST_OPTIMIZER=1                 Enable sw-loop fast-path integration
EOF
}

cmd_discover() {
    local root="${1:-.}"
    testopt_discover_tests "$root"
    printf '%s\n' "${DISCOVERED_TESTS[@]:-}"
}

cmd_smoke() {
    local max_workers=4
    [[ "${1:-}" == --max-workers=* ]] && { max_workers="${1#--max-workers=}"; shift; }
    local root="${1:-.}"
    local start_ts end_ts exit_code=0
    start_ts=$(date +%s)

    testopt_init "$root"
    [[ ${#AFFECTED_TESTS[@]} -eq 0 ]] && { warn "No affected tests"; return 0; }

    # Prioritize by fail-rate, then run with fast-fail
    local -a ordered=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && ordered+=("$line")
    done < <(testopt_prioritize "${AFFECTED_TESTS[@]}")

    testopt_run_with_fast_fail "${ordered[@]}" >/dev/null 2>&1 || exit_code=$?
    end_ts=$(date +%s)

    info "Smoke completed in $((end_ts - start_ts))s ($TESTOPT_STATS_TESTS_RUN tests)"
    testopt_report
    return "$exit_code"
}

cmd_full() {
    local max_workers=4
    [[ "${1:-}" == --max-workers=* ]] && { max_workers="${1#--max-workers=}"; shift; }
    local root="${1:-.}"
    local start_ts end_ts exit_code=0
    start_ts=$(date +%s)

    testopt_init "$root"
    [[ ${#DISCOVERED_TESTS[@]} -eq 0 ]] && { warn "No tests discovered"; return 0; }

    testopt_run_parallel "--max-workers=${max_workers}" "${DISCOVERED_TESTS[@]}" || exit_code=$?
    end_ts=$(date +%s)

    info "Full suite completed in $((end_ts - start_ts))s"
    testopt_report
    return "$exit_code"
}

cmd_stats() {
    testopt_load_history
    local total=${#TEST_HISTORY[@]}
    if [[ "$total" -eq 0 ]] || ! command -v jq >/dev/null 2>&1; then
        echo "{\"total_records\": $total, \"history_file\": \"$TESTOPT_HISTORY_FILE\"}"
        return 0
    fi
    local passes fails
    passes=$(grep -c '"result": *"pass"' "$TESTOPT_HISTORY_FILE" 2>/dev/null || echo 0)
    fails=$(grep -c '"result": *"fail"' "$TESTOPT_HISTORY_FILE" 2>/dev/null || echo 0)
    jq -n \
        --argjson total "$total" \
        --argjson passes "${passes:-0}" \
        --argjson fails "${fails:-0}" \
        --arg file "$TESTOPT_HISTORY_FILE" \
        '{total_records: $total, passes: $passes, fails: $fails, history_file: $file}'
}

cmd_report() {
    testopt_load_history
    testopt_discover_tests "${1:-.}"
    AFFECTED_TESTS=("${DISCOVERED_TESTS[@]}")
    testopt_report
}

cmd_track() {
    local file="${1:-}" result="${2:-}" duration="${3:-0}"
    [[ -z "$file" || -z "$result" ]] && { error "Usage: track FILE pass|fail DURATION_S"; return 1; }
    shift 3 || true
    testopt_record_history "$file" "$result" "$duration" "$@"
    success "Recorded: $file $result ${duration}s"
}

main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        discover) cmd_discover "$@" ;;
        smoke)    cmd_smoke "$@" ;;
        full)     cmd_full "$@" ;;
        stats)    cmd_stats "$@" ;;
        report)   cmd_report "$@" ;;
        track)    cmd_track "$@" ;;
        help|--help|-h) usage ;;
        --version|-v) echo "sw-test-optimizer $VERSION" ;;
        *) error "Unknown subcommand: $cmd"; usage; exit 1 ;;
    esac
}

main "$@"
