#!/usr/bin/env bash
# issue-quarantine.sh — Filter E2E test issues from production issue tracking
# Provides a single quarantine library with config-driven label set.
# Fail-open contract: any error (malformed JSON, missing jq, etc) returns unfiltered input.

set -euo pipefail

VERSION="3.3.0"

[[ -n "${_SW_ISSUE_QUARANTINE_LOADED:-}" ]] && return 0
_SW_ISSUE_QUARANTINE_LOADED=1

# Source config.sh for _config_get
QUARANTINE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "${QUARANTINE_SCRIPT_DIR}/config.sh"

# Utility: safely emit an event if helpers are available
_quarantine_emit_event() {
    local event_type="$1"
    shift
    if [[ "$(type -t emit_event 2>/dev/null)" == "function" ]]; then
        emit_event "$event_type" "$@"
    fi
}

# quarantine_label — Return the label applied by E2E test suite
# Chain: SHIPWRIGHT_LABELS_E2E_TEST env → labels.e2e_test config → default "sw:e2e-test"
quarantine_label() {
    _config_get "labels.e2e_test" "sw:e2e-test"
}

# quarantine_labels — Return all quarantine labels (newline-separated, sorted, deduplicated)
# Reads labels.quarantine from config (JSON array or comma-separated) with fallback
quarantine_labels() {
    local qlabels
    qlabels=$(_config_get "labels.quarantine" "")

    if [[ -z "$qlabels" ]]; then
        quarantine_label
        return 0
    fi

    # Try to parse as JSON array first
    if [[ "$qlabels" == "["* ]]; then
        printf '%s' "$qlabels" | jq -r '.[]' 2>/dev/null || quarantine_label
    else
        # Assume comma-separated, split and output one per line
        printf '%s\n' "${qlabels//,/$'\n'}" | sort -u
    fi
}

# quarantine_filter_json — Filter JSON array of GitHub issues, removing quarantined ones
# INPUT: JSON array [{ number, title, labels: [{name: string}, ...], ... }, ...]
# OUTPUT: Same array, matching issues removed
# FAIL-OPEN: On any error, returns unfiltered input, exit 0
# $1: source label for event logging (e.g., "daemon-poll")
quarantine_filter_json() {
    local source="${1:-unknown}"
    local input filtered qlabels

    input=$(cat)

    # Fail-open: empty input
    [[ -z "$input" ]] && { printf '%s' "$input"; return 0; }

    # Fail-open: empty quarantine set
    qlabels=$(quarantine_labels 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || {
        printf '%s' "$input"
        return 0
    }

    [[ -z "$qlabels" ]] && { printf '%s' "$input"; return 0; }

    # Fail-open: jq filter fails
    filtered=$(printf '%s' "$input" | jq -c --argjson qlabels "$qlabels" \
        '[.[] | select((([(.labels // [])[] | .name]) - $qlabels) == ([(.labels // [])[] | .name]))]' 2>/dev/null) || {
        printf '%s' "$input"
        return 0
    }

    # Fail-open: empty/null result
    [[ -z "$filtered" || "$filtered" == "null" ]] && { printf '%s' "$input"; return 0; }

    # Emit event if we filtered something
    local before_count after_count
    before_count=$(printf '%s' "$input" | jq 'length' 2>/dev/null || echo 0)
    after_count=$(printf '%s' "$filtered" | jq 'length' 2>/dev/null || echo 0)

    if [[ "$before_count" -gt "$after_count" ]]; then
        local filtered_count=$((before_count - after_count))
        _quarantine_emit_event "issue.quarantine" "filtered=$filtered_count" "source=$source"
    fi

    printf '%s' "$filtered"
}

# quarantine_search_qualifier — Emit GitHub search qualifier for server-side filtering
# Output: "-label:"X" -label:"Y"" or empty if no labels
quarantine_search_qualifier() {
    local qualifiers=()
    while IFS= read -r label; do
        [[ -z "$label" ]] && continue
        qualifiers+=("-label:\"$label\"")
    done < <(quarantine_labels 2>/dev/null || echo "")

    [[ ${#qualifiers[@]} -gt 0 ]] && printf '%s ' "${qualifiers[@]}"
}

# quarantine_is_test_issue — Test whether a single GitHub issue is quarantined
# $1: issue JSON object (from `gh issue view --json`)
# Return: 0 if quarantined, 1 otherwise
quarantine_is_test_issue() {
    local issue_json="$1"
    local qlabels

    qlabels=$(quarantine_labels 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null) || return 1
    [[ -z "$qlabels" ]] && return 1

    printf '%s' "$issue_json" | jq -e \
        --argjson qlabels "$qlabels" \
        '([(.labels // [])[] | .name]) | any(. as $n | $qlabels[] | . == $n)' >/dev/null 2>&1
}
