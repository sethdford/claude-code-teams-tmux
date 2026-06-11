#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-template-recommender-test.sh — Smart Template Recommendation Tests    ║
# ║                                                                           ║
# ║  Validates the deterministic scoring core, feedback loop, and CLI with    ║
# ║  synthetic issues. Bandit selector is intentionally NOT sourced so the    ║
# ║  scoring is deterministic across runs.                                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Setup / Teardown ─────────────────────────────────────────────────────────
TEST_TMPDIR=""
setup() {
    TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/tr-test.XXXXXX")
    export TR_FEEDBACK_LOG="$TEST_TMPDIR/template-recommendations.jsonl"
    export NO_GITHUB=true
}
teardown() { [[ -n "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"; }
trap teardown EXIT

# ─── Source the library (without bandit → deterministic) ──────────────────────
# shellcheck source=lib/template-recommender.sh
source "$SCRIPT_DIR/lib/template-recommender.sh"

# ─── Test Helpers ─────────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"; echo "    Actual:   $actual"
    fi
}
assert_not_empty() {
    local actual="$1" description="${2:-}"
    if [[ -n "$actual" ]]; then PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"; echo "    Value was empty"; fi
}
assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"; echo "    '$needle' not in: $haystack"; fi
}

# Build a synthetic issue JSON.
mk_issue() {
    local title="$1" body="$2" labels="$3"
    local labels_json
    labels_json=$(echo "$labels" | jq -R 'split(",") | map(select(length > 0))')
    jq -n --arg t "$title" --arg b "$body" --argjson l "$labels_json" \
        '{title: $t, body: $b, labels: $l}'
}

rec_template() { recommend_template "$1" "{}" | jq -r '.template'; }

setup

echo "── Scoring: label-driven selection ──"
assert_equals "fast" "$(rec_template "$(mk_issue 'Fix typo' 'typo in README' 'docs')")" \
    "docs/typo issue → fast"
assert_equals "standard" "$(rec_template "$(mk_issue 'Fix crash' 'null pointer when parsing input' 'bug')")" \
    "bug issue → standard"
assert_equals "hotfix" "$(rec_template "$(mk_issue 'Outage' 'production down, urgent fix' 'hotfix')")" \
    "hotfix label → hotfix"
assert_equals "enterprise" "$(rec_template "$(mk_issue 'Auth vuln' 'fix authentication token leak' 'security')")" \
    "security issue → enterprise"

echo "── Scoring: keyword + complexity ──"
TR_FULL=$(rec_template "$(mk_issue 'Big refactor' 'refactor the architecture with breaking migration changes across multiple modules' 'enhancement')")
assert_contains "full standard enterprise" "$TR_FULL" "refactor/architecture → non-trivial template ($TR_FULL)"

echo "── Output contract ──"
REC=$(recommend_template "$(mk_issue 'Fix crash' 'bug' 'bug')" "{}")
assert_equals "object" "$(echo "$REC" | jq -r 'type')" "recommendation is a JSON object"
CONF=$(echo "$REC" | jq -r '.confidence')
assert_equals "1" "$(awk -v c="$CONF" 'BEGIN { print (c>=0 && c<=100) ? 1 : 0 }')" "confidence in [0,100] ($CONF)"
assert_equals "number" "$(echo "$REC" | jq -r '.confidence | type')" "confidence is a number"
assert_equals "5" "$(echo "$REC" | jq -r '.scores | keys | length')" "scores has all 5 templates"
assert_equals "array" "$(echo "$REC" | jq -r '.reasoning | type')" "reasoning is an array"
assert_equals "true" "$(echo "$REC" | jq -r ".reasoning | length > 0")" "reasoning is non-empty"

echo "── Edge cases ──"
EMPTY=$(recommend_template '{"title":"","body":"","labels":[]}' "{}")
assert_equals "standard" "$(echo "$EMPTY" | jq -r '.template')" "empty issue → standard default"
assert_equals "object" "$(recommend_template '{}' '{}' | jq -r 'type')" "missing fields → still valid object"
# Object-form labels (GitHub shape: [{name: ...}])
OBJL=$(recommend_template '{"title":"x","body":"y","labels":[{"name":"docs"}]}' "{}")
assert_equals "fast" "$(echo "$OBJL" | jq -r '.template')" "object-form labels parsed (docs → fast)"

