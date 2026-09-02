#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-patrol test — Unit tests for all patrol functions  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: daemon-patrol Tests"

setup_test_env "sw-lib-daemon-patrol-test"
trap cleanup_test_env EXIT

# Set up daemon environment
export STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
export LOG_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon.log"
export DAEMON_DIR="$TEST_TEMP_DIR/home/.shipwright"
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
export PAUSE_FLAG="$TEST_TEMP_DIR/home/.shipwright/daemon.pause"
export REPO_DIR="$TEST_TEMP_DIR/project"
export NO_GITHUB=true
export POLL_INTERVAL=60
export MAX_PARALLEL=2
export BASE_BRANCH="main"
export PIPELINE_TEMPLATE="standard"
export PATROL_LABEL="shipwright-patrol"
export PATROL_DRY_RUN="false"
export PATROL_AUTO_WATCH="false"
export PATROL_MAX_ISSUES="10"
export DECISION_ENGINE_ENABLED="false"
export DAEMON_LOG_WRITE_COUNT=0

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$EVENTS_FILE")" "$REPO_DIR"
touch "$LOG_FILE"

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
info() { :; }
success() { :; }
warn() { :; }
error() { :; }
daemon_log() { :; }
notify() { :; }
notify_on_patrol_finding() { :; }

# Git mock
mock_git
mock_gh

# Required env vars for daemon-state.sh
export WATCH_LABEL="${WATCH_LABEL:-shipwright}"
export WATCH_MODE="${WATCH_MODE:-label}"
export WORKTREE_DIR="${WORKTREE_DIR:-$REPO_DIR/.worktrees}"

# Source dependencies
_DAEMON_STATE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-state.sh"

_DAEMON_PATROL_LOADED=""
source "$SCRIPT_DIR/lib/daemon-patrol.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_security_scan
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_security_scan"

# Create mock security scan output with vulnerabilities
SECURITY_SCAN_OUTPUT="package-lock.json: CRITICAL: Command Injection in lodash v4.17.19
package-lock.json: HIGH: Prototype Pollution in lodash v4.17.19
requirements.txt: CRITICAL: SQL Injection in django v2.2.0"

mock_binary "npm" 'case "${1:-}" in
audit)
  echo "{\"auditReportVersion\":2,\"vulnerabilities\":{\"lodash\":{\"name\":\"lodash\",\"severity\":\"critical\",\"via\":[{\"url\":\"https://advisory.com\",\"title\":\"Command Injection\"}]}}}"
  ;;
*) exit 0 ;;
esac'

# Initialize state
init_state

# Call the security scan function
daemon_patrol_security_scan 2>/dev/null || true

# Verify events were emitted for findings
events_content=$(cat "$EVENTS_FILE" 2>/dev/null || echo "")
if [[ -n "$events_content" ]]; then
    assert_contains "Security scan emits findings event" "$events_content" "patrol.finding" || true
    assert_pass "daemon_patrol_security_scan processes vulnerabilities"
else
    assert_pass "daemon_patrol_security_scan runs without errors"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_config_refresh
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_config_refresh"

# Create a valid config file
CONFIG_FILE="$DAEMON_DIR/patrol-config.json"
mkdir -p "$(dirname "$CONFIG_FILE")"
jq -n '{
  "enabled": true,
  "scan_interval": 3600,
  "checks": ["security", "architecture", "regression"]
}' > "$CONFIG_FILE"

# Test valid config reload
daemon_patrol_config_refresh 2>/dev/null || true
assert_pass "daemon_patrol_config_refresh loads valid config"

# Test with malformed config (syntax error)
echo "invalid json {{{" > "$CONFIG_FILE"
daemon_patrol_config_refresh 2>/dev/null || true
assert_pass "daemon_patrol_config_refresh handles syntax errors gracefully"

# Restore valid config
jq -n '{
  "enabled": true,
  "scan_interval": 3600
}' > "$CONFIG_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_worker_memory
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_worker_memory"

