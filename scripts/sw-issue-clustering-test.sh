#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-issue-clustering-test.sh — Semantic Issue Clustering Engine Tests     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERING="$SCRIPT_DIR/sw-issue-clustering.sh"
ALGO_JS="$SCRIPT_DIR/../src/issue-clustering.js"
PASS=0
FAIL=0

# Isolated sandbox so tests never touch the real ~/.shipwright.
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/sw-clustering-test.XXXXXX")"
export SHIPWRIGHT_HOME="$TEST_HOME"
export SW_CLUSTERING_EVENTS="$TEST_HOME/events.jsonl"
export SW_CLUSTERING_OUTPUT="$TEST_HOME/issue-clusters.json"
# Low threshold so the synthetic fixtures cluster deterministically.
export SW_CLUSTERING_SIMILARITY_THRESHOLD="0.15"

cleanup() { rm -rf "$TEST_HOME"; }
trap cleanup EXIT

# ─── Test helpers ───────────────────────────────────────────────────────────
pass() { PASS=$((PASS + 1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $1"; [[ -n "${2:-}" ]] && echo "    $2"; return 0; }

assert_eq() {
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected '$1' got '$2'"; fi
}
assert_ge() {
    if (( $1 >= $2 )); then pass "$3"; else fail "$3" "expected >= $2 got $1"; fi
}
assert_contains() {
    if echo "$1" | grep -q "$2"; then pass "$3"; else fail "$3" "'$2' not in output"; fi
}

seed_events() {
    cat > "$SW_CLUSTERING_EVENTS" <<'EOF'
{"issue_id":"1","title":"API timeout in auth daemon","description":"daemon crashes with SIGKILL after timeout","files":["scripts/sw-daemon.sh"],"success":true}
{"issue_id":"2","title":"timeout in auth middleware daemon","description":"SIGKILL timeout crash on daemon","files":["scripts/sw-daemon.sh"],"success":true}
{"issue_id":"3","title":"auth daemon timeout SIGKILL","description":"daemon timeout crash","files":["scripts/sw-daemon.sh"],"success":false}
{"issue_id":"4","title":"add dark mode to dashboard css","description":"styling colors theme dashboard frontend","files":["dashboard/public/style.css"],"success":true}
{"issue_id":"5","title":"dashboard dark theme css colors styling","description":"frontend theme dark mode","files":["dashboard/public/style.css"],"success":true}
EOF
}

# ─── Node algorithm: unit-level checks via CLI ──────────────────────────────
test_algo_clusters_similar_issues() {
    echo "Test: algorithm groups similar issues, separates dissimilar"
    seed_events
    local out count
    out="$(jq -s '.' "$SW_CLUSTERING_EVENTS" | node "$ALGO_JS" cluster --threshold 0.15 --generated-at 2026-01-01T00:00:00Z)"
    count="$(echo "$out" | jq '.clusters | length')"
    assert_eq "2" "$count" "produces exactly 2 clusters (daemon vs dashboard)"
    local daemon_size
    daemon_size="$(echo "$out" | jq '[.clusters[] | select(.issue_ids | index("1"))][0].size')"
    assert_eq "3" "$daemon_size" "daemon cluster contains all 3 timeout issues"
}

test_algo_success_rate() {
    echo "Test: algorithm computes success_rate from outcomes"
    seed_events
    local rate
    rate="$(jq -s '.' "$SW_CLUSTERING_EVENTS" | node "$ALGO_JS" cluster --threshold 0.15 \
        | jq '[.clusters[] | select(.issue_ids | index("1"))][0].success_metrics.success_rate')"
    # daemon cluster: 2 success / 3 total = 0.666...
    assert_contains "$rate" "0.66" "daemon cluster success_rate is ~0.67"
}

test_algo_empty_input() {
    echo "Test: algorithm handles empty input gracefully"
    local out count
    out="$(echo '[]' | node "$ALGO_JS" cluster)"
    count="$(echo "$out" | jq '.clusters | length')"
    assert_eq "0" "$count" "empty events produce zero clusters (no crash)"
}

test_algo_invalid_json() {
    echo "Test: algorithm exits non-zero on invalid JSON"
    local code=0
    echo 'not json' | node "$ALGO_JS" cluster >/dev/null 2>&1 || code=$?
    assert_eq "1" "$code" "invalid JSON input exits 1"
}

test_algo_match() {
    echo "Test: algorithm matches a new issue to the right cluster"
    seed_events
    local clusters match cid
    clusters="$(jq -s '.' "$SW_CLUSTERING_EVENTS" | node "$ALGO_JS" cluster --threshold 0.15)"
    match="$(jq -n --argjson c "$clusters" '{issue:{title:"daemon timeout SIGKILL auth crash"},clusters:$c}' \
        | node "$ALGO_JS" match --threshold 0.1)"
    cid="$(echo "$match" | jq -r '.cluster_id')"
    local daemon_cid
    daemon_cid="$(echo "$clusters" | jq -r '[.clusters[] | select(.issue_ids | index("1"))][0].id')"
    assert_eq "$daemon_cid" "$cid" "timeout query matches the daemon cluster"
    assert_contains "$match" '"confidence_tier"' "match includes a confidence tier"
}

test_algo_match_below_threshold() {
    echo "Test: matching returns null below threshold"
    seed_events
    local clusters match
    clusters="$(jq -s '.' "$SW_CLUSTERING_EVENTS" | node "$ALGO_JS" cluster --threshold 0.15)"
    match="$(jq -n --argjson c "$clusters" '{issue:{title:"completely unrelated quantum banana xylophone"},clusters:$c}' \
        | node "$ALGO_JS" match --threshold 0.9)"
    assert_eq "null" "$match" "unrelated issue with high threshold returns null"
}

# ─── Orchestrator: bash wrapper checks ──────────────────────────────────────
test_run_produces_clusters_file() {
    echo "Test: 'run' produces a valid clusters file"
    seed_events
    bash "$CLUSTERING" run >/dev/null 2>&1
    if [[ -f "$SW_CLUSTERING_OUTPUT" ]] && jq empty < "$SW_CLUSTERING_OUTPUT" 2>/dev/null; then
        pass "clusters file created and is valid JSON"
    else
        fail "clusters file created and is valid JSON"
    fi
    local count
    count="$(jq '.clusters | length' "$SW_CLUSTERING_OUTPUT")"
    assert_ge "$count" "1" "at least one cluster persisted"
}

test_run_emits_events() {
    echo "Test: 'run' emits lifecycle events"
    seed_events
    : > "$SW_CLUSTERING_EVENTS.audit" 2>/dev/null || true
    rm -f "$TEST_HOME/events.jsonl.bak"
    # Use a separate events file for emission so we don't pollute the input.
    bash "$CLUSTERING" run >/dev/null 2>&1
    assert_contains "$(cat "$TEST_HOME/events.jsonl")" "clustering.completed" "emits clustering.completed event"
}

test_run_atomic_no_partial() {
    echo "Test: 'run' leaves no temp/partial files"
    seed_events
    bash "$CLUSTERING" run >/dev/null 2>&1
    local leftovers
    leftovers="$(find "$TEST_HOME" -name 'issue-clusters.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "0" "$leftovers" "no .tmp partial cluster files remain"
}

test_run_empty_events() {
    echo "Test: 'run' on missing events file does not crash"
    rm -f "$SW_CLUSTERING_EVENTS" "$SW_CLUSTERING_OUTPUT"
    local code=0
    bash "$CLUSTERING" run >/dev/null 2>&1 || code=$?
    assert_eq "0" "$code" "run with no events exits 0"
    if [[ -f "$SW_CLUSTERING_OUTPUT" ]]; then
        assert_eq "0" "$(jq '.clusters | length' "$SW_CLUSTERING_OUTPUT")" "empty events yields zero clusters"
    else
        fail "empty events yields a clusters file"
    fi
}

test_match_command() {
    echo "Test: 'match' command returns a cluster for a known pattern"
    seed_events
    bash "$CLUSTERING" run >/dev/null 2>&1
    local out
    out="$(SW_CLUSTERING_SIMILARITY_THRESHOLD=0.1 bash "$CLUSTERING" match "daemon timeout SIGKILL auth" 2>/dev/null)"
    assert_contains "$out" '"cluster_id"' "match returns a cluster_id"
}

test_status_command() {
    echo "Test: 'status' reports cluster count"
    seed_events
    bash "$CLUSTERING" run >/dev/null 2>&1
    local out
    out="$(bash "$CLUSTERING" status 2>&1)"
    assert_contains "$out" "Clusters:" "status shows cluster count"
}

test_due_schedule() {
    echo "Test: 'due' respects the re-cluster interval"
    seed_events
    bash "$CLUSTERING" run >/dev/null 2>&1
    # Just ran → not due.
    local code=0
    bash "$CLUSTERING" due || code=$?
    assert_eq "1" "$code" "not due immediately after a run"
    # Backdate last-run beyond the interval → due.
    echo "1000000000" > "$TEST_HOME/.clustering-last-run"
    code=0
    bash "$CLUSTERING" due || code=$?
    assert_eq "0" "$code" "due after interval elapses"
}

test_metrics_command() {
    echo "Test: 'metrics' reports match rate and success rate"
    seed_events
    bash "$CLUSTERING" run >/dev/null 2>&1
    SW_CLUSTERING_SIMILARITY_THRESHOLD=0.1 bash "$CLUSTERING" match "daemon timeout SIGKILL" >/dev/null 2>&1
    local out
    out="$(bash "$CLUSTERING" metrics 2>/dev/null)"
    assert_contains "$out" '"pattern_matches"' "metrics emits machine-readable JSON"
    local matches
    matches="$(echo "$out" | jq '.pattern_matches')"
    assert_ge "$matches" "1" "at least one pattern match recorded"
}

test_node_unit_tests() {
    echo "Test: Node unit tests (node:test) pass"
    local unit_file="$SCRIPT_DIR/../tests/issue-clustering.test.js"
    if [[ ! -f "$unit_file" ]]; then
        fail "node unit test file present" "$unit_file missing"
        return 0
    fi
    local code=0
    node --test "$unit_file" >/dev/null 2>&1 || code=$?
    assert_eq "0" "$code" "node --test tests/issue-clustering.test.js passes"
}

test_help_and_version() {
    echo "Test: help and version"
    assert_contains "$(bash "$CLUSTERING" --help)" "USAGE" "--help shows usage"
    assert_contains "$(bash "$CLUSTERING" --version)" "." "--version prints a version"
}

# ─── Run all ────────────────────────────────────────────────────────────────
echo ""
echo "═══ Semantic Issue Clustering Engine Tests ═══"
echo ""

test_algo_clusters_similar_issues
test_algo_success_rate
test_algo_empty_input
test_algo_invalid_json
test_algo_match
test_algo_match_below_threshold
test_run_produces_clusters_file
test_run_emits_events
test_run_atomic_no_partial
test_run_empty_events
test_match_command
test_status_command
test_due_schedule
test_metrics_command
test_node_unit_tests
test_help_and_version

echo ""
echo "─────────────────────────────────────────────"
echo -e "  Passed: \033[38;2;74;222;128m\033[1m$PASS\033[0m   Failed: \033[38;2;248;113;113m\033[1m$FAIL\033[0m"
echo ""

[[ $FAIL -eq 0 ]]
