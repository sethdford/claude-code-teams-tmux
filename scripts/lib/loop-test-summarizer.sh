#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  loop-test-summarizer — Intelligent test output summarization           ║
# ║                                                                         ║
# ║  Processes raw test output, clusters related failures, categorizes      ║
# ║  and prioritizes errors, and produces a focused summary for the         ║
# ║  next build loop iteration prompt.                                      ║
# ║                                                                         ║
# ║  Priority order: syntax > runtime > type > dependency > assertion       ║
# ║  Clusters by: file path + normalized error pattern                      ║
# ║  Output: JSON summary + focused prompt text                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Module guard
[[ -n "${_MODULE_LOOP_TEST_SUMMARIZER_LOADED:-}" ]] && return 0
_MODULE_LOOP_TEST_SUMMARIZER_LOADED=1

VERSION="3.2.4"

# ─── Constants ────────────────────────────────────────────────────────────────

# Priority weights (higher = fix first)
_LTS_PRIORITY_SYNTAX=100
_LTS_PRIORITY_RUNTIME=80
_LTS_PRIORITY_TYPE=70
_LTS_PRIORITY_DEPENDENCY=60
_LTS_PRIORITY_ASSERTION=40
_LTS_PRIORITY_INTEGRATION=30
_LTS_PRIORITY_UNKNOWN=20

# Max clusters to show in focused prompt
_LTS_MAX_CLUSTERS=5

# ─── Error Extraction ────────────────────────────────────────────────────────

