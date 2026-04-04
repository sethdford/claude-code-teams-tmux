#!/usr/bin/env bash
# config.sh — Centralized configuration reader for Shipwright
# Precedence: SHIPWRIGHT_* env var > daemon-config.json > policy.json > defaults.json
# Usage: source "$SCRIPT_DIR/lib/config.sh"
#        val=$(_config_get "daemon.poll_interval")
[[ -n "${_SW_CONFIG_LOADED:-}" ]] && return 0
_SW_CONFIG_LOADED=1

_CONFIG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_REPO_DIR="$(cd "$_CONFIG_SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "")"

_DEFAULTS_FILE="${_CONFIG_REPO_DIR}/config/defaults.json"
_POLICY_FILE="${_CONFIG_REPO_DIR}/config/policy.json"
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

    # 3. Check policy.json
    if [[ -f "$_POLICY_FILE" ]]; then
        local val
        val=$(jq -r "${jq_path} // \"\"" "$_POLICY_FILE" 2>/dev/null || echo "")
        if [[ -n "$val" && "$val" != "null" ]]; then
            echo "$val"
            return 0
        fi
    fi

    # 4. Check defaults.json
    if [[ -f "$_DEFAULTS_FILE" ]]; then
        local val
        val=$(jq -r "${jq_path} // \"\"" "$_DEFAULTS_FILE" 2>/dev/null || echo "")
        if [[ -n "$val" && "$val" != "null" ]]; then
            echo "$val"
            return 0
        fi
    fi

    # 5. Return fallback
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

# _config_validate_file <file> <schema>
# Validates a JSON file against a JSON Schema using jq type checks.
# Returns 0 if valid, 1 if invalid. Prints errors to stderr.
# Skips silently (returns 0) if jq is unavailable or schema file missing.
_config_validate_file() {
    local file="$1" schema="$2"
    [[ -f "$file" ]] || { echo "config-validate: file not found: $file" >&2; return 1; }
    [[ -f "$schema" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    # Run validation in a subshell to isolate from caller's set -e
    local _val_output _val_rc=0
    _val_output=$(
        set +e
        errors=0

        # Validate JSON syntax first
        if ! jq empty "$file" 2>/dev/null; then
            echo "config-validate: invalid JSON in $file" >&2
            exit 1
        fi

        # Check each section defined in schema for type mismatches
        sections=$(jq -r '.properties | keys[] | select(. != "$schema" and . != "description" and . != "version")' "$schema" 2>/dev/null) || exit 0

        for section in $sections; do
            # Skip if section not present in file
            jq -e ".$section" "$file" >/dev/null 2>&1 || continue

            section_type=$(jq -r ".properties.\"$section\".type // \"\"" "$schema" 2>/dev/null)
            [[ "$section_type" == "object" ]] || continue

            # Check each key in the section
            keys=$(jq -r ".properties.\"$section\".properties // {} | keys[]" "$schema" 2>/dev/null) || continue

            for key in $keys; do
                jq -e ".$section.\"$key\"" "$file" >/dev/null 2>&1 || continue

                expected_type=$(jq -r ".properties.\"$section\".properties.\"$key\".type // \"\"" "$schema" 2>/dev/null)
                actual_type=$(jq -r ".$section.\"$key\" | type" "$file" 2>/dev/null)

                case "$expected_type" in
                    integer)
                        if [[ "$actual_type" != "number" ]]; then
                            echo "config-validate: $section.$key: expected integer, got $actual_type" >&2
                            errors=$((errors + 1))
                        fi
                        ;;
                    number)
                        if [[ "$actual_type" != "number" ]]; then
                            echo "config-validate: $section.$key: expected number, got $actual_type" >&2
                            errors=$((errors + 1))
                        fi
                        ;;
                    string)
                        if [[ "$actual_type" != "string" ]]; then
                            echo "config-validate: $section.$key: expected string, got $actual_type" >&2
                            errors=$((errors + 1))
                        fi
                        ;;
                    boolean)
                        if [[ "$actual_type" != "boolean" ]]; then
                            echo "config-validate: $section.$key: expected boolean, got $actual_type" >&2
                            errors=$((errors + 1))
                        fi
                        ;;
                    array)
                        if [[ "$actual_type" != "array" ]]; then
                            echo "config-validate: $section.$key: expected array, got $actual_type" >&2
                            errors=$((errors + 1))
                        fi
                        ;;
                esac
            done

            # Check for unknown keys if additionalProperties is false
            additional=$(jq -r ".properties.\"$section\" | if has(\"additionalProperties\") then .additionalProperties else true end" "$schema" 2>/dev/null)
            if [[ "$additional" == "false" ]]; then
                actual_keys=$(jq -r ".$section | keys[]" "$file" 2>/dev/null) || continue
                for akey in $actual_keys; do
                    if ! jq -e ".properties.\"$section\".properties.\"$akey\"" "$schema" >/dev/null 2>&1; then
                        echo "config-validate: $section.$akey: unknown key" >&2
                        errors=$((errors + 1))
                    fi
                done
            fi
        done

        [[ $errors -eq 0 ]] && exit 0 || exit 1
    ) 2>&1 || _val_rc=$?

    if [[ -n "$_val_output" ]]; then
        echo "$_val_output" >&2
    fi
    return "$_val_rc"
}

# _config_validate [--strict]
# Validates defaults.json (and daemon-config.json if present) against their schemas.
# --strict: exits 1 on validation errors (for daemon startup)
# Without --strict: prints warnings, always returns 0
_config_validate() {
    local strict=false
    [[ "${1:-}" == "--strict" ]] && strict=true

    command -v jq >/dev/null 2>&1 || return 0

    local schema_file="${_CONFIG_REPO_DIR}/config/defaults.schema.json"
    local has_errors=false

    # Validate defaults.json
    if [[ -f "$_DEFAULTS_FILE" && -f "$schema_file" ]]; then
        if ! _config_validate_file "$_DEFAULTS_FILE" "$schema_file"; then
            has_errors=true
        fi
    fi

    # Validate daemon-config.json against the same schema (subset)
    if [[ -f "$_DAEMON_CONFIG_FILE" && -f "$schema_file" ]]; then
        if ! _config_validate_file "$_DAEMON_CONFIG_FILE" "$schema_file"; then
            has_errors=true
        fi
    fi

    if [[ "$has_errors" == "true" ]]; then
        if [[ "$strict" == "true" ]]; then
            echo "config-validate: strict mode — aborting due to config errors" >&2
            return 1
        fi
    fi
    return 0
}
