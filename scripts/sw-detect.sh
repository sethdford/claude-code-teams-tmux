#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-detect.sh — Project-type auto-detection and template recommendation  ║
# ║                                                                          ║
# ║  Detects project language, framework, test runner, and recommends the    ║
# ║  optimal pipeline template based on project characteristics.            ║
# ║                                                                          ║
# ║  Usage:                                                                  ║
# ║    shipwright detect                    # Report for current repo         ║
# ║    shipwright detect --json             # JSON output                     ║
# ║    shipwright detect --help             # Show help                       ║
# ║    shipwright detect --version          # Show version                    ║
# ║    shipwright detect /path/to/project   # Detect specific path            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
VERSION="3.3.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallback output helpers
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift
    mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# shellcheck source=lib/project-detect.sh
[[ -f "$SCRIPT_DIR/lib/project-detect.sh" ]] && source "$SCRIPT_DIR/lib/project-detect.sh" || {
  error "Required library project-detect.sh not found"
  exit 1
}

# ═══════════════════════════════════════════════════════════════════════════
# Flags & Defaults
# ═══════════════════════════════════════════════════════════════════════════
PROJECT_ROOT="."
OUTPUT_FORMAT="human"  # human or json
VERBOSITY="normal"

# ═══════════════════════════════════════════════════════════════════════════
# Parse arguments
# ═══════════════════════════════════════════════════════════════════════════
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            OUTPUT_FORMAT="json"
            ;;
        --help)
            cat <<'EOF'
usage: shipwright detect [OPTIONS] [PATH]

Auto-detect project type and recommend optimal pipeline template.

OPTIONS:
  --json                Print output as JSON (parseable by jq)
  --help                Show this help message
  --version             Show version

ARGUMENTS:
  PATH                  Project root directory (defaults to current directory)

EXAMPLES:
  # Detect the current repository
  shipwright detect

  # Detect another directory
  shipwright detect /path/to/project

  # Get JSON output for scripting
  shipwright detect --json

  # Parse with jq
  shipwright detect --json | jq .recommended_template

EOF
            exit 0
            ;;
        --version)
            echo "shipwright detect v${VERSION}"
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            exit 1
            ;;
        *)
            # Positional argument: project root
            PROJECT_ROOT="$1"
            ;;
    esac
    shift
done

# ═══════════════════════════════════════════════════════════════════════════
# Validate project root
# ═══════════════════════════════════════════════════════════════════════════
if [[ ! -d "$PROJECT_ROOT" ]]; then
    error "Project root not found: $PROJECT_ROOT"
    exit 1
fi

# Normalize to absolute path
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)" || exit 1

# ═══════════════════════════════════════════════════════════════════════════
# Run detection
# ═══════════════════════════════════════════════════════════════════════════
project_data=$(project_detect_all "$PROJECT_ROOT" 2>/dev/null || echo "{}")

if [[ "$project_data" == "{}" ]] || [[ -z "$project_data" ]]; then
    error "Failed to detect project type"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# Output
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # Emit event
    emit_event "detect.completed" \
        "root=$PROJECT_ROOT" \
        "type=$(echo "$project_data" | jq -r '.type // "unknown"')" \
        "template=$(echo "$project_data" | jq -r '.recommended_template.template // "unknown"')"

    # Output JSON
    echo "$project_data"
else
    # Human-readable output
    type=$(echo "$project_data" | jq -r '.type // "unknown"')
    framework=$(echo "$project_data" | jq -r '.framework // "unknown"')
    build_tool=$(echo "$project_data" | jq -r '.build_tool // "unknown"')
    test_runner=$(echo "$project_data" | jq -r '.test_runner // "unknown"')
    template=$(echo "$project_data" | jq -r '.recommended_template.template // "standard"')
    confidence=$(echo "$project_data" | jq -r '.recommended_template.confidence // 0')
    reason=$(echo "$project_data" | jq -r '.recommended_template.reason // ""')

    echo ""
    info "Project Detection Results"
    echo ""
    echo "  Project Root:         $PROJECT_ROOT"
    echo "  Language:             $type"
    echo "  Framework:            $framework"
    echo "  Build Tool:           $build_tool"
    echo "  Test Runner:          $test_runner"
    echo ""
    echo "  Recommended Template: $template"
    echo "  Confidence:           ${confidence}%"
    echo "  Reason:               $reason"
    echo ""

    # Emit event
    emit_event "detect.completed" \
        "root=$PROJECT_ROOT" \
        "type=$type" \
        "template=$template" \
        "confidence=$confidence"
fi

exit 0
