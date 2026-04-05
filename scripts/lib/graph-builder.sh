#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  graph-builder.sh — Build JSON dependency graph from parsed pairs       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Usage: source this, then pipe dependency pairs into build_graph
# Input: lines of "source_file|target_file" on stdin
# Output: JSON graph to stdout

# Build a JSON dependency graph from stdin lines of "source|target".
# Args: $1 = root_dir (for making paths relative)
# Output: JSON { nodes: [...], edges: [...] } to stdout
build_graph() {
    local root_dir="${1:-.}"
    root_dir="$(cd "$root_dir" && pwd)"

    local tmp_edges tmp_nodes
    tmp_edges="$(mktemp)"
    tmp_nodes="$(mktemp)"

    # Collect unique nodes and edges
    local nodes_seen=""
    local edge_count=0

    while IFS='|' read -r source target; do
        [[ -z "$source" || -z "$target" ]] && continue

        # Make paths relative to root_dir
        local rel_source rel_target
        rel_source="${source#"$root_dir/"}"
        rel_target="${target#"$root_dir/"}"

        # Track nodes
        echo "$rel_source" >> "$tmp_nodes"
        echo "$rel_target" >> "$tmp_nodes"

        # Track edges
        echo "$rel_source|$rel_target" >> "$tmp_edges"
        ((edge_count++)) || true
    done

    # Build unique node list with in-degree counts
    local unique_nodes
    unique_nodes="$(sort -u "$tmp_nodes")"

    # Calculate in-degree for each node
    local json_nodes="["
    local first=true
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        local in_degree=0
        # Count lines ending with "|<node>" — use awk for reliability
        in_degree=$(awk -F'|' -v t="$node" '$2 == t {c++} END {print c+0}' "$tmp_edges")
        local node_type="script"
        if [[ "$node" == *"/lib/"* ]]; then
            node_type="library"
        fi

        if [[ "$first" == "true" ]]; then
            first=false
        else
            json_nodes+=","
        fi
        json_nodes+="$(printf '{"id":"%s","type":"%s","in_degree":%d}' "$node" "$node_type" "$in_degree")"
    done <<< "$unique_nodes"
    json_nodes+="]"

    # Build edges array
    local json_edges="["
    first=true
    while IFS='|' read -r source target; do
        [[ -z "$source" || -z "$target" ]] && continue
        if [[ "$first" == "true" ]]; then
            first=false
        else
            json_edges+=","
        fi
        json_edges+="$(printf '{"source":"%s","target":"%s"}' "$source" "$target")"
    done < "$tmp_edges"
    json_edges+="]"

    # Output complete graph JSON
    printf '{"nodes":%s,"edges":%s}' "$json_nodes" "$json_edges"

    rm -f "$tmp_edges" "$tmp_nodes"
}

# Write graph JSON to a file atomically.
# Args: $1 = output_path, stdin = dependency pairs, $2 = root_dir
write_graph() {
    local output_path="$1"
    local root_dir="${2:-.}"
    local tmp_file
    tmp_file="$(mktemp)"

    build_graph "$root_dir" > "$tmp_file"

    # Prettify with jq if available
    if command -v jq >/dev/null 2>&1; then
        jq '.' "$tmp_file" > "${tmp_file}.pretty" && mv "${tmp_file}.pretty" "$tmp_file"
    fi

    local output_dir
    output_dir="$(dirname "$output_path")"
    mkdir -p "$output_dir"
    mv "$tmp_file" "$output_path"
}
