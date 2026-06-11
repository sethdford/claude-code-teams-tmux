#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright setup-auto — Zero-Config Project Auto-Setup                    ║
# ║                                                                          ║
# ║  One command: detect project, check deps, generate tuned config +        ║
# ║  language-specific agents, then validate. Targets <5 minutes end-to-end. ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034  # VERSION kept for consistency/version reporting
VERSION="3.3.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility + helpers ────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
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

# Core intelligent-defaults library (detection, config, agents).
# shellcheck source=lib/setup-auto.sh
source "$SCRIPT_DIR/lib/setup-auto.sh"

# ── Colors (fall back to empty when helpers absent) ──
: "${CYAN:=}" "${GREEN:=}" "${YELLOW:=}" "${RED:=}" "${BOLD:=}" "${DIM:=}" "${RESET:=}"

# Time budget for the whole run, in seconds (5 minutes). Configurable for tests.
TIME_BUDGET_SECONDS="${SW_SETUP_AUTO_BUDGET:-300}"

# Required external tools and their install hints.
REQUIRED_TOOLS="jq tmux gh claude"

usage() {
    cat <<EOF
${BOLD}shipwright setup-auto${RESET} — Zero-config project auto-setup

${BOLD}USAGE${RESET}
  shipwright setup-auto [PATH] [options]

${BOLD}ARGUMENTS${RESET}
  PATH                 Project directory to set up (default: current directory)

${BOLD}OPTIONS${RESET}
  --dry-run            Detect and report only; write no files
  --no-doctor          Skip the final 'shipwright doctor' validation
  -h, --help           Show this help

${BOLD}WHAT IT DOES${RESET}
  1. Detects language, framework, package manager, and test runner
  2. Scores project complexity (0-100) and checks required tools in parallel
  3. Generates a complexity-tuned .claude/daemon-config.json (existing settings win)
  4. Generates a language-specific specialist agent in .claude/agents/
  5. Validates the result with 'shipwright doctor' and prints next steps

Completes in under ${TIME_BUDGET_SECONDS}s on a standard repo.
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# install_hint(tool) — actionable install command for a missing tool.
# ─────────────────────────────────────────────────────────────────────────────
install_hint() {
    case "$1" in
        jq)     echo "brew install jq   |   apt-get install -y jq" ;;
        tmux)   echo "brew install tmux |   apt-get install -y tmux" ;;
        gh)     echo "brew install gh   |   see https://cli.github.com" ;;
        claude) echo "npm install -g @anthropic-ai/claude-code" ;;
        *)      echo "(see project documentation)" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# check_dependencies() — probe required tools concurrently, report status.
# Writes one '<tool> <0|1>' line per tool to stdout. Exit status is the count
# of missing tools (0 = all present).
# ─────────────────────────────────────────────────────────────────────────────
check_dependencies() {
    local probe_dir tool
    probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-deps.XXXXXX") || return 1

    # Fan out: one background probe per tool (bounded — small fixed set).
    for tool in $REQUIRED_TOOLS; do
        ( command -v "$tool" >/dev/null 2>&1 && echo "1" > "$probe_dir/$tool" \
            || echo "0" > "$probe_dir/$tool" ) &
    done
    wait

    local missing=0
    for tool in $REQUIRED_TOOLS; do
        local present
        present=$(cat "$probe_dir/$tool" 2>/dev/null || echo "0")
        echo "$tool $present"
        [[ "$present" == "1" ]] || missing=$((missing + 1))
    done

    rm -rf "$probe_dir"
    return "$missing"
}

# ─── Argument parsing ───────────────────────────────────────────────────────
DRY_RUN=false
RUN_DOCTOR=true
PROJECT_ROOT="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true ;;
        --no-doctor) RUN_DOCTOR=false ;;
        -h|--help)   usage; exit 0 ;;
        -*)          error "Unknown option: $1"; usage; exit 1 ;;
        *)           PROJECT_ROOT="$1" ;;
    esac
    shift
done

if [[ ! -d "$PROJECT_ROOT" ]]; then
    error "Project directory does not exist: $PROJECT_ROOT"
    exit 1
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

# ─── Run ────────────────────────────────────────────────────────────────────
START_EPOCH=$(now_epoch)

