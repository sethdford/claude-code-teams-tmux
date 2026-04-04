# policy.sh — Load central policy from config/policy.json or ~/.shipwright/policy.json
# Source this to get policy_get and policy_validate helpers.
# Usage: source "$SCRIPT_DIR/lib/policy.sh"   (after SCRIPT_DIR is set)
[[ -n "${POLICY_LOADED:-}" ]] && return 0
POLICY_LOADED=1

# Resolve repo root (caller may set REPO_DIR)
_POLICY_REPO_DIR="${REPO_DIR:-}"
[[ -z "$_POLICY_REPO_DIR" && -n "${SCRIPT_DIR:-}" ]] && _POLICY_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
[[ -z "$_POLICY_REPO_DIR" ]] && _POLICY_REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"

_POLICY_FILE=""
[[ -n "$_POLICY_REPO_DIR" && -f "$_POLICY_REPO_DIR/config/policy.json" ]] && _POLICY_FILE="$_POLICY_REPO_DIR/config/policy.json"
[[ -f "${HOME}/.shipwright/policy.json" ]] && _POLICY_FILE="${HOME}/.shipwright/policy.json"

# Overrides file — written by sw-adaptive.sh, takes precedence over policy.json
_POLICY_OVERRIDES_FILE=""
if [[ -n "$_POLICY_REPO_DIR" && -f "$_POLICY_REPO_DIR/.claude/policy-overrides.json" ]]; then
    _POLICY_OVERRIDES_FILE="$_POLICY_REPO_DIR/.claude/policy-overrides.json"
fi

# Export a single helper: policy_get <json_path> [default]
# e.g. policy_get ".daemon.poll_interval_seconds" 60
# Precedence: policy-overrides.json → policy.json → default
policy_get() {
    local path="$1"
    local default="${2:-}"
    local val=""

    # 1. Check overrides first
    if [[ -n "$_POLICY_OVERRIDES_FILE" && -f "$_POLICY_OVERRIDES_FILE" ]]; then
        val=$(jq -r "${path} // \"\"" "$_POLICY_OVERRIDES_FILE" 2>/dev/null || true)
    fi

    # 2. Fall back to base policy
    if [[ -z "$val" || "$val" == "null" ]]; then
        if [[ -n "$_POLICY_FILE" && -f "$_POLICY_FILE" ]]; then
            val=$(jq -r "${path} // \"\"" "$_POLICY_FILE" 2>/dev/null || true)
        fi
    fi

    # 3. Fall back to default
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# ─── Schema Validation ──────────────────────────────────────────────────────

# _policy_check_range <file> <jq_path> <min> <max>
# Check that a numeric value is within bounds. Returns 1 and prints error if out of range.
_policy_check_range() {
    local file="$1" path="$2" min="$3" max="$4"
    local val
    val=$(jq -r "${path} // empty" "$file" 2>/dev/null || true)
    [[ -z "$val" ]] && return 0  # Missing is OK — fallback chain handles it
    # Ensure numeric
    case "$val" in
        ''|*[!0-9.-]*) echo "FAIL: ${path} = ${val} (not a number)"; return 1 ;;
    esac
    if [[ $(echo "$val < $min" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
        echo "FAIL: ${path} = ${val} (expected >= ${min})"
        return 1
    fi
    if [[ $(echo "$val > $max" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
        echo "FAIL: ${path} = ${val} (expected <= ${max})"
        return 1
    fi
    return 0
}

# _policy_check_type <file> <jq_path> <expected_type>
# Check that a value has the expected jq type (string, number, boolean, object, array).
_policy_check_type() {
    local file="$1" path="$2" expected="$3"
    local actual
    actual=$(jq -r "${path} | type" "$file" 2>/dev/null || true)
    [[ -z "$actual" || "$actual" == "null" ]] && return 0  # Missing is OK
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: ${path} has type ${actual} (expected ${expected})"
        return 1
    fi
    return 0
}

# policy_validate [file]
# Validate a policy file against key constraints. Returns 0 on success, >0 on failure.
# Prints one FAIL line per violation.
policy_validate() {
    local file="${1:-$_POLICY_FILE}"
    local errors=0

    # 1. Valid JSON
    if ! jq empty "$file" 2>/dev/null; then
        echo "FAIL: invalid JSON in ${file}"
        return 1
    fi

    # 2. Required top-level sections
    local section
    for section in daemon pipeline quality; do
        if ! jq -e ".${section}" "$file" >/dev/null 2>&1; then
            echo "FAIL: missing .${section}"
            errors=$((errors + 1))
        fi
    done

    # 3. Type checks for key sections
    _policy_check_type "$file" ".daemon" "object"             || errors=$((errors + 1))
    _policy_check_type "$file" ".pipeline" "object"           || errors=$((errors + 1))
    _policy_check_type "$file" ".quality" "object"            || errors=$((errors + 1))
    _policy_check_type "$file" ".loop" "object"               || errors=$((errors + 1))

    # 4. Numeric range constraints — daemon
    _policy_check_range "$file" ".daemon.poll_interval_seconds" 1 3600       || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.health_heartbeat_timeout" 1 600     || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.stale_state_hours" 1 168            || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.max_parallel" 1 64                  || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.max_workers" 1 64                   || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.min_workers" 1 64                   || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.watchdog_max_restarts" 1 100        || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.graceful_shutdown_seconds" 5 600    || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.progress_hard_limit_seconds" 600 86400 || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.max_retries" 0 20                   || errors=$((errors + 1))

    # 5. Numeric range constraints — pipeline
    _policy_check_range "$file" ".pipeline.max_iterations_default" 1 100     || errors=$((errors + 1))
    _policy_check_range "$file" ".pipeline.coverage_threshold_percent" 0 100 || errors=$((errors + 1))
    _policy_check_range "$file" ".pipeline.quality_gate_score_threshold" 0 100 || errors=$((errors + 1))
    _policy_check_range "$file" ".pipeline.build_test_retries" 0 10          || errors=$((errors + 1))

    # 6. Numeric range constraints — quality
    _policy_check_range "$file" ".quality.coverage_threshold" 0 100          || errors=$((errors + 1))
    _policy_check_range "$file" ".quality.gate_score_threshold" 0 100        || errors=$((errors + 1))

    # 7. Numeric range constraints — loop (if present)
    _policy_check_range "$file" ".loop.max_iterations" 1 100                 || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.extension_size" 1 20                  || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.max_extensions" 0 10                  || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.circuit_breaker_threshold" 1 50       || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.context_budget_chars" 10000 1000000   || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.claude_timeout" 60 7200               || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.test_timeout" 10 3600                 || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.convergence_threshold" 1 20           || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.convergence_window" 2 20              || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.convergence_stall_limit" 1 20         || errors=$((errors + 1))
    _policy_check_range "$file" ".loop.max_restarts" 0 20                    || errors=$((errors + 1))

    # 8. Patrol sub-object constraints (if present)
    _policy_check_range "$file" ".daemon.patrol.interval_seconds" 60 86400   || errors=$((errors + 1))
    _policy_check_range "$file" ".daemon.patrol.max_issues" 1 100            || errors=$((errors + 1))

    return $errors
}
