#!/usr/bin/env bash
# fallback-policy.sh — Config-driven fallback resolver with adaptive override hooks
#
# Adds exactly ONE resolution tier (a learned adaptive override) on top of the
# existing config chain. Single entry point: _smart_fallback.
#
# Precedence (highest to lowest):
#   1. env SW_<KEY>                                  (manual override)
#   2. daemon-config.json .fallback_overrides.<key>  (manual override)
#   3. learned adaptive override                     (IFF learning_enabled
#        ~/.shipwright/adaptive-overrides.json          && confidence>=threshold,
#        clamped to adaptive_range)                       value in/near range)
#   4. config/fallback-policy.json .policies[key].static (static policy)
#   5. hardcoded_default argument                    (== today's call-site literal)
#
# Fail-safe by contract: any missing/corrupt config, invalid key, or empty
# result falls through to hardcoded_default. NEVER returns empty. No logging on
# the hot path. Bash 3.2 compatible (no declare -A / ${var^^} / readarray).
#
# Usage: source "$SCRIPT_DIR/lib/fallback-policy.sh"
#        val=$(_smart_fallback "network.gh_timeout" 30)

[[ -n "${_SW_FALLBACK_POLICY_LOADED:-}" ]] && return 0
_SW_FALLBACK_POLICY_LOADED=1

_FBP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FBP_REPO_DIR="$(cd "$_FBP_SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "")"

# Allow override (mainly for tests); otherwise resolve relative to repo root.
_FBP_POLICY_FILE="${SW_FALLBACK_POLICY_FILE:-${_FBP_REPO_DIR}/config/fallback-policy.json}"
_FBP_OVERRIDES_FILE="${SW_FALLBACK_OVERRIDES_FILE:-${HOME}/.shipwright/adaptive-overrides.json}"

# Per-process cache of the policy file contents (avoids repeated jq spawns / FS reads).
_FBP_POLICY_CACHE=""
_FBP_POLICY_CACHE_SET=""

_fbp_load_policy() {
    if [[ -z "$_FBP_POLICY_CACHE_SET" ]]; then
        _FBP_POLICY_CACHE_SET=1
        if [[ -f "$_FBP_POLICY_FILE" ]]; then
            _FBP_POLICY_CACHE="$(cat "$_FBP_POLICY_FILE" 2>/dev/null || echo "")"
        fi
    fi
    printf '%s' "$_FBP_POLICY_CACHE"
}

# _fallback_clamp <value> <min> <max> -> echoes value clamped to [min,max].
# Non-numeric value (or non-numeric bounds) -> echoes value unchanged.
_fallback_clamp() {
    local value="$1" min="$2" max="$3"
    awk -v v="$value" -v lo="$min" -v hi="$max" '
        function isnum(x){ return (x ~ /^-?[0-9]+(\.[0-9]+)?$/) }
        BEGIN{
            if (!isnum(v) || !isnum(lo) || !isnum(hi)) { print v; exit }
            if (v < lo) { print lo; exit }
            if (v > hi) { print hi; exit }
            print v
        }' 2>/dev/null || printf '%s' "$value"
}

