#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-flaky.sh — Flaky Test Detection & Auto-Quarantine                    ║
# ║                                                                          ║
# ║  Record test results, detect flaky tests by failure-rate variance, and   ║
# ║  auto-quarantine them with a reversible skip annotation + GitHub issue.  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.3.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Fallbacks when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

NO_GITHUB="${NO_GITHUB:-false}"

# shellcheck source=lib/flaky-detection.sh
source "$SCRIPT_DIR/lib/flaky-detection.sh"

show_help() {
    cat <<EOF
USAGE
  shipwright flaky <command> [options]

DESCRIPTION
  Track per-test pass/fail history, detect flaky tests by failure-rate
  variance over a sliding window, and auto-quarantine them.

COMMANDS
  record <pipeline_id> <results-file>   Parse a test-output file and store results
  detect [--json]                       Report tests exceeding the variance threshold
  quarantine [--auto] [test_name]       Quarantine a test (or all detected with --auto)
  list [--all] [--json]                 Show quarantined tests
  lift <test_name>                      Lift a quarantine (mark inactive)
  count                                 Print active quarantine count
  --help, -h                            Show this help text
  --version, -v                         Show version

DETECTION
  A test is flagged when its failure rate over the last N runs is >= the
  variance threshold (default 20%), with at least min-runs runs and
  required-failures failures in the window. Configure via daemon-config.json
  ("patrol": { "flaky_variance_threshold", "flaky_window", "flaky_min_runs",
  "flaky_required_failures", "flaky_max_issues" }) or SW_* env overrides.

EXAMPLES
  npm test 2>&1 | tee out.txt && shipwright flaky record run-42 out.txt
  shipwright flaky detect
  shipwright flaky detect --json
  shipwright flaky quarantine --auto
  shipwright flaky list
  shipwright flaky lift "test/foo.test.js > should do x"
EOF
}

cmd_record() {
    local pipeline_id="${1:-}" file="${2:-}"
    if [[ -z "$pipeline_id" || -z "$file" ]]; then
        error "usage: shipwright flaky record <pipeline_id> <results-file>"
        return 1
    fi
    flaky_record_results "$pipeline_id" "$file"
}

cmd_detect() {
    flaky_detect "${1:-}"
}

cmd_quarantine() {
    local auto=false test_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) auto=true; shift ;;
            *) test_name="$1"; shift ;;
        esac
    done

    if $auto; then
        local detected
        detected=$(flaky_detect --json)
        local count
        count=$(echo "$detected" | jq 'length' 2>/dev/null || echo 0)
        if [[ "${count:-0}" -eq 0 ]]; then
            success "No flaky tests to quarantine"
            return 0
        fi
        local max issued=0
        max=$(flaky_max_issues)
        local name rate runs fails url
        while IFS= read -r row; do
            [[ -z "$row" ]] && continue
            name=$(echo "$row" | jq -r '.test_name')
            rate=$(echo "$row" | jq -r '.failure_rate')
            runs=$(echo "$row" | jq -r '.runs')
            fails=$(echo "$row" | jq -r '.failures')
            # Cooldown / dedup: skip already-active quarantines.
            if type db_is_quarantined >/dev/null 2>&1 && db_is_quarantined "$name"; then
                info "Already quarantined: $name"
                continue
            fi
            url=""
            if [[ "$issued" -lt "$max" ]]; then
                url=$(flaky_create_issue "$name" "$rate" "$runs" "$fails")
                [[ -n "$url" ]] && issued=$((issued + 1))
            fi
            flaky_quarantine_test "$name" "" "$url" || true
        done < <(echo "$detected" | jq -c '.[]' 2>/dev/null)
        return 0
    fi

    if [[ -z "$test_name" ]]; then
        error "usage: shipwright flaky quarantine [--auto] [test_name]"
        return 1
    fi
    local url
    url=$(flaky_create_issue "$test_name" "0" "0" "0")
    flaky_quarantine_test "$test_name" "" "$url"
}

cmd_list() {
    local all="" as_json=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) all="--all"; shift ;;
            --json) as_json=true; shift ;;
            *) shift ;;
        esac
    done
    local rows
    rows=$(db_list_quarantined $all 2>/dev/null || echo "[]")
    if $as_json; then
        echo "$rows"
        return 0
    fi
    local count
    count=$(echo "$rows" | jq 'length' 2>/dev/null || echo 0)
    if [[ "${count:-0}" -eq 0 ]]; then
        success "No quarantined tests"
        return 0
    fi
    info "Quarantined tests (${count}):"
    echo "$rows" | jq -r '.[] | "  • \(.test_name) — \(.failure_rate)%\(if .github_issue_url != "" then " — \(.github_issue_url)" else "" end)"' 2>/dev/null
}

cmd_lift() {
    local test_name="${1:-}"
    [[ -z "$test_name" ]] && { error "usage: shipwright flaky lift <test_name>"; return 1; }
    if db_lift_quarantine "$test_name"; then
        success "Lifted quarantine for: $test_name"
    else
        error "Failed to lift quarantine (DB unavailable?)"
        return 1
    fi
}

cmd_count() {
    db_count_quarantined
}

main() {
    case "${1:-}" in
        record)     shift; cmd_record "$@" ;;
        detect)     shift; cmd_detect "$@" ;;
        quarantine) shift; cmd_quarantine "$@" ;;
        list)       shift; cmd_list "$@" ;;
        lift)       shift; cmd_lift "$@" ;;
        count)      shift; cmd_count "$@" ;;
        --help|-h|"") show_help ;;
        --version|-v) echo "$VERSION" ;;
        *) error "Unknown command: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
