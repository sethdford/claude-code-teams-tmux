#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost per-issue test — Validate per-issue cost tracking       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-cost-per-issue-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock git"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/git"

    # Mock sqlite3
    cat > "$TEMP_DIR/bin/sqlite3" <<'MOCKEOF'
#!/usr/bin/env bash
echo ""
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/sqlite3"

    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

assert_gt() {
    local desc="$1" val="$2" threshold="$3"
    if awk -v v="$val" -v t="$threshold" 'BEGIN { exit !(v > t) }' 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected $val > $threshold"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Cost Per-Issue Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: per-issue file creation ──────────────────────────────────────────
echo -e "${DIM}  file initialization${RESET}"

bash "$SCRIPT_DIR/sw-cost.sh" per-issue 2>&1 >/dev/null || true
if [[ -f "$HOME/.shipwright/cost-per-issue.json" ]]; then
    assert_pass "cost-per-issue.json created on first use"
else
    assert_fail "cost-per-issue.json created on first use"
fi

valid=$(jq -e '.issues' "$HOME/.shipwright/cost-per-issue.json" >/dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "cost-per-issue.json has issues object" "yes" "$valid"

# ─── Test 2: record-per-issue creates entry ───────────────────────────────────
echo ""
echo -e "${DIM}  recording per-issue costs${RESET}"

bash "$SCRIPT_DIR/sw-cost.sh" record-per-issue 42 1.2345 120 true standard sonnet 2>&1 >/dev/null || rc=$?
issue_exists=$(jq -e '.issues["42"]' "$HOME/.shipwright/cost-per-issue.json" >/dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "Issue 42 recorded" "yes" "$issue_exists"

total_cost=$(jq '.issues["42"].total_cost' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 total cost correct" "1.2345" "$total_cost"

total_runs=$(jq '.issues["42"].total_runs' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 total runs is 1" "1" "$total_runs"

successful=$(jq '.issues["42"].successful_runs' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 successful runs is 1" "1" "$successful"

failed=$(jq '.issues["42"].failed_runs' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 failed runs is 0" "0" "$failed"

# ─── Test 3: upsert — second run accumulates ─────────────────────────────────
echo ""
echo -e "${DIM}  upsert accumulation${RESET}"

bash "$SCRIPT_DIR/sw-cost.sh" record-per-issue 42 2.5000 180 false fast opus 2>&1 >/dev/null || true

total_cost=$(jq '.issues["42"].total_cost' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 accumulated cost" "3.7345" "$total_cost"

total_runs=$(jq '.issues["42"].total_runs' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 total runs is 2" "2" "$total_runs"

successful=$(jq '.issues["42"].successful_runs' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 successful runs still 1" "1" "$successful"

failed=$(jq '.issues["42"].failed_runs' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 failed runs is 1" "1" "$failed"

# ─── Test 4: template tracking ───────────────────────────────────────────────
tpl_standard=$(jq '.issues["42"].templates.standard // 0' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Template standard count is 1" "1" "$tpl_standard"

tpl_fast=$(jq '.issues["42"].templates.fast // 0' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Template fast count is 1" "1" "$tpl_fast"

# ─── Test 5: model tracking ──────────────────────────────────────────────────
model_sonnet=$(jq '.issues["42"].models.sonnet // 0' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Model sonnet count is 1" "1" "$model_sonnet"

model_opus=$(jq '.issues["42"].models.opus // 0' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Model opus count is 1" "1" "$model_opus"

# ─── Test 6: multiple issues ─────────────────────────────────────────────────
echo ""
echo -e "${DIM}  multiple issues${RESET}"

bash "$SCRIPT_DIR/sw-cost.sh" record-per-issue 99 5.0000 300 true standard opus 2>&1 >/dev/null || true
bash "$SCRIPT_DIR/sw-cost.sh" record-per-issue 7 0.5000 60 true fast haiku 2>&1 >/dev/null || true

issue_count=$(jq '.issues | length' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Three issues tracked" "3" "$issue_count"

# ─── Test 7: per-issue dashboard output ───────────────────────────────────────
echo ""
echo -e "${DIM}  dashboard display${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" per-issue 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "per-issue exits 0"
else
    assert_fail "per-issue exits 0" "exit code: $rc"
fi
assert_contains "Dashboard shows SUMMARY" "$output" "SUMMARY"
assert_contains "Dashboard shows Issues tracked" "$output" "Issues tracked"
assert_contains "Dashboard shows Total cost" "$output" "Total cost"
assert_contains "Dashboard shows Median" "$output" "Median"
assert_contains "Dashboard shows P95" "$output" "P95"
assert_contains "Dashboard shows TOP" "$output" "TOP"

# ─── Test 8: per-issue --json output ──────────────────────────────────────────
echo ""
echo -e "${DIM}  JSON output${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" per-issue --json 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "per-issue --json exits 0"
else
    assert_fail "per-issue --json exits 0" "exit code: $rc"
fi

json_valid=$(echo "$output" | jq -e '.summary.total_issues' >/dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "JSON output is valid" "yes" "$json_valid"

json_issues=$(echo "$output" | jq '.summary.total_issues')
assert_eq "JSON shows 3 issues" "3" "$json_issues"

json_median=$(echo "$output" | jq '.summary.median_cost_per_issue')
assert_gt "JSON median > 0" "$json_median" "0"

json_p95=$(echo "$output" | jq '.summary.p95_cost_per_issue')
assert_gt "JSON p95 > 0" "$json_p95" "0"

json_most_exp=$(echo "$output" | jq -r '.summary.most_expensive_issue')
assert_eq "Most expensive is issue 99" "99" "$json_most_exp"

# ─── Test 9: per-issue --issue detail view ────────────────────────────────────
echo ""
echo -e "${DIM}  single-issue detail${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" per-issue --issue 42 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "per-issue --issue 42 exits 0"
else
    assert_fail "per-issue --issue 42 exits 0" "exit code: $rc"
fi
assert_contains "Detail shows Issue #42" "$output" "Issue #42"
assert_contains "Detail shows COST SUMMARY" "$output" "COST SUMMARY"
assert_contains "Detail shows TEMPLATES USED" "$output" "TEMPLATES USED"
assert_contains "Detail shows MODELS USED" "$output" "MODELS USED"

# ─── Test 10: per-issue --issue --json ────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-cost.sh" per-issue --issue 42 --json 2>&1) && rc=0 || rc=$?
json_valid=$(echo "$output" | jq -e '.total_cost' >/dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "Issue detail JSON is valid" "yes" "$json_valid"

json_runs=$(echo "$output" | jq '.total_runs')
assert_eq "Issue 42 JSON total_runs is 2" "2" "$json_runs"

json_median=$(echo "$output" | jq '.median_cost')
assert_gt "Issue 42 JSON median > 0" "$json_median" "0"

json_p95=$(echo "$output" | jq '.p95_cost')
assert_gt "Issue 42 JSON p95 > 0" "$json_p95" "0"

# ─── Test 11: non-existent issue ──────────────────────────────────────────────
echo ""
echo -e "${DIM}  edge cases${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" per-issue --issue 99999 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "non-existent issue exits 0 (graceful)"
else
    assert_fail "non-existent issue exits 0 (graceful)" "exit code: $rc"
fi
assert_contains "Non-existent issue warns" "$output" "No cost data"

# ─── Test 12: empty issue skipped ────────────────────────────────────────────
bash "$SCRIPT_DIR/sw-cost.sh" record-per-issue "" 1.00 60 true standard sonnet 2>&1 >/dev/null || true
issue_count=$(jq '.issues | length' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Empty issue not recorded (still 3)" "3" "$issue_count"

# ─── Test 13: help mentions per-issue ─────────────────────────────────────────
echo ""
echo -e "${DIM}  help integration${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" help 2>&1) && rc=0 || rc=$?
assert_contains "Help shows per-issue" "$output" "per-issue"
assert_contains "Help shows PER-ISSUE TRACKING" "$output" "PER-ISSUE TRACKING"

# ─── Test 14: --top flag ──────────────────────────────────────────────────────
echo ""
echo -e "${DIM}  top flag${RESET}"

output=$(bash "$SCRIPT_DIR/sw-cost.sh" per-issue --top 2 --json 2>&1) && rc=0 || rc=$?
json_count=$(echo "$output" | jq '.issues | length')
assert_eq "Top 2 returns 2 issues" "2" "$json_count"

# ─── Test 15: duration tracking ───────────────────────────────────────────────
echo ""
echo -e "${DIM}  duration tracking${RESET}"

dur=$(jq '.issues["42"].total_duration_s' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 total duration is 300s" "300" "$dur"

dur_count=$(jq '.issues["42"].durations | length' "$HOME/.shipwright/cost-per-issue.json")
assert_eq "Issue 42 has 2 duration entries" "2" "$dur_count"

# ─── Test 16: costs array capped at 50 ───────────────────────────────────────
echo ""
echo -e "${DIM}  array bounds${RESET}"

costs_count=$(jq '.issues["42"].costs | length' "$HOME/.shipwright/cost-per-issue.json")
if [[ "$costs_count" -le 50 ]]; then
    assert_pass "Costs array within 50-entry cap"
else
    assert_fail "Costs array within 50-entry cap" "got $costs_count"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
    for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done
fi
echo ""
exit "$FAIL"
