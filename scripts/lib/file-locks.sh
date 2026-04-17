#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright file-locks — File-level lock registry for parallel pipelines  ║
# ║  Prevents conflicts when daemon/fleet spawns multiple pipelines in parallel║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Overview:
#   Before spawning a pipeline, the daemon predicts which files it will edit
#   and acquires locks on them. If any target file is already locked by another
#   pipeline, the issue is queued instead of spawned. On pipeline completion,
#   locks are released and queued issues are reconsidered.
#
# Lock file schema (at $LOCK_FILE):
#   { "version":1,
#     "pipelines": { "<pid>": { "issue": <n>, "files": ["a","b"],
#                               "acquired_at": "ISO", "heartbeat": "ISO" } },
#     "metrics": { "conflicts_avoided": 0, "locks_acquired": 0,
#                  "locks_released": 0, "stale_cleaned": 0 } }
#
# Concurrency:
#   All mutations go through _lock_update() which holds a flock on
#   ${LOCK_FILE}.lock for the duration of the read-modify-write. Check and
#   acquire are one atomic operation — no TOCTOU window.
#
# Deadlock prevention:
#   Files are sorted alphabetically before acquisition. A pipeline acquires
#   all its files in a single atomic update (not one-at-a-time), so circular
#   wait cannot occur.

# Module guard
[[ -n "${_FILE_LOCKS_LOADED:-}" ]] && return 0
_FILE_LOCKS_LOADED=1

# ─── Paths ──────────────────────────────────────────────────────────────────
DAEMON_DIR="${DAEMON_DIR:-${HOME}/.shipwright}"
LOCK_FILE="${LOCK_FILE:-${DAEMON_DIR}/file-locks.json}"
HEARTBEAT_DIR="${HEARTBEAT_DIR:-${DAEMON_DIR}/heartbeats}"

# Stale timeout: a pipeline's locks are considered stale if its PID is dead
# AND its heartbeat file is older than this many seconds.
FILE_LOCK_STALE_SECONDS="${FILE_LOCK_STALE_SECONDS:-120}"

# Flock acquisition timeout (seconds).
FILE_LOCK_FLOCK_TIMEOUT="${FILE_LOCK_FLOCK_TIMEOUT:-5}"

# ─── Helper fallbacks (if not sourced from sw-daemon.sh) ────────────────────
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
fi
if [[ "$(type -t now_epoch 2>/dev/null)" != "function" ]]; then
  now_epoch() { date +%s; }
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
if [[ "$(type -t daemon_log 2>/dev/null)" != "function" ]]; then
  daemon_log() { :; }
fi

# ─── Internal: ensure lock file exists with a valid schema ──────────────────
_lock_init() {
    mkdir -p "$DAEMON_DIR" "$HEARTBEAT_DIR"
    if [[ ! -s "$LOCK_FILE" ]]; then
        echo '{"version":1,"pipelines":{},"metrics":{"conflicts_avoided":0,"locks_acquired":0,"locks_released":0,"stale_cleaned":0}}' > "$LOCK_FILE"
    fi
}

# ─── Internal: serialized read-modify-write on the lock registry ────────────
# Usage: _lock_update '<jq_expr>' [--arg k v ...]
# Writes the result of `jq <jq_expr> $LOCK_FILE` back atomically.
# Returns the jq output on stdout (caller can capture if needed).
_lock_update() {
    local jq_expr="$1"; shift
    _lock_init
    local flock_lock="${LOCK_FILE}.lock"
    local out
    out=$({
        (
            if command -v flock >/dev/null 2>&1; then
                flock -w "$FILE_LOCK_FLOCK_TIMEOUT" 201 2>/dev/null || {
                    daemon_log ERROR "file-locks: flock acquisition timed out"
                    exit 1
                }
            fi
            local tmp
            tmp=$(jq -c "$jq_expr" "$@" "$LOCK_FILE" 2>&1) || {
                daemon_log ERROR "file-locks: jq failed — $(echo "$tmp" | head -1)"
                exit 1
            }
            local tmp_file
            tmp_file=$(mktemp "${LOCK_FILE}.tmp.XXXXXX") || exit 1
            printf '%s\n' "$tmp" > "$tmp_file" || { rm -f "$tmp_file"; exit 1; }
            mv "$tmp_file" "$LOCK_FILE" || { rm -f "$tmp_file"; exit 1; }
            printf '%s' "$tmp"
        ) 201>"$flock_lock"
    }) || return 1
    printf '%s' "$out"
}

