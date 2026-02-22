#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright cost — Token Usage & Cost Intelligence                            ║
# ║  Tracks spending · Enforces budgets · Stage breakdowns · Trend analysis ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

# ─── Cost Storage ──────────────────────────────────────────────────────────
COST_DIR="${HOME}/.shipwright"
COST_FILE="${COST_DIR}/costs.json"
BUDGET_FILE="${COST_DIR}/budget.json"
PER_ISSUE_FILE="${COST_DIR}/cost-per-issue.json"

# Source sw-db.sh for SQLite cost functions (if available)
_COST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_COST_SCRIPT_DIR/sw-db.sh" ]]; then
    source "$_COST_SCRIPT_DIR/sw-db.sh" 2>/dev/null || true
fi

ensure_cost_dir() {
    mkdir -p "$COST_DIR"
    [[ -f "$COST_FILE" ]] || echo '{"entries":[],"summary":{}}' > "$COST_FILE"
    [[ -f "$BUDGET_FILE" ]] || echo '{"daily_budget_usd":0,"enabled":false}' > "$BUDGET_FILE"
}

# ─── Model Pricing (USD per million tokens) ────────────────────────────────
# Default pricing (fallback when no config file exists)
_DEFAULT_OPUS_INPUT_PER_M=15.00
_DEFAULT_OPUS_OUTPUT_PER_M=75.00
_DEFAULT_SONNET_INPUT_PER_M=3.00
_DEFAULT_SONNET_OUTPUT_PER_M=15.00
_DEFAULT_HAIKU_INPUT_PER_M=0.25
_DEFAULT_HAIKU_OUTPUT_PER_M=1.25

MODEL_PRICING_FILE="${HOME}/.shipwright/model-pricing.json"

# Load pricing from config file or use defaults
_cost_load_pricing() {
    if [[ -f "$MODEL_PRICING_FILE" ]]; then
        OPUS_INPUT_PER_M=$(jq -r '.opus.input_per_m // empty' "$MODEL_PRICING_FILE" 2>/dev/null || true)
        OPUS_OUTPUT_PER_M=$(jq -r '.opus.output_per_m // empty' "$MODEL_PRICING_FILE" 2>/dev/null || true)
        SONNET_INPUT_PER_M=$(jq -r '.sonnet.input_per_m // empty' "$MODEL_PRICING_FILE" 2>/dev/null || true)
        SONNET_OUTPUT_PER_M=$(jq -r '.sonnet.output_per_m // empty' "$MODEL_PRICING_FILE" 2>/dev/null || true)
        HAIKU_INPUT_PER_M=$(jq -r '.haiku.input_per_m // empty' "$MODEL_PRICING_FILE" 2>/dev/null || true)
        HAIKU_OUTPUT_PER_M=$(jq -r '.haiku.output_per_m // empty' "$MODEL_PRICING_FILE" 2>/dev/null || true)
    fi
    # Fallback to defaults for any missing values
    OPUS_INPUT_PER_M="${OPUS_INPUT_PER_M:-$_DEFAULT_OPUS_INPUT_PER_M}"
    OPUS_OUTPUT_PER_M="${OPUS_OUTPUT_PER_M:-$_DEFAULT_OPUS_OUTPUT_PER_M}"
    SONNET_INPUT_PER_M="${SONNET_INPUT_PER_M:-$_DEFAULT_SONNET_INPUT_PER_M}"
    SONNET_OUTPUT_PER_M="${SONNET_OUTPUT_PER_M:-$_DEFAULT_SONNET_OUTPUT_PER_M}"
    HAIKU_INPUT_PER_M="${HAIKU_INPUT_PER_M:-$_DEFAULT_HAIKU_INPUT_PER_M}"
    HAIKU_OUTPUT_PER_M="${HAIKU_OUTPUT_PER_M:-$_DEFAULT_HAIKU_OUTPUT_PER_M}"
}

_cost_load_pricing

# cost_calculate <input_tokens> <output_tokens> <model>
# Returns the cost in USD (floating point)
cost_calculate() {
    local input_tokens="${1:-0}"
    local output_tokens="${2:-0}"
    local model="${3:-sonnet}"

    local input_rate output_rate
    case "$model" in
        opus|claude-opus-4*)
            input_rate="$OPUS_INPUT_PER_M"
            output_rate="$OPUS_OUTPUT_PER_M"
            ;;
        sonnet|claude-sonnet-4*)
            input_rate="$SONNET_INPUT_PER_M"
            output_rate="$SONNET_OUTPUT_PER_M"
            ;;
        haiku|claude-haiku-4*)
            input_rate="$HAIKU_INPUT_PER_M"
            output_rate="$HAIKU_OUTPUT_PER_M"
            ;;
        *)
            # Default to sonnet pricing for unknown models
            input_rate="$SONNET_INPUT_PER_M"
            output_rate="$SONNET_OUTPUT_PER_M"
            ;;
    esac

    awk -v it="$input_tokens" -v ot="$output_tokens" \
        -v ir="$input_rate" -v or_="$output_rate" \
        'BEGIN { printf "%.4f", (it / 1000000.0 * ir) + (ot / 1000000.0 * or_) }'
}

# cost_record <input_tokens> <output_tokens> <model> <stage> [issue]
# Records a cost entry to the cost file and events log.
# Tries SQLite first, always writes to JSON for backward compat.
cost_record() {
    local input_tokens="${1:-0}"
    local output_tokens="${2:-0}"
    local model="${3:-sonnet}"
    local stage="${4:-unknown}"
    local issue="${5:-}"

    ensure_cost_dir

    local cost_usd
    cost_usd=$(cost_calculate "$input_tokens" "$output_tokens" "$model")

    # Try SQLite first (arg order must match db_record_cost signature: tokens, tokens, model, cost, stage, issue)
    if type db_record_cost >/dev/null 2>&1; then
        db_record_cost "$input_tokens" "$output_tokens" "$model" "$cost_usd" "$stage" "$issue" 2>/dev/null || true
    fi

    # Always write to JSON (dual-write period)
    (
        if command -v flock >/dev/null 2>&1; then
            flock -w 10 200 2>/dev/null || { warn "Cost lock timeout"; }
        fi
        local tmp_file
        tmp_file=$(mktemp "${COST_FILE}.tmp.XXXXXX")
        jq --argjson input "$input_tokens" \
           --argjson output "$output_tokens" \
           --arg model "$model" \
           --arg stage "$stage" \
           --arg issue "$issue" \
           --arg cost "$cost_usd" \
           --arg ts "$(now_iso)" \
           --argjson epoch "$(now_epoch)" \
           '.entries += [{
               input_tokens: $input,
               output_tokens: $output,
               model: $model,
               stage: $stage,
               issue: $issue,
               cost_usd: ($cost | tonumber),
               ts: $ts,
               ts_epoch: $epoch
           }] | .entries = (.entries | .[-1000:])' \
           "$COST_FILE" > "$tmp_file" && mv "$tmp_file" "$COST_FILE" || rm -f "$tmp_file"
    ) 200>"${COST_FILE}.lock"

    emit_event "cost.record" \
        "input_tokens=${input_tokens}" \
        "output_tokens=${output_tokens}" \
        "model=${model}" \
        "stage=${stage}" \
        "cost_usd=${cost_usd}"
}

