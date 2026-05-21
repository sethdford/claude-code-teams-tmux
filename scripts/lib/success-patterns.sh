#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Success Pattern Injection Engine — Match & inject historical successes  ║
# ║  into failing builds to improve success rate by >3pp.                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.3.0"

# ─── Helper Functions ───────────────────────────────────────────────────────

# sp_paths: Resolve memory directory from repo hash
sp_paths() {
    local repo_hash
    repo_hash=$(git config --get remote.origin.url 2>/dev/null || echo "local")
    repo_hash=$(echo -n "$repo_hash" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    echo "${HOME}/.shipwright/memory/${repo_hash}"
}

# sp_now_iso: ISO8601 timestamp
sp_now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# sp_emit_event: Log event to JSONL
sp_emit_event() {
    local event_type="$1"; shift
    mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(sp_now_iso)\",\"type\":\"success_patterns.${event_type}\""
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}" val="${1#*=}"
        payload="${payload},\"${key}\":\"${val}\""
        shift
    done
    payload="${payload}}"
    echo "$payload" >> "${HOME}/.shipwright/events.jsonl"
}

# sp_deterministic_id: Generate deterministic ID from captured_at + issue_number
sp_deterministic_id() {
    local captured_at="$1" issue_number="$2"
    local combined="${captured_at}:${issue_number}"
    echo -n "$combined" | shasum -a 256 2>/dev/null | cut -c1-40 | sed 's/^/sp_/'
}

# ─── Core Functions ────────────────────────────────────────────────────────

# sp_load_patterns: Load success patterns from memory, degrade on error
sp_load_patterns() {
    local patterns_file
    patterns_file="$(sp_paths)/success-patterns.json"

    local patterns
    if [[ -f "$patterns_file" ]]; then
        patterns=$(jq -e '.patterns // []' "$patterns_file" 2>/dev/null) || {
            sp_emit_event "load_error" "file=${patterns_file}" "reason=malformed_json"
            patterns="[]"
        }
    else
        patterns="[]"
    fi

    # Lazy-backfill missing id and schema_version fields
    patterns=$(echo "$patterns" | jq --arg now "$(sp_now_iso)" '
        map(
            if .id | length == 0 then
                .id = ((.captured_at // $now) + ":" + (.issue_number | tostring)) |
                gsub("[^0-9a-zA-Z:]"; "") |
                "sp_\(.[0:40])"
            else . end |
            if .schema_version == null then
                .schema_version = 1
            else . end
        )
    ' 2>/dev/null) || {
        sp_emit_event "backfill_error" "reason=jq_failed"
        patterns="[]"
    }

    echo "$patterns"
}

# _sp_tokenize: Split string into lowercase tokens, strip stopwords
_sp_tokenize() {
    local text="$1"
    echo "$text" | \
        tr '[:upper:]' '[:lower:]' | \
        tr -cs '[:alnum:]' '\n' | \
        grep -vxE '^.{1,2}$|^(the|and|for|not|with|this|that|from|is|in|to|a|or)$' || true
}

# _sp_jaccard: Compute Jaccard similarity between two token sets (0-1)
# Input: two strings, each on a line, newline-separated tokens
_sp_jaccard() {
    local set1="$1" set2="$2"

    # Handle empty inputs
    [[ -z "$set1" || -z "$set2" ]] && { echo "0"; return 0; }

    local union_count intersection_count
    union_count=$(comm -23 <(echo "$set1" | sort -u) <(echo "$set2" | sort -u) | wc -l)
    union_count=$((union_count + $(echo "$set2" | sort -u | wc -l)))

    intersection_count=$(comm -12 <(echo "$set1" | sort -u) <(echo "$set2" | sort -u) | wc -l)

    # Jaccard = intersection / union (scale to 0-100)
    if [[ $union_count -eq 0 ]]; then
        echo "0"
    else
        # Use bc for floating point math if available, else integer approximation
        if command -v bc >/dev/null 2>&1; then
            echo "scale=2; ($intersection_count * 100) / $union_count" | bc 2>/dev/null || echo "0"
        else
            echo $(( (intersection_count * 100) / union_count ))
        fi
    fi
}

# sp_score_issue: Score incoming issue against loaded patterns
# Simplified: matches goal/files with issue text, scores 0-100
# Input: issue_title, files_json, error_sig_json, patterns_json (optional)
# Output: jq array of {pattern_id, score}
sp_score_issue() {
    local issue_title patterns files_json error_sig_json
    issue_title="${1:-}"
    files_json="${2:-[]}"
    error_sig_json="${3:-[]}"
    patterns="${4:-}"

    [[ -z "$patterns" ]] && patterns="$(sp_load_patterns)"
    [[ -z "$issue_title" ]] && { echo "[]"; return 0; }

    # Convert issue to lowercase for matching
    local issue_lower
    issue_lower=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]')

    # Parse files
    local files_lower
    files_lower=$(echo "$files_json" | jq -r '.[]? // empty' 2>/dev/null | \
        sed 's|.*/||; s|\.[a-z]*$||' | tr '[:upper:]' '[:lower:]' | paste -sd '|' - || echo "")

    # Score each pattern using simple jq
    echo "$patterns" | jq \
        --arg issue_lower "$issue_lower" \
        --arg files_lower "$files_lower" \
        '[ .[] |
            (
                ((.goal // "") + "|" + (.issue_title // "") | ascii_downcase) as $goal_text |
                (
                    (if ($goal_text | contains($issue_lower)) then 40 else 0 end) +
                    (if ((.approach // "") | ascii_downcase | contains($issue_lower)) then 25 else 0 end) +
                    (if (.files_changed[0] // "" | contains($files_lower)) then 35 else 0 end)
                ) as $score |
                {
                    pattern_id: (.id // "unknown"),
                    score: $score
                }
            )
        ] | sort_by(-.score)
    ' 2>/dev/null || echo "[]"
}

# sp_top_k: Filter and rank top-K patterns by similarity
# Input: scores_json (from sp_score_issue), optional threshold, optional max
# Output: jq array of top-K pattern IDs with scores
sp_top_k() {
    local scores_json="$1"
    local similarity_threshold="${2:-60}"
    local max_inject="${3:-3}"

    echo "$scores_json" | jq \
        --arg threshold "$similarity_threshold" \
        --arg max_k "$max_inject" \
        '[.[] | select(.score >= ($threshold | tonumber))] |
         sort_by(-.score) |
         .[0:($max_k | tonumber)]' 2>/dev/null || echo "[]"
}

# sp_render_injection: Format top patterns as markdown fragment for loop prompt
# Input: patterns_json, top_k_json
# Output: markdown fragment + injection_id sidecar
sp_render_injection() {
    local patterns_json="$1" top_k_json="$2"
    local injection_id="inj_$(date +%s)_$((RANDOM % 10000))"

    [[ -z "$patterns_json" ]] && patterns_json="$(sp_load_patterns)"
    [[ -z "$top_k_json" ]] && top_k_json="[]"

    local pattern_count
    pattern_count=$(echo "$top_k_json" | jq 'length' 2>/dev/null || echo 0)

    # Render markdown fragment
    local fragment=""
    if [[ $pattern_count -gt 0 ]]; then
        fragment="## Relevant past successes (from $(basename "$(pwd)") history)

"
        echo "$top_k_json" | jq -c '.[]' 2>/dev/null | while read -r item; do
            local pattern_id score
            pattern_id=$(echo "$item" | jq -r '.pattern_id' 2>/dev/null)
            score=$(echo "$item" | jq -r '.score' 2>/dev/null)

            [[ -z "$pattern_id" ]] && continue

            local pattern
            pattern=$(echo "$patterns_json" | jq \
                --arg pid "$pattern_id" \
                '.[] | select(.id == $pid) | {goal, approach, files_changed}' 2>/dev/null)

            [[ -z "$pattern" ]] && continue

            local confidence="medium"
            [[ ${score} -ge 75 ]] && confidence="**HIGH**"

            local goal
            goal=$(echo "$pattern" | jq -r '.goal // "improvement"' 2>/dev/null | head -c 100)

            local approach_summary
            approach_summary=$(echo "$pattern" | jq -r '.approach // ""' 2>/dev/null | cut -c1-200)

            echo "### Pattern (confidence: ${confidence}, match: ${score}%)
**Goal:** ${goal}
**Approach:** ${approach_summary}
---

"
        done >> /tmp/sp_fragment_$$.txt

        fragment=$(cat /tmp/sp_fragment_$$.txt 2>/dev/null | head -c 1800 || echo "")
        rm -f /tmp/sp_fragment_$$.txt 2>/dev/null || true
    fi

    # Write sidecar
    mkdir -p ".claude/pipeline-artifacts" 2>/dev/null || true
    printf '{"injection_id":"%s","generated_at":"%s","pattern_count":%d}' \
        "$injection_id" "$(sp_now_iso)" "$pattern_count" > ".claude/pipeline-artifacts/injection.json" 2>/dev/null || true

    [[ -n "$fragment" ]] && echo "$fragment"

    sp_emit_event "injected" "injection_id=${injection_id}" "pattern_count=${pattern_count}" 2>/dev/null || true
}

# sp_record_outcome: Record injection effectiveness in append-only JSONL
# Input: injection_id, pattern_ids (comma-sep), outcome (success|failure|abandoned), scores_json
sp_record_outcome() {
    local injection_id="$1" pattern_ids="$2" outcome="$3" scores_json="${4:-[]}"

    [[ -z "$injection_id" || -z "$pattern_ids" || -z "$outcome" ]] && return 1

    local effectiveness_file
    effectiveness_file="$(sp_paths)/pattern-effectiveness.jsonl"
    mkdir -p "$(dirname "$effectiveness_file")"

    # Atomic append with flock
    {
        flock -x 9 2>/dev/null || true

        local scores_array
        scores_array=$(echo "$scores_json" | jq 'map(.score) // []' 2>/dev/null || echo "[]")

        local acknowledged=false
        # Scan for acknowledgement in commit message or PR body (TODO: integrate with memory)

        printf '{"injection_id":"%s","pattern_ids":%s,"injected_at":"%s","outcome":"%s","outcome_at":"%s","scores":%s,"acknowledged":%s}\n' \
            "$injection_id" \
            "$(echo "$pattern_ids" | jq -R 'split(",")')" \
            "$(sp_now_iso)" \
            "$outcome" \
            "$(sp_now_iso)" \
            "$scores_array" \
            "$acknowledged" >> "$effectiveness_file"
    } 9>"${effectiveness_file}.lock" 2>/dev/null || true

    sp_emit_event "outcome_recorded" "injection_id=${injection_id}" "outcome=${outcome}"
}

# sp_effectiveness_report: Aggregate pattern effectiveness over time
# Output: JSON with success_rate, false_positive_rate, per_pattern_metrics
sp_effectiveness_report() {
    local effectiveness_file
    effectiveness_file="$(sp_paths)/pattern-effectiveness.jsonl"

    if [[ ! -f "$effectiveness_file" ]]; then
        echo '{"total_injections":0,"success_rate":0,"false_positive_rate":0,"patterns":[]}'
        return 0
    fi

    local total=0 successes=0 failures=0
    total=$(wc -l < "$effectiveness_file" 2>/dev/null || echo "0")
    successes=$(grep -c '"outcome":"success"' "$effectiveness_file" 2>/dev/null || echo "0")
    failures=$(grep -c '"outcome":"failure"' "$effectiveness_file" 2>/dev/null || echo "0")

    local success_rate=0
    if [[ $total -gt 0 ]]; then
        success_rate=$((successes * 100 / total))
    fi

    local false_positive_rate=0
    if [[ $total -gt 0 ]]; then
        false_positive_rate=$((failures * 100 / total))
    fi

    echo "{\"total_injections\":${total},\"successes\":${successes},\"failures\":${failures},\"success_rate\":${success_rate},\"false_positive_rate\":${false_positive_rate}}"
}

# sp_inject_for_loop: Combined function for loop integration
# Input: goal (string), files_json (optional, default []), threshold (optional, default 60)
# Output: markdown fragment suitable for injection into prompt
# Side effect: writes injection.json sidecar, returns injection_id
sp_inject_for_loop() {
    local goal="${1:-}" files_json="${2:-[]}" threshold="${3:-60}"

    [[ -z "$goal" ]] && return 0

    local patterns scores top_k
    patterns="$(sp_load_patterns)" || patterns="[]"

    [[ "$patterns" == "[]" ]] && return 0

    scores="$(sp_score_issue "$goal" "$files_json" "{}" "$patterns")" || scores="[]"
    top_k="$(sp_top_k "$scores" "$threshold" 3)" || top_k="[]"

    local pattern_count
    pattern_count=$(echo "$top_k" | jq 'length' 2>/dev/null || echo 0)

    [[ $pattern_count -eq 0 ]] && return 0

    sp_render_injection "$patterns" "$top_k"
}

# Functions are available in sourcing context; export not needed for bash sourcing
