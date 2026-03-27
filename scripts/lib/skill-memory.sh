#!/usr/bin/env bash
# skill-memory.sh — Records pipeline outcomes per skill combination
# Stores data in ~/.shipwright/skill-memory.json
# Provides functions to query success rates and get recommendations
[[ -n "${_SKILL_MEMORY_LOADED:-}" ]] && return 0
_SKILL_MEMORY_LOADED=1

SKILL_MEMORY_FILE="${HOME}/.shipwright/skill-memory.json"
SKILL_MEMORY_MAX_RECORDS=200

# ─── Initialization ─────────────────────────────────────────────────────────

# _skill_memory_ensure_file — Create memory file if it doesn't exist or is empty
_skill_memory_ensure_file() {
    if [[ ! -f "$SKILL_MEMORY_FILE" ]] || [[ ! -s "$SKILL_MEMORY_FILE" ]]; then
        mkdir -p "$(dirname "$SKILL_MEMORY_FILE")"
        printf '{"records":[]}\n' > "$SKILL_MEMORY_FILE"
    fi
}

# ─── Core API ───────────────────────────────────────────────────────────────

# skill_memory_record — Record outcome for a skill+stage combination
#   $1: issue_type (frontend|backend|api|database|infrastructure|documentation|security|performance|refactor|testing)
#   $2: stage (plan|design|build|test|review|compound_quality|pr|deploy|validate|monitor)
#   $3: skills_used (comma-separated skill names, not paths)
#   $4: outcome (success|failure|retry)
#   $5: attempt_number (1, 2, 3...)
#   $6: verdict (optional — "effective"|"partially_effective"|"ineffective")
#   $7: evidence (optional — why this verdict)
#   $8: learning (optional — one-sentence takeaway)
# Returns: 0 on success, 1 on error
skill_memory_record() {
    local issue_type="${1:-backend}"
    local stage="${2:-plan}"
    local skills_used="${3:-}"
    local outcome="${4:-success}"
    local attempt="${5:-1}"
    local verdict="${6:-}"
    local evidence="${7:-}"
    local learning="${8:-}"

    [[ -z "$skills_used" ]] && return 1

    _skill_memory_ensure_file

    # Build JSON record
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local record
    record=$(jq -n \
        --arg it "$issue_type" --arg st "$stage" --arg sk "$skills_used" \
        --arg oc "$outcome" --argjson at "$attempt" --arg ts "$timestamp" \
        --arg vd "$verdict" --arg ev "$evidence" --arg lr "$learning" \
        '{issue_type:$it, stage:$st, skills:$sk, outcome:$oc, attempt:$at, timestamp:$ts, verdict:$vd, evidence:$ev, learning:$lr}')

    # Append to records array, handling potential jq unavailability
    if ! command -v jq &>/dev/null; then
        return 1
    fi

    # Use portable file locking (flock on Linux, simple wait on macOS)
    local lockfile="${SKILL_MEMORY_FILE}.lock"
    local lock_attempts=0
    local max_lock_attempts=50  # ~5 seconds with 100ms waits

    # Acquire lock
    while [[ -f "$lockfile" ]] && [[ $lock_attempts -lt $max_lock_attempts ]]; do
        lock_attempts=$((lock_attempts + 1))
        sleep 0.1
    done

    if [[ $lock_attempts -ge $max_lock_attempts ]]; then
        return 1  # Lock timeout
    fi

    # Create lock file
    echo "$$" > "$lockfile"

    # Read current records (don't use subshell to preserve variables)
    local current_records
    current_records=$(jq '.records' "$SKILL_MEMORY_FILE" 2>/dev/null || printf '[]')

    # Add new record and trim to max
    local updated
    updated=$(printf '%s' "$current_records" | jq \
        --argjson rec "$record" \
        --argjson max "$SKILL_MEMORY_MAX_RECORDS" \
        '(. + [$rec]) | sort_by(.timestamp) | .[-$max:]'
    )

    # Write back atomically
    printf '{"records":%s}\n' "$updated" > "$SKILL_MEMORY_FILE"

    # Release lock
    rm -f "$lockfile"

    return 0
}

