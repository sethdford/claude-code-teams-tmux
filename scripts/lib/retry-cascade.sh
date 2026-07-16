#!/usr/bin/env bash
# Module: retry-cascade
# Cost-aware model retry cascade for failed pipeline stages.
#
# When a stage fails, this library decides whether to retry it with a more
# capable (but more expensive) model from a configured cascade. It provides
# pure decision functions — classification, budget pre-flight, circuit
# breaker, and cascade ordering — that the pipeline execution seam
# (run_stage_with_retry) calls on failure. It never invokes `claude` itself
# and never writes cost files directly (that stays with sw-cost.sh's atomic
# path); it only reads config/state and returns decisions.
#
# Bash 3.2 compatible: no associative arrays, no readarray, no ${var,,}.
# Float math via awk (repo idiom), never bc.
VERSION="1.0.0"

# Module guard
[[ -n "${_MODULE_RETRY_CASCADE_LOADED:-}" ]] && return 0
_MODULE_RETRY_CASCADE_LOADED=1

# ─── Defaults / paths (safe when sourced independently) ──────────────────────
_RC_SCRIPT_DIR="${_RC_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$_RC_SCRIPT_DIR/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.claude}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$STATE_DIR/pipeline-artifacts}"

# Failure pattern database (overridable for tests / per-repo).
RETRY_CASCADE_PATTERNS_FILE="${RETRY_CASCADE_PATTERNS_FILE:-$REPO_DIR/config/failure-patterns.json}"

# Per-cascade attempt ledger (flat TSV — no associative arrays).
# Columns: stage \t model \t epoch \t cost_usd
RETRY_CASCADE_ATTEMPTS_FILE="${RETRY_CASCADE_ATTEMPTS_FILE:-$ARTIFACTS_DIR/cascade-attempts.tsv}"

# Ensure minimal helpers exist when sourced standalone.
[[ "$(type -t info 2>/dev/null)" == "function" ]] || info() { echo "$*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]] || warn() { echo "$*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }

# ─── Config accessors ────────────────────────────────────────────────────────

# cascade_enabled -> exit 0 if retry_cascade.enabled is true (default: off)
cascade_enabled() {
    local v
    if type _smart_int >/dev/null 2>&1; then
        v=$(_smart_int "retry_cascade.enabled" "false")
    else
        local cfg="${DAEMON_CONFIG:-$STATE_DIR/daemon-config.json}"
        v=$(jq -r '.retry_cascade.enabled // false' "$cfg" 2>/dev/null || echo "false")
    fi
    [[ "$v" == "true" || "$v" == "1" ]]
}

# cascade_model_order [stage] -> space-separated model order
# Uses per_stage_overrides.<stage>.model_order when present, else the global
# model_order, else the default haiku sonnet opus.
cascade_model_order() {
    local stage="${1:-}"
    local cfg="${DAEMON_CONFIG:-$STATE_DIR/daemon-config.json}"
    local order=""

    if [[ -n "$stage" && -f "$cfg" ]]; then
        order=$(jq -r --arg s "$stage" \
            '(.retry_cascade.per_stage_overrides[$s].model_order // []) | join(" ")' \
            "$cfg" 2>/dev/null || true)
    fi
    if [[ -z "$order" && -f "$cfg" ]]; then
        order=$(jq -r '(.retry_cascade.model_order // []) | join(" ")' "$cfg" 2>/dev/null || true)
    fi
    if [[ -z "$order" ]]; then
        order="haiku sonnet opus"
    fi
    echo "$order"
}

