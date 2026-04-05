#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  graph-analysis.sh — Cycle detection & coupling hotspot analysis        ║
# ║  Implements Tarjan's SCC algorithm in bash for cycle detection          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage: source this, then call detect_cycles <graph.json> or find_hotspots <graph.json>

# ─── Tarjan's SCC algorithm ─────────────────────────────────────────────────
# Detects strongly connected components (cycles) in the dependency graph.
# Args: $1 = path to graph JSON file
# Output: JSON array of cycles to stdout
detect_cycles() {
    local graph_file="$1"
    [[ -f "$graph_file" ]] || { echo "[]"; return 0; }

    # Use jq to extract adjacency list and run Tarjan's in a single pass
    # Strategy: build adjacency list, then DFS-based cycle detection
    jq -r '.edges[] | "\(.source)|\(.target)"' "$graph_file" 2>/dev/null | _tarjan_scc
}

# Internal: Tarjan's SCC via iterative DFS
# Input: lines of "source|target" on stdin
# Output: JSON array of cycles (SCCs with >1 node)
_tarjan_scc() {
    local tmp_adj tmp_result
    tmp_adj="$(mktemp)"
    tmp_result="$(mktemp)"

    # Read edges into temp file
    cat > "$tmp_adj"

    # Extract unique nodes
    local all_nodes
    all_nodes="$(awk -F'|' '{print $1; print $2}' "$tmp_adj" | sort -u)"
    local node_count
    node_count=$(echo "$all_nodes" | grep -c . 2>/dev/null || true)
    node_count=$(echo "$node_count" | tr -d '[:space:]')
    [[ "$node_count" =~ ^[0-9]+$ ]] || node_count=0

    if [[ "$node_count" -eq 0 ]]; then
        echo "[]"
        return 0
    fi

    # Build node index mapping (node -> integer)
    local -a node_list
    local -a node_index node_lowlink node_on_stack
    local -a stack
    local index=0
    local stack_top=-1
    local i=0

    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        node_list[$i]="$node"
        node_index[$i]=-1
        node_lowlink[$i]=0
        node_on_stack[$i]=0
        ((i++)) || true
    done <<< "$all_nodes"

    local total_nodes=$i

    # Helper: find index of node in node_list
    _find_node_idx() {
        local target="$1"
        local j
        for ((j=0; j<total_nodes; j++)); do
            if [[ "${node_list[$j]}" == "$target" ]]; then
                echo "$j"
                return 0
            fi
        done
        echo "-1"
    }

    # Build adjacency list as flat arrays
    # adj_targets[i] = space-separated list of target indices for node i
    local -a adj_targets
    for ((i=0; i<total_nodes; i++)); do
        adj_targets[$i]=""
    done

    while IFS='|' read -r src tgt; do
        [[ -z "$src" || -z "$tgt" ]] && continue
        local src_idx tgt_idx
        src_idx=$(_find_node_idx "$src")
        tgt_idx=$(_find_node_idx "$tgt")
        [[ "$src_idx" -eq -1 || "$tgt_idx" -eq -1 ]] && continue
        adj_targets[$src_idx]="${adj_targets[$src_idx]} $tgt_idx"
    done < "$tmp_adj"

    # Iterative Tarjan's using explicit call stack
    local -a call_stack  # format: "node|child_index|is_root"
    local cycles_json="["
    local first_cycle=true

    _strongconnect() {
        local v="$1"
        node_index[$v]=$index
        node_lowlink[$v]=$index
        ((index++)) || true
        ((stack_top++)) || true
        stack[$stack_top]=$v
        node_on_stack[$v]=1

        # Process neighbors
        local neighbors="${adj_targets[$v]}"
        local w
        for w in $neighbors; do
            [[ -z "$w" ]] && continue
            if [[ "${node_index[$w]}" -eq -1 ]]; then
                _strongconnect "$w"
                if [[ "${node_lowlink[$w]}" -lt "${node_lowlink[$v]}" ]]; then
                    node_lowlink[$v]=${node_lowlink[$w]}
                fi
            elif [[ "${node_on_stack[$w]}" -eq 1 ]]; then
                if [[ "${node_index[$w]}" -lt "${node_lowlink[$v]}" ]]; then
                    node_lowlink[$v]=${node_index[$w]}
                fi
            fi
        done

        # If v is a root node, pop the SCC
        if [[ "${node_lowlink[$v]}" -eq "${node_index[$v]}" ]]; then
            local -a scc_members
            local scc_size=0
            local popped
            while true; do
                popped=${stack[$stack_top]}
                ((stack_top--)) || true
                node_on_stack[$popped]=0
                scc_members[$scc_size]="${node_list[$popped]}"
                ((scc_size++)) || true
                [[ "$popped" -eq "$v" ]] && break
            done

            # Only report SCCs with >1 member (actual cycles)
            if [[ "$scc_size" -gt 1 ]]; then
                local cycle_json="["
                local first_member=true
                local m
                for ((m=0; m<scc_size; m++)); do
                    if [[ "$first_member" == "true" ]]; then
                        first_member=false
                    else
                        cycle_json+=","
                    fi
                    cycle_json+="\"${scc_members[$m]}\""
                done
                cycle_json+="]"

                if [[ "$first_cycle" == "true" ]]; then
                    first_cycle=false
                else
                    cycles_json+=","
                fi
                cycles_json+="$cycle_json"
            fi
        fi
    }

    # Run Tarjan's from each unvisited node
    for ((i=0; i<total_nodes; i++)); do
        if [[ "${node_index[$i]}" -eq -1 ]]; then
            _strongconnect "$i"
        fi
    done

    cycles_json+="]"
    echo "$cycles_json"

    rm -f "$tmp_adj" "$tmp_result"
}

# ─── Coupling hotspot detection ──────────────────────────────────────────────
# Find nodes with in-degree above threshold.
# Args: $1 = graph JSON file, $2 = threshold (default: 10)
# Output: JSON array of hotspots sorted by in-degree descending
find_hotspots() {
    local graph_file="$1"
    local threshold="${2:-10}"

    [[ -f "$graph_file" ]] || { echo "[]"; return 0; }

    jq --argjson threshold "$threshold" '
        [.nodes[] | select(.in_degree >= $threshold)]
        | sort_by(-.in_degree)
    ' "$graph_file"
}

# Get dependents for a specific node.
# Args: $1 = graph JSON file, $2 = node id
# Output: JSON array of source nodes that depend on the given node
get_dependents() {
    local graph_file="$1"
    local node_id="$2"

    jq --arg node "$node_id" '
        [.edges[] | select(.target == $node) | .source]
        | unique
    ' "$graph_file"
}

# ─── Graph statistics ───────────────────────────────────────────────────────
# Calculate summary statistics for the graph.
# Args: $1 = graph JSON file
# Output: JSON object with stats
graph_stats() {
    local graph_file="$1"
    [[ -f "$graph_file" ]] || { echo '{"nodes":0,"edges":0,"libraries":0,"scripts":0}'; return 0; }

    jq '{
        nodes: (.nodes | length),
        edges: (.edges | length),
        libraries: ([.nodes[] | select(.type == "library")] | length),
        scripts: ([.nodes[] | select(.type == "script")] | length),
        max_in_degree: ([.nodes[].in_degree] | max // 0),
        avg_in_degree: (([.nodes[].in_degree] | add // 0) / ([.nodes | length, 1] | max))
    }' "$graph_file"
}
