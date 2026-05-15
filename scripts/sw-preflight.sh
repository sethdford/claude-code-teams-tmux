#!/usr/bin/env bash
# sw-preflight.sh — CLI wrapper for the Pre-Flight Issue Feasibility Validator
#
# Usage:
#   shipwright preflight check [--issue N] [--goal "..."] [--artifacts DIR] [--force]
#   shipwright preflight show                 (print last preflight.json)
#   shipwright preflight log                  (print rejection memory log)

set -euo pipefail

VERSION="3.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pipeline-preflight.sh
source "$SCRIPT_DIR/lib/pipeline-preflight.sh"

ARTIFACTS_DIR_DEFAULT=".claude/pipeline-artifacts"

usage() {
    cat <<EOF
shipwright preflight — Pre-Flight Issue Feasibility Validator

USAGE
  shipwright preflight check [options]
  shipwright preflight show
  shipwright preflight log [--tail N]

CHECK OPTIONS
  --issue N            Issue number to score
  --goal "..."         Goal text (used when --issue is absent)
  --artifacts DIR      Artifacts dir (default: ${ARTIFACTS_DIR_DEFAULT})
  --force              Run all checks, but never return BLOCK (downgrades to WARN)

EXIT CODES
  0   PASS or WARN
  1   BLOCK (pipeline should not start)
EOF
}

cmd_check() {
    local issue="" goal="" artifacts="$ARTIFACTS_DIR_DEFAULT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue)     issue="$2"; shift 2 ;;
            --goal)      goal="$2"; shift 2 ;;
            --artifacts) artifacts="$2"; shift 2 ;;
            --force)     export SW_PREFLIGHT_FORCE=true; shift ;;
            -h|--help)   usage; exit 0 ;;
            *)           echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
    preflight_validate "$issue" "$goal" "$artifacts"
}

cmd_show() {
    local path="${1:-$ARTIFACTS_DIR_DEFAULT/preflight.json}"
    if [[ ! -f "$path" ]]; then
        echo "No preflight.json at: $path" >&2
        exit 1
    fi
    cat "$path"
}

cmd_log() {
    local tail_n=20
    if [[ "${1:-}" == "--tail" ]]; then tail_n="${2:-20}"; fi
    local log="$HOME/.shipwright/memory/preflight-rejections.jsonl"
    [[ -f "$log" ]] || { echo "No rejections logged yet."; exit 0; }
    tail -n "$tail_n" "$log"
}

main() {
    local cmd="${1:-check}"
    shift 2>/dev/null || true
    case "$cmd" in
        check)        cmd_check "$@" ;;
        show)         cmd_show "$@" ;;
        log)          cmd_log "$@" ;;
        -h|--help|"") usage ;;
        *)            echo "Unknown subcommand: $cmd" >&2; usage >&2; exit 2 ;;
    esac
}

main "$@"
