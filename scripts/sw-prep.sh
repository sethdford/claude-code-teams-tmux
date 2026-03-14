#!/usr/bin/env bash
set -euo pipefail
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Not in a git repo, skipping prep" >&2
    exit 1
fi
echo "Mock prep completed"
exit 0
