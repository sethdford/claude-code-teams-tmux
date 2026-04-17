#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Fleet-Wide Cross-Repo Learning Synchronization Engine                    ║
# ║  Broadcast · Dedup · Vote · Prune · Dashboard                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Shared memory layout: ~/.shipwright/fleet-memory/
#   patterns/<sig>.json     — one file per unique pattern, atomic write
#   archive/<sig>.json      — patterns older than 30d with no successes
#   index.json              — cached top-N for dashboard
#
# Each pattern file:
#   { sig, type, content, votes, repos: [..], successes, first_seen, last_seen, last_success }

[[ -n "${_FLEET_MEMORY_LOADED:-}" ]] && return 0
_FLEET_MEMORY_LOADED=1
set -euo pipefail

FLEET_MEMORY_ROOT="${FLEET_MEMORY_ROOT:-${HOME}/.shipwright/fleet-memory}"
FLEET_MEMORY_PATTERNS_DIR="${FLEET_MEMORY_ROOT}/patterns"
FLEET_MEMORY_ARCHIVE_DIR="${FLEET_MEMORY_ROOT}/archive"
FLEET_MEMORY_INDEX="${FLEET_MEMORY_ROOT}/index.json"
FLEET_MEMORY_TTL_DAYS="${FLEET_MEMORY_TTL_DAYS:-30}"

# Fallback helpers when sourced standalone.
[[ "$(type -t now_iso 2>/dev/null)" == "function" ]] || now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
[[ "$(type -t now_epoch 2>/dev/null)" == "function" ]] || now_epoch() { date +%s; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { :; }
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo "▸ $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo "✓ $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo "⚠ $*"; }

# ─── Mode detection ─────────────────────────────────────────────────────────

fleet_memory_enabled() {
    [[ "${SHIPWRIGHT_FLEET_MODE:-}" == "1" ]] && return 0
    [[ "${SHIPWRIGHT_FLEET_MEMORY:-}" == "1" ]] && return 0
    [[ -f ".claude/fleet-config.json" ]] && return 0
    [[ -f "${HOME}/.shipwright/fleet-config.json" ]] && return 0
    return 1
}

fleet_memory_ensure_dirs() {
    mkdir -p "$FLEET_MEMORY_PATTERNS_DIR" "$FLEET_MEMORY_ARCHIVE_DIR"
}

# ─── Signature (content hash for dedup) ─────────────────────────────────────

