#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright policy-hygiene — Detect hardcoded policy values             ║
# ║  Scans bash scripts for patterns that should be in config/policy.json   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Exit codes:
#   0  — no hardcoded policy values found (clean)
#   1  — hardcoded policy values found
#   2  — usage / scan setup error
#
# Usage:
#   shipwright policy-hygiene              # scan default scope, report
#   shipwright policy-hygiene --json       # machine-readable output
#   shipwright policy-hygiene --max N      # fail if more than N findings (default: baseline)
#   shipwright policy-hygiene --baseline   # write current count as accepted baseline

set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_FILE="$REPO_DIR/.claude/policy-hygiene-baseline"

OUTPUT_FORMAT="text"
MAX_FINDINGS=""
WRITE_BASELINE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) OUTPUT_FORMAT="json"; shift ;;
        --max) MAX_FINDINGS="$2"; shift 2 ;;
        --baseline) WRITE_BASELINE=1; shift ;;
        -h|--help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Patterns that indicate hardcoded policy values worth migrating.
# Each pattern is a regex matched against grep -nE output.
# We avoid false positives by excluding test files and explicit defaults.
SCAN_PATHS=(
    "$REPO_DIR/scripts/sw-loop.sh"
    "$REPO_DIR/scripts/sw-daemon.sh"
    "$REPO_DIR/scripts/sw-intelligence.sh"
    "$REPO_DIR/scripts/sw-pipeline.sh"
    "$REPO_DIR/scripts/sw-adaptive.sh"
    "$REPO_DIR/scripts/lib/pipeline-stages-build.sh"
    "$REPO_DIR/scripts/lib/loop-iteration.sh"
    "$REPO_DIR/scripts/lib/loop-restart.sh"
)

# Suspicious hardcoded-numeric assignments — but only at top-level (not inside
# fallback patterns like `${VAR:-60}` which are acceptable).
# Targets: `MAX_ITER=10`, `TIMEOUT=300`, `THRESHOLD=70`, etc.
HARDCODE_PATTERN='^[[:space:]]*(MAX_|TIMEOUT|THRESHOLD|RETRY|POLL_|CIRCUIT_|EXTENSION_|COOLDOWN_)[A-Z_]+=[0-9]+[[:space:]]*$'

findings=()
for f in "${SCAN_PATHS[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        findings+=("$line")
    done < <(grep -nE "$HARDCODE_PATTERN" "$f" 2>/dev/null || true)
done

count=${#findings[@]}

# Load baseline (default 0 if file missing)
baseline=0
if [[ -f "$BASELINE_FILE" ]]; then
    baseline=$(<"$BASELINE_FILE")
fi

if [[ "$WRITE_BASELINE" -eq 1 ]]; then
    mkdir -p "$(dirname "$BASELINE_FILE")"
    echo "$count" > "$BASELINE_FILE"
    echo "Baseline set: $count" >&2
    exit 0
fi

# Use --max if provided, else baseline
threshold="${MAX_FINDINGS:-$baseline}"

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # Bash 3.2 safe JSON emit
    printf '{"count":%d,"baseline":%d,"threshold":%d,"findings":[' "$count" "$baseline" "$threshold"
    first=1
    for finding in "${findings[@]:-}"; do
        [[ -z "$finding" ]] && continue
        [[ $first -eq 0 ]] && printf ','
        # Escape quotes/backslashes
        esc=$(printf '%s' "$finding" | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '"%s"' "$esc"
        first=0
    done
    printf ']}\n'
else
    echo "Policy hygiene scan"
    echo "─────────────────────────────────────"
    echo "Findings:  $count"
    echo "Baseline:  $baseline"
    echo "Threshold: $threshold"
    echo ""
    if [[ "$count" -gt 0 ]]; then
        echo "Hardcoded policy candidates:"
        for finding in "${findings[@]}"; do
            echo "  $finding"
        done
    fi
fi

if [[ "$count" -gt "$threshold" ]]; then
    [[ "$OUTPUT_FORMAT" == "text" ]] && echo "" && echo "FAIL: $count findings exceeds threshold $threshold" >&2
    exit 1
fi

exit 0
