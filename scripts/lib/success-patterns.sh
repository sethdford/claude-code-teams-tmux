#!/usr/bin/env bash
# Success Pattern Injection Engine for Failing Builds
# Loads historical success patterns, scores similarity, injects top-K into build context,
# and tracks injection effectiveness

VERSION="3.3.0"

set -euo pipefail
ERR_TRAP_DEPTH=0
trap 'ERR_TRAP_DEPTH=$((ERR_TRAP_DEPTH+1)); if [[ $ERR_TRAP_DEPTH -le 1 ]]; then error "Error in success-patterns.sh line $LINENO"; fi' ERR

# Scoring weights for similarity matching (sum to 1.0)
readonly SP_WEIGHT_TITLE=0.40
readonly SP_WEIGHT_FILES=0.35
readonly SP_WEIGHT_ERROR=0.25
readonly SP_SIMILARITY_THRESHOLD=0.30
readonly SP_DEFAULT_MAX_INJECT=3

# ==============================================================================
# Helpers
# ==============================================================================

_jq() {
    if command -v jq &>/dev/null; then
        jq "$@"
    else
        return 1
    fi
}

_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8
    else
        date +%s%N | md5sum | cut -c1-8
    fi
}

# ==============================================================================
# Core Functions
# ==============================================================================

# sp_load_patterns — Load and parse success pattern index from disk
# Args: $1 = pattern file path
# Returns: 0 if loaded, 1 if not found or corrupted
sp_load_patterns() {
    local pattern_file="${1:-}"
    if [[ -z "$pattern_file" ]]; then
        return 1
    fi
    if [[ ! -f "$pattern_file" ]]; then
        return 1
    fi

    # Try to parse as JSON; if corrupt, print empty array
    if _jq empty "$pattern_file" 2>/dev/null; then
        cat "$pattern_file"
    else
        echo "[]"
    fi
}

# sp_score_title — Compute Jaccard similarity of title tokens
# Args: $1 = incoming title, $2 = pattern title
# Returns: 0.0-1.0 (printed to stdout)
sp_score_title() {
    local incoming="$1"
    local pattern="$2"

    # Tokenize (lowercase, split on non-alphanumeric)
    local incoming_tokens pattern_tokens
    incoming_tokens=$(echo "$incoming" | tr '[:upper:]' '[:lower:]' | grep -oE '\b[a-z0-9]+\b' | sort -u | paste -sd '|' -)
    pattern_tokens=$(echo "$pattern" | tr '[:upper:]' '[:lower:]' | grep -oE '\b[a-z0-9]+\b' | sort -u | paste -sd '|' -)

    if [[ -z "$incoming_tokens" ]] || [[ -z "$pattern_tokens" ]]; then
        echo "0.0"
        return 0
    fi

    # Compute Jaccard manually (bash 3.2 compatible)
    local in_count pat_count union_count intersection_count
    in_count=$(echo "$incoming_tokens" | tr '|' '\n' | wc -l)
    pat_count=$(echo "$pattern_tokens" | tr '|' '\n' | wc -l)

    # Count intersection by finding common tokens
    intersection_count=$(comm -12 <(echo "$incoming_tokens" | tr '|' '\n' | sort) <(echo "$pattern_tokens" | tr '|' '\n' | sort) | wc -l)

    # Jaccard = intersection / union = intersection / (a + b - intersection)
    union_count=$((in_count + pat_count - intersection_count))

    if [[ $union_count -eq 0 ]]; then
        echo "0.0"
    else
        # Use bc for division if available
        if command -v bc >/dev/null 2>&1; then
            local result
            result=$(echo "scale=2; $intersection_count / $union_count" | bc)
            # Ensure leading zero for values < 1.0
            if [[ "$result" == .* ]]; then
                echo "0$result"
            else
                echo "$result"
            fi
        else
            # Fallback: simple division
            if [[ $intersection_count -eq 0 ]]; then
                echo "0.0"
            elif [[ $intersection_count -eq $union_count ]]; then
                echo "1.0"
            else
                echo "0.5"
            fi
        fi
    fi
}

# sp_score_files — Compute overlap of modified files
# Args: $1 = incoming files (JSON array), $2 = pattern files (JSON array)
# Returns: 0.0-1.0 (printed to stdout)
sp_score_files() {
    local incoming_files="$1"
    local pattern_files="$2"

    if [[ -z "$incoming_files" ]] || [[ -z "$pattern_files" ]]; then
        echo "0.0"
        return 0
    fi

    _jq -n \
        --argjson in "$incoming_files" \
        --argjson pat "$pattern_files" \
        'def file_overlap:
          ([$in[] | split("/")[0]] | unique) as $in_dirs |
          ([$pat[] | split("/")[0]] | unique) as $pat_dirs |
          ($in_dirs | length) as $in_len |
          ($pat_dirs | length) as $pat_len |
          (($in_dirs + $pat_dirs) | unique | length) as $union |
          if ($union == 0) then 0 else (($in_len + $pat_len - $union) / $union) end;
        file_overlap' 2>/dev/null || echo "0.0"
}

