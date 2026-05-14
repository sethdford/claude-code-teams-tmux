# policy.sh — Load central policy from config/policy.json or ~/.shipwright/policy.json
# Source this to get POLICY_* vars (optional). Scripts can also jq config/policy.json directly.
# Usage: source "$SCRIPT_DIR/lib/policy.sh"   (after SCRIPT_DIR is set)
[[ -n "${POLICY_LOADED:-}" ]] && return 0
POLICY_LOADED=1

# Resolve repo root (caller may set REPO_DIR)
_REPO_DIR="${REPO_DIR:-}"
[[ -z "$_REPO_DIR" && -n "${SCRIPT_DIR:-}" ]] && _REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[[ -z "$_REPO_DIR" ]] && _REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"

_POLICY_FILE=""
[[ -n "$_REPO_DIR" && -f "$_REPO_DIR/config/policy.json" ]] && _POLICY_FILE="$_REPO_DIR/config/policy.json"
[[ -f "${HOME}/.shipwright/policy.json" ]] && _POLICY_FILE="${HOME}/.shipwright/policy.json"

# policy_get <json_path> [default]
# Returns policy value from config file. Never fails. Falls back to default.
# e.g. policy_get ".daemon.poll_interval_seconds" 60
policy_get() {
    local path="$1"
    local default="${2:-}"
    if [[ -z "$_POLICY_FILE" || ! -f "$_POLICY_FILE" ]]; then
        echo "$default"
        return 0
    fi
    local val
    val=$(jq -r "${path} // \"\"" "$_POLICY_FILE" 2>/dev/null)
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# policy_get_with_override <env_var_name> <json_path> [default]
# Precedence: $env_var (if set & non-empty) > config file > hardcoded default
# e.g. policy_get_with_override "POLL_INTERVAL" ".daemon.poll_interval_seconds" 60
policy_get_with_override() {
    local env_var="$1"
    local path="$2"
    local default="${3:-}"
    # Use eval-free indirect expansion (bash 3.2 compatible)
    local env_val="${!env_var:-}"
    if [[ -n "$env_val" ]]; then
        echo "$env_val"
        return 0
    fi
    policy_get "$path" "$default"
}

# validate_policy [policy_file]
# Validates policy file structure. Returns 0 if valid, 1 with errors on stderr.
# Checks: valid JSON, required top-level sections, sane value ranges.
validate_policy() {
    local file="${1:-$_POLICY_FILE}"
    local errors=0

    if [[ -z "$file" || ! -f "$file" ]]; then
        echo "validate_policy: policy file not found: ${file:-<none>}" >&2
        return 1
    fi

    if ! jq empty "$file" 2>/dev/null; then
        echo "validate_policy: invalid JSON in $file" >&2
        return 1
    fi

    # Required top-level sections
    local section
    for section in daemon pipeline quality; do
        if [[ "$(jq -r ".$section // \"missing\"" "$file" 2>/dev/null)" == "missing" ]]; then
            echo "validate_policy: missing required section .$section" >&2
            errors=$((errors + 1))
        fi
    done

    # Sane numeric ranges for critical values
    local poll
    poll=$(jq -r '.daemon.poll_interval_seconds // 0' "$file" 2>/dev/null)
    if [[ -n "$poll" && "$poll" != "null" ]] && ! [[ "$poll" =~ ^[0-9]+$ ]]; then
        echo "validate_policy: daemon.poll_interval_seconds must be a positive integer (got: $poll)" >&2
        errors=$((errors + 1))
    elif [[ "$poll" -lt 1 ]]; then
        echo "validate_policy: daemon.poll_interval_seconds must be >= 1 (got: $poll)" >&2
        errors=$((errors + 1))
    fi

    local cov
    cov=$(jq -r '.pipeline.coverage_threshold_percent // 0' "$file" 2>/dev/null)
    if [[ "$cov" =~ ^[0-9]+$ ]] && [[ "$cov" -gt 100 ]]; then
        echo "validate_policy: pipeline.coverage_threshold_percent must be 0-100 (got: $cov)" >&2
        errors=$((errors + 1))
    fi

    [[ "$errors" -eq 0 ]]
}

# policy_file — print path to the active policy file (or empty if none)
policy_file() {
    echo "$_POLICY_FILE"
}
