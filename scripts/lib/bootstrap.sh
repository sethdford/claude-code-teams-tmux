#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright bootstrap — Boilerplate consolidation + initialization       ║
# ║                                                                          ║
# ║  Part 1: Boilerplate elimination (SCRIPT_DIR, ERR trap, library loading) ║
# ║  Part 2: Cold-start initialization (optimization, memory defaults)       ║
# ║  Part 3: Helper functions (show_help_header for standard boxed headers) ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# ─── Module Guard (prevent double-sourcing) ─────────────────────────────
[[ -n "${_SW_BOOTSTRAP_LOADED:-}" ]] && return 0
_SW_BOOTSTRAP_LOADED=1

# ─── Part 1: Boilerplate Elimination ───────────────────────────────────
#
# SCRIPT_DIR Resolution: Caller's BASH_SOURCE[0] is expected to be in scripts/
# We derive SCRIPT_DIR from the call stack, skipping lib/ sources.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    # Find the first non-lib caller (skip lib/bootstrap.sh itself)
    for _src in "${BASH_SOURCE[@]}"; do
        if [[ "$_src" != *"/lib/"* && "$_src" != "$BASH_SOURCE" ]]; then
            SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
            break
        fi
    done
    # Fallback if all sources are in lib/
    if [[ -z "${SCRIPT_DIR:-}" ]]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        SCRIPT_DIR="${SCRIPT_DIR%/lib}"  # strip /lib suffix if present
    fi
fi
export SCRIPT_DIR

# Set up ERR trap (if not already set)
if [[ "$(trap -p ERR)" == "" ]]; then
    trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR
fi

# Source lib/compat.sh (cross-platform compatibility)
# shellcheck source=./compat.sh
if [[ -f "$SCRIPT_DIR/lib/compat.sh" ]]; then
    source "$SCRIPT_DIR/lib/compat.sh"
fi

# Source lib/helpers.sh (colors, output, timestamps)
# shellcheck source=./helpers.sh
if [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]]; then
    source "$SCRIPT_DIR/lib/helpers.sh"
fi

# Fallbacks (when helpers not loaded, e.g. test env)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# Color fallbacks (when NO_COLOR is set or lib/helpers.sh not sourced)
if [[ -z "${CYAN:-}" ]]; then
    CYAN='\033[38;2;0;212;255m'
    PURPLE='\033[38;2;124;58;237m'
    BLUE='\033[38;2;0;102;255m'
    GREEN='\033[38;2;74;222;128m'
    YELLOW='\033[38;2;250;204;21m'
    RED='\033[38;2;248;113;113m'
    DIM='\033[2m'
    BOLD='\033[1m'
    RESET='\033[0m'
fi

if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
    now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
    now_epoch() { date +%s; }
fi

if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
    emit_event() {
        local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
        # shellcheck disable=SC2155
        local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
        while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
        echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
    }
fi

# ─── Part 3: Standard Header Helper ────────────────────────────────────
#
# show_help_header — Prints a standard boxed header with script name, description, and version.
# Usage:
#   show_help_header "Script Name" "Optional description line"
show_help_header() {
    local name="$1"
    local desc="${2:-}"

    echo ""
    if [[ -n "$desc" ]]; then
        echo -e "${CYAN}${BOLD}  ${name}${RESET}  ${DIM}v${VERSION:-unknown}${RESET}"
        echo -e "${DIM}  $(printf '%0.s═' $(seq 1 42))${RESET}"
        echo ""
        echo -e "  ${desc}"
    else
        echo -e "${CYAN}${BOLD}  ${name}${RESET}  ${DIM}v${VERSION:-unknown}${RESET}"
        echo -e "${DIM}  $(printf '%0.s═' $(seq 1 42))${RESET}"
    fi
    echo ""
}

# ─── Part 2: Cold-Start Initialization ────────────────────────────────
#
# bootstrap_optimization — create default iteration model, template weights, model routing
bootstrap_optimization() {
    local opt_dir="$HOME/.shipwright/optimization"
    mkdir -p "$opt_dir"

    # Default iteration model based on common patterns
    if [[ ! -f "$opt_dir/iteration-model.json" ]]; then
        cat > "$opt_dir/iteration-model.json" << 'JSON'
{
    "low": {"mean": 5, "stddev": 2, "samples": 0, "source": "bootstrap"},
    "medium": {"mean": 12, "stddev": 4, "samples": 0, "source": "bootstrap"},
    "high": {"mean": 25, "stddev": 8, "samples": 0, "source": "bootstrap"}
}
JSON
    fi

    # Default template weights
    if [[ ! -f "$opt_dir/template-weights.json" ]]; then
        cat > "$opt_dir/template-weights.json" << 'JSON'
{
    "standard": 1.0,
    "hotfix": 1.0,
    "docs": 1.0,
    "refactor": 1.0,
    "source": "bootstrap"
}
JSON
    fi

    # Default model routing
    if [[ ! -f "$opt_dir/model-routing.json" ]]; then
        cat > "$opt_dir/model-routing.json" << 'JSON'
{
    "routes": {
        "plan": {"recommended": "opus", "source": "bootstrap"},
        "design": {"recommended": "opus", "source": "bootstrap"},
        "build": {"recommended": "sonnet", "source": "bootstrap"},
        "test": {"recommended": "sonnet", "source": "bootstrap"},
        "review": {"recommended": "sonnet", "source": "bootstrap"}
    },
    "default": "sonnet",
    "source": "bootstrap"
}
JSON
    fi
}

# bootstrap_memory — create initial memory patterns based on project type
bootstrap_memory() {
    local mem_dir="$HOME/.shipwright/memory"
    mkdir -p "$mem_dir"

    if [[ ! -f "$mem_dir/patterns.json" ]]; then
        # Detect project type and create initial patterns
        local project_type="unknown"
        [[ -f "package.json" ]] && project_type="nodejs"
        [[ -f "requirements.txt" || -f "pyproject.toml" ]] && project_type="python"
        [[ -f "Cargo.toml" ]] && project_type="rust"
        [[ -f "go.mod" ]] && project_type="go"

        cat > "$mem_dir/patterns.json" << JSON
{
    "project_type": "$project_type",
    "detected_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "source": "bootstrap"
}
JSON
    fi
}
