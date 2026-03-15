#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-debug-bundle.sh — Pipeline Failure Debug Bundle Management           ║
# ║                                                                          ║
# ║  Manage debug bundles collected from pipeline failures:                  ║
# ║  - list: Show all debug bundles                                          ║
# ║  - show: Display bundle contents                                         ║
# ║  - export: Create tar.gz archive for sharing                             ║
# ║  - clean: Remove old bundles                                             ║
# ║  - last: Show the most recent bundle                                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="2.0.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# Load debug-collector library
[[ -f "$SCRIPT_DIR/lib/debug-collector.sh" ]] && source "$SCRIPT_DIR/lib/debug-collector.sh" 2>/dev/null || {
    error "debug-collector library not found"
    exit 1
}

# ─── Defaults ──────────────────────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.claude}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$STATE_DIR/pipeline-artifacts}"

# ─── Help text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright debug-bundle [SUBCOMMAND] [OPTIONS]

DESCRIPTION
  Manage debug bundles collected from pipeline failures.
  Debug bundles contain logs, git state, environment, and error context
  to accelerate failure diagnosis without manual artifact hunting.

SUBCOMMANDS
  list [STAGE]            List all debug bundles (optionally filter by stage)
  show <PATH>             Display bundle contents in human-readable format
  export <PATH> [OUT]     Create tar.gz archive for sharing
  clean [--keep N]        Remove old bundles (keep N most recent, default 10)
  last [STAGE]            Show the most recent bundle (optionally for a stage)

OPTIONS
  --help, -h              Show this help text
  --version, -v           Show version
  --json                  Output in JSON format (where applicable)

EXAMPLES
  shipwright debug-bundle list                    Show all bundles
  shipwright debug-bundle list build              Show build stage bundles only
  shipwright debug-bundle last                    Show most recent bundle details
  shipwright debug-bundle show /path/to/bundle    Display bundle contents
  shipwright debug-bundle export /path/to/bundle  Export as tar.gz
  shipwright debug-bundle clean --keep 5          Keep only 5 most recent bundles

EOF
}

# ─── Subcommands ───────────────────────────────────────────────────────────

cmd_list() {
    local stage_filter="${1:-}"
    local output_format="${OUTPUT_FORMAT:-text}"

    # List all bundles
    local bundles
    bundles=$(list_debug_bundles)

    if [[ -z "$bundles" ]]; then
        warn "No debug bundles found"
        return 0
    fi

    # Filter by stage if specified
    if [[ -n "$stage_filter" ]]; then
        bundles=$(echo "$bundles" | jq -r "select(.stage == \"$stage_filter\")")
    fi

    # Output format
    if [[ "$output_format" == "json" ]]; then
        echo "$bundles"
    else
        # Text format with table headers
        echo "Debug Bundles:"
        echo ""
        printf "%-20s %-25s %-15s %s\n" "STAGE" "TIMESTAMP" "SIZE" "PATH"
        printf "%-20s %-25s %-15s %s\n" "----" "---------" "----" "----"

        echo "$bundles" | jq -r '.stage + "\t" + .timestamp + "\t" + (.size_bytes | tostring) + "\t" + .path' | while IFS=$'\t' read -r stage timestamp size path; do
            # Format size in human-readable form
            local size_human
            if [[ "$size" -gt 1048576 ]]; then
                size_human="$((size / 1048576))MB"
            elif [[ "$size" -gt 1024 ]]; then
                size_human="$((size / 1024))KB"
            else
                size_human="${size}B"
            fi
            printf "%-20s %-25s %-15s %s\n" "$stage" "$timestamp" "$size_human" "$path"
        done
    fi
}

cmd_show() {
    local bundle_path="${1:-}"
    [[ -z "$bundle_path" ]] && { error "Usage: show <bundle-path>"; exit 1; }

    show_debug_bundle "$bundle_path"
}

cmd_export() {
    local bundle_path="${1:-}"
    local output_file="${2:-./${bundle_path##*/}.tar.gz}"
    [[ -z "$bundle_path" ]] && { error "Usage: export <bundle-path> [output-file]"; exit 1; }

    export_debug_bundle "$bundle_path" "$output_file"
}

cmd_clean() {
    local keep=10
    # Parse optional --keep flag
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep)
                keep="${2:-10}"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    info "Cleaning debug bundles (keeping last $keep)..."
    rotate_debug_bundles "$keep"
    success "Cleanup complete"

    # Show what's left
    local remaining
    remaining=$(list_debug_bundles | jq -s 'length')
    info "Remaining bundles: $remaining"
}

cmd_last() {
    local stage_filter="${1:-}"
    local output_format="${OUTPUT_FORMAT:-text}"

    # Get the most recent bundle
    local latest_bundle
    if [[ -n "$stage_filter" ]]; then
        latest_bundle=$(list_debug_bundles | jq -r "select(.stage == \"$stage_filter\") | .path" | head -1)
    else
        latest_bundle=$(list_debug_bundles | jq -r '.path' | head -1)
    fi

    [[ -z "$latest_bundle" ]] && { warn "No debug bundles found"; return 0; }

    if [[ "$output_format" == "json" ]]; then
        list_debug_bundles | jq "select(.path == \"$latest_bundle\")"
    else
        show_debug_bundle "$latest_bundle"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    # Parse global options
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
                OUTPUT_FORMAT="json"
                shift
                ;;
            list|show|export|clean|last)
                # Subcommand starts here
                break
                ;;
            *)
                error "Unknown option or subcommand: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Dispatch subcommand
    case "${1:-list}" in
        list)
            shift
            cmd_list "$@"
            ;;
        show)
            shift
            cmd_show "$@"
            ;;
        export)
            shift
            cmd_export "$@"
            ;;
        clean)
            shift
            cmd_clean "$@"
            ;;
        last)
            shift
            cmd_last "$@"
            ;;
        *)
            error "Unknown subcommand: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
