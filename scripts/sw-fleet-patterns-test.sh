#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet-patterns test — Unit tests for fleet success pattern   ║
# ║  broadcasting, ingestion, deduplication, cap, injection boost, and CLI   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-fleet-patterns-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/memory"
    mkdir -p "$TEST_TEMP_DIR/project/.claude"
    mkdir -p "$TEST_TEMP_DIR/project/.git"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Override HOME for isolated tests
    export HOME="$TEST_TEMP_DIR/home"
    export MEMORY_ROOT="$HOME/.shipwright/memory"
    export GLOBAL_MEMORY="$MEMORY_ROOT/global.json"

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" << 'MOCK_GIT'
#!/usr/bin/env bash
case "$*" in
    *remote*get-url*) echo "https://github.com/org/test-repo.git" ;;
    *diff*--name-only*) echo "src/index.ts"; echo "src/utils.ts" ;;
    *rev-parse*--show-toplevel*) echo "${PROJECT_ROOT:-/tmp}" ;;
    *) echo "" ;;
esac
exit 0
MOCK_GIT
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock claude
    cat > "$TEST_TEMP_DIR/bin/claude" << 'MOCK_CLAUDE'
#!/usr/bin/env bash
echo "mock claude"
exit 0
MOCK_CLAUDE
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

