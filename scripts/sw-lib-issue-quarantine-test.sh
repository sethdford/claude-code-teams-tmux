#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/issue-quarantine test — Unit tests for quarantine system  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: issue-quarantine Tests"

setup_test_env "sw-lib-issue-quarantine-test"
trap cleanup_test_env EXIT

# Source the lib (clear guard to re-source)
_SW_ISSUE_QUARANTINE_LOADED=""
source "$SCRIPT_DIR/lib/issue-quarantine.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_label: Returns the E2E test label
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_label"

label=$(quarantine_label)
assert_eq "quarantine_label returns default 'sw:e2e-test'" "sw:e2e-test" "$label"

# Test with SHIPWRIGHT_LABELS_E2E_TEST env var
export SHIPWRIGHT_LABELS_E2E_TEST="custom:label"
label=$(quarantine_label)
assert_eq "quarantine_label respects SHIPWRIGHT_LABELS_E2E_TEST env var" "custom:label" "$label"
unset SHIPWRIGHT_LABELS_E2E_TEST

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_labels: Returns all quarantine labels (including legacy)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_labels"

labels=$(quarantine_labels)
if echo "$labels" | grep -q "sw:e2e-test"; then
    assert_pass "quarantine_labels includes 'sw:e2e-test'"
else
    assert_fail "quarantine_labels includes 'sw:e2e-test'" "got: $labels"
fi

if echo "$labels" | grep -q "e2e-test"; then
    assert_pass "quarantine_labels includes legacy 'e2e-test'"
else
    assert_fail "quarantine_labels includes legacy 'e2e-test'" "got: $labels"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_filter_json: Filters quarantined issues from JSON array
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_filter_json"

# Test case 1: Filter removes issue with quarantine label
input='[{"number":1,"title":"Real issue","labels":[{"name":"bug"}]},{"number":2,"title":"E2E test issue","labels":[{"name":"sw:e2e-test"}]}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter removes issue with 'sw:e2e-test' label" "1" "$count"

# Test case 2: Filter keeps issue without quarantine label
input='[{"number":1,"title":"Real issue","labels":[{"name":"bug"}]}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter keeps issue without quarantine label" "1" "$count"

# Test case 3: Filter with legacy e2e-test label
input='[{"number":1,"title":"Old E2E test","labels":[{"name":"e2e-test"}]}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter removes issue with legacy 'e2e-test' label" "0" "$count"

# Test case 4: Empty input
input=""
output=$(echo -n "$input" | quarantine_filter_json "test")
assert_eq "Filter handles empty input" "" "$output"

# Test case 5: Issue without labels field
input='[{"number":1,"title":"No labels field"}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter handles missing labels field" "1" "$count"

# Test case 6: Mixed quarantined and non-quarantined
input='[{"number":1,"title":"Real issue","labels":[{"name":"bug"}]},{"number":2,"title":"E2E test","labels":[{"name":"sw:e2e-test"}]},{"number":3,"title":"Another real issue","labels":[{"name":"feature"}]}]'
output=$(echo "$input" | quarantine_filter_json "test")
count=$(echo "$output" | jq 'length')
assert_eq "Filter keeps 2 real issues, removes 1 E2E issue" "2" "$count"

# Test case 7: Fail-open on malformed JSON
input='[invalid json'
output=$(echo "$input" | quarantine_filter_json "test" 2>/dev/null || true)
if [[ -n "$output" ]]; then
    assert_pass "Filter fails open on malformed JSON (returns input)"
else
    assert_fail "Filter fails open on malformed JSON"
fi

# Test case 8: Fail-open on jq failure (empty input also covered)
input=""
output=$(echo -n "$input" | quarantine_filter_json "test")
if [[ "$?" -eq 0 ]]; then
    assert_pass "Filter returns exit code 0 on empty input (fail-open)"
else
    assert_fail "Filter returns exit code 0 on empty input (fail-open)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_search_qualifier: Emits server-side search qualifier
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_search_qualifier"

qualifier=$(quarantine_search_qualifier)
if echo "$qualifier" | grep -q 'sw:e2e-test'; then
    assert_pass "quarantine_search_qualifier includes 'sw:e2e-test'"
else
    assert_fail "quarantine_search_qualifier includes 'sw:e2e-test'" "got: $qualifier"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_is_test_issue: Test whether a single issue is quarantined
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_is_test_issue"

# Issue with quarantine label
issue_json='{"number":1,"title":"E2E test","labels":[{"name":"sw:e2e-test"}]}'
if quarantine_is_test_issue "$issue_json"; then
    assert_pass "quarantine_is_test_issue returns 0 for quarantined issue"
else
    assert_fail "quarantine_is_test_issue returns 0 for quarantined issue"
fi

# Issue without quarantine label
issue_json='{"number":1,"title":"Real issue","labels":[{"name":"bug"}]}'
if quarantine_is_test_issue "$issue_json"; then
    assert_fail "quarantine_is_test_issue returns 1 for non-quarantined issue"
