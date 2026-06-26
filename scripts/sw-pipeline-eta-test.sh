#!/usr/bin/env bash
# sw-pipeline-eta-test.sh — Test Suite for Pipeline Progress / ETA Estimation
# Covers percentile math, IQR outlier filtering, stage-count fallback,
# P50/P90 ETA computation, 24h cache, human formatting, query_stage_durations,
# and bash/TypeScript formula parity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-eta-test.XXXXXX")
trap "rm -rf '$TEST_DIR'" EXIT

export HOME="$TEST_DIR"
export ETA_CACHE_FILE="$TEST_DIR/intelligence-cache.json"

PASS=0
FAIL=0

info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
emit_event() { :; }  # mock — keep ETA estimate side-effect-free in tests

if ! command -v jq >/dev/null 2>&1; then
    error "jq is required but not installed"
    exit 1
fi

# Deterministic clock for cache tests
_FAKE_NOW=1000000000
now_epoch() { echo "$_FAKE_NOW"; }

# Source the module under test
# shellcheck source=lib/pipeline-eta.sh
source "$SCRIPT_DIR/lib/pipeline-eta.sh"

assert_equals() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        success "$msg"; PASS=$((PASS + 1))
    else
        error "$msg (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        success "$msg"; PASS=$((PASS + 1))
    else
        error "$msg (expected to contain '$needle', got '$haystack')"; FAIL=$((FAIL + 1))
    fi
}

# ─── eta_percentile ─────────────────────────────────────────────────────────
info "Testing eta_percentile"
# Matches scripts/sw-adaptive.sh::percentile — averages the neighbouring pair at
# the floored index, so P50 of [10,20,30,40,50] = avg(sorted[2],sorted[3]) = 35.
assert_equals "35" "$(eta_percentile '[10,20,30,40,50]' 50)" "P50 of [10,20,30,40,50] is 35"
assert_equals "45" "$(eta_percentile '[10,20,30,40,50]' 90)" "P90 of [10,20,30,40,50] is 45"
assert_equals "null" "$(eta_percentile '[]' 50)" "P50 of empty array is null"
# P90 >= P50 invariant
p50=$(eta_percentile '[5,10,15,20,100]' 50)
p90=$(eta_percentile '[5,10,15,20,100]' 90)
if awk -v a="$p90" -v b="$p50" 'BEGIN{exit !(a>=b)}'; then
    success "P90 ($p90) >= P50 ($p50)"; PASS=$((PASS + 1))
else
    error "P90 ($p90) should be >= P50 ($p50)"; FAIL=$((FAIL + 1))
fi

# ─── eta_filter_outliers ────────────────────────────────────────────────────
info "Testing eta_filter_outliers"
# An extreme outlier (10000) should be dropped from a tight cluster
filtered=$(eta_filter_outliers '[100,110,105,108,102,10000]')
assert_contains "$filtered" "100" "IQR filter keeps in-range value 100"
if echo "$filtered" | jq -e 'any(. == 10000)' >/dev/null 2>&1; then
    error "IQR filter should drop outlier 10000"; FAIL=$((FAIL + 1))
else
    success "IQR filter drops outlier 10000"; PASS=$((PASS + 1))
fi
# Arrays smaller than 4 pass through unchanged
small=$(eta_filter_outliers '[1,9999]')
assert_equals "2" "$(echo "$small" | jq 'length')" "Arrays < 4 elements pass through unchanged"

# ─── pipeline_eta_estimate: stage-count fallback (no history) ────────────────
info "Testing pipeline_eta_estimate — no-history fallback"
est=$(pipeline_eta_estimate "intake,build,test,pr" "intake" 60 "{}")
assert_equals "25" "$(echo "$est" | jq -r '.progress_pct')" "1/4 complete = 25%"
assert_equals "stage_count" "$(echo "$est" | jq -r '.basis')" "No history → basis=stage_count"
assert_equals "null" "$(echo "$est" | jq -r '.eta_seconds')" "No history → eta is null"
assert_equals "none" "$(echo "$est" | jq -r '.confidence')" "No history → confidence=none"

