# decide-scoring.sh — Value scoring for the decision engine
# Source from sw-decide.sh. Requires helpers.sh.
[[ -n "${_DECIDE_SCORING_LOADED:-}" ]] && return 0
_DECIDE_SCORING_LOADED=1

# ─── State ────────────────────────────────────────────────────────────────────
WEIGHTS_FILE="${HOME}/.shipwright/decisions/weights.json"

# Default weights
_W_IMPACT=30
_W_URGENCY=25
_W_EFFORT=20
_W_CONFIDENCE=15
_W_RISK=10

# ─── Weight Management ───────────────────────────────────────────────────────

scoring_load_weights() {
    if [[ -f "$WEIGHTS_FILE" ]]; then
        _W_IMPACT=$(jq -r '.impact // 30' "$WEIGHTS_FILE" 2>/dev/null || echo "30")
        _W_URGENCY=$(jq -r '.urgency // 25' "$WEIGHTS_FILE" 2>/dev/null || echo "25")
        _W_EFFORT=$(jq -r '.effort // 20' "$WEIGHTS_FILE" 2>/dev/null || echo "20")
        _W_CONFIDENCE=$(jq -r '.confidence // 15' "$WEIGHTS_FILE" 2>/dev/null || echo "15")
        _W_RISK=$(jq -r '.risk // 10' "$WEIGHTS_FILE" 2>/dev/null || echo "10")
    fi

    # Also try loading from tiers config
    if [[ -n "${TIERS_FILE:-}" && -f "${TIERS_FILE:-}" ]]; then
        local cfg_impact
        cfg_impact=$(jq -r '.scoring_weights.impact // empty' "$TIERS_FILE" 2>/dev/null || true)
        if [[ -n "$cfg_impact" ]]; then
            _W_IMPACT=$(echo "$cfg_impact" | awk '{printf "%.0f", $1 * 100}')
            _W_URGENCY=$(jq -r '.scoring_weights.urgency' "$TIERS_FILE" | awk '{printf "%.0f", $1 * 100}')
            _W_EFFORT=$(jq -r '.scoring_weights.effort' "$TIERS_FILE" | awk '{printf "%.0f", $1 * 100}')
            _W_CONFIDENCE=$(jq -r '.scoring_weights.confidence' "$TIERS_FILE" | awk '{printf "%.0f", $1 * 100}')
            _W_RISK=$(jq -r '.scoring_weights.risk' "$TIERS_FILE" | awk '{printf "%.0f", $1 * 100}')
        fi
    fi
}

scoring_save_weights() {
    mkdir -p "$(dirname "$WEIGHTS_FILE")"
    local tmp
    tmp=$(mktemp)
    jq -n \
        --argjson i "$_W_IMPACT" \
        --argjson u "$_W_URGENCY" \
        --argjson e "$_W_EFFORT" \
        --argjson c "$_W_CONFIDENCE" \
        --argjson r "$_W_RISK" \
        --arg ts "$(now_iso)" \
        '{impact:$i, urgency:$u, effort:$e, confidence:$c, risk:$r, updated_at:$ts}' \
        > "$tmp" && mv "$tmp" "$WEIGHTS_FILE"
}

# ─── Dimension Scorers ────────────────────────────────────────────────────────
# Each returns 0-100

_score_impact() {
    local candidate="$1"
    local signal category risk_score
    signal=$(echo "$candidate" | jq -r '.signal // "unknown"')
    category=$(echo "$candidate" | jq -r '.category // "unknown"')
    risk_score=$(echo "$candidate" | jq -r '.risk_score // 50')

    case "$signal" in
        security)
            local severity
            severity=$(echo "$candidate" | jq -r '.evidence.severity // "medium"')
            case "$severity" in
                critical) echo 90 ;; high) echo 70 ;; medium) echo 50 ;; *) echo 30 ;;
            esac ;;
        deps)
            local diff
            diff=$(echo "$candidate" | jq -r '.evidence.major_versions_behind // 1')
            if [[ "${diff:-1}" -ge 3 ]]; then echo 70
            elif [[ "${diff:-1}" -ge 2 ]]; then echo 55
            else echo 35; fi ;;
        coverage)  echo 45 ;;
        docs)      echo 30 ;;
        dead_code) echo 25 ;;
        performance)
            local pct
            pct=$(echo "$candidate" | jq -r '.evidence.regression_pct // 0')
            if [[ "${pct:-0}" -ge 50 ]]; then echo 75
            elif [[ "${pct:-0}" -ge 30 ]]; then echo 60
            else echo 40; fi ;;
        failures)  echo 55 ;;
        dora)      echo 60 ;;
        architecture) echo 50 ;;
        intelligence) echo 45 ;;
        *) echo 40 ;;
    esac
}

