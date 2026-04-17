#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  conflict-queue — FIFO queue for issues blocked by file-lock conflicts    ║
# ║  When daemon/fleet can't spawn due to a file lock, the issue is enqueued  ║
# ║  here; release_files + drain_queue pop a ready issue for re-spawn.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Storage: append-only JSON array at $CONFLICT_QUEUE_FILE. All mutations are
# serialized via flock on ${CONFLICT_QUEUE_FILE}.lock, matching the scheme
# used by file-locks.sh (single serializer across both registries).
#
# Entry schema:
#   { "issue": <n>, "repo": "owner/name", "title": "...",
#     "files": ["a","b"], "enqueued_at": "ISO",
#     "blocked_by_pid": "<owner-pid>", "blocked_by_issue": <n> }

[[ -n "${_CONFLICT_QUEUE_LOADED:-}" ]] && return 0
_CONFLICT_QUEUE_LOADED=1

DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
CONFLICT_QUEUE_FILE="${CONFLICT_QUEUE_FILE:-${DAEMON_DIR}/conflict-queue.json}"
CONFLICT_QUEUE_FLOCK_TIMEOUT="${CONFLICT_QUEUE_FLOCK_TIMEOUT:-5}"

if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
    now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
    emit_event() {
        local event_type="$1"; shift
        mkdir -p "${DAEMON_DIR}"
        local payload="{\"ts\":\"$(now_iso)\",\"type\":\"${event_type}\""
        while [[ $# -gt 0 ]]; do
            local key="${1%%=*}" val="${1#*=}"
            payload="${payload},\"${key}\":\"${val}\""
            shift
        done
        echo "${payload}}" >> "${DAEMON_DIR}/events.jsonl"
    }
fi

_queue_init() {
    mkdir -p "$DAEMON_DIR"
    [[ -s "$CONFLICT_QUEUE_FILE" ]] || echo '[]' > "$CONFLICT_QUEUE_FILE"
}

# ─── Internal: serialized read-modify-write on the queue file ───────────────
_queue_update() {
    local jq_expr="$1"; shift
    _queue_init
    local flock_lock="${CONFLICT_QUEUE_FILE}.lock"
    local out
    out=$({
        (
            if command -v flock >/dev/null 2>&1; then
                flock -w "$CONFLICT_QUEUE_FLOCK_TIMEOUT" 202 2>/dev/null || exit 1
            fi
            local tmp
            tmp=$(jq -c "$jq_expr" "$@" "$CONFLICT_QUEUE_FILE" 2>/dev/null) || exit 1
            local tmp_file
            tmp_file=$(mktemp "${CONFLICT_QUEUE_FILE}.tmp.XXXXXX") || exit 1
            printf '%s\n' "$tmp" > "$tmp_file" || { rm -f "$tmp_file"; exit 1; }
            mv "$tmp_file" "$CONFLICT_QUEUE_FILE" || { rm -f "$tmp_file"; exit 1; }
            printf '%s' "$tmp"
        ) 202>"$flock_lock"
    }) || return 1
    printf '%s' "$out"
}

# ─── Public: enqueue a blocked issue ────────────────────────────────────────
# Usage: queue_enqueue <issue_num> <repo> <title> <blocked_by_pid> \
#                      <blocked_by_issue> <file1> [file2 ...]
queue_enqueue() {
    local issue="$1" repo="$2" title="$3" blocked_pid="$4" blocked_issue="$5"
    shift 5
    local files_json
    files_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    local now
    now=$(now_iso)
    _queue_update '
        . + [{
            issue: ($issue | tonumber),
            repo: $repo,
            title: $title,
            files: $files,
            enqueued_at: $now,
            blocked_by_pid: $blocked_pid,
            blocked_by_issue: ($blocked_issue | tonumber)
        }]
    ' \
        --arg issue "$issue" \
        --arg repo "$repo" \
        --arg title "$title" \
        --argjson files "$files_json" \
        --arg now "$now" \
        --arg blocked_pid "$blocked_pid" \
        --arg blocked_issue "$blocked_issue" >/dev/null || return 1
    emit_event "daemon.conflict_enqueued" \
        "issue=$issue" "blocked_by_issue=$blocked_issue" "file_count=$#"
    return 0
}

# ─── Public: pop first queued entry whose files are now free ────────────────
# Usage: queue_pop_ready
# Echoes the popped entry JSON (or empty string if none ready).
# Requires file-locks.sh to be sourced so we can call lock_check_conflict.
queue_pop_ready() {
    _queue_init
    if [[ "$(type -t lock_check_conflict 2>/dev/null)" != "function" ]]; then
        return 1
    fi
    # Snapshot the queue (read only).
    local entries
    entries=$(jq -c '.[]' "$CONFLICT_QUEUE_FILE" 2>/dev/null) || return 1
    [[ -z "$entries" ]] && return 0

    local idx=0 chosen_idx=-1 chosen_entry=""
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && { idx=$((idx+1)); continue; }
        local files_args=()
        while IFS= read -r f; do
            [[ -n "$f" ]] && files_args+=("$f")
        done < <(echo "$entry" | jq -r '.files[]?')
        if [[ ${#files_args[@]} -eq 0 ]] || lock_check_conflict "${files_args[@]}" >/dev/null; then
            chosen_idx=$idx
            chosen_entry="$entry"
            break
        fi
        idx=$((idx+1))
    done <<< "$entries"

    [[ "$chosen_idx" -lt 0 ]] && return 0

    _queue_update 'del(.[$idx | tonumber])' --arg idx "$chosen_idx" >/dev/null || return 1
    local popped_issue
    popped_issue=$(echo "$chosen_entry" | jq -r '.issue')
    emit_event "daemon.conflict_dequeued" "issue=$popped_issue"
    printf '%s' "$chosen_entry"
    return 0
}

# ─── Public: list current queued entries ────────────────────────────────────
queue_list() {
    _queue_init
    jq -c '.' "$CONFLICT_QUEUE_FILE" 2>/dev/null || echo '[]'
}

# ─── Public: current depth ──────────────────────────────────────────────────
queue_depth() {
    _queue_init
    jq -r 'length' "$CONFLICT_QUEUE_FILE" 2>/dev/null || echo 0
}

# ─── Public: remove an entry by issue number (manual eviction) ──────────────
queue_remove_issue() {
    local issue="$1"
    _queue_update 'map(select(.issue != ($issue | tonumber)))' --arg issue "$issue" >/dev/null || return 1
    return 0
}

# ─── Public: clear the queue (recovery tool) ────────────────────────────────
queue_clear() {
    _queue_update '[]' >/dev/null || return 1
    emit_event "daemon.conflict_queue_cleared"
    return 0
}