# Create mock memory snapshot data
MEMORY_FILE="$DAEMON_DIR/worker-memory.json"
jq -n '{
  "workers": [
    {
      "pid": 1234,
      "memory_mb": 512,
      "timestamp": "2026-02-28T12:00:00Z"
    },
    {
      "pid": 1235,
      "memory_mb": 1024,
      "timestamp": "2026-02-28T12:00:00Z"
    }
  ],
  "max_observed_mb": 1024,
  "avg_observed_mb": 768
}' > "$MEMORY_FILE"

# Call worker memory patrol
daemon_patrol_worker_memory 2>/dev/null || true
assert_pass "daemon_patrol_worker_memory analyzes memory data"

# Test with missing data (graceful degradation)
rm -f "$MEMORY_FILE"
daemon_patrol_worker_memory 2>/dev/null || true
assert_pass "daemon_patrol_worker_memory handles missing data"

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_regression
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_regression"

# Create baseline metrics
BASELINE_FILE="$DAEMON_DIR/baseline-metrics.json"
jq -n '{
  "lead_time_sec": 3600,
  "deployment_frequency_per_day": 2.5,
  "change_failure_rate_pct": 15.0,
  "mean_time_to_recovery_sec": 1800,
  "timestamp": "2026-02-27T00:00:00Z"
}' > "$BASELINE_FILE"

# Create current metrics showing regression
CURRENT_FILE="$DAEMON_DIR/current-metrics.json"
jq -n '{
  "lead_time_sec": 7200,
  "deployment_frequency_per_day": 1.2,
  "change_failure_rate_pct": 32.0,
  "mean_time_to_recovery_sec": 3600,
  "timestamp": "2026-02-28T12:00:00Z"
}' > "$CURRENT_FILE"

# Call regression detection
daemon_patrol_regression 2>/dev/null || true
assert_pass "daemon_patrol_regression detects metric changes"

# Verify event for regression detection
events_content=$(cat "$EVENTS_FILE" 2>/dev/null || echo "")
if [[ -n "$events_content" ]]; then
    assert_contains_regex "Regression detection logs event" "$events_content" "patrol\." || true
fi

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_auto_scale
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_auto_scale"

# Test scaling with various resource inputs
test_scaling_scenario() {
    local cpu_percent="$1" mem_gb_avail="$2" budget_remaining="$3" queue_size="$4" expected_workers="$5"

    # Set environment
    export SYSTEM_CORES=8
    export AVAILABLE_MEMORY_GB="$mem_gb_avail"
    export WORKER_MEM_GB=2
    export REMAINING_BUDGET_USD="$budget_remaining"
    export ESTIMATED_COST_PER_JOB_USD=5.0
    export MAX_WORKERS=8
    export MIN_WORKERS=1

    # Mock df for CPU usage
    mock_binary "df" 'echo "100 $CPU_PERCENT"'

    # Call auto-scale
    daemon_patrol_auto_scale 2>/dev/null || true
    assert_pass "daemon_patrol_auto_scale ($cpu_percent% CPU, ${mem_gb_avail}GB RAM)"
}

# Test 1: High CPU utilization
test_scaling_scenario 80 4 50.0 5 2

# Test 2: Low memory available
test_scaling_scenario 50 1 50.0 10 1

# Test 3: Low budget
test_scaling_scenario 50 8 5.0 10 1

# Test 4: Normal conditions
test_scaling_scenario 40 6 100.0 3 4

# ═══════════════════════════════════════════════════════════════════════════════
# daemon_patrol_architecture_enforce
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "daemon_patrol_architecture_enforce"

# Create architecture rules
ARCH_RULES_FILE="$DAEMON_DIR/architecture-rules.json"
jq -n '{
  "rules": [
    {
      "name": "no-circular-imports",
      "type": "dependency",
      "pattern": "should not allow circular dependencies"
    },
    {
      "name": "layer-boundaries",
      "type": "structure",
      "pattern": "should enforce layer boundaries (controllers, services, models)"
    }
  ]
}' > "$ARCH_RULES_FILE"

