#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  lib/proven-configs — Successful Pipeline Configuration Replay System     ║
# ║  Capture winning configuration tuples on success, replay on similar issues ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Module guard
[[ -n "${_MODULE_PROVEN_CONFIGS_LOADED:-}" ]] && return 0; _MODULE_PROVEN_CONFIGS_LOADED=1

VERSION="1.0.0"

# ─── Ensure helpers are loaded ──────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[[ -f "$SCRIPT_DIR/helpers.sh" ]] && source "$SCRIPT_DIR/helpers.sh" 2>/dev/null || true

# Fallback definitions if helpers not available
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() {
    local event_type="$1"; shift
    mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}" val="${1#*=}"
        payload="${payload},\"${key}\":\"${val}\""
        shift
    done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
}

# ─── Core Functions ──────────────────────────────────────────────────────────

# Get repo hash for storage directory (reuses memory system logic)
_proven_config_repo_hash() {
    local repo_dir="${1:-.}"
    if ! cd "$repo_dir" 2>/dev/null || ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "no-repo" >&2
        return 1
    fi
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$repo_dir")
    echo "$repo_root" | jq -Rs 'gsub("[^a-zA-Z0-9]"; "") | .[0:12]' 2>/dev/null || echo "default"
}

# Ensure proven config directory exists
_proven_config_dir() {
    local repo_hash="${1:-}"
    if [[ -z "$repo_hash" ]]; then
        repo_hash=$(_proven_config_repo_hash "." 2>/dev/null) || repo_hash="default"
    fi
    local config_dir="${HOME}/.shipwright/proven-configs/${repo_hash}"
    mkdir -p "$config_dir"
    echo "$config_dir"
}

# Extract significant keywords from text (remove stopwords, lowercase)
_proven_config_extract_keywords() {
    local text="$1"
    # Remove common stopwords, lowercase, split by non-alphanumeric
    echo "$text" | tr '[:upper:]' '[:lower:]' | \
        tr -cs 'a-z0-9' ' ' | \
        tr -s ' ' '\n' | \
        grep -v -E '^(a|an|the|and|or|is|it|in|on|of|to|for|with|by|from|at|be|this|that|these|those|i|you|he|she|we|they)$' | \
        grep -v '^$' | \
        head -20 | \
        tr '\n' ' ' | \
        sed 's/[[:space:]]*$//'
}

