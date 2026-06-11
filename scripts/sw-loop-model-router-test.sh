#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop-model-router test — Real-time quality scoring &         ║
# ║  adaptive model downshift (issue #628)                                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
trap cleanup_test_env EXIT

echo ""
print_test_header "Shipwright Loop Model Router Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

# Isolate the routing artifact under the temp dir, then source the module.
export LMR_ROUTING_FILE="$TEST_TEMP_DIR/model-routing.jsonl"
# shellcheck source=lib/loop-model-router.sh
source "$SCRIPT_DIR/lib/loop-model-router.sh"

# Run lmr_decide WITHOUT a subshell so its streak/cooldown state mutations
# persist, then expose the decision via the global LMR_DECISION. Never wrap this
# in $(...) — that would discard the very state we need to assert on.
decide() { lmr_decide "$@" || true; }

# ─── Unit: quality scoring ─────────────────────────────────────────────────
echo -e "${BOLD}  Quality Scoring (lmr_quality_score)${RESET}"

# Perfect iteration: tests pass, small clean diff, flat errors, high convergence
score=$(lmr_quality_score true true 0 0 87 90)
assert_gt "high-quality iteration scores above downshift threshold (800)" "$score" "800"

# Test failure dominates → low score
score=$(lmr_quality_score false true 3 1 200 40)
assert_eq "failing tests produce a low score (200)" "200" "$score"

# Unknown test status is neutral, never biases toward downshift
score=$(lmr_quality_score "" "" 0 0 0 50)
[[ "$score" -le 800 ]] && assert_pass "unknown test status stays at/under downshift threshold" \
    || assert_fail "unknown test status stays at/under downshift threshold" "got: $score"

# Empty diff is penalized vs a healthy targeted diff (same other signals)
score_empty=$(lmr_quality_score true true 0 0 0 90)
score_clean=$(lmr_quality_score true true 0 0 87 90)
assert_gt "a targeted diff scores higher than an empty diff" "$score_clean" "$score_empty"

# Huge diff (thrash) is penalized vs a targeted diff
score_huge=$(lmr_quality_score true true 0 0 900 90)
assert_gt "a targeted diff scores higher than a huge (thrash) diff" "$score_clean" "$score_huge"

# Rising error count lowers the score vs flat errors
score_flat=$(lmr_quality_score true true 2 2 100 80)
score_rising=$(lmr_quality_score true true 6 2 100 80)
assert_gt "flat error count scores higher than rising error count" "$score_flat" "$score_rising"

# Composite folding: a valid composite enriches the score
score_comp=$(lmr_quality_score true true 0 0 50 80 85)
assert_gt "composite-folded score is a sane positive value" "$score_comp" "700"

# Score is clamped to [0,1000]
score=$(lmr_quality_score true true 0 0 50 100 100)
[[ "$score" -le 1000 ]] && assert_pass "score is clamped to <= 1000" || assert_fail "score clamp" "got: $score"

# Garbage inputs default conservatively (no crash, valid range)
score=$(lmr_quality_score true true abc xyz "" foo)
[[ "$score" -ge 0 && "$score" -le 1000 ]] && assert_pass "garbage inputs default to a valid score" \
    || assert_fail "garbage inputs default" "got: $score"

# ─── Unit: routing decisions ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Routing Decisions (lmr_decide)${RESET}"

# Disabled → always hold
ADAPTIVE_MODEL_ENABLED=false; HIGH_QUALITY_STREAK=0; MODEL_ROUTE_COOLDOWN=0
decide opus 950 5 true true 0 0; assert_eq "disabled flag forces hold" "hold" "$LMR_DECISION"

ADAPTIVE_MODEL_ENABLED=true

# Early-iteration guard: never route during iterations 1–2
HIGH_QUALITY_STREAK=0; MODEL_ROUTE_COOLDOWN=0
decide opus 950 1 true true 0 0; assert_eq "iteration 1 holds despite high score" "hold" "$LMR_DECISION"
decide opus 950 2 true true 0 0; assert_eq "iteration 2 holds despite high score" "hold" "$LMR_DECISION"

