#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright triage test — Intelligent Issue Labeling & Prioritization    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo "Mock claude response"
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1" detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"; }
echo ""
print_test_header "Shipwright Triage Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-triage.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright triage"
assert_contains "help shows subcommands" "$output" "SUBCOMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-triage.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-triage.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown subcommand exits 1" "1" "$rc"
assert_contains "unknown shows error" "$output" "Unknown subcommand"

# ─── Test 4: analyze requires GitHub (exits with NO_GITHUB=1) ─────────────
echo ""
echo -e "  ${CYAN}GitHub guard${RESET}"
output=$(NO_GITHUB=1 bash "$SCRIPT_DIR/sw-triage.sh" analyze 42 2>&1) && rc=0 || rc=$?
assert_eq "analyze exits 1 with NO_GITHUB=1" "1" "$rc"
assert_contains "analyze shows disabled" "$output" "disabled"

# ─── Test 5: analyze missing args ─────────────────────────────────────────
output=$(NO_GITHUB=1 bash "$SCRIPT_DIR/sw-triage.sh" analyze 2>&1) && rc=0 || rc=$?
assert_eq "analyze without args exits 1" "1" "$rc"

# ─── Test 6: team missing args ────────────────────────────────────────────
output=$(NO_GITHUB=1 bash "$SCRIPT_DIR/sw-triage.sh" team 2>&1) && rc=0 || rc=$?
assert_eq "team without args exits 1" "1" "$rc"

# ─── Test 7: Test internal analyze_type function ──────────────────────────
echo ""
echo -e "  ${CYAN}internal analysis functions${RESET}"
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"

    result=$(analyze_type "Fix the security vulnerability in login")
    if [[ "$result" == "security" ]]; then
        echo "TYPE_SECURITY_OK"
    else
        echo "TYPE_SECURITY_FAIL:$result"
    fi
) > "$TEST_TEMP_DIR/type_output" 2>/dev/null
type_result=$(cat "$TEST_TEMP_DIR/type_output")
if echo "$type_result" | grep -qF "TYPE_SECURITY_OK"; then
    assert_pass "analyze_type detects security"
else
    assert_fail "analyze_type detects security" "got: $type_result"
fi

# ─── Test 8: Test analyze_type for bugs ───────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_type "Bug in the crash handler causing errors")
    if [[ "$result" == "bug" ]]; then
        echo "TYPE_BUG_OK"
    else
        echo "TYPE_BUG_FAIL:$result"
    fi
) > "$TEST_TEMP_DIR/type_output2" 2>/dev/null
type_result2=$(cat "$TEST_TEMP_DIR/type_output2")
if echo "$type_result2" | grep -qF "TYPE_BUG_OK"; then
    assert_pass "analyze_type detects bug"
else
    assert_fail "analyze_type detects bug" "got: $type_result2"
fi

# ─── Test 9: Test analyze_type for feature ────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_type "Add new payment integration")
    if [[ "$result" == "feature" ]]; then
        echo "TYPE_FEATURE_OK"
    else
        echo "TYPE_FEATURE_FAIL:$result"
    fi
) > "$TEST_TEMP_DIR/type_output3" 2>/dev/null
type_result3=$(cat "$TEST_TEMP_DIR/type_output3")
if echo "$type_result3" | grep -qF "TYPE_FEATURE_OK"; then
    assert_pass "analyze_type detects feature"
else
    assert_fail "analyze_type detects feature" "got: $type_result3"
fi

# ─── Test 10: Test analyze_complexity ──────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    # Simple short text
    result=$(analyze_complexity "Fix a typo")
    echo "$result"
) > "$TEST_TEMP_DIR/complexity_output" 2>/dev/null
complexity_result=$(cat "$TEST_TEMP_DIR/complexity_output")
assert_eq "short text = trivial complexity" "trivial" "$complexity_result"

# ─── Test 11: Test analyze_risk ────────────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_risk "Security vulnerability with critical exploit")
    echo "$result"
) > "$TEST_TEMP_DIR/risk_output" 2>/dev/null
risk_result=$(cat "$TEST_TEMP_DIR/risk_output")
assert_eq "security text = high risk" "high" "$risk_result"

# ─── Test 12: Test analyze_effort ──────────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(analyze_effort "trivial" "low")
    echo "$result"
) > "$TEST_TEMP_DIR/effort_output" 2>/dev/null
effort_result=$(cat "$TEST_TEMP_DIR/effort_output")
assert_eq "trivial+low = xs effort" "xs" "$effort_result"

