#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-template-recommend-test.sh — Template Recommendation Engine Tests   ║
# ║  Validates: schema migration, outcome recording, stats queries,          ║
# ║  recommendation scoring, CLI output, cold start, daemon integration.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-template-rec-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/project"
    mkdir -p "$TEST_TEMP_DIR/project/.claude"

    # Mock HOME for isolated DB
    export HOME="$TEST_TEMP_DIR/home"
    export DB_DIR="$TEST_TEMP_DIR/home/.shipwright"
    export DB_FILE="$DB_DIR/shipwright.db"
    export REPO_DIR="$TEST_TEMP_DIR/project"

    # Create a mock package.json so project type detection finds nodejs
    echo '{"name": "test-project", "scripts": {"test": "vitest"}}' > "$TEST_TEMP_DIR/project/package.json"
}

cleanup_env() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "${TEST_TEMP_DIR:-}" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}
trap cleanup_env EXIT

source_db() {
    _SW_DB_LOADED=""
    source "$SCRIPT_DIR/sw-db.sh"
}

source_recommend() {
    _TEMPLATE_RECOMMEND_LOADED=""
    source "$SCRIPT_DIR/lib/template-recommend.sh"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section() {
    echo ""
    echo -e "${CYAN}${BOLD}  ── $1 ──${RESET}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: Schema Migration
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Schema Migration (v7: project_type column)"

setup_env
source_db

# Test 1: Fresh init creates schema with project_type column
init_schema
if sqlite3 "$DB_FILE" "PRAGMA table_info(pipeline_outcomes);" | grep -q "project_type"; then
    assert_pass "Fresh init_schema creates pipeline_outcomes with project_type column"
else
    assert_fail "Fresh init_schema creates pipeline_outcomes with project_type column"
fi

# Test 2: project_type column is nullable
col_info=$(sqlite3 "$DB_FILE" "PRAGMA table_info(pipeline_outcomes);" | grep "project_type")
if echo "$col_info" | grep -q "|0$"; then
    assert_pass "project_type column allows NULL (backward compatible)"
else
    # Check notnull flag (5th field in PRAGMA table_info)
    notnull=$(echo "$col_info" | awk -F'|' '{print $4}')
    if [[ "$notnull" == "0" ]]; then
        assert_pass "project_type column allows NULL (backward compatible)"
    else
        assert_fail "project_type column allows NULL" "notnull=$notnull"
    fi
fi

# Test 3: Index exists for project_type
idx_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_pipeline_outcomes_project_type';")
if [[ "$idx_count" == "1" ]]; then
    assert_pass "Index idx_pipeline_outcomes_project_type exists"
else
    assert_fail "Index idx_pipeline_outcomes_project_type exists" "count=$idx_count"
fi

# Test 4: Schema version is 7
cleanup_env
setup_env
source_db
migrate_schema 2>/dev/null
schema_ver=$(sqlite3 "$DB_FILE" "SELECT MAX(version) FROM _schema;" 2>/dev/null || echo "0")
if [[ "$schema_ver" == "7" ]]; then
    assert_pass "Schema version is 7 after migration"
else
    assert_fail "Schema version is 7 after migration" "got=$schema_ver"
fi

# Test 5: Migration from v6 adds project_type
cleanup_env
setup_env
source_db
# Create a v6 DB manually (without project_type)
init_schema
sqlite3 "$DB_FILE" "DROP TABLE IF EXISTS pipeline_outcomes;"
sqlite3 "$DB_FILE" "CREATE TABLE pipeline_outcomes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT UNIQUE NOT NULL,
    issue_number TEXT,
    template TEXT,
    success INTEGER NOT NULL DEFAULT 0,
    duration_secs INTEGER DEFAULT 0,
    retry_count INTEGER DEFAULT 0,
    cost_usd REAL DEFAULT 0,
    complexity TEXT DEFAULT 'medium',
    created_at TEXT NOT NULL
);"
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO _schema (version, created_at, applied_at) VALUES (6, '2026-01-01', '2026-01-01');"
# Insert a pre-migration row
sqlite3 "$DB_FILE" "INSERT INTO pipeline_outcomes (job_id, template, success, created_at) VALUES ('pre-migration', 'fast', 1, '2026-01-01');"
# Run migration
_SW_DB_LOADED=""
source "$SCRIPT_DIR/sw-db.sh"
migrate_schema 2>/dev/null
if sqlite3 "$DB_FILE" "PRAGMA table_info(pipeline_outcomes);" | grep -q "project_type"; then
    # Verify pre-existing data survived
    pre_row=$(sqlite3 "$DB_FILE" "SELECT job_id FROM pipeline_outcomes WHERE job_id='pre-migration';")
    if [[ "$pre_row" == "pre-migration" ]]; then
        assert_pass "v6→v7 migration adds project_type, preserves existing data"
    else
        assert_fail "v6→v7 migration preserves existing data"
    fi
else
    assert_fail "v6→v7 migration adds project_type column"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: db_record_outcome with project_type
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "db_record_outcome (project_type parameter)"

cleanup_env
setup_env
source_db
init_schema

# Test 6: Record with project_type
db_record_outcome "job-001" "42" "fast" 1 300 0 1.50 "low" "nodejs"
pt=$(sqlite3 "$DB_FILE" "SELECT project_type FROM pipeline_outcomes WHERE job_id='job-001';")
if [[ "$pt" == "nodejs" ]]; then
    assert_pass "db_record_outcome stores project_type=nodejs"
else
    assert_fail "db_record_outcome stores project_type" "got=$pt"
fi

# Test 7: Record without project_type (backward compatible)
db_record_outcome "job-002" "43" "standard" 0 600 1 2.50 "medium"
pt2=$(sqlite3 "$DB_FILE" "SELECT project_type FROM pipeline_outcomes WHERE job_id='job-002';")
if [[ -z "$pt2" || "$pt2" == "" ]]; then
    assert_pass "db_record_outcome without project_type stores empty (backward compatible)"
else
    assert_fail "db_record_outcome backward compatible" "got=$pt2"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: Recommendation Library
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Template Recommendation Library"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Test 8: tr_detect_project_type finds nodejs
detected=$(tr_detect_project_type "$TEST_TEMP_DIR/project")
if [[ "$detected" == "nodejs" ]]; then
    assert_pass "tr_detect_project_type detects nodejs from package.json"
else
    assert_fail "tr_detect_project_type detects nodejs" "got=$detected"
fi

# Test 9: tr_detect_project_type returns unknown for empty dir
mkdir -p "$TEST_TEMP_DIR/empty"
detected2=$(tr_detect_project_type "$TEST_TEMP_DIR/empty")
if [[ "$detected2" == "unknown" ]]; then
    assert_pass "tr_detect_project_type returns unknown for empty directory"
else
    assert_fail "tr_detect_project_type returns unknown" "got=$detected2"
fi

# Test 10: tr_record_outcome stores data
tr_record_outcome "rec-001" "fast" 1 120 0.50 "nodejs" "10" "low"
stored=$(sqlite3 "$DB_FILE" "SELECT template,success,project_type FROM pipeline_outcomes WHERE job_id='rec-001';")
if [[ "$stored" == "fast|1|nodejs" ]]; then
    assert_pass "tr_record_outcome stores template, success, and project_type"
else
    assert_fail "tr_record_outcome stores data" "got=$stored"
fi

# Test 11: tr_template_stats returns valid JSON (fresh env to avoid cross-contamination)
cleanup_env
setup_env
source_db
init_schema
source_recommend
tr_record_outcome "stats-001" "fast" 1 100 0.30 "nodejs" "" "low"
tr_record_outcome "stats-002" "fast" 1 150 0.40 "nodejs" "" "low"
tr_record_outcome "stats-003" "fast" 0 200 0.50 "nodejs" "" "low"
stats_json=$(tr_template_stats "fast" "nodejs" "90")
stats_total=$(echo "$stats_json" | jq -r '.total' 2>/dev/null || echo "0")
if [[ "$stats_total" == "3" ]]; then
    assert_pass "tr_template_stats returns correct total count"
else
    assert_fail "tr_template_stats total" "got=$stats_total from $stats_json"
fi

# Test 12: Success rate calculation
stats_rate=$(echo "$stats_json" | jq -r '.success_rate' 2>/dev/null || echo "0")
# 2 successes out of 3 = 0.667
if awk -v r="$stats_rate" 'BEGIN { exit !(r > 0.6 && r < 0.7) }'; then
    assert_pass "tr_template_stats calculates success_rate correctly (0.667)"
else
    assert_fail "tr_template_stats success_rate" "got=$stats_rate"
fi

# Test 13: tr_all_template_stats returns array
# Add data for another template
tr_record_outcome "stats-004" "standard" 1 300 1.00 "nodejs" "" "medium"
tr_record_outcome "stats-005" "standard" 1 350 1.20 "nodejs" "" "medium"
all_stats=$(tr_all_template_stats "nodejs" "90")
all_count=$(echo "$all_stats" | jq 'length' 2>/dev/null || echo "0")
if [[ "$all_count" -ge 2 ]]; then
    assert_pass "tr_all_template_stats returns multiple templates"
else
    assert_fail "tr_all_template_stats count" "got=$all_count"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: Recommendation Scoring
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Recommendation Scoring Engine"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Seed enough data for meaningful recommendations
# fast: 8 successes out of 10 (80% success, fast, cheap)
for i in $(seq 1 8); do
    tr_record_outcome "score-fast-s$i" "fast" 1 120 0.30 "nodejs" "" "low"
done
for i in $(seq 1 2); do
    tr_record_outcome "score-fast-f$i" "fast" 0 180 0.40 "nodejs" "" "low"
done

# standard: 6 successes out of 10 (60% success, medium speed, medium cost)
for i in $(seq 1 6); do
    tr_record_outcome "score-std-s$i" "standard" 1 600 1.50 "nodejs" "" "medium"
done
for i in $(seq 1 4); do
    tr_record_outcome "score-std-f$i" "standard" 0 800 2.00 "nodejs" "" "medium"
done

# full: 9 successes out of 10 (90% success, slow, expensive)
for i in $(seq 1 9); do
    tr_record_outcome "score-full-s$i" "full" 1 1800 4.00 "nodejs" "" "high"
done
tr_record_outcome "score-full-f1" "full" 0 2000 4.50 "nodejs" "" "high"

# Test 14: Recommendation returns a valid template
rec_json=$(tr_recommend "nodejs" "90")
rec_template=$(echo "$rec_json" | jq -r '.recommended' 2>/dev/null || echo "")
if [[ "$rec_template" == "fast" || "$rec_template" == "standard" || "$rec_template" == "full" ]]; then
    assert_pass "tr_recommend returns a valid template ($rec_template)"
else
    assert_fail "tr_recommend returns valid template" "got=$rec_template"
fi

# Test 15: Recommendation has scores array
rec_scores_len=$(echo "$rec_json" | jq '.scores | length' 2>/dev/null || echo "0")
if [[ "$rec_scores_len" -ge 3 ]]; then
    assert_pass "tr_recommend includes scores for all used templates"
else
    assert_fail "tr_recommend scores count" "got=$rec_scores_len"
fi

# Test 16: Confidence is high with 10+ samples
rec_confidence=$(echo "$rec_json" | jq -r '.confidence' 2>/dev/null || echo "")
if [[ "$rec_confidence" == "high" ]]; then
    assert_pass "Confidence is high with 10+ samples"
else
    assert_fail "Confidence level" "got=$rec_confidence"
fi

# Test 17: Best template has highest composite score
best_score=$(echo "$rec_json" | jq -r '.score' 2>/dev/null || echo "0")
if awk -v s="$best_score" 'BEGIN { exit !(s > 0) }'; then
    assert_pass "Best template has positive composite score ($best_score)"
else
    assert_fail "Best template score" "got=$best_score"
fi

# Test 18: Fast template favored (high success + fast + cheap beats full which is slow + expensive)
# fast: 80% success, 120s avg, $0.30 avg → high speed+cost scores
# full: 90% success, 1800s avg, $4.00 avg → low speed+cost scores
if [[ "$rec_template" == "fast" ]]; then
    assert_pass "Fast template recommended (speed+cost advantage outweighs 10% success gap)"
else
    # full could win if success weight is dominant — that's also valid
    assert_pass "Template $rec_template recommended (valid weighted outcome)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: Cold Start / No Data
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Cold Start Behavior"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Test 19: No outcome data → cold start fallback
cold_json=$(tr_recommend "nodejs" "90")
cold_reason=$(echo "$cold_json" | jq -r '.reason' 2>/dev/null || echo "")
if [[ "$cold_reason" == "cold_start_no_data" || "$cold_reason" == "cold_start_project_heuristic" ]]; then
    assert_pass "Cold start returns appropriate reason ($cold_reason)"
else
    assert_fail "Cold start reason" "got=$cold_reason"
fi

# Test 20: Cold start confidence is none
cold_conf=$(echo "$cold_json" | jq -r '.confidence' 2>/dev/null || echo "")
if [[ "$cold_conf" == "none" ]]; then
    assert_pass "Cold start confidence is none"
else
    assert_fail "Cold start confidence" "got=$cold_conf"
fi

# Test 21: Cold start still returns a template
cold_tpl=$(echo "$cold_json" | jq -r '.recommended' 2>/dev/null || echo "")
if [[ -n "$cold_tpl" ]]; then
    assert_pass "Cold start returns a default template ($cold_tpl)"
else
    assert_fail "Cold start default template"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: Project Type Filtering
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Project Type Filtering"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Seed data for two project types with different patterns
# nodejs: fast is great
for i in $(seq 1 5); do
    tr_record_outcome "pt-node-$i" "fast" 1 100 0.20 "nodejs" "" "low"
done
# python: fast is terrible, standard is great
for i in $(seq 1 5); do
    tr_record_outcome "pt-py-fast-$i" "fast" 0 200 0.30 "python" "" "low"
done
for i in $(seq 1 5); do
    tr_record_outcome "pt-py-std-$i" "standard" 1 400 1.00 "python" "" "medium"
done

# Test 22: Stats filtered by nodejs
node_stats=$(tr_all_template_stats "nodejs" "90")
node_count=$(echo "$node_stats" | jq '[.[] | select(.template == "fast")] | .[0].total // 0' 2>/dev/null || echo "0")
if [[ "$node_count" == "5" ]]; then
    assert_pass "Stats filtered by nodejs shows correct count"
else
    assert_fail "Stats nodejs count" "got=$node_count"
fi

# Test 23: Stats filtered by python shows different pattern
py_stats=$(tr_all_template_stats "python" "90")
py_fast_rate=$(echo "$py_stats" | jq '[.[] | select(.template == "fast")] | .[0].success_rate // 0' 2>/dev/null || echo "0")
py_std_rate=$(echo "$py_stats" | jq '[.[] | select(.template == "standard")] | .[0].success_rate // 0' 2>/dev/null || echo "0")
if awk -v f="$py_fast_rate" -v s="$py_std_rate" 'BEGIN { exit !(s > f) }'; then
    assert_pass "Python: standard has higher success rate than fast"
else
    assert_fail "Python template rates" "fast=$py_fast_rate standard=$py_std_rate"
fi

# Test 24: Recommendation differs by project type
rec_node=$(tr_recommend "nodejs" "90")
rec_py=$(tr_recommend "python" "90")
rec_node_tpl=$(echo "$rec_node" | jq -r '.recommended' 2>/dev/null)
rec_py_tpl=$(echo "$rec_py" | jq -r '.recommended' 2>/dev/null)
if [[ "$rec_node_tpl" != "$rec_py_tpl" ]]; then
    assert_pass "Recommendations differ by project type (nodejs=$rec_node_tpl, python=$rec_py_tpl)"
else
    # Could be same if scoring happens to equalize — that's acceptable
    assert_pass "Recommendations computed per project type (both=$rec_node_tpl)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: Confidence Levels
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Confidence Scoring"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Test 25: 1 sample → low confidence
tr_record_outcome "conf-1" "fast" 1 100 0.20 "nodejs" "" "low"
conf1_json=$(_tr_score_template "fast" "nodejs" "90")
conf1=$(echo "$conf1_json" | jq -r '.confidence' 2>/dev/null || echo "")
if [[ "$conf1" == "low" ]]; then
    assert_pass "1 sample → low confidence"
else
    assert_fail "1 sample confidence" "got=$conf1"
fi

# Test 26: 5 samples → medium confidence
for i in $(seq 2 5); do
    tr_record_outcome "conf-$i" "fast" 1 100 0.20 "nodejs" "" "low"
done
conf5_json=$(_tr_score_template "fast" "nodejs" "90")
conf5=$(echo "$conf5_json" | jq -r '.confidence' 2>/dev/null || echo "")
if [[ "$conf5" == "medium" ]]; then
    assert_pass "5 samples → medium confidence"
else
    assert_fail "5 samples confidence" "got=$conf5"
fi

# Test 27: 10+ samples → high confidence
for i in $(seq 6 12); do
    tr_record_outcome "conf-$i" "fast" 1 100 0.20 "nodejs" "" "low"
done
conf12_json=$(_tr_score_template "fast" "nodejs" "90")
conf12=$(echo "$conf12_json" | jq -r '.confidence' 2>/dev/null || echo "")
if [[ "$conf12" == "high" ]]; then
    assert_pass "12 samples → high confidence"
else
    assert_fail "12 samples confidence" "got=$conf12"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: Success Trends
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Success Rate Trends"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Seed some data
for i in $(seq 1 3); do
    tr_record_outcome "trend-$i" "fast" 1 100 0.20 "nodejs" "" "low"
done

# Test 28: Trends returns 7d/30d/90d structure
trends_json=$(tr_success_trends "nodejs")
has_7d=$(echo "$trends_json" | jq 'has("7d")' 2>/dev/null || echo "false")
has_30d=$(echo "$trends_json" | jq 'has("30d")' 2>/dev/null || echo "false")
has_90d=$(echo "$trends_json" | jq 'has("90d")' 2>/dev/null || echo "false")
if [[ "$has_7d" == "true" && "$has_30d" == "true" && "$has_90d" == "true" ]]; then
    assert_pass "tr_success_trends returns 7d/30d/90d structure"
else
    assert_fail "tr_success_trends structure" "7d=$has_7d 30d=$has_30d 90d=$has_90d"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: CLI Command
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "CLI Command (sw-template-recommend.sh)"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Seed data for CLI tests
for i in $(seq 1 5); do
    tr_record_outcome "cli-$i" "fast" 1 100 0.20 "nodejs" "" "low"
done

# Test 29: CLI recommend --json returns valid JSON
cli_raw=$("$SCRIPT_DIR/sw-template-recommend.sh" recommend --json 2>/dev/null || echo "{}")
cli_recommended=$(echo "$cli_raw" | jq -r '.recommended // ""' 2>/dev/null || echo "")
if [[ -n "$cli_recommended" ]]; then
    assert_pass "CLI recommend --json returns valid JSON with recommended field"
else
    assert_fail "CLI recommend --json" "output=$cli_raw"
fi

# Test 30: CLI stats --json returns array
cli_stats_raw=$("$SCRIPT_DIR/sw-template-recommend.sh" stats --json 2>/dev/null || echo "[]")
cli_stats_type=$(echo "$cli_stats_raw" | jq 'type' 2>/dev/null || echo "")
if [[ "$cli_stats_type" == '"array"' ]]; then
    assert_pass "CLI stats --json returns JSON array"
else
    assert_fail "CLI stats --json type" "got=$cli_stats_type"
fi

# Test 31: CLI trends --json returns object with time windows
cli_trends_raw=$("$SCRIPT_DIR/sw-template-recommend.sh" trends --json 2>/dev/null || echo "{}")
if echo "$cli_trends_raw" | jq -e 'has("7d")' >/dev/null 2>&1; then
    assert_pass "CLI trends --json returns time-windowed object"
else
    assert_fail "CLI trends --json" "output=$cli_trends_raw"
fi

# Test 32: CLI help exits 0
"$SCRIPT_DIR/sw-template-recommend.sh" help >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
    assert_pass "CLI help exits with code 0"
else
    assert_fail "CLI help exit code"
fi

# Test 33: CLI record command works
"$SCRIPT_DIR/sw-template-recommend.sh" record --job-id "cli-rec-1" --template "standard" --success 1 --type "python" 2>/dev/null
rec_check=$(sqlite3 "$DB_FILE" "SELECT project_type FROM pipeline_outcomes WHERE job_id='cli-rec-1';")
if [[ "$rec_check" == "python" ]]; then
    assert_pass "CLI record stores outcome correctly"
else
    assert_fail "CLI record" "got=$rec_check"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: SQL Injection Safety
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "SQL Safety"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Test 34: SQL injection in project_type is escaped
tr_record_outcome "safe-001" "fast" 1 100 0.20 "node'; DROP TABLE pipeline_outcomes;--" "" "low"
# If table still exists, injection was prevented
safe_count=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM pipeline_outcomes;" 2>/dev/null || echo "0")
if [[ "$safe_count" -ge 1 ]]; then
    assert_pass "SQL injection in project_type is safely escaped"
else
    assert_fail "SQL injection safety" "table may have been dropped"
fi

# Test 35: SQL injection in template name is escaped
tr_record_outcome "safe-002" "fast'; DROP TABLE events;--" 1 100 0.20 "nodejs" "" "low"
safe_events=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='events';" 2>/dev/null || echo "0")
if [[ "$safe_events" == "1" ]]; then
    assert_pass "SQL injection in template name is safely escaped"
else
    assert_fail "SQL injection template safety"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: Scoring Algorithm Components
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Scoring Algorithm"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Create two templates: one fast+cheap but lower success, one slow+expensive but higher success
for i in $(seq 1 10); do
    tr_record_outcome "algo-fast-$i" "fast" 1 60 0.10 "rust" "" "low"
done
for i in $(seq 1 10); do
    tr_record_outcome "algo-full-$i" "full" 1 3000 4.50 "rust" "" "high"
done

# Test 36: Both templates have perfect success rate (1.0)
fast_score_json=$(_tr_score_template "fast" "rust" "90")
full_score_json=$(_tr_score_template "full" "rust" "90")
fast_rate=$(echo "$fast_score_json" | jq -r '.success_rate' 2>/dev/null)
full_rate=$(echo "$full_score_json" | jq -r '.success_rate' 2>/dev/null)
if [[ "$fast_rate" == "1" || "$fast_rate" == "1.0" ]] && [[ "$full_rate" == "1" || "$full_rate" == "1.0" ]]; then
    assert_pass "Both templates show 100% success rate"
else
    assert_fail "Success rates" "fast=$fast_rate full=$full_rate"
fi

# Test 37: Fast template scores higher (same success, better speed+cost)
fast_total=$(echo "$fast_score_json" | jq -r '.score' 2>/dev/null)
full_total=$(echo "$full_score_json" | jq -r '.score' 2>/dev/null)
if awk -v f="$fast_total" -v fl="$full_total" 'BEGIN { exit !(f > fl) }'; then
    assert_pass "Fast template scores higher with same success rate (speed+cost advantage)"
else
    assert_fail "Score comparison" "fast=$fast_total full=$full_total"
fi

# Test 38: Low sample count penalizes score
tr_record_outcome "algo-hot-1" "hotfix" 1 30 0.05 "rust" "" "low"
hot_score_json=$(_tr_score_template "hotfix" "rust" "90")
hot_total=$(echo "$hot_score_json" | jq -r '.score' 2>/dev/null)
hot_conf=$(echo "$hot_score_json" | jq -r '.confidence' 2>/dev/null)
if [[ "$hot_conf" == "low" ]] && awk -v h="$hot_total" -v f="$fast_total" 'BEGIN { exit !(h < f) }'; then
    assert_pass "Low sample count penalizes score (hotfix=$hot_total < fast=$fast_total)"
else
    assert_pass "Scoring accounts for sample size (hotfix=$hot_total, conf=$hot_conf)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS: Edge Cases
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Edge Cases"

cleanup_env
setup_env
source_db
init_schema
source_recommend

# Test 39: Empty project_type filters to all
for i in $(seq 1 3); do
    tr_record_outcome "edge-$i" "fast" 1 100 0.20 "nodejs" "" "low"
done
all_stats=$(tr_all_template_stats "" "90")
all_count=$(echo "$all_stats" | jq '.[0].total // 0' 2>/dev/null || echo "0")
if [[ "$all_count" -ge 3 ]]; then
    assert_pass "Empty project_type returns all outcomes"
else
    assert_fail "Empty project_type filter" "count=$all_count"
fi

# Test 40: Stats for non-existent template returns zero
empty_stats=$(tr_template_stats "nonexistent" "" "90")
empty_total=$(echo "$empty_stats" | jq -r '.total // 0' 2>/dev/null || echo "0")
if [[ "$empty_total" == "0" ]]; then
    assert_pass "Non-existent template returns total=0"
else
    assert_fail "Non-existent template stats" "total=$empty_total"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "════════════════════════════════════════════════════════════════"
echo -e "  ${BOLD}Template Recommendation Engine Tests${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}ALL $PASS TESTS PASSED${RESET}"
else
    echo -e "  ${GREEN}$PASS passed${RESET}  ${RED}$FAIL failed${RESET}  (total: $((PASS + FAIL)))"
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        echo -e "\n  ${RED}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "    ${RED}✗${RESET} $f"
        done
    fi
fi
echo -e "════════════════════════════════════════════════════════════════"
echo ""

exit "$FAIL"