# sp_score_error — Compute substring match ratio for error signatures
# Args: $1 = incoming error sig, $2 = pattern error sig
# Returns: 0.0-1.0 (printed to stdout)
sp_score_error() {
    local incoming="$1"
    local pattern="$2"

    if [[ -z "$incoming" ]] || [[ -z "$pattern" ]]; then
        echo "0.0"
        return 0
    fi

    local lower_incoming lower_pattern
    lower_incoming=$(echo "$incoming" | tr '[:upper:]' '[:lower:]')
    lower_pattern=$(echo "$pattern" | tr '[:upper:]' '[:lower:]')

    # Simple substring match: if pattern found in incoming, return 0.5; if equal, return 1.0
    if [[ "$lower_incoming" == "$lower_pattern" ]]; then
        echo "1.0"
    elif [[ "$lower_incoming" == *"$lower_pattern"* ]] || [[ "$lower_pattern" == *"$lower_incoming"* ]]; then
        echo "0.5"
    else
        echo "0.0"
    fi
}

# sp_similarity_score — Compute weighted similarity score
# Args: $1 = incoming (JSON object), $2 = pattern (JSON object)
# Returns: 0.0-1.0 (printed to stdout)
sp_similarity_score() {
    local incoming="$1"
    local pattern="$2"

    local incoming_title incoming_files incoming_error
    local pattern_title pattern_files pattern_error

    incoming_title=$(echo "$incoming" | _jq -r '.goal // "unknown"' 2>/dev/null || echo "unknown")
    pattern_title=$(echo "$pattern" | _jq -r '.goal // "unknown"' 2>/dev/null || echo "unknown")

    incoming_files=$(echo "$incoming" | _jq -r '.files_changed // []' 2>/dev/null || echo "[]")
    pattern_files=$(echo "$pattern" | _jq -r '.files_changed // []' 2>/dev/null || echo "[]")

    incoming_error=$(echo "$incoming" | _jq -r '.error_signature // ""' 2>/dev/null || echo "")
    pattern_error=$(echo "$pattern" | _jq -r '.error_signature // ""' 2>/dev/null || echo "")

    local score_title score_files score_error
    score_title=$(sp_score_title "$incoming_title" "$pattern_title" || echo "0.0")
    score_files=$(sp_score_files "$incoming_files" "$pattern_files" || echo "0.0")
    score_error=$(sp_score_error "$incoming_error" "$pattern_error" || echo "0.0")

    _jq -n \
        --arg t "$score_title" \
        --arg f "$score_files" \
        --arg e "$score_error" \
        '($t | tonumber) * 0.40 + ($f | tonumber) * 0.35 + ($e | tonumber) * 0.25' 2>/dev/null || echo "0.0"
}

# sp_top_k — Find top K similar patterns
# Args: $1 = incoming (JSON), $2 = patterns (JSON array), $3 = k, $4 = threshold
# Returns: JSON array of top patterns
sp_top_k() {
    local incoming="$1"
    local patterns="$2"
    local k="${3:-3}"
    local threshold="${4:-0.30}"

    if [[ -z "$patterns" ]] || [[ "$patterns" == "[]" ]]; then
        echo "[]"
        return 0
    fi

    # Score each pattern against incoming
    _jq -n \
        --argjson in "$incoming" \
        --argjson pats "$patterns" \
        --arg k "$k" \
        --arg thresh "$threshold" \
        'def score:
          . as $pat |
          (($in | tostring) as $in_str |
           ($pat | tostring) as $pat_str |
           (($in_str | split(" ") | unique | length) as $in_len |
            ($pat_str | split(" ") | unique | length) as $pat_len |
            if ($in_len == 0 or $pat_len == 0) then 0 else
              (($in_str | split(" ") + ($pat_str | split(" ")) | unique | length) as $union |
               (($in_len + $pat_len - $union) / $union))
            end));
        pats | map({pat: ., score: (. | score)}) |
        sort_by(.score) | reverse |
        map(select(.score >= ($thresh | tonumber))) |
        .[0:($k | tonumber)] |
        map(.pat)' 2>/dev/null || echo "[]"
}

