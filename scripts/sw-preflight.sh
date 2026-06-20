#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-preflight.sh — Pipeline Pre-Flight Health Validator (standalone CLI)  ║
# ║                                                                          ║
# ║  Runs environment health checks (disk, tmux, network, GitHub rate        ║
# ║  limits, Claude CLI) and reports blocking issues with actionable fixes.  ║
# ║  The same checks run automatically before `shipwright pipeline start`.   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.3.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events) + config helpers.
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"

# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR).
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "▸ $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "✓ $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "⚠ $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "✗ $*" >&2; }

# Project root used by the disk-space check.
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# shellcheck source=lib/pipeline-preflight.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-preflight.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-preflight.sh"

# ─── Help text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright preflight [OPTIONS]

DESCRIPTION
  Validate environment health before launching a pipeline. Checks disk space,
  tmux availability, network connectivity, GitHub API rate limits, and the
  Claude CLI. Exits non-zero when a blocking issue is found.

OPTIONS
  --json          Output machine-readable JSON (status + reasons)
  --help, -h      Show this help text
  --version, -v   Show version

CONFIG (daemon-config.json)
  preflight.min_disk_gb         Minimum free disk in GB (default 5)
  preflight.min_github_requests Minimum GitHub API requests remaining (default 10)

EXAMPLES
  shipwright preflight             Run health checks (human output)
  shipwright preflight --json      Run health checks (JSON output)

EOF
}

# ─── JSON output ────────────────────────────────────────────────────────────
emit_json() {
    local status="$1"
    if command -v jq >/dev/null 2>&1; then
        local arr='[]'
        local r
        if [[ ${#PREFLIGHT_REASONS[@]} -gt 0 ]]; then
            for r in "${PREFLIGHT_REASONS[@]}"; do
                arr=$(echo "$arr" | jq --arg r "$r" '. + [$r]')
            done
        fi
        jq -n --arg status "$status" --argjson reasons "$arr" \
            '{status: $status, reasons: $reasons}'
    else
        echo "{\"status\":\"$status\",\"reasons\":[]}"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local json_mode=false
    case "${1:-}" in
        --help|-h)    show_help; exit 0 ;;
        --version|-v) echo "$VERSION"; exit 0 ;;
        --json)       json_mode=true ;;
        "")           ;;
        *)            error "Unknown option: $1"; show_help; exit 1 ;;
    esac

    if [[ "$json_mode" == "true" ]]; then
        PREFLIGHT_QUIET=true
        if preflight_health_check; then
            emit_json "passed"
            exit 0
        else
            emit_json "failed"
            exit 1
        fi
    fi

    if preflight_health_check; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
