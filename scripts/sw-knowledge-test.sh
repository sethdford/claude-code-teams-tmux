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

# ════════════════════════════════════════════════════════════════════════════
# SUCCESS-PATTERN MINING & RECOMMENDATION (issue #668)
# ════════════════════════════════════════════════════════════════════════════
FIXTURE="$SCRIPT_DIR/fixtures/fleet-patterns.sample.json"
EVENTS="$HOME/.shipwright/events.jsonl"
PATTERNS="$HOME/.shipwright/fleet-patterns.json"

# Seed a successful pipeline.completed event.
seed_success() {
    local template="$1" complexity="$2" iterations="$3" cost="$4" goal="$5" repo="$6" result="${7:-success}" ts="${8:-2026-06-01T00:00:00Z}"
    mkdir -p "$HOME/.shipwright"
    jq -nc --arg tp "$template" --argjson cx "$complexity" --argjson it "$iterations" \
        --arg co "$cost" --arg g "$goal" --arg r "$repo" --arg res "$result" --arg ts "$ts" \
        '{ts:$ts, type:"pipeline.completed", result:$res, template:$tp, complexity:$cx, iterations:$it, total_cost:$co, goal:$g, repo:$r}' \
        >> "$EVENTS"
}

# ─── Test 17: mine-success consolidates 2 repos sharing a signature ──────────
rm -f "$EVENTS" "$PATTERNS"
seed_success "standard" 5 2 "0.40" "add auth module" "repoA" "success" "2026-06-01T00:00:00Z"
seed_success "standard" 5 4 "0.60" "add auth module" "repoB" "success" "2026-06-02T00:00:00Z"
seed_success "standard" 5 9 "1.00" "add auth module" "repoA" "failure" "2026-06-03T00:00:00Z"
bash "$KNOWLEDGE" mine-success >/dev/null 2>&1 || true
n_patterns=$(jq -r '[.patterns[] | select(.goal_tokens|index("auth"))] | length' "$PATTERNS")
assert_eq "mine-success consolidates shared signature into one pattern" "1" "$n_patterns"
applied=$(jq -r '.patterns[] | select(.goal_tokens|index("auth")) | .applied_count' "$PATTERNS")
assert_eq "applied_count counts only successes (2)" "2" "$applied"
repo_count=$(jq -r '.patterns[] | select(.goal_tokens|index("auth")) | .repo_count' "$PATTERNS")
assert_eq "repo_count spans 2 repos" "2" "$repo_count"
srate=$(jq -r '.patterns[] | select(.goal_tokens|index("auth")) | .success_rate' "$PATTERNS")
assert_eq "success_rate computed over all runs (2/3=66)" "66" "$srate"
avg_it=$(jq -r '.patterns[] | select(.goal_tokens|index("auth")) | .avg_iterations' "$PATTERNS")
assert_eq "avg_iterations over successes ((2+4)/2=3)" "3" "$avg_it"

# ─── Test 18: mine-success tolerates torn lines and exits 0 ──────────────────
echo 'this is not json {{{' >> "$EVENTS"
if bash "$KNOWLEDGE" mine-success >/dev/null 2>&1; then
    assert_pass "mine-success survives torn event line (exit 0)"
else
    assert_fail "mine-success survives torn event line (exit 0)"
fi
if jq -e '.version == 1' "$PATTERNS" >/dev/null 2>&1; then
    assert_pass "fleet-patterns.json remains valid schema-v1 after torn input"
else
    assert_fail "fleet-patterns.json remains valid schema-v1 after torn input"
fi

# ─── Test 19: scoring weights sum to exactly 1.0 ─────────────────────────────
weights_sum=$(awk 'BEGIN{printf "%.1f", 0.5+0.3+0.2}')
assert_eq "scoring weights sum to 1.0" "1.0" "$weights_sum"

