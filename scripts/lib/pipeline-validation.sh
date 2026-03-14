#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-validation.sh — Template Schema Validator                      ║
# ║                                                                          ║
# ║  Validates pipeline template JSON against known constraints.             ║
# ║  Accumulates all errors before returning, so users see everything at     ║
# ║  once rather than fixing one error at a time.                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Valid stage IDs (the 12 canonical pipeline stages)
VALID_STAGE_IDS="intake plan design build test review compound_quality audit pr merge deploy validate monitor"

# Valid gate values
VALID_GATE_VALUES="auto approve"

# Error accumulator (newline-separated)
_VALIDATION_ERRORS=""

# ─── Internal helpers ─────────────────────────────────────────────────────

_add_error() {
    if [[ -z "$_VALIDATION_ERRORS" ]]; then
        _VALIDATION_ERRORS="$1"
    else
        _VALIDATION_ERRORS="${_VALIDATION_ERRORS}
$1"
    fi
}

_is_valid_stage_id() {
    local id="$1"
    local valid
    for valid in $VALID_STAGE_IDS; do
        [[ "$valid" == "$id" ]] && return 0
    done
    return 1
}

_is_valid_gate() {
    local gate="$1"
    local valid
    for valid in $VALID_GATE_VALUES; do
        [[ "$valid" == "$gate" ]] && return 0
    done
    return 1
}

# ─── Validation functions ─────────────────────────────────────────────────

# Validate required top-level fields exist
_validate_required_fields() {
    local json="$1"

    # name: required, non-empty string
    local name
    name=$(echo "$json" | jq -r '.name // empty' 2>/dev/null) || true
    if [[ -z "$name" ]]; then
        _add_error "missing required field: 'name'"
    fi

    # description: required, non-empty string
    local desc
    desc=$(echo "$json" | jq -r '.description // empty' 2>/dev/null) || true
    if [[ -z "$desc" ]]; then
        _add_error "missing required field: 'description'"
    fi

    # defaults: required object
    local has_defaults
    has_defaults=$(echo "$json" | jq -e '.defaults' >/dev/null 2>&1 && echo "yes" || echo "no")
    if [[ "$has_defaults" == "no" ]]; then
        _add_error "missing required field: 'defaults'"
    fi

    # stages: required non-empty array
    local stages_type
    stages_type=$(echo "$json" | jq -r '.stages | type' 2>/dev/null) || true
    if [[ "$stages_type" != "array" ]]; then
        _add_error "missing required field: 'stages' (must be an array)"
        return 1  # can't validate stages if missing
    fi

    local stages_len
    stages_len=$(echo "$json" | jq '.stages | length' 2>/dev/null) || true
    if [[ "${stages_len:-0}" -eq 0 ]]; then
        _add_error "'stages' array must not be empty"
        return 1
    fi

    return 0
}

# Validate each stage object
_validate_stages() {
    local json="$1"
    local stage_count
    stage_count=$(echo "$json" | jq '.stages | length' 2>/dev/null) || return 0

    local i=0
    while [[ "$i" -lt "$stage_count" ]]; do
        local stage
        stage=$(echo "$json" | jq ".stages[$i]" 2>/dev/null)

        # id: required, must be valid
        local id
        id=$(echo "$stage" | jq -r '.id // empty' 2>/dev/null) || true
        if [[ -z "$id" ]]; then
            _add_error "stage[$i]: missing required field 'id'"
        elif ! _is_valid_stage_id "$id"; then
            _add_error "stage[$i]: unknown stage id '$id' (valid: $VALID_STAGE_IDS)"
        fi

        # enabled: required, must be boolean
        local enabled_type
        enabled_type=$(echo "$stage" | jq -r '.enabled | type' 2>/dev/null) || true
        if [[ "$enabled_type" != "boolean" ]]; then
            _add_error "stage[$i] ($id): 'enabled' must be a boolean, got '$enabled_type'"
        fi

        # gate: required, must be valid value
        local gate
        gate=$(echo "$stage" | jq -r '.gate // empty' 2>/dev/null) || true
        if [[ -z "$gate" ]]; then
            _add_error "stage[$i] ($id): missing required field 'gate'"
        elif ! _is_valid_gate "$gate"; then
            _add_error "stage[$i] ($id): invalid gate value '$gate' (valid: $VALID_GATE_VALUES)"
        fi

        # config: required, must be object
        local config_type
        config_type=$(echo "$stage" | jq -r '.config | type' 2>/dev/null) || true
        if [[ "$config_type" != "object" ]]; then
            _add_error "stage[$i] ($id): 'config' must be an object, got '$config_type'"
        fi

        i=$((i + 1))
    done
}

