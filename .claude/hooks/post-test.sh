#!/usr/bin/env bash
# Post-test hook: check for common issues after test runs
set -euo pipefail

# Check for leftover console.log / print debugging
DEBUGGING_STMTS=$(grep -rn "console\.log\|debugger\|print(" src/ app/ lib/ 2>/dev/null | grep -v node_modules | grep -v ".test." | grep -v ".spec." || true)
if [[ -n "$DEBUGGING_STMTS" ]]; then
    echo "Warning: Found debugging statements:"
    echo "$DEBUGGING_STMTS" | head -10
fi

echo "Post-test checks complete"