# Extract error blocks from raw test output
# Handles: vitest/jest, pytest, go test, bash test harness, generic
# Input: raw test output (stdin or $1)
# Output: one error block per line (newlines within block replaced with ␤)
_lts_extract_error_blocks() {
    local input="${1:-}"
    if [[ -z "$input" ]]; then
        input="$(cat)"
    fi
    [[ -z "$input" ]] && return 0

    # Strip ANSI codes
    local cleaned
    cleaned=$(printf '%s' "$input" | sed 's/\x1b\[[0-9;]*m//g' 2>/dev/null || printf '%s' "$input")

    local in_block=false
    local block=""
    local block_count=0

    while IFS= read -r line; do
        # Skip empty lines outside blocks
        if [[ -z "$line" ]] && [[ "$in_block" != "true" ]]; then
            continue
        fi

        # Detect error block start patterns
        local is_start=false

        # vitest/jest: FAIL, ✗, ✕, ×, AssertionError, expect(
        if [[ $line =~ ^[[:space:]]*(FAIL|✗|✕|×|Error:|AssertionError) ]] || \
           [[ $line =~ (TypeError|SyntaxError|ReferenceError|RangeError) ]] || \
           [[ $line =~ ^[[:space:]]*expect\( ]] || \
           [[ $line =~ (FAILED|FAIL:|Error:) ]]; then
            is_start=true
        fi

        # pytest: FAILED, ERROR, E   (pytest error lines start with E + spaces)
        if [[ $line =~ ^(FAILED|ERROR|E[[:space:]]+) ]]; then
            is_start=true
        fi

        # go test: --- FAIL, panic:
        if [[ $line =~ ^---[[:space:]]+FAIL ]] || [[ $line =~ ^panic: ]]; then
            is_start=true
        fi

        # bash test harness: FAIL:, ✗
        if [[ $line =~ ^[[:space:]]*(FAIL:|FAIL[[:space:]]) ]]; then
            is_start=true
        fi

        # Generic error patterns
        if [[ $line =~ ^[[:space:]]*(error|Error|ERROR)\[? ]] || \
           [[ $line =~ (fatal error|compilation failed|build failed) ]]; then
            is_start=true
        fi

        if [[ "$is_start" == "true" ]]; then
            # Emit previous block if exists
            if [[ -n "$block" ]]; then
                printf '%s\n' "$block"
                block_count=$((block_count + 1))
            fi
            in_block=true
            block="$line"
        elif [[ "$in_block" == "true" ]]; then
            # Stack trace continuation: indented lines, "at " lines, "Caused by"
            if [[ $line =~ ^[[:space:]]+(at[[:space:]]|in[[:space:]]|from[[:space:]]|\^|~|Caused[[:space:]]by) ]] || \
               [[ $line =~ ^[[:space:]]{2,} ]] || \
               [[ $line =~ ^[[:space:]]*(Expected|Received|Difference|got|want) ]]; then
                block="${block}␤${line}"
            else
                # End of block
                if [[ -n "$block" ]]; then
                    printf '%s\n' "$block"
                    block_count=$((block_count + 1))
                fi
                in_block=false
                block=""

                # Check if this line starts a new block
                if [[ $line =~ (Error|FAIL|panic|FAILED) ]]; then
                    in_block=true
                    block="$line"
                fi
            fi
        fi

        # Safety: cap at 200 blocks
        if [[ $block_count -ge 200 ]]; then
            break
        fi
    done <<< "$cleaned"

    # Emit final block
    if [[ -n "$block" ]]; then
        printf '%s\n' "$block"
    fi
}

# ─── Categorization ──────────────────────────────────────────────────────────

# Categorize an error block into one of: syntax, type, assertion, runtime,
# dependency, integration, unknown
# Input: error block text
# Output: category string
_lts_categorize_error() {
    local error_block="$1"

    if [[ $error_block =~ (SyntaxError|parse[[:space:]]error|unexpected[[:space:]]token|invalid[[:space:]]syntax|unterminated|unexpected[[:space:]]end) ]]; then
        echo "syntax"
    elif [[ $error_block =~ (TypeError|type[[:space:]]mismatch|is[[:space:]]not[[:space:]]a[[:space:]]function|cannot[[:space:]]read[[:space:]]propert|undefined[[:space:]]is[[:space:]]not) ]]; then
        echo "type"
    elif [[ $error_block =~ (segfault|Segmentation[[:space:]]fault|OOM|out[[:space:]]of[[:space:]]memory|SIGKILL|signal[[:space:]]9|Killed|panic:|fatal[[:space:]]error|stack[[:space:]]overflow) ]]; then
        echo "runtime"
    elif [[ $error_block =~ (module[[:space:]]not[[:space:]]found|cannot[[:space:]]find[[:space:]]module|import[[:space:]]error|ImportError|no[[:space:]]such[[:space:]]package|ENOENT|ModuleNotFoundError|require\(\)|Cannot[[:space:]]find) ]]; then
        echo "dependency"
    elif [[ $error_block =~ (AssertionError|assert|expect|toEqual|toBe|toMatch|toThrow|should[[:space:]]|FAILED|test.*failed|Expected|Received|got:|want:) ]]; then
        echo "assertion"
    elif [[ $error_block =~ (ECONNREFUSED|ECONNRESET|timeout|timed[[:space:]]out|connection|socket|network|ETIMEDOUT|fetch[[:space:]]failed|502|503|504) ]]; then
        echo "integration"
    else
        echo "unknown"
    fi
}

# Get priority score for a category
_lts_category_priority() {
    local category="$1"
    case "$category" in
        syntax)      echo "$_LTS_PRIORITY_SYNTAX" ;;
        runtime)     echo "$_LTS_PRIORITY_RUNTIME" ;;
        type)        echo "$_LTS_PRIORITY_TYPE" ;;
        dependency)  echo "$_LTS_PRIORITY_DEPENDENCY" ;;
        assertion)   echo "$_LTS_PRIORITY_ASSERTION" ;;
        integration) echo "$_LTS_PRIORITY_INTEGRATION" ;;
        *)           echo "$_LTS_PRIORITY_UNKNOWN" ;;
    esac
}

# ─── Clustering ───────────────────────────────────────────────────────────────