# Validate no duplicate stage IDs
_validate_no_duplicate_stages() {
    local json="$1"
    local ids
    ids=$(echo "$json" | jq -r '.stages[].id' 2>/dev/null) || return 0

    local seen=""
    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        # Check if already seen (space-delimited list)
        case " $seen " in
            *" $id "*)
                _add_error "duplicate stage id: '$id'"
                ;;
        esac
        seen="$seen $id"
    done <<< "$ids"
}

# Validate stage ordering constraints (only for enabled stages)
_validate_stage_ordering() {
    local json="$1"
    local enabled_ids
    enabled_ids=$(echo "$json" | jq -r '[.stages[] | select(.enabled != false) | .id] | join(",")' 2>/dev/null) || return 0

    _check_stage_order() {
        local before="$1"
        local after="$2"
        local ids="$enabled_ids"

        local has_before=false has_after=false
        local before_pos=-1 after_pos=-1 pos=0

        local IFS=","
        for sid in $ids; do
            [[ "$sid" == "$before" ]] && { has_before=true; before_pos=$pos; }
            [[ "$sid" == "$after" ]]  && { has_after=true; after_pos=$pos; }
            pos=$((pos + 1))
        done

        if [[ "$has_before" == "true" && "$has_after" == "true" ]]; then
            if [[ "$before_pos" -ge "$after_pos" ]]; then
                _add_error "stage ordering violation: '$before' must come before '$after'"
            fi
        fi
    }

    _check_stage_order "intake" "build"
    _check_stage_order "build" "test"
    _check_stage_order "test" "pr"
    _check_stage_order "plan" "build"
    _check_stage_order "review" "pr"
    _check_stage_order "deploy" "validate"
    _check_stage_order "validate" "monitor"
}

# Validate numeric config values are positive where expected
_validate_config_values() {
    local json="$1"
    local stage_count
    stage_count=$(echo "$json" | jq '.stages | length' 2>/dev/null) || return 0

    local i=0
    while [[ "$i" -lt "$stage_count" ]]; do
        local id
        id=$(echo "$json" | jq -r ".stages[$i].id // empty" 2>/dev/null) || true

        # max_iterations must be positive if present
        local max_iter
        max_iter=$(echo "$json" | jq -r ".stages[$i].config.max_iterations // empty" 2>/dev/null) || true
        if [[ -n "$max_iter" ]]; then
            if ! [[ "$max_iter" =~ ^[0-9]+$ ]] || [[ "$max_iter" -le 0 ]]; then
                _add_error "stage[$i] ($id): 'max_iterations' must be a positive integer, got '$max_iter'"
            fi
        fi

        # coverage_min must be 0-100 if present
        local cov_min
        cov_min=$(echo "$json" | jq -r ".stages[$i].config.coverage_min // empty" 2>/dev/null) || true
        if [[ -n "$cov_min" ]]; then
            if ! [[ "$cov_min" =~ ^[0-9]+$ ]] || [[ "$cov_min" -lt 0 ]] || [[ "$cov_min" -gt 100 ]]; then
                _add_error "stage[$i] ($id): 'coverage_min' must be 0-100, got '$cov_min'"
            fi
        fi

        # max_cycles must be positive if present
        local max_cycles
        max_cycles=$(echo "$json" | jq -r ".stages[$i].config.max_cycles // empty" 2>/dev/null) || true
        if [[ -n "$max_cycles" ]]; then
            if ! [[ "$max_cycles" =~ ^[0-9]+$ ]] || [[ "$max_cycles" -le 0 ]]; then
                _add_error "stage[$i] ($id): 'max_cycles' must be a positive integer, got '$max_cycles'"
            fi
        fi

        # wait_ci_timeout_s must be positive if present
        local timeout
        timeout=$(echo "$json" | jq -r ".stages[$i].config.wait_ci_timeout_s // empty" 2>/dev/null) || true
        if [[ -n "$timeout" ]]; then
            if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -le 0 ]]; then
                _add_error "stage[$i] ($id): 'wait_ci_timeout_s' must be a positive integer, got '$timeout'"
            fi
        fi

        # duration_minutes must be positive if present
        local duration
        duration=$(echo "$json" | jq -r ".stages[$i].config.duration_minutes // empty" 2>/dev/null) || true
        if [[ -n "$duration" ]]; then
            if ! [[ "$duration" =~ ^[0-9]+$ ]] || [[ "$duration" -le 0 ]]; then
                _add_error "stage[$i] ($id): 'duration_minutes' must be a positive integer, got '$duration'"
            fi
        fi

        i=$((i + 1))
    done
}