# cost_check_budget [estimated_cost_usd]
# Checks if daily budget would be exceeded. Returns 0=ok, 1=warning, 2=blocked.
cost_check_budget() {
    local estimated="${1:-0}"

    ensure_cost_dir

    # Try DB for budget info
    local budget_enabled budget_usd
    if type db_get_budget >/dev/null 2>&1 && type db_available >/dev/null 2>&1 && db_available 2>/dev/null; then
        local db_budget
        db_budget=$(db_get_budget 2>/dev/null || true)
        if [[ -n "$db_budget" ]]; then
            budget_enabled=$(echo "$db_budget" | cut -d'|' -f2)
            budget_usd=$(echo "$db_budget" | cut -d'|' -f1)
            [[ "$budget_enabled" == "1" ]] && budget_enabled="true"
        fi
    fi
    # Fallback to JSON
    budget_enabled="${budget_enabled:-$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")}"
    budget_usd="${budget_usd:-$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")}"

    if [[ "$budget_enabled" != "true" || "$budget_usd" == "0" ]]; then
        return 0
    fi

    # Calculate today's spending
    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$today_start" +%s 2>/dev/null || date -u -d "$today_start" +%s 2>/dev/null || echo "0")

    local today_spent
    today_spent=$(jq --argjson cutoff "$today_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
        "$COST_FILE" 2>/dev/null || echo "0")

    local projected
    projected=$(awk -v spent="$today_spent" -v est="$estimated" 'BEGIN { printf "%.4f", spent + est }')

    local pct_used
    pct_used=$(awk -v spent="$today_spent" -v budget="$budget_usd" 'BEGIN { printf "%.0f", (spent / budget) * 100 }')

    if awk -v proj="$projected" -v budget="$budget_usd" 'BEGIN { exit !(proj > budget) }'; then
        error "Budget exceeded! Today: \$${today_spent} + estimated \$${estimated} > \$${budget_usd} daily limit"
        emit_event "cost.budget_exceeded" "today_spent=${today_spent}" "estimated=${estimated}" "budget=${budget_usd}"
        return 2
    fi

    if [[ "${pct_used}" -ge 80 ]]; then
        warn "Budget warning: ${pct_used}% used (\$${today_spent} / \$${budget_usd})"
        emit_event "cost.budget_warning" "pct_used=${pct_used}" "today_spent=${today_spent}" "budget=${budget_usd}"
        return 1
    fi

    return 0
}

# cost_remaining_budget
# Returns remaining daily budget as a plain number (for daemon auto-scale consumption)
# Outputs "unlimited" if budget is not enabled