_score_urgency() {
    local candidate="$1"
    local signal
    signal=$(echo "$candidate" | jq -r '.signal // "unknown"')

    case "$signal" in
        security)
            local severity
            severity=$(echo "$candidate" | jq -r '.evidence.severity // "medium"')
            case "$severity" in
                critical) echo 95 ;; high) echo 75 ;; *) echo 45 ;;
            esac ;;
        performance) echo 60 ;;
        dora)        echo 55 ;;
        failures)    echo 65 ;;
        deps)        echo 35 ;;
        coverage)    echo 30 ;;
        docs)        echo 20 ;;
        dead_code)   echo 15 ;;
        *)           echo 40 ;;
    esac
}

_score_effort() {
    # Inverted: easy = high score, hard = low score
    local candidate="$1"
    local category
    category=$(echo "$candidate" | jq -r '.category // "unknown"')

    case "$category" in
        deps_patch)             echo 90 ;;
        deps_minor)             echo 75 ;;
        doc_sync)               echo 85 ;;
        dead_code)              echo 70 ;;
        test_coverage)          echo 60 ;;
        security_patch)         echo 65 ;;
        deps_major)             echo 40 ;;
        security_critical)      echo 45 ;;
        performance_regression) echo 35 ;;
        recurring_failure)      echo 30 ;;
        refactor_hotspot)       echo 25 ;;
        architecture_drift)     echo 20 ;;
        dora_regression)        echo 30 ;;
        *)                      echo 50 ;;
    esac
}

_score_confidence() {
    local candidate="$1"
    local raw_conf
    raw_conf=$(echo "$candidate" | jq -r '.confidence // "0.80"')
    # Convert 0.0-1.0 to 0-100
    echo "$raw_conf" | awk '{printf "%.0f", $1 * 100}'
}

_score_risk() {
    local candidate="$1"
    local risk_score
    risk_score=$(echo "$candidate" | jq -r '.risk_score // 50')
    echo "$risk_score"
}

# ─── Main Scorer ──────────────────────────────────────────────────────────────

score_candidate() {
    local candidate="$1"

    local impact urgency effort confidence risk
    impact=$(_score_impact "$candidate")
    urgency=$(_score_urgency "$candidate")
    effort=$(_score_effort "$candidate")
    confidence=$(_score_confidence "$candidate")
    risk=$(_score_risk "$candidate")

    # Formula: value = (impact * w1) + (urgency * w2) + (effort * w3) + (confidence * w4) - (risk * w5)
    # All weights are integers summing to 100, scores are 0-100
    local value
    value=$(( (impact * _W_IMPACT + urgency * _W_URGENCY + effort * _W_EFFORT + confidence * _W_CONFIDENCE - risk * _W_RISK) / 100 ))

    # Clamp to 0-100
    [[ "$value" -lt 0 ]] && value=0
    [[ "$value" -gt 100 ]] && value=100

    echo "$candidate" | jq \
        --argjson vs "$value" \
        --argjson imp "$impact" \
        --argjson urg "$urgency" \
        --argjson eff "$effort" \
        --argjson conf "$confidence" \
        --argjson rsk "$risk" \
        '. + {value_score: $vs, scores: {impact: $imp, urgency: $urg, effort: $eff, confidence: $conf, risk: $rsk}}'
}

# ─── Outcome Learning ────────────────────────────────────────────────────────
# EMA (exponential moving average) weight adjustment based on decision outcomes

scoring_update_weights() {
    local outcome="$1"
    local result
    result=$(echo "$outcome" | jq -r '.result // "unknown"')
    local alpha=20  # EMA factor (out of 100): 20% new, 80% old

    # Adjust weights based on which dimension was most predictive
    # Success: boost the dominant scoring dimension; Failure: dampen it
    local signal
    signal=$(echo "$outcome" | jq -r '.signal // "unknown"')

    case "$result" in
        success)
            case "$signal" in
                security)     _W_URGENCY=$(( (_W_URGENCY * (100 - alpha) + 30 * alpha) / 100 )) ;;
                deps)         _W_EFFORT=$(( (_W_EFFORT * (100 - alpha) + 25 * alpha) / 100 )) ;;
                performance)  _W_IMPACT=$(( (_W_IMPACT * (100 - alpha) + 35 * alpha) / 100 )) ;;
                failures)     _W_URGENCY=$(( (_W_URGENCY * (100 - alpha) + 30 * alpha) / 100 )) ;;
                *)            ;; # No adjustment for generic signals
            esac ;;
        failure)
            # On failure, slightly increase risk weight
            _W_RISK=$(( (_W_RISK * (100 - alpha) + 15 * alpha) / 100 )) ;;
    esac

    # Normalize weights to sum to 100
    local total=$(( _W_IMPACT + _W_URGENCY + _W_EFFORT + _W_CONFIDENCE + _W_RISK ))
    if [[ "$total" -gt 0 && "$total" -ne 100 ]]; then
        _W_IMPACT=$(( _W_IMPACT * 100 / total ))
        _W_URGENCY=$(( _W_URGENCY * 100 / total ))
        _W_EFFORT=$(( _W_EFFORT * 100 / total ))
        _W_CONFIDENCE=$(( _W_CONFIDENCE * 100 / total ))
        _W_RISK=$((100 - _W_IMPACT - _W_URGENCY - _W_EFFORT - _W_CONFIDENCE))
    fi

    scoring_save_weights
}