else
    assert_pass "quarantine_is_test_issue returns 1 for non-quarantined issue"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Integration: wiring verification
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Integration & Wiring"

# Verify quarantine_label is idempotent
label1=$(quarantine_label)
label2=$(quarantine_label)
assert_eq "quarantine_label is idempotent" "$label1" "$label2"

# Verify all functions exist
for fn in quarantine_label quarantine_labels quarantine_filter_json quarantine_search_qualifier quarantine_is_test_issue; do
    if declare -f "$fn" >/dev/null 2>&1; then
        assert_pass "Function '$fn' exists and is callable"
    else
        assert_fail "Function '$fn' exists and is callable"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# Regression: consumers must load the library without relying on SCRIPT_DIR
# daemon-poll-github.sh is sourced before sw-daemon.sh sets SCRIPT_DIR, so a
# SCRIPT_DIR-relative source silently resolved to lib/lib/ and left
# quarantine_filter_json undefined — daemon poll ran unfiltered.
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Regression: SCRIPT_DIR-independent loading"

if env -u SCRIPT_DIR bash -c \
    "set -euo pipefail; source '$SCRIPT_DIR/lib/daemon-poll-github.sh'; declare -f quarantine_filter_json >/dev/null" \
    >/dev/null 2>&1; then
    assert_pass "daemon-poll-github.sh defines quarantine_filter_json with SCRIPT_DIR unset"
else
    assert_fail "daemon-poll-github.sh defines quarantine_filter_json with SCRIPT_DIR unset"
fi

# The same load must actually filter, not just define the symbol.
regression_input='[{"number":1,"title":"Real","labels":[{"name":"bug"}]},{"number":2,"title":"E2E","labels":[{"name":"sw:e2e-test"}]}]'
regression_count=$(env -u SCRIPT_DIR bash -c \
    "set -euo pipefail; source '$SCRIPT_DIR/lib/daemon-poll-github.sh'; printf '%s' '$regression_input' | quarantine_filter_json 'daemon-poll' | jq 'length'" \
    2>/dev/null || echo "ERR")
assert_eq "daemon-poll-github.sh load filters quarantined issues" "1" "$regression_count"

# A SCRIPT_DIR pointing elsewhere must not break resolution either.
if env SCRIPT_DIR="/nonexistent/path" bash -c \
    "set -euo pipefail; source '$SCRIPT_DIR/lib/daemon-poll-github.sh'; declare -f quarantine_filter_json >/dev/null" \
    >/dev/null 2>&1; then
    assert_pass "daemon-poll-github.sh ignores a stale SCRIPT_DIR when locating the library"
else
    assert_fail "daemon-poll-github.sh ignores a stale SCRIPT_DIR when locating the library"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Regression: every sourced consumer library resolves the quarantine lib itself
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Regression: consumer libraries load the quarantine lib"

for consumer_lib in daemon-poll-github.sh daemon-triage.sh root-cause.sh fleet-failover.sh; do
    if env -u SCRIPT_DIR bash -c \
        "source '$SCRIPT_DIR/lib/$consumer_lib'; declare -f quarantine_filter_json >/dev/null" \
        >/dev/null 2>&1; then
        assert_pass "lib/$consumer_lib loads the quarantine library with SCRIPT_DIR unset"
    else
        assert_fail "lib/$consumer_lib loads the quarantine library with SCRIPT_DIR unset"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# Every consumer that queries GitHub issues must filter them
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Consumer coverage"

for consumer in \
    lib/daemon-poll-github.sh \
    lib/daemon-triage.sh \
    lib/root-cause.sh \
    lib/fleet-failover.sh \
    sw-decide.sh \
    sw-autonomous.sh \
    sw-patrol-meta.sh \
    sw-strategic.sh \
    sw-triage.sh \
    sw-release-manager.sh; do
    if grep -q 'quarantine_filter_json\|quarantine_search_qualifier' "$SCRIPT_DIR/$consumer"; then
        assert_pass "$consumer filters quarantined issues"
    else
        assert_fail "$consumer filters quarantined issues" "no quarantine call found"
    fi
done

# quarantine_filter_json matches on labels, so every call site must have asked
# GitHub for them. A --json list without `labels` filters nothing, silently.
print_test_section "Filter call sites request labels"

labels_violations=""
while IFS= read -r hit; do
    hit_file="${hit%%:*}"
    hit_line="${hit#*:}"
    hit_line="${hit_line%%:*}"
    # The gh invocation may span several lines above the pipe into the filter.
    window=$(sed -n "$((hit_line > 6 ? hit_line - 6 : 1)),${hit_line}p" "$hit_file")
    printf '%s' "$window" | grep -q -- '--json' || continue
    printf '%s' "$window" | grep -q 'labels' || labels_violations="${labels_violations}${hit_file}:${hit_line} "
