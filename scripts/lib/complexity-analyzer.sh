#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  complexity-analyzer.sh — Script Complexity Analysis Library             ║
# ║                                                                          ║
# ║  Metrics: LOC, cyclomatic complexity, nesting depth, function count      ║
# ║  Anti-pattern detection for Common Pitfalls from CLAUDE.md               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
[[ -n "${_COMPLEXITY_ANALYZER_LOADED:-}" ]] && return 0
_COMPLEXITY_ANALYZER_LOADED=1

# ─── Calculate basic metrics for a script ─────────────────────────────────
# Output: JSON object with loc, functions, avg_function_length
complexity_calculate_metrics() {
    local script_path="$1"

    if [[ ! -f "$script_path" ]]; then
        return 1
    fi

    local total_lines=0
    total_lines=$(wc -l < "$script_path" 2>/dev/null || true)
    total_lines="${total_lines# }"
    total_lines="${total_lines%% *}"
    total_lines="${total_lines:-0}"

    local comment_lines=0
    comment_lines=$(grep -c '^\s*#' "$script_path" 2>/dev/null || true)
    comment_lines="${comment_lines:-0}"

    local blank_lines=0
    blank_lines=$(grep -c '^\s*$' "$script_path" 2>/dev/null || true)
    blank_lines="${blank_lines:-0}"

    local code_lines=$((total_lines - comment_lines - blank_lines))
    [[ $code_lines -lt 0 ]] && code_lines=0

    local function_count=0
    function_count=$(grep -c '^[a-zA-Z_][a-zA-Z0-9_]*()' "$script_path" 2>/dev/null || true)
    function_count="${function_count:-0}"

    local avg_func_length=0
    if [[ $function_count -gt 0 ]]; then
        avg_func_length=$((code_lines / function_count))
    fi

    jq -n \
        --argjson total "$total_lines" \
        --argjson code "$code_lines" \
        --argjson comments "$comment_lines" \
        --argjson blanks "$blank_lines" \
        --argjson functions "$function_count" \
        --argjson avg_len "$avg_func_length" \
        '{
            total_lines: $total,
            code_lines: $code,
            comment_lines: $comments,
            blank_lines: $blanks,
            function_count: $functions,
            avg_function_length: $avg_len
        }'
}

# ─── Estimate cyclomatic complexity (count decision points) ───────────────
# Counts: if, elif, case, &&, ||, for, while, until
# Base: 1 (single path through)
complexity_estimate_cyclomatic() {
    local script_path="$1"

    if [[ ! -f "$script_path" ]]; then
        echo "0"
        return 1
    fi

    local if_count=0 elif_count=0 case_count=0 and_count=0 or_count=0 loop_count=0

    if_count=$(grep -c '\bif\b' "$script_path" 2>/dev/null || true)
    if_count="${if_count:-0}"
    elif_count=$(grep -c '\belif\b' "$script_path" 2>/dev/null || true)
    elif_count="${elif_count:-0}"
    case_count=$(grep -c '\bcase\b' "$script_path" 2>/dev/null || true)
    case_count="${case_count:-0}"
    and_count=$(grep -c '&&' "$script_path" 2>/dev/null || true)
    and_count="${and_count:-0}"
    or_count=$(grep -c '||' "$script_path" 2>/dev/null || true)
    or_count="${or_count:-0}"
    loop_count=$(grep -Ec '\b(for|while|until)\b' "$script_path" 2>/dev/null || true)
    loop_count="${loop_count:-0}"

    local complexity=$((1 + if_count + elif_count + case_count + and_count + or_count + loop_count))
    echo "$complexity"
}