# ─── Test 13: Test suggest_labels ──────────────────────────────────────────
(
    set +euo pipefail
    source "$SCRIPT_DIR/sw-triage.sh"
    result=$(suggest_labels "bug" "simple" "high" "m")
    echo "$result"
) > "$TEST_TEMP_DIR/labels_output" 2>/dev/null
labels_result=$(cat "$TEST_TEMP_DIR/labels_output")
assert_contains "suggest_labels includes type" "$labels_result" "type:bug"
assert_contains "suggest_labels includes risk" "$labels_result" "risk:high"
assert_contains "suggest_labels includes priority" "$labels_result" "priority:high"

# ─── Test 14: team works offline with recruit (NO_GITHUB=1) ────────────
echo ""
echo -e "  ${CYAN}triage team offline fallback${RESET}"

# Create mock recruit that returns team JSON
cat > "$TEST_TEMP_DIR/bin/sw-recruit.sh" <<'MOCK_RECRUIT'
#!/usr/bin/env bash
if [[ "${1:-}" == "team" && "${2:-}" == "--json" ]]; then
    echo '{"team":["builder","reviewer"],"method":"heuristic","estimated_cost":3.0,"model":"sonnet","agents":2,"template":"standard","max_iterations":8}'
    exit 0
fi
echo "mock recruit"
MOCK_RECRUIT
chmod +x "$TEST_TEMP_DIR/bin/sw-recruit.sh"

