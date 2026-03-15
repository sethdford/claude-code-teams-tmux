#!/usr/bin/env bash
# config-validate.sh — Schema validation for daemon-config.json
# Usage: source "$SCRIPT_DIR/lib/config-validate.sh"
#        _validate_daemon_config "/path/to/daemon-config.json"
[[ -n "${_SW_CONFIG_VALIDATE_LOADED:-}" ]] && return 0
_SW_CONFIG_VALIDATE_LOADED=1

VERSION="3.2.4"

_CV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CV_REPO_DIR="$(cd "$_CV_SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "")"
_CV_SCHEMA_FILE="${_CV_REPO_DIR}/config/daemon-config.schema.json"

# ─── Helpers (use shared helpers if loaded, otherwise minimal fallbacks) ──────
if [[ "$(type -t error 2>/dev/null)" != "function" ]]; then
    _cv_error() { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
else
    _cv_error() { error "$@"; }
fi
if [[ "$(type -t warn 2>/dev/null)" != "function" ]]; then
    _cv_warn() { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*" >&2; }
else
    _cv_warn() { warn "$@"; }
fi
if [[ "$(type -t info 2>/dev/null)" != "function" ]]; then
    _cv_info() { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
else
    _cv_info() { info "$@"; }
fi
if [[ "$(type -t success 2>/dev/null)" != "function" ]]; then
    _cv_success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
else
    _cv_success() { success "$@"; }
fi

# ─── _validate_json_syntax ───────────────────────────────────────────────────
# Validates that a file contains valid JSON.
# Returns 0 on success, 1 on failure. Prints error details on failure.
_validate_json_syntax() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        _cv_error "Config file not found: $file"
        return 1
    fi
    local parse_err
    parse_err=$(jq '.' "$file" 2>&1 >/dev/null) || {
        _cv_error "Invalid JSON in $file"
        _cv_error "  $parse_err"
        return 1
    }
    return 0
}

# ─── _validate_type ──────────────────────────────────────────────────────────
# Validates a single field's type against expected type.
# Usage: _validate_type "$value" "$type" "$field_name"
# Returns 0 on match, 1 on mismatch
_validate_type() {
    local value="$1" expected_type="$2" field="$3"
    local actual_type
    actual_type=$(echo "$value" | jq -r 'type' 2>/dev/null) || {
        _cv_error "  $field: cannot determine type"
        return 1
    }

    case "$expected_type" in
        integer)
            if [[ "$actual_type" != "number" ]]; then
                _cv_error "  $field: expected integer, got $actual_type"
                return 1
            fi
            # Check it's actually an integer (no decimal)
            local is_int
            is_int=$(echo "$value" | jq 'if . == (. | floor) then "yes" else "no" end' 2>/dev/null)
            if [[ "$is_int" == '"no"' ]]; then
                _cv_error "  $field: expected integer, got float"
                return 1
            fi
            ;;
        number)
            if [[ "$actual_type" != "number" ]]; then
                _cv_error "  $field: expected number, got $actual_type"
                return 1
            fi
            ;;
        string)
            if [[ "$actual_type" != "string" ]]; then
                _cv_error "  $field: expected string, got $actual_type"
                return 1
            fi
            ;;
        boolean)
            if [[ "$actual_type" != "boolean" ]]; then
                _cv_error "  $field: expected boolean, got $actual_type"
                return 1
            fi
            ;;
        object)
            if [[ "$actual_type" != "object" ]]; then
                _cv_error "  $field: expected object, got $actual_type"
                return 1
            fi
            ;;
        array)
            if [[ "$actual_type" != "array" ]]; then
                _cv_error "  $field: expected array, got $actual_type"
                return 1
            fi
            ;;
    esac
    return 0
}

# ─── _validate_range ─────────────────────────────────────────────────────────
# Validates numeric value against min/max bounds from schema.
# Usage: _validate_range "$value" "$min" "$max" "$field_name"
_validate_range() {
    local value="$1" min="$2" max="$3" field="$4"
    if [[ -n "$min" && "$min" != "null" ]]; then
        local below
        below=$(echo "$value" | jq --argjson min "$min" '. < $min' 2>/dev/null)
        if [[ "$below" == "true" ]]; then
            _cv_error "  $field: value $(echo "$value" | jq '.') is below minimum $min"
            return 1
        fi
    fi
    if [[ -n "$max" && "$max" != "null" ]]; then
        local above
        above=$(echo "$value" | jq --argjson max "$max" '. > $max' 2>/dev/null)
        if [[ "$above" == "true" ]]; then
            _cv_error "  $field: value $(echo "$value" | jq '.') exceeds maximum $max"
            return 1
        fi
    fi
    return 0
}

# ─── _validate_enum ──────────────────────────────────────────────────────────
# Validates a string value against an enum list from schema.
# Usage: _validate_enum "$value" "$enum_json_array" "$field_name"
_validate_enum() {
    local value="$1" enum_array="$2" field="$3"
    if [[ -z "$enum_array" || "$enum_array" == "null" ]]; then
        return 0
    fi
    local match
    match=$(jq -n --argjson val "$value" --argjson enum "$enum_array" \
        '$enum | index($val) != null' 2>/dev/null)
    if [[ "$match" != "true" ]]; then
        local allowed
        allowed=$(echo "$enum_array" | jq -r 'join(", ")' 2>/dev/null)
        _cv_error "  $field: value $(echo "$value" | jq '.') not in allowed values [$allowed]"
        return 1
    fi
    return 0
}

