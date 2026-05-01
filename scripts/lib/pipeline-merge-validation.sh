#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  pipeline-merge-validation — State machine + safe revert helpers         ║
# ║                                                                          ║
# ║  Powers post-merge validation in the validate stage:                     ║
# ║   - Atomic JSON state machine (VALIDATING → SUCCESS|FAILED → REVERT*)    ║
# ║   - flock-based serialization (30 min lock timeout)                      ║
# ║   - Safe revert with idempotency + no-cascade guards                     ║
# ║   - Async issue-reopen retry queue with circuit breaker                  ║
# ║   - Memory logging of validation outcomes                                ║
# ║                                                                          ║
# ║  All writes are atomic (temp + mv). All risky ops are fail-soft.         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_PIPELINE_MERGE_VALIDATION_LOADED:-}" ]] && return 0
_PIPELINE_MERGE_VALIDATION_LOADED=1

# ─── State constants ─────────────────────────────────────────────────────────
readonly MV_STATE_VALIDATING="STATE_VALIDATING"
readonly MV_STATE_SUCCESS="STATE_SUCCESS"
readonly MV_STATE_FAILED="STATE_FAILED"
readonly MV_STATE_REVERTING="STATE_REVERTING"
readonly MV_STATE_REVERTED="STATE_REVERTED"
readonly MV_STATE_REVERT_FAILED="STATE_REVERT_FAILED"

# Lock-break timeout: stale locks held longer than this are forcibly released
readonly MV_LOCK_STALE_SECONDS=1800   # 30 min

# Circuit breaker: refuse new revert if N consecutive reverts have failed
readonly MV_REVERT_CB_THRESHOLD=3
readonly MV_REVERT_CB_WINDOW_SECONDS=86400  # 24 h

# Issue-reopen circuit breaker
readonly MV_ISSUE_REOPEN_CB_THRESHOLD=3

# ─── Path helpers (lazy-resolved against ARTIFACTS_DIR) ─────────────────────
_mv_state_file()   { echo "${ARTIFACTS_DIR:-.claude/pipeline-artifacts}/validation-state.json"; }
_mv_lock_file()    { echo "${ARTIFACTS_DIR:-.claude/pipeline-artifacts}/validation-lock"; }
_mv_revert_log()   { echo "${ARTIFACTS_DIR:-.claude/pipeline-artifacts}/revert-history.jsonl"; }
_mv_pending_reopens() { echo "${ARTIFACTS_DIR:-.claude/pipeline-artifacts}/pending-issue-reopens.jsonl"; }

_mv_memory_file() {
    local repo_hash
    repo_hash=$(echo "${PROJECT_ROOT:-$(pwd)}" | cksum | awk '{print $1}')
    local dir="${HOME}/.shipwright/memory/${repo_hash}"
    mkdir -p "$dir" 2>/dev/null || true
    echo "${dir}/validation-failures.jsonl"
}

_mv_now_epoch() { date +%s; }
_mv_now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ─── Atomic write helper ────────────────────────────────────────────────────
_mv_atomic_write() {
    local path="$1"; local content="$2"
    local dir tmp
    dir=$(dirname "$path")
    mkdir -p "$dir" 2>/dev/null || return 1
    tmp=$(mktemp "${dir}/.mv-tmp.XXXXXX") || return 1
    printf '%s' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path"
}

# ─── Lock management (flock-based) ──────────────────────────────────────────
# Returns 0 on acquisition. Auto-breaks stale locks (mtime > MV_LOCK_STALE_SECONDS).
validation_lock_acquire() {
    local lock; lock=$(_mv_lock_file)
    mkdir -p "$(dirname "$lock")" 2>/dev/null || true

    # Stale-lock detection: break locks older than threshold
    if [[ -f "$lock" ]]; then
        local age now mtime
        now=$(_mv_now_epoch)
        # Cross-platform mtime: GNU stat -c, BSD stat -f
        mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo "$now")
        age=$(( now - mtime ))
        if [[ "$age" -gt "$MV_LOCK_STALE_SECONDS" ]]; then
            rm -f "$lock"
        fi
    fi

    # Use flock when available; otherwise atomic mkdir-style fallback
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lock" 2>/dev/null || return 1
        flock -n 9 || return 1
        return 0
    fi
    # Fallback: noclobber lock
    ( set -o noclobber; : > "$lock" ) 2>/dev/null || return 1
    return 0
}

