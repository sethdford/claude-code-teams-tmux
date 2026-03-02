#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-ping.sh — Ping Command                                               ║
# ║                                                                          ║
# ║  Prints "pong" to stdout and exits 0.                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.2.4"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t error 2>/dev/null)" == "function" ]] || error() { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# ─── Help text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright ping [OPTIONS]

DESCRIPTION
  Prints "pong" to stdout and exits 0. Useful for verifying the CLI is
  installed and responding correctly.

OPTIONS
  --help, -h      Show this help text
  --version, -v   Show version

EXAMPLES
  shipwright ping              Print "pong"
  shipwright ping --help       Show this help text

EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-v)
            echo "$VERSION"
            exit 0
            ;;
        "")
            echo "pong"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
