#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright quickstart — One-Command Setup for Standard Projects         ║
# ║                                                                           ║
# ║  Detect project type, run init → prep → doctor in sequence with timing.  ║
# ║  Idempotent — skips init if already set up. Non-git-repos run init only. ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_epoch 2>/dev/null)" != "function" ]]; then
  now_epoch() { date +%s; }
fi

# ─── Colors ────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Flags and State ───────────────────────────────────────────────────────
SKIP_INIT=false
SKIP_PREP=false
SKIP_DOCTOR=false
FORCE=false
QUIET=false
PROJECT_TYPE=""
INIT_NEEDED=false

# Timing
START_TIME=0
PHASE_TIMES=()
PHASE_RESULTS=()

# ─── Detect Project Type ──────────────────────────────────────────────────

# Analyzes the current directory and returns a project type string
# Output: "nodejs" | "python" | "go" | "rust" | "ruby" | "java" | "unknown"
detect_project_type() {
    local type_indicator=""

    # Check for Node.js
    if [[ -f "package.json" || -f "yarn.lock" || -f "pnpm-lock.yaml" || -f "bun.lockb" ]]; then
        type_indicator="nodejs"
    fi

    # Check for Python (prioritize if both exist)
    if [[ -f "pyproject.toml" || -f "requirements.txt" || -f "setup.py" || -f "Pipfile" || -f "poetry.lock" ]]; then
        # Python takes priority over Node if both exist
        type_indicator="python"
    fi

    # Check for Go
    if [[ -f "go.mod" || -f "go.sum" ]]; then
        type_indicator="go"
    fi

    # Check for Rust
    if [[ -f "Cargo.toml" || -f "Cargo.lock" ]]; then
        type_indicator="rust"
    fi

    # Check for Ruby
    if [[ -f "Gemfile" || -f "Gemfile.lock" || -f ".ruby-version" ]]; then
        type_indicator="ruby"
    fi

    # Check for Java
    if [[ -f "pom.xml" || -f "build.gradle" || -f "build.gradle.kts" || -f "settings.gradle" ]]; then
        type_indicator="java"
    fi

    # Default to unknown if no detection
    if [[ -z "$type_indicator" ]]; then
        type_indicator="unknown"
    fi

    echo "$type_indicator"
}

# ─── Check if init is needed ──────────────────────────────────────────────

# Returns 0 (success) if .claude dir exists, 1 if not
check_init_needed() {
    if [[ -d ".claude" ]]; then
        return 1  # init not needed
    else
        return 0  # init needed
    fi
}

# ─── Run a phase with timing ──────────────────────────────────────────────

# Usage: run_phase "phase_name" "script_path" [args...]
# Outputs: (phase_name, start_time, end_time, exit_code)
run_phase() {
    local phase_name="$1"
    shift
    local script="$1"
    shift

    if ! [[ -x "$script" ]]; then
        error "Script not found or not executable: $script"
        return 1
    fi

    info "Running ${CYAN}${BOLD}${phase_name}${RESET}..."

    local phase_start
    phase_start=$(now_epoch)

    local phase_exit=0
    if "$script" "$@" || phase_exit=$?; then
        :
    fi

    local phase_end
    phase_end=$(now_epoch)
    local phase_duration=$((phase_end - phase_start))

    if [[ $phase_exit -eq 0 ]]; then
        success "${phase_name} completed in ${CYAN}${phase_duration}s${RESET}"
        PHASE_RESULTS+=("${phase_name}:success:${phase_duration}s")
    else
        error "${phase_name} failed (exit code: $phase_exit)"
        PHASE_RESULTS+=("${phase_name}:failed:${phase_duration}s")
        return $phase_exit
    fi

    return 0
}

# ─── Show Help ─────────────────────────────────────────────────────────────

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright quickstart${RESET} ${DIM}v${VERSION}${RESET}"
    echo -e "${DIM}════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "${BOLD}DESCRIPTION${RESET}"
    echo -e "  One-command setup for standard projects. Detects project type,"
    echo -e "  then runs init → prep → doctor in sequence with progress."
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright quickstart${RESET} [options]"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--skip-init${RESET}      Skip init (assumes .claude/ exists)"
    echo -e "  ${CYAN}--skip-prep${RESET}      Skip prep"
    echo -e "  ${CYAN}--skip-doctor${RESET}    Skip doctor"
    echo -e "  ${CYAN}--force${RESET}          Force re-run init (overwrites existing .claude/)"
    echo -e "  ${CYAN}--quiet${RESET}          Suppress non-essential output"
    echo -e "  ${CYAN}--help, -h${RESET}       Show this help"
    echo -e "  ${CYAN}--version${RESET}        Show version"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}# Full setup for a new project${RESET}"
    echo -e "  shipwright quickstart"
    echo ""
    echo -e "  ${DIM}# Skip init if .claude/ already exists${RESET}"
    echo -e "  shipwright quickstart --skip-init"
    echo ""
    echo -e "  ${DIM}# Force re-run init, skip prep${RESET}"
    echo -e "  shipwright quickstart --force --skip-prep"
    echo ""
}