# Extract file path from error block (first match)
_lts_extract_file() {
    local block="$1"
    local file=""

    # Pattern: file.ext:line:col or file.ext:line
    if [[ $block =~ ([a-zA-Z0-9_./-]+\.(ts|js|py|go|sh|rs|java|rb|tsx|jsx|mjs|cjs)):[0-9]+ ]]; then
        file="${BASH_REMATCH[1]}"
    # Pattern: File "path", line N (Python)
    elif [[ $block =~ File[[:space:]]+\"([^\"]+)\" ]]; then
        file="${BASH_REMATCH[1]}"
    # Pattern: at path/file.ext
    elif [[ $block =~ at[[:space:]]+([a-zA-Z0-9_./-]+\.(ts|js|py|go|sh|rs|java|rb|tsx|jsx))(\:|[[:space:]]) ]]; then
        file="${BASH_REMATCH[1]}"
    fi

    # Normalize: strip leading ./ and common prefixes
    file="${file#./}"
    echo "$file"
}

# Normalize error pattern for clustering (strip specifics, keep shape)
_lts_normalize_pattern() {
    local block="$1"
    local first_line
    first_line=$(echo "$block" | head -1)
    # Remove line numbers, specific values, quotes content
    local normalized
    normalized=$(printf '%s' "$first_line" | \
        sed -e 's/:[0-9]*//g' \
            -e 's/"[^"]*"/STRING/g' \
            -e "s/'[^']*'/STRING/g" \
            -e 's/[0-9]\{1,\}/N/g' \
            -e 's/  */ /g' \
            -e 's/^[[:space:]]*//' 2>/dev/null || printf '%s' "$first_line")
    echo "$normalized"
}

# Cluster error blocks by file + normalized pattern
# Input: newline-separated error blocks
# Output: JSON array of clusters
_lts_cluster_errors() {
    local error_blocks="$1"
    [[ -z "$error_blocks" ]] && echo "[]" && return 0

    # Need jq for clustering
    if ! command -v jq >/dev/null 2>&1; then
        # Fallback: no clustering, just list errors
        local count=0
        local items="[]"
        while IFS= read -r block; do
            [[ -z "$block" ]] && continue
            count=$((count + 1))
            local cat
            cat=$(_lts_categorize_error "$block")
            local pri
            pri=$(_lts_category_priority "$cat")
            local file
            file=$(_lts_extract_file "$block")
            local first_line
            first_line=$(printf '%s' "$block" | sed 's/␤.*//' | head -1)
            items=$(printf '%s' "$items" | jq --arg c "$cat" --argjson p "$pri" \
                --arg f "$file" --arg s "$first_line" \
                '. + [{"category":$c,"priority":$p,"file":$f,"sample":$s,"count":1}]' 2>/dev/null || echo "$items")
        done <<< "$error_blocks"
        echo "$items"
        return 0
    fi

    # Build clusters: key = file + normalized_pattern
    local clusters_json="[]"
    local seen_keys=""

    while IFS= read -r block; do
        [[ -z "$block" ]] && continue

        local category
        category=$(_lts_categorize_error "$block")
        local priority
        priority=$(_lts_category_priority "$category")
        local file
        file=$(_lts_extract_file "$block")
        local pattern
        pattern=$(_lts_normalize_pattern "$block")
        local first_line
        first_line=$(printf '%s' "$block" | sed 's/␤.*//' | head -1)

        # Cluster key: file + category (keeps related errors together)
        local cluster_key="${file}::${category}"

        # Check if we've seen this cluster
        local found=false
        if echo "$seen_keys" | grep -qF "$cluster_key" 2>/dev/null; then
            found=true
        fi

        if [[ "$found" == "true" ]]; then
            # Increment count for existing cluster
            clusters_json=$(printf '%s' "$clusters_json" | jq \
                --arg key "$cluster_key" \
                'map(if .cluster_key == $key then .count += 1 else . end)' 2>/dev/null || echo "$clusters_json")
        else
            # Add new cluster
            seen_keys="${seen_keys}${cluster_key}"$'\n'
            clusters_json=$(printf '%s' "$clusters_json" | jq \
                --arg key "$cluster_key" \
                --arg cat "$category" \
                --argjson pri "$priority" \
                --arg file "$file" \
                --arg sample "$first_line" \
                --arg pat "$pattern" \
                '. + [{
                    "cluster_key": $key,
                    "category": $cat,
                    "priority": $pri,
                    "file": $file,
                    "sample": $sample,
                    "pattern": $pat,
                    "count": 1
                }]' 2>/dev/null || echo "$clusters_json")
        fi
    done <<< "$error_blocks"

    echo "$clusters_json"
}

# ─── Priority Sorting ────────────────────────────────────────────────────────

# Sort clusters by priority (descending), then by count (descending)
# Input: JSON array of clusters
# Output: sorted JSON array
_lts_prioritize_clusters() {
    local clusters="$1"
    [[ -z "$clusters" ]] && echo "[]" && return 0

    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$clusters" | jq 'sort_by(-.priority, -.count)' 2>/dev/null || echo "$clusters"
    else
        echo "$clusters"
    fi
}

# ─── Focused Prompt Generation ───────────────────────────────────────────────

# Generate a focused, actionable prompt section from prioritized clusters
# Input: sorted JSON array of clusters, total error count
# Output: multi-line text suitable for prompt injection
_lts_generate_focused_prompt() {
    local clusters="$1"
    local total_errors="${2:-0}"
    local max_clusters="${3:-$_LTS_MAX_CLUSTERS}"

    [[ -z "$clusters" ]] && return 0

    if ! command -v jq >/dev/null 2>&1; then
        echo "## Test Failures (${total_errors} errors)"
        echo "Fix the test failures shown in the test output above."
        return 0
    fi

    local cluster_count
    cluster_count=$(printf '%s' "$clusters" | jq 'length' 2>/dev/null || echo "0")
    [[ "$cluster_count" == "0" ]] && return 0

    local shown=$max_clusters
    if [[ "$cluster_count" -lt "$shown" ]]; then
        shown=$cluster_count
    fi

    local output=""
    output+="## Intelligent Error Summary (${total_errors} errors in ${cluster_count} clusters)"
    output+=$'\n'
    output+=$'\n'
    output+="Fix in this order (highest priority first):"
    output+=$'\n'

    local i=0
    while [[ $i -lt $shown ]]; do
        local cat count file sample pri
        cat=$(printf '%s' "$clusters" | jq -r ".[$i].category" 2>/dev/null)
        count=$(printf '%s' "$clusters" | jq -r ".[$i].count" 2>/dev/null)
        file=$(printf '%s' "$clusters" | jq -r ".[$i].file // \"(unknown)\"" 2>/dev/null)
        sample=$(printf '%s' "$clusters" | jq -r ".[$i].sample" 2>/dev/null)
        pri=$(printf '%s' "$clusters" | jq -r ".[$i].priority" 2>/dev/null)

        local label
        case "$cat" in
            syntax)      label="SYNTAX ERROR" ;;
            runtime)     label="RUNTIME ERROR" ;;
            type)        label="TYPE ERROR" ;;
            dependency)  label="MISSING DEPENDENCY" ;;
            assertion)   label="TEST ASSERTION" ;;
            integration) label="INTEGRATION ERROR" ;;
            *)           label="ERROR" ;;
        esac

        local count_suffix=""
        if [[ "$count" -gt 1 ]]; then
            count_suffix=" (${count} failures)"
        fi

        output+=$'\n'
        output+="### ${i+1}. [${label}] ${file}${count_suffix}"
        # Fix: i+1 doesn't work in all bash versions
        local display_num=$((i + 1))
        # Rewrite the line with correct numbering
        output=$(printf '%s' "$output" | sed "s/### ${i+1}\./### ${display_num}./" 2>/dev/null || echo "$output")
        output+=$'\n'
        output+="   ${sample}"
        output+=$'\n'

        # Add fix suggestion based on category
        case "$cat" in
            syntax)
                output+="   → Check for typos, missing brackets/parens, or malformed expressions"
                output+=$'\n'
                ;;
            runtime)
                output+="   → Check for null/undefined access, infinite loops, or resource exhaustion"
                output+=$'\n'
                ;;
            type)
                output+="   → Check argument types, return types, and interface conformance"
                output+=$'\n'
                ;;
            dependency)
                output+="   → Check imports, install missing packages, or fix module paths"
                output+=$'\n'
                ;;
            assertion)
                output+="   → Review the expected vs actual values; fix the implementation (not the test)"
                output+=$'\n'
                ;;
            integration)
                output+="   → Check service connectivity, API endpoints, or mock configuration"
                output+=$'\n'
                ;;
        esac

        i=$((i + 1))
    done

    # Remainder notice
    local remaining=$((cluster_count - shown))
    if [[ $remaining -gt 0 ]]; then
        output+=$'\n'
        output+="... and ${remaining} more error cluster(s). Fix the above first — remaining errors may resolve as side effects."
        output+=$'\n'
    fi

    printf '%s' "$output"
}