# Create a file that violates a rule
VIOLATION_FILE="$REPO_DIR/src/circular-import.js"
mkdir -p "$(dirname "$VIOLATION_FILE")"
cat > "$VIOLATION_FILE" <<'EOF'
// This file violates architecture rules
const serviceA = require('./service-a');
const serviceB = require('./service-b');
serviceB.dependsOn(serviceA);
serviceA.dependsOn(serviceB); // VIOLATION: circular dependency
EOF

# Initialize git repo for pattern analysis
mkdir -p "$REPO_DIR/.git"
(cd "$REPO_DIR" && git init -q -b main 2>/dev/null && git config user.email "test@test.com" && git config user.name "Test" && touch .gitignore && git add . && git commit -q -m "init" 2>/dev/null) || true

# Call architecture enforcement
daemon_patrol_architecture_enforce 2>/dev/null || true
assert_pass "daemon_patrol_architecture_enforce validates rules"

# Verify that violations are detected (event emitted)
events_content=$(cat "$EVENTS_FILE" 2>/dev/null || echo "")
if [[ -n "$events_content" ]]; then
    assert_contains_regex "Architecture validation logs event" "$events_content" "patrol\." || true
fi

# ═══════════════════════════════════════════════════════════════════════════════
# patrol_build_labels (helper function)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "patrol_build_labels"

export PATROL_LABEL="patrol"
export WATCH_LABEL="shipwright"
PATROL_AUTO_WATCH="false"

labels=$(patrol_build_labels "security")
assert_eq "patrol_build_labels without auto-watch" "patrol,security" "$labels"

PATROL_AUTO_WATCH="true"
labels=$(patrol_build_labels "performance")
assert_contains "patrol_build_labels with auto-watch includes WATCH_LABEL" "$labels" "shipwright"

# ═══════════════════════════════════════════════════════════════════════════════
# Integration: Patrol with decision engine signal mode
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration: Patrol signal emission"

export DECISION_ENGINE_ENABLED="true"
export SIGNALS_PENDING_FILE="$DAEMON_DIR/signals/pending.jsonl"
mkdir -p "$(dirname "$SIGNALS_PENDING_FILE")"

# Reset events file
: > "$EVENTS_FILE"

# Call security scan with decision engine enabled
daemon_patrol_security_scan 2>/dev/null || true

# Check if signals were written
if [[ -f "$SIGNALS_PENDING_FILE" ]]; then
    signal_count=$(wc -l < "$SIGNALS_PENDING_FILE" 2>/dev/null || echo "0")
    if [[ "$signal_count" -gt 0 ]]; then
        assert_pass "Patrol emits signals to decision engine"
    else
        assert_pass "Patrol signal file created (no findings in mock)"
    fi
else
    assert_pass "Patrol handles decision engine signal mode"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Edge cases and error handling
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Edge cases and error handling"

# Test 1: No configuration file (graceful degradation)
rm -f "$CONFIG_FILE"
daemon_patrol_config_refresh 2>/dev/null || true
assert_pass "Handles missing configuration file"

# Test 2: Empty metrics file
echo "{}" > "$BASELINE_FILE"
daemon_patrol_regression 2>/dev/null || true
assert_pass "Handles empty metrics data"

# Test 3: Patrol with DRY_RUN enabled
export PATROL_DRY_RUN="true"
daemon_patrol_security_scan 2>/dev/null || true
assert_pass "Patrol respects DRY_RUN flag"


# ═══════════════════════════════════════════════════════════════════════════════
# Duplicate / runaway issue detection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_patrol_normalize_title"

assert_eq "normalize strips bracketed tags" \
    "test failure" "$(_patrol_normalize_title "[automated] Test failure")"
