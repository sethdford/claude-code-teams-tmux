#!/usr/bin/env bash
# Hook: ConfigChange — notify daemon of config updates
set -euo pipefail

input=$(cat)

# Log config change event
mkdir -p "$HOME/.shipwright" 2>/dev/null || true
echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"config.changed\",\"detail\":$(echo "$input" | jq -c '.' 2>/dev/null || echo '{}')}" >> "$HOME/.shipwright/events.jsonl" 2>/dev/null || true

# Signal running daemon to reload config (if PID file exists)
pid_file="$HOME/.shipwright/daemon.pid"
if [[ -f "$pid_file" ]]; then
    daemon_pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
        kill -USR1 "$daemon_pid" 2>/dev/null || true
    fi
fi
