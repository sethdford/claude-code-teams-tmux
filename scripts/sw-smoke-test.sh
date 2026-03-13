#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-smoke-test.sh — Pipeline Health Smoke Test                           ║
# ║                                                                          ║
# ║  Runs the minimal pipeline template to validate that core pipeline       ║
# ║  machinery works: file creation, git commit, branch management.          ║
# ║  Use as a quick health check for new installations or after upgrades.    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# shellcheck disable=SC2034
VERSION="3.2.4"
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }

# ─── Help text ──────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
USAGE
  shipwright smoke-test [OPTIONS]

DESCRIPTION
  Runs the minimal pipeline template to validate core pipeline machinery.
  Creates a timestamped health-check file, commits it, and verifies success.

  This is the simplest possible pipeline task — use it to validate that
  the environment, git operations, and pipeline orchestration all work.

OPTIONS
  --local           Run without GitHub integration (default)
  --github          Enable GitHub integration (creates PR)
  --issue <N>       Attach to a GitHub issue
  --help, -h        Show this help text
  --version, -v     Show version

EXAMPLES
  shipwright smoke-test                 Quick local health check
  shipwright smoke-test --github        Health check with PR creation
  shipwright smoke-test --issue 261     Attach to issue #261

EOF
}

# ─── Parse Arguments ─────────────────────────────────────────────────────────
LOCAL_MODE=true
ISSUE_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)      LOCAL_MODE=true; shift ;;
        --github)     LOCAL_MODE=false; shift ;;
        --issue)      ISSUE_ARG="--issue $2"; LOCAL_MODE=false; shift 2 ;;
        --help|-h)    show_help; exit 0 ;;
        --version|-v) echo "$VERSION"; exit 0 ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# ─── Build Goal ──────────────────────────────────────────────────────────────
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
HEALTH_FILE=".claude/health-check-${TIMESTAMP}.txt"

GOAL="Create the file ${HEALTH_FILE} with the following content:

---
Shipwright Health Check
Timestamp: ${TIMESTAMP}
Host: \$(hostname)
Branch: \$(git rev-parse --abbrev-ref HEAD)
Pipeline: minimal
---

Then stage and commit the file with the message: chore: health check ${TIMESTAMP}

When the file is committed, signal LOOP_COMPLETE."

# ─── Run Pipeline ────────────────────────────────────────────────────────────
info "Shipwright Smoke Test"
info "Health check file: ${HEALTH_FILE}"
echo ""

START_EPOCH="$(date +%s)"

PIPELINE_ARGS=(
    start
    --goal "$GOAL"
    --pipeline minimal
    --skip-gates
)

if [[ "$LOCAL_MODE" == "true" ]]; then
    PIPELINE_ARGS+=(--local)
fi

# shellcheck disable=SC2086
if [[ -n "$ISSUE_ARG" ]]; then
    PIPELINE_ARGS+=($ISSUE_ARG)
fi

info "Running: shipwright pipeline ${PIPELINE_ARGS[*]}"
echo ""

EXIT_CODE=0
bash "$SCRIPT_DIR/sw-pipeline.sh" "${PIPELINE_ARGS[@]}" || EXIT_CODE=$?

END_EPOCH="$(date +%s)"
DURATION=$(( END_EPOCH - START_EPOCH ))

echo ""
echo "─────────────────────────────────────────"

# ─── Verify Results ──────────────────────────────────────────────────────────
CHECKS_PASSED=0
CHECKS_FAILED=0

# Check 1: Pipeline exit code
if [[ "$EXIT_CODE" -eq 0 ]]; then
    success "Pipeline exited with code 0"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    error "Pipeline exited with code $EXIT_CODE"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check 2: Health-check file exists
if [[ -f "$HEALTH_FILE" ]]; then
    success "Health-check file created: $HEALTH_FILE"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    error "Health-check file not found: $HEALTH_FILE"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

# Check 3: Git commit exists
COMMIT_MSG="chore: health check ${TIMESTAMP}"
if git log --oneline -5 2>/dev/null | grep -q "health check"; then
    success "Git commit found"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    error "Git commit not found with message containing 'health check'"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

echo ""
info "Duration: ${DURATION}s"
info "Checks: ${CHECKS_PASSED} passed, ${CHECKS_FAILED} failed"

emit_event "smoke_test.complete" \
    "duration_s=$DURATION" \
    "checks_passed=$CHECKS_PASSED" \
    "checks_failed=$CHECKS_FAILED" \
    "exit_code=$EXIT_CODE"

if [[ "$CHECKS_FAILED" -eq 0 ]]; then
    success "Smoke test PASSED"
    exit 0
else
    error "Smoke test FAILED"
    exit 1
fi