validation_lock_release() {
    local lock; lock=$(_mv_lock_file)
    if command -v flock >/dev/null 2>&1; then
        flock -u 9 2>/dev/null || true
        exec 9>&- 2>/dev/null || true
    fi
    rm -f "$lock" 2>/dev/null || true
}

# ─── State machine ─────────────────────────────────────────────────────────
# Initialize state for a merge commit. Idempotent: replaces any prior state.
validation_state_init() {
    local merge_sha="${1:-}"
    [[ -z "$merge_sha" ]] && { echo "validation_state_init: merge_sha required" >&2; return 1; }

    local issue_num="${2:-${ISSUE_NUMBER:-}}"
    local now; now=$(_mv_now_epoch)
    local content
    content=$(jq -n \
        --arg state "$MV_STATE_VALIDATING" \
        --arg sha "$merge_sha" \
        --arg iso "$(_mv_now_iso)" \
        --argjson epoch "$now" \
        --arg issue "$issue_num" \
        '{
            state: $state,
            merge_commit_sha: $sha,
            issue_number: $issue,
            validation_start_iso: $iso,
            validation_start_epoch: $epoch,
            checks_api_responses: [],
            smoke_tests_log: "",
            revert_status: null,
            updated_iso: $iso
        }') || return 1
    _mv_atomic_write "$(_mv_state_file)" "$content"
}

# Read state JSON. Returns "{}" if file is missing or corrupt.
validation_state_read() {
    local path; path=$(_mv_state_file)
    [[ -f "$path" ]] || { echo "{}"; return 0; }
    if jq empty "$path" 2>/dev/null; then
        cat "$path"
    else
        echo "{}"
    fi
}

# Atomically transition to a new state, optionally merging additional fields (JSON object).
# Usage: validation_state_transition STATE_FAILED '{"reason":"smoke","exit_code":1}'
validation_state_transition() {
    local new_state="$1"; local extra="${2:-{\}}"
    [[ -z "$new_state" ]] && return 1

    local current; current=$(validation_state_read)
    local merged
    merged=$(jq -n \
        --argjson cur "$current" \
        --argjson extra "$extra" \
        --arg state "$new_state" \
        --arg iso "$(_mv_now_iso)" \
        '$cur + $extra + {state: $state, updated_iso: $iso}') || return 1
    _mv_atomic_write "$(_mv_state_file)" "$merged"
}

validation_state_get_field() {
    local field="$1"
    validation_state_read | jq -r --arg f "$field" '.[$f] // empty'
}

# ─── Safe revert helpers ───────────────────────────────────────────────────
# Returns 0 if a revert of this commit already exists in recent history.
revert_is_already_applied() {
    local sha="${1:-}"
    [[ -z "$sha" ]] && return 1
    # Look for a "Revert" commit referencing the short SHA in recent history (last 100)
    local short="${sha:0:7}"
    git log -n 100 --grep="Revert" --oneline 2>/dev/null \
        | grep -q -F "$short" && return 0
    # Also look for the canonical "This reverts commit <full-sha>" body
    git log -n 100 --grep="This reverts commit ${sha}" 2>/dev/null \
        | grep -q . && return 0
    return 1
}

# Returns 0 if HEAD is no longer the commit we were validating (someone else committed).
revert_is_head_different() {
    local validated_sha="${1:-}"
    [[ -z "$validated_sha" ]] && return 1
    local head_sha
    head_sha=$(git rev-parse HEAD 2>/dev/null) || return 1
    [[ "$head_sha" != "$validated_sha" ]]
}