echo "── tr_repo_context ──"
CTX=$(tr_repo_context "$SCRIPT_DIR/..")
assert_equals "object" "$(echo "$CTX" | jq -r 'type')" "repo context is valid JSON object"
assert_equals "true" "$(echo "$CTX" | jq -r ".file_count > 0")" "repo context reports file_count"
NONREPO=$(tr_repo_context "$TEST_TMPDIR")
assert_equals "object" "$(echo "$NONREPO" | jq -r 'type')" "non-repo dir → valid JSON ({} or context)"

echo "── Feedback loop ──"
tr_record_recommendation "624" "enterprise" "75" "true"
assert_equals "1" "$(grep -c . "$TR_FEEDBACK_LOG")" "recommendation appended to log"
tr_record_outcome "624" "enterprise" "success"
assert_equals "2" "$(grep -c . "$TR_FEEDBACK_LOG")" "outcome appended to log"
ACC=$(tr_accuracy)
assert_equals "1" "$(echo "$ACC" | jq -r '.total')" "accuracy counts 1 evaluated pair"
assert_equals "1" "$(echo "$ACC" | jq -r '.matched')" "accuracy counts 1 match"
assert_equals "100" "$(echo "$ACC" | jq -r '.accuracy')" "accuracy is 100% on a match"

# Mismatch lowers accuracy.
tr_record_recommendation "625" "fast" "60" "true"
tr_record_outcome "625" "full" "success"
ACC2=$(tr_accuracy)
assert_equals "2" "$(echo "$ACC2" | jq -r '.total')" "accuracy counts 2 pairs"
assert_equals "1" "$(echo "$ACC2" | jq -r '.matched')" "accuracy counts 1 match of 2"
assert_equals "50" "$(echo "$ACC2" | jq -r '.accuracy')" "accuracy is 50% with one mismatch"

ACC_EMPTY=$(TR_FEEDBACK_LOG="$TEST_TMPDIR/none.jsonl" tr_accuracy)
assert_equals "0" "$(echo "$ACC_EMPTY" | jq -r '.total')" "no log → zero accuracy, no crash"

echo "── CLI integration ──"
CLI="$SCRIPT_DIR/sw-template-recommender.sh"
assert_not_empty "$(bash "$CLI" --version)" "CLI --version prints"
assert_contains "$(bash "$CLI" --help)" "recommend" "CLI --help lists commands"
assert_contains "$(bash "$CLI" help)" "feedback" "CLI help (no dashes) works"
JSON_OUT=$(bash "$CLI" recommend --goal "fix typo" --labels docs --json)
assert_equals "fast" "$(echo "$JSON_OUT" | jq -r '.template')" "CLI recommend --json → fast for docs"
EXPL=$(bash "$CLI" explain --goal "refactor architecture" --labels enhancement)
assert_contains "$EXPL" "Score breakdown" "CLI explain shows score breakdown"

# CLI feedback + accuracy round-trip in an isolated log.
ISO_LOG="$TEST_TMPDIR/iso.jsonl"
TR_FEEDBACK_LOG="$ISO_LOG" bash "$CLI" recommend --issue 700 --goal "fix typo" --labels docs --json >/dev/null
TR_FEEDBACK_LOG="$ISO_LOG" bash "$CLI" feedback --issue 700 --template fast --outcome success >/dev/null
ISO_ACC=$(TR_FEEDBACK_LOG="$ISO_LOG" bash "$CLI" accuracy --json)
assert_equals "100" "$(echo "$ISO_ACC" | jq -r '.accuracy')" "CLI feedback loop round-trips to 100% accuracy"

echo "── CLI error handling ──"
set +e
bash "$CLI" bogus-command >/dev/null 2>&1; assert_equals "1" "$?" "unknown command exits 1"
bash "$CLI" recommend >/dev/null 2>&1; assert_equals "1" "$?" "recommend with no input exits 1"
bash "$CLI" feedback --issue 1 >/dev/null 2>&1; assert_equals "1" "$?" "feedback missing args exits 1"
bash "$CLI" feedback --issue 1 --template fast --outcome bogus >/dev/null 2>&1; assert_equals "1" "$?" "invalid outcome exits 1"
set -e

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
echo "─────────────────────────────────────────"
echo -e "  Passed: \033[38;2;74;222;128m$PASS\033[0m   Failed: \033[38;2;248;113;113m$FAIL\033[0m"
echo "─────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
