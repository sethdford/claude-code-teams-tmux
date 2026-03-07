#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright post-merge-monitor — Production Feedback & Regression Learn  ║
# ║  Polls GitHub · Correlates signals · Emits events · Updates memory       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.2.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"

# Memory system integration (for regression tracking)
# shellcheck source=sw-memory.sh
[[ -f "$SCRIPT_DIR/sw-memory.sh" ]] && source "$SCRIPT_DIR/sw-memory.sh"

# Fallbacks when helpers not loaded (e.g. test env)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*" >&2; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Storage Paths ─────────────────────────────────────────────────────────
POST_MERGE_HEALTH_FILE="${HOME}/.shipwright/post-merge-health.jsonl"
POLL_LIMIT=20  # Check 20 recent merges

# ─── Initialize directories ───────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "${HOME}/.shipwright"
}

# ─── Detect owner/repo from git remote ──────────────────────────────────────
get_owner_repo() {
    local remote_url
    remote_url=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)
    if [[ -z "$remote_url" ]]; then
        return 1
    fi
    echo "$remote_url" | sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##'
}

# ─── Get recent merged PRs from GitHub ──────────────────────────────────────
get_recent_merged_prs() {
    # Returns JSON array: [{ "number": 123, "mergedAt": "...", "mergeCommit": "abc123", "headRefName": "feat/..." }]
    if [[ -n "${NO_GITHUB:-}" ]]; then
        echo "[]"
        return 0
    fi

    local owner_repo
    owner_repo=$(get_owner_repo) || { warn "Could not determine owner/repo"; return 1; }

    # Use gh CLI to get recent merged PRs
    gh pr list \
        --repo "$owner_repo" \
        --state merged \
        --limit "$POLL_LIMIT" \
        --json number,mergedAt,mergeCommit,headRefName 2>/dev/null || echo "[]"
}

# ─── Check CI status for a commit ───────────────────────────────────────────
check_ci_status_for_commit() {
    local commit_sha="$1"
    local owner_repo="$2"
    # Returns: "pass" or "fail" + error context

    if [[ -n "${NO_GITHUB:-}" ]]; then
        return 0
    fi

    # Check status checks on main branch for this commit
    local checks_json
    checks_json=$(gh api repos/"$owner_repo"/commits/"$commit_sha"/check-runs \
        --jq '.check_runs | map(select(.status == "completed")) | .[] | select(.conclusion == "failure")' 2>/dev/null || true)

    if [[ -n "$checks_json" ]]; then
        echo "$checks_json" | jq -r '.name' 2>/dev/null | head -1 || echo "CI check failed"
    fi
}

# ─── Check deployment status ────────────────────────────────────────────────
check_deployment_status() {
    local commit_sha="$1"
    local owner_repo="$2"
    # Returns deployment failure context if found

    if [[ -n "${NO_GITHUB:-}" ]]; then
        return 0
    fi

    # Get deployments for this commit
    gh api repos/"$owner_repo"/deployments \
        --jq ".[] | select(.sha == \"$commit_sha\") | select(.statuses[-1].state == \"failure\") | .environment" \
        2>/dev/null || true
}

# ─── Check for regression issues labeled on this PR ─────────────────────────
check_regression_issues() {
    local pr_number="$1"
    local owner_repo="$2"
    # Returns issue titles that mention this PR number

    if [[ -n "${NO_GITHUB:-}" ]]; then
        return 0
    fi

    # Look for issues labeled 'regression' that mention this PR
    gh issue list \
        --repo "$owner_repo" \
        --label regression \
        --limit 10 \
        --json body,title 2>/dev/null | \
        jq --arg pr_num "#$pr_number" -r '.[] | select(.body | contains($pr_num)) | .title' 2>/dev/null || true
}