# Circuit-breaker: returns 0 (open, refuse) if we've had >= threshold revert failures
# in the last MV_REVERT_CB_WINDOW_SECONDS.
revert_circuit_breaker_open() {
    local log; log=$(_mv_revert_log)
    [[ -f "$log" ]] || return 1
    local cutoff now fails
    now=$(_mv_now_epoch)
    cutoff=$(( now - MV_REVERT_CB_WINDOW_SECONDS ))
    fails=$(jq -s --argjson cutoff "$cutoff" \
        '[.[] | select(.epoch >= $cutoff and .outcome == "failed")] | length' \
        "$log" 2>/dev/null || echo 0)
    [[ "$fails" -ge "$MV_REVERT_CB_THRESHOLD" ]]
}

_mv_revert_log_append() {
    local sha="$1"; local outcome="$2"; local reason="${3:-}"
    local log; log=$(_mv_revert_log)
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    local entry
    entry=$(jq -cn \
        --arg sha "$sha" \
        --arg outcome "$outcome" \
        --arg reason "$reason" \
        --arg iso "$(_mv_now_iso)" \
        --argjson epoch "$(_mv_now_epoch)" \
        '{commit_sha:$sha, outcome:$outcome, reason:$reason, iso:$iso, epoch:$epoch}')
    echo "$entry" >> "$log"
}

# Execute the revert. Returns:
#   0 = reverted successfully
#   2 = skipped (idempotent / no-cascade / circuit breaker)
#   1 = failed (conflict or other error)
revert_commit() {
    local sha="${1:-}"
    [[ -z "$sha" ]] && return 1

    if revert_circuit_breaker_open; then
        _mv_revert_log_append "$sha" "skipped" "circuit_breaker_open"
        return 2
    fi
    if revert_is_already_applied "$sha"; then
        _mv_revert_log_append "$sha" "skipped" "already_reverted"
        return 2
    fi
    if revert_is_head_different "$sha"; then
        _mv_revert_log_append "$sha" "skipped" "head_moved"
        return 2
    fi

    local before after
    before=$(git rev-parse HEAD 2>/dev/null)
    if ! git revert --no-edit -m 1 "$sha" >/dev/null 2>&1; then
        # Try non-merge revert as fallback (commit was not a merge)
        git revert --abort >/dev/null 2>&1 || true
        if ! git revert --no-edit "$sha" >/dev/null 2>&1; then
            git revert --abort >/dev/null 2>&1 || true
            _mv_revert_log_append "$sha" "failed" "conflict_or_error"
            return 1
        fi
    fi
    after=$(git rev-parse HEAD 2>/dev/null)
    if [[ "$before" == "$after" ]]; then
        _mv_revert_log_append "$sha" "failed" "no_sha_change"
        return 1
    fi
    _mv_revert_log_append "$sha" "succeeded" "$after"
    echo "$after"
    return 0
}

# ─── Issue reopening with async retry queue ─────────────────────────────────
# Reopen an issue with failure context. On failure, append to retry queue.
issue_reopen_with_context() {
    local issue_num="${1:-}"
    local merge_sha="${2:-}"
    local revert_sha="${3:-}"
    local failure_summary="${4:-Validation failed after merge}"
    [[ -z "$issue_num" ]] && return 1

    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    local body
    body=$(printf '## Post-merge validation failed\n\n%s\n\n| Field | Value |\n|---|---|\n| Merge commit | `%s` |\n| Revert commit | `%s` |\n| Detected at | %s |\n\n_Reopened automatically by `shipwright pipeline` validate stage._' \
        "$failure_summary" "$merge_sha" "${revert_sha:-not-reverted}" "$(_mv_now_iso)")

    if gh issue reopen "$issue_num" --comment "$body" >/dev/null 2>&1; then
        gh issue edit "$issue_num" --add-label "validation-failed" >/dev/null 2>&1 || true
        return 0
    fi
    _mv_queue_pending_reopen "$issue_num" "$merge_sha" "$revert_sha" "$failure_summary"
    return 1
}

