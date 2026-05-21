#!/usr/bin/env bash
# Success Pattern Injection Engine CLI
# Subcommands: index, score, inject, report, forget

VERSION="3.3.0"

set -euo pipefail
ERR_TRAP_DEPTH=0
trap 'ERR_TRAP_DEPTH=$((ERR_TRAP_DEPTH+1)); if [[ $ERR_TRAP_DEPTH -le 1 ]]; then error "Error in sw-success-patterns.sh line $LINENO"; fi' ERR

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/compat.sh"
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/success-patterns.sh"

# ==============================================================================
# Help
# ==============================================================================

help() {
    cat <<'EOF'
shipwright success-patterns v3.3.0 — Success Pattern Injection Engine

USAGE
  shipwright success-patterns <command> [options]

COMMANDS
  index <file>          Load and validate pattern index
  score <incoming.json> Score incoming against patterns
  inject <goal>         Generate injection snippet and id
  report                Show effectiveness metrics
  forget <injection_id> Remove outcome record

EXAMPLES
  shipwright success-patterns index ~/.shipwright/memory/patterns.json
  shipwright success-patterns inject "Fix flaky tests"
  shipwright success-patterns report
EOF
}

# ==============================================================================
# Commands
# ==============================================================================

cmd_index() {
    local file="${1:-}"
    if [[ -z "$file" ]]; then
        error "Missing pattern file path"
        return 1
    fi
    if [[ ! -f "$file" ]]; then
        error "Pattern file not found: $file"
        return 1
    fi

    info "Indexing patterns from $file"
    local patterns
    patterns=$(sp_load_patterns "$file" 2>/dev/null || echo "[]")
    echo "$patterns" | jq '.' 2>/dev/null || echo "[]"
}

cmd_score() {
    local incoming_file="${1:-}"
    if [[ -z "$incoming_file" ]]; then
        error "Missing incoming JSON file"
        return 1
    fi
    if [[ ! -f "$incoming_file" ]]; then
        error "Incoming file not found: $incoming_file"
        return 1
    fi

    info "Scoring incoming against patterns"
    local incoming patterns pattern_file
    incoming=$(jq -c '.' "$incoming_file" 2>/dev/null || echo "{}")

    # Find pattern file
    pattern_file=$(find "${HOME}/.shipwright/memory" -name "success-patterns.json" -type f 2>/dev/null | head -1)
    if [[ -z "$pattern_file" ]] || [[ ! -f "$pattern_file" ]]; then
        info "No pattern file found"
        echo "[]"
        return 0
    fi

    patterns=$(sp_load_patterns "$pattern_file" 2>/dev/null || echo "[]")
    patterns=$(echo "$patterns" | jq -r 'if type == "array" then . else if .patterns then .patterns else [] end end' 2>/dev/null || echo "[]")

    local top
    top=$(sp_top_k "$incoming" "$patterns" 3 0.30)
    echo "$top" | jq '.'
}

cmd_inject() {
    local goal="${1:-}"
    if [[ -z "$goal" ]]; then
        error "Missing goal description"
        return 1
    fi

    info "Generating injection for: $goal"
    sp_inject_for_loop "$goal" | jq '.'
}

cmd_report() {
    info "Effectiveness metrics"
    sp_effectiveness_report | jq '.'
}

cmd_forget() {
    local injection_id="${1:-}"
    if [[ -z "$injection_id" ]]; then
        error "Missing injection_id"
        return 1
    fi

    info "Removing outcome record for $injection_id"
    local outcomes_file="${HOME}/.shipwright/memory/injection-outcomes.jsonl"
    if [[ -f "$outcomes_file" ]]; then
        grep -v "\"injection_id\": \"$injection_id\"" "$outcomes_file" > "$outcomes_file.tmp"
        mv "$outcomes_file.tmp" "$outcomes_file"
        success "Removed $injection_id"
    else
        warn "No outcomes file found"
    fi
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    local cmd="${1:-}"

    case "$cmd" in
        index) shift; cmd_index "$@" ;;
        score) shift; cmd_score "$@" ;;
        inject) shift; cmd_inject "$@" ;;
        report) shift; cmd_report "$@" ;;
        forget) shift; cmd_forget "$@" ;;
        -h|--help|help) help; return 0 ;;
        '') help; return 1 ;;
        *) error "Unknown command: $cmd"; help; return 1 ;;
    esac
}

main "$@"
