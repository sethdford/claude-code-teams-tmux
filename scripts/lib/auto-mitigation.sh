#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  auto-mitigation.sh — Failure Pattern Auto-Mitigation Engine             ║
# ║                                                                           ║
# ║  Scores, ranks, and formats failure pattern fixes for injection into     ║
# ║  build loop iterations. Tracks outcomes for effectiveness feedback.       ║
# ║                                                                           ║
# ║  Usage: Source from sw-loop.sh or loop-iteration.sh                      ║
# ║    source scripts/lib/auto-mitigation.sh                                 ║
# ║    matches=$(mitigation_query_fixes "$error_text" "build" 3)             ║
# ║    formatted=$(mitigation_format "$matches" "prompt")                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

[[ -n "${_AUTO_MITIGATION_LOADED:-}" ]] && return 0
_AUTO_MITIGATION_LOADED=1

# ─── Defaults ────────────────────────────────────────────────────────────────
MITIGATION_MAX_CHARS="${MITIGATION_MAX_CHARS:-4000}"
MITIGATION_MIN_MATCH_LEN="${MITIGATION_MIN_MATCH_LEN:-10}"
MITIGATION_PROACTIVE_MIN_SEEN="${MITIGATION_PROACTIVE_MIN_SEEN:-3}"
MITIGATION_PROACTIVE_MIN_RATE="${MITIGATION_PROACTIVE_MIN_RATE:-70}"
MITIGATION_STALE_DAYS="${MITIGATION_STALE_DAYS:-30}"
MITIGATION_STALE_MIN_SEEN="${MITIGATION_STALE_MIN_SEEN:-5}"
MITIGATION_STALE_MAX_RATE="${MITIGATION_STALE_MAX_RATE:-20}"

# Resolve SCRIPT_DIR relative to this file's location (parent of lib/)
AUTO_MITIGATION_SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ─── Fallback helpers (when sourced standalone in tests) ─────────────────────
if [[ "$(type -t info 2>/dev/null)" != "function" ]]; then
    info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
    success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
    warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
    error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
fi
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
    now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
    now_epoch() { date +%s; }
fi
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
    emit_event() { :; }
fi

