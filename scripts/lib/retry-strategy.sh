#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_RETRY_STRATEGY_LOADED:-}" ]] && return 0
_RETRY_STRATEGY_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright retry-strategy — Intelligent Retry Decision Engine           ║
# ║  Classify failure → consult memory → emit decision (action+confidence)  ║
# ║  4 categories: recoverable-transient / recoverable-escalation /         ║
# ║                context-exhausted / unrecoverable                        ║
# ║  Ladder: same model → sonnet → opus → session-restart → human           ║
# ║  Near-pure: only side effect is appending a retry.decision event.       ║
# ║  Reuses recovery_classify_error / memory_query_fix_for_error when loaded.║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="3.3.0"

# ─── Output Helpers (defensive fallbacks) ─────────────────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

# ─── Configuration ────────────────────────────────────────────────────────────
RETRY_STRATEGY_CONFIG="${RETRY_STRATEGY_CONFIG:-.claude/daemon-config.json}"
RETRY_METRICS_FILE="${RETRY_METRICS_FILE:-.claude/pipeline-artifacts/retry-metrics.jsonl}"

# Read a retry_strategy.* config value (env handled by callers): config → default.
_retry_cfg() {
    local key="$1" def="$2" v=""
    if [[ -f "$RETRY_STRATEGY_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        v=$(jq -r --arg k "$key" '.retry_strategy[$k] // empty' "$RETRY_STRATEGY_CONFIG" 2>/dev/null || true)
    fi
    echo "${v:-$def}"
}

# Model escalation ladder (comma-separated). Terminal rungs (session-restart,
# human) are appended automatically by retry_escalation_target.
RETRY_MODEL_LADDER="${RETRY_MODEL_LADDER:-$(_retry_cfg model_ladder "sonnet,opus")}"

# Minimum confidence (integer 0-100) to keep retrying a non-transient failure.
if [[ -z "${RETRY_MIN_CONFIDENCE_INT:-}" ]]; then
    _retry_mc=$(_retry_cfg min_confidence_to_retry "0.3")
    RETRY_MIN_CONFIDENCE_INT=$(awk -v x="$_retry_mc" 'BEGIN{printf "%d", (x*100)}' 2>/dev/null || echo 30)
    [[ "$RETRY_MIN_CONFIDENCE_INT" =~ ^[0-9]+$ ]] || RETRY_MIN_CONFIDENCE_INT=30
fi

# ─── Category Mapping (fine-grained → 4 mandated categories) ──────────────────
# Maps the fine-grained category from recovery_classify_error / classify_failure
# into exactly one of the four mandated retry categories.
retry_category_of() {
    case "${1:-unknown}" in
        network_error|api_error|timeout|lock_error|rate_limit)
            echo "recoverable-transient" ;;
        context_exhaustion)
            echo "context-exhausted" ;;
        auth_error|permission_error|invalid_issue)
            echo "unrecoverable" ;;
        resource_error|test_assertion|build_error|build_failure|type_error|syntax_error|import_error|null_reference|lint_error|deprecation_error)
            echo "recoverable-escalation" ;;
        *)
            # unknown / unrecognized → conservative escalation (try harder before giving up)
            echo "recoverable-escalation" ;;
    esac
}