done < <(grep -rn '| quarantine_filter_json' "$SCRIPT_DIR" --include='sw-*.sh' --include='*.sh' \
    | grep -v -- '-test\.sh' || true)

assert_eq "every quarantine_filter_json call site requests 'labels'" "" "$labels_violations"

# ═══════════════════════════════════════════════════════════════════════════════
# Fail-open: malformed and empty input pass through with exit 0
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Fail-open on bad input"

failopen_out=$(printf '%s' 'not json at all' | quarantine_filter_json "failopen" 2>/dev/null)
failopen_rc=$?
assert_eq "malformed JSON passes through unfiltered" "not json at all" "$failopen_out"
assert_eq "malformed JSON exits 0" "0" "$failopen_rc"

failopen_out=$(printf '%s' '' | quarantine_filter_json "failopen" 2>/dev/null; echo "rc=$?")
assert_eq "empty input exits 0" "rc=0" "$failopen_out"

# An issue array with no labels key at all must survive intact.
nolabels=$(printf '%s' '[{"number":1,"title":"No labels key"}]' \
    | quarantine_filter_json "failopen" | jq 'length')
assert_eq "issues without a labels key are not dropped" "1" "$nolabels"

# ═══════════════════════════════════════════════════════════════════════════════
# quarantine_backfill_candidates: finds synthetic issues that predate the label
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "quarantine_backfill_candidates"

backfill_input='[
  {"number":1,"title":"E2E test: add comment to README [automated]","labels":[]},
  {"number":2,"title":"E2E test: already labeled","labels":[{"name":"sw:e2e-test"}]},
  {"number":3,"title":"Fix the daemon poll loop","labels":[{"name":"bug"}]},
  {"number":4,"title":"E2E test: legacy label","labels":[{"name":"e2e-test"}]}
]'

backfill_out=$(printf '%s' "$backfill_input" | quarantine_backfill_candidates)
assert_eq "backfill finds exactly the unlabeled synthetic issue" "1" \
    "$(printf '%s' "$backfill_out" | jq 'length')"
assert_eq "backfill selects the right issue number" "1" \
    "$(printf '%s' "$backfill_out" | jq -r '.[0].number')"

assert_eq "backfill ignores issues already carrying the label" "0" \
    "$(printf '%s' '[{"number":2,"title":"E2E test: x","labels":[{"name":"sw:e2e-test"}]}]' \
        | quarantine_backfill_candidates | jq 'length')"

assert_eq "backfill ignores legacy-labeled issues" "0" \
    "$(printf '%s' '[{"number":4,"title":"E2E test: x","labels":[{"name":"e2e-test"}]}]' \
        | quarantine_backfill_candidates | jq 'length')"

assert_eq "backfill ignores real issues" "0" \
    "$(printf '%s' '[{"number":3,"title":"Fix the daemon","labels":[]}]' \
        | quarantine_backfill_candidates | jq 'length')"

# The pattern anchors at the start — a real issue merely mentioning E2E is safe.
assert_eq "backfill does not match a mid-title mention of E2E test" "0" \
    "$(printf '%s' '[{"number":5,"title":"Speed up the E2E test suite","labels":[]}]' \
        | quarantine_backfill_candidates | jq 'length')"

# Fail-closed: unlike the filter, bad input must yield no relabel candidates.
assert_eq "malformed JSON yields no backfill candidates" "[]" \
    "$(printf '%s' 'not json' | quarantine_backfill_candidates)"
assert_eq "empty input yields no backfill candidates" "[]" \
    "$(printf '%s' '' | quarantine_backfill_candidates)"

# ═══════════════════════════════════════════════════════════════════════════════
# CLI wiring: `shipwright triage quarantine` and doctor validation
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "CLI wiring"

if "$SCRIPT_DIR/sw-triage.sh" help 2>&1 | grep -q "quarantine list"; then
    assert_pass "triage help documents 'quarantine list'"
else
    assert_fail "triage help documents 'quarantine list'"
fi

if grep -q 'quarantine)' "$SCRIPT_DIR/sw-triage.sh"; then
    assert_pass "triage router dispatches the quarantine subcommand"
else
    assert_fail "triage router dispatches the quarantine subcommand"
fi

# `apply` without --apply must not reach `gh issue edit`. Proven structurally:
# the edit call is guarded by the do_apply flag.
if grep -A 3 'if \[\[ "\$do_apply" != "true" \]\]' "$SCRIPT_DIR/sw-triage.sh" | grep -q 'Dry run'; then
    assert_pass "triage quarantine apply is a dry run without --apply"
else
    assert_fail "triage quarantine apply is a dry run without --apply"
fi

if grep -q 'E2E ISSUE QUARANTINE' "$SCRIPT_DIR/sw-doctor.sh"; then
    assert_pass "doctor reports quarantine config health"
else
    assert_fail "doctor reports quarantine config health"
fi

print_test_results