# ─── pipeline_eta_estimate: with history (P50) ───────────────────────────────
info "Testing pipeline_eta_estimate — with historical durations"
DMAP='{"intake":[10,12,11,10,13],"build":[100,120,110,105,115],"test":[40,50,45,48,42],"pr":[20,22,18,19,21]}'
est=$(pipeline_eta_estimate "intake,build,test,pr" "intake,build" 130 "$DMAP")
assert_equals "50" "$(echo "$est" | jq -r '.progress_pct')" "2/4 complete = 50%"
assert_equals "p50_history" "$(echo "$est" | jq -r '.basis')" "Sufficient history → basis=p50_history"
# Remaining = test + pr ; eta should be P50(test)+P50(pr) ≈ 45+20 = 65
eta=$(echo "$est" | jq -r '.eta_seconds')
if [[ "$eta" -ge 60 && "$eta" -le 70 ]]; then
    success "ETA for remaining test+pr is ~65s (got ${eta}s)"; PASS=$((PASS + 1))
else
    error "ETA expected ~65s, got ${eta}s"; FAIL=$((FAIL + 1))
fi
# P90 >= P50 for the aggregate estimate
eta90=$(echo "$est" | jq -r '.eta_p90_seconds')
if [[ "$eta90" -ge "$eta" ]]; then
    success "eta_p90 ($eta90) >= eta_p50 ($eta)"; PASS=$((PASS + 1))
else
    error "eta_p90 ($eta90) should be >= eta_p50 ($eta)"; FAIL=$((FAIL + 1))
fi

# ─── Mixed coverage: one remaining stage lacks history → fallback ────────────
info "Testing pipeline_eta_estimate — partial coverage degrades gracefully"
DMAP_PARTIAL='{"build":[100,120,110,105,115]}'
est=$(pipeline_eta_estimate "intake,build,test,pr" "intake" 60 "$DMAP_PARTIAL")
assert_equals "stage_count" "$(echo "$est" | jq -r '.basis')" "Missing history for a remaining stage → stage_count"

# ─── All complete ───────────────────────────────────────────────────────────
info "Testing pipeline_eta_estimate — all stages complete"
est=$(pipeline_eta_estimate "intake,build" "intake,build" 200 "{}")
assert_equals "100" "$(echo "$est" | jq -r '.progress_pct')" "All complete = 100%"
assert_equals "complete" "$(echo "$est" | jq -r '.basis')" "All complete → basis=complete"
assert_equals "0" "$(echo "$est" | jq -r '.eta_seconds')" "All complete → eta=0"

# ─── pipeline_eta_format ────────────────────────────────────────────────────
info "Testing pipeline_eta_format"
hist='{"progress_pct":42,"eta_seconds":1080,"eta_p90_seconds":1500,"confidence":"high","basis":"p50_history","total_stages":9,"completed_stages":4,"elapsed_seconds":600}'
assert_equals "Progress: 42% (~18 min remaining)" "$(pipeline_eta_format "$hist")" "Formats p50_history with minutes"
nohist='{"progress_pct":44,"eta_seconds":null,"eta_p90_seconds":null,"confidence":"none","basis":"stage_count","total_stages":9,"completed_stages":4,"elapsed_seconds":600}'
assert_equals "Progress: 4/9 stages" "$(pipeline_eta_format "$nohist")" "Formats stage_count fallback"
donejson='{"progress_pct":100,"eta_seconds":0,"eta_p90_seconds":0,"confidence":"high","basis":"complete","total_stages":9,"completed_stages":9,"elapsed_seconds":600}'
assert_equals "Progress: 100% (complete)" "$(pipeline_eta_format "$donejson")" "Formats complete"
secs='{"progress_pct":90,"eta_seconds":20,"eta_p90_seconds":30,"confidence":"low","basis":"p50_history","total_stages":9,"completed_stages":8,"elapsed_seconds":600}'
assert_contains "$(pipeline_eta_format "$secs")" "~20s remaining" "Sub-minute ETA shows seconds"