# sp_render_injection — Render top patterns as context snippet
# Args: $1 = patterns (JSON array), $2 = injection_id
# Returns: Markdown text (printed to stdout) + sidecar JSON written to file
sp_render_injection() {
    local patterns="$1"
    local injection_id="$2"
    local char_limit=${3:-2000}
    local line_limit=${4:-20}

    if [[ -z "$patterns" ]] || [[ "$patterns" == "[]" ]]; then
        echo ""
        return 0
    fi

    local output
    output=$'## 🔄 Success Patterns Injected\n'

    local count=0
    while read -r line; do
        local goal approach iterations
        goal=$(echo "$line" | _jq -r '.goal // ""' 2>/dev/null || echo "")
        approach=$(echo "$line" | _jq -r '.approach // ""' 2>/dev/null || echo "")
        iterations=$(echo "$line" | _jq -r '.iterations // 0' 2>/dev/null || echo "0")

        if [[ -n "$goal" ]]; then
            local snippet
            snippet=$(echo "- **$goal** ($iterations iter): $approach")
            output+=$'\n'"$snippet"
            count=$((count+1))

            # Check limits
            if [[ ${#output} -gt $char_limit ]] || [[ $count -ge $line_limit ]]; then
                break
            fi
        fi
    done < <(echo "$patterns" | _jq -c '.[]' 2>/dev/null || true)

    # Cap output
    if [[ ${#output} -gt $char_limit ]]; then
        output="${output:0:$char_limit}..."
    fi

    echo "$output"

    # Write sidecar JSON
    {
        echo "{"
        echo "  \"injection_id\": \"$injection_id\","
        echo "  \"patterns_count\": $count,"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
        echo "}"
    } > ".claude/pipeline-artifacts/injection.json" 2>/dev/null || true
}

# sp_record_outcome — Record injection outcome (success/failure)
# Args: $1 = injection_id, $2 = error_msg, $3 = status, $4 = metadata
# Returns: 0
sp_record_outcome() {
    local injection_id="$1"
    local error_msg="$2"
    local status="$3"  # success|failure
    local metadata="${4:-{}}"

    local outcomes_file="${HOME}/.shipwright/memory/injection-outcomes.jsonl"
    mkdir -p "$(dirname "$outcomes_file")"

    {
        echo "{"
        echo "  \"injection_id\": \"$injection_id\","
        echo "  \"status\": \"$status\","
        echo "  \"error\": \"$error_msg\","
        echo "  \"metadata\": $metadata,"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
        echo "}"
    } >> "$outcomes_file" 2>/dev/null || true

    return 0
}

# sp_effectiveness_report — Generate effectiveness summary
# Args: (none)
# Returns: JSON object with metrics (printed to stdout)
sp_effectiveness_report() {
    local outcomes_file="${HOME}/.shipwright/memory/injection-outcomes.jsonl"

    if [[ ! -f "$outcomes_file" ]]; then
        _jq -n '{success_count: 0, failure_count: 0, effectiveness: 0}'
        return 0
    fi

    _jq -s '{
        success_count: map(select(.status == "success")) | length,
        failure_count: map(select(.status == "failure")) | length,
        total: length,
        effectiveness: (map(select(.status == "success")) | length / (map(.) | length))
    }' "$outcomes_file" 2>/dev/null || {
        _jq -n '{success_count: 0, failure_count: 0, effectiveness: 0}'
    }
}

# sp_inject_for_loop — Wrapper for injection in loop context
# Args: $1 = goal/title, $2 = test_strategy (optional)
# Returns: JSON with injection_id and snippet
sp_inject_for_loop() {
    local goal="$1"
    local test_strategy="${2:-}"

    # Build incoming context
    local incoming
    incoming=$(
        _jq -n \
            --arg goal "$goal" \
            '{
                goal: $goal,
                files_changed: [],
                error_signature: "",
                test_strategy: "",
                iterations: 0
            }'
    )

    # Load patterns from memory
    local memory_dir="${HOME}/.shipwright/memory"
    local pattern_file
    if [[ -d "$memory_dir" ]]; then
        pattern_file=$(find "$memory_dir" -name "success-patterns.json" -type f 2>/dev/null | head -1)
    fi

    local patterns="[]"
    if [[ -n "$pattern_file" ]] && [[ -f "$pattern_file" ]]; then
        patterns=$(sp_load_patterns "$pattern_file" 2>/dev/null || echo "[]")
        patterns=$(_jq -r 'if type == "array" then . else if .patterns then .patterns else [] end end' <<< "$patterns" 2>/dev/null || echo "[]")
    fi

    # Score and select top K
    local top_patterns
    top_patterns=$(sp_top_k "$incoming" "$patterns" 3 0.30)

    # Generate injection_id
    local injection_id="inj-$(_uuid)-$(date +%s)"

    # Render snippet
    local snippet
    snippet=$(sp_render_injection "$top_patterns" "$injection_id")

    # Output JSON
    _jq -n \
        --arg id "$injection_id" \
        --arg snippet "$snippet" \
        --argjson patterns "$top_patterns" \
        '{
            injection_id: $id,
            snippet: $snippet,
            patterns_count: ($patterns | length),
            timestamp: "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"
        }'

    return 0
}

export -f sp_load_patterns
export -f sp_score_title
export -f sp_score_files
export -f sp_score_error
export -f sp_similarity_score
export -f sp_top_k
export -f sp_render_injection
export -f sp_record_outcome
export -f sp_effectiveness_report
export -f sp_inject_for_loop