# Happy path: two consecutive high-quality iters → downshift on the second
HIGH_QUALITY_STREAK=0; MODEL_ROUTE_COOLDOWN=0
decide opus 850 3 true true 0 0
assert_eq "first high-quality iter holds (streak building)" "hold" "$LMR_DECISION"
assert_eq "streak reaches 1 after first high iter" "1" "$HIGH_QUALITY_STREAK"
decide opus 900 4 true true 0 0
assert_eq "second consecutive high-quality iter downshifts" "downshift" "$LMR_DECISION"
assert_eq "streak resets to 0 after downshift" "0" "$HIGH_QUALITY_STREAK"

# Upshift on low score (regardless of streak), only when on sonnet
HIGH_QUALITY_STREAK=2; MODEL_ROUTE_COOLDOWN=0
decide sonnet 400 5 true true 0 0
assert_eq "low score on sonnet upshifts" "upshift" "$LMR_DECISION"
assert_eq "upshift sets the cooldown" "2" "$MODEL_ROUTE_COOLDOWN"
assert_eq "upshift resets the streak" "0" "$HIGH_QUALITY_STREAK"

# Upshift on a test pass→fail regression even with a high score
HIGH_QUALITY_STREAK=0; MODEL_ROUTE_COOLDOWN=0
decide sonnet 850 5 false true 0 0
assert_eq "pass->fail regression on sonnet upshifts" "upshift" "$LMR_DECISION"

# On opus already, a degraded score holds (nothing higher to escalate to)
HIGH_QUALITY_STREAK=3; MODEL_ROUTE_COOLDOWN=0
decide opus 300 5 true true 0 0
assert_eq "low score on opus holds (no higher tier)" "hold" "$LMR_DECISION"
assert_eq "degraded opus iter resets the streak" "0" "$HIGH_QUALITY_STREAK"

# Rising errors block a downshift even with a high score
HIGH_QUALITY_STREAK=1; MODEL_ROUTE_COOLDOWN=0
decide opus 850 5 true true 5 3
assert_eq "rising error count blocks downshift" "hold" "$LMR_DECISION"

# Cooldown blocks an immediate re-downshift after an upshift (anti-thrash)
HIGH_QUALITY_STREAK=1; MODEL_ROUTE_COOLDOWN=2
decide opus 900 6 true true 0 0
assert_eq "cooldown blocks re-downshift (iter A)" "hold" "$LMR_DECISION"
assert_eq "cooldown decremented to 1" "1" "$MODEL_ROUTE_COOLDOWN"
decide opus 900 7 true true 0 0
assert_eq "cooldown blocks re-downshift (iter B)" "hold" "$LMR_DECISION"
assert_eq "cooldown decremented to 0" "0" "$MODEL_ROUTE_COOLDOWN"

# Boundary: score exactly 800 is NOT > 800 → no streak increment, hold
HIGH_QUALITY_STREAK=1; MODEL_ROUTE_COOLDOWN=0
decide opus 800 5 true true 0 0
assert_eq "score exactly 800 holds (strict >)" "hold" "$LMR_DECISION"
assert_eq "score exactly 800 resets streak (neutral band)" "0" "$HIGH_QUALITY_STREAK"

# Boundary: score exactly 500 is NOT < 500 → no upshift
HIGH_QUALITY_STREAK=0; MODEL_ROUTE_COOLDOWN=0
decide sonnet 500 5 true true 0 0
assert_eq "score exactly 500 holds (strict <)" "hold" "$LMR_DECISION"

# ─── Unit: model tier transitions (sw-model-router downshift_model) ─────────
echo ""
echo -e "${BOLD}  Model Tier Transitions (downshift_model / escalate)${RESET}"