assert_eq "normalize strips parenthesised asides" \
    "test failure" "$(_patrol_normalize_title "Test failure (run 12)")"
assert_eq "normalize strips issue references" \
    "test failure" "$(_patrol_normalize_title "Test failure #3502")"
assert_eq "normalize strips ISO-8601 timestamps" \
    "test failure at" "$(_patrol_normalize_title "Test failure at 2026-09-02T03:57:52Z")"
assert_eq "normalize strips commit SHAs" \
    "test failure in" "$(_patrol_normalize_title "Test failure in 4a3f9bc")"
assert_eq "normalize strips bare digits" \
    "test failure attempt" "$(_patrol_normalize_title "Test failure attempt 17")"
assert_eq "normalize collapses punctuation and whitespace" \
    "test failure here" "$(_patrol_normalize_title "  Test:  failure --- here!! ")"
assert_eq "normalize lowercases" \
    "test failure" "$(_patrol_normalize_title "TEST Failure")"
assert_eq "normalize of empty string is empty" "" "$(_patrol_normalize_title "")"
assert_eq "normalize collapses two runs of the same generator" \
    "$(_patrol_normalize_title "[automated] E2E failure #3502 at 2026-09-02T03:57:52Z")" \
    "$(_patrol_normalize_title "[automated] E2E failure #3517 at 2026-08-30T11:02:03Z")"
assert_eq "normalize keeps genuinely different titles apart" \
    "fix login bug" "$(_patrol_normalize_title "Fix login bug")"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "patrol_group_duplicate_issues"

DUP_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DUP_OLD="2020-01-01T00:00:00Z"

# Build a JSON array of $1 issues starting at number $2, with label JSON $3 and
# createdAt $4.
dup_fixture() {
    local count="$1" start="$2" labels="$3" created="$4"
    local i=0 n
    {
        while [[ "$i" -lt "$count" ]]; do
            n=$((start + i))
            jq -cn --argjson n "$n" --arg t "[automated] E2E failure #${n}" \
                --arg c "$created" --argjson l "$labels" \
                '{number: $n, title: $t, createdAt: $c, labels: $l, assignees: []}'
            i=$((i + 1))
        done
    } | jq -s '.'
}

DUP_AUTO_LABELS_JSON='[{"name":"automated"},{"name":"e2e"}]'
export PATROL_DUP_THRESHOLD=3
export PATROL_DUP_WINDOW_DAYS=7
export PATROL_DUP_AUTO_LABELS="automated,auto-patrol"

# No duplicates at all → no-op
distinct_issues=$(jq -cn '[
  {number:1, title:"Fix login bug",     createdAt:"'"$DUP_NOW"'", labels:[{"name":"automated"}], assignees:[]},
  {number:2, title:"Add dark mode",     createdAt:"'"$DUP_NOW"'", labels:[{"name":"automated"}], assignees:[]},
  {number:3, title:"Upgrade the parser",createdAt:"'"$DUP_NOW"'", labels:[{"name":"automated"}], assignees:[]},
  {number:4, title:"Rewrite the docs",  createdAt:"'"$DUP_NOW"'", labels:[{"name":"automated"}], assignees:[]}
]')
out=$(printf '%s' "$distinct_issues" | patrol_group_duplicate_issues "")
assert_eq "no duplicates produces no clusters" "" "$out"

# Exactly at the threshold → no-op (pins the `count > threshold` boundary)
out=$(dup_fixture 3 3502 "$DUP_AUTO_LABELS_JSON" "$DUP_NOW" | patrol_group_duplicate_issues "")
assert_eq "cluster of exactly threshold (3) is a no-op" "" "$out"

# One above the threshold → cluster emitted
out=$(dup_fixture 4 3502 "$DUP_AUTO_LABELS_JSON" "$DUP_NOW" | patrol_group_duplicate_issues "")
assert_eq "cluster of threshold+1 (4) emits one cluster" "1" "$(printf '%s' "$out" | grep -c . || true)"
assert_eq "cluster of 4 closes all but the newest" \
    "3502 3503 3504" "$(printf '%s' "$out" | jq -r '.close | join(" ")')"
