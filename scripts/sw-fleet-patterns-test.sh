#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet-patterns test — Validate pattern extraction, query,    ║
# ║  effectiveness tracking, prune, and stats.                               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

SUT="$SCRIPT_DIR/sw-fleet-patterns.sh"

setup() {
    setup_test_env "sw-fleet-patterns-test"
    export FLEET_PATTERNS_FILE="$TEST_TEMP_DIR/home/.shipwright/fleet-patterns.json"
    rm -f "$FLEET_PATTERNS_FILE"
}

teardown() {
    cleanup_test_env
}

run_sut() {
    "$SUT" "$@"
}

# ─── Tests ───────────────────────────────────────────────────────────────────

test_store_initialization() {
    print_test_section "Store initialization"
    setup
    run_sut stats >/dev/null
    if [[ -f "$FLEET_PATTERNS_FILE" ]]; then
        assert_pass "fleet-patterns.json created on first use"
    else
        assert_fail "fleet-patterns.json should be created"
    fi
    local schema
    schema=$(jq -r '.schema_version' "$FLEET_PATTERNS_FILE")
    assert_eq "schema_version is 1" "1" "$schema"
    teardown
}

test_extract_creates_pattern() {
    print_test_section "extract creates a new pattern"
    setup
    local id
    id=$(run_sut extract --tech-stack "node" --issue-signature "timeout" \
                         --error-signature "ECONNRESET" --root-cause "no retry" \
                         --fix "add retries" --files "src/api.js" \
                         --repo "test/repo" --cost 0.5 --iterations 2 2>/dev/null)
    assert_pass "extract returned a pattern id"
    [[ -n "$id" ]] && assert_pass "pattern id is non-empty" || assert_fail "pattern id missing"

    local count
    count=$(jq '.patterns | length' "$FLEET_PATTERNS_FILE")
    assert_eq "store has 1 pattern after extract" "1" "$count"

    local stored_id
    stored_id=$(jq -r '.patterns[0].id' "$FLEET_PATTERNS_FILE")
    assert_eq "stored id matches returned id" "$id" "$stored_id"
    teardown
}

test_extract_idempotent() {
    print_test_section "extract is idempotent on (tech, issue, error)"
    setup
    local id1 id2
    id1=$(run_sut extract --tech-stack "node" --issue-signature "timeout" \
                         --error-signature "ECONNRESET" --repo "repo1" 2>/dev/null)
    id2=$(run_sut extract --tech-stack "node" --issue-signature "timeout" \
                         --error-signature "ECONNRESET" --repo "repo2" 2>/dev/null)
    assert_eq "same signature yields same id" "$id1" "$id2"

    local count
    count=$(jq '.patterns | length' "$FLEET_PATTERNS_FILE")
    assert_eq "second extract did not duplicate" "1" "$count"

    local repos
    repos=$(jq -r '.patterns[0].source_repos | length' "$FLEET_PATTERNS_FILE")
    assert_eq "source_repos accumulated both repos" "2" "$repos"
    teardown
}

test_query_finds_match() {
    print_test_section "query finds matching pattern"
    setup
    run_sut extract --tech-stack "node vitest npm" --issue-signature "api timeout" \
                    --error-signature "ECONNRESET" --root-cause "no retry" \
                    --fix "p-retry" >/dev/null

    local result
    result=$(run_sut query --tech-stack "node vitest" --issue-signature "timeout in api" \
                           --top 1 --json 2>/dev/null)

    local n
    n=$(echo "$result" | jq '.matches | length')
    assert_eq "query returns 1 match" "1" "$n"

    local score
    score=$(echo "$result" | jq -r '.matches[0].match_score')
    assert_gt "match score > 0" "$score" "0"
    teardown
}

test_query_threshold() {
    print_test_section "query threshold filters out low-score matches"
    setup
    run_sut extract --tech-stack "python" --issue-signature "totally unrelated" \
                    --error-signature "ZeroDivisionError" >/dev/null

    local result
    result=$(run_sut query --tech-stack "node" --issue-signature "timeout" \
                           --threshold 80 --json 2>/dev/null)
    local n
    n=$(echo "$result" | jq '.matches | length')
    assert_eq "high threshold filters non-matches" "0" "$n"
    teardown
}

test_record_use_updates_effectiveness() {
    print_test_section "record-use updates effectiveness"
    setup
    local id
    id=$(run_sut extract --tech-stack "go" --issue-signature "race" \
                         --error-signature "DATA RACE" 2>/dev/null)

    run_sut record-use --id "$id" --outcome success --cost 0.1 >/dev/null
    run_sut record-use --id "$id" --outcome success --cost 0.1 >/dev/null
    run_sut record-use --id "$id" --outcome failure --cost 0.2 >/dev/null

    local uses successes failures eff
    uses=$(jq ".patterns[] | select(.id==\"$id\") | .uses" "$FLEET_PATTERNS_FILE")
    successes=$(jq ".patterns[] | select(.id==\"$id\") | .successes" "$FLEET_PATTERNS_FILE")
    failures=$(jq ".patterns[] | select(.id==\"$id\") | .failures" "$FLEET_PATTERNS_FILE")
    eff=$(jq ".patterns[] | select(.id==\"$id\") | .effectiveness" "$FLEET_PATTERNS_FILE")

    assert_eq "uses incremented to 3" "3" "$uses"
    # Initial extract was success → 1, plus 2 successes record-use = 3
    assert_eq "successes counted" "3" "$successes"
    assert_eq "failure counted" "1" "$failures"
    # effectiveness = 3 / 4 = 0.75
    local eff_pct
    eff_pct=$(awk -v e="$eff" 'BEGIN{ printf "%d", e*100 }')
    assert_eq "effectiveness = 75%" "75" "$eff_pct"
    teardown
}