# ─── Calculate maximum nesting depth ──────────────────────────────────────
# Tracks do/done, if/fi, case/esac keyword pairs
complexity_calculate_nesting_depth() {
    local script_path="$1"

    if [[ ! -f "$script_path" ]]; then
        echo "0"
        return 1
    fi

    local max_depth=0
    local current_depth=0
    local in_heredoc=""

    while IFS= read -r line; do
        # Skip heredoc content
        if [[ -n "$in_heredoc" ]]; then
            if [[ "$line" =~ ^${in_heredoc}$ ]]; then
                in_heredoc=""
            fi
            continue
        fi

        # Detect heredoc start
        if [[ "$line" =~ \<\<-?[[:space:]]*[\'\"]?([A-Za-z_]+)[\'\"]? ]]; then
            in_heredoc="${BASH_REMATCH[1]}"
            continue
        fi

        # Skip comments and blank lines
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]] && continue

        # Count opening keywords (if, for, while, until, case, do, {)
        if [[ "$trimmed" =~ ^(if|for|while|until|case)[[:space:]] ]] || \
           [[ "$trimmed" =~ [[:space:]](do|then)($|[[:space:]]) ]] || \
           [[ "$trimmed" =~ \{[[:space:]]*$ ]]; then
            current_depth=$((current_depth + 1))
            if [[ $current_depth -gt $max_depth ]]; then
                max_depth=$current_depth
            fi
        fi

        # Count closing keywords (fi, done, esac, })
        if [[ "$trimmed" =~ ^(fi|done|esac)($|[[:space:]]) ]] || \
           [[ "$trimmed" =~ ^\} ]]; then
            current_depth=$((current_depth - 1))
            [[ $current_depth -lt 0 ]] && current_depth=0
        fi
    done < "$script_path"

    echo "$max_depth"
}

# ─── Anti-pattern detection ───────────────────────────────────────────────
# Detects 8 patterns from CLAUDE.md Common Pitfalls
# Output: JSON array of violations with line numbers
complexity_detect_anti_patterns() {
    local script_path="$1"
    local violations="[]"

    if [[ ! -f "$script_path" ]]; then
        echo "[]"
        return 1
    fi

    local script_name
    script_name=$(basename "$script_path")

    # Skip test files for some patterns (they legitimately use different patterns)
    local is_test=false
    [[ "$script_name" == *"-test.sh" ]] && is_test=true

    # Pattern 1: grep -c without || true/echo (double output under pipefail)
    local grep_c_lines=""
    grep_c_lines=$(grep -n 'grep[[:space:]]\+-c\|grep[[:space:]]\+--count' "$script_path" 2>/dev/null || true)
    if [[ -n "$grep_c_lines" ]]; then
        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            local line_num="${match%%:*}"
            local line_content="${match#*:}"
            # Check if the same line has || true or || echo
            if ! echo "$line_content" | grep -q '||' 2>/dev/null; then
                violations=$(echo "$violations" | jq \
                    --arg pattern "grep-c-pipefail" \
                    --arg severity "high" \
                    --argjson line_num "$line_num" \
                    --arg context "${line_content:0:120}" \
                    --arg suggestion "Add || true after grep -c to prevent double output under pipefail" \
                    '. + [{pattern: $pattern, severity: $severity, line_number: $line_num, context: $context, suggestion: $suggestion}]')
            fi
        done <<< "$grep_c_lines"
    fi

    # Pattern 2: cmd | while read (subshell variable loss)
    local pipe_while_lines=""
    pipe_while_lines=$(grep -n '|[[:space:]]*while.*read' "$script_path" 2>/dev/null || true)
    if [[ -n "$pipe_while_lines" ]]; then
        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            local line_num="${match%%:*}"
            local line_content="${match#*:}"
            violations=$(echo "$violations" | jq \
                --arg pattern "pipe-while-read" \
                --arg severity "high" \
                --argjson line_num "$line_num" \
                --arg context "${line_content:0:120}" \
                --arg suggestion "Use: while read; done < <(cmd) to preserve variable state" \
                '. + [{pattern: $pattern, severity: $severity, line_number: $line_num, context: $context, suggestion: $suggestion}]')
        done <<< "$pipe_while_lines"
    fi

    # Pattern 3: json-interpolation (jq with ${var} instead of --arg)
    local json_interp_lines=""
    json_interp_lines=$(grep -n 'jq.*"\$\{' "$script_path" 2>/dev/null || true)
    if [[ -n "$json_interp_lines" ]]; then
        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            local line_num="${match%%:*}"
            local line_content="${match#*:}"
            violations=$(echo "$violations" | jq \
                --arg pattern "json-interpolation" \
                --arg severity "high" \
                --argjson line_num "$line_num" \
                --arg context "${line_content:0:120}" \
                --arg suggestion "Use jq --arg for proper escaping, never string interpolation" \
                '. + [{pattern: $pattern, severity: $severity, line_number: $line_num, context: $context, suggestion: $suggestion}]')
        done <<< "$json_interp_lines"
    fi

    # Pattern 4: bash4-syntax (declare -A, readarray, ${var,,}, ${var^^})
    local bash4_lines=""
    bash4_lines=$(grep -n 'declare[[:space:]]\+-A\|readarray\b' "$script_path" 2>/dev/null || true)
    if [[ -n "$bash4_lines" ]]; then
        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            local line_num="${match%%:*}"
            local line_content="${match#*:}"
            violations=$(echo "$violations" | jq \
                --arg pattern "bash4-syntax" \
                --arg severity "high" \
                --argjson line_num "$line_num" \
                --arg context "${line_content:0:120}" \
                --arg suggestion "Not Bash 3.2 compatible. Use indexed arrays + case statements instead" \
                '. + [{pattern: $pattern, severity: $severity, line_number: $line_num, context: $context, suggestion: $suggestion}]')
        done <<< "$bash4_lines"
    fi

    # Pattern 5: missing-version (no VERSION= at top)
    if [[ "$is_test" == "false" ]]; then
        local has_version=0
        has_version=$(grep -c '^VERSION=' "$script_path" 2>/dev/null || true)
        has_version="${has_version:-0}"
        if [[ $has_version -eq 0 ]]; then
            violations=$(echo "$violations" | jq \
                --arg pattern "missing-version" \
                --arg severity "low" \
                --arg context "No VERSION= variable found at top of script" \
                --arg suggestion "Add VERSION=\"3.2.4\" at the top of the script" \
                '. + [{pattern: $pattern, severity: $severity, line_number: 1, context: $context, suggestion: $suggestion}]')
        fi
    fi

    # Pattern 6: missing-no-github guard (gh API calls without NO_GITHUB check)
    if [[ "$is_test" == "false" ]]; then
        local has_gh_calls=0
        has_gh_calls=$(grep -c '\bgh[[:space:]]\+\(api\|pr\|issue\|run\|release\)' "$script_path" 2>/dev/null || true)
        has_gh_calls="${has_gh_calls:-0}"
        if [[ $has_gh_calls -gt 0 ]]; then
            local has_guard=0
            has_guard=$(grep -c 'NO_GITHUB' "$script_path" 2>/dev/null || true)
            has_guard="${has_guard:-0}"
            if [[ $has_guard -eq 0 ]]; then
                local first_gh_line=""
                first_gh_line=$(grep -n '\bgh[[:space:]]\+\(api\|pr\|issue\|run\|release\)' "$script_path" 2>/dev/null | head -1 || true)
                local gh_line_num=0
                [[ -n "$first_gh_line" ]] && gh_line_num="${first_gh_line%%:*}"
                violations=$(echo "$violations" | jq \
                    --arg pattern "missing-no-github" \
                    --arg severity "medium" \
                    --argjson line_num "${gh_line_num:-0}" \
                    --arg context "GitHub API calls found without NO_GITHUB guard" \
                    --arg suggestion "Check \$NO_GITHUB before GitHub API calls for offline support" \
                    '. + [{pattern: $pattern, severity: $severity, line_number: $line_num, context: $context, suggestion: $suggestion}]')
            fi
        fi
    fi

    # Pattern 7: non-atomic-write (echo/printf > file without tmp+mv)
    # Only flag direct writes to known state files, not general output
    local non_atomic_lines=""
    non_atomic_lines=$(grep -n 'echo\s.*>\s*\$\|printf.*>\s*\$\|cat.*>\s*\$' "$script_path" 2>/dev/null | grep -v '>/dev/null\|>>\|> /dev' || true)
    if [[ -n "$non_atomic_lines" ]] && [[ "$is_test" == "false" ]]; then
        # Only flag if the script does file writes but never uses tmp+mv pattern
        local has_atomic=0
        has_atomic=$(grep -c 'mv.*tmp\|mktemp\|atomic_write' "$script_path" 2>/dev/null || true)
        has_atomic="${has_atomic:-0}"
        if [[ $has_atomic -eq 0 ]]; then
            local first_match
            first_match=$(echo "$non_atomic_lines" | head -1)
            local write_line_num="${first_match%%:*}"
            violations=$(echo "$violations" | jq \
                --arg pattern "non-atomic-write" \
                --arg severity "medium" \
                --argjson line_num "${write_line_num:-0}" \
                --arg context "Direct file writes without atomic tmp+mv pattern" \
                --arg suggestion "Use tmp file + mv for atomic writes to prevent corruption" \
                '. + [{pattern: $pattern, severity: $severity, line_number: $line_num, context: $context, suggestion: $suggestion}]')
        fi
    fi

    # Pattern 8: cd-in-function (bare cd changes caller directory)
    if [[ "$is_test" == "false" ]]; then
        local cd_in_func=""
        cd_in_func=$(grep -n '^\s\+cd[[:space:]]' "$script_path" 2>/dev/null || true)
        if [[ -n "$cd_in_func" ]]; then
            # Check if cd is inside a subshell (...)
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                local line_content="${match#*:}"
                # Skip if the line is inside parentheses (subshell) or has ( before cd
                if ! echo "$line_content" | grep -q '(\s*cd\|cd.*&&.*)\|SCRIPT_DIR\|dirname' 2>/dev/null; then
                    violations=$(echo "$violations" | jq \
                        --arg pattern "cd-in-function" \
                        --arg severity "medium" \
                        --argjson line_num "$line_num" \
                        --arg context "${line_content:0:120}" \
                        --arg suggestion "Use subshell: ( cd dir && ... ) to avoid changing caller directory" \
                        '. + [{pattern: $pattern, severity: $severity, line_number: $line_num, context: $context, suggestion: $suggestion}]')
                    break  # Only report first occurrence
                fi
            done <<< "$cd_in_func"
        fi
    fi

    echo "$violations"
}

# ─── Full analysis of a single script ─────────────────────────────────────
# Output: JSON object with metrics, complexity, nesting, violations
complexity_analyze_script() {
    local script_path="$1"

    if [[ ! -f "$script_path" ]]; then
        return 1
    fi

    local metrics
    metrics=$(complexity_calculate_metrics "$script_path") || return 1

    local cyclomatic
    cyclomatic=$(complexity_estimate_cyclomatic "$script_path")

    local nesting
    nesting=$(complexity_calculate_nesting_depth "$script_path")

    local violations
    violations=$(complexity_detect_anti_patterns "$script_path")

    jq -n \
        --arg script "$script_path" \
        --argjson metrics "$metrics" \
        --argjson cc "$cyclomatic" \
        --argjson nesting "$nesting" \
        --argjson violations "$violations" \
        '{
            script: $script,
            metrics: $metrics,
            cyclomatic_complexity: $cc,
            max_nesting_depth: $nesting,
            violation_count: ($violations | length),
            violations: $violations,
            grade: (
                if $cc > 100 then "F"
                elif $cc > 50 then "D"
                elif $cc > 25 then "C"
                elif $cc > 10 then "B"
                else "A"
                end
            )
        }'
}

