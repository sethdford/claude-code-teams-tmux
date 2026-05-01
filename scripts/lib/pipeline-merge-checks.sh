#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-merge-checks — GitHub Checks API polling for post-merge gate   ║
# ║                                                                          ║
# ║  Polls required check runs on a merge commit until completion or         ║
# ║  timeout. Exponential backoff (1→2→4→8s, capped). Fail-open on timeout. ║
# ║  Logs every API response to checks-responses.jsonl for post-mortem.     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_PIPELINE_MERGE_CHECKS_LOADED:-}" ]] && return 0
_PIPELINE_MERGE_CHECKS_LOADED=1

readonly MC_DEFAULT_TIMEOUT_S=180
readonly MC_BACKOFF_MAX_S=8

_mc_responses_file() {
    echo "${ARTIFACTS_DIR:-.claude/pipeline-artifacts}/checks-responses.jsonl"
}

_mc_log_response() {
    local sha="$1"; local response="$2"; local attempt="$3"
    local file; file=$(_mc_responses_file)
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    local entry
    entry=$(jq -cn \
        --arg sha "$sha" \
        --argjson attempt "$attempt" \
        --arg iso "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson response "$response" \
        '{commit_sha:$sha, attempt:$attempt, iso:$iso, response:$response}' 2>/dev/null) || return 0
    echo "$entry" >> "$file"
}

# Compute next backoff delay: 1, 2, 4, 8, 8, 8, ...
_mc_next_delay() {
    local attempt="$1"
    local d=$(( 1 << (attempt - 1) ))
    [[ $d -gt $MC_BACKOFF_MAX_S ]] && d=$MC_BACKOFF_MAX_S
    echo "$d"
}

# Examine a check-runs JSON response and classify it.
# Echoes one of: passed | failed | pending | empty
checks_classify_response() {
    local response="${1:-}"
    [[ -z "$response" ]] && { echo "empty"; return 0; }
    # Validate JSON
    echo "$response" | jq empty 2>/dev/null || { echo "empty"; return 0; }

    local total
    total=$(echo "$response" | jq '.total_count // (.check_runs | length // 0)' 2>/dev/null)
    [[ -z "$total" || "$total" == "null" || "$total" -eq 0 ]] && { echo "empty"; return 0; }

    # Any in-progress / queued / pending → still pending
    local pending
    pending=$(echo "$response" | jq '[.check_runs[]? | select(.status != "completed")] | length' 2>/dev/null)
    if [[ -n "$pending" && "$pending" != "null" && "$pending" -gt 0 ]]; then
        echo "pending"
        return 0
    fi

    # All completed: any non-success conclusion → failed
    local bad
    bad=$(echo "$response" | jq '[.check_runs[]? | select(.conclusion != null and .conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped")] | length' 2>/dev/null)
    if [[ -n "$bad" && "$bad" != "null" && "$bad" -gt 0 ]]; then
        echo "failed"
        return 0
    fi
    echo "passed"
}

# Poll required checks for a commit SHA.
# Echoes final classification: passed | failed | timeout
# Always exits 0 (caller decides on classification).
checks_poll_required_checks() {
    local owner="${1:-}"; local repo="${2:-}"; local sha="${3:-}"
    local timeout_s="${4:-$MC_DEFAULT_TIMEOUT_S}"
    [[ -z "$owner" || -z "$repo" || -z "$sha" ]] && { echo "empty"; return 0; }

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        echo "passed"
        return 0
    fi

    local start now elapsed attempt=0 response classification
    start=$(date +%s)

    while :; do
        attempt=$((attempt + 1))
        response=$(gh api "repos/${owner}/${repo}/commits/${sha}/check-runs" 2>/dev/null || echo "")
        if [[ -n "$response" ]]; then
            _mc_log_response "$sha" "$response" "$attempt"
            classification=$(checks_classify_response "$response")
            case "$classification" in
                passed|failed)
                    echo "$classification"
                    return 0
                    ;;
                empty)
                    # No checks configured: treat as passed (nothing to gate on)
                    # Wait one full backoff before concluding to allow checks to register
                    if [[ "$attempt" -ge 3 ]]; then
                        echo "passed"
                        return 0
                    fi
                    ;;
                pending) : ;;  # keep polling
            esac
        fi

        now=$(date +%s); elapsed=$(( now - start ))
        if [[ "$elapsed" -ge "$timeout_s" ]]; then
            echo "timeout"
            return 0
        fi

        sleep "$(_mc_next_delay "$attempt")"
    done
}

# Convenience: parse owner/repo from `gh repo view --json` (cached, single call)
checks_detect_owner_repo() {
    if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
        echo "$GITHUB_REPOSITORY"
        return 0
    fi
    local v
    v=$(gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null || true)
    [[ -n "$v" ]] && echo "$v"
}
