#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  report-generator.sh — Markdown report + Mermaid diagram generation     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage: source this, then call generate_report <graph.json> <output.md>

# Generate a full coupling report in markdown format.
# Args: $1 = graph JSON, $2 = output markdown path, $3 = hotspot threshold
generate_report() {
    local graph_file="$1"
    local output_path="$2"
    local threshold="${3:-10}"

    [[ -f "$graph_file" ]] || { echo "Error: graph file not found: $graph_file" >&2; return 1; }

    local tmp_report
    tmp_report="$(mktemp)"

    # Get stats
    local stats
    stats="$(graph_stats "$graph_file")"
    local node_count edge_count lib_count script_count max_degree
    node_count="$(echo "$stats" | jq -r '.nodes')"
    edge_count="$(echo "$stats" | jq -r '.edges')"
    lib_count="$(echo "$stats" | jq -r '.libraries')"
    script_count="$(echo "$stats" | jq -r '.scripts')"
    max_degree="$(echo "$stats" | jq -r '.max_in_degree')"

    # Get cycles
    local cycles
    cycles="$(detect_cycles "$graph_file")"
    local cycle_count
    cycle_count="$(echo "$cycles" | jq 'length')"

    # Get hotspots
    local hotspots
    hotspots="$(find_hotspots "$graph_file" "$threshold")"
    local hotspot_count
    hotspot_count="$(echo "$hotspots" | jq 'length')"

    # Write report
    cat > "$tmp_report" <<EOF
# Dependency Graph Analysis Report

Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Summary

| Metric | Value |
|--------|-------|
| Total scripts | $node_count |
| Total dependencies | $edge_count |
| Library scripts | $lib_count |
| Command scripts | $script_count |
| Max in-degree | $max_degree |
| Circular dependencies | $cycle_count |
| Coupling hotspots (>= $threshold) | $hotspot_count |

EOF

    # Cycles section
    if [[ "$cycle_count" -gt 0 ]]; then
        echo "## Circular Dependencies" >> "$tmp_report"
        echo "" >> "$tmp_report"
        echo "The following circular dependency chains were detected:" >> "$tmp_report"
        echo "" >> "$tmp_report"

        local i
        for ((i=0; i<cycle_count; i++)); do
            local cycle_members
            cycle_members="$(echo "$cycles" | jq -r ".[$i][]")"
            echo "### Cycle $((i+1))" >> "$tmp_report"
            echo "" >> "$tmp_report"
            echo '```' >> "$tmp_report"
            echo "$cycle_members" | tr '\n' ' -> ' | sed 's/ -> $/\n/' >> "$tmp_report"
            echo '```' >> "$tmp_report"
            echo "" >> "$tmp_report"
            echo "**Recommendation**: Break this cycle by extracting shared logic into a separate module or using lazy loading." >> "$tmp_report"
            echo "" >> "$tmp_report"
        done
    else
        echo "## Circular Dependencies" >> "$tmp_report"
        echo "" >> "$tmp_report"
        echo "No circular dependencies detected." >> "$tmp_report"
        echo "" >> "$tmp_report"
    fi

    # Hotspots section
    if [[ "$hotspot_count" -gt 0 ]]; then
        echo "## Coupling Hotspots" >> "$tmp_report"
        echo "" >> "$tmp_report"
        echo "Scripts with in-degree >= $threshold (high coupling):" >> "$tmp_report"
        echo "" >> "$tmp_report"
        echo "| Script | Type | In-Degree | Dependents |" >> "$tmp_report"
        echo "|--------|------|-----------|------------|" >> "$tmp_report"

        local j
        for ((j=0; j<hotspot_count; j++)); do
            local hs_id hs_type hs_degree
            hs_id="$(echo "$hotspots" | jq -r ".[$j].id")"
            hs_type="$(echo "$hotspots" | jq -r ".[$j].type")"
            hs_degree="$(echo "$hotspots" | jq -r ".[$j].in_degree")"

            local dependents
            dependents="$(get_dependents "$graph_file" "$hs_id" | jq -r '.[]' | head -5)"
            local dep_preview
            dep_preview="$(echo "$dependents" | tr '\n' ', ' | sed 's/,$//')"
            local total_deps
            total_deps="$(get_dependents "$graph_file" "$hs_id" | jq 'length')"
            if [[ "$total_deps" -gt 5 ]]; then
                dep_preview="$dep_preview, ... (+$((total_deps - 5)) more)"
            fi

            echo "| \`$hs_id\` | $hs_type | $hs_degree | $dep_preview |" >> "$tmp_report"
        done

        echo "" >> "$tmp_report"

        # Refactoring suggestions
        echo "### Refactoring Suggestions" >> "$tmp_report"
        echo "" >> "$tmp_report"

        for ((j=0; j<hotspot_count; j++)); do
            local hs_id hs_degree
            hs_id="$(echo "$hotspots" | jq -r ".[$j].id")"
            hs_degree="$(echo "$hotspots" | jq -r ".[$j].in_degree")"

            echo "$((j+1)). **\`$hs_id\`** (in-degree: $hs_degree)" >> "$tmp_report"
            if [[ "$hs_degree" -ge 20 ]]; then
                echo "   - **Critical**: This script is a major coupling point. Consider splitting into focused sub-modules." >> "$tmp_report"
            elif [[ "$hs_degree" -ge 15 ]]; then
                echo "   - **High**: Extract distinct responsibilities into separate library files." >> "$tmp_report"
            else
                echo "   - **Moderate**: Monitor growth. Consider extracting if more dependents are added." >> "$tmp_report"
            fi
            echo "" >> "$tmp_report"
        done
    else
        echo "## Coupling Hotspots" >> "$tmp_report"
        echo "" >> "$tmp_report"
        echo "No coupling hotspots detected (threshold: in-degree >= $threshold)." >> "$tmp_report"
        echo "" >> "$tmp_report"
    fi

    # Mermaid diagram
    echo "## Dependency Graph (Mermaid)" >> "$tmp_report"
    echo "" >> "$tmp_report"
    _generate_mermaid "$graph_file" "$threshold" >> "$tmp_report"

    # Write atomically
    local output_dir
    output_dir="$(dirname "$output_path")"
    mkdir -p "$output_dir"
    mv "$tmp_report" "$output_path"
}

