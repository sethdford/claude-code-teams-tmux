#!/usr/bin/env bash
# Hook: WorktreeCreate — auto-setup worktree for pipeline agents
# Copies essential config into new worktrees so agents inherit settings
set -euo pipefail

# Read hook input from stdin (JSON with worktree details)
input=$(cat)
worktree_path=$(echo "$input" | jq -r '.worktree_path // empty' 2>/dev/null || true)

[[ -z "$worktree_path" ]] && exit 0

# Copy daemon config if it exists
src_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n "$src_root" ]]; then
    src_config="$src_root/.claude/daemon-config.json"
    if [[ -f "$src_config" ]]; then
        mkdir -p "$worktree_path/.claude" 2>/dev/null || true
        cp "$src_config" "$worktree_path/.claude/daemon-config.json" 2>/dev/null || true
    fi

    # Copy pipeline artifacts directory structure
    if [[ -d "$src_root/.claude/pipeline-artifacts" ]]; then
        mkdir -p "$worktree_path/.claude/pipeline-artifacts" 2>/dev/null || true
    fi
fi