# skill_memory_get_success_rate — Get success rate for a skill combo
#   $1: issue_type
#   $2: stage
#   $3: skill_name
# Returns: success rate as percentage (0-100), or empty if no data
skill_memory_get_success_rate() {
    local issue_type="${1:-backend}"
    local stage="${2:-plan}"
    local skill_name="${3:-}"

    [[ -z "$skill_name" ]] && return 1
    [[ ! -f "$SKILL_MEMORY_FILE" ]] && return 1

    if ! command -v jq &>/dev/null; then
        return 1
    fi

    local success_count fail_count
    success_count=$(jq --arg it "$issue_type" --arg st "$stage" --arg sk "$skill_name" '[.records[] | select(.issue_type == $it and .stage == $st and (.skills | split(",") | contains([$sk])))] | map(select(.outcome == "success")) | length' "$SKILL_MEMORY_FILE" 2>/dev/null || printf '0')

    fail_count=$(jq --arg it "$issue_type" --arg st "$stage" --arg sk "$skill_name" '[.records[] | select(.issue_type == $it and .stage == $st and (.skills | split(",") | contains([$sk])))] | map(select(.outcome != "success")) | length' "$SKILL_MEMORY_FILE" 2>/dev/null || printf '0')

    local total=$((success_count + fail_count))
    [[ "$total" -eq 0 ]] && return 1

    local rate=$((success_count * 100 / total))
    printf '%d' "$rate"
}