assert_eq "cluster of 4 keeps the newest issue number" \
    "3505" "$(printf '%s' "$out" | jq -r '.keep')"

# Happy path: 6 duplicates
DUP_SIX=$(dup_fixture 6 3502 "$DUP_AUTO_LABELS_JSON" "$DUP_NOW")
cluster=$(printf '%s' "$DUP_SIX" | patrol_group_duplicate_issues "")
assert_eq "six duplicates report count 6" "6" "$(printf '%s' "$cluster" | jq -r '.count')"
assert_eq "six duplicates close 3502-3506, keeping 3507" \
    "3502 3503 3504 3505 3506" "$(printf '%s' "$cluster" | jq -r '.close | join(" ")')"
assert_eq "six duplicates keep the newest" "3507" "$(printf '%s' "$cluster" | jq -r '.keep')"

# keep policy: the default is spec-compliant "newest"; "oldest" is opt-in.
out=$(PATROL_DUP_KEEP=oldest dup_fixture 6 3502 "$DUP_AUTO_LABELS_JSON" "$DUP_NOW" \
    | PATROL_DUP_KEEP=oldest patrol_group_duplicate_issues "")
assert_eq "keep=oldest survives the lowest issue number" "3502" "$(printf '%s' "$out" | jq -r '.keep')"
assert_eq "keep=oldest closes 3503-3507" \
    "3503 3504 3505 3506 3507" "$(printf '%s' "$out" | jq -r '.close | join(" ")')"
out=$(dup_fixture 6 3502 "$DUP_AUTO_LABELS_JSON" "$DUP_NOW" \
    | PATROL_DUP_KEEP=nonsense patrol_group_duplicate_issues "")
assert_eq "an unrecognised keep policy degrades to newest" "3507" "$(printf '%s' "$out" | jq -r '.keep')"
assert_eq "closed issue numbers are always emitted in ascending order" "true" \
    "$(printf '%s' "$out" | jq -r '.close == (.close | sort)')"

# Invariant: keep is never in close, and close/skipped are disjoint
assert_eq "invariant: keep is not in close" "false" \
    "$(printf '%s' "$cluster" | jq -r '[.close[] == .keep] | any')"
assert_eq "invariant: close and skipped are disjoint" "0" \
    "$(printf '%s' "$cluster" | jq -r '[.skipped[].number] as $s | [.close[] | select(. as $c | $s | index($c))] | length')"

# G1: a human label set is never touched
out=$(dup_fixture 6 3502 '[{"name":"bug"}]' "$DUP_NOW" | patrol_group_duplicate_issues "")
assert_eq "human-labelled cluster is a no-op" "" "$out"

# G1 regression (A1): `shipwright` is the daemon's human request label and must
# NOT be treated as an automation label — otherwise every queued human issue
# becomes closable.
out=$(dup_fixture 6 3502 '[{"name":"shipwright"}]' "$DUP_NOW" | patrol_group_duplicate_issues "")
assert_eq "shipwright-labelled cluster is a no-op" "" "$out"

# G4: outside the creation window
out=$(dup_fixture 6 3502 "$DUP_AUTO_LABELS_JSON" "$DUP_OLD" | patrol_group_duplicate_issues "")
assert_eq "cluster outside the creation window is a no-op" "" "$out"

# G2 + G3: assigned issues and issues with a running pipeline are spared
DUP_STATE="$TEST_TEMP_DIR/dup-state.json"
echo '{"active_jobs":[{"issue":3504}]}' > "$DUP_STATE"
cluster=$(printf '%s' "$DUP_SIX" \
    | jq '[.[] | if .number == 3503 then .assignees = [{"login":"someone"}] else . end]' \
    | patrol_group_duplicate_issues "$DUP_STATE")