# Point SCRIPT_DIR to temp dir and copy triage there.
# lib/ must come along: sw-triage.sh sources lib/compat.sh behind a
# `[[ -f ]]` guard, so a missing lib/ is skipped silently at startup and then
# surfaces ~600 lines later as `_smart_model: command not found` (exit 127).
# These tests isolate the *recruit* dependency, not the shared library — a real
# install always has lib/ next to the scripts.
cp "$SCRIPT_DIR/sw-triage.sh" "$TEST_TEMP_DIR/bin/sw-triage.sh"
mkdir -p "$TEST_TEMP_DIR/bin/lib"
cp "$SCRIPT_DIR/lib"/*.sh "$TEST_TEMP_DIR/bin/lib/" 2>/dev/null || true

output=$(NO_GITHUB=1 SCRIPT_DIR="$TEST_TEMP_DIR/bin" bash "$TEST_TEMP_DIR/bin/sw-triage.sh" team 42 2>&1) && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
    assert_pass "team works offline with recruit (exit 0)"
else
    # Even if non-zero, check if it produced a recommendation
    if echo "$output" | grep -q "pipeline_template"; then
        assert_pass "team works offline with recruit (produced recommendation)"
    else
        assert_fail "team works offline with recruit" "exit=$rc output=$(echo "$output" | tail -3)"
    fi
fi

# Verify team output contains expected fields
if echo "$output" | grep -q "pipeline_template"; then
    assert_pass "team offline output has pipeline_template"
else
    assert_fail "team offline output has pipeline_template" "got: $(echo "$output" | tail -5)"
fi

if echo "$output" | grep -q '"source": "recruit"'; then
    assert_pass "team offline uses recruit source"
elif echo "$output" | grep -q '"source": "heuristic"'; then
    assert_pass "team offline falls back to heuristic source"
else
    assert_fail "team offline has source field" "got: $(echo "$output" | tail -5)"
fi

# ─── Test 15: team offline without recruit falls to defaults ──────────
rm -f "$TEST_TEMP_DIR/bin/sw-recruit.sh"
output=$(NO_GITHUB=1 SCRIPT_DIR="$TEST_TEMP_DIR/bin" bash "$TEST_TEMP_DIR/bin/sw-triage.sh" team 42 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "pipeline_template"; then
    assert_pass "team offline without recruit uses heuristic defaults"
else
    assert_fail "team offline without recruit uses heuristic defaults" "exit=$rc output=$(echo "$output" | tail -3)"
fi

# ─── Test 16-24: memory pattern matching ──────────────────────────────────
echo ""
echo -e "  ${CYAN}memory pattern matching${RESET}"

# The git mock echoes "" for `git config`, so _triage_repo_hash always hashes
# the literal "local" — deterministic across machines and CI runners.
if command -v shasum >/dev/null 2>&1; then
    REPO_HASH=$(printf 'local' | shasum -a 256 | cut -c1-12)
else
    REPO_HASH=$(printf 'local' | sha256sum | cut -c1-12)
fi

PAT_MEM_ROOT="$TEST_TEMP_DIR/mem"
mkdir -p "$PAT_MEM_ROOT/$REPO_HASH"
cat > "$PAT_MEM_ROOT/$REPO_HASH/failures.json" <<'FIXTURE'
{"failures":[
  {"stage":"build","pattern":"grep -c under pipefail produces double output in daemon dispatch","root_cause":"pipefail semantics","fix":"use || true with ${var:-0}","seen_count":4},
  {"stage":"test","pattern":"mktemp directory creation failed on the CI runner","root_cause":"","fix":"","seen_count":2}
]}
FIXTURE
cat > "$PAT_MEM_ROOT/global.json" <<'FIXTURE'
{"common_patterns":[{"pattern":"stale pipeline lock blocks worktree cleanup","category":"general","source":"aggregate"}],"cross_repo_learnings":[]}
FIXTURE

pattern_match() { MEMORY_ROOT="$PAT_MEM_ROOT" bash "$SCRIPT_DIR/sw-triage.sh" pattern-match "$@" 2>&1; }

# Match: issue text overlapping a local failure pattern
output=$(pattern_match "grep -c under pipefail produces double output") && rc=0 || rc=$?
assert_eq "pattern-match exits 0 on a match" "0" "$rc"
assert_eq "local pattern match reports source=local" "local" "$(echo "$output" | jq -r '.source')"
match_score=$(echo "$output" | jq -r '.score')
if [[ "${match_score:-0}" -ge 60 ]]; then
    assert_pass "local pattern match scores at or above threshold (got $match_score)"
else
    assert_fail "local pattern match scores at or above threshold" "got: $match_score"
fi
assert_contains "match carries the captured fix as note" "$(echo "$output" | jq -r '.note')" "|| true"
assert_eq "match confidence is a known tier" "true" \
    "$(echo "$output" | jq -r '.confidence | . == "low" or . == "medium" or . == "high"')"

# No match: unrelated issue text
output=$(pattern_match "add a dark mode toggle to the account settings screen") && rc=0 || rc=$?
assert_eq "pattern-match exits 0 on no match" "0" "$rc"
assert_eq "unrelated text produces no match" "{}" "$(echo "$output" | tr -d ' \n')"

# Fleet: global.json pattern matches when fleet lookup is enabled
output=$(pattern_match "stale pipeline lock blocks worktree cleanup")
assert_eq "fleet pattern match reports source=fleet" "fleet" "$(echo "$output" | jq -r '.source')"

# Fleet disabled: same text must not match
output=$(SHIPWRIGHT_TRIAGE_PATTERN_MATCHING_FLEET_ENABLED=false MEMORY_ROOT="$PAT_MEM_ROOT" \
    bash "$SCRIPT_DIR/sw-triage.sh" pattern-match "stale pipeline lock blocks worktree cleanup" 2>&1)
assert_eq "fleet_enabled=false suppresses the fleet match" "{}" "$(echo "$output" | tr -d ' \n')"

# Feature disabled entirely
output=$(SHIPWRIGHT_TRIAGE_PATTERN_MATCHING_ENABLED=false MEMORY_ROOT="$PAT_MEM_ROOT" \
    bash "$SCRIPT_DIR/sw-triage.sh" pattern-match "grep -c under pipefail produces double output" 2>&1)
assert_eq "enabled=false makes pattern matching a no-op" "{}" "$(echo "$output" | tr -d ' \n')"

# Threshold is honoured: a very high threshold rejects an otherwise-good match
output=$(SHIPWRIGHT_TRIAGE_PATTERN_MATCHING_SIMILARITY_THRESHOLD=99 MEMORY_ROOT="$PAT_MEM_ROOT" \
    bash "$SCRIPT_DIR/sw-triage.sh" pattern-match "grep -c under pipefail produces double output" 2>&1)
assert_eq "threshold=99 rejects a 60-80 scoring match" "{}" "$(echo "$output" | tr -d ' \n')"

# ─── Graceful degradation ─────────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}pattern matching degradation${RESET}"

output=$(MEMORY_ROOT="$TEST_TEMP_DIR/no-such-memory-root" bash "$SCRIPT_DIR/sw-triage.sh" \
    pattern-match "grep -c under pipefail produces double output" 2>&1) && rc=0 || rc=$?
assert_eq "missing memory dir exits 0" "0" "$rc"
assert_eq "missing memory dir yields no match" "{}" "$(echo "$output" | tr -d ' \n')"

CORRUPT_ROOT="$TEST_TEMP_DIR/corrupt-mem"
mkdir -p "$CORRUPT_ROOT/$REPO_HASH"
echo '{' > "$CORRUPT_ROOT/$REPO_HASH/failures.json"
echo '{' > "$CORRUPT_ROOT/global.json"
output=$(MEMORY_ROOT="$CORRUPT_ROOT" bash "$SCRIPT_DIR/sw-triage.sh" \
    pattern-match "grep -c under pipefail produces double output" 2>&1) && rc=0 || rc=$?
assert_eq "corrupt memory JSON exits 0" "0" "$rc"
assert_eq "corrupt memory JSON yields no match" "{}" "$(echo "$output" | tr -d ' \n')"

EMPTY_ROOT="$TEST_TEMP_DIR/empty-mem"
mkdir -p "$EMPTY_ROOT/$REPO_HASH"
echo '{"failures":[]}' > "$EMPTY_ROOT/$REPO_HASH/failures.json"
output=$(MEMORY_ROOT="$EMPTY_ROOT" bash "$SCRIPT_DIR/sw-triage.sh" \
    pattern-match "grep -c under pipefail produces double output" 2>&1) && rc=0 || rc=$?
assert_eq "empty failures list exits 0" "0" "$rc"
assert_eq "empty failures list yields no match" "{}" "$(echo "$output" | tr -d ' \n')"

# No SHA tool on PATH: the repo hash degrades to "local" instead of an empty
# path segment, so the lookup misses cleanly rather than scanning MEMORY_ROOT.
output=$(bash -c "source \"$SCRIPT_DIR/sw-triage.sh\"
shasum()    { return 127; }
sha256sum() { return 127; }
_triage_repo_hash" 2>&1) && rc=0 || rc=$?
assert_eq "absent SHA tool exits 0" "0" "$rc"
assert_eq "absent SHA tool falls back to a 'local' repo hash" "local" "$output"

output=$(MEMORY_ROOT="$PAT_MEM_ROOT" bash "$SCRIPT_DIR/sw-triage.sh" pattern-match "" 2>&1) && rc=0 || rc=$?
assert_eq "pattern-match without text exits 1" "1" "$rc"
assert_contains "pattern-match without text shows usage" "$output" "Usage: triage pattern-match"

# ─── analyze JSON shape (AC4 backward compatibility) ──────────────────────
echo ""
echo -e "  ${CYAN}analyze output shape${RESET}"

mkdir -p "$TEST_TEMP_DIR/ghbin"
cat > "$TEST_TEMP_DIR/ghbin/gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
    echo "{\"title\":\"$SW_MOCK_ISSUE_TITLE\",\"body\":\"$SW_MOCK_ISSUE_BODY\",\"labels\":[{\"name\":\"bug\"}]}"
    exit 0
fi
echo '[]'
exit 0
MOCK
chmod +x "$TEST_TEMP_DIR/ghbin/gh"

EXPECTED_KEYS='issue title type complexity risk effort suggested_labels existing_labels'

# No-match analyze: key list must be identical to the pre-change output
output=$(PATH="$TEST_TEMP_DIR/ghbin:$PATH" MEMORY_ROOT="$PAT_MEM_ROOT" NO_GITHUB="" \
    SW_MOCK_ISSUE_TITLE="Add a dark mode toggle" \
    SW_MOCK_ISSUE_BODY="Users want a dark mode toggle on the account settings screen" \
    bash "$SCRIPT_DIR/sw-triage.sh" analyze 42 2>/dev/null) && rc=0 || rc=$?
analyze_json=$(echo "$output" | sed -n '/^{/,$p')
assert_eq "analyze exits 0 with a mocked issue" "0" "$rc"
assert_eq "analyze no-match key list is unchanged" "$EXPECTED_KEYS" \
    "$(echo "$analyze_json" | jq -r 'keys_unsorted | join(" ")')"

# Match analyze: known_pattern_match appended, base keys still intact
output=$(PATH="$TEST_TEMP_DIR/ghbin:$PATH" MEMORY_ROOT="$PAT_MEM_ROOT" NO_GITHUB="" \
    SW_MOCK_ISSUE_TITLE="grep -c under pipefail produces double output" \
    SW_MOCK_ISSUE_BODY="Seen again in daemon dispatch" \
    bash "$SCRIPT_DIR/sw-triage.sh" analyze 43 2>/dev/null) && rc=0 || rc=$?
analyze_json=$(echo "$output" | sed -n '/^{/,$p')
assert_eq "analyze exits 0 on a pattern match" "0" "$rc"
assert_eq "analyze match key list appends known_pattern_match" \
    "$EXPECTED_KEYS known_pattern_match" \
    "$(echo "$analyze_json" | jq -r 'keys_unsorted | join(" ")')"
assert_eq "analyze known_pattern_match has all fields" "true" \
    "$(echo "$analyze_json" | jq -r '.known_pattern_match | has("pattern") and has("source") and has("score") and has("confidence") and has("note")')"

echo ""
echo ""
print_test_results
