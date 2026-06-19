#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright knowledge test — Fleet-Wide Pattern Mining & Transfer tests   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

KNOWLEDGE="$SCRIPT_DIR/sw-knowledge.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright/memory"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    MEM="$HOME/.shipwright/memory"
}

# Seed a per-repo failures.json
seed_failures() {
    local repo="$1"; shift
    local pattern="$1" fix="${2:-fix it}" seen="${3:-1}"
    mkdir -p "$MEM/$repo"
    jq -n --arg p "$pattern" --arg f "$fix" --argjson s "$seen" \
        '{failures: [{stage:"test", pattern:$p, root_cause:"rc", fix:$f, seen_count:$s, last_seen:"2026-06-19T00:00:00Z", category:"test_failure"}]}' \
        > "$MEM/$repo/failures.json"
}

trap cleanup_test_env EXIT

echo ""
print_test_header "Shipwright Knowledge (Fleet Pattern Mining) Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_env

# ─── Test 1: mine on empty fleet produces valid file ─────────────────────────
output=$(bash "$KNOWLEDGE" mine 2>&1) || true
if jq -e '.patterns and .metrics' "$MEM/fleet-knowledge.json" >/dev/null 2>&1; then
    assert_pass "mine produces a valid fleet-knowledge.json"
else
    assert_fail "mine produces a valid fleet-knowledge.json"
fi

# ─── Test 2: cross-repo collapse by signature ────────────────────────────────
# Two repos with the SAME failure (ANSI + case + digit variants) must collapse
# to one pattern with repo_count == 2.
seed_failures "repoA" $'\033[31mConnection timeout after 30 seconds\033[0m' "increase timeout" 3
seed_failures "repoB" "connection timeout after 90 seconds" "bump timeout" 2
bash "$KNOWLEDGE" mine >/dev/null 2>&1 || true
repo_count=$(jq -r '[.patterns[] | select(.summary|ascii_downcase|contains("connection timeout"))][0].repo_count // 0' "$MEM/fleet-knowledge.json")
assert_eq "same failure across 2 repos collapses to repo_count=2" "2" "$repo_count"

total_occ=$(jq -r '[.patterns[] | select(.summary|ascii_downcase|contains("connection timeout"))][0].total_occurrences // 0' "$MEM/fleet-knowledge.json")
assert_eq "occurrences summed across repos (3+2=5)" "5" "$total_occ"

# ─── Test 3: confidence is bounded 0..100 and cross-repo scores higher ───────
conf=$(jq -r '[.patterns[] | select(.repo_count==2)][0].confidence // 0' "$MEM/fleet-knowledge.json")
if [[ "$conf" -ge 0 && "$conf" -le 100 ]]; then
    assert_pass "confidence within [0,100] bounds ($conf)"
else
    assert_fail "confidence within [0,100] bounds" "got $conf"
fi
# A 2-repo pattern should out-score any 1-repo pattern.
seed_failures "repoC" "single repo only failure xyz" "noop" 1
bash "$KNOWLEDGE" mine >/dev/null 2>&1 || true
cross_conf=$(jq -r '[.patterns[] | select(.repo_count>=2)] | sort_by(-.confidence) | .[0].confidence // 0' "$MEM/fleet-knowledge.json")
solo_conf=$(jq -r '[.patterns[] | select(.repo_count==1)] | sort_by(-.confidence) | .[0].confidence // 0' "$MEM/fleet-knowledge.json")
if [[ "$cross_conf" -gt "$solo_conf" ]]; then
    assert_pass "cross-repo pattern out-scores solo pattern ($cross_conf > $solo_conf)"
else
    assert_fail "cross-repo pattern out-scores solo pattern" "$cross_conf vs $solo_conf"
fi

# ─── Test 4: metrics reflect cross-repo count ────────────────────────────────
cross=$(jq -r '.metrics.cross_repo_patterns // 0' "$MEM/fleet-knowledge.json")
assert_eq "cross_repo_patterns metric == 1" "1" "$cross"

# ─── Test 5: inject emits relevant ranked context ────────────────────────────
output=$(bash "$KNOWLEDGE" inject test 2>&1) || true
assert_contains "inject emits fleet knowledge header" "$output" "Fleet-Wide Knowledge Context"
assert_contains "inject surfaces cross-repo pattern" "$output" "timeout after 30"

