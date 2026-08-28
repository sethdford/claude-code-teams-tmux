#!/usr/bin/env bash
# issue-noise.sh — Detect and filter E2E test issues and other noise from the queue
# Source from sw-daemon.sh or sw-triage.sh. Requires config.sh, helpers.sh for emit_event.
# Usage: is_noise_issue <json_issue_string>  → returns 0 (is noise) or 1 (not noise)
[[ -n "${_ISSUE_NOISE_LOADED:-}" ]] && return 0
_ISSUE_NOISE_LOADED=1

VERSION="1.0.0"

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Source helpers if available
[[ -x "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"

# ── Configuration ──
# Read noise detection config from daemon-config.json or config/defaults.json:
#   {
#     "noise_issues": {
#       "enabled": true,
#       "label_patterns": ["e2e-test", "automated"],
#       "title_pattern": "\\[automated\\]",
#       "body_marker": "<!-- AUTO-GENERATED -->|<!-- E2E-TEST -->",
#       "override_labels": ["p0", "urgent", "security"],
#       "auto_close_enabled": false,
#       "flood_alert_threshold": 5,
#       "flood_time_window_mins": 60
#     }
#   }

_noise_cfg() {
    local key="$1"
    local default="${2:-}"

    # Try daemon-config.json first (if it has this setting)
    if [[ -f "${REPO_DIR:-.}/.claude/daemon-config.json" ]]; then
        local val
        val=$(jq -r ".noise_issues.${key} // empty" "${REPO_DIR:-.}/.claude/daemon-config.json" 2>/dev/null || echo "")
        if [[ -n "$val" && "$val" != "null" ]]; then
            # For arrays, use join to convert to comma-separated
            echo "$val" | jq -r 'if type == "array" then join(",") else . end' 2>/dev/null || echo "$val"
            return
        fi
    fi

    # Fall back to defaults.json
    if [[ -f "${REPO_DIR:-.}/config/defaults.json" ]]; then
        local val
        val=$(jq -r ".noise_issues.${key} // empty" "${REPO_DIR:-.}/config/defaults.json" 2>/dev/null || echo "")
        if [[ -n "$val" && "$val" != "null" ]]; then
            # For arrays, use join to convert to comma-separated
            echo "$val" | jq -r 'if type == "array" then join(",") else . end' 2>/dev/null || echo "$val"
            return
        fi
    fi

    echo "$default"
}

# ── Core Detection ──

# noise_issue_confidence <issue_json_string>
# Returns: "none" (not noise) | "title" (title pattern match, skip only) | "high" (auto-close eligible)
#
# Tiered confidence:
#   high  — label match OR body marker detected → can auto-close after success
#   title — title pattern match → skip from scoring ONLY, never auto-close
#   none  — not detected as noise, OR carries override label (p0/urgent/security)
noise_issue_confidence() {
    local issue_json="$1"
    local enabled
    enabled=$(_noise_cfg "enabled" "true")
    [[ "$enabled" != "true" ]] && { echo "none"; return; }

    local issue_num issue_title issue_body labels_csv
    issue_num=$(echo "$issue_json" | jq -r '.number' 2>/dev/null || echo "")
    issue_title=$(echo "$issue_json" | jq -r '.title // ""' 2>/dev/null || echo "")
    issue_body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null || echo "")
    labels_csv=$(echo "$issue_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || echo "")

    # ── Override labels (p0, urgent, security) disable ALL noise detection ──
    local override_labels
    override_labels=$(_noise_cfg "override_labels" "p0,urgent,security")
    if echo "$labels_csv" | grep -qiE "${override_labels//,/|}"; then
        echo "none"
        return
    fi

    # ── High confidence: label match ──
    local label_patterns label_pattern_regex
    label_patterns=$(_noise_cfg "label_patterns" "e2e-test,automated")
    # Convert comma-separated list to regex alternation
    label_pattern_regex="${label_patterns//,/|}"
    if echo "$labels_csv" | grep -qiE "$label_pattern_regex"; then
        echo "high"
        return
    fi

    # ── High confidence: body marker ──
    local body_marker
    body_marker=$(_noise_cfg "body_marker" "<!-- AUTO-GENERATED -->|<!-- E2E-TEST -->")
    if echo "$issue_body" | grep -qE "$body_marker"; then
        echo "high"
        return
    fi

    # ── Title confidence: title pattern match ──
    local title_pattern
    title_pattern=$(_noise_cfg "title_pattern" "\\[automated\\]")
    if echo "$issue_title" | grep -qiE "$title_pattern"; then
        echo "title"
        return
    fi

    echo "none"
}

# is_noise_issue <issue_json_string>
# Returns 0 (is noise, skip) or 1 (not noise, process normally)
is_noise_issue() {
    local issue_json="$1"
    local confidence
    confidence=$(noise_issue_confidence "$issue_json")
    [[ "$confidence" != "none" ]]  # Returns true (0) if confidence is high or title
}

# is_auto_close_eligible <issue_json_string>
# Returns 0 (yes, can auto-close) or 1 (no, keep or manual close only)
is_auto_close_eligible() {
    local issue_json="$1"
    local enabled auto_close_cfg
    enabled=$(_noise_cfg "enabled" "true")
    [[ "$enabled" != "true" ]] && return 1

    auto_close_cfg=$(_noise_cfg "auto_close_enabled" "false")
    [[ "$auto_close_cfg" != "true" ]] && return 1

    local confidence
    confidence=$(noise_issue_confidence "$issue_json")
    [[ "$confidence" == "high" ]]  # Only high confidence, NOT title
}

# ── Filtering ──

# noise_filter_issues <jq_filter_expr>
# Reads JSON array from stdin, emits filtered array to stdout (excluding noise).
# Args: optional jq filter to apply after noise filtering (e.g., '.[] | select(.state=="open")')
# Usage: gh issue list --json ... | noise_filter_issues '.[] | select(.state=="open")'
noise_filter_issues() {
    local post_filter="${1:-.}"
    local override_labels label_patterns body_marker title_pattern
    override_labels=$(_noise_cfg "override_labels" "p0,urgent,security")
    label_patterns=$(_noise_cfg "label_patterns" "e2e-test,automated")
    body_marker=$(_noise_cfg "body_marker" "<!-- AUTO-GENERATED -->|<!-- E2E-TEST -->")
    title_pattern=$(_noise_cfg "title_pattern" "[automated]")

    # Convert patterns to jq-compatible format (escape pipes and brackets for jq)
    override_labels=$(echo "$override_labels" | sed 's/,/|/g')
    label_patterns=$(echo "$label_patterns" | sed 's/,/|/g')
    # For jq regex, brackets need to be escaped properly
    title_pattern=$(echo "$title_pattern" | sed 's/\[/\\[/g; s/\]/\\]/g')

    jq --arg ol "$override_labels" --arg lp "$label_patterns" \
       --arg bm "$body_marker" --arg tp "$title_pattern" \
       "[
        .[] |
        select(
            if ([.labels[].name] | join(\",\") | test(\$ol; \"i\")) then
                true
            elif (([.labels[].name] | join(\",\") | test(\$lp; \"i\")) or
                  (.body and (.body | test(\$bm))) or
                  (.title | test(\$tp; \"i\"))) then
                false
            else
                true
            end
        )
       ] | ${post_filter}"
}

# ── Flood Detection ──

# noise_check_flood <count> <time_window_mins>
# Returns 0 (flood detected) or 1 (normal volume)
# Tracks flood state in ~/.shipwright/noise-flood-alert.state to dedupe hourly alerts
noise_check_flood() {
    local count="${1:-0}"
    local time_window_mins="${2:-60}"
    local enabled
    enabled=$(_noise_cfg "enabled" "true")
    [[ "$enabled" != "true" ]] && return 1

    local threshold
    threshold=$(_noise_cfg "flood_alert_threshold" "5")

    if [[ "$count" -ge "$threshold" ]]; then
        # Check if we've already alerted in the last hour
        local alert_file="${HOME}/.shipwright/noise-flood-alert.state"
        local alert_dedupe_secs=3600  # 1 hour
        local now_secs
        now_secs=$(date +%s 2>/dev/null || echo "0")

        local should_alert=true
        if [[ -f "$alert_file" ]]; then
            local last_alert_secs
            last_alert_secs=$(cat "$alert_file" 2>/dev/null || echo "0")
            if [[ $((now_secs - last_alert_secs)) -lt $alert_dedupe_secs ]]; then
                should_alert=false
            fi
        fi

        if [[ "$should_alert" == "true" ]]; then
            mkdir -p "${HOME}/.shipwright"
            echo "$now_secs" > "$alert_file" 2>/dev/null || true
            emit_event "daemon.noise_flood" \
                "count=$count" \
                "threshold=$threshold" \
                "time_window_mins=$time_window_mins"
            return 0
        fi

        return 0  # Flood detected (but alert already sent)
    fi

    return 1  # Normal volume
}

# noise_describe <issue_json_string>
# Returns human-readable reason why issue is noise
noise_describe() {
    local issue_json="$1"
    local issue_num issue_title issue_body labels_csv confidence
    issue_num=$(echo "$issue_json" | jq -r '.number' 2>/dev/null || echo "?")
    issue_title=$(echo "$issue_json" | jq -r '.title // ""' 2>/dev/null || echo "")
    issue_body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null || echo "")
    labels_csv=$(echo "$issue_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || echo "")
    confidence=$(noise_issue_confidence "$issue_json")

    case "$confidence" in
        high)
            if echo "$labels_csv" | grep -qiE "$(_noise_cfg "label_patterns" "e2e-test,automated")"; then
                echo "#$issue_num: noise (label match)"
            elif echo "$issue_body" | grep -qE "$(_noise_cfg "body_marker" "<!-- AUTO-GENERATED -->")"; then
                echo "#$issue_num: noise (body marker)"
            else
                echo "#$issue_num: noise (high confidence)"
            fi
            ;;
        title)
            echo "#$issue_num: noise (title pattern: $issue_title)"
            ;;
        *)
            echo "#$issue_num: not noise"
            ;;
    esac
}