# cascade_models_after <stage> <currentModel> -> models strictly AFTER current
# in the cascade order. A stage already on the last model yields an empty list,
# so the cascade never retries "downward" or sideways.
cascade_models_after() {
    local stage="$1" current="$2"
    local order after="" seen_current=0 m
    order=$(cascade_model_order "$stage")

    # Normalize current model alias (claude-opus-4* -> opus, etc.)
    current=$(_cascade_normalize_model "$current")

    for m in $order; do
        if [[ "$seen_current" -eq 1 ]]; then
            after="$after $m"
        fi
        [[ "$(_cascade_normalize_model "$m")" == "$current" ]] && seen_current=1
    done

    # If the current model was never found in the order, the whole order is a
    # valid escalation set (current ran on something outside the cascade).
    if [[ "$seen_current" -eq 0 ]]; then
        after="$order"
    fi

    echo "$after" | xargs 2>/dev/null || echo "$after"
}

# _cascade_normalize_model <model> -> canonical short name (haiku/sonnet/opus/…)
_cascade_normalize_model() {
    local m="$1"
    case "$m" in
        opus|claude-opus-*)   echo "opus" ;;
        sonnet|claude-sonnet-*) echo "sonnet" ;;
        haiku|claude-haiku-*) echo "haiku" ;;
        *) echo "$m" ;;
    esac
}

# ─── Failure classification ──────────────────────────────────────────────────

# cascade_classify_failure <errorOutput> [exitCode]
# -> stdout "retryable" | "non-retryable"; always exit 0.
# Non-retryable patterns are checked first and win. If the patterns file is
# missing, defaults to "retryable" (+ warn) so a misconfigured repo does not
# silently suppress legitimate retries. When the file exists but nothing
# matches, defaults to "non-retryable" (budget-safe: don't cascade on an
# unrecognized error).
cascade_classify_failure() {
    local output="${1:-}"
    # exitCode ($2) reserved for future use; classification is text-driven today.

    if [[ ! -f "$RETRY_CASCADE_PATTERNS_FILE" ]]; then
        warn "retry-cascade: patterns file not found ($RETRY_CASCADE_PATTERNS_FILE) — defaulting to retryable"
        echo "retryable"
        return 0
    fi

    local non_retryable retryable
    non_retryable=$(jq -r '[.non_retryable[].pattern] | join("|")' "$RETRY_CASCADE_PATTERNS_FILE" 2>/dev/null || echo "")
    retryable=$(jq -r '[.retryable[].pattern] | join("|")' "$RETRY_CASCADE_PATTERNS_FILE" 2>/dev/null || echo "")

    if [[ -n "$non_retryable" ]] && printf '%s' "$output" | grep -qiE "$non_retryable" 2>/dev/null; then
        echo "non-retryable"
        return 0
    fi
    if [[ -n "$retryable" ]] && printf '%s' "$output" | grep -qiE "$retryable" 2>/dev/null; then
        echo "retryable"
        return 0
    fi

    # Recognized nothing — do not spend budget cascading on an unknown error.
    echo "non-retryable"
    return 0
}

# ─── Budget pre-flight ───────────────────────────────────────────────────────

# _cascade_per_stage_cap <stage> -> float dollar cap for one stage's cascade
_cascade_per_stage_cap() {
    local stage="$1"
    local cfg="${DAEMON_CONFIG:-$STATE_DIR/daemon-config.json}"
    local cap=""

    if [[ -n "$stage" && -f "$cfg" ]]; then
        cap=$(jq -r --arg s "$stage" \
            '.retry_cascade.per_stage_overrides[$s].max_cascade_cost_per_stage_usd // empty' \
            "$cfg" 2>/dev/null || true)
    fi
    if [[ -z "$cap" || "$cap" == "null" ]]; then
        if type _smart_float >/dev/null 2>&1; then
            cap=$(_smart_float "retry_cascade.max_cascade_cost_per_stage_usd" "5.0")
        else
            cap=$(jq -r '.retry_cascade.max_cascade_cost_per_stage_usd // 5.0' "$cfg" 2>/dev/null || echo "5.0")
        fi
    fi
    echo "$cap"
}