# ─── Test 6: inject bumps injection counter ──────────────────────────────────
inj=$(jq -r '.metrics.total_injections // 0' "$MEM/fleet-knowledge.json")
if [[ "$inj" -ge 1 ]]; then
    assert_pass "inject increments total_injections ($inj)"
else
    assert_fail "inject increments total_injections" "got $inj"
fi

# ─── Test 7: transfer promotes cross-repo into global.json ───────────────────
bash "$KNOWLEDGE" transfer >/dev/null 2>&1 || true
if jq -e '.cross_repo_learnings' "$MEM/global.json" >/dev/null 2>&1; then
    assert_pass "transfer creates/updates global.json"
else
    assert_fail "transfer creates/updates global.json"
fi
learned=$(jq -r '[.cross_repo_learnings[] | select(.pattern|ascii_downcase|contains("connection timeout"))] | length' "$MEM/global.json")
assert_eq "cross-repo pattern transferred to global.json" "1" "$learned"

# ─── Test 8: transfer is additive + deduped (idempotent) ─────────────────────
before=$(jq '.cross_repo_learnings | length' "$MEM/global.json")
bash "$KNOWLEDGE" transfer >/dev/null 2>&1 || true
after=$(jq '.cross_repo_learnings | length' "$MEM/global.json")
assert_eq "re-running transfer does not duplicate entries" "$before" "$after"

# ─── Test 9: search finds a known pattern ────────────────────────────────────
output=$(bash "$KNOWLEDGE" search timeout 2>&1) || true
assert_contains "search finds matching pattern" "$output" "timeout after 30"

# ─── Test 10: search with no query fails ─────────────────────────────────────
if bash "$KNOWLEDGE" search >/dev/null 2>&1; then
    assert_fail "search with no query exits nonzero"
else
    assert_pass "search with no query exits nonzero"
fi

# ─── Test 11: malformed memory JSON does not crash mine ──────────────────────
mkdir -p "$MEM/repoBad"
echo 'this is not json {{{' > "$MEM/repoBad/failures.json"
if bash "$KNOWLEDGE" mine >/dev/null 2>&1; then
    assert_pass "mine survives malformed repo memory JSON"
else
    assert_fail "mine survives malformed repo memory JSON"
fi
# And the output file is still valid JSON.
if jq -e '.patterns' "$MEM/fleet-knowledge.json" >/dev/null 2>&1; then
    assert_pass "fleet-knowledge.json remains valid after malformed input"
else
    assert_fail "fleet-knowledge.json remains valid after malformed input"
fi

# ─── Test 12: malformed global.json is repaired by transfer ──────────────────
echo 'garbage{' > "$MEM/global.json"
bash "$KNOWLEDGE" transfer >/dev/null 2>&1 || true
if jq -e '.cross_repo_learnings' "$MEM/global.json" >/dev/null 2>&1; then
    assert_pass "transfer repairs malformed global.json"
else
    assert_fail "transfer repairs malformed global.json"
fi

# ─── Test 13: show --json emits valid JSON ───────────────────────────────────
output=$(bash "$KNOWLEDGE" show --json 2>/dev/null) || true
if jq -e '.patterns' <<< "$output" >/dev/null 2>&1; then
    assert_pass "show --json emits valid JSON"
else
    assert_fail "show --json emits valid JSON"
fi

# ─── Test 14: report renders summary ─────────────────────────────────────────
output=$(bash "$KNOWLEDGE" report 2>&1) || true
assert_contains "report renders summary header" "$output" "Fleet-Wide Knowledge Report"

# ─── Test 15: unknown command exits nonzero ──────────────────────────────────
if bash "$KNOWLEDGE" bogus >/dev/null 2>&1; then
    assert_fail "unknown command exits nonzero"
else
    assert_pass "unknown command exits nonzero"
fi

# ─── Test 16: router dispatches knowledge + mine alias ───────────────────────
output=$(bash "$SCRIPT_DIR/sw" knowledge report 2>&1) || true
assert_contains "router dispatches 'knowledge'" "$output" "Fleet-Wide Knowledge Report"
output=$(bash "$SCRIPT_DIR/sw" mine 2>&1) || true
assert_contains "router dispatches 'mine' alias" "$output" "Mined"

echo ""
echo ""
print_test_results