# ─── Main Entry Point ────────────────────────────────────────────────────────

# Summarize test output into a focused, prioritized error summary
# Input: raw test output (string), output directory
# Output: writes test-summary.json to output dir, prints focused prompt text
#
# Usage:
#   summarize_test_output "$raw_output" "$LOG_DIR" "$ITERATION"
#   # or read from file:
#   summarize_test_output "$(cat test.log)" "$LOG_DIR" 3
summarize_test_output() {
    local raw_output="$1"
    local output_dir="${2:-.}"
    local iteration="${3:-0}"

    if [[ -z "$raw_output" ]]; then
        rm -f "$output_dir/test-summary.json" 2>/dev/null || true
        return 0
    fi

    # Step 1: Extract error blocks
    local error_blocks
    error_blocks=$(_lts_extract_error_blocks "$raw_output")

    if [[ -z "$error_blocks" ]]; then
        # No errors found — clean up any previous summary
        rm -f "$output_dir/test-summary.json" 2>/dev/null || true
        return 0
    fi

    # Count total errors
    local total_errors=0
    while IFS= read -r _block; do
        [[ -n "$_block" ]] && total_errors=$((total_errors + 1))
    done <<< "$error_blocks"

    # Step 2: Cluster errors
    local clusters
    clusters=$(_lts_cluster_errors "$error_blocks")

    # Step 3: Prioritize clusters
    local sorted_clusters
    sorted_clusters=$(_lts_prioritize_clusters "$clusters")

    # Step 4: Generate focused prompt
    local focused_prompt
    focused_prompt=$(_lts_generate_focused_prompt "$sorted_clusters" "$total_errors")

    # Step 5: Write JSON summary (atomic write)
    if command -v jq >/dev/null 2>&1; then
        local summary_file="$output_dir/test-summary.json"
        local tmp_file="${summary_file}.tmp.$$"

        jq -n \
            --argjson iteration "$iteration" \
            --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --argjson total_errors "$total_errors" \
            --argjson clusters "$sorted_clusters" \
            --arg focused_prompt "$focused_prompt" \
            '{
                iteration: $iteration,
                timestamp: $timestamp,
                total_errors: $total_errors,
                cluster_count: ($clusters | length),
                clusters: $clusters,
                focused_prompt: $focused_prompt
            }' > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$summary_file" || rm -f "$tmp_file" 2>/dev/null
    fi

    # Output focused prompt to stdout
    printf '%s\n' "$focused_prompt"
}