_mv_queue_pending_reopen() {
    local issue_num="$1"; local merge_sha="$2"; local revert_sha="$3"; local summary="$4"
    local q; q=$(_mv_pending_reopens)
    mkdir -p "$(dirname "$q")" 2>/dev/null || true
    local entry
    entry=$(jq -cn \
        --arg issue "$issue_num" \
        --arg merge "$merge_sha" \
        --arg revert "$revert_sha" \
        --arg summary "$summary" \
        --arg iso "$(_mv_now_iso)" \
        --argjson attempts 1 \
        '{issue_number:$issue, merge_commit_sha:$merge, revert_commit_sha:$revert, summary:$summary, queued_iso:$iso, attempts:$attempts}')
    echo "$entry" >> "$q"
}

# Process the retry queue. Each entry retried once per call. Circuit-broken after MV_ISSUE_REOPEN_CB_THRESHOLD attempts.
issue_reopen_process_queue() {
    local q; q=$(_mv_pending_reopens)
    [[ -f "$q" ]] || return 0
    [[ ! -s "$q" ]] && { rm -f "$q"; return 0; }
    if [[ "${NO_GITHUB:-}" == "true" || "${NO_GITHUB:-}" == "1" ]]; then
        return 0
    fi

    local tmp; tmp=$(mktemp)
    local entry issue merge revert summary attempts ok
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        issue=$(echo "$entry" | jq -r '.issue_number // ""')
        merge=$(echo "$entry" | jq -r '.merge_commit_sha // ""')
        revert=$(echo "$entry" | jq -r '.revert_commit_sha // ""')
        summary=$(echo "$entry" | jq -r '.summary // ""')
        attempts=$(echo "$entry" | jq -r '.attempts // 1')
        if [[ "$attempts" -ge "$MV_ISSUE_REOPEN_CB_THRESHOLD" ]]; then
            # Drop with operator alert (left in JSONL .dead-letter for inspection)
            echo "$entry" | jq -c '. + {dead_letter_iso: "'"$(_mv_now_iso)"'"}' >> "${q}.dead-letter"
            continue
        fi
        ok=0
        gh issue reopen "$issue" --comment "$summary (retry attempt $attempts)" >/dev/null 2>&1 && ok=1
        if [[ "$ok" -eq 1 ]]; then
            gh issue edit "$issue" --add-label "validation-failed" >/dev/null 2>&1 || true
        else
            echo "$entry" | jq -c --argjson n "$((attempts + 1))" '.attempts = $n' >> "$tmp"
        fi
    done < "$q"
    if [[ -s "$tmp" ]]; then
        mv -f "$tmp" "$q"
    else
        rm -f "$tmp" "$q"
    fi
}

# ─── Memory logging ────────────────────────────────────────────────────────
# Append a validation outcome record. Truncates to last 100 entries.
validation_memory_log() {
    local merge_sha="$1"; local outcome="$2"; local root_cause="${3:-unknown}"
    local revert_sha="${4:-}"; local detection_seconds="${5:-0}"
    local file; file=$(_mv_memory_file)
    local entry
    entry=$(jq -cn \
        --arg sha "$merge_sha" \
        --arg outcome "$outcome" \
        --arg cause "$root_cause" \
        --arg revert "$revert_sha" \
        --argjson detect "$detection_seconds" \
        --arg iso "$(_mv_now_iso)" \
        '{commit_sha:$sha, outcome:$outcome, root_cause:$cause, revert_commit_sha:$revert, detection_seconds:$detect, iso:$iso}')
    echo "$entry" >> "$file"
    # Truncate to last 100 entries
    if [[ $(wc -l < "$file" 2>/dev/null || echo 0) -gt 100 ]]; then
        local tail_tmp; tail_tmp=$(mktemp)
        tail -n 100 "$file" > "$tail_tmp" && mv -f "$tail_tmp" "$file"
    fi
}
