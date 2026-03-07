# pipeline-quality-bash-compat.sh — Bash compatibility checks for pipeline-quality-checks.sh
# Source from pipeline-quality-checks.sh. Requires ARTIFACTS_DIR, SCRIPT_DIR.
[[ -n "${_PIPELINE_QUALITY_BASH_COMPAT_LOADED:-}" ]] && return 0
_PIPELINE_QUALITY_BASH_COMPAT_LOADED=1

# Defaults for variables normally set by sw-pipeline.sh (safe under set -u).
ARTIFACTS_DIR="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
BASE_BRANCH="${BASE_BRANCH:-main}"
PIPELINE_CONFIG="${PIPELINE_CONFIG:-}"
TEST_CMD="${TEST_CMD:-}"

run_bash_compat_check() {
    local violations=0
    local violation_details=""

    # Get modified .sh files relative to base branch
    local changed_files
    changed_files=$(git diff --name-only "origin/${BASE_BRANCH:-main}...HEAD" -- '*.sh' 2>/dev/null || echo "")

    if [[ -z "$changed_files" ]]; then
        echo "0"
        return 0
    fi

    # Check each file for bash 3.2 incompatibilities
    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue

        # declare -A (associative arrays; declare -a is bash 3.2 compatible)
        local declare_a_count
        declare_a_count=$(grep -c 'declare[[:space:]]*-A' "$filepath" 2>/dev/null || true)
        if [[ "$declare_a_count" -gt 0 ]]; then
            violations=$((violations + declare_a_count))
            violation_details="${violation_details}${filepath}: declare -A (${declare_a_count} occurrences)
"
        fi

        # readarray or mapfile
        local readarray_count
        readarray_count=$(grep -c 'readarray\|mapfile' "$filepath" 2>/dev/null || true)
        if [[ "$readarray_count" -gt 0 ]]; then
            violations=$((violations + readarray_count))
            violation_details="${violation_details}${filepath}: readarray/mapfile (${readarray_count} occurrences)
"
        fi

        # ${var,,} or ${var^^} (case conversion)
        local case_conv_count
        case_conv_count=$(grep -c '\$\{[a-zA-Z_][a-zA-Z0-9_]*,,' "$filepath" 2>/dev/null || true)
        case_conv_count=$((case_conv_count + $(grep -c '\$\{[a-zA-Z_][a-zA-Z0-9_]*\^\^' "$filepath" 2>/dev/null || true)))
        if [[ "$case_conv_count" -gt 0 ]]; then
            violations=$((violations + case_conv_count))
            violation_details="${violation_details}${filepath}: case conversion \$\{var,,\} or \$\{var\^\^\} (${case_conv_count} occurrences)
"
        fi

        # |& (pipe stderr to stdout in-place)
        local pipe_ampersand_count
        pipe_ampersand_count=$(grep -c '|&' "$filepath" 2>/dev/null || true)
        if [[ "$pipe_ampersand_count" -gt 0 ]]; then
            violations=$((violations + pipe_ampersand_count))
            violation_details="${violation_details}${filepath}: |& operator (${pipe_ampersand_count} occurrences)
"
        fi

        # ;& or ;;& in case statements (advanced fallthrough)
        local advanced_case_count
        advanced_case_count=$(grep -c ';&\|;;&' "$filepath" 2>/dev/null || true)
        if [[ "$advanced_case_count" -gt 0 ]]; then
            violations=$((violations + advanced_case_count))
            violation_details="${violation_details}${filepath}: advanced case ;& or ;;& (${advanced_case_count} occurrences)
"
        fi

    done <<< "$changed_files"

    # Log details if violations found
    if [[ "$violations" -gt 0 ]]; then
        warn "Bash 3.2 compatibility check: ${violations} violation(s) found:"
        echo "$violation_details" | sed 's/^/  /'
    fi

    echo "$violations"
}

# ──────────────────────────────────────────────────────────────────────────────
# Test Coverage Check
# Runs configured test command and extracts coverage percentage
# Returns: coverage percentage (0-100), or "skip" if no test command configured
# ──────────────────────────────────────────────────────────────────────────────

run_atomic_write_check() {
    local violations=0
    local violation_details=""

    # Get modified files (not just .sh — includes state/config files)
    local changed_files
    changed_files=$(git diff --name-only "origin/${BASE_BRANCH:-main}...HEAD" 2>/dev/null || echo "")

    if [[ -z "$changed_files" ]]; then
        echo "0"
        return 0
    fi

    # Check for direct writes to state/config files (patterns that should use tmp+mv)
    # Look for: echo "..." > state/config files
    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue

        # Only check state/config/artifacts files
        if [[ ! "$filepath" =~ (state|config|artifact|cache|db|json)$ ]]; then
            continue
        fi

        # Check for direct redirection writes (> file) in state/config paths
        local bad_writes
        bad_writes=$(git show "HEAD:$filepath" 2>/dev/null | grep -c 'echo.*>' 2>/dev/null || true)
        bad_writes="${bad_writes:-0}"

        if [[ "$bad_writes" -gt 0 ]]; then
            violations=$((violations + bad_writes))
            violation_details="${violation_details}${filepath}: ${bad_writes} direct write(s) (should use tmp+mv)
"
        fi
    done <<< "$changed_files"

    if [[ "$violations" -gt 0 ]]; then
        warn "Atomic write violations: ${violations} found (should use tmp file + mv pattern):"
        echo "$violation_details" | sed 's/^/  /'
    fi

    echo "$violations"
}

# ──────────────────────────────────────────────────────────────────────────────
# New Function Test Detection
# Detects new functions added in the diff but checks if corresponding tests exist
# Returns: count of untested new functions
# ──────────────────────────────────────────────────────────────────────────────

run_new_function_test_check() {
    local untested_functions=0
    local details=""

    # Get diff
    local diff_content
    diff_content=$(git diff "origin/${BASE_BRANCH:-main}...HEAD" 2>/dev/null || true)

    if [[ -z "$diff_content" ]]; then
        echo "0"
        return 0
    fi

    # Extract newly added function definitions (lines starting with +functionname())
    local new_functions
    new_functions=$(echo "$diff_content" | grep -E '^\+[a-zA-Z_][a-zA-Z0-9_]*\(\)' | sed 's/^\+//' | sed 's/()//' || true)

    if [[ -z "$new_functions" ]]; then
        echo "0"
        return 0
    fi

    # For each new function, check if test files were modified
    local test_files_modified=0
    test_files_modified=$(echo "$diff_content" | grep -c '\-\-\-.*test\|\.test\.\|_test\.' || true)

    # Simple heuristic: if we have new functions but no test file modifications, warn
    if [[ "$test_files_modified" -eq 0 ]]; then
        local func_count
        func_count=$(echo "$new_functions" | wc -l | xargs)
        untested_functions="$func_count"
        details="Added ${func_count} new function(s) but no test file modifications detected"
    fi

    if [[ "$untested_functions" -gt 0 ]]; then
        warn "New functions without tests: ${details}"
    fi

    echo "$untested_functions"
}