assert_eq "downshift opus -> sonnet" "sonnet" "$(bash "$SCRIPT_DIR/sw-model-router.sh" downshift opus 2>&1)"
assert_eq "downshift sonnet -> sonnet (floor)" "sonnet" "$(bash "$SCRIPT_DIR/sw-model-router.sh" downshift sonnet 2>&1)"
assert_eq "downshift haiku -> haiku (floor)" "haiku" "$(bash "$SCRIPT_DIR/sw-model-router.sh" downshift haiku 2>&1)"
rc=0; out=$(bash "$SCRIPT_DIR/sw-model-router.sh" downshift bogus 2>&1) || rc=$?
assert_eq "downshift unknown model exits non-zero" "1" "$rc"
assert_contains "downshift unknown model errors" "$out" "Unknown model"
# Mirror: escalate still works (no regression)
assert_eq "escalate sonnet -> opus" "opus" "$(bash "$SCRIPT_DIR/sw-model-router.sh" escalate sonnet 2>&1)"

# ─── Integration: stateful multi-iteration sequence ────────────────────────
echo ""
echo -e "${BOLD}  Integration: multi-iteration sequence${RESET}"

# Simulate the loop applying decisions to MODEL across iterations.
ADAPTIVE_MODEL_ENABLED=true
HIGH_QUALITY_STREAK=0; MODEL_ROUTE_COOLDOWN=0
SIM_MODEL="opus"
apply_decision() {
    case "$1" in
        downshift) [[ "$SIM_MODEL" == "opus" ]]   && SIM_MODEL="sonnet" ;;
        upshift)   [[ "$SIM_MODEL" == "sonnet" ]] && SIM_MODEL="opus" ;;
    esac
}
# iters 1-2: locked to opus
for it in 1 2; do decide "$SIM_MODEL" 900 "$it" true true 0 0; apply_decision "$LMR_DECISION"; done
assert_eq "model stays opus through iterations 1-2" "opus" "$SIM_MODEL"
# iters 3-4: sustained high quality → downshift to sonnet by iter 4
for it in 3 4; do decide "$SIM_MODEL" 880 "$it" true true 0 0; apply_decision "$LMR_DECISION"; done
assert_eq "model downshifts to sonnet after 2 high-quality iters" "sonnet" "$SIM_MODEL"
# iter 5: regression on sonnet → upshift back to opus
decide "$SIM_MODEL" 850 5 false true 0 0; apply_decision "$LMR_DECISION"
assert_eq "model upshifts back to opus on regression" "opus" "$SIM_MODEL"

# ─── Integration: record + savings round-trip ──────────────────────────────
echo ""
echo -e "${BOLD}  Integration: logging & savings summary${RESET}"

rm -f "$LMR_ROUTING_FILE"
# No file yet → graceful n/a
assert_contains "savings summary handles missing file" "$(lmr_savings_summary)" "n/a"

lmr_record_iteration 1 opus 650 hold
lmr_record_iteration 2 opus 820 hold
lmr_record_iteration 3 sonnet 880 downshift
lmr_record_iteration 4 sonnet 900 hold

assert_eq "routing log has one line per iteration" "4" "$(wc -l < "$LMR_ROUTING_FILE" | tr -d ' ')"
if command -v jq >/dev/null 2>&1; then
    last_decision=$(tail -1 "$LMR_ROUTING_FILE" | jq -r '.decision')
    assert_eq "last logged decision is recorded" "hold" "$last_decision"
    norm=$(tail -1 "$LMR_ROUTING_FILE" | jq -r '.score_normalized')
    assert_eq "normalized score is milli/1000" "0.9" "$norm"
fi

summary=$(lmr_savings_summary)
assert_contains "savings summary reports the model mix" "$summary" "2 opus / 2 sonnet"
assert_contains "savings summary reports an estimate" "$summary" "savings ~40%"

# All-opus → zero savings
rm -f "$LMR_ROUTING_FILE"
lmr_record_iteration 1 opus 700 hold
lmr_record_iteration 2 opus 700 hold
assert_contains "all-opus run reports ~0% savings" "$(lmr_savings_summary)" "savings ~0%"

# ─── Integration: flag plumbing in sw-loop.sh ──────────────────────────────
echo ""
echo -e "${BOLD}  Integration: sw-loop.sh flag plumbing${RESET}"

# The loop must accept --adaptive-model without erroring at parse time.
loop_help=$(bash "$SCRIPT_DIR/sw-loop.sh" --help 2>&1 || true)
assert_contains "sw-loop.sh references --adaptive-model" "$loop_help" "adaptive-model"

echo ""
echo ""
print_test_results
