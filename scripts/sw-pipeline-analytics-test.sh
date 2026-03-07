#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright analytics test — Validate pipeline analytics engine          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"

    # Link real jq and sqlite3
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    if command -v sqlite3 &>/dev/null; then
        ln -sf "$(command -v sqlite3)" "$TEST_TEMP_DIR/bin/sqlite3"
    fi

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Link real date
    if command -v date &>/dev/null; then
        ln -sf "$(command -v date)" "$TEST_TEMP_DIR/bin/date"
    fi

    # Mock bc (may not be installed)
    if ! command -v bc &>/dev/null; then
        cat > "$TEST_TEMP_DIR/bin/bc" <<'MOCKEOF'
#!/usr/bin/env bash
echo "0"
MOCKEOF
        chmod +x "$TEST_TEMP_DIR/bin/bc"
    else
        ln -sf "$(command -v bc)" "$TEST_TEMP_DIR/bin/bc"
    fi

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

seed_db() {
    local db_file="$HOME/.shipwright/shipwright.db"

    # Source sw-db.sh to initialize schema
    (
        export HOME="$TEST_TEMP_DIR/home"
        source "$SCRIPT_DIR/sw-db.sh"
        init_schema
    )

    # Seed pipeline_runs
    sqlite3 "$db_file" <<'SQL'
INSERT INTO pipeline_runs (job_id, issue_number, goal, branch, status, template, started_at, completed_at, duration_secs, stage_name, created_at)
VALUES
    ('job-001', 1, 'Add login page', 'feat/login', 'completed', 'standard', '2026-03-06T10:00:00Z', '2026-03-06T10:05:00Z', 300, 'pr', '2026-03-06T10:00:00Z'),
    ('job-002', 2, 'Fix auth bug', 'fix/auth', 'completed', 'fast', '2026-03-06T14:00:00Z', '2026-03-06T14:02:00Z', 120, 'pr', '2026-03-06T14:00:00Z'),
    ('job-003', 3, 'Refactor DB layer', 'refactor/db', 'failed', 'standard', '2026-03-05T08:00:00Z', '2026-03-05T08:10:00Z', 600, 'build', '2026-03-05T08:00:00Z'),
    ('job-004', 4, 'Add dashboard', 'feat/dash', 'completed', 'full', '2026-03-05T16:00:00Z', '2026-03-05T16:20:00Z', 1200, 'pr', '2026-03-05T16:00:00Z'),
    ('job-005', 5, 'Fix CSS regression', 'fix/css', 'failed', 'fast', '2026-03-04T22:00:00Z', '2026-03-04T22:03:00Z', 180, 'test', '2026-03-04T22:00:00Z'),
    ('job-006', 6, 'Active pipeline', 'feat/active', 'running', 'autonomous', '2026-03-07T01:00:00Z', NULL, NULL, 'build', '2026-03-07T01:00:00Z');
SQL

    # Seed pipeline_stages (failures)
    sqlite3 "$db_file" <<'SQL'
INSERT INTO pipeline_stages (job_id, stage_name, status, started_at, completed_at, duration_secs, error_message, created_at)
VALUES
    ('job-003', 'build', 'failed', '2026-03-05T08:05:00Z', '2026-03-05T08:10:00Z', 300, 'Compilation error in module.ts', '2026-03-05T08:05:00Z'),
    ('job-005', 'test', 'failed', '2026-03-04T22:01:00Z', '2026-03-04T22:03:00Z', 120, 'Assertion failed: expected 200 got 500', '2026-03-04T22:01:00Z'),
    ('job-001', 'build', 'completed', '2026-03-06T10:01:00Z', '2026-03-06T10:03:00Z', 120, '', '2026-03-06T10:01:00Z'),
    ('job-001', 'test', 'completed', '2026-03-06T10:03:00Z', '2026-03-06T10:04:00Z', 60, '', '2026-03-06T10:03:00Z');
SQL

    # Seed pipeline_outcomes
    sqlite3 "$db_file" <<'SQL'
INSERT INTO pipeline_outcomes (job_id, issue_number, template, success, duration_secs, cost_usd, complexity, created_at)
VALUES
    ('job-001', '1', 'standard', 1, 300, 0.50, 'medium', '2026-03-06T10:05:00Z'),
    ('job-002', '2', 'fast', 1, 120, 0.20, 'low', '2026-03-06T14:02:00Z'),
    ('job-003', '3', 'standard', 0, 600, 0.80, 'high', '2026-03-05T08:10:00Z'),
    ('job-004', '4', 'full', 1, 1200, 1.50, 'high', '2026-03-05T16:20:00Z'),
    ('job-005', '5', 'fast', 0, 180, 0.15, 'low', '2026-03-04T22:03:00Z');
SQL

    # Seed cost_entries
    sqlite3 "$db_file" <<'SQL'
INSERT INTO cost_entries (input_tokens, output_tokens, model, stage, cost_usd, ts, ts_epoch)
VALUES
    (10000, 5000, 'sonnet', 'build', 0.50, '2026-03-06T10:00:00Z', 1772920800),
    (8000, 3000, 'haiku', 'test', 0.20, '2026-03-06T14:00:00Z', 1772935200),
    (15000, 8000, 'opus', 'review', 1.50, '2026-03-05T16:00:00Z', 1772856000);
SQL
}