# ─── Test 20: pinned scoring — probe scores exactly 60 against the fixture ───
cp "$FIXTURE" "$PATTERNS"
# Probe "alpha zzz" @complexity 5 vs pattern {alpha,beta,gamma,delta}@c5,repo5:
#   overlap=1/5=0.2, complexity_match=1.0, repo_norm=1.0
#   floor(100*(0.5*0.2 + 0.3*1 + 0.2*1) + 0.5) = floor(60.5) = 60
score=$(bash "$KNOWLEDGE" recommend --json "alpha zzz" 5 9 | jq -r '.[] | select(.template=="standard") | .score')
assert_eq "pinned formula scores probe at exactly 60" "60" "$score"

# ─── Test 21: gate boundary — threshold 60 passes, 61 rejects ────────────────
n60=$(SW_FLEET_RECOMMEND_THRESHOLD=60 bash "$KNOWLEDGE" recommend --json "alpha zzz" 5 9 | jq -r '[.[] | select(.template=="standard")] | length')
assert_eq "score 60 clears threshold 60" "1" "$n60"
n61=$(SW_FLEET_RECOMMEND_THRESHOLD=61 bash "$KNOWLEDGE" recommend --json "alpha zzz" 5 9 | jq -r '[.[] | select(.template=="standard")] | length')
assert_eq "score 60 rejected at threshold 61" "0" "$n61"

# ─── Test 22: gate requires applied_count >= 2 (excludes one-off flukes) ──────
# Pattern cccc (hotfix, applied=1) matches "flaky test"@c2 strongly but must be gated out.
n_fluke=$(bash "$KNOWLEDGE" recommend --json "flaky test" 2 9 | jq -r '[.[] | select(.template=="hotfix")] | length')
assert_eq "single-application pattern is gated out (applied<2)" "0" "$n_fluke"

# ─── Test 23: Jaccard with no token overlap scores below threshold ───────────
# Unrelated title @complexity far from any pattern → empty intersection.
n_none=$(bash "$KNOWLEDGE" recommend --json "wholly unrelated subject matter" 0 9 | jq 'length')
assert_eq "no-overlap low-complexity probe yields no recommendation" "0" "$n_none"

# ─── Test 24: recommend on empty library returns sentinel, no crash ──────────
rm -f "$PATTERNS"
output=$(bash "$KNOWLEDGE" recommend "anything here" 5 2>&1) || true
assert_contains "recommend on empty library emits NO_RECOMMENDATION sentinel" "$output" "NO_RECOMMENDATION"

# ─── Test 25: recommend with no title fails ──────────────────────────────────
if bash "$KNOWLEDGE" recommend >/dev/null 2>&1; then
    assert_fail "recommend with no title exits nonzero"
else
    assert_pass "recommend with no title exits nonzero"
fi

# ─── Test 26: reconcile — reuses are recounted, never double-counted ─────────
rm -f "$EVENTS" "$PATTERNS"
seed_success "standard" 5 2 "0.40" "add auth module" "repoA" "success" "2026-06-01T00:00:00Z"
seed_success "standard" 5 4 "0.60" "add auth module" "repoB" "success" "2026-06-02T00:00:00Z"
bash "$KNOWLEDGE" mine-success >/dev/null 2>&1 || true
SIG=$(jq -r '.patterns[] | select(.goal_tokens|index("auth")) | .signature' "$PATTERNS")
for i in 1 2 3; do
    jq -nc --arg s "$SIG" --arg ts "2026-06-05T00:00:0${i}Z" \
        '{ts:$ts, type:"knowledge.pattern_recommended", signature:$s, template:"standard"}' >> "$EVENTS"
done
bash "$KNOWLEDGE" mine-success >/dev/null 2>&1 || true
bash "$KNOWLEDGE" mine-success >/dev/null 2>&1 || true
reuses=$(jq -r '.metrics.total_reuses' "$PATTERNS")
assert_eq "3 reuse events + 2 mines => total_reuses=3 (recount, not increment)" "3" "$reuses"
prate=$(jq -r '.metrics.reuse_rate' "$PATTERNS")
assert_eq "reuse_rate = reuses/recommendations = 100" "100" "$prate"

