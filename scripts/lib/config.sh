#!/usr/bin/env bash
# config.sh — Centralized configuration reader for Shipwright
# Precedence: SHIPWRIGHT_* env var > daemon-config.json > hardcoded-values.json > defaults.json
# Usage: source "$SCRIPT_DIR/lib/config.sh"
#        val=$(_config_get "daemon.poll_interval")
#        _config_get_validated "loop.extension_size" --type=integer --min=1 --max=10
[[ -n "${_SW_CONFIG_LOADED:-}" ]] && return 0
_SW_CONFIG_LOADED=1

_CONFIG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_REPO_DIR="$(cd "$_CONFIG_SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "")"

_DEFAULTS_FILE="${_CONFIG_REPO_DIR}/config/defaults.json"
_POLICY_FILE="${_CONFIG_REPO_DIR}/config/policy.json"
_HARDCODED_VALUES_FILE="${_CONFIG_REPO_DIR}/config/hardcoded-values.json"
_DAEMON_CONFIG_FILE=".claude/daemon-config.json"

# Resolve daemon config relative to git root or cwd
if [[ ! -f "$_DAEMON_CONFIG_FILE" ]]; then
    local_root="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
    _DAEMON_CONFIG_FILE="${local_root}/.claude/daemon-config.json"
fi

# _config_get "section.key" [default]
# Reads config with full precedence chain
_config_get() {
    local dotpath="$1"
    local fallback="${2:-}"

    # 1. Check env var: daemon.poll_interval -> SHIPWRIGHT_DAEMON_POLL_INTERVAL
    local env_name="SHIPWRIGHT_$(echo "$dotpath" | tr '[:lower:].' '[:upper:]_')"
    local env_val="${!env_name:-}"
    if [[ -n "$env_val" ]]; then
        echo "$env_val"
        return 0
    fi

    # Convert dotpath to jq path: "daemon.poll_interval" -> ".daemon.poll_interval"
    local jq_path=".${dotpath}"

    # 2. Check daemon-config.json
    if [[ -f "$_DAEMON_CONFIG_FILE" ]]; then
        local val
        val=$(jq -r "${jq_path} // \"\"" "$_DAEMON_CONFIG_FILE" 2>/dev/null || echo "")
        if [[ -n "$val" && "$val" != "null" ]]; then
            echo "$val"
            return 0
        fi
    fi

    # 3. Check policy.json (for policy-level config)
    if [[ -f "$_POLICY_FILE" ]]; then
        local val
        val=$(jq -r "${jq_path} // \"\"" "$_POLICY_FILE" 2>/dev/null || echo "")
        if [[ -n "$val" && "$val" != "null" ]]; then
            echo "$val"
            return 0
        fi
    fi

    # 4. Check hardcoded-values.json (discovered hardcoded values)
    if [[ -f "$_HARDCODED_VALUES_FILE" ]]; then
        local val
        # Convert dotpath to policy path: "loop.extension_size" -> ".policies[\"loop.extension_size\"].value"
        val=$(jq -r ".policies[\"${dotpath}\"].value // \"\"" "$_HARDCODED_VALUES_FILE" 2>/dev/null || echo "")
        if [[ -n "$val" && "$val" != "null" ]]; then
            echo "$val"
            return 0
        fi
    fi

    # 5. Check defaults.json
    if [[ -f "$_DEFAULTS_FILE" ]]; then
        local val
        val=$(jq -r "${jq_path} // \"\"" "$_DEFAULTS_FILE" 2>/dev/null || echo "")
        if [[ -n "$val" && "$val" != "null" ]]; then
            echo "$val"
            return 0
        fi
    fi

    # 6. Return fallback
    echo "$fallback"
}

# _config_get_int "section.key" [default]
# Same as _config_get but ensures integer output
_config_get_int() {
    local val
    val=$(_config_get "$1" "${2:-0}")
    # Strip non-numeric
    echo "${val//[!0-9-]/}"
}

# _config_get_bool "section.key" [default]
# Returns 0 (true) or 1 (false) for use in conditionals
_config_get_bool() {
    local val
    val=$(_config_get "$1" "${2:-false}")
    case "$val" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# _config_get_validated "policy.key" --type=<type> --min=<min> --max=<max> [--default=<val>]
# Returns value if within bounds, otherwise errors
_config_get_validated() {
    local policy_key="$1"
    shift

    local type="integer"
    local min=""
    local max=""
    local default=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type=*) type="${1#*=}" ;;
            --min=*) min="${1#*=}" ;;
            --max=*) max="${1#*=}" ;;
            --default=*) default="${1#*=}" ;;
            *) ;;
        esac
        shift
    done

    # Get value
    local val
    val=$(_config_get "$policy_key" "$default")

    # Validate integer type
    if [[ "$type" == "integer" ]]; then
        # Strip non-numeric
        val="${val//[!0-9-]/}"

        # Check bounds
        if [[ -n "$min" && $val -lt $min ]]; then
            echo "ERROR: policy $policy_key value $val is below minimum $min" >&2
            return 2
        fi
        if [[ -n "$max" && $val -gt $max ]]; then
            echo "ERROR: policy $policy_key value $val exceeds maximum $max" >&2
            return 2
        fi
    fi

    echo "$val"
    return 0
}

# _config_has_override "policy.key"
# Returns 0 if overridden, 1 if using default
_config_has_override() {
    local policy_key="$1"
    local dotpath="$policy_key"

    # Check env var
    local env_name="SHIPWRIGHT_$(echo "$dotpath" | tr '[:lower:].' '[:upper:]_')"
    [[ -n "${!env_name:-}" ]] && return 0

    # Check daemon-config.json
    [[ -f "$_DAEMON_CONFIG_FILE" ]] && \
        jq -e ".${dotpath}" "$_DAEMON_CONFIG_FILE" >/dev/null 2>&1 && return 0

    # Check policy.json
    [[ -f "$_POLICY_FILE" ]] && \
        jq -e ".${dotpath}" "$_POLICY_FILE" >/dev/null 2>&1 && return 0

    # Check hardcoded-values.json
    [[ -f "$_HARDCODED_VALUES_FILE" ]] && \
        jq -e ".policies[\"${dotpath}\"]" "$_HARDCODED_VALUES_FILE" >/dev/null 2>&1 && return 0

    return 1
}

# _config_confidence "policy.key"
# Returns confidence score (0.0-1.0) from hardcoded-values metadata
_config_confidence() {
    local policy_key="$1"

    if [[ -f "$_HARDCODED_VALUES_FILE" ]]; then
        jq -r ".policies[\"${policy_key}\"].confidence // 0.5" "$_HARDCODED_VALUES_FILE" 2>/dev/null || echo "0.5"
    else
        echo "0.5"
    fi
}
