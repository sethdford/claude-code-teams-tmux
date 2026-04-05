#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-analyze.sh — Script Dependency Graph Analyzer                        ║
# ║                                                                          ║
# ║  Parses source/. statements, builds dependency graph, detects cycles     ║
# ║  and coupling hotspots, generates reports in Markdown + Mermaid.         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.3.0"
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

# ─── Defaults ───────────────────────────────────────────────────────────────
DEFAULT_THRESHOLD=10
DEFAULT_MERMAID_LIMIT=30
SHIPWRIGHT_DIR="${SHIPWRIGHT_DIR:-$HOME/.shipwright}"

# ─── Temp file cleanup ─────────────────────────────────────────────────────
TMPFILES=()
cleanup() {
    local f
    for f in "${TMPFILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    [[ -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

make_tmp() {
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/sw-analyze.XXXXXX")"
    TMPFILES+=("$f")
    echo "$f"
}

# ─── Help ───────────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright analyze [dependencies] [OPTIONS]

DESCRIPTION
  Analyzes script dependency graph, detects circular dependencies
  and high-coupling hotspots, generates reports.

OPTIONS
  --dir PATH         Directory to scan (default: scripts/ in repo root)
  --threshold N      In-degree threshold for hotspot detection (default: 10)
  --json             Output dependency graph as JSON to stdout
  --report           Generate coupling-report.md (default action)
  --mermaid          Output Mermaid flowchart to stdout
  --output PATH      Output path for report (default: scripts/coupling-report.md)
  --help, -h         Show this help text
  --version, -v      Show version

EXAMPLES
  shipwright analyze dependencies              Full analysis with report
  shipwright analyze --json                    JSON graph to stdout
  shipwright analyze --mermaid                 Mermaid diagram to stdout
  shipwright analyze --threshold 5             Lower hotspot threshold
  shipwright analyze --dir /path/to/scripts    Scan custom directory

EOF
}

