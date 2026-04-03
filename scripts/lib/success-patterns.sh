#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Success Pattern Library with Automatic Pattern Replay Engine              ║
# ║  Captures successful patterns · Injects into future builds · A/B testing  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Module guard - prevent double-sourcing
[[ -n "${_SUCCESS_PATTERNS_LOADED:-}" ]] && return 0
_SUCCESS_PATTERNS_LOADED=1

set -euo pipefail

# Import helpers for color output and events
if [[ "$(type -t info 2>/dev/null)" != "function" ]]; then
    info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
    success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
    warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
    error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
fi

if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
    now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
    now_epoch() { date +%s; }
fi

if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
    emit_event() {
        local event_type="$1"; shift
        mkdir -p "${HOME}/.shipwright"
        local payload
        payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
        while [[ $# -gt 0 ]]; do
            local key="${1%%=*}" val="${1#*=}"
            payload="${payload},\"${key}\":\"${val}\""
            shift
        done
        echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
    }
fi

# ─── Storage Paths ──────────────────────────────────────────────────────────

# Must be defined or available from sourcing context
MEMORY_ROOT="${MEMORY_ROOT:-${HOME}/.shipwright/memory}"

# ─── Core Functions ─────────────────────────────────────────────────────────

# success_pattern_capture <state_file> <artifacts_dir> [repo_memory_dir]
# Called on successful pipeline completion only.
# Extracts goal, issue type, complexity, iterations, files changed, approach, etc.
success_pattern_capture() {
    local state_file="${1:-}"
    local artifacts_dir="${2:-}"
    local mem_dir="${3:-}"

    [[ -z "$state_file" || ! -f "$state_file" ]] && return 0
    [[ -z "$artifacts_dir" ]] && return 0

    # Default to calling context's repo_memory_dir if available
    if [[ -z "$mem_dir" ]] && type repo_memory_dir &>/dev/null 2>&1; then
        mem_dir="$(repo_memory_dir)"
    fi
    mem_dir="${mem_dir:-$MEMORY_ROOT/unknown}"

    local patterns_file="$mem_dir/success-patterns.json"
    mkdir -p "$mem_dir"
    [[ ! -f "$patterns_file" ]] && echo '{"patterns":[]}' > "$patterns_file"

    # Extract basic info from state file
    local goal issue_type complexity
    goal=$(sed -n 's/^goal: *//p' "$state_file" | head -1 || echo "")
    issue_type=$(sed -n 's/^issue_type: *//p' "$state_file" | head -1 || echo "feature")
    complexity=$(sed -n 's/^complexity: *//p' "$state_file" | head -1 || echo "50")

    [[ -z "$goal" ]] && return 0

    # Get iteration count from loop state if available
    local iterations=1
    if [[ -f "$artifacts_dir/.claude/loop-state.md" ]]; then
        iterations=$(grep -o "Iteration [0-9]*" "$artifacts_dir/.claude/loop-state.md" | tail -1 | grep -o "[0-9]*" || echo "1")
    fi

    # Extract files changed from git (safe for JSON passing)
    local files_changed_json='[]'
    local files_changed=0
    if type repo_memory_dir &>/dev/null 2>&1; then
        local git_files
        git_files=$(git diff --name-only 2>/dev/null | jq -sR 'split("\n")[:-1]' 2>/dev/null || echo '[]')
        if [[ -n "$git_files" && "$git_files" != "[]" ]]; then
            files_changed_json="$git_files"
            files_changed=$(echo "$files_changed_json" | jq '. | length' 2>/dev/null || echo 0)
        fi
    fi

    # Quality gate: skip trivial pipelines
    # Only skip if BOTH: iterations < 2 AND files_changed < 3
    if [[ "$iterations" -lt 2 && "$files_changed" -lt 3 ]]; then
        info "Pattern capture: skipping trivial pipeline (iterations=$iterations, files=$files_changed)"
        return 0
    fi

    # Get file patterns (directory-level globs)
    local file_patterns
    if [[ "$files_changed_json" != "[]" && "$files_changed_json" != "" ]]; then
        file_patterns=$(echo "$files_changed_json" | jq -r '.[] | gsub("/[^/]*$"; "") | gsub("[^/]*$"; "")' | sort -u | paste -sd ' ' - || echo ".")
    else
        file_patterns="."
    fi

    # Get test strategy from artifacts
    local test_strategy="npm test"
    if [[ -f "$artifacts_dir/test-command.txt" ]]; then
        test_strategy=$(cat "$artifacts_dir/test-command.txt")
    fi

    # Get template from state file
    local template
    template=$(sed -n 's/^template: *//p' "$state_file" | head -1 || echo "standard")

    # Get commit count
    local commit_count=1
    if type repo_memory_dir &>/dev/null 2>&1; then
        commit_count=$(git rev-list --count HEAD 2>/dev/null || echo 1)
    fi

    # Get duration from state if available
    local duration_s=0
    if sed -n 's/^duration_s: *//p' "$state_file" | head -1 &>/dev/null; then
        duration_s=$(sed -n 's/^duration_s: *//p' "$state_file" | head -1 || echo "0")
    fi

    # Get cost from state if available
    local cost_usd="0"
    if sed -n 's/^cost_usd: *//p' "$state_file" | head -1 &>/dev/null; then
        cost_usd=$(sed -n 's/^cost_usd: *//p' "$state_file" | head -1 || echo "0")
    fi

    # Build approach from artifacts - collect recent loop iterations
    local approach=""
    if [[ -d "$artifacts_dir/.claude/loop-logs" ]]; then
        approach=$(find "$artifacts_dir/.claude/loop-logs" -name "iteration-*.log" -type f | sort -V | tail -3 | xargs tail -20 2>/dev/null | head -100 | sed 's/^/loop: /' || echo "")
    fi
    approach="${approach:0:1000}"  # Cap at 1KB

    # Generate pattern ID (hash of goal + issue_type + file_patterns)
    local pattern_id
    pattern_id=$(echo -n "$goal:$issue_type:$file_patterns" | shasum -a 256 | cut -d' ' -f1)

    # Check for duplicate
    local existing_idx
    existing_idx=$(jq --arg id "$pattern_id" \
        '[.patterns[]] | to_entries | map(select(.value.id == $id)) | .[0].key // -1' \
        "$patterns_file" 2>/dev/null || echo "-1")

    (
        # Acquire lock for atomic write
        if command -v flock >/dev/null 2>&1; then
            flock -w 10 200 2>/dev/null || { warn "Pattern lock timeout"; return 1; }
        fi

        local tmp_file
        tmp_file=$(mktemp "${patterns_file}.tmp.XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$tmp_file'" EXIT

        if [[ "$existing_idx" != "-1" && "$existing_idx" != "null" ]]; then
            # Deduplicate: increment seen_count
            jq --argjson idx "$existing_idx" \
               --arg ts "$(now_iso)" \
               '.patterns[$idx].seen_count += 1 | .patterns[$idx].captured_at = $ts' \
               "$patterns_file" > "$tmp_file" && mv "$tmp_file" "$patterns_file" || rm -f "$tmp_file"
            info "Pattern capture: deduplicated (pattern_id=$pattern_id)"
        else
            # Add new pattern - all arguments passed to final jq as strings
            jq --arg id "$pattern_id" \
               --arg goal "$goal" \
               --arg type "$issue_type" \
               --arg complexity "$complexity" \
               --arg approach "$approach" \
               --arg iterations "$iterations" \
               --arg duration_s "$duration_s" \
               --arg files_json "$files_changed_json" \
               --arg file_patterns "$file_patterns" \
               --arg test_strategy "$test_strategy" \
               --arg template "$template" \
               --arg commit_count "$commit_count" \
               --arg cost_usd "$cost_usd" \
               --arg ts "$(now_iso)" \
               '.patterns += [{
                    id: $id,
                    goal: $goal,
                    issue_type: $type,
                    complexity: ($complexity | tonumber),
                    approach: $approach,
                    iterations: ($iterations | tonumber),
                    duration_s: ($duration_s | tonumber),
                    files_changed: ($files_json | fromjson? // []),
                    file_patterns: $file_patterns,
                    test_strategy: $test_strategy,
                    template: $template,
                    commit_count: ($commit_count | tonumber),
                    cost_usd: $cost_usd,
                    captured_at: $ts,
                    seen_count: 1,
                    injection_count: 0,
                    success_after_injection: 0
                }] |
                .patterns = (.patterns | sort_by(.captured_at) | reverse | .[:200])' \
               "$patterns_file" > "$tmp_file" && mv "$tmp_file" "$patterns_file" || rm -f "$tmp_file"
            success "Pattern captured (goal=$goal, iterations=$iterations)"
        fi
    ) 200>"${patterns_file}.lock"

    emit_event "pattern.captured" "goal=${goal:0:50}" "type=$issue_type" "iterations=$iterations"
}

# success_pattern_match <goal> <issue_type> <complexity> [max_results] [repo_memory_dir]
# Returns top N matching patterns as JSON array, scored by relevance.
# Pure jq — no Claude call.
success_pattern_match() {
    local goal="${1:-}"
    local issue_type="${2:-feature}"
    local complexity="${3:-50}"
    local max_results="${4:-3}"
    local mem_dir="${5:-}"

    [[ -z "$goal" ]] && { echo "[]"; return 0; }

    if [[ -z "$mem_dir" ]] && type repo_memory_dir &>/dev/null 2>&1; then
        mem_dir="$(repo_memory_dir)"
    fi
    mem_dir="${mem_dir:-$MEMORY_ROOT/unknown}"

    local patterns_file="$mem_dir/success-patterns.json"
    [[ ! -f "$patterns_file" ]] && { echo "[]"; return 0; }

    # Simple scoring: prefer type match, recent patterns, and high success rate
    # Avoid complex date parsing that can fail
    jq --arg goal "$goal" \
       --arg type "$issue_type" \
       --argjson max_res "$max_results" \
       '.patterns |
       map(. as $p |
           {
               pattern: $p,
               score: (
                   (if (.issue_type // "feature") == $type then 50 else 20 end) +
                   (if ((.goal // "") | ascii_downcase) | contains($goal | ascii_downcase) then 30 else 0 end) +
                   (if ((.seen_count // 0) | tonumber) > 2 then 20 else 0 end)
               ) | tonumber
           }
       ) |
       sort_by(.score | tonumber) | reverse |
       map(select(.score > 0)) |
       .[0:$max_res] |
       map(.pattern)' \
       "$patterns_file" 2>/dev/null || echo "[]"
}

# success_pattern_inject <goal> <issue_type> <complexity> [repo_memory_dir]
# Returns markdown text for prompt injection (max 2KB).
success_pattern_inject() {
    local goal="${1:-}"
    local issue_type="${2:-feature}"
    local complexity="${3:-50}"
    local mem_dir="${4:-}"

    [[ -z "$goal" ]] && { echo ""; return 0; }

    if [[ -z "$mem_dir" ]] && type repo_memory_dir &>/dev/null 2>&1; then
        mem_dir="$(repo_memory_dir)"
    fi
    mem_dir="${mem_dir:-$MEMORY_ROOT/unknown}"

    # Check if A/B testing is enabled and this is control group
    local ab_ratio="0"
    if [[ -n "${REPO_DIR:-}" && -f "${REPO_DIR}/.claude/daemon-config.json" ]]; then
        ab_ratio=$(jq -r '.intelligence.ab_test_ratio // 0' "${REPO_DIR}/.claude/daemon-config.json" 2>/dev/null || echo "0")
    fi

    local ab_arm="treatment"
    if [[ "$ab_ratio" != "0" && "$ab_ratio" != "0.0" ]] && [[ -n "${ISSUE_NUMBER:-}" ]]; then
        if ! success_pattern_ab_assign "$ISSUE_NUMBER" | grep -q "treatment"; then
            # Control group gets no injection
            echo ""
            return 0
        fi
    fi

    # Get matching patterns
    local matches
    matches=$(success_pattern_match "$goal" "$issue_type" "$complexity" 3 "$mem_dir" 2>/dev/null || echo "[]")

    if [[ -z "$matches" || "$matches" == "[]" ]]; then
        echo ""
        return 0
    fi

    # Build markdown injection
    local output=""
    output+="## Success Patterns for Similar Issues"$'\n'
    output+="Similar issues succeeded with:"$'\n'

    echo "$matches" | jq -r '.[] | "- \(.issue_type | ascii_upcase): \(.goal) (\(.iterations) iterations, \(.files_changed | length) files)\n  Approach: \(.approach | if length > 200 then .[0:200] + "..." else . end)\n  Files: \(.file_patterns)\n  Test strategy: \(.test_strategy)\n"' 2>/dev/null | head -50 >> /dev/null

    # Simple text output (fallback if jq fails)
    echo "$matches" | while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            echo "- Pattern: $(echo "$line" | jq -r '.goal // ""')"
        fi
    done

    echo "$output"
}

# success_pattern_export <output_path> [repo_memory_dir]
# Copies success-patterns.json to repo-local .claude/memory path.
success_pattern_export() {
    local output_dir="${1:-.claude/memory/success-patterns}"
    local mem_dir="${2:-}"

    if [[ -z "$mem_dir" ]] && type repo_memory_dir &>/dev/null 2>&1; then
        mem_dir="$(repo_memory_dir)"
    fi
    mem_dir="${mem_dir:-$MEMORY_ROOT/unknown}"

    mkdir -p "$(dirname "$output_dir")"
    local src="$mem_dir/success-patterns.json"

    [[ ! -f "$src" ]] && { echo "No success patterns to export"; return 0; }

    if cp "$src" "$output_dir" 2>/dev/null; then
        success "Exported $(jq '.patterns | length' "$output_dir" 2>/dev/null || echo "?") patterns to $output_dir"
    else
        warn "Failed to export success patterns"
        return 1
    fi
}

# ─── A/B Testing Functions ──────────────────────────────────────────────────

# success_pattern_ab_assign <issue_id>
# Returns "treatment" or "control".
# Deterministic: same issue always gets same arm within a week.
success_pattern_ab_assign() {
    local issue_id="${1:-}"
    [[ -z "$issue_id" ]] && { echo "treatment"; return 0; }

    # Read ratio from config
    local ab_ratio="0"
    if [[ -n "${REPO_DIR:-}" && -f "${REPO_DIR}/.claude/daemon-config.json" ]]; then
        ab_ratio=$(jq -r '.intelligence.ab_test_ratio // 0' "${REPO_DIR}/.claude/daemon-config.json" 2>/dev/null || echo "0")
    fi

    [[ "$ab_ratio" == "0" || "$ab_ratio" == "0.0" ]] && { echo "treatment"; return 0; }

    # Deterministic hash: issue_id + YYYY-WW (week-based stratification)
    local week_key
    week_key=$(date -u +%Y-%V)
    local hash_input="${issue_id}:${week_key}"
    local hash_val
    hash_val=$(echo -n "$hash_input" | shasum | cut -c1-8)
    local hash_num=$((16#${hash_val:0:8} % 100))

    local threshold
    threshold=$(echo "$ab_ratio * 100" | bc | cut -d. -f1)

    if [[ "$hash_num" -lt "$threshold" ]]; then
        echo "treatment"
    else
        echo "control"
    fi
}

# success_pattern_ab_record_outcome <issue_id> <arm> <success:bool> <iterations>
# Records pipeline outcome for A/B analysis.
success_pattern_ab_record_outcome() {
    local issue_id="${1:-}"
    local arm="${2:-control}"
    local success="${3:-false}"
    local iterations="${4:-1}"

    [[ -z "$issue_id" ]] && return 0

    mkdir -p "${HOME}/.shipwright/optimization"
    local outcomes_file="${HOME}/.shipwright/optimization/ab-outcomes.jsonl"

    # Append outcome record (one JSON per line)
    local outcome
    outcome=$(jq -n \
        --arg id "$issue_id" \
        --arg arm "$arm" \
        --arg success "$success" \
        --argjson iters "$iterations" \
        --arg ts "$(now_iso)" \
        '{issue_id: $id, arm: $arm, success: ($success == "true"), iterations: $iters, timestamp: $ts}')

    echo "$outcome" >> "$outcomes_file"
    emit_event "ab.outcome" "issue=$issue_id" "arm=$arm" "success=$success"
}

# success_pattern_ab_report
# Reads ab-outcomes.jsonl, calculates per-arm success rates.
# Returns JSON: { control_builds, treatment_builds, control_success_rate, treatment_success_rate, effect_size }
success_pattern_ab_report() {
    local outcomes_file="${HOME}/.shipwright/optimization/ab-outcomes.jsonl"
    [[ ! -f "$outcomes_file" ]] && { echo '{"control_builds":0,"treatment_builds":0,"control_success_rate":0,"treatment_success_rate":0,"effect_size":0}'; return 0; }

    jq -s '
        group_by(.arm) |
        map({
            arm: .[0].arm,
            builds: length,
            successes: map(select(.success) | .success) | length
        }) |
        reduce .[] as $group (
            {control_builds: 0, control_successes: 0, treatment_builds: 0, treatment_successes: 0};
            if $group.arm == "control" then
                .control_builds = $group.builds | .control_successes = $group.successes
            else
                .treatment_builds = $group.builds | .treatment_successes = $group.successes
            end
        ) |
        (if .control_builds > 0 then (.control_successes / .control_builds) else 0 end) as $cr |
        (if .treatment_builds > 0 then (.treatment_successes / .treatment_builds) else 0 end) as $tr |
        {
            control_builds: .control_builds,
            treatment_builds: .treatment_builds,
            control_success_rate: ($cr * 100 | round / 100),
            treatment_success_rate: ($tr * 100 | round / 100),
            effect_size: (($tr - $cr) * 100 | round / 100)
        }
    ' "$outcomes_file" 2>/dev/null || echo '{"control_builds":0,"treatment_builds":0,"control_success_rate":0,"treatment_success_rate":0,"effect_size":0}'
}

# ─── Effectiveness Tracking ──────────────────────────────────────────────────

# success_pattern_record_injection <pattern_id> <pipeline_id>
# Increments injection_count on the pattern.
success_pattern_record_injection() {
    local pattern_id="${1:-}"
    local pipeline_id="${2:-}"
    [[ -z "$pattern_id" ]] && return 0

    local mem_dir
    if type repo_memory_dir &>/dev/null 2>&1; then
        mem_dir="$(repo_memory_dir)"
    else
        mem_dir="$MEMORY_ROOT/unknown"
    fi

    local patterns_file="$mem_dir/success-patterns.json"
    [[ ! -f "$patterns_file" ]] && return 0

    (
        if command -v flock >/dev/null 2>&1; then
            flock -w 10 200 2>/dev/null || return 1
        fi

        local tmp_file
        tmp_file=$(mktemp "${patterns_file}.tmp.XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$tmp_file'" EXIT

        jq --arg id "$pattern_id" \
           '.patterns |= map(if .id == $id then .injection_count += 1 else . end)' \
           "$patterns_file" > "$tmp_file" && mv "$tmp_file" "$patterns_file" || rm -f "$tmp_file"
    ) 200>"${patterns_file}.lock"
}

# success_pattern_record_outcome <pattern_id> <success:bool>
# Records whether injection led to success.
success_pattern_record_outcome() {
    local pattern_id="${1:-}"
    local success="${2:-false}"
    [[ -z "$pattern_id" ]] && return 0

    local mem_dir
    if type repo_memory_dir &>/dev/null 2>&1; then
        mem_dir="$(repo_memory_dir)"
    else
        mem_dir="$MEMORY_ROOT/unknown"
    fi

    local patterns_file="$mem_dir/success-patterns.json"
    [[ ! -f "$patterns_file" ]] && return 0

    (
        if command -v flock >/dev/null 2>&1; then
            flock -w 10 200 2>/dev/null || return 1
        fi

        local tmp_file
        tmp_file=$(mktemp "${patterns_file}.tmp.XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$tmp_file'" EXIT

        if [[ "$success" == "true" ]]; then
            jq --arg id "$pattern_id" \
               '.patterns |= map(if .id == $id then .success_after_injection += 1 else . end)' \
               "$patterns_file" > "$tmp_file" && mv "$tmp_file" "$patterns_file" || rm -f "$tmp_file"
        fi
    ) 200>"${patterns_file}.lock"
}

# Module loaded successfully
success "Success patterns module loaded"