fleet_memory_sig() {
    local type="$1" content="$2"
    local normalized
    # Normalize: lowercase, collapse whitespace. Keeps "Foo Bar" and "foo  bar" dedup'd.
    normalized=$(echo "${type}|${content}" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
    echo -n "$normalized" | shasum -a 256 | cut -c1-16
}

_scrub_content() {
    # Strip anything that looks like a secret/token/email before broadcast.
    local text="$1"
    text=$(echo "$text" | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<email>/g')
    text=$(echo "$text" | sed -E 's/(sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{12,})/<secret>/g')
    text=$(echo "$text" | sed -E 's/(password|token|secret|api[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1=<redacted>/gi')
    echo "$text"
}

# ─── Broadcast (capture → fleet) ────────────────────────────────────────────
# fleet_memory_broadcast <type> <content> [repo]
fleet_memory_broadcast() {
    local type="${1:-}" content="${2:-}" repo="${3:-${REPO_NAME:-$(basename "$PWD")}}"

    [[ -z "$type" || -z "$content" ]] && return 1
    fleet_memory_enabled || return 0

    fleet_memory_ensure_dirs

    content=$(_scrub_content "$content")

    local sig ts file tmp
    sig=$(fleet_memory_sig "$type" "$content")
    ts=$(now_iso)
    file="${FLEET_MEMORY_PATTERNS_DIR}/${sig}.json"
    tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    # Retry loop for concurrent writers.
    local attempts=0
    while [[ $attempts -lt 5 ]]; do
        if [[ -f "$file" ]]; then
            # Merge: add repo if new, increment votes.
            jq --arg repo "$repo" --arg ts "$ts" '
                . as $in
                | .repos = ((.repos // []) + [$repo] | unique)
                | .votes = (.repos | length)
                | .last_seen = $ts
            ' "$file" > "$tmp" 2>/dev/null || {
                attempts=$((attempts + 1))
                sleep 0.1
                continue
            }
        else
            jq -n --arg sig "$sig" --arg type "$type" --arg content "$content" \
                  --arg repo "$repo" --arg ts "$ts" '{
                sig: $sig,
                type: $type,
                content: $content,
                repos: [$repo],
                votes: 1,
                successes: 0,
                first_seen: $ts,
                last_seen: $ts,
                last_success: null
            }' > "$tmp" 2>/dev/null || {
                attempts=$((attempts + 1))
                sleep 0.1
                continue
            }
        fi
        if mv "$tmp" "$file" 2>/dev/null; then
            emit_event "fleet_memory.broadcast" "sig=$sig" "type=$type" "repo=$repo"
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.1
    done

    warn "fleet_memory_broadcast: failed after 5 attempts for sig=$sig"
    return 1
}

# ─── Load (inject fleet patterns into pipeline prompt) ──────────────────────
# Emits up to <n> most-voted patterns matching optional <query keywords>.
# Prints markdown lines, never JSON, so it appends cleanly to prompts.
fleet_memory_inject() {
    local query="${1:-}" max="${2:-5}"
    [[ ! -d "$FLEET_MEMORY_PATTERNS_DIR" ]] && return 0

    local file patterns score
    patterns=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$patterns'" RETURN

    for file in "$FLEET_MEMORY_PATTERNS_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        local entry
        entry=$(cat "$file" 2>/dev/null) || continue
        # Rank: votes + successes. Filter by query keyword if given.
        if [[ -n "$query" ]]; then
            local content_lower query_lower
            content_lower=$(echo "$entry" | jq -r '.content // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')
            query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')
            local kw matched=0
            for kw in $query_lower; do
                [[ ${#kw} -lt 3 ]] && continue
                if echo "$content_lower" | grep -qF "$kw"; then
                    matched=1
                    break
                fi
            done
            [[ $matched -eq 0 ]] && continue
        fi
        score=$(echo "$entry" | jq -r '((.votes // 1) * 10) + (.successes // 0)' 2>/dev/null)
        echo "${score}|${entry}" >> "$patterns"
    done

    [[ ! -s "$patterns" ]] && return 0

    echo ""
    echo "## Fleet-Wide Patterns (cross-repo learnings)"
    sort -t'|' -k1 -rn "$patterns" | head -n "$max" | while IFS='|' read -r _ entry; do
        local type content votes repos_csv
        type=$(echo "$entry" | jq -r '.type // "pattern"')
        content=$(echo "$entry" | jq -r '.content // ""' | head -c 280)
        votes=$(echo "$entry" | jq -r '.votes // 1')
        repos_csv=$(echo "$entry" | jq -r '(.repos // []) | join(",")')
        echo "- [fleet ${type} · votes=${votes} · repos=${repos_csv}] ${content}"
    done
}

# ─── Record success (effectiveness feedback) ────────────────────────────────
fleet_memory_record_success() {
    local sig="${1:-}"
    [[ -z "$sig" ]] && return 1
    local file="${FLEET_MEMORY_PATTERNS_DIR}/${sig}.json"
    [[ -f "$file" ]] || return 0

    local tmp ts
    tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    ts=$(now_iso)

    jq --arg ts "$ts" '
        .successes = ((.successes // 0) + 1) |
        .last_success = $ts
    ' "$file" > "$tmp" 2>/dev/null && mv "$tmp" "$file" && {
        emit_event "fleet_memory.success" "sig=$sig"
        return 0
    }
    return 1
}

# ─── Prune (archive stale patterns) ─────────────────────────────────────────
# Moves patterns with no successes whose last_seen is older than TTL days.
fleet_memory_prune() {
    fleet_memory_ensure_dirs
    local now_epoch_val cutoff archived=0 file last_seen_epoch successes
    now_epoch_val=$(now_epoch)
    cutoff=$((now_epoch_val - FLEET_MEMORY_TTL_DAYS * 86400))

    for file in "$FLEET_MEMORY_PATTERNS_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        local last_seen
        last_seen=$(jq -r '.last_seen // ""' "$file" 2>/dev/null)
        successes=$(jq -r '.successes // 0' "$file" 2>/dev/null)
        [[ "$successes" -gt 0 ]] && continue
        [[ -z "$last_seen" ]] && continue
        # Parse ISO8601 to epoch (portable-ish).
        last_seen_epoch=$(date -u -d "$last_seen" +%s 2>/dev/null || \
                         date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_seen" +%s 2>/dev/null || echo 0)
        if [[ "$last_seen_epoch" -gt 0 && "$last_seen_epoch" -lt "$cutoff" ]]; then
            mv "$file" "$FLEET_MEMORY_ARCHIVE_DIR/" 2>/dev/null && archived=$((archived + 1))
        fi
    done

    emit_event "fleet_memory.prune" "archived=$archived" "ttl_days=$FLEET_MEMORY_TTL_DAYS"
    echo "$archived"
}

# ─── Stats & Dashboard ──────────────────────────────────────────────────────
fleet_memory_stats_json() {
    fleet_memory_ensure_dirs
    local total=0 multi_repo=0 with_successes=0 total_votes=0 file votes successes
    for file in "$FLEET_MEMORY_PATTERNS_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        total=$((total + 1))
        votes=$(jq -r '.votes // 1' "$file" 2>/dev/null)
        successes=$(jq -r '.successes // 0' "$file" 2>/dev/null)
        total_votes=$((total_votes + votes))
        [[ "$votes" -gt 1 ]] && multi_repo=$((multi_repo + 1))
        [[ "$successes" -gt 0 ]] && with_successes=$((with_successes + 1))
    done

    local reuse_rate=0 adoption_rate=0
    if [[ "$total" -gt 0 ]]; then
        reuse_rate=$((multi_repo * 100 / total))
        adoption_rate=$((with_successes * 100 / total))
    fi

    jq -n --argjson total "$total" \
          --argjson multi "$multi_repo" \
          --argjson succ "$with_successes" \
          --argjson votes "$total_votes" \
          --argjson reuse "$reuse_rate" \
          --argjson adopt "$adoption_rate" '{
        total_patterns: $total,
        multi_repo_patterns: $multi,
        patterns_with_successes: $succ,
        total_votes: $votes,
        cross_repo_reuse_rate_pct: $reuse,
        adoption_rate_pct: $adopt
    }'
}

fleet_memory_dashboard() {
    fleet_memory_ensure_dirs

    local stats
    stats=$(fleet_memory_stats_json)

    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║  Fleet Memory Dashboard                                            ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Totals"
    echo "$stats" | jq -r '
        "  Patterns:            \(.total_patterns)",
        "  Multi-repo:          \(.multi_repo_patterns)",
        "  With successes:      \(.patterns_with_successes)",
        "  Total votes:         \(.total_votes)",
        "  Cross-repo reuse:    \(.cross_repo_reuse_rate_pct)%",
        "  Adoption rate:       \(.adoption_rate_pct)%"'
    echo ""
    echo "Top 10 patterns (by votes × successes)"
    local tmp
    tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    local file
    for file in "$FLEET_MEMORY_PATTERNS_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        local score entry
        entry=$(cat "$file") || continue
        score=$(echo "$entry" | jq -r '((.votes // 1) * 10) + (.successes // 0) * 5')
        echo "${score}|${entry}" >> "$tmp"
    done

    if [[ -s "$tmp" ]]; then
        sort -t'|' -k1 -rn "$tmp" | head -10 | while IFS='|' read -r _ entry; do
            echo "$entry" | jq -r '"  · [\(.type)] v=\(.votes) s=\(.successes // 0) — \(.content | .[0:80])"'
        done
    else
        echo "  (no patterns yet)"
    fi
    echo ""
}

# ─── Sync (rebuild index for external consumers, e.g. dashboard) ────────────
fleet_memory_sync() {
    fleet_memory_ensure_dirs
    local tmp
    tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    echo "[]" > "$tmp"
    local file
    for file in "$FLEET_MEMORY_PATTERNS_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        jq --slurpfile e "$file" '. + $e' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
    done

    mv "$tmp" "$FLEET_MEMORY_INDEX"
    emit_event "fleet_memory.sync" "index=$FLEET_MEMORY_INDEX"
}
