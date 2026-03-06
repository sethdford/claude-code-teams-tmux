#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-detect.sh — Project Type Auto-Detection                             ║
# ║                                                                          ║
# ║  Detects project type (web/cli/library/infrastructure), language,       ║
# ║  framework, and recommends a pipeline template with confidence score.   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.2.4"
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

# Require jq
if ! command -v jq >/dev/null 2>&1; then
    error "jq is required but not installed. Install with: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
fi

# Source detection library
# shellcheck source=lib/project-type-detection.sh
source "$SCRIPT_DIR/lib/project-type-detection.sh"

# ─── Help text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright detect [OPTIONS] [PATH]

DESCRIPTION
  Auto-detect project type, language, framework, and recommend a pipeline
  template. Analyzes filesystem signals to classify projects as web apps,
  CLI tools, libraries, or infrastructure.

OPTIONS
  --json           Machine-readable JSON output
  --generate       Generate .claude/project-detection.json config file
  --help, -h       Show this help text
  --version, -v    Show version

ARGUMENTS
  PATH             Project root directory (default: current directory)

EXAMPLES
  shipwright detect                     Detect current project
  shipwright detect --json              Machine-readable output
  shipwright detect --generate          Generate config files
  shipwright detect /path/to/project    Detect specific project

EOF
}

# ─── Human-readable output ──────────────────────────────────────────────────
print_detection() {
    local detection="$1"
    local recommendation="$2"

    local lang framework project_type confidence
    lang=$(echo "$detection" | jq -r '.language')
    framework=$(echo "$detection" | jq -r '.framework')
    project_type=$(echo "$detection" | jq -r '.project_type')
    confidence=$(echo "$detection" | jq -r '.confidence')

    echo ""
    echo -e "\033[38;2;0;212;255m\033[1m  Project Detection Results\033[0m"
    echo -e "\033[2m  ─────────────────────────────────────────\033[0m"
    echo ""
    echo -e "  Language:      \033[1m${lang}\033[0m"
    echo -e "  Framework:     \033[1m${framework}\033[0m"
    echo -e "  Project Type:  \033[1m${project_type}\033[0m"

    # Confidence with color coding
    local conf_color
    if [[ "$confidence" -ge 70 ]]; then
        conf_color="\033[38;2;74;222;128m"   # green
    elif [[ "$confidence" -ge 40 ]]; then
        conf_color="\033[38;2;250;204;21m"   # yellow
    else
        conf_color="\033[38;2;248;113;113m"  # red
    fi
    echo -e "  Confidence:    ${conf_color}\033[1m${confidence}%\033[0m"

    # Package manager and test info
    local pkg_mgr test_fw test_cmd build_cmd
    pkg_mgr=$(echo "$detection" | jq -r '.package_manager')
    test_fw=$(echo "$detection" | jq -r '.test_framework')
    test_cmd=$(echo "$detection" | jq -r '.test_cmd')
    build_cmd=$(echo "$detection" | jq -r '.build_cmd')

    echo ""
    [[ "$pkg_mgr" != "unknown" ]] && echo -e "  Package Mgr:   ${pkg_mgr}"
    [[ "$test_fw" != "unknown" ]] && echo -e "  Test Framework: ${test_fw}"
    [[ -n "$test_cmd" ]]         && echo -e "  Test Command:  ${test_cmd}"
    [[ -n "$build_cmd" ]]        && echo -e "  Build Command: ${build_cmd}"

    # Signals
    local signal_count
    signal_count=$(echo "$detection" | jq '.signals | length')
    if [[ "$signal_count" -gt 0 ]]; then
        echo ""
        echo -e "  \033[2mSignals:\033[0m"
        echo "$detection" | jq -r '.signals[]' | while IFS= read -r signal; do
            echo -e "    \033[2m- ${signal}\033[0m"
        done
    fi

    # Secondary types
    local sec_count
    sec_count=$(echo "$detection" | jq '.secondary_types | length')
    if [[ "$sec_count" -gt 0 ]]; then
        echo ""
        echo -e "  \033[2mSecondary types:\033[0m"
        echo "$detection" | jq -r '.secondary_types[] | "    \(.type): \(.confidence)%"'
    fi

    # Template recommendation
    if [[ -n "$recommendation" ]]; then
        local template rationale
        template=$(echo "$recommendation" | jq -r '.template')
        rationale=$(echo "$recommendation" | jq -r '.rationale')
        echo ""
        echo -e "\033[38;2;0;212;255m\033[1m  Template Recommendation\033[0m"
        echo -e "\033[2m  ─────────────────────────────────────────\033[0m"
        echo ""
        echo -e "  Template:      \033[1m${template}\033[0m"
        echo -e "  Rationale:     ${rationale}"

        local alt_template alt_rationale
        alt_template=$(echo "$recommendation" | jq -r '.alternatives[0].template // ""')
        alt_rationale=$(echo "$recommendation" | jq -r '.alternatives[0].rationale // ""')
        if [[ -n "$alt_template" ]]; then
            echo -e "  \033[2mAlternative:   ${alt_template} — ${alt_rationale}\033[0m"
        fi

        echo ""
        echo -e "  \033[2mRecommended agents:\033[0m"
        echo "$recommendation" | jq -r '.recommended_agents[]' | while IFS= read -r agent; do
            echo -e "    \033[2m- ${agent}\033[0m"
        done
    fi
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local json_mode=false
    local generate_mode=false
    local project_path=""

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
                json_mode=true
                shift
                ;;
            --generate)
                generate_mode=true
                shift
                ;;
            -*)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                project_path="$1"
                shift
                ;;
        esac
    done

    local root="${project_path:-$(pwd)}"
    if [[ ! -d "$root" ]]; then
        error "Directory does not exist: $root"
        exit 1
    fi

    # Run detection
    local detection
    detection=$(detect_project_type "$root")

    # Get recommendation
    local recommendation
    recommendation=$(recommend_template "$detection")

    if $generate_mode; then
        generate_project_config "$root" "$detection" > /dev/null
        success "Generated .claude/project-detection.json"
        if ! $json_mode; then
            print_detection "$detection" "$recommendation"
        fi
    fi

    if $json_mode; then
        # Combine detection and recommendation into one JSON
        jq -n \
            --argjson detection "$detection" \
            --argjson recommendation "$recommendation" \
            '{ detection: $detection, recommendation: $recommendation }'
    elif ! $generate_mode; then
        print_detection "$detection" "$recommendation"
    fi
}

main "$@"