# ─── _validate_daemon_config ────────────────────────────────────────────────
# Main entry point: validates daemon-config.json against schema.
# Usage: _validate_daemon_config "/path/to/config.json" ["/path/to/schema.json"]
# Returns 0 if valid, 1 if invalid. Prints all errors found.
_validate_daemon_config() {
    local config_file="${1:-.claude/daemon-config.json}"
    local schema_file="${2:-$_CV_SCHEMA_FILE}"
    local errors=0

    # Skip validation if SKIP_CONFIG_VALIDATION is set
    if [[ "${SKIP_CONFIG_VALIDATION:-}" == "true" ]]; then
        _cv_info "Config validation skipped (SKIP_CONFIG_VALIDATION=true)"
        return 0
    fi

    # Check schema file exists
    if [[ ! -f "$schema_file" ]]; then
        _cv_warn "Schema file not found: $schema_file — skipping validation"
        return 0
    fi

    # Step 1: Validate JSON syntax
    if ! _validate_json_syntax "$config_file"; then
        return 1
    fi

    # Step 2: Validate top-level must be an object
    local root_type
    root_type=$(jq -r 'type' "$config_file" 2>/dev/null)
    if [[ "$root_type" != "object" ]]; then
        _cv_error "Config must be a JSON object, got $root_type"
        return 1
    fi

    # Step 3: Validate each present field against schema
    local fields
    fields=$(jq -r 'keys[]' "$config_file" 2>/dev/null) || {
        _cv_error "Failed to read config keys"
        return 1
    }

    while IFS= read -r field; do
        [[ -z "$field" ]] && continue

        # Get schema definition for this field
        local schema_def
        schema_def=$(jq -r --arg f "$field" '.properties[$f] // empty' "$schema_file" 2>/dev/null)
        if [[ -z "$schema_def" ]]; then
            # Field not in schema — allowed (additionalProperties: true)
            continue
        fi

        # Get the value and expected type
        local value expected_type
        value=$(jq --arg f "$field" '.[$f]' "$config_file" 2>/dev/null)
        expected_type=$(echo "$schema_def" | jq -r '.type // empty' 2>/dev/null)

        if [[ -z "$expected_type" ]]; then
            continue
        fi

        # Type check
        if ! _validate_type "$value" "$expected_type" "$field"; then
            errors=$((errors + 1))
            continue
        fi

        # Range check (for numeric types)
        if [[ "$expected_type" == "integer" || "$expected_type" == "number" ]]; then
            local min max
            min=$(echo "$schema_def" | jq -r '.minimum // empty' 2>/dev/null)
            max=$(echo "$schema_def" | jq -r '.maximum // empty' 2>/dev/null)
            if ! _validate_range "$value" "$min" "$max" "$field"; then
                errors=$((errors + 1))
            fi
        fi

        # Enum check (for string types)
        if [[ "$expected_type" == "string" ]]; then
            local enum_arr
            enum_arr=$(echo "$schema_def" | jq '.enum // empty' 2>/dev/null)
            if [[ -n "$enum_arr" ]]; then
                if ! _validate_enum "$value" "$enum_arr" "$field"; then
                    errors=$((errors + 1))
                fi
            fi
        fi

        # Nested object: validate sub-properties if schema defines them
        if [[ "$expected_type" == "object" ]]; then
            local sub_props
            sub_props=$(echo "$schema_def" | jq -r '.properties // empty | keys[]' 2>/dev/null) || true
            if [[ -n "$sub_props" ]]; then
                while IFS= read -r subfield; do
                    [[ -z "$subfield" ]] && continue
                    local sub_value sub_schema sub_type
                    sub_value=$(jq --arg f "$field" --arg sf "$subfield" '.[$f][$sf] // empty' "$config_file" 2>/dev/null)
                    [[ -z "$sub_value" || "$sub_value" == "null" ]] && continue
                    sub_schema=$(echo "$schema_def" | jq --arg sf "$subfield" '.properties[$sf] // empty' 2>/dev/null)
                    [[ -z "$sub_schema" ]] && continue
                    sub_type=$(echo "$sub_schema" | jq -r '.type // empty' 2>/dev/null)
                    [[ -z "$sub_type" ]] && continue
                    if ! _validate_type "$sub_value" "$sub_type" "${field}.${subfield}"; then
                        errors=$((errors + 1))
                    fi
                    # Range for nested numerics
                    if [[ "$sub_type" == "integer" || "$sub_type" == "number" ]]; then
                        local sub_min sub_max
                        sub_min=$(echo "$sub_schema" | jq -r '.minimum // empty' 2>/dev/null)
                        sub_max=$(echo "$sub_schema" | jq -r '.maximum // empty' 2>/dev/null)
                        if ! _validate_range "$sub_value" "$sub_min" "$sub_max" "${field}.${subfield}"; then
                            errors=$((errors + 1))
                        fi
                    fi
                done <<< "$sub_props"
            fi
        fi
    done <<< "$fields"

    if [[ "$errors" -gt 0 ]]; then
        _cv_error "Config validation failed with $errors error(s)"
        return 1
    fi

    _cv_success "Config validated successfully"
    return 0
}