# ─── Correlate signals to a PR ──────────────────────────────────────────────
correlate_signals() {
    local pr_number="$1"
    local merge_sha="$2"
    local owner_repo="$3"
    shift 3
    local signals=("$@")

    # Determine health status from signal count
    local status="stable"
    local signal_count=${#signals[@]}

    if [[ $signal_count -ge 2 ]]; then
        status="regression"
    elif [[ $signal_count -eq 1 ]]; then
        status="degraded"
    fi

    echo "$status"
}

# ─── Record health atomically ───────────────────────────────────────────────
record_health() {
    local pr_number="$1"
    local status="$2"
    local merge_sha="$3"
    local merged_at="$4"
    local signals_json="$5"

    ensure_dirs

    local tmp_file
    tmp_file=$(mktemp "${POST_MERGE_HEALTH_FILE}.tmp.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" EXIT

    local record
    record=$(jq -n \
        --arg pr_num "$pr_number" \
        --arg status "$status" \
        --arg merge_sha "$merge_sha" \
        --arg merged_at "$merged_at" \
        --arg ts "$(now_iso)" \
        --argjson signals "$signals_json" \
        '{
            pr_number: ($pr_num | tonumber),
            status: $status,
            merge_sha: $merge_sha,
            merged_at: $merged_at,
            signals: $signals,
            last_checked: $ts
        }')

    # Append to JSONL (idempotency: if PR already in file, this is a duplicate detection issue)
    echo "$record" >> "$tmp_file"

    # If old file exists, copy non-duplicate entries
    if [[ -f "$POST_MERGE_HEALTH_FILE" ]]; then
        # Filter out old records for this PR number, append new one
        jq --arg pr_num "$pr_number" 'select(.pr_number != ($pr_num | tonumber))' \
            "$POST_MERGE_HEALTH_FILE" >> "$tmp_file" 2>/dev/null || true
    fi

    # Atomic move
    mv "$tmp_file" "$POST_MERGE_HEALTH_FILE"
}

# ─── Emit regression event to memory ────────────────────────────────────────
emit_regression_event() {
    local pr_number="$1"
    local signal_type="$2"
    local ref="$3"
    local error_context="$4"
    local confidence="${5:-medium}"

    local owner_repo
    owner_repo=$(get_owner_repo) || owner_repo="unknown/unknown"

    # Emit event to event bus
    emit_event "feedback.production.regression" \
        "pr_number=$pr_number" \
        "signal_type=$signal_type" \
        "ref=${ref:0:40}" \
        "confidence=$confidence" \
        "repo=$owner_repo" \
        "context=${error_context:0:100}"

    # Capture in memory system with production tags
    if type memory_capture_failure >/dev/null 2>&1; then
        local failure_pattern="[PRODUCTION_REGRESSION] PR #$pr_number: $signal_type — $error_context (confidence: $confidence)"
        local tags='["production_regression","feedback","post_merge"]'
        memory_capture_failure "deploy" "$failure_pattern" "post-merge-monitor" "$tags" 2>/dev/null || true
    fi
}

# ─── Poll GitHub for signals ───────────────────────────────────────────────
cmd_monitor() {
    local dry_run="${1:-}"

    if [[ -n "${NO_GITHUB:-}" ]]; then
        warn "NO_GITHUB mode: skipping GitHub API calls"
        return 0
    fi

    info "Polling GitHub for post-merge signals..."
    ensure_dirs

    local owner_repo
    owner_repo=$(get_owner_repo) || { error "Could not determine owner/repo"; return 1; }

    # Get recent merged PRs
    local prs_json
    prs_json=$(get_recent_merged_prs) || { error "Failed to fetch merged PRs"; return 1; }

    local pr_count
    pr_count=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo "0")
    info "Found $pr_count recent merged PRs"

    # For each PR, check for signals
    local pr_idx=0
    while [[ $pr_idx -lt $(echo "$prs_json" | jq 'length' 2>/dev/null || echo "0") ]]; do
        local pr_data
        pr_data=$(echo "$prs_json" | jq ".[$pr_idx]" 2>/dev/null || echo "{}")

        local pr_number merge_sha merged_at
        pr_number=$(echo "$pr_data" | jq -r '.number' 2>/dev/null || echo "")
        merge_sha=$(echo "$pr_data" | jq -r '.mergeCommit.oid' 2>/dev/null || echo "")
        merged_at=$(echo "$pr_data" | jq -r '.mergedAt' 2>/dev/null || echo "")

        if [[ -z "$pr_number" || -z "$merge_sha" ]]; then
            pr_idx=$((pr_idx + 1))
            continue
        fi

        info "Checking PR #$pr_number (merged at $merged_at)"

        # Collect signals for this PR
        local signals_json="[]"
        local has_signals=false

        # Check CI status
        local ci_failure
        ci_failure=$(check_ci_status_for_commit "$merge_sha" "$owner_repo" 2>/dev/null || true)
        if [[ -n "$ci_failure" ]]; then
            signals_json=$(echo "$signals_json" | jq --arg type "ci_failure" --arg ctx "$ci_failure" \
                '. += [{type: $type, error_context: $ctx, confidence: "high"}]' 2>/dev/null || echo "[]")
            has_signals=true
        fi

        # Check deployment status
        local deploy_env
        deploy_env=$(check_deployment_status "$merge_sha" "$owner_repo" 2>/dev/null || true)
        if [[ -n "$deploy_env" ]]; then
            signals_json=$(echo "$signals_json" | jq --arg env "$deploy_env" \
                '. += [{type: "deploy_failure", error_context: $env, confidence: "high"}]' 2>/dev/null || echo "[]")
            has_signals=true
        fi

        # Check regression issues
        local regression_issue
        regression_issue=$(check_regression_issues "$pr_number" "$owner_repo" 2>/dev/null || true)
        if [[ -n "$regression_issue" ]]; then
            signals_json=$(echo "$signals_json" | jq --arg issue "$regression_issue" \
                '. += [{type: "regression_issue", error_context: $issue, confidence: "medium"}]' 2>/dev/null || echo "[]")
            has_signals=true
        fi

        # Record health
        local status
        status=$(correlate_signals "$pr_number" "$merge_sha" "$owner_repo" $([[ "$has_signals" == "true" ]] && echo "signal" || true))

        if [[ -z "$dry_run" ]]; then
            record_health "$pr_number" "$status" "$merge_sha" "$merged_at" "$signals_json"

            # Emit events for new signals
            if [[ "$has_signals" == "true" ]]; then
                emit_regression_event "$pr_number" "mixed_signals" "$merge_sha" "PR $pr_number has production issues"
            fi
        fi

        [[ "$status" == "stable" ]] && success "PR #$pr_number: stable" || warn "PR #$pr_number: $status"

        pr_idx=$((pr_idx + 1))
    done

    success "Post-merge monitoring complete"
}

# ─── Check a single PR's health ────────────────────────────────────────────
cmd_check_pr() {
    local pr_number="${1:-}"
    [[ -z "$pr_number" ]] && { error "Usage: check-pr <pr_number>"; return 1; }

    if [[ -n "${NO_GITHUB:-}" ]]; then
        warn "NO_GITHUB mode: skipping GitHub API calls"
        return 0
    fi

    info "Checking health of PR #$pr_number..."

    local owner_repo
    owner_repo=$(get_owner_repo) || { error "Could not determine owner/repo"; return 1; }

    # Fetch the PR
    local pr_data
    pr_data=$(gh pr view "$pr_number" --repo "$owner_repo" --json mergeCommit,mergedAt,state 2>/dev/null || echo "{}")

    local state
    state=$(echo "$pr_data" | jq -r '.state' 2>/dev/null)

    if [[ "$state" != "MERGED" ]]; then
        warn "PR #$pr_number is not merged (state: $state)"
        return 0
    fi

    local merge_sha merged_at
    merge_sha=$(echo "$pr_data" | jq -r '.mergeCommit.oid' 2>/dev/null)
    merged_at=$(echo "$pr_data" | jq -r '.mergedAt' 2>/dev/null)

    # Collect signals
    local signals_json="[]"
    local has_signals=false

    local ci_failure
    ci_failure=$(check_ci_status_for_commit "$merge_sha" "$owner_repo" 2>/dev/null || true)
    [[ -n "$ci_failure" ]] && {
        signals_json=$(echo "$signals_json" | jq --arg ctx "$ci_failure" '. += [{type: "ci_failure", error_context: $ctx}]' 2>/dev/null || echo "[]")
        has_signals=true
    }

    # Determine status
    local status
    [[ "$has_signals" == "true" ]] && status="degraded" || status="stable"

    info "PR #$pr_number: $status"
    echo "$signals_json" | jq '.'
}

# ─── Show recent merge health status ────────────────────────────────────────
cmd_status() {
    ensure_dirs

    if [[ ! -f "$POST_MERGE_HEALTH_FILE" ]]; then
        info "No post-merge health records yet"
        return 0
    fi

    info "Recent Merge Health Status:"
    echo ""

    local total stable degraded regression
    total=0 stable=0 degraded=0 regression=0

    tail -20 "$POST_MERGE_HEALTH_FILE" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pr_num status merged_at signal_count
        pr_num=$(echo "$line" | jq -r '.pr_number' 2>/dev/null || echo "?")
        status=$(echo "$line" | jq -r '.status' 2>/dev/null || echo "?")
        merged_at=$(echo "$line" | jq -r '.merged_at' 2>/dev/null || echo "?")
        signal_count=$(echo "$line" | jq '.signals | length' 2>/dev/null || echo "0")

        case "$status" in
            stable)      echo "  ✓ PR #$pr_num: stable ($signal_count signals)" ;;
            degraded)    echo "  ⚠ PR #$pr_num: degraded ($signal_count signals)" ;;
            regression)  echo "  ✗ PR #$pr_num: regression ($signal_count signals)" ;;
            *)           echo "  ? PR #$pr_num: unknown" ;;
        esac
    done

    echo ""
    info "Run 'jq .' on $POST_MERGE_HEALTH_FILE for detailed view"
}