# Generate Mermaid diagram showing hotspots and their connections.
# For large graphs, only show hotspots + their immediate neighbors.
_generate_mermaid() {
    local graph_file="$1"
    local threshold="${2:-10}"

    echo '```mermaid'
    echo 'graph LR'

    # For large graphs, only render hotspot subgraph
    local node_count
    node_count="$(jq '.nodes | length' "$graph_file")"

    if [[ "$node_count" -gt 50 ]]; then
        echo '    %% Showing hotspot subgraph only (full graph too large)'
        # Show hotspot nodes and their direct edges
        jq -r --argjson threshold "$threshold" '
            (.nodes[] | select(.in_degree >= $threshold) | .id) as $hotspots |
            .edges[] | select(.target == $hotspots) |
            "    \(.source | gsub("[^a-zA-Z0-9]"; "_")) [\(.source | split("/") | last)] --> \(.target | gsub("[^a-zA-Z0-9]"; "_")) [\(.target | split("/") | last)]"
        ' "$graph_file" 2>/dev/null | sort -u | head -100
    else
        # Small graph: render everything
        jq -r '
            .edges[] |
            "    \(.source | gsub("[^a-zA-Z0-9]"; "_")) [\(.source | split("/") | last)] --> \(.target | gsub("[^a-zA-Z0-9]"; "_")) [\(.target | split("/") | last)]"
        ' "$graph_file" 2>/dev/null | sort -u
    fi

    # Style hotspot nodes
    jq -r --argjson threshold "$threshold" '
        .nodes[] | select(.in_degree >= $threshold) |
        "    style \(.id | gsub("[^a-zA-Z0-9]"; "_")) fill:#f43f5e,color:#fff"
    ' "$graph_file" 2>/dev/null || true

    echo '```'
}