# ─── Stage 1: Parse Dependencies ───────────────────────────────────────────
# Scans all .sh files for source/. statements
# Output: TSV lines to edges_file (source_script\ttarget_script\tconditional)
parse_dependencies() {
    local script_dir="$1"
    local edges_file="$2"

    : > "$edges_file"

    local script_file base_name line target conditional rel_target
    while IFS= read -r script_file; do
        base_name="${script_file#"$script_dir"/}"

        while IFS= read -r line; do
            # Skip comments (lines starting with optional whitespace + #)
            case "$line" in
                *'#'*) ;;
            esac

            conditional="false"
            target=""

            # Pattern 1: [[ -f "..." ]] && source "..."
            if echo "$line" | grep -qE '\]\]\s*&&\s*(source|\.)'; then
                conditional="true"
                target="$(echo "$line" | sed -E 's/.*\]\]\s*&&\s*(source|\.)\s+//' | sed -E 's/^["'\'']//' | sed -E 's/["'\'']\s*$//' | sed -E 's/["'\''].*//')"
            # Pattern 2: source "..." or . "..."
            elif echo "$line" | grep -qE '^\s*(source|\.)\s+'; then
                target="$(echo "$line" | sed -E 's/^\s*(source|\.)\s+//' | sed -E 's/^["'\'']//' | sed -E 's/["'\'']\s*$//' | sed -E 's/["'\''].*//')"
            fi

            [[ -z "$target" ]] && continue

            # Resolve $SCRIPT_DIR to the relative base
            target="$(echo "$target" | sed -E 's/\$\{?SCRIPT_DIR\}?/scripts/' | sed -E 's/\$\{?_COMPAT\}?/scripts\/lib\/compat.sh/')"

            # Strip leading ./ if present
            target="${target#./}"

            # Skip targets that still contain unresolved variables
            case "$target" in
                *'$'*) continue ;;
            esac

            # Normalize: if target starts with scripts/ keep it, otherwise prefix
            case "$target" in
                scripts/*) rel_target="$target" ;;
                *) rel_target="$target" ;;
            esac

            printf '%s\t%s\t%s\n' "$base_name" "$rel_target" "$conditional" >> "$edges_file"
        done < <(grep -E '(source|\.\s+).*\$' "$script_file" 2>/dev/null || true)

    done < <(find "$script_dir" -name '*.sh' -type f 2>/dev/null | sort)
}

# ─── Stage 2: Build Graph JSON ─────────────────────────────────────────────
build_graph_json() {
    local edges_file="$1"
    local graph_json="$2"

    local tmp_json
    tmp_json="$(make_tmp)"

    # Collect unique nodes from edges
    local nodes_file
    nodes_file="$(make_tmp)"
    {
        cut -f1 "$edges_file"
        cut -f2 "$edges_file"
    } | sort -u > "$nodes_file"

    # Build nodes array
    local nodes_json="[]"
    local node node_type
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        case "$node" in
            */lib/*) node_type="library" ;;
            *-test.sh) node_type="test" ;;
            *) node_type="script" ;;
        esac
        nodes_json="$(echo "$nodes_json" | jq --arg id "$node" --arg type "$node_type" '. + [{"id": $id, "type": $type}]')"
    done < "$nodes_file"

    # Build edges array
    local edges_json="[]"
    local src tgt cond
    while IFS=$'\t' read -r src tgt cond; do
        [[ -z "$src" || -z "$tgt" ]] && continue
        edges_json="$(echo "$edges_json" | jq --arg source "$src" --arg target "$tgt" --arg conditional "$cond" '. + [{"source": $source, "target": $target, "conditional": ($conditional == "true")}]')"
    done < "$edges_file"

    # Assemble graph
    local gen_at
    gen_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
    jq -n \
        --arg generated_at "$gen_at" \
        --arg version "1.0" \
        --argjson nodes "$nodes_json" \
        --argjson edges "$edges_json" \
        '{generated_at: $generated_at, version: $version, nodes: $nodes, edges: $edges}' \
        > "$tmp_json"

    # Atomic write
    mv "$tmp_json" "$graph_json"
}

# ─── Stage 3a: Cycle Detection (DFS) ───────────────────────────────────────
# Uses temp files for visited/stack tracking (Bash 3.2 safe)
detect_cycles() {
    local graph_json="$1"

    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sw-analyze-dfs.XXXXXX")"
    local adj_dir="$TMP_DIR/adj"
    local visited_file="$TMP_DIR/visited"
    local stack_file="$TMP_DIR/stack"
    local cycles_file="$TMP_DIR/cycles"
    mkdir -p "$adj_dir"
    : > "$visited_file"
    : > "$cycles_file"

    # Build adjacency lists as files
    local edge_count
    edge_count="$(jq '.edges | length' "$graph_json")"
    local i=0
    while [[ $i -lt $edge_count ]]; do
        local src tgt
        src="$(jq -r ".edges[$i].source" "$graph_json")"
        tgt="$(jq -r ".edges[$i].target" "$graph_json")"
        # Sanitize for filename: replace / with __
        local src_safe
        src_safe="$(echo "$src" | sed 's|/|__|g')"
        echo "$tgt" >> "$adj_dir/$src_safe"
        i=$((i + 1))
    done

    # DFS function
    _dfs_visit() {
        local node="$1"
        local path="$2"

        # Already fully visited — skip
        if grep -qxF "$node" "$visited_file" 2>/dev/null; then
            return
        fi

        # On current stack — cycle found
        if grep -qxF "$node" "$stack_file" 2>/dev/null; then
            echo "${path} -> ${node}" >> "$cycles_file"
            return
        fi

        echo "$node" >> "$stack_file"

        local node_safe neighbor
        node_safe="$(echo "$node" | sed 's|/|__|g')"
        if [[ -f "$adj_dir/$node_safe" ]]; then
            while IFS= read -r neighbor; do
                [[ -z "$neighbor" ]] && continue
                _dfs_visit "$neighbor" "${path} -> ${neighbor}"
            done < "$adj_dir/$node_safe"
        fi

        echo "$node" >> "$visited_file"
        # Remove from stack
        local stack_tmp
        stack_tmp="$(make_tmp)"
        grep -vxF "$node" "$stack_file" > "$stack_tmp" 2>/dev/null || true
        mv "$stack_tmp" "$stack_file"
    }

    # Run DFS from all nodes
    local node_count
    node_count="$(jq '.nodes | length' "$graph_json")"
    local j=0
    while [[ $j -lt $node_count ]]; do
        local node
        node="$(jq -r ".nodes[$j].id" "$graph_json")"
        : > "$stack_file"
        if ! grep -qxF "$node" "$visited_file" 2>/dev/null; then
            _dfs_visit "$node" "$node"
        fi
        j=$((j + 1))
    done

    # Output cycles
    if [[ -s "$cycles_file" ]]; then
        cat "$cycles_file"
        return 1
    fi
    return 0
}

# ─── Stage 3b: Compute Metrics ─────────────────────────────────────────────
compute_metrics() {
    local graph_json="$1"
    local threshold="${2:-$DEFAULT_THRESHOLD}"

    jq --argjson threshold "$threshold" '
    . as $graph |
    {
        total_nodes: (.nodes | length),
        total_edges: (.edges | length),
        nodes: [
            .nodes[] | . as $node |
            {
                id: .id,
                type: .type,
                in_degree: ([$graph.edges[] | select(.target == $node.id)] | length),
                out_degree: ([$graph.edges[] | select(.source == $node.id)] | length)
            }
        ] | sort_by(-.in_degree),
        hotspots: [
            .nodes[] | . as $node |
            {
                id: .id,
                type: .type,
                in_degree: ([$graph.edges[] | select(.target == $node.id)] | length),
                dependents: [$graph.edges[] | select(.target == $node.id) | .source]
            }
            | select(.in_degree >= $threshold)
        ] | sort_by(-.in_degree)
    }
    ' < "$graph_json"
}

# ─── Stage 4: Generate Report ──────────────────────────────────────────────
generate_report() {
    local graph_json="$1"
    local metrics_json="$2"
    local cycles_output="$3"
    local output_path="$4"

    local tmp_report
    tmp_report="$(make_tmp)"

    local total_nodes total_edges hotspot_count
    total_nodes="$(echo "$metrics_json" | jq '.total_nodes')"
    total_edges="$(echo "$metrics_json" | jq '.total_edges')"
    hotspot_count="$(echo "$metrics_json" | jq '.hotspots | length')"

    local cycle_count=0
    if [[ -n "$cycles_output" ]]; then
        cycle_count="$(echo "$cycles_output" | grep -c '.' || true)"
    fi

    cat > "$tmp_report" <<EOF
# Script Dependency Analysis Report

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)

## Summary

| Metric | Value |
|--------|-------|
| Total scripts | $total_nodes |
| Total dependency edges | $total_edges |
| Circular dependencies | $cycle_count |
| Coupling hotspots | $hotspot_count |

EOF

    # Cycles section
    if [[ $cycle_count -gt 0 ]]; then
        cat >> "$tmp_report" <<'EOF'
## Circular Dependencies

The following circular dependency chains were detected:

EOF
        echo "$cycles_output" | while IFS= read -r cycle; do
            echo "- \`$cycle\`" >> "$tmp_report"
        done
        echo "" >> "$tmp_report"
    else
        echo "## Circular Dependencies" >> "$tmp_report"
        echo "" >> "$tmp_report"
        echo "No circular dependencies detected." >> "$tmp_report"
        echo "" >> "$tmp_report"
    fi

    # Hotspots section
    if [[ $hotspot_count -gt 0 ]]; then
        cat >> "$tmp_report" <<'EOF'
## Coupling Hotspots

Scripts with high in-degree (many dependents) represent coupling risks:

| Script | Type | In-Degree | Dependents |
|--------|------|-----------|------------|
EOF
        echo "$metrics_json" | jq -r '.hotspots[] | "| `\(.id)` | \(.type) | \(.in_degree) | \(.dependents | join(", ")) |"' >> "$tmp_report"
        echo "" >> "$tmp_report"

        cat >> "$tmp_report" <<'EOF'
### Refactoring Suggestions

EOF
        echo "$metrics_json" | jq -r '.hotspots[] | "- **\(.id)** (in-degree: \(.in_degree)): Consider splitting into smaller, focused modules to reduce coupling."' >> "$tmp_report"
        echo "" >> "$tmp_report"
    else
        echo "## Coupling Hotspots" >> "$tmp_report"
        echo "" >> "$tmp_report"
        echo "No coupling hotspots detected at current threshold." >> "$tmp_report"
        echo "" >> "$tmp_report"
    fi

    # Top 10 by in-degree
    cat >> "$tmp_report" <<'EOF'
## Top 10 Most-Depended-On Scripts

| Rank | Script | In-Degree | Out-Degree |
|------|--------|-----------|------------|
EOF
    echo "$metrics_json" | jq -r '.nodes[:10] | to_entries[] | "| \(.key + 1) | `\(.value.id)` | \(.value.in_degree) | \(.value.out_degree) |"' >> "$tmp_report"
    echo "" >> "$tmp_report"

    # Mermaid diagram
    cat >> "$tmp_report" <<'EOF'
## Dependency Graph (Top 30)

```mermaid
EOF
    generate_mermaid "$graph_json" >> "$tmp_report"
    cat >> "$tmp_report" <<'EOF'
```
EOF

    # Atomic write
    mv "$tmp_report" "$output_path"
}

# ─── Stage 4 (alt): Mermaid ────────────────────────────────────────────────
generate_mermaid() {
    local graph_json="$1"
    local limit="${2:-$DEFAULT_MERMAID_LIMIT}"

    # Get top N nodes by total degree (in + out)
    local top_nodes
    top_nodes="$(jq -r --argjson limit "$limit" '
        . as $graph |
        [.nodes[] | . as $node | {
            id: .id,
            degree: (
                ([$graph.edges[] | select(.target == $node.id)] | length) +
                ([$graph.edges[] | select(.source == $node.id)] | length)
            )
        }] | sort_by(-.degree) | .[:$limit] | .[].id
    ' "$graph_json" 2>/dev/null || true)"

    echo "flowchart TD"

    # Create node definitions with sanitized IDs
    local node_id safe_id label
    while IFS= read -r node_id; do
        [[ -z "$node_id" ]] && continue
        safe_id="$(echo "$node_id" | sed 's|[/.-]|_|g')"
        label="$(basename "$node_id" .sh)"
        echo "    ${safe_id}[\"${label}\"]"
    done <<< "$top_nodes"

    # Add edges between included nodes
    local top_nodes_file
    top_nodes_file="$(make_tmp)"
    echo "$top_nodes" > "$top_nodes_file"

    local edge_count src tgt
    edge_count="$(jq '.edges | length' "$graph_json")"
    local i=0
    while [[ $i -lt $edge_count ]]; do
        src="$(jq -r ".edges[$i].source" "$graph_json")"
        tgt="$(jq -r ".edges[$i].target" "$graph_json")"
        # Only include if both nodes are in top set
        if grep -qxF "$src" "$top_nodes_file" 2>/dev/null && grep -qxF "$tgt" "$top_nodes_file" 2>/dev/null; then
            local safe_src safe_tgt
            safe_src="$(echo "$src" | sed 's|[/.-]|_|g')"
            safe_tgt="$(echo "$tgt" | sed 's|[/.-]|_|g')"
            echo "    ${safe_src} --> ${safe_tgt}"
        fi
        i=$((i + 1))
    done
}

# ─── Main ───────────────────────────────────────────────────────────────────
main() {
    # Skip "dependencies" subcommand if present
    case "${1:-}" in
        dependencies|deps) shift ;;
    esac

    local scan_dir=""
    local threshold="$DEFAULT_THRESHOLD"
    local mode="report"
    local output_path=""

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
            --dir)
                scan_dir="${2:-}"
                [[ -z "$scan_dir" ]] && { error "Missing argument for --dir"; exit 1; }
                shift 2
                ;;
            --threshold)
                threshold="${2:-}"
                [[ -z "$threshold" ]] && { error "Missing argument for --threshold"; exit 1; }
                # Validate integer
                case "$threshold" in
                    *[!0-9]*) error "Threshold must be a positive integer"; exit 1 ;;
                esac
                shift 2
                ;;
            --json)
                mode="json"
                shift
                ;;
            --report)
                mode="report"
                shift
                ;;
            --mermaid)
                mode="mermaid"
                shift
                ;;
            --output)
                output_path="${2:-}"
                [[ -z "$output_path" ]] && { error "Missing argument for --output"; exit 1; }
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Prerequisites
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required but not installed"
        exit 1
    fi

    # Determine scan directory
    if [[ -z "$scan_dir" ]]; then
        local repo_root
        repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
        if [[ -n "$repo_root" && -d "$repo_root/scripts" ]]; then
            scan_dir="$repo_root/scripts"
        else
            scan_dir="$(pwd)/scripts"
        fi
    fi

    if [[ ! -d "$scan_dir" ]]; then
        error "Directory not found: $scan_dir"
        exit 1
    fi

    # Check for .sh files
    local file_count
    file_count="$(find "$scan_dir" -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$file_count" -eq 0 ]]; then
        error "No .sh files found in $scan_dir"
        exit 1
    fi

    info "Scanning $file_count scripts in $scan_dir" >&2

    # Stage 1: Parse
    local edges_file
    edges_file="$(make_tmp)"
    parse_dependencies "$scan_dir" "$edges_file"

    local edge_count
    edge_count="$(wc -l < "$edges_file" | tr -d ' ')"
    info "Found $edge_count dependency edges" >&2

    # Stage 2: Build graph JSON
    mkdir -p "$SHIPWRIGHT_DIR"
    local graph_json="$SHIPWRIGHT_DIR/dependency-graph.json"
    local graph_tmp
    graph_tmp="$(make_tmp)"
    build_graph_json "$edges_file" "$graph_tmp"

    # Copy to canonical location
    cp "$graph_tmp" "$graph_json"

    local node_count
    node_count="$(jq '.nodes | length' "$graph_tmp")"
    info "Built graph: $node_count nodes, $edge_count edges" >&2

    # Stage 3a: Cycle detection
    local cycles_output=""
    local has_cycles=0
    cycles_output="$(detect_cycles "$graph_tmp" 2>/dev/null)" || has_cycles=1

    if [[ $has_cycles -eq 1 ]]; then
        local cycle_count
        cycle_count="$(echo "$cycles_output" | grep -c '.' || true)"
        warn "Detected $cycle_count circular dependency chain(s)" >&2
    else
        success "No circular dependencies" >&2
    fi

    # Stage 3b: Metrics
    local metrics_json
    metrics_json="$(compute_metrics "$graph_tmp" "$threshold")"

    local hotspot_count
    hotspot_count="$(echo "$metrics_json" | jq '.hotspots | length')"
    if [[ $hotspot_count -gt 0 ]]; then
        warn "$hotspot_count coupling hotspot(s) detected (threshold: $threshold)" >&2
    else
        success "No coupling hotspots (threshold: $threshold)" >&2
    fi

    # Output based on mode
    case "$mode" in
        json)
            jq '.' "$graph_tmp"
            ;;
        mermaid)
            generate_mermaid "$graph_tmp"
            ;;
        report)
            if [[ -z "$output_path" ]]; then
                output_path="$scan_dir/coupling-report.md"
            fi
            generate_report "$graph_tmp" "$metrics_json" "$cycles_output" "$output_path"
            success "Report written to $output_path" >&2
            success "Graph saved to $graph_json" >&2
            ;;
    esac
}

main "$@"