cost_remaining_budget() {
    ensure_cost_dir

    # Try DB for remaining budget (single query)
    if type db_remaining_budget >/dev/null 2>&1 && type db_available >/dev/null 2>&1 && db_available 2>/dev/null; then
        local db_result
        db_result=$(db_remaining_budget 2>/dev/null || true)
        if [[ -n "$db_result" ]]; then
            echo "$db_result"
            return 0
        fi
    fi

    # Fallback to JSON
    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")

    if [[ "$budget_enabled" != "true" || "$budget_usd" == "0" ]]; then
        echo "unlimited"
        return 0
    fi

    # Calculate today's spending (same pattern as cost_check_budget)
    local today_start
    today_start=$(date -u +"%Y-%m-%dT00:00:00Z")
    local today_epoch
    today_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$today_start" +%s 2>/dev/null || date -u -d "$today_start" +%s 2>/dev/null || echo "0")

    local today_spent
    today_spent=$(jq --argjson cutoff "$today_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0' \
        "$COST_FILE" 2>/dev/null || echo "0")

    # Validate numeric values
    if [[ ! "$today_spent" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        today_spent="0"
    fi
    if [[ ! "$budget_usd" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "unlimited"
        return 0
    fi

    # Calculate remaining
    local remaining
    remaining=$(awk -v budget="$budget_usd" -v spent="$today_spent" 'BEGIN { printf "%.2f", budget - spent }')

    echo "$remaining"
}

# ─── Cost-Per-Outcome ──────────────────────────────────────────────────────

OUTCOMES_FILE="${COST_DIR}/cost-outcomes.json"

_ensure_outcomes_file() {
    mkdir -p "$COST_DIR"
    [[ -f "$OUTCOMES_FILE" ]] || echo '{"outcomes":[],"summary":{"total_pipelines":0,"successful":0,"failed":0,"total_cost":0}}' > "$OUTCOMES_FILE"
}

# cost_record_outcome <pipeline_id> <total_cost> <success> <model_used> <template>
# Records pipeline outcome with cost for efficiency tracking.
cost_record_outcome() {
    local pipeline_id="${1:-unknown}"
    local total_cost="${2:-0}"
    local success_flag="${3:-false}"
    local model_used="${4:-sonnet}"
    local template="${5:-standard}"

    _ensure_outcomes_file

    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-cost-outcome.XXXXXX")
    jq --arg pid "$pipeline_id" \
       --arg cost "$total_cost" \
       --arg success "$success_flag" \
       --arg model "$model_used" \
       --arg tpl "$template" \
       --arg ts "$(now_iso)" \
       --argjson epoch "$(now_epoch)" \
       '
       .outcomes += [{
           pipeline_id: $pid,
           cost_usd: ($cost | tonumber),
           success: ($success == "true"),
           model: $model,
           template: $tpl,
           ts: $ts,
           ts_epoch: $epoch
       }] |
       .outcomes = (.outcomes | .[-500:]) |
       .summary.total_pipelines = (.outcomes | length) |
       .summary.successful = ([.outcomes[] | select(.success == true)] | length) |
       .summary.failed = ([.outcomes[] | select(.success == false)] | length) |
       .summary.total_cost = ([.outcomes[].cost_usd] | add // 0 | . * 100 | round / 100)
       ' "$OUTCOMES_FILE" > "$tmp_file" && mv "$tmp_file" "$OUTCOMES_FILE" || rm -f "$tmp_file"

    emit_event "cost.outcome_recorded" \
        "pipeline_id=$pipeline_id" \
        "cost_usd=$total_cost" \
        "success=$success_flag" \
        "model=$model_used" \
        "template=$template"
}

# cost_show_efficiency [--json]
# Displays cost/success efficiency metrics.
cost_show_efficiency() {
    local json_output=false
    [[ "${1:-}" == "--json" ]] && json_output=true

    _ensure_outcomes_file

    local total_pipelines successful failed total_cost
    total_pipelines=$(jq '.summary.total_pipelines // 0' "$OUTCOMES_FILE" 2>/dev/null || echo "0")
    successful=$(jq '.summary.successful // 0' "$OUTCOMES_FILE" 2>/dev/null || echo "0")
    failed=$(jq '.summary.failed // 0' "$OUTCOMES_FILE" 2>/dev/null || echo "0")
    total_cost=$(jq '.summary.total_cost // 0' "$OUTCOMES_FILE" 2>/dev/null || echo "0")

    local cost_per_success="N/A"
    local cost_per_pipeline="N/A"
    if [[ "$successful" -gt 0 ]]; then
        cost_per_success=$(awk -v tc="$total_cost" -v s="$successful" 'BEGIN { printf "%.2f", tc / s }')
    fi
    if [[ "$total_pipelines" -gt 0 ]]; then
        cost_per_pipeline=$(awk -v tc="$total_cost" -v tp="$total_pipelines" 'BEGIN { printf "%.2f", tc / tp }')
    fi

    local success_rate="0"
    if [[ "$total_pipelines" -gt 0 ]]; then
        success_rate=$(awk -v s="$successful" -v tp="$total_pipelines" 'BEGIN { printf "%.1f", (s / tp) * 100 }')
    fi

    # Model breakdown from outcomes
    local model_breakdown
    model_breakdown=$(jq '[.outcomes[] | {model, cost_usd, success}] |
        group_by(.model) | map({
            model: .[0].model,
            count: length,
            cost: ([.[].cost_usd] | add // 0 | . * 100 | round / 100),
            successes: ([.[] | select(.success == true)] | length)
        }) | sort_by(-.cost)' "$OUTCOMES_FILE" 2>/dev/null || echo "[]")

    # Template breakdown
    local template_breakdown
    template_breakdown=$(jq '[.outcomes[] | {template, cost_usd, success}] |
        group_by(.template) | map({
            template: .[0].template,
            count: length,
            cost: ([.[].cost_usd] | add // 0 | . * 100 | round / 100),
            successes: ([.[] | select(.success == true)] | length)
        }) | sort_by(-.cost)' "$OUTCOMES_FILE" 2>/dev/null || echo "[]")

    # Savings opportunity: estimate savings if sonnet handled opus stages
    local opus_cost sonnet_equivalent_cost savings_estimate
    opus_cost=$(jq '[.outcomes[] | select(.model == "opus") | .cost_usd] | add // 0' "$OUTCOMES_FILE" 2>/dev/null || echo "0")
    # Sonnet is roughly 5x cheaper than opus (3/15 input, 15/75 output)
    sonnet_equivalent_cost=$(awk -v oc="$opus_cost" 'BEGIN { printf "%.2f", oc / 5.0 }')
    savings_estimate=$(awk -v oc="$opus_cost" -v sc="$sonnet_equivalent_cost" 'BEGIN { printf "%.2f", oc - sc }')

    if [[ "$json_output" == "true" ]]; then
        jq -n \
            --argjson total "$total_pipelines" \
            --argjson successful "$successful" \
            --argjson failed "$failed" \
            --argjson total_cost "$total_cost" \
            --arg cost_per_success "$cost_per_success" \
            --arg cost_per_pipeline "$cost_per_pipeline" \
            --arg success_rate "$success_rate" \
            --argjson model_breakdown "$model_breakdown" \
            --argjson template_breakdown "$template_breakdown" \
            --argjson savings_estimate "$savings_estimate" \
            '{
                total_pipelines: $total,
                successful: $successful,
                failed: $failed,
                total_cost_usd: $total_cost,
                cost_per_success_usd: $cost_per_success,
                cost_per_pipeline_usd: $cost_per_pipeline,
                success_rate_pct: $success_rate,
                by_model: $model_breakdown,
                by_template: $template_breakdown,
                potential_savings_usd: $savings_estimate
            }'
        return 0
    fi

    echo ""
    echo -e "${BOLD}  COST EFFICIENCY${RESET}"
    echo -e "    Pipelines total     ${CYAN}${total_pipelines}${RESET}"
    echo -e "    Successful          ${GREEN}${successful}${RESET} (${success_rate}%)"
    echo -e "    Failed              ${RED}${failed}${RESET}"
    echo -e "    Total cost          ${CYAN}\$${total_cost}${RESET}"
    echo -e "    Cost per pipeline   \$${cost_per_pipeline}"
    echo -e "    Cost per success    \$${cost_per_success}"
    echo ""

    # Model breakdown
    local model_count
    model_count=$(echo "$model_breakdown" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$model_count" -gt 0 ]]; then
        echo -e "${BOLD}  BY MODEL${RESET}"
        echo "$model_breakdown" | jq -r '.[] | "    \(.model)\t$\(.cost)\t\(.successes)/\(.count) successful"' 2>/dev/null | \
            while IFS=$'\t' read -r mdl cost stats; do
                printf "    %-12s %-12s %s\n" "$mdl" "$cost" "$stats"
            done
        echo ""
    fi

    # Template breakdown
    local tpl_count
    tpl_count=$(echo "$template_breakdown" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$tpl_count" -gt 0 ]]; then
        echo -e "${BOLD}  BY TEMPLATE${RESET}"
        echo "$template_breakdown" | jq -r '.[] | "    \(.template)\t$\(.cost)\t\(.successes)/\(.count) successful"' 2>/dev/null | \
            while IFS=$'\t' read -r tpl cost stats; do
                printf "    %-16s %-12s %s\n" "$tpl" "$cost" "$stats"
            done
        echo ""
    fi

    # Savings opportunity
    if awk -v s="$savings_estimate" 'BEGIN { exit !(s > 0.01) }' 2>/dev/null; then
        echo -e "${BOLD}  SAVINGS OPPORTUNITY${RESET}"
        echo -e "    If sonnet handled opus stages: ~\$${savings_estimate} potential savings"
        echo -e "    ${DIM}(Based on ~5x cost difference between opus and sonnet)${RESET}"
        echo ""
    fi
}

# ─── Cost Per Issue ────────────────────────────────────────────────────────

_ensure_per_issue_file() {
    mkdir -p "$COST_DIR"
    [[ -f "$PER_ISSUE_FILE" ]] || echo '{"issues":{}}' > "$PER_ISSUE_FILE"
}

# cost_record_per_issue <issue> <cost_usd> <duration_s> <success> <template> <model>
# Upserts per-issue cost data — aggregates runs, tracks totals and outcomes.
cost_record_per_issue() {
    local issue="${1:-}"
    local cost_usd="${2:-0}"
    local duration_s="${3:-0}"
    local success="${4:-false}"
    local template="${5:-standard}"
    local model="${6:-sonnet}"

    [[ -z "$issue" ]] && return 0

    _ensure_per_issue_file

    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-cost-per-issue.XXXXXX")

    jq --arg issue "$issue" \
       --arg cost "$cost_usd" \
       --argjson dur "$duration_s" \
       --arg success "$success" \
       --arg tpl "$template" \
       --arg model "$model" \
       --arg ts "$(now_iso)" \
       --argjson epoch "$(now_epoch)" \
       '
       .issues[$issue] = (
           (.issues[$issue] // {
               issue: $issue,
               total_cost: 0,
               total_runs: 0,
               successful_runs: 0,
               failed_runs: 0,
               total_duration_s: 0,
               costs: [],
               durations: [],
               first_seen: $ts,
               templates: {},
               models: {}
           }) |
           .total_cost = (.total_cost + ($cost | tonumber) | . * 10000 | round / 10000) |
           .total_runs = (.total_runs + 1) |
           .successful_runs = (if $success == "true" then .successful_runs + 1 else .successful_runs end) |
           .failed_runs = (if $success != "true" then .failed_runs + 1 else .failed_runs end) |
           .total_duration_s = (.total_duration_s + $dur) |
           .costs = (.costs + [($cost | tonumber)] | .[-50:]) |
           .durations = (.durations + [$dur] | .[-50:]) |
           .last_seen = $ts |
           .last_epoch = $epoch |
           .templates[$tpl] = ((.templates[$tpl] // 0) + 1) |
           .models[$model] = ((.models[$model] // 0) + 1)
       )
       ' "$PER_ISSUE_FILE" > "$tmp_file" && mv "$tmp_file" "$PER_ISSUE_FILE" || rm -f "$tmp_file"

    emit_event "cost.per_issue_recorded" \
        "issue=$issue" \
        "cost_usd=$cost_usd" \
        "duration_s=$duration_s" \
        "success=$success"
}

# _compute_median <json_array_string>
# Returns median of a JSON number array (via jq).
_compute_median() {
    local arr="$1"
    echo "$arr" | jq '
        sort |
        if length == 0 then 0
        elif length % 2 == 1 then .[length / 2 | floor]
        else (.[length / 2 - 1] + .[length / 2]) / 2
        end | . * 100 | round / 100
    '
}

# _compute_p95 <json_array_string>
# Returns p95 of a JSON number array.
_compute_p95() {
    local arr="$1"
    echo "$arr" | jq '
        sort |
        if length == 0 then 0
        else
            (length * 0.95 | ceil) as $idx |
            if $idx >= length then .[-1]
            elif $idx < 1 then .[0]
            else .[$idx - 1]
            end
        end | . * 100 | round / 100
    '
}

# cost_show_per_issue [--json] [--top N] [--issue NUM]
# Displays per-issue cost dashboard with stats.
cost_show_per_issue() {
    local json_output=false
    local top_n=10
    local filter_issue=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)   json_output=true; shift ;;
            --top)    top_n="${2:-10}"; shift 2 ;;
            --top=*)  top_n="${1#--top=}"; shift ;;
            --issue)  filter_issue="${2:-}"; shift 2 ;;
            --issue=*) filter_issue="${1#--issue=}"; shift ;;
            *)        shift ;;
        esac
    done

    _ensure_per_issue_file

    local issue_count
    issue_count=$(jq '.issues | length' "$PER_ISSUE_FILE" 2>/dev/null || echo "0")

    if [[ "$issue_count" -eq 0 ]]; then
        if [[ "$json_output" == "true" ]]; then
            echo '{"issues":[],"summary":{"total_issues":0,"total_cost":0,"median_cost":0,"p95_cost":0}}'
        else
            warn "No per-issue cost data found."
        fi
        return 0
    fi

    # Single-issue detail view
    if [[ -n "$filter_issue" ]]; then
        local issue_data
        issue_data=$(jq --arg i "$filter_issue" '.issues[$i] // null' "$PER_ISSUE_FILE" 2>/dev/null)
        if [[ "$issue_data" == "null" || -z "$issue_data" ]]; then
            if [[ "$json_output" == "true" ]]; then
                echo '{"error":"issue not found"}'
            else
                warn "No cost data for issue #${filter_issue}"
            fi
            return 0
        fi

        local i_total_cost i_runs i_successes i_failures i_median i_p95 i_avg_dur
        i_total_cost=$(echo "$issue_data" | jq '.total_cost')
        i_runs=$(echo "$issue_data" | jq '.total_runs')
        i_successes=$(echo "$issue_data" | jq '.successful_runs')
        i_failures=$(echo "$issue_data" | jq '.failed_runs')
        i_median=$(_compute_median "$(echo "$issue_data" | jq '.costs')")
        i_p95=$(_compute_p95 "$(echo "$issue_data" | jq '.costs')")
        i_avg_dur="0"
        if [[ "$i_runs" -gt 0 ]]; then
            i_avg_dur=$(echo "$issue_data" | jq '.total_duration_s / .total_runs | round')
        fi

        if [[ "$json_output" == "true" ]]; then
            echo "$issue_data" | jq --argjson median "$i_median" --argjson p95 "$i_p95" --argjson avg_dur "$i_avg_dur" \
                '. + {median_cost: $median, p95_cost: $p95, avg_duration_s: $avg_dur}'
            return 0
        fi

        echo ""
        echo -e "${PURPLE}${BOLD}━━━ Cost Detail: Issue #${filter_issue} ━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        echo -e "${BOLD}  COST SUMMARY${RESET}"
        echo -e "    Total cost          ${CYAN}\$${i_total_cost}${RESET}"
        echo -e "    Median cost         \$${i_median}"
        echo -e "    P95 cost            \$${i_p95}"
        echo -e "    Pipeline runs       ${i_runs} (${GREEN}${i_successes} pass${RESET}, ${RED}${i_failures} fail${RESET})"
        echo -e "    Avg duration        $(format_duration "$i_avg_dur")"
        echo ""

        local tpl_data
        tpl_data=$(echo "$issue_data" | jq '.templates | to_entries | sort_by(-.value)')
        local tpl_count
        tpl_count=$(echo "$tpl_data" | jq 'length')
        if [[ "$tpl_count" -gt 0 ]]; then
            echo -e "${BOLD}  TEMPLATES USED${RESET}"
            echo "$tpl_data" | jq -r '.[] | "    \(.key)\t\(.value) run(s)"' | \
                while IFS=$'\t' read -r tpl count; do
                    printf "    %-16s %s\n" "$tpl" "$count"
                done
            echo ""
        fi

        local model_data
        model_data=$(echo "$issue_data" | jq '.models | to_entries | sort_by(-.value)')
        local model_count
        model_count=$(echo "$model_data" | jq 'length')
        if [[ "$model_count" -gt 0 ]]; then
            echo -e "${BOLD}  MODELS USED${RESET}"
            echo "$model_data" | jq -r '.[] | "    \(.key)\t\(.value) run(s)"' | \
                while IFS=$'\t' read -r mdl count; do
                    printf "    %-16s %s\n" "$mdl" "$count"
                done
            echo ""
        fi

        echo -e "    ${DIM}First seen: $(echo "$issue_data" | jq -r '.first_seen')${RESET}"
        echo -e "    ${DIM}Last seen:  $(echo "$issue_data" | jq -r '.last_seen')${RESET}"
        echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo ""
        return 0
    fi

    # Global summary stats
    local all_costs all_issues_sorted
    all_costs=$(jq '[.issues[].total_cost]' "$PER_ISSUE_FILE" 2>/dev/null || echo "[]")
    all_issues_sorted=$(jq --argjson top "$top_n" '
        [.issues | to_entries[] | .value] |
        sort_by(-.total_cost) | .[:$top]
    ' "$PER_ISSUE_FILE" 2>/dev/null || echo "[]")

    local grand_total median_cost p95_cost
    grand_total=$(echo "$all_costs" | jq 'add // 0 | . * 100 | round / 100')
    median_cost=$(_compute_median "$all_costs")
    p95_cost=$(_compute_p95 "$all_costs")

    # Most expensive issue
    local most_expensive_issue most_expensive_cost
    most_expensive_issue=$(echo "$all_issues_sorted" | jq -r '.[0].issue // "N/A"')
    most_expensive_cost=$(echo "$all_issues_sorted" | jq '.[0].total_cost // 0')

    if [[ "$json_output" == "true" ]]; then
        jq -n \
            --argjson issues "$all_issues_sorted" \
            --argjson total_issues "$issue_count" \
            --argjson total_cost "$grand_total" \
            --argjson median_cost "$median_cost" \
            --argjson p95_cost "$p95_cost" \
            --arg most_expensive_issue "$most_expensive_issue" \
            --argjson most_expensive_cost "$most_expensive_cost" \
            '{
                issues: $issues,
                summary: {
                    total_issues: $total_issues,
                    total_cost: $total_cost,
                    median_cost_per_issue: $median_cost,
                    p95_cost_per_issue: $p95_cost,
                    most_expensive_issue: $most_expensive_issue,
                    most_expensive_cost: $most_expensive_cost
                }
            }'
        return 0
    fi

    # ── Dashboard Output ──
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Cost Per Issue ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${DIM}$(now_iso)${RESET}"
    echo ""

    echo -e "${BOLD}  SUMMARY${RESET}"
    echo -e "    Issues tracked      ${CYAN}${issue_count}${RESET}"
    echo -e "    Total cost          ${CYAN}\$${grand_total}${RESET}"
    echo -e "    Median per issue    \$${median_cost}"
    echo -e "    P95 per issue       \$${p95_cost}"
    echo -e "    Most expensive      ${CYAN}#${most_expensive_issue}${RESET} (\$${most_expensive_cost})"
    echo ""

    echo -e "${BOLD}  TOP ${top_n} BY COST${RESET}"
    printf "    %-8s %-12s %-6s %-8s %-10s\n" "Issue" "Cost" "Runs" "Success" "Median"
    printf "    %-8s %-12s %-6s %-8s %-10s\n" "─────" "────" "────" "───────" "──────"

    echo "$all_issues_sorted" | jq -r '.[] |
        "\(.issue)\t\(.total_cost)\t\(.total_runs)\t\(.successful_runs)/\(.total_runs)\t\(.costs)"
    ' | while IFS=$'\t' read -r issue cost runs success_ratio costs_arr; do
        local row_median
        row_median=$(_compute_median "$costs_arr")
        printf "    #%-7s \$%-11s %-6s %-8s \$%-9s\n" "$issue" "$cost" "$runs" "$success_ratio" "$row_median"
    done
    echo ""

    echo -e "  ${DIM}View detail: shipwright cost per-issue --issue <N>${RESET}"
    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Pricing Management ──────────────────────────────────────────────────────

# cost_update_pricing [model] [input_per_m] [output_per_m]
# Updates model pricing config. With no args, shows current pricing.
cost_update_pricing() {
    local model="${1:-}"
    local input_price="${2:-}"
    local output_price="${3:-}"

    mkdir -p "$COST_DIR"

    if [[ -z "$model" ]]; then
        # Show current pricing
        echo ""
        echo -e "${BOLD}  Model Pricing${RESET} (per 1M tokens)"
        echo -e "    ${DIM}Source: ${MODEL_PRICING_FILE:-defaults}${RESET}"
        echo ""
        printf "    %-12s %-12s %-12s\n" "Model" "Input" "Output"
        printf "    %-12s %-12s %-12s\n" "─────" "─────" "──────"
        printf "    %-12s \$%-11s \$%-11s\n" "opus" "$OPUS_INPUT_PER_M" "$OPUS_OUTPUT_PER_M"
        printf "    %-12s \$%-11s \$%-11s\n" "sonnet" "$SONNET_INPUT_PER_M" "$SONNET_OUTPUT_PER_M"
        printf "    %-12s \$%-11s \$%-11s\n" "haiku" "$HAIKU_INPUT_PER_M" "$HAIKU_OUTPUT_PER_M"
        echo ""
        if [[ -f "$MODEL_PRICING_FILE" ]]; then
            echo -e "    ${GREEN}Using custom pricing from config${RESET}"
        else
            echo -e "    ${DIM}Using default pricing (no config file)${RESET}"
        fi
        echo ""
        return 0
    fi

    if [[ -z "$input_price" || -z "$output_price" ]]; then
        error "Usage: shipwright cost update-pricing <model> <input_per_m> <output_per_m>"
        return 1
    fi

    # Validate model name
    case "$model" in
        opus|sonnet|haiku) ;;
        *) error "Unknown model: $model (expected opus, sonnet, or haiku)"; return 1 ;;
    esac

    # Validate prices are numbers
    if ! echo "$input_price" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        error "Invalid input price: $input_price"
        return 1
    fi
    if ! echo "$output_price" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        error "Invalid output price: $output_price"
        return 1
    fi

    # Initialize config if missing
    if [[ ! -f "$MODEL_PRICING_FILE" ]]; then
        jq -n \
            --argjson oi "$_DEFAULT_OPUS_INPUT_PER_M" --argjson oo "$_DEFAULT_OPUS_OUTPUT_PER_M" \
            --argjson si "$_DEFAULT_SONNET_INPUT_PER_M" --argjson so "$_DEFAULT_SONNET_OUTPUT_PER_M" \
            --argjson hi "$_DEFAULT_HAIKU_INPUT_PER_M" --argjson ho "$_DEFAULT_HAIKU_OUTPUT_PER_M" \
            '{
                opus: {input_per_m: $oi, output_per_m: $oo},
                sonnet: {input_per_m: $si, output_per_m: $so},
                haiku: {input_per_m: $hi, output_per_m: $ho},
                updated_at: ""
            }' > "$MODEL_PRICING_FILE"
    fi

    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-cost-pricing.XXXXXX")
    jq --arg model "$model" \
       --argjson input "$input_price" \
       --argjson output "$output_price" \
       --arg ts "$(now_iso)" \
       '.[$model].input_per_m = $input | .[$model].output_per_m = $output | .updated_at = $ts' \
       "$MODEL_PRICING_FILE" > "$tmp_file" && mv "$tmp_file" "$MODEL_PRICING_FILE" || rm -f "$tmp_file"

    # Reload pricing
    _cost_load_pricing

    success "Pricing updated: ${model} → \$${input_price}/\$${output_price} per 1M tokens (in/out)"
    emit_event "cost.pricing_updated" "model=$model" "input_per_m=$input_price" "output_per_m=$output_price"
}

# ─── Dashboard ─────────────────────────────────────────────────────────────

cost_dashboard() {
    local period_days=7
    local json_output=false
    local by_stage=false
    local by_issue=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --period)  period_days="${2:-7}"; shift 2 ;;
            --period=*) period_days="${1#--period=}"; shift ;;
            --json)    json_output=true; shift ;;
            --by-stage) by_stage=true; shift ;;
            --by-issue) by_issue=true; shift ;;
            *)         shift ;;
        esac
    done

    ensure_cost_dir

    if [[ ! -f "$COST_FILE" ]]; then
        warn "No cost data found."
        return 0
    fi

    local cutoff_epoch
    cutoff_epoch=$(( $(now_epoch) - (period_days * 86400) ))

    # Filter entries within period
    local period_entries
    period_entries=$(jq --argjson cutoff "$cutoff_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff)]' \
        "$COST_FILE" 2>/dev/null || echo "[]")

    local entry_count
    entry_count=$(echo "$period_entries" | jq 'length')

    if [[ "$entry_count" -eq 0 ]]; then
        warn "No cost entries in the last ${period_days} day(s)."
        return 0
    fi

    # Aggregate stats
    local total_cost avg_cost max_cost total_input total_output
    total_cost=$(echo "$period_entries" | jq '[.[].cost_usd] | add // 0 | . * 100 | round / 100')
    avg_cost=$(echo "$period_entries" | jq '[.[].cost_usd] | if length > 0 then add / length else 0 end | . * 100 | round / 100')
    max_cost=$(echo "$period_entries" | jq '[.[].cost_usd] | max // 0 | . * 100 | round / 100')
    total_input=$(echo "$period_entries" | jq '[.[].input_tokens] | add // 0')
    total_output=$(echo "$period_entries" | jq '[.[].output_tokens] | add // 0')

    # Stage breakdown
    local stage_breakdown
    stage_breakdown=$(echo "$period_entries" | jq '
        group_by(.stage) | map({
            stage: .[0].stage,
            cost: ([.[].cost_usd] | add // 0 | . * 100 | round / 100),
            count: length
        }) | sort_by(-.cost)')

    # Issue breakdown
    local issue_breakdown
    issue_breakdown=$(echo "$period_entries" | jq '
        [.[] | select(.issue != "")] | group_by(.issue) | map({
            issue: .[0].issue,
            cost: ([.[].cost_usd] | add // 0 | . * 100 | round / 100),
            count: length
        }) | sort_by(-.cost) | .[:10]')

    # Cost trend (compare first half vs second half of period)
    local half_epoch
    half_epoch=$(( cutoff_epoch + (period_days * 86400 / 2) ))
    local first_half_cost second_half_cost trend
    first_half_cost=$(echo "$period_entries" | jq --argjson mid "$half_epoch" \
        '[.[] | select(.ts_epoch < $mid) | .cost_usd] | add // 0')
    second_half_cost=$(echo "$period_entries" | jq --argjson mid "$half_epoch" \
        '[.[] | select(.ts_epoch >= $mid) | .cost_usd] | add // 0')

    if awk -v f="$first_half_cost" -v s="$second_half_cost" 'BEGIN { exit !(f > 0) }' 2>/dev/null; then
        local change_pct
        change_pct=$(awk -v f="$first_half_cost" -v s="$second_half_cost" \
            'BEGIN { printf "%.0f", ((s - f) / f) * 100 }')
        if [[ "$change_pct" -gt 10 ]]; then
            trend="↑ ${change_pct}% (increasing)"
        elif [[ "$change_pct" -lt -10 ]]; then
            trend="↓ ${change_pct#-}% (decreasing)"
        else
            trend="→ stable"
        fi
    else
        trend="→ insufficient data"
    fi

    # Budget info
    local budget_enabled budget_usd today_spent
    budget_enabled=$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")

    local today_start_epoch
    today_start_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$(date -u +%Y-%m-%dT00:00:00Z)" +%s 2>/dev/null || date -u -d "$(date -u +%Y-%m-%dT00:00:00Z)" +%s 2>/dev/null || echo "0")
    today_spent=$(jq --argjson cutoff "$today_start_epoch" \
        '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0 | . * 100 | round / 100' \
        "$COST_FILE" 2>/dev/null || echo "0")

    # ── JSON Output ──
    if [[ "$json_output" == "true" ]]; then
        jq -n \
            --arg period "${period_days}d" \
            --argjson total_cost "$total_cost" \
            --argjson avg_cost "$avg_cost" \
            --argjson max_cost "$max_cost" \
            --argjson total_input "$total_input" \
            --argjson total_output "$total_output" \
            --argjson entry_count "$entry_count" \
            --argjson stage_breakdown "$stage_breakdown" \
            --argjson issue_breakdown "$issue_breakdown" \
            --arg trend "$trend" \
            --arg budget_enabled "$budget_enabled" \
            --argjson budget_usd "${budget_usd:-0}" \
            --argjson today_spent "$today_spent" \
            '{
                period: $period,
                total_cost_usd: $total_cost,
                avg_cost_usd: $avg_cost,
                max_cost_usd: $max_cost,
                total_input_tokens: $total_input,
                total_output_tokens: $total_output,
                entries: $entry_count,
                by_stage: $stage_breakdown,
                by_issue: $issue_breakdown,
                trend: $trend,
                budget: {
                    enabled: ($budget_enabled == "true"),
                    daily_usd: $budget_usd,
                    today_spent_usd: $today_spent
                }
            }'
        return 0
    fi

    # ── Dashboard Output ──
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Cost Intelligence ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  Period: last ${period_days} day(s)    ${DIM}$(now_iso)${RESET}"
    echo ""

    echo -e "${BOLD}  SPENDING SUMMARY${RESET}"
    echo -e "    Total cost          ${CYAN}\$${total_cost}${RESET}"
    echo -e "    Avg per pipeline    \$${avg_cost}"
    echo -e "    Max single pipeline \$${max_cost}"
    echo -e "    Entries             ${entry_count}"
    echo ""

    echo -e "${BOLD}  TOKENS${RESET}"
    echo -e "    Input tokens        $(printf "%'d" "$total_input")"
    echo -e "    Output tokens       $(printf "%'d" "$total_output")"
    echo ""

    echo -e "${BOLD}  TREND${RESET}"
    echo -e "    ${trend}"
    echo ""

    # Stage breakdown
    if [[ "$by_stage" == "true" ]]; then
        echo -e "${BOLD}  BY STAGE${RESET}"
        echo "$stage_breakdown" | jq -r '.[] | "    \(.stage)\t$\(.cost)\t(\(.count) entries)"' 2>/dev/null | \
            while IFS=$'\t' read -r stage cost count; do
                printf "    %-20s %-12s %s\n" "$stage" "$cost" "$count"
            done
        echo ""
    fi

    # Issue breakdown
    if [[ "$by_issue" == "true" ]]; then
        echo -e "${BOLD}  BY ISSUE${RESET}"
        echo "$issue_breakdown" | jq -r '.[] | "    #\(.issue)\t$\(.cost)\t(\(.count) entries)"' 2>/dev/null | \
            while IFS=$'\t' read -r issue cost count; do
                printf "    %-20s %-12s %s\n" "$issue" "$cost" "$count"
            done
        echo ""
    fi

    # Budget
    if [[ "$budget_enabled" == "true" ]]; then
        local pct_used
        pct_used=$(awk -v spent="$today_spent" -v budget="$budget_usd" \
            'BEGIN { if (budget > 0) printf "%.0f", (spent / budget) * 100; else print "0" }')
        local bar=""
        local filled=$(( pct_used / 5 ))
        [[ "$filled" -gt 20 ]] && filled=20
        local empty=$(( 20 - filled ))
        bar=$(printf '%0.s█' $(seq 1 "$filled") 2>/dev/null || true)
        bar+=$(printf '%0.s░' $(seq 1 "$empty") 2>/dev/null || true)

        local color="$GREEN"
        [[ "$pct_used" -ge 80 ]] && color="$YELLOW"
        [[ "$pct_used" -ge 100 ]] && color="$RED"

        echo -e "${BOLD}  DAILY BUDGET${RESET}"
        echo -e "    ${color}${bar}${RESET} ${pct_used}%"
        echo -e "    \$${today_spent} / \$${budget_usd}"
        echo ""
    fi

    # Efficiency summary (if outcome data exists)
    if [[ -f "$OUTCOMES_FILE" ]]; then
        local outcome_count
        outcome_count=$(jq '.summary.total_pipelines // 0' "$OUTCOMES_FILE" 2>/dev/null || echo "0")
        if [[ "$outcome_count" -gt 0 ]]; then
            local eff_successful eff_total_cost eff_cost_per_success eff_rate
            eff_successful=$(jq '.summary.successful // 0' "$OUTCOMES_FILE" 2>/dev/null || echo "0")
            eff_total_cost=$(jq '.summary.total_cost // 0' "$OUTCOMES_FILE" 2>/dev/null || echo "0")
            eff_rate="0"
            if [[ "$outcome_count" -gt 0 ]]; then
                eff_rate=$(awk -v s="$eff_successful" -v t="$outcome_count" 'BEGIN { printf "%.0f", (s/t)*100 }')
            fi
            eff_cost_per_success="N/A"
            if [[ "$eff_successful" -gt 0 ]]; then
                eff_cost_per_success=$(awk -v tc="$eff_total_cost" -v s="$eff_successful" 'BEGIN { printf "%.2f", tc / s }')
            fi

            echo -e "${BOLD}  EFFICIENCY${RESET}"
            echo -e "    Success rate        ${eff_rate}% (${eff_successful}/${outcome_count})"
            echo -e "    Cost per success    \$${eff_cost_per_success}"
            echo ""
        fi
    fi

    echo -e "${PURPLE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# ─── Budget Management ─────────────────────────────────────────────────────

budget_set() {
    local amount="${1:-}"

    if [[ -z "$amount" ]]; then
        error "Usage: shipwright cost budget set <amount_usd>"
        return 1
    fi

    # Validate it's a number
    if ! echo "$amount" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        error "Invalid amount: ${amount} (must be a positive number)"
        return 1
    fi

    ensure_cost_dir

    # Write to DB if available
    if type db_set_budget >/dev/null 2>&1; then
        db_set_budget "$amount" 2>/dev/null || true
    fi

    # Always write to JSON (dual-write)
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg amt "$amount" \
       '{daily_budget_usd: ($amt | tonumber), enabled: true}' \
       "$BUDGET_FILE" > "$tmp_file" && mv "$tmp_file" "$BUDGET_FILE"

    success "Daily budget set to \$${amount}"
    emit_event "cost.budget_set" "daily_budget_usd=${amount}"
}

budget_show() {
    ensure_cost_dir

    local budget_enabled budget_usd
    budget_enabled=$(jq -r '.enabled' "$BUDGET_FILE" 2>/dev/null || echo "false")
    budget_usd=$(jq -r '.daily_budget_usd' "$BUDGET_FILE" 2>/dev/null || echo "0")

    echo ""
    echo -e "${BOLD}  Daily Budget${RESET}"
    if [[ "$budget_enabled" == "true" ]]; then
        echo -e "    Limit:    ${CYAN}\$${budget_usd}${RESET} per day"
        echo -e "    Status:   ${GREEN}enabled${RESET}"

        # Show today's usage
        local today_start_epoch
        today_start_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$(date -u +%Y-%m-%dT00:00:00Z)" +%s 2>/dev/null || date -u -d "$(date -u +%Y-%m-%dT00:00:00Z)" +%s 2>/dev/null || echo "0")
        local today_spent
        today_spent=$(jq --argjson cutoff "$today_start_epoch" \
            '[.entries[] | select(.ts_epoch >= $cutoff) | .cost_usd] | add // 0 | . * 100 | round / 100' \
            "$COST_FILE" 2>/dev/null || echo "0")
        echo -e "    Today:    \$${today_spent} / \$${budget_usd}"
    else
        echo -e "    Status:   ${DIM}not configured${RESET}"
        echo -e "    ${DIM}Set with: shipwright cost budget set <amount>${RESET}"
    fi
    echo ""
}

# ─── Help ──────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright cost${RESET} ${DIM}v${VERSION}${RESET} — Token Usage & Cost Intelligence"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright cost${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}show${RESET}                          Show cost summary for current period"
    echo -e "  ${CYAN}show${RESET} --period 30              Last 30 days"
    echo -e "  ${CYAN}show${RESET} --json                   JSON output"
    echo -e "  ${CYAN}show${RESET} --by-stage               Breakdown by pipeline stage"
    echo -e "  ${CYAN}show${RESET} --by-issue               Breakdown by issue"
    echo -e "  ${CYAN}budget set${RESET} <amount>            Set daily budget (USD)"
    echo -e "  ${CYAN}budget show${RESET}                    Show current budget/usage"
    echo ""
    echo -e "${BOLD}PIPELINE INTEGRATION${RESET}"
    echo -e "  ${CYAN}record${RESET} <in> <out> <model> <stage> [issue]   Record token usage"
    echo -e "  ${CYAN}record-outcome${RESET} <id> <cost> <success> <model> <tpl>  Record pipeline outcome"
    echo -e "  ${CYAN}calculate${RESET} <in> <out> <model>                Calculate cost (no record)"
    echo -e "  ${CYAN}check-budget${RESET} [estimated_usd]                Check budget before starting"
    echo ""
    echo -e "${BOLD}PER-ISSUE TRACKING${RESET}"
    echo -e "  ${CYAN}per-issue${RESET}                      Show cost-per-issue dashboard"
    echo -e "  ${CYAN}per-issue${RESET} --json               JSON output"
    echo -e "  ${CYAN}per-issue${RESET} --issue <N>          Detail view for issue N"
    echo -e "  ${CYAN}per-issue${RESET} --top 20             Show top 20 most expensive issues"
    echo ""
    echo -e "${BOLD}EFFICIENCY${RESET}"
    echo -e "  ${CYAN}efficiency${RESET}                     Show cost/success efficiency metrics"
    echo -e "  ${CYAN}efficiency${RESET} --json              JSON output"
    echo ""
    echo -e "${BOLD}MODEL PRICING${RESET}"
    echo -e "  ${CYAN}update-pricing${RESET} [model] [in] [out]  Update model pricing"
    echo -e "  ${CYAN}update-pricing${RESET}                     Show current pricing"
    echo -e "  ${DIM}Current: opus \$${OPUS_INPUT_PER_M}/\$${OPUS_OUTPUT_PER_M}, sonnet \$${SONNET_INPUT_PER_M}/\$${SONNET_OUTPUT_PER_M}, haiku \$${HAIKU_INPUT_PER_M}/\$${HAIKU_OUTPUT_PER_M}${RESET}"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright cost show${RESET}                              # 7-day cost summary"
    echo -e "  ${DIM}shipwright cost show --period 30 --by-stage${RESET}       # 30-day breakdown by stage"
    echo -e "  ${DIM}shipwright cost budget set 50.00${RESET}                  # Set \$50/day limit"
    echo -e "  ${DIM}shipwright cost budget show${RESET}                       # Check current budget"
    echo -e "  ${DIM}shipwright cost efficiency${RESET}                        # Cost per successful pipeline"
    echo -e "  ${DIM}shipwright cost update-pricing opus 15.00 75.00${RESET}   # Update opus pricing"
    echo -e "  ${DIM}shipwright cost per-issue${RESET}                         # Cost per issue dashboard"
    echo -e "  ${DIM}shipwright cost per-issue --issue 42${RESET}              # Detail for issue #42"
    echo -e "  ${DIM}shipwright cost per-issue --json${RESET}                  # JSON output"
    echo -e "  ${DIM}shipwright cost calculate 50000 10000 opus${RESET}        # Estimate cost"
}

# ─── Command Router ─────────────────────────────────────────────────────────
# Only run CLI when executed directly (not when sourced by sw-pipeline.sh)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

case "$SUBCOMMAND" in
    show)
        cost_dashboard "$@"
        ;;
    budget)
        BUDGET_CMD="${1:-show}"
        shift 2>/dev/null || true
        case "$BUDGET_CMD" in
            set)  budget_set "$@" ;;
            show) budget_show ;;
            *)    error "Unknown budget command: ${BUDGET_CMD}"; show_help; exit 1 ;;
        esac
        ;;
    record)
        cost_record "$@"
        ;;
    record-outcome)
        cost_record_outcome "$@"
        ;;
    calculate)
        cost_calculate "$@"
        echo ""
        ;;
    remaining-budget)
        cost_remaining_budget
        ;;
    check-budget)
        cost_check_budget "$@"
        ;;
    efficiency)
        cost_show_efficiency "$@"
        ;;
    per-issue)
        cost_show_per_issue "$@"
        ;;
    record-per-issue)
        cost_record_per_issue "$@"
        ;;
    update-pricing)
        cost_update_pricing "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        error "Unknown command: ${SUBCOMMAND}"
        echo ""
        show_help
        exit 1
        ;;
esac

fi  # end source guard