echo ""
echo -e "${CYAN}${BOLD}▸ Zero-Config Auto-Setup${RESET}  ${DIM}${PROJECT_ROOT}${RESET}"
$DRY_RUN && echo -e "  ${YELLOW}(dry-run — no files will be written)${RESET}"
echo ""

# 1. Detect project ----------------------------------------------------------
echo -e "${BOLD}Detect${RESET}  ${DIM}language / framework / tooling${RESET}"
detection=$(project_detect_type "$PROJECT_ROOT" 2>/dev/null || echo '{}')
proj_type=$(echo "$detection" | jq -r '.type // "unknown"')
proj_framework=$(echo "$detection" | jq -r '.framework // "unknown"')
proj_build=$(echo "$detection" | jq -r '.build_tool // "unknown"')
proj_test=$(echo "$detection" | jq -r '.test_runner // "unknown"')
success "type: ${proj_type}   framework: ${proj_framework}   build: ${proj_build}   tests: ${proj_test}"

# 2. Complexity score + dependency check (independent — report both) ---------
echo ""
echo -e "${BOLD}Analyze${RESET}  ${DIM}complexity + required tools${RESET}"
cx=$(setup_auto_complexity_score "$PROJECT_ROOT")
score=$(echo "$cx" | jq -r '.score')
band=$(setup_auto_complexity_band "$score")
success "complexity: ${score}/100 (${band})"

dep_status=0
dep_lines=$(check_dependencies) || dep_status=$?
while read -r tool present; do
    [[ -z "$tool" ]] && continue
    if [[ "$present" == "1" ]]; then
        success "${tool} present"
    else
        warn "${tool} missing — install: $(install_hint "$tool")"
    fi
done <<< "$dep_lines"

# 3 + 4. Generate config and agents (skipped in dry-run) ---------------------
if $DRY_RUN; then
    echo ""
    info "dry-run: would generate config (template for '${band}') and a '${proj_type}' specialist agent"
else
    echo ""
    echo -e "${BOLD}Generate${RESET}  ${DIM}config + agents${RESET}"
    config_file=$(setup_auto_generate_config "$PROJECT_ROOT" "$score")
    success "config: ${config_file}"

    agent_file=$(setup_auto_generate_agents "$PROJECT_ROOT" "$proj_type" || true)
    if [[ -n "$agent_file" ]]; then
        success "agent: ${agent_file}"
    else
        info "no specialist agent template for '${proj_type}' (or already present)"
    fi
fi

# 5. Validate ----------------------------------------------------------------
if $RUN_DOCTOR && ! $DRY_RUN; then
    echo ""
    echo -e "${BOLD}Validate${RESET}  ${DIM}shipwright doctor${RESET}"
    if [[ -x "$SCRIPT_DIR/sw-doctor.sh" ]]; then
        if ( cd "$PROJECT_ROOT" && "$SCRIPT_DIR/sw-doctor.sh" >/dev/null 2>&1 ); then
            success "doctor: all checks passed"
        else
            warn "doctor reported issues — run 'shipwright doctor' for details"
        fi
    else
        warn "doctor unavailable — skipping validation"
    fi
fi

# ─── Summary + timing budget ────────────────────────────────────────────────
END_EPOCH=$(now_epoch)
ELAPSED=$(( END_EPOCH - START_EPOCH ))

echo ""
echo -e "${DIM}────────────────────────────────────────${RESET}"
if [[ "$ELAPSED" -le "$TIME_BUDGET_SECONDS" ]]; then
    success "Auto-setup complete in ${ELAPSED}s ${DIM}(budget ${TIME_BUDGET_SECONDS}s)${RESET}"
else
    warn "Auto-setup took ${ELAPSED}s — over the ${TIME_BUDGET_SECONDS}s budget"
fi

echo ""
echo -e "${BOLD}Next steps${RESET}"
if [[ "$dep_status" -gt 0 ]]; then
    echo -e "  ${YELLOW}•${RESET} Install the ${dep_status} missing tool(s) listed above"
fi
echo -e "  ${CYAN}•${RESET} Review .claude/daemon-config.json (tuned for '${band}' complexity)"
echo -e "  ${CYAN}•${RESET} Run ${BOLD}shipwright pipeline start --goal \"...\"${RESET} to deliver your first feature"
echo -e "  ${CYAN}•${RESET} Run ${BOLD}shipwright daemon start${RESET} to auto-process labeled issues"
echo ""

# Setup itself succeeded; missing deps are advisory (reported above), not fatal.
exit 0