# ─── Show Version ──────────────────────────────────────────────────────────

show_version() {
    echo -e "${CYAN}${BOLD}shipwright quickstart${RESET} ${DIM}v${VERSION}${RESET}"
}

# ─── Flag Parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-init)
            SKIP_INIT=true
            shift
            ;;
        --skip-prep)
            SKIP_PREP=true
            shift
            ;;
        --skip-doctor)
            SKIP_DOCTOR=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        --version)
            show_version
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# ─── Main Orchestration ───────────────────────────────────────────────────

main() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright quickstart${RESET} — One-Command Setup"
    echo -e "${DIM}════════════════════════════════════════════════════════════${RESET}"
    echo ""

    # Start timing
    START_TIME=$(now_epoch)

    # Detect project type
    PROJECT_TYPE=$(detect_project_type)
    if [[ "$QUIET" != "true" ]]; then
        info "Detected project type: ${CYAN}${PROJECT_TYPE}${RESET}"
    fi
    emit_event "quickstart_detect" "project_type=${PROJECT_TYPE}"

    # Determine if init is needed
    INIT_NEEDED=$(check_init_needed && echo "true" || echo "false")

    # Decide which phases to run
    RUN_INIT=false
    RUN_PREP=false
    RUN_DOCTOR=false

    # Init phase
    if [[ "$FORCE" == "true" || "$INIT_NEEDED" == "true" ]]; then
        if [[ "$SKIP_INIT" != "true" ]]; then
            RUN_INIT=true
        fi
    fi

    # Prep phase (requires git repo)
    if [[ "$SKIP_PREP" != "true" ]]; then
        if git rev-parse --show-toplevel >/dev/null 2>&1; then
            RUN_PREP=true
        elif [[ "$QUIET" != "true" ]]; then
            warn "Skipping prep — not in a git repository"
        fi
    fi

    # Doctor phase (always available)
    if [[ "$SKIP_DOCTOR" != "true" ]]; then
        RUN_DOCTOR=true
    fi

    # Show phase summary
    if [[ "$QUIET" != "true" ]]; then
        echo ""
        info "Phases to run:"
        [[ "$RUN_INIT" == "true" ]] && echo -e "  ${GREEN}✓${RESET} init"
        [[ "$RUN_PREP" == "true" ]] && echo -e "  ${GREEN}✓${RESET} prep"
        [[ "$RUN_DOCTOR" == "true" ]] && echo -e "  ${GREEN}✓${RESET} doctor"
        [[ "$RUN_INIT" == "false" && "$RUN_PREP" == "false" && "$RUN_DOCTOR" == "false" ]] && {
            warn "No phases to run. Use --force to override or --skip-* to exclude phases."
            return 0
        }
        echo ""
    fi

    # Run init
    if [[ "$RUN_INIT" == "true" ]]; then
        run_phase "init" "$SCRIPT_DIR/sw-init.sh" || return $?
    fi

    # Run prep
    if [[ "$RUN_PREP" == "true" ]]; then
        run_phase "prep" "$SCRIPT_DIR/sw-prep.sh" || return $?
    fi

    # Run doctor
    if [[ "$RUN_DOCTOR" == "true" ]]; then
        run_phase "doctor" "$SCRIPT_DIR/sw-doctor.sh" || return $?
    fi

    # Summary
    local end_time
    end_time=$(now_epoch)
    local total_duration=$((end_time - START_TIME))

    echo ""
    echo -e "${CYAN}${BOLD}Summary${RESET}"
    echo -e "${DIM}════════════════════════════════════════════════════════════${RESET}"

    for result in "${PHASE_RESULTS[@]}"; do
        local phase_name="${result%%:*}"
        local phase_status="${result#*:}"
        phase_status="${phase_status%:*}"
        local phase_time="${result##*:}"

        if [[ "$phase_status" == "success" ]]; then
            echo -e "  ${GREEN}✓${RESET} ${phase_name}: ${phase_time}"
        else
            echo -e "  ${YELLOW}⚠${RESET} ${phase_name}: failed"
        fi
    done

    echo ""
    success "Quickstart completed in ${CYAN}${total_duration}s${RESET}"
    emit_event "quickstart_complete" "duration=${total_duration}" "project_type=${PROJECT_TYPE}" "phases=$(IFS=,; echo "${PHASE_RESULTS[*]}")"
    echo ""
}

main "$@"