# skill_memory_get_recommendations — Get recommended skills based on history
#   $1: issue_type
#   $2: stage
# Returns: comma-separated skill names sorted by success rate (highest first)
skill_memory_get_recommendations() {
    local issue_type="${1:-backend}"
    local stage="${2:-plan}"

    [[ ! -f "$SKILL_MEMORY_FILE" ]] && return 0

    if ! command -v jq &>/dev/null; then
        return 0
    fi

    # Get all skills used in this (issue_type, stage) and their success rates
    local skills_json
    skills_json=$(jq --arg it "$issue_type" --arg st "$stage" '
        .records as $original_records |
        [.records[] | select(.issue_type == $it and .stage == $st)] |
        map(.skills | split(",") | .[]) |
        unique |
        map({
            name: .,
            total: [$original_records[] | select(.issue_type == $it and .stage == $st and (.skills | split(",") | contains([.])))] | length
        })
    ' "$SKILL_MEMORY_FILE" 2>/dev/null || printf '[]')

    # For each skill, calculate success rate and output
    local recommendations
    recommendations=$(printf '%s' "$skills_json" | jq -r '.[] | .name' 2>/dev/null | while read -r skill; do
        local rate
        rate=$(skill_memory_get_success_rate "$issue_type" "$stage" "$skill" 2>/dev/null || printf '0')
        printf '%d,%s\n' "$rate" "$skill"
    done | sort -rn | awk -F, '{print $2}' | tr '\n' ',' | sed 's/,$//')

    printf '%s' "$recommendations"
}

# skill_memory_stats — Get statistics for a skill/stage combo
#   $1: issue_type
#   $2: stage (optional)
#   $3: skill_name (optional)
# Returns: JSON with success_count, failure_count, retry_count, success_rate
skill_memory_stats() {
    local issue_type="${1:-backend}"
    local stage="${2:-}"
    local skill_name="${3:-}"

    [[ ! -f "$SKILL_MEMORY_FILE" ]] && return 1

    if ! command -v jq &>/dev/null; then
        return 1
    fi

    local filter='.issue_type == "'$issue_type'"'
    [[ -n "$stage" ]] && filter="$filter and .stage == \"$stage\""
    [[ -n "$skill_name" ]] && filter="$filter and (.skills | split(\",\") | contains([\"$skill_name\"]))"

    jq --arg it "$issue_type" --arg st "$stage" --arg sk "$skill_name" '
        [.records[] | select($it != "" and .issue_type == $it) | select(($st == "" or .stage == $st)) | select(($sk == "" or (.skills | split(",") | contains([$sk]))))] |
        {
            success_count: map(select(.outcome == "success")) | length,
            failure_count: map(select(.outcome == "failure")) | length,
            retry_count: map(select(.outcome == "retry")) | length,
            success_rate: (
                (map(select(.outcome == "success")) | length) as $success |
                if (. | length) == 0 then 0
                else ($success * 100 / (. | length) | floor)
                end
            ),
            total_records: (. | length)
        }
    ' "$SKILL_MEMORY_FILE" 2>/dev/null || printf '{"error":"unable to compute stats"}'
}

# skill_memory_clear — Clear all memory (useful for testing)
skill_memory_clear() {
    if [[ -f "$SKILL_MEMORY_FILE" ]]; then
        rm -f "$SKILL_MEMORY_FILE" "${SKILL_MEMORY_FILE}.lock"
    fi
    _skill_memory_ensure_file
}

# skill_memory_export — Export records as JSON (useful for analysis)
skill_memory_export() {
    [[ ! -f "$SKILL_MEMORY_FILE" ]] && printf '{"records":[]}\n' && return 0
    cat "$SKILL_MEMORY_FILE"
}

# skill_memory_import — Import records from JSON file
#   $1: path to JSON file with {"records": [...]} structure
skill_memory_import() {
    local import_file="${1:-}"
    [[ -z "$import_file" || ! -f "$import_file" ]] && return 1

    if ! command -v jq &>/dev/null; then
        return 1
    fi

    local lockfile="${SKILL_MEMORY_FILE}.lock"
    local lock_attempts=0
    local max_lock_attempts=50

    while [[ -f "$lockfile" ]] && [[ $lock_attempts -lt $max_lock_attempts ]]; do
        lock_attempts=$((lock_attempts + 1))
        sleep 0.1
    done

    if [[ $lock_attempts -ge $max_lock_attempts ]]; then
        return 1
    fi

    echo "$$" > "$lockfile"

    # Merge records, dedup by timestamp, keep newest
    local merged
    merged=$(jq -s \
        --argjson max "$SKILL_MEMORY_MAX_RECORDS" \
        '[.[0].records, .[1].records] | flatten |
         unique_by(.timestamp + .issue_type + .stage + .skills) |
         sort_by(.timestamp) |
         .[-$max:]' \
        "$SKILL_MEMORY_FILE" "$import_file")

    printf '{"records":%s}\n' "$merged" > "$SKILL_MEMORY_FILE"

    rm -f "$lockfile"

    return 0
}

# skill_memory_prune — Keep only N most recent records
#   $1: max_records (default 200)
skill_memory_prune() {
    local max_records="${1:-200}"
    [[ ! -f "$SKILL_MEMORY_FILE" ]] && return 0

    if ! command -v jq &>/dev/null; then
        return 1
    fi

    local lockfile="${SKILL_MEMORY_FILE}.lock"
    local lock_attempts=0
    local max_lock_attempts=50

    while [[ -f "$lockfile" ]] && [[ $lock_attempts -lt $max_lock_attempts ]]; do
        lock_attempts=$((lock_attempts + 1))
        sleep 0.1
    done

    if [[ $lock_attempts -ge $max_lock_attempts ]]; then
        return 1
    fi

    echo "$$" > "$lockfile"

    local pruned
    pruned=$(jq --argjson max "$max_records" \
        '.records |= sort_by(.timestamp) | .records |= .[-$max:]' \
        "$SKILL_MEMORY_FILE")

    printf '%s\n' "$pruned" > "$SKILL_MEMORY_FILE"

    rm -f "$lockfile"

    return 0
}

# Initialize on load
_skill_memory_ensure_file