test_record_use_missing_id() {
    print_test_section "record-use rejects unknown id"
    setup
    run_sut extract --tech-stack "x" --issue-signature "y" --error-signature "z" >/dev/null
    if run_sut record-use --id "nonexistent" --outcome success >/dev/null 2>&1; then
        assert_fail "record-use should fail on unknown id"
    else
        assert_pass "record-use rejects unknown id"
    fi
    teardown
}

test_prune_removes_ineffective() {
    print_test_section "prune evicts low-effectiveness patterns"
    setup
    local good_id bad_id
    good_id=$(run_sut extract --tech-stack "good" --issue-signature "g" --error-signature "G" 2>/dev/null)
    bad_id=$(run_sut extract --tech-stack "bad" --issue-signature "b" --error-signature "B" 2>/dev/null)

    # Make bad_id ineffective: 6 failures, 0 successes
    for _ in 1 2 3 4 5 6; do
        run_sut record-use --id "$bad_id" --outcome failure >/dev/null
    done
    # Make good_id effective
    for _ in 1 2 3 4 5 6; do
        run_sut record-use --id "$good_id" --outcome success >/dev/null
    done

    # Force both patterns to look old by overwriting their timestamps
    local old_ts="2020-01-01T00:00:00Z"
    local mutated
    mutated=$(jq --arg ts "$old_ts" '.patterns |= map(.created_at = $ts | .updated_at = $ts)' "$FLEET_PATTERNS_FILE")
    echo "$mutated" > "$FLEET_PATTERNS_FILE"

    run_sut prune --max-age-days 30 --min-effectiveness 0.4 --min-uses 5 >/dev/null

    local remaining
    remaining=$(jq '.patterns | length' "$FLEET_PATTERNS_FILE")
    assert_eq "only effective pattern survives" "1" "$remaining"

    local kept_id
    kept_id=$(jq -r '.patterns[0].id' "$FLEET_PATTERNS_FILE")
    assert_eq "kept the effective pattern" "$good_id" "$kept_id"
    teardown
}

test_prune_dry_run() {
    print_test_section "prune --dry-run does not modify store"
    setup
    run_sut extract --tech-stack "x" --issue-signature "y" --error-signature "z" >/dev/null
    local before
    before=$(jq '.patterns | length' "$FLEET_PATTERNS_FILE")
    run_sut prune --dry-run >/dev/null
    local after
    after=$(jq '.patterns | length' "$FLEET_PATTERNS_FILE")
    assert_eq "dry-run preserves store" "$before" "$after"
    teardown
}

test_stats_json() {
    print_test_section "stats --json emits valid JSON"
    setup
    run_sut extract --tech-stack "node" --issue-signature "x" --error-signature "y" --repo "r1" >/dev/null
    run_sut extract --tech-stack "go" --issue-signature "a" --error-signature "b" --repo "r2" >/dev/null

    local out
    out=$(run_sut stats --json 2>/dev/null)
    local n
    n=$(echo "$out" | jq -r '.total_patterns')
    assert_eq "stats reports 2 patterns" "2" "$n"

    local repos
    repos=$(echo "$out" | jq -r '.unique_repos')
    assert_eq "stats reports 2 unique repos" "2" "$repos"
    teardown
}

test_extract_requires_signature() {
    print_test_section "extract requires at least one signature"
    setup
    if run_sut extract >/dev/null 2>&1; then
        assert_fail "extract should fail with no signatures"
    else
        assert_pass "extract rejects empty signatures"
    fi
    teardown
}

test_query_empty_store() {
    print_test_section "query on empty store returns empty matches"
    setup
    local out
    out=$(run_sut query --tech-stack "anything" --json 2>/dev/null)
    local n
    n=$(echo "$out" | jq '.matches | length')
    assert_eq "empty store returns no matches" "0" "$n"
    teardown
}

# ─── Run all ─────────────────────────────────────────────────────────────────
print_test_header "sw-fleet-patterns Test Suite"

test_store_initialization
test_extract_creates_pattern
test_extract_idempotent
test_query_finds_match
test_query_threshold
test_record_use_updates_effectiveness
test_record_use_missing_id
test_prune_removes_ineffective
test_prune_dry_run
test_stats_json
test_extract_requires_signature
test_query_empty_store

print_test_results