# ─── Internal: write a per-pipeline heartbeat file ──────────────────────────
_lock_write_heartbeat() {
    local pid="$1"
    mkdir -p "$HEARTBEAT_DIR"
    local hb="${HEARTBEAT_DIR}/pipeline-${pid}.json"
    local tmp
    tmp=$(mktemp "${hb}.tmp.XXXXXX") || return 1
    printf '{"pid":%s,"heartbeat":"%s"}\n' "$pid" "$(now_iso)" > "$tmp"
    mv "$tmp" "$hb"
}

_lock_remove_heartbeat() {
    local pid="$1"
    rm -f "${HEARTBEAT_DIR}/pipeline-${pid}.json"
}

# ─── Public: check conflict without modifying state ─────────────────────────
# Usage: lock_check_conflict <file1> [file2 ...]
# Echoes JSON: {"conflict":false} or
#              {"conflict":true,"owner_pid":"123","owner_issue":42,"file":"x"}
# Exit code: 0 if no conflict, 1 if conflict.
lock_check_conflict() {
    _lock_init
    local files_json
    files_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    local result
    result=$(jq -c --argjson files "$files_json" '
        . as $root
        | [ $files[] as $f
            | ($root.pipelines
               | to_entries[]
               | select(.value.files | index($f))
               | {owner_pid:.key, owner_issue:.value.issue, file:$f}) ]
        | if length == 0 then {conflict:false}
          else (.[0] + {conflict:true}) end
    ' "$LOCK_FILE" 2>/dev/null) || result='{"conflict":false}'
    printf '%s' "$result"
    if [[ "$(echo "$result" | jq -r '.conflict')" == "true" ]]; then
        return 1
    fi
    return 0
}

# ─── Public: atomically acquire locks on files for a pipeline ───────────────
# Usage: lock_acquire_files <pid> <issue_num> <file1> [file2 ...]
# Returns 0 on success, 1 if any file is already locked by another pipeline.
# On conflict, echoes the conflict JSON (same format as lock_check_conflict).
lock_acquire_files() {
    local pid="$1"; shift
    local issue="$1"; shift
    [[ $# -eq 0 ]] && return 0  # no files to lock = trivially acquired

    # Sort + dedupe files alphabetically (deadlock prevention).
    local sorted_files
    sorted_files=$(printf '%s\n' "$@" | sort -u)
    local files_json
    files_json=$(printf '%s\n' "$sorted_files" | jq -R . | jq -s .)

    local now
    now=$(now_iso)

    # Atomic check-and-acquire in a single jq expression.
    # If any requested file is locked by a *different* pid, the expression
    # returns the unchanged state tagged with a conflict marker. Otherwise
    # it adds the pipeline entry and increments the counter.
    local result
    result=$(_lock_update '
        . as $root
        | ($files | map(
            . as $f
            | ($root.pipelines
               | to_entries[]?
               | select(.key != $pid)
               | select(.value.files | index($f))
               | {owner_pid:.key, owner_issue:.value.issue, file:$f})
          ) | flatten) as $conflicts
        | if ($conflicts | length) > 0 then
            . + {_conflict: $conflicts[0]}
          else
            .pipelines[$pid] = {
              issue: ($issue | tonumber),
              files: $files,
              acquired_at: $now,
              heartbeat: $now
            }
            | .metrics.locks_acquired = ((.metrics.locks_acquired // 0) + 1)
          end
    ' \
        --arg pid "$pid" \
        --argjson issue "$issue" \
        --argjson files "$files_json" \
        --arg now "$now") || return 1

    # Check if the update tagged a conflict (the conflict branch adds _conflict
    # but does NOT write the pipeline — we need to strip _conflict before it
    # persists). Detect + rollback:
    if echo "$result" | jq -e '._conflict' >/dev/null 2>&1; then
        # Strip _conflict field from persisted state, increment metric.
        _lock_update '. |= (del(._conflict)
                          | .metrics.conflicts_avoided = ((.metrics.conflicts_avoided // 0) + 1))' >/dev/null || true
        local conflict
        conflict=$(echo "$result" | jq -c '._conflict + {conflict:true}')
        emit_event "daemon.conflict_detected" \
            "pid=$pid" "issue=$issue" \
            "owner_pid=$(echo "$conflict" | jq -r '.owner_pid')" \
            "owner_issue=$(echo "$conflict" | jq -r '.owner_issue')" \
            "file=$(echo "$conflict" | jq -r '.file')"
        printf '%s' "$conflict"
        return 1
    fi

    _lock_write_heartbeat "$pid"
    emit_event "daemon.lock_acquired" \
        "pid=$pid" "issue=$issue" \
        "files_count=$(echo "$files_json" | jq 'length')"
    return 0
}

# ─── Public: release all locks held by a pipeline ───────────────────────────
# Usage: lock_release_files <pid>
# Idempotent: safe to call even if pid holds no locks.
lock_release_files() {
    local pid="$1"
    _lock_init
    local had_locks
    had_locks=$(jq -r --arg pid "$pid" 'if .pipelines[$pid] then "yes" else "no" end' "$LOCK_FILE" 2>/dev/null || echo "no")
    _lock_update '
        if .pipelines[$pid] then
          del(.pipelines[$pid])
          | .metrics.locks_released = ((.metrics.locks_released // 0) + 1)
        else . end
    ' --arg pid "$pid" >/dev/null || return 1
    _lock_remove_heartbeat "$pid"
    if [[ "$had_locks" == "yes" ]]; then
        emit_event "daemon.lock_released" "pid=$pid"
    fi
    return 0
}

# ─── Public: update heartbeat timestamp for a pipeline ──────────────────────
lock_touch_heartbeat() {
    local pid="$1"
    _lock_init
    local now
    now=$(now_iso)
    _lock_update '
        if .pipelines[$pid] then .pipelines[$pid].heartbeat = $now else . end
    ' --arg pid "$pid" --arg now "$now" >/dev/null || return 1
    _lock_write_heartbeat "$pid"
}

# ─── Public: list all currently held locks ──────────────────────────────────
# Echoes the pipelines object as JSON.
lock_list() {
    _lock_init
    jq -c '.pipelines' "$LOCK_FILE" 2>/dev/null || echo '{}'
}

# ─── Public: show metrics counters ──────────────────────────────────────────
lock_metrics() {
    _lock_init
    jq -c '.metrics' "$LOCK_FILE" 2>/dev/null || echo '{}'
}

# ─── Public: clean up stale locks from dead pipelines ───────────────────────
# A pipeline is considered stale if:
#   - its PID is no longer alive (kill -0 fails), AND
#   - its heartbeat is older than FILE_LOCK_STALE_SECONDS seconds.
# Returns number of pipelines cleaned (on stdout).
lock_cleanup_stale() {
    _lock_init
    local cleaned=0
    local stale_cutoff=$(( $(now_epoch) - FILE_LOCK_STALE_SECONDS ))
    local pids
    pids=$(jq -r '.pipelines | keys[]?' "$LOCK_FILE" 2>/dev/null)
    [[ -z "$pids" ]] && { echo 0; return 0; }
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        # PID alive check
        if kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        # Heartbeat age check
        local hb_iso hb_epoch
        hb_iso=$(jq -r --arg pid "$pid" '.pipelines[$pid].heartbeat // ""' "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$hb_iso" ]]; then
            # Convert ISO to epoch; GNU date and BSD date both accept -d here on typical linux.
            hb_epoch=$(date -u -d "$hb_iso" +%s 2>/dev/null || echo 0)
            if [[ "$hb_epoch" -ge "$stale_cutoff" ]]; then
                continue  # heartbeat recent — maybe a race, don't clean
            fi
        fi
        local issue
        issue=$(jq -r --arg pid "$pid" '.pipelines[$pid].issue // "?"' "$LOCK_FILE" 2>/dev/null)
        _lock_update '
            if .pipelines[$pid] then
              del(.pipelines[$pid])
              | .metrics.stale_cleaned = ((.metrics.stale_cleaned // 0) + 1)
            else . end
        ' --arg pid "$pid" >/dev/null || continue
        _lock_remove_heartbeat "$pid"
        emit_event "daemon.lock_stale_cleaned" "pid=$pid" "issue=$issue" "reason=dead_pid"
        daemon_log INFO "file-locks: cleaned stale locks for pid=$pid issue=$issue"
        cleaned=$((cleaned + 1))
    done <<< "$pids"
    echo "$cleaned"
}
