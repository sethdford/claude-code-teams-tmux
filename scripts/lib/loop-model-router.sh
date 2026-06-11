#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_LOOP_MODEL_ROUTER_LOADED:-}" ]] && return 0
_LOOP_MODEL_ROUTER_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop-model-router — Real-Time Quality Scoring & Adaptive     ║
# ║  Model Downshift for the build loop.                                     ║
# ║                                                                          ║
# ║  Consumes the per-iteration signals (test result, diff size, error      ║
# ║  count trend, convergence, and the optional process-reward composite)   ║
# ║  to produce a normalized 0–1000 milli-quality-score, then decides        ║
# ║  whether to downshift Opus→Sonnet (sustained high quality) or upshift    ║
# ║  Sonnet→Opus (quality degradation). Pure bash + jq — no extra LLM call.  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="3.3.0"

# This module is meant to be sourced, not executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "loop-model-router.sh is a library — source it, don't execute it." >&2
    exit 1
fi

# ─── Minimal output helper fallbacks (when sourced standalone) ───────────────
[[ "$(type -t warn 2>/dev/null)" == "function" ]]  || warn()  { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*" >&2; }
[[ "$(type -t error 2>/dev/null)" == "function" ]] || error() { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
    now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi

# ─── Tunable thresholds (config-chain via _smart_int when available) ─────────
# All scores are integer milli-scores in [0, 1000]; 0.8 == 800, 0.5 == 500.
_lmr_threshold() {
    local key="$1" default="$2"
    if [[ "$(type -t _smart_int 2>/dev/null)" == "function" ]]; then
        _smart_int "$key" "$default"
    else
        echo "$default"
    fi
}

# Default routing file (append-only artifact, safe to delete)
LMR_ROUTING_FILE="${LMR_ROUTING_FILE:-.claude/pipeline-artifacts/model-routing.jsonl}"

# ─── Quality Scoring ─────────────────────────────────────────────────────────
# lmr_quality_score <test_passed> <prev_test_passed> <error_count> \
#                   <prev_error_count> <diff_lines> <convergence_0_100> [composite_0_100]
#
# Maps the iteration signals into a normalized 0–1000 milli-score. Every named
# input (test result, diff size, error count, convergence) always influences the
# result. When a valid process-reward composite (0–100) is supplied, it is blended
# equally with the explicit-signal score so the richer composite enriches — but
# never replaces — the diff/error/convergence guards.
#
# Weighting of the explicit-signal blend: test 45%, convergence 25%,
# error-trend 20%, diff-sanity 10%.
lmr_quality_score() {
    local test_passed="${1:-}"
    local prev_test_passed="${2:-}"   # reserved for callers; trend handled by error/score guards
    local error_count="${3:-0}"
    local prev_error_count="${4:-0}"
    local diff_lines="${5:-0}"
    local convergence="${6:-50}"      # 0–100
    local composite="${7:-}"          # 0–100, optional

    # Default any non-integer inputs conservatively
    [[ "$error_count"      =~ ^[0-9]+$ ]] || error_count=0
    [[ "$prev_error_count" =~ ^[0-9]+$ ]] || prev_error_count=0
    [[ "$diff_lines"       =~ ^[0-9]+$ ]] || diff_lines=0
    [[ "$convergence"      =~ ^[0-9]+$ ]] || convergence=50
    [[ "$convergence" -gt 100 ]] && convergence=100

    # 1. Test signal (milli)
    local test_milli
    if [[ "$test_passed" == "true" ]]; then
        test_milli=1000
    elif [[ "$test_passed" == "false" ]]; then
        test_milli=0
    else
        test_milli=500   # unknown — neutral, never biases toward downshift
    fi

    # 2. Convergence signal (milli)
    local conv_milli=$(( convergence * 10 ))

    # 3. Error-trend signal (milli): reward flat/declining error counts,
    #    penalize rising error counts proportional to the prior count.
    local err_milli
    local err_delta=$(( error_count - prev_error_count ))
    if [[ "$err_delta" -le 0 ]]; then
        err_milli=1000
    else
        local denom=$prev_error_count
        [[ "$denom" -lt 1 ]] && denom=1
        local penalty=$(( err_delta * 1000 / denom ))
        err_milli=$(( 1000 - penalty ))
        [[ "$err_milli" -lt 0 ]] && err_milli=0
    fi

    # 4. Diff-sanity signal (milli): 0-line diffs (no progress) and very large
    #    diffs (>800 lines, likely thrash/refactor) are both penalized.
    local diff_milli
    if [[ "$diff_lines" -eq 0 ]]; then
        diff_milli=300
    elif [[ "$diff_lines" -gt 800 ]]; then
        diff_milli=200
    else
        diff_milli=1000
    fi

    # Weighted explicit-signal blend
    local signal_blend=$(( (test_milli * 45 + conv_milli * 25 + err_milli * 20 + diff_milli * 10) / 100 ))

    # Fold in the process-reward composite when it is a valid 0–100 integer
    local score
    if [[ "$composite" =~ ^[0-9]+$ ]] && [[ "$composite" -ge 0 ]] && [[ "$composite" -le 100 ]]; then
        score=$(( (composite * 10 + signal_blend) / 2 ))
    else
        score=$signal_blend
    fi

    [[ "$score" -lt 0 ]] && score=0
    [[ "$score" -gt 1000 ]] && score=1000
    echo "$score"
}

# ─── Routing Decision ────────────────────────────────────────────────────────
# lmr_decide <current_model> <score_milli> <iteration> \
#            <test_passed> <prev_test_passed> <error_count> <prev_error_count>
#
# Sets the global LMR_DECISION to one of: downshift | upshift | hold.
# Also mutates the routing state globals HIGH_QUALITY_STREAK and
# MODEL_ROUTE_COOLDOWN. IMPORTANT: this function does NOT echo its result and
# must be called WITHOUT command substitution — `$(lmr_decide ...)` would run it
# in a subshell and silently discard the streak/cooldown state mutations. Read
# LMR_DECISION after calling.
#
# Reads ADAPTIVE_MODEL_ENABLED (must be "true" to ever route).
#
# Guard order (safety first): disabled → early-iteration → upshift-dominates →
# rising-errors → cooldown → sustained-high-quality downshift → neutral hold.
lmr_decide() {
    local current_model="${1:-opus}"
    local score="${2:-500}"
    local iteration="${3:-1}"
    local test_passed="${4:-}"
    local prev_test_passed="${5:-}"
    local error_count="${6:-0}"
    local prev_error_count="${7:-0}"

    [[ "$score"           =~ ^[0-9]+$ ]] || score=500
    [[ "$iteration"       =~ ^[0-9]+$ ]] || iteration=1
    [[ "$error_count"      =~ ^[0-9]+$ ]] || error_count=0
    [[ "$prev_error_count" =~ ^[0-9]+$ ]] || prev_error_count=0

    HIGH_QUALITY_STREAK="${HIGH_QUALITY_STREAK:-0}"
    MODEL_ROUTE_COOLDOWN="${MODEL_ROUTE_COOLDOWN:-0}"
    LMR_DECISION="hold"

    local downshift_score upshift_score cooldown_len
    downshift_score=$(_lmr_threshold "loop.downshift_score" 800)
    upshift_score=$(_lmr_threshold "loop.upshift_score" 500)
    cooldown_len=$(_lmr_threshold "loop.route_cooldown" 2)

    # 1. Disabled → never route
    if [[ "${ADAPTIVE_MODEL_ENABLED:-false}" != "true" ]]; then
        LMR_DECISION="hold"; return 0
    fi

    # 2. Never route during the first two iterations
    if [[ "$iteration" -le 2 ]]; then
        LMR_DECISION="hold"; return 0
    fi

    # 3. Upshift dominates — degradation forces an immediate, sticky escalation.
    local regressed=false
    [[ "$prev_test_passed" == "true" && "$test_passed" == "false" ]] && regressed=true
    if [[ "$score" -lt "$upshift_score" ]] || [[ "$regressed" == "true" ]]; then
        HIGH_QUALITY_STREAK=0
        if [[ "$current_model" == "sonnet" ]]; then
            MODEL_ROUTE_COOLDOWN=$cooldown_len
            LMR_DECISION="upshift"; return 0
        fi
        # Already on opus (or other) — nothing higher to escalate to
        LMR_DECISION="hold"; return 0
    fi

    # 4. Errors rising → never downshift on uncertain footing
    if [[ "$error_count" -gt "$prev_error_count" ]]; then
        LMR_DECISION="hold"; return 0
    fi

    # 5. Cooldown after a recent upshift blocks immediate re-downshift (anti-thrash)
    if [[ "$MODEL_ROUTE_COOLDOWN" -gt 0 ]]; then
        MODEL_ROUTE_COOLDOWN=$(( MODEL_ROUTE_COOLDOWN - 1 ))
        LMR_DECISION="hold"; return 0
    fi

    # 6. Sustained high quality → downshift after 2 consecutive high-score iters
    if [[ "$score" -gt "$downshift_score" ]]; then
        HIGH_QUALITY_STREAK=$(( HIGH_QUALITY_STREAK + 1 ))
        if [[ "$HIGH_QUALITY_STREAK" -ge 2 ]] && [[ "$current_model" == "opus" ]]; then
            HIGH_QUALITY_STREAK=0
            LMR_DECISION="downshift"; return 0
        fi
        LMR_DECISION="hold"; return 0
    fi

    # 7. Neutral band (upshift_score ≤ score ≤ downshift_score) → reset streak, hold
    HIGH_QUALITY_STREAK=0
    LMR_DECISION="hold"; return 0
}

# ─── Per-Iteration Logging ───────────────────────────────────────────────────
# lmr_record_iteration <iteration> <model> <score_milli> <decision> [routing_file]
lmr_record_iteration() {
    local iteration="${1:-0}"
    local model="${2:-unknown}"
    local score="${3:-0}"
    local decision="${4:-hold}"
    local routing_file="${5:-$LMR_ROUTING_FILE}"

    [[ "$iteration" =~ ^[0-9]+$ ]] || iteration=0
    [[ "$score"     =~ ^[0-9]+$ ]] || score=0

    local routing_dir
    routing_dir=$(dirname "$routing_file")
    mkdir -p "$routing_dir" 2>/dev/null || true

    if ! command -v jq >/dev/null 2>&1; then
        warn "loop-model-router: jq unavailable — skipping routing log"
        return 1
    fi

    local record
    record=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --argjson iter "$iteration" \
        --arg model "$model" \
        --argjson score "$score" \
        --arg decision "$decision" \
        '{timestamp: $ts, iteration: $iter, model: $model, score: $score, score_normalized: (($score|tonumber)/1000), decision: $decision}' 2>/dev/null)

    if [[ -z "$record" ]]; then
        warn "loop-model-router: failed to build routing record"
        return 1
    fi

    # Atomic append via temp file + mv
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/model-routing-$$.tmp")
    if [[ -f "$routing_file" ]]; then
        cat "$routing_file" > "$tmp_file"
    fi
    echo "$record" >> "$tmp_file"
    mv "$tmp_file" "$routing_file"
}

# ─── Savings Summary ─────────────────────────────────────────────────────────
# lmr_savings_summary [routing_file]
# Reads the routing JSONL and estimates cost savings vs an all-opus baseline.
# Sonnet is assumed to cost LMR_SONNET_COST_PCT% of opus per iteration.
lmr_savings_summary() {
    local routing_file="${1:-$LMR_ROUTING_FILE}"
    local sonnet_pct="${LMR_SONNET_COST_PCT:-20}"

    if [[ ! -f "$routing_file" ]] || ! command -v jq >/dev/null 2>&1; then
        echo "Model mix: n/a"
        return 0
    fi

    local opus_iters sonnet_iters other_iters total
    opus_iters=$(jq -r 'select(.model=="opus")   | .iteration' "$routing_file" 2>/dev/null | wc -l | tr -d ' ')
    sonnet_iters=$(jq -r 'select(.model=="sonnet") | .iteration' "$routing_file" 2>/dev/null | wc -l | tr -d ' ')
    other_iters=$(jq -r 'select(.model!="opus" and .model!="sonnet") | .iteration' "$routing_file" 2>/dev/null | wc -l | tr -d ' ')
    opus_iters="${opus_iters:-0}"; sonnet_iters="${sonnet_iters:-0}"; other_iters="${other_iters:-0}"
    total=$(( opus_iters + sonnet_iters + other_iters ))

    if [[ "$total" -eq 0 ]]; then
        echo "Model mix: n/a"
        return 0
    fi

    # Savings% = sonnet_iters * (100 - sonnet_pct) / total
    local savings_pct=$(( sonnet_iters * (100 - sonnet_pct) / total ))

    local mix="${opus_iters} opus / ${sonnet_iters} sonnet"
    [[ "$other_iters" -gt 0 ]] && mix="${mix} / ${other_iters} other"
    echo "Model mix: ${mix}  •  est. savings ~${savings_pct}%"
}