# Validate defaults object structure
_validate_defaults() {
    local json="$1"
    local has_defaults
    has_defaults=$(echo "$json" | jq -e '.defaults' >/dev/null 2>&1 && echo "yes" || echo "no")
    [[ "$has_defaults" == "no" ]] && return 0  # already caught by required fields check

    # defaults.agents must be positive integer if present
    local agents
    agents=$(echo "$json" | jq -r '.defaults.agents // empty' 2>/dev/null) || true
    if [[ -n "$agents" ]]; then
        if ! [[ "$agents" =~ ^[0-9]+$ ]] || [[ "$agents" -le 0 ]]; then
            _add_error "defaults.agents must be a positive integer, got '$agents'"
        fi
    fi
}

# ─── Public API ───────────────────────────────────────────────────────────

# Validate a pipeline template. Accepts a file path or JSON string.
# Returns 0 on success, 1 on failure. Errors printed to stderr.
validate_pipeline_template() {
    local input="${1:-}"
    local json=""

    _VALIDATION_ERRORS=""

    # Read input
    if [[ -n "$input" ]]; then
        if [[ -f "$input" ]]; then
            json=$(cat "$input" 2>/dev/null) || true
        else
            json="$input"
        fi
    else
        json=$(cat) || true
    fi

    # Check valid JSON
    if [[ -z "$json" ]] || ! echo "$json" | jq . >/dev/null 2>&1; then
        echo "validation error: input is not valid JSON" >&2
        return 1
    fi

    # Run all validators
    _validate_required_fields "$json" || true  # continue even if stages missing
    _validate_defaults "$json"

    # Only validate stages if the array exists
    local stages_type
    stages_type=$(echo "$json" | jq -r '.stages | type' 2>/dev/null) || true
    if [[ "$stages_type" == "array" ]]; then
        local stages_len
        stages_len=$(echo "$json" | jq '.stages | length' 2>/dev/null) || true
        if [[ "${stages_len:-0}" -gt 0 ]]; then
            _validate_stages "$json"
            _validate_no_duplicate_stages "$json"
            _validate_stage_ordering "$json"
            _validate_config_values "$json"
        fi
    fi

    # Report errors
    if [[ -n "$_VALIDATION_ERRORS" ]]; then
        local error_count=0
        while IFS= read -r err; do
            echo "validation error: $err" >&2
            error_count=$((error_count + 1))
        done <<< "$_VALIDATION_ERRORS"
        echo "template validation failed with $error_count error(s)" >&2
        return 1
    fi

    return 0
}

# Get validation errors as a list (for programmatic use)
get_validation_errors() {
    echo "$_VALIDATION_ERRORS"
}