# ─── Generate refactor suggestion for a script ────────────────────────────
complexity_generate_suggestion() {
    local result_json="$1"

    local script cc loc violations grade
    script=$(echo "$result_json" | jq -r '.script')
    cc=$(echo "$result_json" | jq -r '.cyclomatic_complexity')
    loc=$(echo "$result_json" | jq -r '.metrics.code_lines')
    violations=$(echo "$result_json" | jq -r '.violation_count')
    grade=$(echo "$result_json" | jq -r '.grade')

    local suggestion=""

    if [[ $loc -gt 2000 ]]; then
        suggestion="HIGH PRIORITY: Split into modular libraries (${loc} LOC). Extract related functions into scripts/lib/ modules."
    elif [[ $loc -gt 1500 ]]; then
        suggestion="MEDIUM PRIORITY: Consider decomposition (${loc} LOC). Group functions by responsibility into separate files."
    elif [[ $cc -gt 50 ]]; then
        suggestion="Reduce cyclomatic complexity (CC=${cc}). Simplify nested conditionals, extract helper functions."
    elif [[ $violations -gt 3 ]]; then
        suggestion="Fix ${violations} anti-pattern violations. Run: shipwright complexity $(basename "$script") for details."
    fi

    if [[ -n "$suggestion" ]]; then
        jq -n --arg script "$script" --arg suggestion "$suggestion" --arg grade "$grade" \
            '{script: $script, suggestion: $suggestion, grade: $grade}'
    fi
}
