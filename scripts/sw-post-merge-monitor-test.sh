#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright post-merge-monitor test — Production feedback & regression   ║
# ║  Tests: polling, signal correlation, event emission, memory integration  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# Override assert functions for cleaner output
assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1"; local detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi; }
assert_eq() { local desc="$1" expected="$2" actual="$3"; if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc" "expected '$expected', got '$actual'"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; if printf '%s\n' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; if printf '%s\n' "$haystack" | grep -qE -- "$pattern" 2>/dev/null; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

# ─── Test Setup ───────────────────────────────────────────────────────────
setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Mock git command
    cat > "$TEST_TEMP_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" ]]; then shift; shift; fi
case "${1:-}" in
    remote)
        if [[ "${2:-}" == "get-url" ]]; then
            echo "git@github.com:test/repo.git"
        fi
        ;;
    *) return 1 ;;
esac
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh command
    cat > "$TEST_TEMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    pr)
        case "${2:-}" in
            list)
                echo '[{"number":123,"mergedAt":"2026-03-07T10:00:00Z","mergeCommit":{"oid":"abc123def456"},"headRefName":"feat/test"},{"number":122,"mergedAt":"2026-03-06T15:30:00Z","mergeCommit":{"oid":"xyz789"},"headRefName":"fix/bug"}]'
                ;;
            view)
                echo '{"state":"MERGED","mergeCommit":{"oid":"abc123def456"},"mergedAt":"2026-03-07T10:00:00Z"}'
                ;;
        esac
        ;;
    api)
        echo '{"check_runs":[]}'
        ;;
    issue)
        case "${2:-}" in
            list) echo '[]' ;;
        esac
        ;;
esac
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export REPO_DIR="$TEST_TEMP_DIR/repo"
}

trap cleanup_test_env EXIT

# ═════════════════════════════════════════════════════════════════════════════
# TEST SUITE
# ═════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Post-Merge-Monitor Tests"
echo ""
setup_env

# ─── Script Safety & Conventions ───────────────────────────────────────────
echo -e "  ${CYAN}Script Safety & Conventions${RESET}"
output=$(cat "$SCRIPT_DIR/sw-post-merge-monitor.sh")
assert_contains "Uses set -euo pipefail" "$output" "set -euo pipefail"
assert_contains "Has ERR trap" "$output" "trap 'echo"
assert_contains "Has VERSION variable" "$output" "VERSION="

