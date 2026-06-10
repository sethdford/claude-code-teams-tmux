#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  error-quality-analyzer test suite                                       ║
# ║  Tests batch scoring, event emission, correlation, offenders, templates  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: error-quality-analyzer Tests"

setup_test_env "sw-lib-error-quality-analyzer-test"
trap cleanup_test_env EXIT

# Source the library under test.
source "$SCRIPT_DIR/lib/error-quality-analyzer.sh"

# ─── Fixtures ───────────────────────────────────────────────────────────────
WORK="$TEST_TEMP_DIR"
mkdir -p "$WORK/.claude"

# A realistic error-summary.json: a high-actionability line and a vague one.
SUMMARY="$WORK/error-summary.json"
cat > "$SUMMARY" <<'EOF'
{
  "iteration": 3,
  "timestamp": "2026-06-10T14:00:00Z",
  "error_count": 3,
  "error_lines": [
    "scripts/foo.sh:42: SyntaxError: unexpected token near `fi`",
    "scripts/bar.sh:10: SyntaxError: invalid syntax found here",
    "Test failed"
  ],
  "test_cmd": "npm test"
}
EOF

# ─── AC1: eqa_score_summary_file ────────────────────────────────────────────
scored=$(eqa_score_summary_file "$SUMMARY")
assert_json_key "score: reads iteration" "$scored" ".iteration" "3"
assert_json_key "score: counts all error lines" "$scored" ".error_count" "3"

n_scored=$(echo "$scored" | jq '.scored_errors | length')
assert_eq "score: scored_errors length" "3" "$n_scored"

# The first line is highly actionable (file:line + type) → high score.
first_score=$(echo "$scored" | jq '.scored_errors[0].score')
assert_gt "score: actionable line scores high" "$first_score" "50"

# The vague last line scores lower than the actionable one.
vague_score=$(echo "$scored" | jq '.scored_errors[2].score')
assert_gt "score: actionable beats vague" "$first_score" "$vague_score"

# Classification is attached.
first_type=$(echo "$scored" | jq -r '.scored_errors[0].type')
assert_eq "score: classifies syntax" "syntax" "$first_type"

# Missing file → graceful failure, valid JSON.
missing=$(eqa_score_summary_file "$WORK/nope.json" || true)
assert_contains "score: missing file handled" "$missing" "scored_errors"

# ─── AC4: eqa_emit_iteration_quality ────────────────────────────────────────
EVENTS="$WORK/events.jsonl"
export EVENTS_FILE="$EVENTS"
# Provide a local emit_event that writes to our test events file.
emit_event() {
    local etype="$1"; shift
    local fields=""
    for kv in "$@"; do
        local k="${kv%%=*}" v="${kv#*=}"
        if [[ "$v" =~ ^-?[0-9]+$ ]]; then
            fields="${fields},\"${k}\":${v}"
        else
            fields="${fields},\"${k}\":\"${v}\""
        fi
    done
    echo "{\"type\":\"${etype}\"${fields}}" >> "$EVENTS_FILE"
}

eqa_emit_iteration_quality "$SUMMARY" "job-1"
emitted=$(grep '"error.quality"' "$EVENTS" || true)
assert_contains "emit: error.quality event written" "$emitted" "error.quality"
assert_contains "emit: carries iteration" "$emitted" "\"iteration\":3"
assert_contains "emit: carries top_type" "$emitted" "syntax"

# Empty summary → no event emitted (no spurious metrics).
cat > "$WORK/empty.json" <<'EOF'
{"iteration": 9, "timestamp": "t", "error_count": 0, "error_lines": [], "test_cmd": "x"}
EOF
before=$(wc -l < "$EVENTS")
eqa_emit_iteration_quality "$WORK/empty.json" "job-1"
after=$(wc -l < "$EVENTS")
assert_eq "emit: no event for empty summary" "$before" "$after"

# ─── AC2 + AC5: correlation and offenders ───────────────────────────────────
# Build a synthetic event stream: a low-scoring "type" error never gets fixed,
# a higher-scoring "syntax" error gets fixed the next iteration.
CORR="$WORK/corr.jsonl"
{
    i=0
    while [[ $i -lt 12 ]]; do
        echo "{\"type\":\"error.quality\",\"job_id\":\"j\",\"iteration\":$i,\"error_count\":1,\"avg_score\":20,\"top_type\":\"type\"}"
        echo "{\"type\":\"loop.iteration_complete\",\"job_id\":\"j\",\"iteration\":$((i+1)),\"test_passed\":\"false\"}"
        i=$((i + 1))
    done
    i=100
    while [[ $i -lt 112 ]]; do
        echo "{\"type\":\"error.quality\",\"job_id\":\"j\",\"iteration\":$i,\"error_count\":1,\"avg_score\":80,\"top_type\":\"syntax\"}"
        echo "{\"type\":\"loop.iteration_complete\",\"job_id\":\"j\",\"iteration\":$((i+1)),\"test_passed\":\"true\"}"
        i=$((i + 1))
    done
} > "$CORR"

correlated=$(eqa_correlate "$CORR" 10)
type_fix=$(echo "$correlated" | jq -r '.[] | select(.type=="type") | .fix_rate')
syntax_fix=$(echo "$correlated" | jq -r '.[] | select(.type=="syntax") | .fix_rate')
assert_eq "correlate: unfixed type has 0 fix_rate" "0" "$type_fix"
assert_eq "correlate: fixed syntax has 100 fix_rate" "100" "$syntax_fix"

# Sorted ascending by avg_score → lowest-actionability type is first.
first_type=$(echo "$correlated" | jq -r '.[0].type')
assert_eq "correlate: sorted ascending by score" "type" "$first_type"

# min_sample gate: with a high min, nothing qualifies.
gated=$(eqa_correlate "$CORR" 100)
assert_eq "correlate: min_sample gate" "0" "$(echo "$gated" | jq 'length')"

offenders=$(eqa_top_offenders "$CORR" 10 5)
off_count=$(echo "$offenders" | jq 'length')
assert_gt "offenders: returns at least one" "$off_count" "0"
worst=$(echo "$offenders" | jq -r '.[0].type')
assert_eq "offenders: worst is lowest-score type" "type" "$worst"

# ─── AC3: template generation ───────────────────────────────────────────────
export EQA_TEMPLATES_FILE="$WORK/.claude/error-templates.json"
out=$(eqa_generate_templates "$CORR" 10 5)
assert_eq "templates: writes to configured path" "$EQA_TEMPLATES_FILE" "$out"
assert_file_exists "templates: file created" "$EQA_TEMPLATES_FILE"

tmpl_for_type=$(jq -r '.templates[] | select(.type=="type") | .template' "$EQA_TEMPLATES_FILE")
assert_contains "templates: includes file:line guidance" "$tmpl_for_type" "<file>:<line>"
assert_contains "templates: names the error type" "$tmpl_for_type" "type error"

# ─── Report orchestrator ────────────────────────────────────────────────────
report=$(eqa_report "$CORR" 10 5)
assert_contains "report: header present" "$report" "Error Feedback Loop Quality Report"
assert_contains "report: lists offender type" "$report" "type"

# Report with no qualifying data is graceful.
empty_report=$(eqa_report "$WORK/none.jsonl" 10 5)
assert_contains "report: graceful with no data" "$empty_report" "minimum sample"

print_test_results