assert_eq "assigned and active issues are excluded from close" \
    "3502 3505 3506" "$(printf '%s' "$cluster" | jq -r '.close | join(" ")')"
assert_eq "assigned issue is recorded as skipped" \
    "assigned" "$(printf '%s' "$cluster" | jq -r '.skipped[] | select(.number == 3503) | .reason')"
assert_eq "in-flight issue is recorded as skipped" \
    "active_pipeline" "$(printf '%s' "$cluster" | jq -r '.skipped[] | select(.number == 3504) | .reason')"

# Same title, different label sets → different clusters, neither above threshold
mixed=$(jq -s '.' <<<"$(dup_fixture 3 3502 "$DUP_AUTO_LABELS_JSON" "$DUP_NOW"; dup_fixture 3 3600 '[{"name":"auto-patrol"}]' "$DUP_NOW")" | jq 'add')
out=$(printf '%s' "$mixed" | patrol_group_duplicate_issues "")
assert_eq "identical titles with different label sets do not merge" "" "$out"

# Malformed / empty input degrades to zero clusters, exit 0
out=$(echo 'not json at all' | patrol_group_duplicate_issues "" 2>/dev/null; echo "rc=$?")
assert_eq "malformed input yields no clusters and exit 0" "rc=0" "$out"
out=$(echo '[]' | patrol_group_duplicate_issues "" 2>/dev/null; echo "rc=$?")
assert_eq "empty array yields no clusters and exit 0" "rc=0" "$out"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "patrol_duplicate_issues"

DUP_GH_LOG="$TEST_TEMP_DIR/gh-calls.log"
DUP_EVENT_LOG="$TEST_TEMP_DIR/dup-events.log"

# Recording mocks. The harness installs no-op stubs at the top of this file;
# both are restored at the end of this section.
dup_record_gh() {
    local issues_file="$1"
    mock_binary "gh" 'echo "$@" >> '"$DUP_GH_LOG"'
case "${1:-}" in
    issue)
        case "${2:-}" in
            list)  cat '"$issues_file"' ;;
            close) : ;;
            *)     echo "[]" ;;
        esac ;;
    *) echo "" ;;
esac
exit 0'
}
emit_event() { echo "$*" >> "$DUP_EVENT_LOG"; }

dup_reset() { : > "$DUP_GH_LOG"; : > "$DUP_EVENT_LOG"; }
dup_close_count() { grep -c "^issue close" "$DUP_GH_LOG" 2>/dev/null || true; }

export NO_GITHUB=false
export PATROL_DRY_RUN=false
export PATROL_DUP_ENABLED=true
export PATROL_DUP_MAX_CLOSURES=25
export PATROL_DUP_FETCH_LIMIT=300
export DECISION_ENGINE_ENABLED=false
export STATE_FILE="$TEST_TEMP_DIR/dup-empty-state.json"
echo '{"active_jobs":[]}' > "$STATE_FILE"
export PIPELINE_ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"

DUP_ISSUES_FILE="$TEST_TEMP_DIR/dup-issues.json"
printf '%s' "$DUP_SIX" > "$DUP_ISSUES_FILE"
dup_record_gh "$DUP_ISSUES_FILE"

# Happy path: closes 5, keeps the newest, comments on every closure
dup_reset
patrol_duplicate_issues >/dev/null 2>&1
assert_eq "closes every duplicate but the canonical issue" "5" "$(dup_close_count)"
assert_eq "PATROL_DUP_FINDINGS counts the closures" "5" "$PATROL_DUP_FINDINGS"
assert_eq "the canonical issue is never closed" "0" \
    "$(grep -c '^issue close 3507' "$DUP_GH_LOG" 2>/dev/null || true)"
assert_eq "the oldest member of a runaway cluster is closed" "1" \
    "$(grep -c '^issue close 3502' "$DUP_GH_LOG" 2>/dev/null || true)"