# ─── Cache store + read + TTL ───────────────────────────────────────────────
info "Testing 24h cache"
rm -f "$ETA_CACHE_FILE"
eta_cache_store "stage_durations" '{"build":[1,2,3]}' "$_FAKE_NOW"
cached=$(jq -c '.eta.stage_durations.durations' "$ETA_CACHE_FILE")
assert_equals '{"build":[1,2,3]}' "$cached" "Cache stores duration map under .eta key"
# Existing top-level keys must survive a store
echo '{"entries":{"x":1}}' > "$ETA_CACHE_FILE"
eta_cache_store "stage_durations" '{"test":[9]}' "$_FAKE_NOW"
assert_equals "1" "$(jq -r '.entries.x' "$ETA_CACHE_FILE")" "Cache store preserves existing .entries key"
# Fresh cache is read back by eta_duration_map (no DB needed)
dmap=$(eta_duration_map)
assert_equals '[9]' "$(echo "$dmap" | jq -c '.test')" "eta_duration_map reads fresh cache"
# Expired cache is ignored
echo "{\"eta\":{\"stage_durations\":{\"durations\":{\"old\":[1]},\"cached_at\":1}}}" > "$ETA_CACHE_FILE"
dmap=$(eta_duration_map)
if echo "$dmap" | jq -e '.old' >/dev/null 2>&1; then
    error "Expired cache should be ignored"; FAIL=$((FAIL + 1))
else
    success "Expired cache (>24h) is ignored"; PASS=$((PASS + 1))
fi

# ─── query_stage_durations (real sqlite3) ───────────────────────────────────
if command -v sqlite3 >/dev/null 2>&1; then
    info "Testing query_stage_durations against SQLite"
    export DB_DIR="$TEST_DIR/.shipwright"
    mkdir -p "$DB_DIR"
    export DB_FILE="$DB_DIR/shipwright.db"
    export SHIPWRIGHT_DB_ENABLED=1
    # shellcheck source=sw-db.sh
    source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null || true
    sqlite3 "$DB_FILE" "CREATE TABLE pipeline_stages (id INTEGER PRIMARY KEY, job_id TEXT, stage_name TEXT, status TEXT, started_at TEXT, completed_at TEXT, duration_secs INTEGER, error_message TEXT, metadata TEXT, created_at TEXT);"
    sqlite3 "$DB_FILE" "INSERT INTO pipeline_stages (job_id,stage_name,status,duration_secs,created_at) VALUES ('j1','build','complete',100,'t'),('j2','build','complete',120,'t'),('j3','build','failed',5,'t'),('j4','test','complete',40,'t'),('j5','build','complete',0,'t');"
    durs=$(query_stage_durations)
    assert_equals "[100,120]" "$(echo "$durs" | jq -c '.build')" "Only completed build durations >0 (excludes failed & zero)"
    assert_equals "[40]" "$(echo "$durs" | jq -c '.test')" "Test stage durations returned"
    # Stage filter
    durs1=$(query_stage_durations "build")
    assert_equals "[100,120]" "$(echo "$durs1" | jq -c '.build')" "Stage filter returns only that stage"
    assert_equals "null" "$(echo "$durs1" | jq -c '.test')" "Stage filter excludes other stages"
    # Input validation rejects injection
    if query_stage_durations "build'; DROP TABLE pipeline_stages; --" 2>/dev/null; then
        error "query_stage_durations should reject invalid stage names"; FAIL=$((FAIL + 1))
    else
        success "query_stage_durations rejects invalid/injection stage names"; PASS=$((PASS + 1))
    fi
else
    warn "sqlite3 not available — skipping query_stage_durations DB tests"
fi

# ─── Bash / TypeScript parity fixture ───────────────────────────────────────
# Mirror of the algorithm constants the dashboard server.ts must reproduce.
# If these numbers change, the TS mirror must be updated to match.
info "Testing bash/TS parity fixture"
PARITY_DMAP='{"intake":[10,12,11,10,13],"build":[100,120,110,105,115],"test":[40,50,45,48,42],"pr":[20,22,18,19,21]}'
parity=$(pipeline_eta_estimate "intake,build,test,pr" "intake,build" 130 "$PARITY_DMAP")
# Pure JSON output (the contract server.ts must reproduce for the same inputs).
echo "$parity" | jq -S . > "$TEST_DIR/parity-fixture.json"
assert_equals "50" "$(jq -r '.progress_pct' "$TEST_DIR/parity-fixture.json")" "Parity fixture progress_pct=50"
assert_equals "p50_history" "$(jq -r '.basis' "$TEST_DIR/parity-fixture.json")" "Parity fixture basis=p50_history"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo -e "Results: \033[38;2;74;222;128m${PASS} passed\033[0m, \033[38;2;248;113;113m${FAIL} failed\033[0m"
[[ "$FAIL" -eq 0 ]] || exit 1
