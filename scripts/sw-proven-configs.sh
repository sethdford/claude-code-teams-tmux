#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright proven-configs — Manage successful pipeline configurations   ║
# ║  List, inspect, match, and maintain proven configuration patterns         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Load dependencies ──────────────────────────────────────────────────────
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/proven-configs.sh" ]] && source "$SCRIPT_DIR/lib/proven-configs.sh"

# Fallback definitions
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# ─── Commands ───────────────────────────────────────────────────────────────

cmd_help() {
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════╗
║  shipwright proven-configs — Manage successful pipeline configurations ║
╚══════════════════════════════════════════════════════════════════════════╝

USAGE:
    shipwright proven-configs <command> [options]

COMMANDS:
    list              Show all proven configurations (table format)
    show <id>         Show full details of a configuration (JSON)
    match             Find best configuration for current issue
    stats             Show aggregate statistics
    prune             Remove old/failing configurations
    reset             Clear all proven configurations (dangerous!)
    help              Show this help message

SUBCOMMAND DETAILS:

  list
    Show all proven configurations in table format
    Columns: ID | Type | Complexity | Template | Model | Confidence | Replays | Captured

  show <id>
    Display full details of a single configuration as formatted JSON
    Example: shipwright proven-configs show pc-1234567890-abcd

  match [options]
    Find best matching configuration for current issue
    Options:
      --issue <N>               Fetch issue #N from GitHub
      --type <type>             Issue type (bug, feature, chore, etc.)
      --complexity <N>          Complexity level (0-10)
      --labels <label,label>    Issue labels (comma or space separated)
    Example: shipwright proven-configs match --type bug --complexity 3

  stats
    Show aggregate statistics about captured configurations
    Output includes: total count, success rate, top issue types

  prune [options]
    Remove stale or failing configurations
    Preserves at least 3 configs per issue type
    Options:
      --max-age <days>          Remove configs older than N days (default: 90)
      --min-confidence <pct>    Remove configs with confidence < pct (default: 30)
    Confirmation required before deletion

  reset
    Delete ALL proven configurations for current repo
    Double confirmation required — use with caution!

EXAMPLES:
    # List all proven configurations
    shipwright proven-configs list

    # Find best config for a bug with complexity 3
    shipwright proven-configs match --type bug --complexity 3

    # Show details of one config
    shipwright proven-configs show pc-1234567890-xyz

    # Prune old low-confidence configs
    shipwright proven-configs prune --max-age 60 --min-confidence 50

    # Show stats
    shipwright proven-configs stats

EOF
    exit 0
}

cmd_list() {
    local repo_dir="${1:-.}"

    local repo_hash
    repo_hash=$(_proven_config_repo_hash "$repo_dir" 2>/dev/null) || repo_hash="default"

    local config_dir config_file
    config_dir=$(_proven_config_dir "$repo_hash")
    config_file="$config_dir/configs.jsonl"

    if [[ ! -f "$config_file" ]]; then
        info "No proven configurations found for this repo"
        return 0
    fi

    # Check if file is empty
    if [[ ! -s "$config_file" ]]; then
        info "No proven configurations found for this repo"
        return 0
    fi

    # Build table with jq
    echo ""
    echo "┌────────────────────┬──────┬─────────────┬──────────────┬───────┬────────┬────────┬──────────────────────┐"
    echo "│ ID                 │ Type │ Complexity  │ Template     │ Model │ Confidence │ Replays │ Captured           │"
    echo "├────────────────────┼──────┼─────────────┼──────────────┼───────┼────────┼────────┼──────────────────────┤"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        if ! jq -e '.' <<<"$line" >/dev/null 2>&1; then
            continue
        fi

        local id type complexity template model confidence replays captured_at
        id=$(echo "$line" | jq -r '.id // ""' | cut -c1-18)
        type=$(echo "$line" | jq -r '.issue_type // "?"' | cut -c1-6)
        complexity=$(echo "$line" | jq -r '.complexity // "?"')
        template=$(echo "$line" | jq -r '.config.template // "?"' | cut -c1-12)
        model=$(echo "$line" | jq -r '.config.model // "?"' | cut -c1-5)
        confidence=$(echo "$line" | jq -r '(.confidence * 100 | floor)' 2>/dev/null || echo "?")
        replays=$(echo "$line" | jq -r '.replay_count // 0')
        captured_at=$(echo "$line" | jq -r '.captured_at // "?"' | cut -c1-19)

        printf "│ %-18s │ %-4s │ %11s │ %-12s │ %-5s │ %6s%% │ %6s │ %-20s │\n" \
            "$id" "$type" "$complexity" "$template" "$model" "$confidence" "$replays" "$captured_at"
    done < <(proven_config_list "$repo_hash" 2>/dev/null | jq -r '.[] | @json' 2>/dev/null || true)

    echo "└────────────────────┴──────┴─────────────┴──────────────┴───────┴────────┴────────┴──────────────────────┘"
    echo ""
}