# ─── Internal: resolve failures file ─────────────────────────────────────────
_mitigation_failures_file() {
    local mem_dir=""
    if type repo_memory_dir >/dev/null 2>&1; then
        mem_dir="$(repo_memory_dir 2>/dev/null || true)"
    fi
    if [[ -z "$mem_dir" ]]; then
        local repo_hash
        repo_hash=$(echo -n "$(git config remote.origin.url 2>/dev/null || echo "local")" \
            | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
        mem_dir="${HOME}/.shipwright/memory/${repo_hash}"
    fi
    echo "$mem_dir/failures.json"
}

# ─── Internal: compute text similarity (0-100) ──────────────────────────────
# Uses substring matching: proportion of pattern chars found in error text.
# Bash 3.2 compatible (no associative arrays).
_mitigation_text_similarity() {
    local error_text="$1"
    local pattern="$2"

    [[ -z "$error_text" || -z "$pattern" ]] && echo "0" && return

    local pattern_len=${#pattern}
    local error_len=${#error_text}

    # Trivial: pattern shorter than minimum
    [[ "$pattern_len" -lt "$MITIGATION_MIN_MATCH_LEN" ]] && echo "0" && return

    # Case-insensitive substring check via jq (Bash 3.2 safe)
    local contains
    contains=$(jq -n --arg err "$error_text" --arg pat "$pattern" \
        '($err | ascii_downcase) | contains($pat | ascii_downcase) | if . then 100 else 0 end' \
        2>/dev/null || echo "0")

    if [[ "$contains" == "100" ]]; then
        echo "100"
        return
    fi

    # Partial match: check first line of pattern against error text
    local first_line
    first_line=$(echo "$pattern" | head -1 | cut -c1-100)
    [[ ${#first_line} -lt "$MITIGATION_MIN_MATCH_LEN" ]] && echo "0" && return

    local partial
    partial=$(jq -n --arg err "$error_text" --arg pat "$first_line" \
        '($err | ascii_downcase) | contains($pat | ascii_downcase) | if . then 60 else 0 end' \
        2>/dev/null || echo "0")

    echo "$partial"
}

# ─── Internal: compute recency score (0-100) ────────────────────────────────
_mitigation_recency_score() {
    local last_seen="$1"
    [[ -z "$last_seen" || "$last_seen" == "null" ]] && echo "0" && return

    local now_s last_s age_days
    now_s=$(date +%s 2>/dev/null)
    # Parse ISO date to epoch (portable)
    last_s=$(date -d "$last_seen" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_seen" +%s 2>/dev/null || echo "0")
    [[ "$last_s" == "0" ]] && echo "0" && return

    age_days=$(( (now_s - last_s) / 86400 ))
    # Linear decay: 100 at 0 days, 0 at 90 days
    if [[ "$age_days" -ge 90 ]]; then
        echo "0"
    elif [[ "$age_days" -le 0 ]]; then
        echo "100"
    else
        echo $(( 100 - (age_days * 100 / 90) ))
    fi
}

# ─── Internal: compute frequency score (0-100) ──────────────────────────────
_mitigation_frequency_score() {
    local seen_count="${1:-0}"
    # Logarithmic: 1→20, 3→50, 5→70, 10→85, 20→100
    if [[ "$seen_count" -le 0 ]]; then
        echo "0"
    elif [[ "$seen_count" -ge 20 ]]; then
        echo "100"
    else
        echo $(( seen_count * 100 / 20 ))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═══════════════════════════════════════════════════════════════════════════════

# mitigation_query_fixes <error_text> [stage] [limit]
# Returns JSON array of matching fixes, scored and ranked.
# Each element: {fix, score, effectiveness, seen_count, category, pattern, files_hint}
mitigation_query_fixes() {
    local error_text="${1:-}"
    local stage="${2:-}"
    local limit="${3:-3}"

    # Fail-open: return empty array on any error
    [[ -z "$error_text" ]] && echo "[]" && return 0

    local failures_file
    failures_file="$(_mitigation_failures_file)"
    [[ ! -f "$failures_file" ]] && echo "[]" && return 0

    # Extract candidates: failures with non-empty fixes, optional stage filter
    local candidates
    if [[ -n "$stage" ]]; then
        candidates=$(jq --arg stage "$stage" '[.failures[] | select(.fix != null and .fix != "" and (.stage == $stage or .stage == null))]' \
            "$failures_file" 2>/dev/null || echo "[]")
    else
        candidates=$(jq '[.failures[] | select(.fix != null and .fix != "")]' \
            "$failures_file" 2>/dev/null || echo "[]")
    fi

    local count
    count=$(echo "$candidates" | jq 'length' 2>/dev/null || echo "0")
    [[ "$count" == "0" ]] && echo "[]" && return 0

    # Score each candidate
    local results="[]"
    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local entry
        entry=$(echo "$candidates" | jq ".[$i]" 2>/dev/null)

        local pattern fix effectiveness seen_count category last_seen files_hint
        pattern=$(echo "$entry" | jq -r '.pattern // ""' 2>/dev/null)
        fix=$(echo "$entry" | jq -r '.fix // ""' 2>/dev/null)
        effectiveness=$(echo "$entry" | jq -r '.fix_effectiveness_rate // 0' 2>/dev/null)
        seen_count=$(echo "$entry" | jq -r '.seen_count // 1' 2>/dev/null)
        category=$(echo "$entry" | jq -r '.category // "unknown"' 2>/dev/null)
        last_seen=$(echo "$entry" | jq -r '.last_seen // ""' 2>/dev/null)
        files_hint=$(echo "$entry" | jq -r '.files // ""' 2>/dev/null)

        # Compute composite score
        local text_sim recency freq
        text_sim=$(_mitigation_text_similarity "$error_text" "$pattern")
        recency=$(_mitigation_recency_score "$last_seen")
        freq=$(_mitigation_frequency_score "$seen_count")

        # Skip if no text similarity at all
        if [[ "$text_sim" -gt 0 ]]; then
            # Composite: text_similarity*0.4 + effectiveness*0.3 + recency*0.2 + frequency*0.1
            local score
            score=$(( (text_sim * 4 + effectiveness * 3 + recency * 2 + freq * 1) / 10 ))

            results=$(echo "$results" | jq --argjson score "$score" \
                --arg fix "$fix" \
                --argjson eff "$effectiveness" \
                --argjson seen "$seen_count" \
                --arg cat "$category" \
                --arg pat "$pattern" \
                --arg files "$files_hint" \
                '. + [{fix: $fix, score: $score, effectiveness: $eff, seen_count: $seen, category: $cat, pattern: $pat, files_hint: $files}]' \
                2>/dev/null || echo "$results")
        fi

        i=$(( i + 1 ))
    done

    # Sort by score descending and limit
    echo "$results" | jq --argjson lim "$limit" \
        'sort_by(-.score) | .[:$lim]' 2>/dev/null || echo "[]"
}

# mitigation_proactive_inject <stage> [goal_text]
# Returns formatted markdown for high-confidence patterns (seen>=3, rate>=70%)
# that should be proactively injected BEFORE any error occurs.
mitigation_proactive_inject() {
    local stage="${1:-build}"
    local goal_text="${2:-}"

    local failures_file
    failures_file="$(_mitigation_failures_file)"
    [[ ! -f "$failures_file" ]] && return 0

    local min_seen="$MITIGATION_PROACTIVE_MIN_SEEN"
    local min_rate="$MITIGATION_PROACTIVE_MIN_RATE"

    # Query high-confidence patterns for this stage
    local patterns
    patterns=$(jq --arg stage "$stage" \
        --argjson min_seen "$min_seen" \
        --argjson min_rate "$min_rate" \
        '[.failures[]
         | select(.fix != null and .fix != "")
         | select(.stage == $stage or .stage == null)
         | select((.seen_count // 0) >= $min_seen)
         | select((.fix_effectiveness_rate // 0) >= $min_rate)]
         | sort_by(-.fix_effectiveness_rate)
         | .[:3]' \
        "$failures_file" 2>/dev/null || echo "[]")

    local count
    count=$(echo "$patterns" | jq 'length' 2>/dev/null || echo "0")
    [[ "$count" == "0" ]] && return 0

    local output="## Proactive Mitigations (from past failures)
The following fixes have been proven effective in similar contexts:"

    local i=0
    local char_count=${#output}
    while [[ "$i" -lt "$count" ]] && [[ "$char_count" -lt "$MITIGATION_MAX_CHARS" ]]; do
        local fix rate category pattern
        fix=$(echo "$patterns" | jq -r ".[$i].fix // \"\"" 2>/dev/null)
        rate=$(echo "$patterns" | jq -r ".[$i].fix_effectiveness_rate // 0" 2>/dev/null)
        category=$(echo "$patterns" | jq -r ".[$i].category // \"unknown\"" 2>/dev/null)
        pattern=$(echo "$patterns" | jq -r ".[$i].pattern // \"\"" 2>/dev/null | head -1 | cut -c1-80)

        local block="
- **[${category}] ${rate}% effective**: ${fix}
  Pattern: \`${pattern}\`"

        char_count=$(( char_count + ${#block} ))
        if [[ "$char_count" -lt "$MITIGATION_MAX_CHARS" ]]; then
            output="${output}${block}"
        fi
        i=$(( i + 1 ))
    done

    echo "$output"
}

# mitigation_format <matches_json> [mode]
# Formats matched fixes for injection into prompts or display.
# mode: "prompt" (default) — structured for LLM context
#        "display" — human-readable summary
mitigation_format() {
    local matches_json="${1:-[]}"
    local mode="${2:-prompt}"

    local count
    count=$(echo "$matches_json" | jq 'length' 2>/dev/null || echo "0")
    [[ "$count" == "0" ]] && return 0

    local output=""
    local char_count=0

    if [[ "$mode" == "prompt" ]]; then
        output="## Known Fixes (from past failures — ranked by confidence)
Apply these proven fixes if they match your current errors:"
        char_count=${#output}

        local i=0
        while [[ "$i" -lt "$count" ]] && [[ "$char_count" -lt "$MITIGATION_MAX_CHARS" ]]; do
            local fix score eff category pattern files_hint
            fix=$(echo "$matches_json" | jq -r ".[$i].fix // \"\"" 2>/dev/null)
            score=$(echo "$matches_json" | jq -r ".[$i].score // 0" 2>/dev/null)
            eff=$(echo "$matches_json" | jq -r ".[$i].effectiveness // 0" 2>/dev/null)
            category=$(echo "$matches_json" | jq -r ".[$i].category // \"unknown\"" 2>/dev/null)
            pattern=$(echo "$matches_json" | jq -r ".[$i].pattern // \"\"" 2>/dev/null | head -1 | cut -c1-100)
            files_hint=$(echo "$matches_json" | jq -r ".[$i].files_hint // \"\"" 2>/dev/null)

            local rank=$(( i + 1 ))
            local block="

### Fix #${rank} [${category}, ${eff}% effective, score: ${score}]
**Error pattern**: \`${pattern}\`
**Fix**: ${fix}"
            if [[ -n "$files_hint" && "$files_hint" != "null" && "$files_hint" != "" ]]; then
                block="${block}
**Files**: ${files_hint}"
            fi

            char_count=$(( char_count + ${#block} ))
            if [[ "$char_count" -lt "$MITIGATION_MAX_CHARS" ]]; then
                output="${output}${block}"
            fi
            i=$(( i + 1 ))
        done
    else
        # Display mode — compact summary
        local i=0
        while [[ "$i" -lt "$count" ]]; do
            local fix eff category
            fix=$(echo "$matches_json" | jq -r ".[$i].fix // \"\"" 2>/dev/null | cut -c1-80)
            eff=$(echo "$matches_json" | jq -r ".[$i].effectiveness // 0" 2>/dev/null)
            category=$(echo "$matches_json" | jq -r ".[$i].category // \"unknown\"" 2>/dev/null)
            output="${output}[${category}, ${eff}%] ${fix}
"
            i=$(( i + 1 ))
        done
    fi

    [[ -n "$output" ]] && echo "$output"
}

# mitigation_track_outcome <pattern> <applied:bool> <resolved:bool> [pipeline_id]
# Dual-writes outcome to failures.json and memory-effectiveness.jsonl.
mitigation_track_outcome() {
    local pattern="${1:-}"
    local applied="${2:-false}"
    local resolved="${3:-false}"
    local pipeline_id="${4:-unknown}"

    [[ -z "$pattern" ]] && return 1

    # Write to failures.json via existing memory system
    if type memory_record_fix_outcome >/dev/null 2>&1; then
        memory_record_fix_outcome "$pattern" "$applied" "$resolved" 2>/dev/null || true
    fi

    # Dual-write to memory-effectiveness.jsonl
    if type memeff_track_outcome >/dev/null 2>&1; then
        local outcome="none"
        [[ "$resolved" == "true" ]] && outcome="success"
        [[ "$applied" == "true" && "$resolved" != "true" ]] && outcome="failure"
        memeff_track_outcome "mitigation:${pattern:0:60}" "$pipeline_id" "$outcome" "" 2>/dev/null || true
    fi

    emit_event "mitigation.outcome" \
        "pattern=${pattern:0:60}" \
        "applied=${applied}" \
        "resolved=${resolved}" \
        "pipeline=${pipeline_id}"

    return 0
}

# mitigation_stats
# Returns JSON with aggregated mitigation statistics.
mitigation_stats() {
    local failures_file
    failures_file="$(_mitigation_failures_file)"

    if [[ ! -f "$failures_file" ]]; then
        echo '{"total_injections":0,"total_resolved":0,"resolution_rate":0,"top_patterns":[],"stale_count":0}'
        return 0
    fi

    jq '{
        total_injections: ([.failures[] | .times_fix_suggested // 0] | add // 0),
        total_resolved: ([.failures[] | .times_fix_resolved // 0] | add // 0),
        resolution_rate: (
            if ([.failures[] | .times_fix_applied // 0] | add // 0) > 0 then
                (([.failures[] | .times_fix_resolved // 0] | add // 0) * 100 /
                 ([.failures[] | .times_fix_applied // 0] | add // 0))
            else 0 end
        ),
        top_patterns: [
            .failures[]
            | select(.fix != null and .fix != "")
            | select((.times_fix_suggested // 0) > 0)
            | {
                pattern: (.pattern // "" | .[:80]),
                fix: (.fix // "" | .[:120]),
                effectiveness: (.fix_effectiveness_rate // 0),
                seen_count: (.seen_count // 0),
                category: (.category // "unknown")
            }
        ] | sort_by(-.effectiveness) | .[:10],
        stale_count: [
            .failures[]
            | select((.fix_effectiveness_rate // 0) < 20)
            | select((.seen_count // 0) >= 5)
        ] | length
    }' "$failures_file" 2>/dev/null || echo '{"total_injections":0,"total_resolved":0,"resolution_rate":0,"top_patterns":[],"stale_count":0}'
}

# mitigation_prune_stale
# Archives patterns with low effectiveness to failures-archived.json.
# Returns the number of pruned patterns.
mitigation_prune_stale() {
    local failures_file
    failures_file="$(_mitigation_failures_file)"
    [[ ! -f "$failures_file" ]] && echo "0" && return 0

    local archive_file="${failures_file%.json}-archived.json"
    local max_rate="$MITIGATION_STALE_MAX_RATE"
    local min_seen="$MITIGATION_STALE_MIN_SEEN"
    local stale_days="$MITIGATION_STALE_DAYS"

    local now_s
    now_s=$(date +%s 2>/dev/null)
    local cutoff_ts
    cutoff_ts=$(date -u -d "@$(( now_s - stale_days * 86400 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -r "$(( now_s - stale_days * 86400 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || echo "1970-01-01T00:00:00Z")

    # Identify stale patterns
    local stale_count
    stale_count=$(jq --argjson max_rate "$max_rate" --argjson min_seen "$min_seen" --arg cutoff "$cutoff_ts" \
        '[.failures[]
         | select((.fix_effectiveness_rate // 0) < $max_rate)
         | select((.seen_count // 0) >= $min_seen)
         | select((.last_seen // "9999") < $cutoff)
        ] | length' "$failures_file" 2>/dev/null || echo "0")

    [[ "$stale_count" == "0" ]] && echo "0" && return 0

    # Archive stale patterns (atomic write)
    (
        if command -v flock >/dev/null 2>&1; then
            flock -w 10 200 2>/dev/null || { warn "Mitigation archive lock timeout"; echo "0"; return 0; }
        fi

        # Initialize archive if needed
        [[ ! -f "$archive_file" ]] && echo '{"archived":[]}' > "$archive_file"

        local tmp_archive tmp_failures
        tmp_archive=$(mktemp "${archive_file}.tmp.XXXXXX")
        tmp_failures=$(mktemp "${failures_file}.tmp.XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$tmp_archive' '$tmp_failures'" EXIT

        # Extract stale and keep patterns
        local stale_patterns
        stale_patterns=$(jq --argjson max_rate "$max_rate" --argjson min_seen "$min_seen" --arg cutoff "$cutoff_ts" \
            '[.failures[]
             | select((.fix_effectiveness_rate // 0) < $max_rate)
             | select((.seen_count // 0) >= $min_seen)
             | select((.last_seen // "9999") < $cutoff)]' "$failures_file" 2>/dev/null)

        # Append to archive
        jq --argjson stale "$stale_patterns" \
            '.archived = (.archived + $stale)' "$archive_file" > "$tmp_archive" \
            && mv "$tmp_archive" "$archive_file" || rm -f "$tmp_archive"

        # Remove stale from failures
        jq --argjson max_rate "$max_rate" --argjson min_seen "$min_seen" --arg cutoff "$cutoff_ts" \
            '.failures = [.failures[]
             | select(
                 ((.fix_effectiveness_rate // 0) >= $max_rate) or
                 ((.seen_count // 0) < $min_seen) or
                 ((.last_seen // "9999") >= $cutoff)
             )]' "$failures_file" > "$tmp_failures" \
            && mv "$tmp_failures" "$failures_file" || rm -f "$tmp_failures"

    ) 200>"${failures_file}.lock" 2>/dev/null

    emit_event "mitigation.prune" "count=${stale_count}"
    echo "$stale_count"
}
