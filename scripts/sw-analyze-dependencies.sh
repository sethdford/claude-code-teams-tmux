#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-analyze-dependencies.sh — Script Dependency Graph Analyzer          ║
# ║                                                                          ║
# ║  Parses all scripts/*.sh for source/. statements, builds a dependency   ║
# ║  graph, detects circular dependencies and coupling hotspots, generates  ║
# ║  reports with refactoring suggestions and Mermaid visualizations.       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.3.0"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

# Source library modules
# shellcheck source=lib/dependency-parser.sh
source "$SCRIPT_DIR/lib/dependency-parser.sh"
# shellcheck source=lib/graph-builder.sh
source "$SCRIPT_DIR/lib/graph-builder.sh"
# shellcheck source=lib/graph-analysis.sh
source "$SCRIPT_DIR/lib/graph-analysis.sh"
# shellcheck source=lib/report-generator.sh
source "$SCRIPT_DIR/lib/report-generator.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────
DEFAULT_SCAN_DIR=""  # Set to repo root/scripts at runtime
DEFAULT_GRAPH_PATH="${HOME}/.shipwright/dependency-graph.json"
DEFAULT_REPORT_PATH=""  # Set to repo root/scripts/coupling-report.md at runtime
DEFAULT_THRESHOLD=10

# ─── Help text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright analyze dependencies [OPTIONS]

DESCRIPTION
  Analyzes bash script dependencies by parsing source/. statements,
  building a dependency graph, detecting circular dependencies,
  and identifying coupling hotspots.

OPTIONS
  --help, -h          Show this help text
  --version, -v       Show version
  --scan-dir DIR      Directory to scan (default: scripts/)
  --output FILE       Graph JSON output path (default: ~/.shipwright/dependency-graph.json)
  --report FILE       Markdown report output path (default: scripts/coupling-report.md)
  --threshold N       In-degree threshold for hotspots (default: 10)
  --json              Output results as JSON to stdout
  --quiet, -q         Suppress progress output

EXAMPLES
  shipwright analyze dependencies                     Full analysis with defaults
  shipwright analyze dependencies --threshold 5       Lower hotspot threshold
  shipwright analyze dependencies --json              JSON output for scripting
  shipwright analyze dependencies --scan-dir ./lib    Scan specific directory

EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    local scan_dir=""
    local graph_path="$DEFAULT_GRAPH_PATH"
    local report_path=""
    local threshold="$DEFAULT_THRESHOLD"
    local json_output=false
    local quiet=false

    # Find repo root
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    # Parse arguments
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
            --scan-dir)
                scan_dir="$2"
                shift 2
                ;;
            --output)
                graph_path="$2"
                shift 2
                ;;
            --report)
                report_path="$2"
                shift 2
                ;;
            --threshold)
                threshold="$2"
                shift 2
                ;;
            --json)
                json_output=true
                shift
                ;;
            --quiet|-q)
                quiet=true
                shift
                ;;
            dependencies)
                # Sub-command consumed by the router
                shift
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Apply defaults that depend on repo_root
    [[ -z "$scan_dir" ]] && scan_dir="$repo_root/scripts"
    [[ -z "$report_path" ]] && report_path="$repo_root/scripts/coupling-report.md"

    # JSON mode implies quiet (stdout must be clean JSON)
    [[ "$json_output" == "true" ]] && quiet=true

    # Validate scan directory
    if [[ ! -d "$scan_dir" ]]; then
        error "Scan directory not found: $scan_dir"
        exit 1
    fi

    # Pre-flight: check for jq
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required but not found. Install with: brew install jq (macOS) or apt install jq (Linux)"
        exit 1
    fi

    [[ "$quiet" == "false" ]] && info "Scanning dependencies in: $scan_dir"

    # Step 1: Parse dependencies
    local tmp_pairs
    tmp_pairs="$(mktemp)"
    trap 'rm -f "${tmp_pairs:-}"' EXIT

    parse_directory "$scan_dir" "*.sh" > "$tmp_pairs"

    local pair_count
    pair_count=$(wc -l < "$tmp_pairs" | tr -d ' ')
    [[ "$quiet" == "false" ]] && info "Found $pair_count dependency relationships"

    # Step 2: Build graph
    [[ "$quiet" == "false" ]] && info "Building dependency graph..."
    write_graph "$graph_path" "$repo_root" < "$tmp_pairs"
    [[ "$quiet" == "false" ]] && success "Graph written to: $graph_path"

    # Step 3: Analyze
    [[ "$quiet" == "false" ]] && info "Detecting cycles..."
    local cycles
    cycles="$(detect_cycles "$graph_path")"
    local cycle_count
    cycle_count="$(echo "$cycles" | jq 'length')"

    [[ "$quiet" == "false" ]] && info "Finding coupling hotspots (threshold: $threshold)..."
    local hotspots
    hotspots="$(find_hotspots "$graph_path" "$threshold")"
    local hotspot_count
    hotspot_count="$(echo "$hotspots" | jq 'length')"

    # Step 4: Generate report
    [[ "$quiet" == "false" ]] && info "Generating report..."
    generate_report "$graph_path" "$report_path" "$threshold"
    [[ "$quiet" == "false" ]] && success "Report written to: $report_path"

    # Step 5: Output results
    if [[ "$json_output" == "true" ]]; then
        local stats
        stats="$(graph_stats "$graph_path")"
        jq -n --argjson stats "$stats" \
              --argjson cycles "$cycles" \
              --argjson hotspots "$hotspots" \
              --arg graph_path "$graph_path" \
              --arg report_path "$report_path" '{
            graph_path: $graph_path,
            report_path: $report_path,
            stats: $stats,
            cycles: $cycles,
            hotspots: $hotspots
        }'
    else
        [[ "$quiet" == "false" ]] && echo ""
        [[ "$quiet" == "false" ]] && echo "┌──────────────────────────────────────────────┐"
        [[ "$quiet" == "false" ]] && echo "│       Dependency Analysis Results             │"
        [[ "$quiet" == "false" ]] && echo "└──────────────────────────────────────────────┘"

        local stats
        stats="$(graph_stats "$graph_path")"
        local node_count edge_count
        node_count="$(echo "$stats" | jq -r '.nodes')"
        edge_count="$(echo "$stats" | jq -r '.edges')"

        [[ "$quiet" == "false" ]] && info "Scripts analyzed: $node_count"
        [[ "$quiet" == "false" ]] && info "Dependencies found: $edge_count"

        if [[ "$cycle_count" -gt 0 ]]; then
            warn "Circular dependencies: $cycle_count"
        else
            success "No circular dependencies"
        fi

        if [[ "$hotspot_count" -gt 0 ]]; then
            warn "Coupling hotspots: $hotspot_count"
            echo "$hotspots" | jq -r '.[] | "  \(.id) (in-degree: \(.in_degree))"'
        else
            success "No coupling hotspots above threshold"
        fi

        [[ "$quiet" == "false" ]] && echo ""
        [[ "$quiet" == "false" ]] && info "Full report: $report_path"
        [[ "$quiet" == "false" ]] && info "Graph JSON: $graph_path"
    fi
}

main "$@"