cmd_show() {
    local config_id="$1"
    [[ -z "$config_id" ]] && {
        error "Usage: shipwright proven-configs show <id>"
        return 1
    }

    local repo_hash
    repo_hash=$(_proven_config_repo_hash "." 2>/dev/null) || repo_hash="default"

    local config_dir config_file
    config_dir=$(_proven_config_dir "$repo_hash")
    config_file="$config_dir/configs.jsonl"

    if [[ ! -f "$config_file" ]]; then
        error "No configurations found"
        return 1
    fi

    # Find the config
    local found=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        if ! jq -e '.' <<<"$line" >/dev/null 2>&1; then
            continue
        fi

        local this_id
        this_id=$(echo "$line" | jq -r '.id // ""')
        if [[ "$this_id" == "$config_id" ]]; then
            echo "$line" | jq '.'
            found=1
            break
        fi
    done < "$config_file"

    if [[ $found -eq 0 ]]; then
        error "Configuration not found: $config_id"
        return 1
    fi
    return 0
}

cmd_match() {
    local issue_type="" complexity="" labels="" issue_number=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --issue) issue_number="$2"; shift 2 ;;
            --type) issue_type="$2"; shift 2 ;;
            --complexity) complexity="$2"; shift 2 ;;
            --labels) labels="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # If issue number provided, try to fetch from GitHub
    if [[ -n "$issue_number" && -z "${NO_GITHUB:-}" ]]; then
        info "Fetching issue metadata from GitHub..."
        # This would require GitHub API integration
        # For now, just use what was provided
        warn "GitHub integration not yet implemented in this stage"
    fi

    # Default to unknown/0 if not provided
    issue_type="${issue_type:-unknown}"
    complexity="${complexity:-5}"
    labels="${labels:-}"
    local goal_text=""

    # Try to match
    local match
    match=$(proven_config_match "$issue_type" "$complexity" "$labels" "$goal_text" "." 2>/dev/null)

    if [[ -n "$match" ]]; then
        echo "$match" | jq '.'
        local confidence score
        confidence=$(echo "$match" | jq -r '.confidence // 0')
        score=$(echo "$match" | jq -r '.score // 0')
        success "Found matching configuration (confidence: $(printf "%.0f%%" "$(echo "$confidence * 100" | bc)")  score: $score)"
        return 0
    else
        info "No matching configuration found for issue type=$issue_type complexity=$complexity"
        return 0
    fi
}

cmd_stats() {
    local repo_hash
    repo_hash=$(_proven_config_repo_hash "." 2>/dev/null) || repo_hash="default"

    local stats
    stats=$(proven_config_stats "$repo_hash")

    if [[ -z "$stats" || "$stats" == "{}" ]]; then
        info "No statistics available (no configurations captured)"
        return 0
    fi

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║         Proven Configuration Statistics                    ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    local total_configs total_replays success_rate avg_confidence
    total_configs=$(echo "$stats" | jq -r '.total_configs // 0')
    total_replays=$(echo "$stats" | jq -r '.total_replays // 0')
    success_rate=$(echo "$stats" | jq -r '.replay_success_rate // 0')
    avg_confidence=$(echo "$stats" | jq -r '.avg_confidence // 0')

    printf "  Total Configurations:  %d\n" "$total_configs"
    printf "  Total Replays:         %d\n" "$total_replays"
    printf "  Replay Success Rate:   %.1f%%\n" "$(echo "$success_rate * 100" | bc)"
    printf "  Average Confidence:    %.1f%%\n" "$(echo "$avg_confidence * 100" | bc)"

    echo ""
    echo "  Top Issue Types:"
    echo "$stats" | jq -r '.top_issue_types[] | "    • \(.type): \(.count) configs"'

    echo ""
}

cmd_prune() {
    local max_age_days=90 min_confidence=30

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-age) max_age_days="$2"; shift 2 ;;
            --min-confidence) min_confidence="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # Confirm action
    local response
    echo ""
    read -p "Remove configurations older than $max_age_days days with confidence < ${min_confidence}%? (y/N) " response
    [[ "$response" != "y" && "$response" != "Y" ]] && {
        info "Pruning cancelled"
        return 0
    }

    local repo_hash
    repo_hash=$(_proven_config_repo_hash "." 2>/dev/null) || repo_hash="default"

    # Convert min_confidence from percentage to decimal
    local min_conf_decimal
    min_conf_decimal=$(echo "scale=2; $min_confidence / 100" | bc)

    if proven_config_prune "$max_age_days" "$min_conf_decimal" "."; then
        success "Pruning complete"
    else
        warn "Pruning failed or no changes made"
    fi
}

cmd_reset() {
    echo ""
    warn "This will delete ALL proven configurations for this repository"
    echo ""
    read -p "Type 'yes' to confirm deletion: " confirm
    [[ "$confirm" != "yes" ]] && {
        info "Reset cancelled"
        return 0
    }

    local repo_hash
    repo_hash=$(_proven_config_repo_hash "." 2>/dev/null) || repo_hash="default"

    local config_dir config_file
    config_dir=$(_proven_config_dir "$repo_hash")
    config_file="$config_dir/configs.jsonl"

    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        rm -f "${config_file}.tmp."*
        success "All proven configurations deleted"
    else
        info "No configurations to delete"
    fi
}

# ─── Main Entry Point ──────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"

    case "$cmd" in
        list)    shift; cmd_list "$@" ;;
        show)    shift; cmd_show "$@" ;;
        match)   shift; cmd_match "$@" ;;
        stats)   shift; cmd_stats "$@" ;;
        prune)   shift; cmd_prune "$@" ;;
        reset)   shift; cmd_reset "$@" ;;
        help|-h|--help) cmd_help ;;
        *)
            error "Unknown command: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
