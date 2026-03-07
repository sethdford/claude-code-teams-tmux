#!/usr/bin/env bash
# Hook: WorktreeRemove — clean up state for removed worktree agents
set -euo pipefail

input=$(cat)
worktree_path=$(echo "$input" | jq -r '.worktree_path // empty' 2>/dev/null || true)

[[ -z "$worktree_path" ]] && exit 0

# Clean up heartbeat files associated with this worktree
heartbeat_dir="$HOME/.shipwright/heartbeats"
if [[ -d "$heartbeat_dir" ]]; then
    for hb in "$heartbeat_dir"/*.json; do
        [[ -f "$hb" ]] || continue
        hb_path=$(jq -r '.worktree // empty' "$hb" 2>/dev/null || true)
        if [[ "$hb_path" == "$worktree_path" ]]; then
            rm -f "$hb"
        fi
    done
fi