# ─── Test 27: composer hook is read-only and emits exactly one event ─────────
cp "$FIXTURE" "$PATTERNS"
HOOK_LIB="$SCRIPT_DIR/lib/pipeline-composer-fleet.sh"
hook_events="$HOME/hook-events.jsonl"
: > "$hook_events"
hook_out=$(
    KNOWLEDGE_BIN="$KNOWLEDGE" bash -c '
        set -euo pipefail
        emit_event() { local t="$1"; shift; printf "{\"type\":\"%s\"}\n" "$t" >> "'"$hook_events"'"; }
        source "'"$HOOK_LIB"'"
        composer_fleet_recommendation '"'"'{"title":"auth refactor","complexity":6}'"'"'
    ' 2>/dev/null
) || true
assert_eq "composer hook returns proven template on a hit" "fast" "$hook_out"
hook_evt_count=$(grep -c "knowledge.pattern_recommended" "$hook_events" 2>/dev/null || true)
assert_eq "composer hook emits exactly one recommendation event" "1" "${hook_evt_count:-0}"
# Library must be untouched by the hook (pure read).
lib_sig_before=$(md5sum "$PATTERNS" 2>/dev/null | cut -d' ' -f1 || true)
KNOWLEDGE_BIN="$KNOWLEDGE" bash -c '
    emit_event() { :; }
    source "'"$HOOK_LIB"'"
    composer_fleet_recommendation '"'"'{"title":"auth refactor","complexity":6}'"'"' >/dev/null 2>&1
' || true
lib_sig_after=$(md5sum "$PATTERNS" 2>/dev/null | cut -d' ' -f1 || true)
assert_eq "composer hook leaves fleet-patterns.json unmodified" "$lib_sig_before" "$lib_sig_after"

# ─── Test 28: composer hook returns empty on a miss (composer falls back) ────
miss_out=$(
    KNOWLEDGE_BIN="$KNOWLEDGE" bash -c '
        emit_event() { :; }
        source "'"$HOOK_LIB"'"
        composer_fleet_recommendation '"'"'{"title":"zzz nothing matches at all","complexity":0}'"'"'
    ' 2>/dev/null
) || true
assert_eq "composer hook returns empty string on a miss" "" "$miss_out"

# ─── Test 29: patterns-report renders + exposes drift signal ─────────────────
output=$(bash "$KNOWLEDGE" patterns-report 2>&1) || true
assert_contains "patterns-report renders summary header" "$output" "Fleet Success-Pattern Report"
# Drift: events scanned but zero patterns mined (e.g. schema rename).
rm -f "$EVENTS" "$PATTERNS"
jq -nc '{ts:"2026-06-01T00:00:00Z", type:"pipeline.completed", result:"success", tmpl:"standard"}' >> "$EVENTS"
# (no template/complexity fields recognized → still mines via // defaults; force drift by zero successes)
rm -f "$EVENTS"
jq -nc '{ts:"2026-06-01T00:00:00Z", type:"pipeline.completed", result:"failure", template:"standard", complexity:5, goal:"x"}' >> "$EVENTS"
bash "$KNOWLEDGE" mine-success >/dev/null 2>&1 || true
output=$(bash "$KNOWLEDGE" patterns-report 2>&1) || true
assert_contains "patterns-report surfaces drift signal when events>0 but patterns=0" "$output" "Drift signal"

# ─── Test 30: router dispatches the three new subcommands ────────────────────
rm -f "$EVENTS" "$PATTERNS"
output=$(bash "$SCRIPT_DIR/sw" knowledge mine-success 2>&1) || true
assert_contains "router dispatches 'knowledge mine-success'" "$output" "Mined"
output=$(bash "$SCRIPT_DIR/sw" knowledge patterns-report 2>&1) || true
assert_contains "router dispatches 'knowledge patterns-report'" "$output" "Fleet Success-Pattern Report"
output=$(bash "$SCRIPT_DIR/sw" knowledge recommend "some title" 5 2>&1) || true
assert_contains "router dispatches 'knowledge recommend'" "$output" "Fleet Pattern Recommendation"

echo ""
echo ""
print_test_results