# _smart_fallback <policy_key> <hardcoded_default> -> echoes resolved value.
# Pure (no side effects). NEVER empty.
_smart_fallback() {
    local key="$1" default="${2:-}"

    # Invalid key -> fail-safe to default.
    if [[ ! "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]]; then
        printf '%s' "$default"
        return 0
    fi

    # 1. Env override: network.gh_timeout -> SW_NETWORK_GH_TIMEOUT
    local env_key env_val=""
    env_key="SW_$(echo "$key" | tr '[:lower:].' '[:upper:]_')"
    eval 'env_val="${'"$env_key"':-}"' 2>/dev/null || true
    if [[ -n "$env_val" ]]; then
        printf '%s' "$env_val"
        return 0
    fi

    # 2. daemon-config.json .fallback_overrides[<key>] (flat dotted key)
    local cfg="${DAEMON_CONFIG:-${WORK_DIR:-.}/.claude/daemon-config.json}"
    if [[ -f "$cfg" ]]; then
        local cfg_val
        cfg_val=$(jq -r --arg k "$key" '.fallback_overrides[$k] // empty' "$cfg" 2>/dev/null || true)
        if [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
            printf '%s' "$cfg_val"
            return 0
        fi
    fi

    # Load policy declaration once (cached).
    local policy
    policy="$(_fbp_load_policy)"

    # 3. Adaptive override (only if policy declares learning_enabled).
    if [[ -n "$policy" ]]; then
        local learning_enabled
        learning_enabled=$(printf '%s' "$policy" | jq -r --arg k "$key" \
            '.policies[$k].learning_enabled // false' 2>/dev/null || echo "false")
        if [[ "$learning_enabled" == "true" && -f "$_FBP_OVERRIDES_FILE" ]]; then
            local learned conf threshold range_min range_max
            learned=$(jq -r --arg k "$key" '.[$k].value // empty' "$_FBP_OVERRIDES_FILE" 2>/dev/null || true)
            conf=$(jq -r --arg k "$key" '.[$k].confidence // 0' "$_FBP_OVERRIDES_FILE" 2>/dev/null || echo 0)
            threshold=$(printf '%s' "$policy" | jq -r --arg k "$key" \
                '.policies[$k].confidence_threshold // 0.85' 2>/dev/null || echo "0.85")
            range_min=$(printf '%s' "$policy" | jq -r --arg k "$key" \
                '.policies[$k].adaptive_range[0] // empty' 2>/dev/null || true)
            range_max=$(printf '%s' "$policy" | jq -r --arg k "$key" \
                '.policies[$k].adaptive_range[1] // empty' 2>/dev/null || true)
            if [[ -n "$learned" && "$learned" != "null" ]]; then
                # Gate on confidence >= threshold (float-safe via awk).
                local confident
                confident=$(awk -v c="$conf" -v t="$threshold" \
                    'BEGIN{ print (c+0 >= t+0) ? "1" : "0" }' 2>/dev/null || echo 0)
                if [[ "$confident" == "1" ]]; then
                    if [[ -n "$range_min" && -n "$range_max" ]]; then
                        learned=$(_fallback_clamp "$learned" "$range_min" "$range_max")
                    fi
                    printf '%s' "$learned"
                    return 0
                fi
            fi
        fi
    fi

    # 4. Static policy value.
    if [[ -n "$policy" ]]; then
        local static_val
        static_val=$(printf '%s' "$policy" | jq -r --arg k "$key" \
            '.policies[$k].static // empty' 2>/dev/null || true)
        if [[ -n "$static_val" && "$static_val" != "null" ]]; then
            printf '%s' "$static_val"
            return 0
        fi
    fi

    # 5. Hardcoded default (fail-safe).
    printf '%s' "$default"
}

# _fallback_audit [dir] -> emits JSONL {file,line,variable,default,context} to stdout.
# Read-only scan of *.sh for ${VAR:-default} fallback patterns. Non-zero on fs error.
_fallback_audit() {
    local dir="${1:-${_FBP_REPO_DIR}/scripts}"
    [[ -d "$dir" ]] || { echo "audit: directory not found: $dir" >&2; return 1; }

    # Match ${VAR:-default} occurrences. One JSON object per match.
    grep -rnoE '\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\}' "$dir" --include='*.sh' 2>/dev/null | \
    while IFS= read -r match; do
        local file line expr var default context
        file="${match%%:*}"
        local rest="${match#*:}"
        line="${rest%%:*}"
        expr="${rest#*:}"
        # expr looks like ${VAR:-default}
        var="${expr#\$\{}"
        var="${var%%:-*}"
        default="${expr#*:-}"
        default="${default%\}}"
        context="$(basename "$file")"
        jq -n -c \
            --arg file "$file" \
            --arg line "$line" \
            --arg variable "$var" \
            --arg default "$default" \
            --arg context "$context" \
            '{file:$file, line:($line|tonumber), variable:$variable, default:$default, context:$context}' \
            2>/dev/null || true
    done
}