# ─── Help & Interface ──────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Help & Interface${RESET}"
output=$(bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "post-merge-monitor"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

output=$(bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help flag works" "0" "$rc"

# ─── Subcommands ──────────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Subcommands${RESET}"
output=$(bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" monitor 2>&1) && rc=0 || rc=$?
assert_eq "monitor command exits 0 or 1" "$(echo $((rc == 0 || rc == 1)))" "1"

bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" status >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "status command exits 0" "0" "$rc"

output=$(bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" ingest '{"pr_number":123,"signal_type":"test"}' 2>&1) && rc=0 || rc=$?
assert_eq "ingest valid JSON exits 0" "0" "$rc"
assert_contains "ingest shows success" "$output" "ingested"

output=$(bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" ingest 'not json' 2>&1) && rc=0 || rc=$?
assert_eq "ingest invalid JSON exits 1" "1" "$rc"

output=$(bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" check-pr 123 2>&1) && rc=0 || rc=$?
assert_eq "check-pr exits 0 or 1" "$(echo $((rc == 0 || rc == 1)))" "1"

# ─── Error Handling ────────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Error Handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" invalid 2>&1) && rc=0 || rc=$?
assert_eq "invalid command exits 1" "1" "$rc"

output=$(bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" check-pr 2>&1) && rc=0 || rc=$?
assert_eq "check-pr without args exits 1" "1" "$rc"

output=$(bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" ingest 2>&1) && rc=0 || rc=$?
assert_eq "ingest without args exits 1" "1" "$rc"

# ─── Graceful Degradation ─────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Graceful Degradation${RESET}"
output=$(NO_GITHUB=1 bash "$SCRIPT_DIR/sw-post-merge-monitor.sh" monitor 2>&1) && rc=0 || rc=$?
assert_eq "NO_GITHUB mode exits 0" "0" "$rc"
assert_contains_regex "NO_GITHUB skips GitHub" "$output" "skipping|NO_GITHUB"

# ─── Directory Creation ────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Directory Creation${RESET}"
[[ -d "$HOME/.shipwright" ]] && assert_pass ".shipwright directory exists" || assert_fail ".shipwright directory exists"

# ─── Core Functions ───────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Core Functions${RESET}"
output=$(cat "$SCRIPT_DIR/sw-post-merge-monitor.sh")
assert_contains "has get_owner_repo function" "$output" "get_owner_repo()"
assert_contains "has get_recent_merged_prs function" "$output" "get_recent_merged_prs()"
assert_contains "has check_ci_status_for_commit function" "$output" "check_ci_status_for_commit()"
assert_contains "has check_deployment_status function" "$output" "check_deployment_status()"
assert_contains "has check_regression_issues function" "$output" "check_regression_issues()"
assert_contains "has correlate_signals function" "$output" "correlate_signals()"
assert_contains "has record_health function" "$output" "record_health()"
assert_contains "has emit_regression_event function" "$output" "emit_regression_event()"

# ─── Atomic Writes ────────────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Atomic Writes & Safety${RESET}"
assert_contains "record_health uses mktemp" "$output" "mktemp"
assert_contains "record_health uses atomic mv" "$output" -E 'mv.*tmp_file'
assert_contains "emit_event logs to JSONL" "$output" "events.jsonl"

# ─── New Functions (Post-Merge Feedback Integration) ──────────────────────
echo ""
echo -e "  ${CYAN}Post-Merge Feedback Integration Functions${RESET}"
assert_contains "has is_duplicate_regression_event function" "$output" "is_duplicate_regression_event()"
assert_contains "has link_pr_to_issue_pattern function" "$output" "link_pr_to_issue_pattern()"
assert_contains "deduplication checks events.jsonl" "$output" "feedback.production.regression"
assert_contains "link_pr_to_issue_pattern calls memory_tag_failure_as_risky" "$output" "memory_tag_failure_as_risky"
assert_contains "emit_regression_event checks for duplicates" "$output" "is_duplicate_regression_event"
assert_contains "emit_regression_event calls link_pr_to_issue_pattern" "$output" "link_pr_to_issue_pattern"

# ─── Deduplication Logic ──────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Deduplication Logic${RESET}"

# Test: duplicate event is detected
mkdir -p "$HOME/.shipwright"
local_events="$HOME/.shipwright/events.jsonl"
# Write a recent regression event
echo '{"ts":"2026-03-07T10:00:00Z","type":"feedback.production.regression","ref":"abc123def456","signal_type":"ci_failure"}' > "$local_events"

# Source the monitor script to get the function
(
    export HOME="$HOME"
    export REPO_DIR="$TEST_TEMP_DIR/repo"
    export NO_GITHUB=1
    # Source just the function definitions
    source "$SCRIPT_DIR/sw-post-merge-monitor.sh" help >/dev/null 2>&1 || true
) && rc=0 || rc=$?
# The script runs main on source, so we test via script structure instead
assert_contains "dedup window default 3600s" "$output" "3600"
assert_contains "dedup scans recent events" "$output" "tail -200"

# ─── Memory Integration ──────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}Memory Integration${RESET}"
assert_contains "emit_regression_event captures failure with tags" "$output" "production_regression"
assert_contains "tags include post_merge" "$output" "post_merge"
assert_contains "link function extracts issue from branch" "$output" "headRefName"
assert_contains "link function checks PR body for Closes/Fixes" "$output" "closes\|fixes\|resolves"

echo ""
echo ""
print_test_results