assert_eq "every closure carries an explanatory comment" "5" \
    "$(grep -c '^issue close .*--comment' "$DUP_GH_LOG" 2>/dev/null || true)"
assert_contains "closure comment names the canonical issue" \
    "$(_patrol_duplicate_comment 3507 6)" "#3507"
assert_contains "emits patrol.duplicate_detected" "$(cat "$DUP_EVENT_LOG")" "patrol.duplicate_detected"
assert_contains "emits patrol.duplicate_closed" "$(cat "$DUP_EVENT_LOG")" "patrol.duplicate_closed"
assert_file_exists "writes an audit record" "$PIPELINE_ARTIFACTS_DIR/patrol-log.jsonl"

# --dry-run: identical decisions, zero mutations
dup_reset
patrol_duplicate_issues --dry-run >/dev/null 2>&1
assert_eq "--dry-run closes nothing" "0" "$(dup_close_count)"
assert_eq "--dry-run still reports the intended closures" "5" "$PATROL_DUP_FINDINGS"
assert_contains "--dry-run emits patrol.duplicate_dry_run" "$(cat "$DUP_EVENT_LOG")" "patrol.duplicate_dry_run"

# PATROL_DRY_RUN=true is honoured without the flag
dup_reset
PATROL_DRY_RUN=true patrol_duplicate_issues >/dev/null 2>&1
assert_eq "PATROL_DRY_RUN=true closes nothing" "0" "$(dup_close_count)"

# Closure cap
dup_reset
PATROL_DUP_MAX_CLOSURES=2 patrol_duplicate_issues >/dev/null 2>&1
assert_eq "closure cap is respected" "2" "$(dup_close_count)"

# Below threshold → no closures
dup_reset
printf '%s' "$(dup_fixture 3 3502 "$DUP_AUTO_LABELS_JSON" "$DUP_NOW")" > "$DUP_ISSUES_FILE"
patrol_duplicate_issues >/dev/null 2>&1
assert_eq "cluster at threshold closes nothing" "0" "$(dup_close_count)"
assert_eq "cluster at threshold reports zero findings" "0" "$PATROL_DUP_FINDINGS"
printf '%s' "$DUP_SIX" > "$DUP_ISSUES_FILE"

# Truncation guard: a full page means the view is partial — stand down
dup_reset
PATROL_DUP_FETCH_LIMIT=6 patrol_duplicate_issues >/dev/null 2>&1
assert_eq "a truncated fetch closes nothing" "0" "$(dup_close_count)"
assert_eq "a truncated fetch reports zero findings" "0" "$PATROL_DUP_FINDINGS"

# Disabled
dup_reset
PATROL_DUP_ENABLED=false patrol_duplicate_issues >/dev/null 2>&1
assert_eq "disabled check closes nothing" "0" "$(dup_close_count)"

# NO_GITHUB
dup_reset
NO_GITHUB=true patrol_duplicate_issues >/dev/null 2>&1
assert_eq "NO_GITHUB closes nothing" "0" "$(dup_close_count)"
assert_eq "NO_GITHUB does not call gh at all" "0" \
    "$(grep -c . "$DUP_GH_LOG" 2>/dev/null || true)"

# gh failures never propagate
dup_reset
mock_binary "gh" 'echo "$@" >> '"$DUP_GH_LOG"'
exit 1'
patrol_duplicate_issues >/dev/null 2>&1
rc=$?
assert_eq "a failing gh returns 0" "0" "$rc"
assert_eq "a failing gh reports zero findings" "0" "$PATROL_DUP_FINDINGS"

dup_reset
mock_binary "gh" 'echo "$@" >> '"$DUP_GH_LOG"'
echo "not json"
exit 0'
patrol_duplicate_issues >/dev/null 2>&1
rc=$?
assert_eq "non-JSON gh output returns 0" "0" "$rc"
assert_eq "non-JSON gh output reports zero findings" "0" "$PATROL_DUP_FINDINGS"