# ─── Fine-grained Classification ──────────────────────────────────────────────
# Returns a fine-grained category. Detects context-exhaustion first (neither
# delegate emits it reliably from text), then delegates to recovery_classify_error
# when available, else falls back to a self-contained grep classifier.
retry_classify() {
    local error_text="${1:-}"
    [[ -z "$error_text" ]] && { echo "unknown"; return 0; }

    local lower
    lower=$(echo "$error_text" | tr '[:upper:]' '[:lower:]')

    # Context exhaustion — checked first; not produced by the delegates from text.
    if echo "$lower" | grep -qE '(context.*exhaust|context.*window|context.*limit|context_exhaustion|max.*iterations|iteration.*exhaust|out of context|prompt too long|token limit exceeded|exceeds.*context)'; then
        echo "context_exhaustion"
        return 0
    fi

    # Delegate to the richer auto-recovery classifier when it is loaded.
    if type recovery_classify_error >/dev/null 2>&1; then
        recovery_classify_error "$error_text"
        return 0
    fi

    # Self-contained fallback (keeps the lib usable in isolation / unit tests).
    if echo "$lower" | grep -qE '(rate limit|429|503|502|overloaded|timeout|timed out|econnreset|socket hang up|network|connection refused|enotfound|deadline exceeded)'; then
        echo "network_error"
    elif echo "$lower" | grep -qE '(not logged in|unauthorized|auth.*fail|401|403|invalid.*token|permission denied|forbidden|eacces)'; then
        echo "permission_error"
    elif echo "$lower" | grep -qE '(out of memory|heap|oom|enomem|segfault|sigsegv|memory limit)'; then
        echo "resource_error"
    elif echo "$lower" | grep -qE '(syntax error|unexpected token|parse error|unterminated)'; then
        echo "syntax_error"
    elif echo "$lower" | grep -qE '(type error|is not assignable|cannot find name|type.*is not)'; then
        echo "type_error"
    elif echo "$lower" | grep -qE '(module not found|cannot find module|no such file|import error)'; then
        echo "import_error"
    elif echo "$lower" | grep -qE '(assert|expect|to equal|to be|mismatch|not equal)'; then
        echo "test_assertion"
    elif echo "$lower" | grep -qE '(build|compile|linker|undefined reference|unresolved)'; then
        echo "build_error"
    elif echo "$lower" | grep -qE '(lint|eslint|prettier|format|style)'; then
        echo "lint_error"
    else
        echo "unknown"
    fi
}

# ─── Memory Lookup ────────────────────────────────────────────────────────────
# Guarded wrapper over memory_query_fix_for_error. Returns the best-fix JSON
# (fix, fix_effectiveness_rate, category, ...) or empty. Never errors.
retry_memory_lookup() {
    local error_text="${1:-}"
    [[ -z "$error_text" ]] && return 0
    type memory_query_fix_for_error >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local result
    result=$(memory_query_fix_for_error "$error_text" 2>/dev/null) || true
    [[ -z "$result" || "$result" == "null" ]] && return 0
    echo "$result"
}

