#!/usr/bin/env bash
# config.sh — Centralized configuration reader for Shipwright
# Precedence: SHIPWRIGHT_* env var > daemon-config.json > policy-overrides.json > policy.json > defaults.json
# Usage: source "$SCRIPT_DIR/lib/config.sh"
#        val=$(_config_get "daemon.poll_interval")
[[ -n "${_SW_CONFIG_LOADED:-}" ]] && return 0
_SW_CONFIG_LOADED=1

_CONFIG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_REPO_DIR="$(cd "$_CONFIG_SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "")"

_DEFAULTS_FILE="${_CONFIG_REPO_DIR}/config/defaults.json"
_POLICY_FILE="${_CONFIG_REPO_DIR}/config/policy.json"
_DAEMON_CONFIG_FILE=".claude/daemon-config.json"
_POLICY_OVERRIDES_FILE=".claude/policy-overrides.json"

# Resolve daemon config and policy overrides relative to git root or cwd
if [[ ! -f "$_DAEMON_CONFIG_FILE" ]]; then
    local_root="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
    _DAEMON_CONFIG_FILE="${local_root}/.claude/daemon-config.json"
    _POLICY_OVERRIDES_FILE="${local_root}/.claude/policy-overrides.json"
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

    # 3. Check policy-overrides.json (adaptive/operator overrides)
    if [[ -f "$_POLICY_OVERRIDES_FILE" ]]; then
        local val
        val=$(jq -r "${jq_path} // \"\"" "$_POLICY_OVERRIDES_FILE" 2>/dev/null || echo "")
        if [[ -n "$val" && "$val" != "null" ]]; then
            echo "$val"
            return 0
        fi
    fi

    # 4. Check policy.json
    if [[ -f "$_POLICY_FILE" ]]; then
        local val
        val=$(jq -r "${jq_path} // \"\"" "$_POLICY_FILE" 2>/dev/null || echo "")
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