# cascade_stage_spent <stage> -> total cost already spent this cascade for stage
cascade_stage_spent() {
    local stage="$1"
    [[ -f "$RETRY_CASCADE_ATTEMPTS_FILE" ]] || { echo "0"; return; }
    awk -F'\t' -v s="$stage" \
        'BEGIN{t=0} $1==s {t+=$4} END{printf "%.4f", t}' \
        "$RETRY_CASCADE_ATTEMPTS_FILE" 2>/dev/null || echo "0"
}

# cascade_budget_ok <stage> <model> <estimatedCostUsd> -> exit 0 ok | 1 exceed
# Checks BEFORE the attempt: (spent_so_far + estimate) must stay within BOTH
# the per-stage cap and the global remaining daily budget.
cascade_budget_ok() {
    local stage="$1" model="$2" estimate="${3:-0}"
    local cap spent projected
    cap=$(_cascade_per_stage_cap "$stage")
    spent=$(cascade_stage_spent "$stage")

    # Guard against non-numeric inputs.
    [[ "$estimate" =~ ^-?[0-9]*\.?[0-9]+$ ]] || estimate="0"
    [[ "$cap" =~ ^-?[0-9]*\.?[0-9]+$ ]] || cap="5.0"

    projected=$(awk -v a="$spent" -v b="$estimate" 'BEGIN{printf "%.4f", a+b}')

    # Per-stage cap check.
    if awk -v p="$projected" -v c="$cap" 'BEGIN{exit !(p > c)}'; then
        return 1
    fi

    # Global remaining budget check (skip when unlimited/unconfigured).
    if type cost_remaining_budget >/dev/null 2>&1; then
        local remaining
        remaining=$(cost_remaining_budget 2>/dev/null || echo "unlimited")
        if [[ "$remaining" != "unlimited" && "$remaining" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
            if awk -v e="$estimate" -v r="$remaining" 'BEGIN{exit !(e > r)}'; then
                return 1
            fi
        fi
    fi

    return 0
}

# cascade_estimate_cost <stage> <model> -> estimated USD for a (stage, model)
# attempt. Prefers historical average from ~/.shipwright/costs.json for that
# (stage, model); falls back to a per-model constant so the budget guard is
# never seeded with a meaningless flat estimate.
cascade_estimate_cost() {
    local stage="$1" model="$2"
    local norm cost_file est=""
    norm=$(_cascade_normalize_model "$model")
    cost_file="${COST_FILE:-${HOME}/.shipwright/costs.json}"

    if [[ -f "$cost_file" ]]; then
        est=$(jq -r --arg s "$stage" --arg m "$norm" '
            [.entries[]?
             | select((.stage == $s) and ((.model // "") | test($m)))
             | .cost_usd] as $c
            | if ($c | length) > 0 then ($c | add / ($c | length)) else empty end' \
            "$cost_file" 2>/dev/null || true)
    fi

    if [[ -n "$est" && "$est" != "null" && "$est" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        printf "%.4f" "$est"
        return
    fi

    # Per-model fallback estimate (rough single-attempt cost).
    case "$norm" in
        opus)   echo "0.5000" ;;
        sonnet) echo "0.1500" ;;
        haiku)  echo "0.0200" ;;
        *)      echo "0.1500" ;;
    esac
}

# ─── Circuit breaker (flat-file counter, no associative arrays) ───────────────

# _cascade_circuit_threshold -> int failures before a stage:model is blocked
_cascade_circuit_threshold() {
    if type _smart_int >/dev/null 2>&1; then
        _smart_int "retry_cascade.circuit_breaker_threshold" "3"
    else
        local cfg="${DAEMON_CONFIG:-$STATE_DIR/daemon-config.json}"
        jq -r '.retry_cascade.circuit_breaker_threshold // 3' "$cfg" 2>/dev/null || echo "3"
    fi
}

# cascade_circuit_open <stage> <model> -> exit 0 tripped | 1 ok
cascade_circuit_open() {
    local stage="$1" model="$2" threshold count
    threshold=$(_cascade_circuit_threshold)
    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
    [[ -f "$RETRY_CASCADE_ATTEMPTS_FILE" ]] || return 1

    count=$(awk -F'\t' -v s="$stage" -v m="$model" \
        'BEGIN{n=0} $1==s && $2==m {n++} END{print n}' \
        "$RETRY_CASCADE_ATTEMPTS_FILE" 2>/dev/null || echo "0")
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    [[ "$count" -ge "$threshold" ]]
}

# cascade_record_attempt <stage> <model> [cost_usd]
# Appends one row to the attempt ledger. Cost writes to the real cost files
# stay with sw-cost.sh's cost_record; this ledger is cascade-local state only.
cascade_record_attempt() {
    local stage="$1" model="$2" cost="${3:-0}"
    [[ "$cost" =~ ^-?[0-9]*\.?[0-9]+$ ]] || cost="0"
    mkdir -p "$(dirname "$RETRY_CASCADE_ATTEMPTS_FILE")" 2>/dev/null || true
    local epoch
    epoch=$(date -u +%s 2>/dev/null || echo "0")
    printf '%s\t%s\t%s\t%s\n' "$stage" "$model" "$epoch" "$cost" \
        >> "$RETRY_CASCADE_ATTEMPTS_FILE" 2>/dev/null || true
}

# ─── Orchestration seam ──────────────────────────────────────────────────────

# cascade_next_model <stage> <retryAttempt> <errorOutput> [exitCode]
# The single decision function the pipeline's run_stage_with_retry calls on a
# stage failure. On success it echoes the model to use for the retry (exit 0)
# and records the attempt in the cascade ledger. Otherwise it echoes nothing and
# returns a distinct code so the caller can emit a precise event:
#   10 = cascade disabled            (fall through to normal retry logic)
#   11 = failure is non-retryable    (caller should fail fast)
#   12 = model order exhausted       (no further model to escalate to)
#   13 = circuit breaker open        (this stage:model has failed too often)
#   14 = budget would be exceeded    (caller should stop cascading)
#
# retryAttempt is 1-based (first retry = 1) and indexes directly into the
# configured model_order, so the initial attempt implicitly used order[0] (the
# cheapest model) and each retry escalates one step. Configure model_order
# cheapest-first (default: haiku sonnet opus) for cost-aware escalation.
cascade_next_model() {
    local stage="$1" attempt="$2" err="${3:-}" code="${4:-1}"

    cascade_enabled || return 10

    if [[ "$(cascade_classify_failure "$err" "$code")" != "retryable" ]]; then
        return 11
    fi

    # Select the attempt-th model (0-based) from the configured order.
    local order model="" idx=0 m
    order=$(cascade_model_order "$stage")
    for m in $order; do
        if [[ "$idx" -eq "$attempt" ]]; then
            model="$m"
            break
        fi
        idx=$((idx + 1))
    done
    [[ -n "$model" ]] || return 12

    cascade_circuit_open "$stage" "$model" && return 13

    local est
    est=$(cascade_estimate_cost "$stage" "$model")
    cascade_budget_ok "$stage" "$model" "$est" || return 14

    cascade_record_attempt "$stage" "$model" "$est"
    echo "$model"
    return 0
}

# cascade_reset [stage]
# Clears the attempt ledger for a fresh cascade. With a stage arg, removes only
# that stage's rows; otherwise truncates the whole ledger.
cascade_reset() {
    local stage="${1:-}"
    [[ -f "$RETRY_CASCADE_ATTEMPTS_FILE" ]] || return 0
    if [[ -z "$stage" ]]; then
        : > "$RETRY_CASCADE_ATTEMPTS_FILE" 2>/dev/null || true
        return 0
    fi
    local tmp
    tmp=$(mktemp "${RETRY_CASCADE_ATTEMPTS_FILE}.tmp.XXXXXX" 2>/dev/null) || return 0
    awk -F'\t' -v s="$stage" '$1!=s' "$RETRY_CASCADE_ATTEMPTS_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$RETRY_CASCADE_ATTEMPTS_FILE" 2>/dev/null || rm -f "$tmp"
}