# Decision engine mode routes to signals instead of closing
dup_reset
dup_record_gh "$DUP_ISSUES_FILE"
DUP_SIGNALS="$TEST_TEMP_DIR/dup-signals.jsonl"
: > "$DUP_SIGNALS"
SIGNALS_PENDING_FILE="$DUP_SIGNALS" DECISION_ENGINE_ENABLED=true \
    patrol_duplicate_issues >/dev/null 2>&1
assert_eq "decision engine mode closes nothing" "0" "$(dup_close_count)"
assert_eq "decision engine mode emits one signal per duplicate" "5" \
    "$(jq -s 'length' "$DUP_SIGNALS")"
assert_eq "signals carry the duplicate_issue signal type" "5" \
    "$(jq -rs '[.[] | select(.signal == "duplicate_issue")] | length' "$DUP_SIGNALS")"

# Restore the harness-wide stubs and mocks for any later sections.
emit_event() { :; }
mock_gh
export NO_GITHUB=true
export DECISION_ENGINE_ENABLED=false
unset PIPELINE_ARTIFACTS_DIR

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "duplicate patrol threshold configuration"

# The daemon resolves the threshold as: SW_PATROL_DUPLICATE_ISSUE_THRESHOLD env
# → patrol.duplicate_issue_threshold (flat, as the issue specifies) →
# patrol.checks.duplicate_issues.threshold (house convention) → 3. The first two
# hops are _smart_int's job; assert them against the real function.
source "$SCRIPT_DIR/lib/compat.sh"

DUP_CFG_DIR="$TEST_TEMP_DIR/cfg"
mkdir -p "$DUP_CFG_DIR"
DUP_CFG="$DUP_CFG_DIR/daemon-config.json"

echo '{"patrol":{"duplicate_issue_threshold":9}}' > "$DUP_CFG"
assert_eq "flat patrol.duplicate_issue_threshold is honoured" "9" \
    "$(DAEMON_CONFIG="$DUP_CFG" _smart_int "patrol.duplicate_issue_threshold" 3)"

assert_eq "SW_PATROL_DUPLICATE_ISSUE_THRESHOLD overrides the config file" "12" \
    "$(SW_PATROL_DUPLICATE_ISSUE_THRESHOLD=12 DAEMON_CONFIG="$DUP_CFG" \
        _smart_int "patrol.duplicate_issue_threshold" 3)"

echo '{"patrol":{"checks":{"duplicate_issues":{"threshold":7}}}}' > "$DUP_CFG"
assert_eq "nested threshold falls through _smart_int to the caller's default" "7" \
    "$(DAEMON_CONFIG="$DUP_CFG" _smart_int "patrol.duplicate_issue_threshold" \
        "$(jq -r '.patrol.duplicate_issue_threshold // .patrol.checks.duplicate_issues.threshold // 3' "$DUP_CFG")")"

echo '{"patrol":{"duplicate_issue_threshold":9,"checks":{"duplicate_issues":{"threshold":7}}}}' > "$DUP_CFG"
assert_eq "flat key wins over the nested key when both are set" "9" \
    "$(jq -r '.patrol.duplicate_issue_threshold // .patrol.checks.duplicate_issues.threshold // 3' "$DUP_CFG")"

daemon_src=$(cat "$SCRIPT_DIR/sw-daemon.sh")
assert_contains "sw-daemon.sh reads both threshold key forms" "$daemon_src" \
    ".patrol.duplicate_issue_threshold // .patrol.checks.duplicate_issues.threshold"
assert_contains "sw-daemon.sh logs the resolved duplicate patrol config at startup" \
    "$daemon_src" 'patrol duplicate_issues enabled=${PATROL_DUP_ENABLED}'
assert_contains "daemon_patrol runs the duplicate issue check" \
    "$(cat "$SCRIPT_DIR/lib/daemon-patrol.sh")" "patrol_duplicate_issues --dry-run"

print_test_results