# ─── Confidence Scoring (bash-safe integer math) ──────────────────────────────
# Internal: returns an integer in [5, 99].
_retry_confidence_int() {
    local fine="${1:-unknown}" mem_rate="${2:-0}" attempt="${3:-1}" max="${4:-3}"
    local v
    if [[ "$fine" == "unknown" ]]; then v=30; else v=70; fi
    [[ "$mem_rate" =~ ^[0-9]+$ ]] || mem_rate=0
    [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=1
    [[ "$max" =~ ^[0-9]+$ ]] || max=3
    # Memory match with a track record raises confidence.
    [[ "$mem_rate" -gt 50 ]] && v=$((v + 20))
    # Diminishing returns near/at the attempt budget.
    [[ "$attempt" -ge "$max" ]] && v=$((v - 20))
    [[ "$v" -lt 5 ]] && v=5
    [[ "$v" -gt 99 ]] && v=99
    echo "$v"
}

# Public: returns confidence formatted as "0.NN" (always < 1.00).
retry_compute_confidence() {
    local v
    v=$(_retry_confidence_int "$@")
    printf '0.%02d\n' "$v"
}

# ─── Escalation Ladder ────────────────────────────────────────────────────────
# Given the current model and attempt, returns the next rung:
#   <next model in ladder> → session-restart → human (terminal).
# Bounded by the ladder length so it always terminates.
retry_escalation_target() {
    local current_model="${1:-}" attempt="${2:-1}" max_attempts="${3:-3}"
    local full rungs=() r
    full="$(echo "$RETRY_MODEL_LADDER" | tr ',' ' ') session-restart human"
    for r in $full; do
        rungs[${#rungs[@]}]="$r"
    done

    local i idx=-1
    for ((i = 0; i < ${#rungs[@]}; i++)); do
        if [[ "${rungs[$i]}" == "$current_model" ]]; then
            idx=$i
            break
        fi
    done

    local next_idx
    if [[ "$idx" -ge 0 ]]; then
        next_idx=$((idx + 1))
    else
        # Current model not on the ladder (e.g. haiku/default) → start at the top.
        next_idx=0
    fi

    local last=$(( ${#rungs[@]} - 1 ))
    [[ "$next_idx" -gt "$last" ]] && next_idx=$last
    echo "${rungs[$next_idx]}"
}

# ─── Decision Emitter (builds JSON + emits retry.decision) ────────────────────
_retry_emit_decision() {
    local category="$1" action="$2" confidence="$3" target="$4" advice="$5" mem_fix="$6" reason="$7"
    [[ "$advice" =~ ^[0-9]+$ ]] || advice=0

    local json
    if command -v jq >/dev/null 2>&1; then
        json=$(jq -nc \
            --arg category "$category" \
            --arg action "$action" \
            --arg confidence "$confidence" \
            --arg target "$target" \
            --argjson advice "$advice" \
            --arg memoryFix "$mem_fix" \
            --arg reason "$reason" \
            '{category:$category, action:$action, confidence:$confidence, escalationTarget:$target, maxAttemptsAdvice:$advice, memoryFix:$memoryFix, reason:$reason}' 2>/dev/null) || true
    fi
    if [[ -z "$json" ]]; then
        # jq-free fallback (memoryFix omitted to avoid escaping pitfalls).
        json="{\"category\":\"${category}\",\"action\":\"${action}\",\"confidence\":\"${confidence}\",\"escalationTarget\":\"${target}\",\"maxAttemptsAdvice\":${advice},\"memoryFix\":\"\",\"reason\":\"${reason}\"}"
    fi

    if type emit_event >/dev/null 2>&1; then
        emit_event "retry.decision" "category=$category" "action=$action" "confidence=$confidence" "target=$target" || true
    fi
    echo "$json"
}

# ─── Decision Orchestrator ────────────────────────────────────────────────────
# retry_decide <error_text> <attempt> <max_attempts> <current_model>
# Emits a retry.decision event and prints the decision JSON to stdout.
retry_decide() {
    local error_text="${1:-}" attempt="${2:-1}" max_attempts="${3:-3}" current_model="${4:-${MODEL:-opus}}"
    [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=1
    [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=3

    # Empty error → cannot classify; don't burn a retry cycle.
    if [[ -z "$error_text" ]]; then
        _retry_emit_decision "unrecoverable" "skip" "0.30" "human" 0 "" "empty error text — nothing to classify"
        return 0
    fi

    local fine category
    fine=$(retry_classify "$error_text")
    category=$(retry_category_of "$fine")

    # Memory lookup (graceful empty when memory/jq absent).
    local mem mem_rate=0 mem_fix="" mem_cat=""
    mem=$(retry_memory_lookup "$error_text")
    if [[ -n "$mem" ]]; then
        mem_rate=$(echo "$mem" | jq -r '.fix_effectiveness_rate // 0' 2>/dev/null | cut -d. -f1)
        [[ "$mem_rate" =~ ^[0-9]+$ ]] || mem_rate=0
        mem_fix=$(echo "$mem" | jq -r '.fix // ""' 2>/dev/null)
        mem_cat=$(echo "$mem" | jq -r '.category // ""' 2>/dev/null)
    fi

    local conf_int conf
    conf_int=$(_retry_confidence_int "$fine" "$mem_rate" "$attempt" "$max_attempts")
    conf=$(printf '0.%02d' "$conf_int")

    # Map category → action / escalation target / per-class attempt advice.
    local action target advice
    case "$category" in
        recoverable-transient)
            action="immediate"; target="$current_model"; advice=4 ;;
        recoverable-escalation)
            action="model-escalation"; target="$(retry_escalation_target "$current_model" "$attempt" "$max_attempts")"; advice=2 ;;
        context-exhausted)
            action="session-restart"; target="session-restart"; advice=2 ;;
        unrecoverable)
            action="skip"; target="human"; advice=0 ;;
        *)
            action="model-escalation"; target="$(retry_escalation_target "$current_model" "$attempt" "$max_attempts")"; advice=2 ;;
    esac

    local reason="${fine} mapped to ${category}"
    local mem_fix_str=""
    if [[ -n "$mem_fix" ]]; then
        mem_fix_str="[${mem_cat:-$fine}, ${mem_rate}% success rate] ${mem_fix}"
        reason="${reason}; memory match raised confidence"
    fi

    # Min-confidence gate: low confidence on a non-transient failure → skip.
    if [[ "$conf_int" -lt "$RETRY_MIN_CONFIDENCE_INT" && "$category" != "recoverable-transient" && "$action" != "skip" ]]; then
        action="skip"; target="human"; advice=0
        reason="${reason}; confidence ${conf} below threshold 0.$(printf '%02d' "$RETRY_MIN_CONFIDENCE_INT") — skipping"
    fi

    # Max-attempts gate: at/over budget → terminal action (never another model bump).
    if [[ "$attempt" -ge "$max_attempts" && "$action" != "skip" ]]; then
        action="skip"; target="human"; advice=0
        reason="${reason}; attempt ${attempt}/${max_attempts} exhausted retry budget"
    fi

    _retry_emit_decision "$category" "$action" "$conf" "$target" "$advice" "$mem_fix_str" "$reason"
}

# ─── Outcome Recording + Metrics ──────────────────────────────────────────────
# retry_record_outcome <strategy> <success_bool> <category> [error_sig]
# Atomically appends to the metrics JSONL, emits retry.outcome, and (when an
# error signature is supplied) feeds the result back into failure memory.
retry_record_outcome() {
    local strategy="${1:-unknown}" success="${2:-false}" category="${3:-unknown}" error_sig="${4:-}"
    [[ "$success" == "true" ]] || success="false"

    local entry
    if command -v jq >/dev/null 2>&1; then
        entry=$(jq -nc \
            --arg ts "$(now_iso)" --arg s "$strategy" --arg cat "$category" \
            --argjson ok "$success" \
            '{ts:$ts, strategy:$s, success:$ok, category:$cat}' 2>/dev/null) || true
    fi
    [[ -z "$entry" ]] && entry="{\"ts\":\"$(now_iso)\",\"strategy\":\"${strategy}\",\"success\":${success},\"category\":\"${category}\"}"

    mkdir -p "$(dirname "$RETRY_METRICS_FILE")" 2>/dev/null || true

    # Atomic read-modify-write with bounded retention (last 1000 entries).
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/sw-retry-metrics.XXXXXX" 2>/dev/null) || tmp=""
    if [[ -n "$tmp" ]]; then
        {
            [[ -f "$RETRY_METRICS_FILE" ]] && cat "$RETRY_METRICS_FILE"
            echo "$entry"
        } 2>/dev/null | tail -1000 > "$tmp" 2>/dev/null
        mv "$tmp" "$RETRY_METRICS_FILE" 2>/dev/null || { rm -f "$tmp"; echo "$entry" >> "$RETRY_METRICS_FILE" 2>/dev/null || true; }
    else
        echo "$entry" >> "$RETRY_METRICS_FILE" 2>/dev/null || true
    fi

    if type emit_event >/dev/null 2>&1; then
        emit_event "retry.outcome" "strategy=$strategy" "success=$success" "category=$category" || true
    fi

    # Close the loop into failure memory when we know the error signature.
    if [[ -n "$error_sig" ]] && type memory_track_fix >/dev/null 2>&1; then
        memory_track_fix "$error_sig" "$success" || true
    fi
}

# retry_metrics — aggregate per-strategy success rate from the metrics JSONL.
retry_metrics() {
    if [[ ! -f "$RETRY_METRICS_FILE" ]] || ! command -v jq >/dev/null 2>&1; then
        echo '{"total":0,"strategies":[]}'
        return 0
    fi
    jq -s '
        {
            total: length,
            strategies: (
                group_by(.strategy)
                | map({
                    strategy: .[0].strategy,
                    attempts: length,
                    successes: ([.[] | select(.success == true)] | length),
                    successRate: (
                        if length > 0
                        then (([.[] | select(.success == true)] | length) * 100 / length | floor)
                        else 0 end
                    )
                })
            )
        }
    ' "$RETRY_METRICS_FILE" 2>/dev/null || echo '{"total":0,"strategies":[]}'
}

# ─── CLI Dispatch (tests / debugging) ─────────────────────────────────────────
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    _cmd="${1:-}"
    shift || true
    case "$_cmd" in
        decide)      retry_decide "$@" ;;
        classify)    retry_classify "$@" ;;
        category)    retry_category_of "$(retry_classify "${1:-}")" ;;
        confidence)  retry_compute_confidence "$@" ;;
        target)      retry_escalation_target "$@" ;;
        record)      retry_record_outcome "$@" ;;
        metrics)     retry_metrics ;;
        *)
            echo "usage: retry-strategy.sh {decide <err> <attempt> <max> <model>|classify <err>|category <err>|confidence <fine> <rate> <attempt> <max>|target <model> <attempt> <max>|record <strategy> <success> <category> [sig]|metrics}" >&2
            exit 1 ;;
    esac
fi