# Compute Jaccard similarity between two space-separated label sets
_proven_config_label_similarity() {
    local labels1="$1"
    local labels2="$2"

    # Convert to sorted unique sets
    local set1 set2 intersection union
    set1=$(echo "$labels1" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    set2=$(echo "$labels2" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')

    # If both empty, return 1.0
    if [[ -z "$set1" && -z "$set2" ]]; then
        echo "1.0"
        return 0
    fi

    # Count intersection and union
    local count1 count2 count_both
    count1=$(echo "$set1" | wc -w)
    count2=$(echo "$set2" | wc -w)

    # Simple approximation: count matching labels
    local matching=0
    for label in $set1; do
        if echo "$set2" | grep -qw "$label"; then
            matching=$((matching + 1))
        fi
    done

    # Jaccard = intersection / union
    union=$((count1 + count2 - matching))
    if [[ $union -eq 0 ]]; then
        echo "0.0"
    else
        echo "scale=2; $matching / $union" | bc 2>/dev/null || echo "0.0"
    fi
}

# Score a candidate config against query parameters
# Returns: score as integer (0-100)
_proven_config_score() {
    local query_type="$1"
    local query_complexity="$2"
    local query_labels="$3"
    local query_keywords="$4"

    local candidate="$5"  # JSON object

    if [[ -z "$candidate" ]]; then
        echo "0"
        return 0
    fi

    # Extract fields from candidate JSON
    local cand_type cand_complexity cand_labels cand_keywords cand_replay_count cand_success_count cand_age_days
    cand_type=$(echo "$candidate" | jq -r '.issue_type // ""' 2>/dev/null || echo "")
    cand_complexity=$(echo "$candidate" | jq -r '.complexity // 0' 2>/dev/null || echo "0")
    cand_labels=$(echo "$candidate" | jq -r '.labels // ""' 2>/dev/null || echo "")
    cand_keywords=$(echo "$candidate" | jq -r '.goal_keywords // ""' 2>/dev/null || echo "")
    cand_replay_count=$(echo "$candidate" | jq -r '.replay_count // 0' 2>/dev/null || echo "0")
    cand_success_count=$(echo "$candidate" | jq -r '.replay_success_count // 0' 2>/dev/null || echo "0")
    cand_captured_at=$(echo "$candidate" | jq -r '.captured_at // ""' 2>/dev/null || echo "")

    # Compute scores for each factor

    # Type match: 40 points (binary)
    local type_match_score=0
    if [[ "$query_type" == "$cand_type" ]]; then
        type_match_score=40
    fi

    # Complexity match: 25 points (similarity, max 25 when delta=0)
    local complexity_delta
    complexity_delta=$(echo "scale=1; $query_complexity - $cand_complexity" | bc 2>/dev/null | tr -d '-')
    # Score = 25 * (1 - delta/10), clamped to [0,25]
    local complexity_score
    complexity_score=$(echo "scale=1; 25 * (1 - $complexity_delta / 10)" | bc 2>/dev/null || echo "0")
    if (( $(echo "$complexity_score < 0" | bc -l 2>/dev/null || echo "1") )); then
        complexity_score="0"
    fi
    if (( $(echo "$complexity_score > 25" | bc -l 2>/dev/null || echo "0") )); then
        complexity_score="25"
    fi

    # Label overlap: 20 points (Jaccard similarity * 20)
    local label_similarity
    label_similarity=$(_proven_config_label_similarity "$query_labels" "$cand_labels")
    local label_score
    label_score=$(echo "scale=1; $label_similarity * 20" | bc 2>/dev/null || echo "0")

    # Keyword overlap: 15 points (count matching keywords / total)
    local keyword_match_count=0
    if [[ -n "$query_keywords" && -n "$cand_keywords" ]]; then
        for kw in $query_keywords; do
            if echo "$cand_keywords" | grep -qw "$kw"; then
                keyword_match_count=$((keyword_match_count + 1))
            fi
        done
    fi
    local total_keywords
    total_keywords=$(echo "$query_keywords $cand_keywords" | wc -w)
    if [[ $total_keywords -eq 0 ]]; then
        total_keywords=1
    fi
    local keyword_score
    keyword_score=$(echo "scale=1; ($keyword_match_count / $total_keywords) * 15" | bc 2>/dev/null || echo "0")

    # Confidence multiplier: replay_success_count / max(replay_count, 1), min 0.5
    local confidence
    if [[ $cand_replay_count -eq 0 ]]; then
        confidence="0.5"
    else
        confidence=$(echo "scale=2; $cand_success_count / $cand_replay_count" | bc 2>/dev/null || echo "0.5")
    fi

    # Recency decay: 1.0 - (age_days / 90), clamped [0.3, 1.0]
    local recency_multiplier="1.0"
    if [[ -n "$cand_captured_at" ]]; then
        local now_epoch captured_epoch age_seconds age_days
        now_epoch=$(date +%s)
        captured_epoch=$(date -d "$cand_captured_at" +%s 2>/dev/null || echo "$now_epoch")
        age_seconds=$((now_epoch - captured_epoch))
        age_days=$((age_seconds / 86400))
        recency_multiplier=$(echo "scale=2; 1.0 - ($age_days / 90)" | bc 2>/dev/null || echo "1.0")
        # Clamp [0.3, 1.0]
        if (( $(echo "$recency_multiplier < 0.3" | bc -l 2>/dev/null || echo "0") )); then
            recency_multiplier="0.3"
        fi
        if (( $(echo "$recency_multiplier > 1.0" | bc -l 2>/dev/null || echo "0") )); then
            recency_multiplier="1.0"
        fi
    fi

    # Combined score: (type + complexity + label + keyword) * confidence * recency
    local weighted_score
    weighted_score=$(echo "scale=1; ($type_match_score + $complexity_score + $label_score + $keyword_score)" | bc 2>/dev/null || echo "0")
    local final_score
    final_score=$(echo "scale=1; $weighted_score * $confidence * $recency_multiplier" | bc 2>/dev/null || echo "0")

    # Round to integer (0-100)
    printf "%.0f" "$final_score"
}

# Capture successful pipeline configuration
# Usage: proven_config_capture <state_file> <artifacts_dir> [repo_dir]
proven_config_capture() {
    local state_file="$1"
    local artifacts_dir="$2"
    local repo_dir="${3:-.}"

    # Validate inputs
    if [[ ! -f "$state_file" ]]; then
        error "proven_config_capture: state_file not found: $state_file"
        return 1
    fi

    # Extract config from state file and artifacts
    local template model iterations timeout quality_threshold coverage effort team_size
    local issue_type complexity labels goal_keywords
    local outcome_result cost_usd duration_s iterations_used stages_passed stages_total

    # Try to parse state file
    template=$(jq -r '.pipeline_template // .template // "standard"' "$state_file" 2>/dev/null || echo "standard")
    model=$(jq -r '.model // "sonnet"' "$state_file" 2>/dev/null || echo "sonnet")
    iterations=$(jq -r '.max_iterations // 10' "$state_file" 2>/dev/null || echo "10")
    timeout=$(jq -r '.timeout_s // 600' "$state_file" 2>/dev/null || echo "600")
    quality_threshold=$(jq -r '.quality_threshold // 70' "$state_file" 2>/dev/null || echo "70")
    coverage=$(jq -r '.coverage_min // 80' "$state_file" 2>/dev/null || echo "80")
    effort=$(jq -r '.effort_level // "medium"' "$state_file" 2>/dev/null || echo "medium")
    team_size=$(jq -r '.team_size // 1' "$state_file" 2>/dev/null || echo "1")

    # Issue context
    issue_type=$(jq -r '.issue_type // "unknown"' "$state_file" 2>/dev/null || echo "unknown")
    complexity=$(jq -r '.complexity // 5' "$state_file" 2>/dev/null || echo "5")
    labels=$(jq -r '.labels // ""' "$state_file" 2>/dev/null || echo "")
    goal_keywords=$(_proven_config_extract_keywords "${goal_keywords:-$(jq -r '.goal // ""' "$state_file" 2>/dev/null || echo "")}")

    # Outcome metrics from artifacts
    if [[ -f "$artifacts_dir/error-log.jsonl" ]]; then
        outcome_result=$(tail -1 "$artifacts_dir/error-log.jsonl" 2>/dev/null | jq -r '.result // "success"' 2>/dev/null || echo "success")
    else
        outcome_result="success"
    fi

    # Cost and duration from state
    cost_usd=$(jq -r '.cost_usd // 0' "$state_file" 2>/dev/null || echo "0")
    duration_s=$(jq -r '.duration_s // 0' "$state_file" 2>/dev/null || echo "0")
    iterations_used=$(jq -r '.iterations_used // 1' "$state_file" 2>/dev/null || echo "1")
    stages_passed=$(jq -r '.stages_passed // 1' "$state_file" 2>/dev/null || echo "1")
    stages_total=$(jq -r '.stages_total // 1' "$state_file" 2>/dev/null || echo "1")

    # Get repo hash
    local repo_hash
    repo_hash=$(_proven_config_repo_hash "$repo_dir" 2>/dev/null) || repo_hash="default"

    # Generate unique ID
    local config_id
    config_id="pc-$(date +%s)-$RANDOM"

    # Build config JSON (single line)
    local config_entry
    config_entry=$(jq -n \
        --arg id "$config_id" \
        --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg issue_type "$issue_type" \
        --arg complexity "$complexity" \
        --arg labels "$labels" \
        --arg goal_keywords "$goal_keywords" \
        --arg template "$template" \
        --arg model "$model" \
        --arg iterations "$iterations" \
        --arg timeout "$timeout" \
        --arg quality_threshold "$quality_threshold" \
        --arg coverage "$coverage" \
        --arg effort "$effort" \
        --arg team_size "$team_size" \
        --arg result "$outcome_result" \
        --arg cost_usd "$cost_usd" \
        --arg duration_s "$duration_s" \
        --arg iterations_used "$iterations_used" \
        --arg stages_passed "$stages_passed" \
        --arg stages_total "$stages_total" \
        '{
            id: $id,
            captured_at: $captured_at,
            issue_type: $issue_type,
            complexity: ($complexity | tonumber),
            labels: $labels,
            goal_keywords: $goal_keywords,
            config: {
                template: $template,
                model: $model,
                max_iterations: ($iterations | tonumber),
                timeout_s: ($timeout | tonumber),
                quality_threshold: ($quality_threshold | tonumber),
                coverage_min: ($coverage | tonumber),
                effort_level: $effort,
                team_size: ($team_size | tonumber)
            },
            outcome: {
                result: $result,
                cost_usd: ($cost_usd | tonumber),
                duration_s: ($duration_s | tonumber),
                iterations_used: ($iterations_used | tonumber),
                stages_passed: ($stages_passed | tonumber),
                stages_total: ($stages_total | tonumber)
            },
            replay_count: 0,
            replay_success_count: 0,
            last_replayed_at: null,
            confidence: 1.0
        }' 2>/dev/null) || {
        error "proven_config_capture: failed to build JSON"
        return 1
    }

    # Validate JSON
    if ! jq -e '.' <<<"$config_entry" >/dev/null 2>&1; then
        error "proven_config_capture: invalid JSON generated"
        return 1
    fi

    # Append to JSONL with atomic write
    local config_dir config_file tmp_file
    config_dir=$(_proven_config_dir "$repo_hash")
    config_file="$config_dir/configs.jsonl"

    # Atomic append (< PIPE_BUF is safe)
    if ! echo "$config_entry" >> "$config_file"; then
        error "proven_config_capture: failed to write config"
        return 1
    fi

    emit_event "proven_config_captured" "id=$config_id" "template=$template" "model=$model" "confidence=1.0"
    success "Captured proven configuration ($config_id)"
    echo "$config_id"
    return 0
}

# Find best matching proven configuration
# Usage: proven_config_match <issue_type> <complexity> <labels> <goal_text> [repo_dir]
proven_config_match() {
    local issue_type="$1"
    local complexity="$2"
    local labels="$3"
    local goal_text="$4"
    local repo_dir="${5:-.}"

    local repo_hash
    repo_hash=$(_proven_config_repo_hash "$repo_dir" 2>/dev/null) || repo_hash="default"

    local config_dir config_file
    config_dir=$(_proven_config_dir "$repo_hash")
    config_file="$config_dir/configs.jsonl"

    # Return empty if no configs
    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # Extract keywords from goal
    local query_keywords
    query_keywords=$(_proven_config_extract_keywords "$goal_text")

    # Search configs: recent first (tail -500), then full file if needed
    local best_score=0
    local best_config=""
    local line config_score

    # Try recent configs first
    local search_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        search_count=$((search_count + 1))

        # Skip invalid JSON
        if ! jq -e '.' <<<"$line" >/dev/null 2>&1; then
            continue
        fi

        config_score=$(_proven_config_score "$issue_type" "$complexity" "$labels" "$query_keywords" "$line")
        if [[ $config_score -gt $best_score ]]; then
            best_score=$config_score
            best_config="$line"
        fi
    done < <(tail -500 "$config_file" 2>/dev/null || cat "$config_file" 2>/dev/null)

    # If no match in recent entries and file is large, try full scan (but this is less likely needed)

    # Return best match if score >= 50
    if [[ $best_score -ge 50 && -n "$best_config" ]]; then
        # Add score to output JSON
        echo "$best_config" | jq --arg score "$best_score" '. + {score: ($score | tonumber)}'
        emit_event "proven_config_matched" "score=$best_score" "issue_type=$issue_type"
        return 0
    fi

    # No good match
    return 0
}

# Apply proven configuration to pipeline environment
# Usage: proven_config_apply <config_json>
proven_config_apply() {
    local config_json="$1"

    if [[ -z "$config_json" ]]; then
        return 0
    fi

    # Extract config object
    local config
    config=$(echo "$config_json" | jq -r '.config' 2>/dev/null) || return 1

    # Only override if not already explicitly set by user
    # User intent (env vars set) takes precedence
    if [[ -z "${PIPELINE_TEMPLATE:-}" ]]; then
        export PIPELINE_TEMPLATE=$(echo "$config" | jq -r '.template // "standard"' 2>/dev/null || echo "standard")
    fi

    if [[ -z "${MODEL:-}" ]]; then
        export MODEL=$(echo "$config" | jq -r '.model // "sonnet"' 2>/dev/null || echo "sonnet")
    fi

    if [[ -z "${MAX_ITERATIONS:-}" ]]; then
        export MAX_ITERATIONS=$(echo "$config" | jq -r '.max_iterations // 10' 2>/dev/null || echo "10")
    fi

    if [[ -z "${TIMEOUT_S:-}" ]]; then
        export TIMEOUT_S=$(echo "$config" | jq -r '.timeout_s // 600' 2>/dev/null || echo "600")
    fi

    if [[ -z "${QUALITY_THRESHOLD:-}" ]]; then
        export QUALITY_THRESHOLD=$(echo "$config" | jq -r '.quality_threshold // 70' 2>/dev/null || echo "70")
    fi

    if [[ -z "${COVERAGE_MIN:-}" ]]; then
        export COVERAGE_MIN=$(echo "$config" | jq -r '.coverage_min // 80' 2>/dev/null || echo "80")
    fi

    if [[ -z "${EFFORT_LEVEL:-}" ]]; then
        export EFFORT_LEVEL=$(echo "$config" | jq -r '.effort_level // "medium"' 2>/dev/null || echo "medium")
    fi

    if [[ -z "${TEAM_SIZE:-}" ]]; then
        export TEAM_SIZE=$(echo "$config" | jq -r '.team_size // 1' 2>/dev/null || echo "1")
    fi

    # Always set proven config ID for tracking
    export PROVEN_CONFIG_ID=$(echo "$config_json" | jq -r '.id // ""' 2>/dev/null || echo "")

    return 0
}

# Track replay outcome
# Usage: proven_config_track_replay <config_id> <result> [repo_dir]
proven_config_track_replay() {
    local config_id="$1"
    local result="$2"  # success or failure
    local repo_dir="${3:-.}"

    [[ "$result" =~ ^(success|failure)$ ]] || return 1

    local repo_hash
    repo_hash=$(_proven_config_repo_hash "$repo_dir" 2>/dev/null) || repo_hash="default"

    local config_dir config_file
    config_dir=$(_proven_config_dir "$repo_hash")
    config_file="$config_dir/configs.jsonl"

    if [[ ! -f "$config_file" ]]; then
        return 1
    fi

    # Find and update the config
    local tmp_file
    tmp_file="${config_file}.tmp.$$"
    local found=0
    local updated_entry

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Skip invalid JSON
        if ! jq -e '.' <<<"$line" >/dev/null 2>&1; then
            echo "$line" >> "$tmp_file"
            continue
        fi

        local this_id
        this_id=$(echo "$line" | jq -r '.id // ""' 2>/dev/null)

        if [[ "$this_id" == "$config_id" ]]; then
            found=1
            # Update replay counts and confidence
            updated_entry=$(echo "$line" | jq \
                --arg result "$result" \
                --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '.replay_count += 1 |
                 (if $result == "success" then .replay_success_count += 1 else . end) |
                 .last_replayed_at = $now |
                 .confidence = (.replay_success_count / .replay_count) |
                 (if .confidence < 0.5 then .confidence = 0.5 else . end)' 2>/dev/null)

            # Demote if success rate dropped below 40% after 5+ replays
            if (( $(echo "${replay_count:-0} >= 5" | sed 's/replay_count/$(echo "$updated_entry" | jq -r ".replay_count")/') )); then
                local confidence success_rate
                success_rate=$(echo "$updated_entry" | jq -r '.replay_success_count' 2>/dev/null || echo "0")
                confidence=$(echo "$updated_entry" | jq -r '.confidence' 2>/dev/null || echo "0")
                if (( $(echo "$confidence < 0.4" | bc -l 2>/dev/null || echo "0") )); then
                    updated_entry=$(echo "$updated_entry" | jq '. + {demoted: true}')
                    warn "Config $config_id demoted: success rate < 40%"
                fi
            fi

            echo "$updated_entry" >> "$tmp_file"
        else
            echo "$line" >> "$tmp_file"
        fi
    done < "$config_file"

    # Atomic replace
    if [[ $found -eq 1 ]]; then
        mv "$tmp_file" "$config_file"
        emit_event "proven_config_replay_tracked" "id=$config_id" "result=$result"
        return 0
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# List all proven configurations
# Usage: proven_config_list [repo_hash]
proven_config_list() {
    local repo_hash="${1:-}"
    if [[ -z "$repo_hash" ]]; then
        repo_hash=$(_proven_config_repo_hash "." 2>/dev/null) || repo_hash="default"
    fi

    local config_dir config_file
    config_dir=$(_proven_config_dir "$repo_hash")
    config_file="$config_dir/configs.jsonl"

    if [[ ! -f "$config_file" ]]; then
        echo "[]"
        return 0
    fi

    # Read all valid configs and sort by confidence descending
    jq -s 'sort_by(.confidence) | reverse' "$config_file" 2>/dev/null || echo "[]"
}

# Get statistics about proven configurations
# Usage: proven_config_stats [repo_hash]
proven_config_stats() {
    local repo_hash="${1:-}"
    if [[ -z "$repo_hash" ]]; then
        repo_hash=$(_proven_config_repo_hash "." 2>/dev/null) || repo_hash="default"
    fi

    local config_dir config_file
    config_dir=$(_proven_config_dir "$repo_hash")
    config_file="$config_dir/configs.jsonl"

    if [[ ! -f "$config_file" ]]; then
        jq -n '{total_configs: 0, total_replays: 0, replay_success_rate: 0, avg_confidence: 0, top_issue_types: []}'
        return 0
    fi

    # Compute stats with jq
    jq -s '
        {
            total_configs: (. | length),
            total_replays: (map(.replay_count) | add // 0),
            replay_success_rate: (
                (map(.replay_success_count) | add // 0) as $successes |
                (map(.replay_count) | add // 0) as $total |
                if $total == 0 then 0 else ($successes / $total) end
            ),
            avg_confidence: (map(.confidence) | add / (length // 1)),
            top_issue_types: (
                group_by(.issue_type) |
                map({type: .[0].issue_type, count: (. | length)}) |
                sort_by(-.count) |
                .[0:5]
            )
        }
    ' "$config_file" 2>/dev/null || jq -n '{total_configs: 0, total_replays: 0, replay_success_rate: 0, avg_confidence: 0, top_issue_types: []}'
}

# Prune old/failing configurations
# Usage: proven_config_prune [max_age_days] [min_confidence] [repo_dir]
proven_config_prune() {
    local max_age_days="${1:-90}"
    local min_confidence="${2:-0.3}"
    local repo_dir="${3:-.}"

    local repo_hash
    repo_hash=$(_proven_config_repo_hash "$repo_dir" 2>/dev/null) || repo_hash="default"

    local config_dir config_file
    config_dir=$(_proven_config_dir "$repo_hash")
    config_file="$config_dir/configs.jsonl"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # Build new JSONL keeping only recent/high-confidence configs
    # but preserving at least 3 per issue_type
    local tmp_file now_epoch
    tmp_file="${config_file}.tmp.$$"
    now_epoch=$(date +%s)

    # Use jq to filter and rebuild
    jq -r --arg now "$now_epoch" --arg max_age "$max_age_days" --arg min_conf "$min_confidence" '
        . as $entry |
        ($entry.captured_at | fromdateiso8601) as $captured_epoch |
        (($now | tonumber) - $captured_epoch) / 86400 as $age |
        if ($age <= ($max_age | tonumber)) or ($entry.confidence >= ($min_conf | tonumber)) then
            $entry
        else
            empty
        end
    ' "$config_file" 2>/dev/null > "$tmp_file"

    # Move back
    mv "$tmp_file" "$config_file"
    emit_event "proven_config_pruned" "max_age_days=$max_age_days" "min_confidence=$min_confidence"
    return 0
}

# Export functions for use in pipeline
export -f proven_config_capture
export -f proven_config_match
export -f proven_config_apply
export -f proven_config_track_replay
export -f proven_config_prune
export -f proven_config_list
export -f proven_config_stats
