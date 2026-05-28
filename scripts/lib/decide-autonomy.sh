# decide-autonomy.sh — Tier enforcement & rate limiting for the decision engine
# Source from sw-decide.sh. Requires helpers.sh, policy.sh.
[[ -n "${_DECIDE_AUTONOMY_LOADED:-}" ]] && return 0
_DECIDE_AUTONOMY_LOADED=1

# ─── State ────────────────────────────────────────────────────────────────────
DECISIONS_DIR="${HOME}/.shipwright/decisions"
HALT_FILE="${DECISIONS_DIR}/halt.json"
LAST_DECISION_FILE="${DECISIONS_DIR}/last-decision.json"
OUTCOMES_FILE="${DECISIONS_DIR}/outcomes.jsonl"

_ensure_decisions_dir() {
    mkdir -p "$DECISIONS_DIR"
}

_daily_log_file() {
    echo "${DECISIONS_DIR}/daily-log-$(date -u +%Y-%m-%d).jsonl"
}

# ─── Tier Configuration ──────────────────────────────────────────────────────

TIERS_DATA=""
CATEGORY_RULES=""
TIER_LIMITS=""

autonomy_load_tiers() {
    local tiers_path="${TIERS_FILE:-}"
    if [[ -z "$tiers_path" ]]; then
        # Try repo-relative, then policy
        local repo_dir="${_REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo '.')}"
        tiers_path="${repo_dir}/config/decision-tiers.json"
        if [[ ! -f "$tiers_path" ]]; then
            tiers_path=$(policy_get ".decision.tiers_file" "config/decision-tiers.json")
            [[ "$tiers_path" != /* ]] && tiers_path="${repo_dir}/${tiers_path}"
        fi
    fi

    if [[ ! -f "$tiers_path" ]]; then
        return 1
    fi

    TIERS_FILE="$tiers_path"
    TIERS_DATA=$(cat "$tiers_path")
    CATEGORY_RULES=$(echo "$TIERS_DATA" | jq -c '.category_rules // {}')
    TIER_LIMITS=$(echo "$TIERS_DATA" | jq -c '.limits // {}')
    return 0
}

# ─── Tier Resolution ─────────────────────────────────────────────────────────

autonomy_resolve_tier() {
    local category="$1"
    if [[ -z "$CATEGORY_RULES" ]]; then
        echo "draft"
        return
    fi
    local tier
    tier=$(echo "$CATEGORY_RULES" | jq -r --arg cat "$category" '.[$cat].tier // "draft"')
    echo "${tier:-draft}"
}

autonomy_get_labels() {
    local tier="$1"
    if [[ -z "$TIERS_DATA" ]]; then
        echo ""
        return
    fi
    echo "$TIERS_DATA" | jq -r --arg t "$tier" '.tiers[$t].labels // [] | join(",")'
}

autonomy_get_template() {
    local tier="$1"
    if [[ -z "$TIERS_DATA" ]]; then
        echo "standard"
        return
    fi
    local tmpl
    tmpl=$(echo "$TIERS_DATA" | jq -r --arg t "$tier" '.tiers[$t].pipeline_template // "standard"')
    [[ "$tmpl" == "null" ]] && tmpl=""
    echo "$tmpl"
}

# ─── Budget Checks ───────────────────────────────────────────────────────────

autonomy_check_budget() {
    local tier="$1"
    _ensure_decisions_dir

    local daily_log
    daily_log=$(_daily_log_file)

    # Count today's issues created
    local today_count=0
    if [[ -f "$daily_log" ]]; then
        today_count=$(jq -s '[.[] | select(.action == "issue_created" or .action == "draft_written")] | length' "$daily_log" 2>/dev/null || echo "0")
    fi

    local max_issues
    max_issues=$(echo "${TIER_LIMITS:-{}}" | jq -r '.max_issues_per_day // 15')

    if [[ "$today_count" -ge "$max_issues" ]]; then
        return 1
    fi

    # Check cost budget
    local max_cost
    max_cost=$(echo "${TIER_LIMITS:-{}}" | jq -r '.max_cost_per_day_usd // 25')
    local today_cost=0
    if [[ -f "$daily_log" ]]; then
        today_cost=$(jq -s '[.[] | .estimated_cost_usd // 0] | add // 0' "$daily_log" 2>/dev/null || echo "0")
    fi

    # Only check cost for auto tier (propose/draft are cheap)
    if [[ "$tier" == "auto" ]]; then
        local cost_exceeded
        cost_exceeded=$(echo "$today_cost $max_cost" | awk '{print ($1 >= $2) ? "true" : "false"}')
        if [[ "$cost_exceeded" == "true" ]]; then
            return 1
        fi
    fi

    return 0
}

# ─── Rate Limiting ────────────────────────────────────────────────────────────

autonomy_check_rate_limit() {
    [[ ! -f "$LAST_DECISION_FILE" ]] && return 0

    local last_epoch
    last_epoch=$(jq -r '.epoch // 0' "$LAST_DECISION_FILE" 2>/dev/null || echo "0")
    local now_e
    now_e=$(now_epoch)

    local cooldown
    cooldown=$(echo "${TIER_LIMITS:-{}}" | jq -r '.cooldown_seconds // 300')

    local elapsed=$((now_e - last_epoch))
    if [[ "$elapsed" -lt "$cooldown" ]]; then
        return 1
    fi
    return 0
}

# ─── Halt Management ─────────────────────────────────────────────────────────

autonomy_check_halt() {
    [[ -f "$HALT_FILE" ]] && return 1
    return 0
}

autonomy_halt() {
    _ensure_decisions_dir
    local reason="${1:-manual halt}"
    local tmp
    tmp=$(mktemp)
    jq -n --arg reason "$reason" --arg ts "$(now_iso)" --argjson epoch "$(now_epoch)" \
        '{halted: true, reason: $reason, halted_at: $ts, epoch: $epoch}' > "$tmp" && mv "$tmp" "$HALT_FILE"
    emit_event "decision.halted" "reason=$reason"
}

autonomy_resume() {
    if [[ -f "$HALT_FILE" ]]; then
        rm -f "$HALT_FILE"
        emit_event "decision.resumed"
    fi
}

# ─── Consecutive Failure Tracking ─────────────────────────────────────────────

autonomy_check_consecutive_failures() {
    _ensure_decisions_dir
    local daily_log
    daily_log=$(_daily_log_file)
    [[ ! -f "$daily_log" ]] && return 0

    local max_consecutive
    max_consecutive=$(echo "${TIER_LIMITS:-{}}" | jq -r '.halt_after_consecutive_failures // 3')

    # Get the last N decisions and check if all failed
    local recent
    recent=$(jq -s --argjson n "$max_consecutive" '. | reverse | .[:$n]' "$daily_log" 2>/dev/null || echo '[]')
    local count
    count=$(echo "$recent" | jq 'length' 2>/dev/null || echo "0")
    [[ "$count" -lt "$max_consecutive" ]] && return 0

    local all_failed
    all_failed=$(echo "$recent" | jq --argjson n "$max_consecutive" \
        '[.[] | select(.outcome == "failure")] | length == $n' 2>/dev/null || echo "false")

    if [[ "$all_failed" == "true" ]]; then
        autonomy_halt "Halted: ${max_consecutive} consecutive failures"
        return 1
    fi
    return 0
}

# ─── Risk Ceiling ─────────────────────────────────────────────────────────────

autonomy_check_risk_ceiling() {
    local category="$1"
    local risk_score="$2"
    [[ -z "$CATEGORY_RULES" ]] && return 0

    local ceiling
    ceiling=$(echo "$CATEGORY_RULES" | jq -r --arg cat "$category" '.[$cat].risk_ceiling // 100')

    if [[ "$risk_score" -gt "$ceiling" ]]; then
        return 1
    fi
    return 0
}

# ─── Decision Recording ──────────────────────────────────────────────────────

autonomy_record_decision() {
    local decision_json="$1"
    _ensure_decisions_dir

    local daily_log
    daily_log=$(_daily_log_file)

    # Append to daily log (atomic via tmp + append)
    echo "$decision_json" >> "$daily_log"

    # Update last-decision pointer
    local tmp
    tmp=$(mktemp)
    echo "$decision_json" | jq '. + {epoch: (now | floor)}' > "$tmp" && mv "$tmp" "$LAST_DECISION_FILE"

    # Rotate old daily logs (keep 30 days)
    find "$DECISIONS_DIR" -name "daily-log-*.jsonl" -mtime +30 -delete 2>/dev/null || true
}

autonomy_record_outcome() {
    local decision_id="$1"
    local result="$2"
    local detail="${3:-}"
    _ensure_decisions_dir

    local outcome
    outcome=$(jq -n \
        --arg id "$decision_id" \
        --arg result "$result" \
        --arg detail "$detail" \
        --arg ts "$(now_iso)" \
        '{decision_id: $id, result: $result, detail: $detail, recorded_at: $ts}')

    echo "$outcome" >> "$OUTCOMES_FILE"

    # Update daily log entry with outcome
    local daily_log
    daily_log=$(_daily_log_file)
    if [[ -f "$daily_log" ]]; then
        local tmp
        tmp=$(mktemp)
        jq --arg id "$decision_id" --arg res "$result" \
            'if .id == $id then . + {outcome: $res} else . end' \
            "$daily_log" > "$tmp" && mv "$tmp" "$daily_log" || rm -f "$tmp"
    fi
}

# ─── Daily Summary ────────────────────────────────────────────────────────────

autonomy_daily_summary() {
    _ensure_decisions_dir
    local daily_log
    daily_log=$(_daily_log_file)

    if [[ ! -f "$daily_log" ]]; then
        jq -n '{date: (now | strftime("%Y-%m-%d")), total: 0, auto: 0, propose: 0, draft: 0, budget_remaining: {issues: 15, cost_usd: 25}}'
        return
    fi

    local max_issues max_cost
    max_issues=$(echo "${TIER_LIMITS:-{}}" | jq -r '.max_issues_per_day // 15')
    max_cost=$(echo "${TIER_LIMITS:-{}}" | jq -r '.max_cost_per_day_usd // 25')

    jq -s --argjson mi "$max_issues" --arg mc "$max_cost" '
        {
            date: (now | strftime("%Y-%m-%d")),
            total: length,
            auto: [.[] | select(.tier == "auto")] | length,
            propose: [.[] | select(.tier == "propose")] | length,
            draft: [.[] | select(.tier == "draft")] | length,
            successes: [.[] | select(.outcome == "success")] | length,
            failures: [.[] | select(.outcome == "failure")] | length,
            budget_remaining: {
                issues: ($mi - length),
                cost_usd: ($mc - ([.[] | .estimated_cost_usd // 0] | add // 0))
            },
            halted: false
        }
    ' "$daily_log" 2>/dev/null || echo '{}'
}