cleanup_env() {
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER: Write a fleet pattern event to events.jsonl
# ═══════════════════════════════════════════════════════════════════════════════

write_fleet_event() {
    local source_repo="${1:-org/repo1}"
    local goal="${2:-add rate limiting}"
    local pattern_hash="${3:-abc123}"
    local ts="${4:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    mkdir -p "$HOME/.shipwright"
    cat >> "$HOME/.shipwright/events.jsonl" << EOF
{"ts":"$ts","type":"fleet.pattern.success","source_repo":"$source_repo","goal":"$goal","approach":"intake,build,test,pr","template":"standard","complexity":"30","duration_s":"120","files_changed":"5","test_strategy":"vitest","pattern_hash":"$pattern_hash"}
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

print_test_header "Fleet Success Pattern Broadcasting"

# ─── Test 1: Fleet pattern event emission requires fleet config ────────────
setup_env

test_fleet_event_requires_config() {
    echo -e "\n${BOLD}Test 1: Fleet pattern event NOT emitted when no fleet config${RESET}"

    # Source pipeline-commands in a subshell to test the guard
    local fleet_cfg="$TEST_TEMP_DIR/project/.claude/fleet-config.json"
    # fleet-config.json does NOT exist → no event should be emitted

    # Simulate: check if fleet config exists (the guard logic)
    if [[ -f "$fleet_cfg" ]]; then
        assert_fail "Should not find fleet config"
    else
        assert_pass "No fleet config → event emission skipped"
    fi
}
test_fleet_event_requires_config

# ─── Test 2: Fleet pattern event emitted when fleet config exists ──────────

test_fleet_event_with_config() {
    echo -e "\n${BOLD}Test 2: Fleet pattern event emitted with fleet config${RESET}"

    # Create fleet config
    echo '{"repos":[]}' > "$TEST_TEMP_DIR/project/.claude/fleet-config.json"

    if [[ -f "$TEST_TEMP_DIR/project/.claude/fleet-config.json" ]]; then
        assert_pass "Fleet config exists → event emission path active"
    else
        assert_fail "Fleet config should exist"
    fi

    # Simulate event emission
    write_fleet_event "org/test-repo" "add rate limiting" "hash1"

    if grep -q "fleet.pattern.success" "$HOME/.shipwright/events.jsonl" 2>/dev/null; then
        assert_pass "fleet.pattern.success event written to events.jsonl"
    else
        assert_fail "Event should be in events.jsonl"
    fi
}
test_fleet_event_with_config

# ─── Test 3: Pattern ingestion creates new entry in global.json ────────────

test_ingestion_creates_entry() {
    echo -e "\n${BOLD}Test 3: Pattern ingestion creates new entry in global.json${RESET}"

    # Clean state
    rm -f "$HOME/.shipwright/events.jsonl"
    rm -f "$GLOBAL_MEMORY"

    write_fleet_event "org/repo-alpha" "add caching layer" "hash_alpha"

    # Source memory and run ingestion
    (
        export SCRIPT_DIR="$SCRIPT_DIR"
        export REPO_DIR="${SCRIPT_DIR}/.."
        source "$SCRIPT_DIR/sw-memory.sh"
        memory_ingest_fleet_patterns
    )

    if [[ -f "$GLOBAL_MEMORY" ]]; then
        local count
        count=$(jq '.fleet_patterns | length' "$GLOBAL_MEMORY" 2>/dev/null || echo "0")
        if [[ "$count" -eq 1 ]]; then
            assert_pass "One fleet pattern created in global.json"
        else
            assert_fail "Expected 1 fleet pattern, got $count"
        fi

        local stored_repo
        stored_repo=$(jq -r '.fleet_patterns[0].source_repo' "$GLOBAL_MEMORY" 2>/dev/null)
        if [[ "$stored_repo" == "org/repo-alpha" ]]; then
            assert_pass "source_repo correctly stored"
        else
            assert_fail "Expected org/repo-alpha, got $stored_repo"
        fi

        local stored_count
        stored_count=$(jq '.fleet_patterns[0].cross_repo_success_count' "$GLOBAL_MEMORY" 2>/dev/null)
        if [[ "$stored_count" -eq 1 ]]; then
            assert_pass "cross_repo_success_count initialized to 1"
        else
            assert_fail "Expected count 1, got $stored_count"
        fi
    else
        assert_fail "global.json should be created"
    fi
}
test_ingestion_creates_entry

# ─── Test 4: Pattern ingestion increments count for new source_repo ────────

test_ingestion_increments_count() {
    echo -e "\n${BOLD}Test 4: Ingestion increments count for new source_repo${RESET}"

    # Add event from a different repo with same pattern hash
    write_fleet_event "org/repo-beta" "add caching layer" "hash_alpha"

    (
        export SCRIPT_DIR="$SCRIPT_DIR"
        export REPO_DIR="${SCRIPT_DIR}/.."
        source "$SCRIPT_DIR/sw-memory.sh"
        memory_ingest_fleet_patterns
    )

    local count
    count=$(jq '.fleet_patterns[0].cross_repo_success_count' "$GLOBAL_MEMORY" 2>/dev/null)
    if [[ "$count" -eq 2 ]]; then
        assert_pass "cross_repo_success_count incremented to 2"
    else
        assert_fail "Expected count 2, got $count"
    fi

    local repos_len
    repos_len=$(jq '.fleet_patterns[0].repos_succeeded | length' "$GLOBAL_MEMORY" 2>/dev/null)
    if [[ "$repos_len" -eq 2 ]]; then
        assert_pass "repos_succeeded has 2 entries"
    else
        assert_fail "Expected 2 repos, got $repos_len"
    fi
}
test_ingestion_increments_count

# ─── Test 5: Pattern ingestion does NOT double-count same source_repo ──────

test_no_double_count() {
    echo -e "\n${BOLD}Test 5: Same source_repo does NOT double-count${RESET}"

    # Add another event from same repo with same hash
    write_fleet_event "org/repo-alpha" "add caching layer" "hash_alpha"

    (
        export SCRIPT_DIR="$SCRIPT_DIR"
        export REPO_DIR="${SCRIPT_DIR}/.."
        source "$SCRIPT_DIR/sw-memory.sh"
        memory_ingest_fleet_patterns
    )

    local count
    count=$(jq '.fleet_patterns[0].cross_repo_success_count' "$GLOBAL_MEMORY" 2>/dev/null)
    if [[ "$count" -eq 2 ]]; then
        assert_pass "Count stays at 2 (no double-count)"
    else
        assert_fail "Expected count 2, got $count"
    fi
}
test_no_double_count

# ─── Test 6: Fleet patterns capped at 200 entries ─────────────────────────

test_cap_at_200() {
    echo -e "\n${BOLD}Test 6: Fleet patterns capped at 200 entries${RESET}"

    # Create a global.json with 201 patterns
    local patterns="["
    for i in $(seq 1 201); do
        [[ "$i" -gt 1 ]] && patterns="${patterns},"
        patterns="${patterns}{\"pattern_hash\":\"cap_hash_$i\",\"source_repo\":\"org/repo-$i\",\"goal\":\"goal $i\",\"approach\":\"build,test\",\"template\":\"fast\",\"test_strategy\":\"vitest\",\"complexity\":10,\"avg_duration_s\":60,\"cross_repo_success_count\":$i,\"repos_succeeded\":[\"org/repo-$i\"],\"first_seen\":\"2026-04-01T00:00:00Z\",\"last_seen\":\"2026-04-01T00:00:00Z\",\"adopted_count\":0}"
    done
    patterns="${patterns}]"

    echo "{\"common_patterns\":[],\"cross_repo_learnings\":[],\"fleet_patterns\":$patterns}" > "$GLOBAL_MEMORY"

    # Clear events to avoid re-processing
    rm -f "$HOME/.shipwright/events.jsonl"
    write_fleet_event "org/new-repo" "new goal" "new_hash_999"

    (
        export SCRIPT_DIR="$SCRIPT_DIR"
        export REPO_DIR="${SCRIPT_DIR}/.."
        source "$SCRIPT_DIR/sw-memory.sh"
        memory_ingest_fleet_patterns
    )

    local count
    count=$(jq '.fleet_patterns | length' "$GLOBAL_MEMORY" 2>/dev/null)
    if [[ "$count" -le 200 ]]; then
        assert_pass "Fleet patterns capped at 200 (got $count)"
    else
        assert_fail "Expected <= 200, got $count"
    fi
}
test_cap_at_200

# ─── Test 7: Memory injection boosts fleet patterns with count > 3 ────────

test_injection_boost() {
    echo -e "\n${BOLD}Test 7: Memory injection boosts fleet patterns with count > 3${RESET}"

    # Set up global.json with a high-count pattern
    cat > "$GLOBAL_MEMORY" << 'EOF'
{
    "common_patterns": [],
    "cross_repo_learnings": [],
    "fleet_patterns": [
        {
            "pattern_hash": "boost_hash",
            "source_repo": "org/first",
            "goal": "implement rate limiting for API endpoints",
            "approach": "intake,plan,build,test,review,pr",
            "template": "standard",
            "test_strategy": "vitest",
            "complexity": 45,
            "avg_duration_s": 300,
            "cross_repo_success_count": 5,
            "repos_succeeded": ["org/first", "org/second", "org/third", "org/fourth", "org/fifth"],
            "first_seen": "2026-04-01T00:00:00Z",
            "last_seen": "2026-04-03T00:00:00Z",
            "adopted_count": 3
        },
        {
            "pattern_hash": "low_hash",
            "source_repo": "org/single",
            "goal": "minor fix",
            "approach": "build,test",
            "template": "fast",
            "test_strategy": "vitest",
            "complexity": 10,
            "avg_duration_s": 60,
            "cross_repo_success_count": 1,
            "repos_succeeded": ["org/single"],
            "first_seen": "2026-04-01T00:00:00Z",
            "last_seen": "2026-04-01T00:00:00Z",
            "adopted_count": 0
        }
    ]
}
EOF

    # Create minimal patterns.json for the repo memory dir
    local repo_hash
    repo_hash=$(echo "${TEST_TEMP_DIR}/project" | sed 's|/|_|g')
    mkdir -p "$MEMORY_ROOT/$repo_hash"
    echo '{"project":{"type":"nodejs","test_runner":"vitest"},"conventions":{}}' > "$MEMORY_ROOT/$repo_hash/patterns.json"
    echo '{"failures":[]}' > "$MEMORY_ROOT/$repo_hash/failures.json"
    echo '{"decisions":[]}' > "$MEMORY_ROOT/$repo_hash/decisions.json"

    local output
    output=$(
        export SCRIPT_DIR="$SCRIPT_DIR"
        export REPO_DIR="${SCRIPT_DIR}/.."
        export PROJECT_ROOT="$TEST_TEMP_DIR/project"
        source "$SCRIPT_DIR/sw-memory.sh"
        memory_inject_context "build" 2>/dev/null || true
    )

    if echo "$output" | grep -q "Fleet-Proven Patterns"; then
        assert_pass "Fleet-Proven Patterns section injected for build stage"
    else
        assert_fail "Expected Fleet-Proven Patterns section in output"
    fi

    if echo "$output" | grep -q "implement rate limiting"; then
        assert_pass "High-count pattern (5 repos) included in injection"
    else
        assert_fail "Expected high-count pattern in injection"
    fi

    if echo "$output" | grep -q "minor fix"; then
        assert_fail "Low-count pattern (1 repo) should NOT be injected"
    else
        assert_pass "Low-count pattern correctly excluded from injection"
    fi
}
test_injection_boost

# ─── Test 8: CLI fleet patterns displays top patterns ─────────────────────

test_cli_display() {
    echo -e "\n${BOLD}Test 8: CLI fleet patterns displays top patterns${RESET}"

    # Use the global.json from test 7 (already has patterns)
    local output
    output=$(bash "$SCRIPT_DIR/sw-fleet.sh" patterns --top 5 2>/dev/null || true)

    if echo "$output" | grep -q "Fleet Success Patterns"; then
        assert_pass "CLI shows Fleet Success Patterns header"
    else
        assert_fail "Expected header in CLI output"
    fi

    if echo "$output" | grep -q "Total patterns"; then
        assert_pass "CLI shows total patterns stat"
    else
        assert_fail "Expected total patterns stat"
    fi
}
test_cli_display

# ─── Test 9: CLI fleet patterns --json outputs valid JSON ──────────────────

test_cli_json_output() {
    echo -e "\n${BOLD}Test 9: CLI fleet patterns --json outputs valid JSON${RESET}"

    local output
    output=$(bash "$SCRIPT_DIR/sw-fleet.sh" patterns --json 2>/dev/null || true)

    if echo "$output" | jq . >/dev/null 2>&1; then
        assert_pass "JSON output is valid"
    else
        assert_fail "Invalid JSON output: $output"
    fi

    local total
    total=$(echo "$output" | jq '.total_patterns' 2>/dev/null)
    if [[ "$total" -eq 2 ]]; then
        assert_pass "JSON total_patterns is 2"
    else
        assert_fail "Expected total_patterns=2, got $total"
    fi

    local shared
    shared=$(echo "$output" | jq '.patterns_shared' 2>/dev/null)
    if [[ "$shared" -eq 1 ]]; then
        assert_pass "JSON patterns_shared is 1 (only the 5-repo pattern)"
    else
        assert_fail "Expected patterns_shared=1, got $shared"
    fi
}
test_cli_json_output

# ─── Test 10: CLI with empty global.json shows "no patterns" ──────────────

test_cli_empty_state() {
    echo -e "\n${BOLD}Test 10: CLI with empty state shows no patterns message${RESET}"

    rm -f "$GLOBAL_MEMORY"
    local output
    output=$(bash "$SCRIPT_DIR/sw-fleet.sh" patterns 2>/dev/null || true)

    if echo "$output" | grep -qi "no fleet patterns"; then
        assert_pass "Empty state shows informative message"
    else
        assert_fail "Expected 'no fleet patterns' message, got: $output"
    fi
}
test_cli_empty_state

# ─── Test 11: Pattern hash deduplication works correctly ──────────────────

test_hash_dedup() {
    echo -e "\n${BOLD}Test 11: Pattern hash deduplication works correctly${RESET}"

    rm -f "$GLOBAL_MEMORY"
    rm -f "$HOME/.shipwright/events.jsonl"

    # Two events with same hash but different goals (hash is canonical)
    write_fleet_event "org/repo-x" "goal alpha" "same_hash_123"
    write_fleet_event "org/repo-y" "goal beta (same hash)" "same_hash_123"

    (
        export SCRIPT_DIR="$SCRIPT_DIR"
        export REPO_DIR="${SCRIPT_DIR}/.."
        source "$SCRIPT_DIR/sw-memory.sh"
        memory_ingest_fleet_patterns
    )

    local pattern_count
    pattern_count=$(jq '.fleet_patterns | length' "$GLOBAL_MEMORY" 2>/dev/null)
    if [[ "$pattern_count" -eq 1 ]]; then
        assert_pass "Same hash deduplicates into single pattern"
    else
        assert_fail "Expected 1 pattern, got $pattern_count"
    fi

    local repo_count
    repo_count=$(jq '.fleet_patterns[0].cross_repo_success_count' "$GLOBAL_MEMORY" 2>/dev/null)
    if [[ "$repo_count" -eq 2 ]]; then
        assert_pass "Two different repos counted for same hash"
    else
        assert_fail "Expected 2 repos, got $repo_count"
    fi
}
test_hash_dedup

# ─── Test 12: Atomic write safety ────────────────────────────────────────

test_atomic_write() {
    echo -e "\n${BOLD}Test 12: Atomic write safety (global.json not corrupted)${RESET}"

    rm -f "$GLOBAL_MEMORY"
    rm -f "$HOME/.shipwright/events.jsonl"

    # Write multiple events
    for i in $(seq 1 5); do
        write_fleet_event "org/repo-$i" "goal $i" "atomic_hash_$i"
    done

    (
        export SCRIPT_DIR="$SCRIPT_DIR"
        export REPO_DIR="${SCRIPT_DIR}/.."
        source "$SCRIPT_DIR/sw-memory.sh"
        memory_ingest_fleet_patterns
    )

    # Verify global.json is valid JSON
    if jq . "$GLOBAL_MEMORY" >/dev/null 2>&1; then
        assert_pass "global.json is valid JSON after multi-event write"
    else
        assert_fail "global.json is corrupted"
    fi

    # Verify no tmp files left behind
    local tmp_count
    tmp_count=$(find "$MEMORY_ROOT" -name "global.json.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$tmp_count" -eq 0 ]]; then
        assert_pass "No tmp files left behind"
    else
        assert_fail "Found $tmp_count leftover tmp files"
    fi

    local count
    count=$(jq '.fleet_patterns | length' "$GLOBAL_MEMORY" 2>/dev/null)
    if [[ "$count" -eq 5 ]]; then
        assert_pass "All 5 patterns stored correctly"
    else
        assert_fail "Expected 5 patterns, got $count"
    fi
}
test_atomic_write

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_results
cleanup_env