# ─── Manually ingest a production event ────────────────────────────────────
cmd_ingest() {
    local event_json="${1:-}"
    [[ -z "$event_json" ]] && { error "Usage: ingest <json>"; return 1; }

    ensure_dirs

    # Validate JSON
    if ! echo "$event_json" | jq . >/dev/null 2>&1; then
        error "Invalid JSON provided"
        return 1
    fi

    # Extract PR number and signal info
    local pr_number signal_type error_context
    pr_number=$(echo "$event_json" | jq -r '.pr_number // empty' 2>/dev/null || echo "")
    signal_type=$(echo "$event_json" | jq -r '.signal_type // "unknown"' 2>/dev/null || echo "unknown")
    error_context=$(echo "$event_json" | jq -r '.error_context // "ingested event"' 2>/dev/null || echo "ingested event")

    if [[ -z "$pr_number" ]]; then
        error "Event must include pr_number"
        return 1
    fi

    emit_regression_event "$pr_number" "$signal_type" "ingested" "$error_context"
    success "Event ingested for PR #$pr_number"
}

# ─── Show help ─────────────────────────────────────────────────────────────
cmd_help() {
    cat <<'EOF'
shipwright post-merge-monitor — Post-merge production feedback & regression learning

USAGE:
  shipwright post-merge-monitor <subcommand> [args]

SUBCOMMANDS:
  monitor           Poll GitHub for post-merge signals, record health, emit events
  check-pr <num>    Check health of a specific merged PR
  status            Show recent merge health summary
  ingest <json>     Manually ingest a production event
  help              Show this help text

EXAMPLES:
  shipwright post-merge-monitor monitor
  shipwright post-merge-monitor check-pr 123
  shipwright feedback monitor          # (alias)

ENVIRONMENT:
  NO_GITHUB=1       Skip all GitHub API calls (local/offline mode)

DATA:
  Health records:   ~/.shipwright/post-merge-health.jsonl
  Events log:       ~/.shipwright/events.jsonl
EOF
}

# ─── Main router ───────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"

    case "$cmd" in
        monitor|poll)    cmd_monitor "${2:-}" ;;
        check-pr)        cmd_check_pr "${2:-}" ;;
        status)          cmd_status ;;
        ingest)          cmd_ingest "${2:-}" ;;
        help|--help|-h)  cmd_help ;;
        *)               error "Unknown command: $cmd"; cmd_help; return 1 ;;
    esac
}

main "$@"