trap cleanup_test_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Pipeline Analytics Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: --help flag ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-pipeline-analytics.sh" --help 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--help exits 0"
else
    assert_fail "--help exits 0" "exit code: $rc"
fi
assert_contains "--help shows USAGE" "$output" "USAGE"
assert_contains "--help shows --json" "$output" "--json"
assert_contains "--help shows --period" "$output" "--period"
assert_contains "--help shows --active" "$output" "--active"

# ─── Test 2: VERSION is defined ─────────────────────────────────────────────
if grep -q '^VERSION=' "$SCRIPT_DIR/sw-pipeline-analytics.sh"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

# ─── Test 3: Empty database — terminal mode ─────────────────────────────────
echo ""
echo -e "${DIM}  empty database${RESET}"

output=$(bash "$SCRIPT_DIR/sw-pipeline-analytics.sh" 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "empty db — exits 0"
else
    assert_fail "empty db — exits 0" "exit code: $rc"
fi

# ─── Test 4: Empty database — JSON mode ─────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-pipeline-analytics.sh" --json 2>/dev/null) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "empty db --json exits 0"
else
    assert_fail "empty db --json exits 0" "exit code: $rc"
fi

if echo "$output" | jq -e '.summary.total_runs' >/dev/null 2>&1; then
    total=$(echo "$output" | jq '.summary.total_runs')
    assert_eq "empty db returns total_runs=0" "0" "$total"
else
    assert_fail "empty db JSON has summary.total_runs" "output: $output"
fi

if echo "$output" | jq -e '.by_template' >/dev/null 2>&1; then
    assert_pass "empty db JSON has by_template key"
else
    assert_fail "empty db JSON has by_template key"
fi

# ─── Test 5: Seeded database — JSON structure ──────────────────────────────
echo ""
echo -e "${DIM}  seeded database${RESET}"

seed_db

output=$(bash "$SCRIPT_DIR/sw-pipeline-analytics.sh" --json --period 90 2>/dev/null) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "seeded db --json exits 0"
else
    assert_fail "seeded db --json exits 0" "exit code: $rc"
fi

# Validate JSON schema
for key in summary by_template by_stage_failure by_complexity by_hour trends active_pipelines period_days generated_at; do
    if echo "$output" | jq -e ".$key" >/dev/null 2>&1; then
        assert_pass "JSON has key: $key"
    else
        assert_fail "JSON has key: $key" "output: $(echo "$output" | head -3)"
    fi
done

# ─── Test 6: Summary values correct ────────────────────────────────────────
echo ""
echo -e "${DIM}  summary values${RESET}"

total=$(echo "$output" | jq '.summary.total_runs')
successful=$(echo "$output" | jq '.summary.successful')
failed_count=$(echo "$output" | jq '.summary.failed')
rate=$(echo "$output" | jq '.summary.success_rate')

# We seeded 5 completed/failed runs + 1 running = 6 total in pipeline_runs
# But summary counts all statuses, so total should be 6
# completed=3, failed=2
if [[ "$successful" -ge 3 ]]; then
    assert_pass "summary.successful >= 3 (got $successful)"
else
    assert_fail "summary.successful >= 3" "got $successful"
fi

if [[ "$failed_count" -ge 2 ]]; then
    assert_pass "summary.failed >= 2 (got $failed_count)"
else
    assert_fail "summary.failed >= 2" "got $failed_count"
fi

if echo "$output" | jq -e '.summary.success_rate > 0' >/dev/null 2>&1; then
    assert_pass "success_rate > 0 (got $rate)"
else
    assert_fail "success_rate > 0" "got $rate"
fi

# ─── Test 7: Template breakdown ────────────────────────────────────────────
echo ""
echo -e "${DIM}  template breakdown${RESET}"

template_count=$(echo "$output" | jq '.by_template | length')
if [[ "$template_count" -ge 2 ]]; then
    assert_pass "by_template has >= 2 entries (got $template_count)"
else
    assert_fail "by_template has >= 2 entries" "got $template_count"
fi

# Check that 'standard' template appears
if echo "$output" | jq -e '.by_template[] | select(.template == "standard")' >/dev/null 2>&1; then
    assert_pass "by_template includes 'standard'"
else
    assert_fail "by_template includes 'standard'"
fi

# ─── Test 8: Stage failure attribution ─────────────────────────────────────
echo ""
echo -e "${DIM}  stage failure attribution${RESET}"

stage_count=$(echo "$output" | jq '.by_stage_failure | length')
if [[ "$stage_count" -ge 1 ]]; then
    assert_pass "by_stage_failure has entries (got $stage_count)"
else
    assert_fail "by_stage_failure has entries" "got $stage_count"
fi

# build and test should appear as failing stages
if echo "$output" | jq -e '.by_stage_failure[] | select(.stage_name == "build" or .stage_name == "test")' >/dev/null 2>&1; then
    assert_pass "failure attribution includes build or test stage"
else
    assert_fail "failure attribution includes build or test stage"
fi

# ─── Test 9: Complexity breakdown ──────────────────────────────────────────
echo ""
echo -e "${DIM}  complexity breakdown${RESET}"

complexity_count=$(echo "$output" | jq '.by_complexity | length')
if [[ "$complexity_count" -ge 1 ]]; then
    assert_pass "by_complexity has entries (got $complexity_count)"
else
    assert_fail "by_complexity has entries" "got $complexity_count"
fi

# ─── Test 10: Trends ──────────────────────────────────────────────────────
echo ""
echo -e "${DIM}  trends${RESET}"

trend_count=$(echo "$output" | jq '.trends.periods | length')
assert_eq "trends has 3 periods" "3" "$trend_count"

if echo "$output" | jq -e '.trends.periods[] | select(.label == "7d")' >/dev/null 2>&1; then
    assert_pass "trends includes 7d period"
else
    assert_fail "trends includes 7d period"
fi

if echo "$output" | jq -e '.trends.periods[] | select(.label == "90d")' >/dev/null 2>&1; then
    assert_pass "trends includes 90d period"
else
    assert_fail "trends includes 90d period"
fi

# ─── Test 11: Active pipelines ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  active pipelines${RESET}"

active_count=$(echo "$output" | jq '.active_pipelines | length')
if [[ "$active_count" -ge 1 ]]; then
    assert_pass "active_pipelines has >= 1 entry (got $active_count)"
else
    assert_fail "active_pipelines has >= 1 entry" "got $active_count"
fi

# ─── Test 12: --active flag ───────────────────────────────────────────────
echo ""
echo -e "${DIM}  --active flag${RESET}"

active_output=$(bash "$SCRIPT_DIR/sw-pipeline-analytics.sh" --active --json 2>/dev/null) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--active --json exits 0"
else
    assert_fail "--active --json exits 0" "exit code: $rc"
fi

# Should return just the active pipelines array
if echo "$active_output" | jq -e '.[0].job_id' >/dev/null 2>&1; then
    assert_pass "--active returns array with job_id"
else
    # Could also be an empty array if active runs already expired
    if echo "$active_output" | jq -e 'type == "array"' >/dev/null 2>&1; then
        assert_pass "--active returns valid array"
    else
        assert_fail "--active returns valid array" "output: $active_output"
    fi
fi

# ─── Test 13: Period filtering ─────────────────────────────────────────────
echo ""
echo -e "${DIM}  period filtering${RESET}"

period_output=$(bash "$SCRIPT_DIR/sw-pipeline-analytics.sh" --json --period 30 2>/dev/null) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--period 30 exits 0"
else
    assert_fail "--period 30 exits 0" "exit code: $rc"
fi

period_val=$(echo "$period_output" | jq '.period_days')
assert_eq "period_days matches requested" "30" "$period_val"

# ─── Test 14: Invalid period falls back ────────────────────────────────────
invalid_output=$(bash "$SCRIPT_DIR/sw-pipeline-analytics.sh" --json --period 999 2>/dev/null) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "invalid period falls back gracefully"
else
    assert_fail "invalid period falls back gracefully" "exit code: $rc"
fi

# ─── Test 15: Terminal output (non-JSON) ──────────────────────────────────
echo ""
echo -e "${DIM}  terminal output${RESET}"

terminal_output=$(bash "$SCRIPT_DIR/sw-pipeline-analytics.sh" --period 90 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "terminal output exits 0"
else
    assert_fail "terminal output exits 0" "exit code: $rc"
fi

assert_contains "terminal shows Pipeline Analytics" "$terminal_output" "Pipeline Analytics"
assert_contains "terminal shows Summary" "$terminal_output" "Summary"

# ─── Test 16: Cost total included ──────────────────────────────────────────
echo ""
echo -e "${DIM}  cost tracking${RESET}"

cost_val=$(echo "$output" | jq '.summary.total_cost_usd')
if echo "$output" | jq -e '.summary.total_cost_usd >= 0' >/dev/null 2>&1; then
    assert_pass "total_cost_usd >= 0 (got $cost_val)"
else
    assert_fail "total_cost_usd >= 0" "got $cost_val"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_results
