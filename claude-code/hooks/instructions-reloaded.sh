#!/usr/bin/env bash
# Hook: InstructionsLoaded (matcher: "compact")
# After auto-compaction, log reload event for observability
set -euo pipefail

mkdir -p "$HOME/.shipwright" 2>/dev/null || true
echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"instructions.reloaded\",\"trigger\":\"compaction\"}" >> "$HOME/.shipwright/events.jsonl" 2>/dev/null || true
