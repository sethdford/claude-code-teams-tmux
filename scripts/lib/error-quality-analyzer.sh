#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  error-quality-analyzer — Batch analysis of error feedback loop quality   ║
# ║                                                                           ║
# ║  Builds on error-actionability.sh (pure per-message scoring) to add:      ║
# ║   - Batch scoring of error-summary.json files            (AC1)            ║
# ║   - Per-iteration error.quality event emission           (AC4)            ║
# ║   - Quality↔fix-success correlation over events.jsonl    (AC2)            ║
# ║   - Bottom-5 lowest-actionability error types            (AC5)            ║
# ║   - Improved error template generation                   (AC3)            ║
# ║                                                                           ║
# ║  events.jsonl is the single correlation store (append-only).              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Module guard
[[ -n "${_MODULE_ERROR_QUALITY_ANALYZER_LOADED:-}" ]] && return 0
_MODULE_ERROR_QUALITY_ANALYZER_LOADED=1

EQA_VERSION="3.3.0"

# ─── Dependency: error-actionability scoring/classification ─────────────────
# Source the pure scoring lib if its functions are not already loaded.
if [[ "$(type -t score_error_actionability 2>/dev/null)" != "function" ]]; then
    _eqa_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [[ -f "${_eqa_dir}/error-actionability.sh" ]]; then
        # shellcheck source=/dev/null
        source "${_eqa_dir}/error-actionability.sh"
    fi
fi

# Fallbacks so the lib degrades gracefully if scoring is unavailable.
if [[ "$(type -t score_error_actionability 2>/dev/null)" != "function" ]]; then
    score_error_actionability() { echo '{"score": 0, "breakdown": {}, "threshold_met": false}'; }
fi
if [[ "$(type -t erract_classify 2>/dev/null)" != "function" ]]; then
    erract_classify() { echo "unknown"; }
fi

# emit_event fallback (real one comes from helpers.sh in the loop context).
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
    emit_event() { true; }
fi

# Default correlation tuning (config-overridable via env).
EQA_MIN_SAMPLE="${EQA_MIN_SAMPLE:-10}"
EQA_TOP_N="${EQA_TOP_N:-5}"

# Configurable templates path; defaults to repo-local .claude/.
EQA_TEMPLATES_FILE="${EQA_TEMPLATES_FILE:-.claude/error-templates.json}"

# ─── AC1: Score every error line in an error-summary.json ───────────────────
# Input:  path to an error-summary.json (as written by write_error_summary)
# Output: JSON {iteration, timestamp, error_count, avg_score, top_type, scored_errors:[...]}
eqa_score_summary_file() {
    local summary_file="$1"

    if [[ ! -f "$summary_file" ]]; then
        echo '{"error": "file not found", "scored_errors": []}'
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo '{"error": "jq unavailable", "scored_errors": []}'
        return 1
    fi

    local iteration timestamp
    iteration=$(jq -r '.iteration // 0' "$summary_file" 2>/dev/null || echo 0)
    timestamp=$(jq -r '.timestamp // ""' "$summary_file" 2>/dev/null || echo "")

    # Read error lines (newline-delimited, one per array entry).
    local lines_file
    lines_file=$(mktemp "${TMPDIR:-/tmp}/eqa-lines.XXXXXX")
    jq -r '.error_lines[]? // empty' "$summary_file" 2>/dev/null > "$lines_file" || true

    # Accumulate scored entries into a JSON array file (bash 3.2: no assoc arrays).
    local scored_file
    scored_file=$(mktemp "${TMPDIR:-/tmp}/eqa-scored.XXXXXX")
    echo "[]" > "$scored_file"

    local total_score=0
    local n=0
    local line score etype score_json
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        score_json=$(score_error_actionability "$line" 2>/dev/null || echo '{"score":0}')
        score=$(echo "$score_json" | grep -o '"score":[[:space:]]*[0-9]*' | grep -o '[0-9]*$' || echo 0)
        [[ -z "$score" ]] && score=0
        etype=$(erract_classify "$line" 2>/dev/null || echo "unknown")

        local tmp_scored
        tmp_scored=$(mktemp "${TMPDIR:-/tmp}/eqa-acc.XXXXXX")
        jq \
            --arg line "$line" \
            --argjson score "$score" \
            --arg type "$etype" \
            --argjson breakdown "$(echo "$score_json" | jq '.breakdown // {}' 2>/dev/null || echo '{}')" \
            '. + [{line: $line, score: $score, type: $type, breakdown: $breakdown}]' \
            "$scored_file" > "$tmp_scored" 2>/dev/null && mv "$tmp_scored" "$scored_file" || rm -f "$tmp_scored"

        total_score=$((total_score + score))
        n=$((n + 1))
    done < "$lines_file"

    local avg_score=0
    [[ $n -gt 0 ]] && avg_score=$((total_score / n))

    # Determine the dominant (most frequent) error type.
    local top_type="unknown"
    if [[ $n -gt 0 ]]; then
        top_type=$(jq -r '[.[].type] | group_by(.) | max_by(length) | .[0] // "unknown"' "$scored_file" 2>/dev/null || echo "unknown")
    fi

    jq -n \
        --argjson iteration "${iteration:-0}" \
        --arg timestamp "$timestamp" \
        --argjson error_count "$n" \
        --argjson avg_score "$avg_score" \
        --arg top_type "$top_type" \
        --slurpfile scored "$scored_file" \
        '{
            iteration: $iteration,
            timestamp: $timestamp,
            error_count: $error_count,
            avg_score: $avg_score,
            top_type: $top_type,
            scored_errors: $scored[0]
        }' 2>/dev/null || echo '{"scored_errors": []}'

    rm -f "$lines_file" "$scored_file" 2>/dev/null || true
}

# ─── AC4: Emit a per-iteration error.quality event ──────────────────────────
# Input:  path to an error-summary.json
# Side effect: emits one error.quality event to events.jsonl via emit_event.
eqa_emit_iteration_quality() {
    local summary_file="$1"
    local job_id="${2:-${PIPELINE_JOB_ID:-loop-$$}}"

    [[ -f "$summary_file" ]] || return 0

    local scored
    scored=$(eqa_score_summary_file "$summary_file" 2>/dev/null || echo "")
    [[ -z "$scored" ]] && return 0

    local iteration error_count avg_score top_type
    iteration=$(echo "$scored" | jq -r '.iteration // 0' 2>/dev/null || echo 0)
    error_count=$(echo "$scored" | jq -r '.error_count // 0' 2>/dev/null || echo 0)
    avg_score=$(echo "$scored" | jq -r '.avg_score // 0' 2>/dev/null || echo 0)
    top_type=$(echo "$scored" | jq -r '.top_type // "unknown"' 2>/dev/null || echo "unknown")

    # Nothing scored — skip (no spurious metrics from empty data).
    [[ "${error_count:-0}" -eq 0 ]] && return 0

    emit_event "error.quality" \
        "iteration=$iteration" \
        "job_id=$job_id" \
        "error_count=$error_count" \
        "avg_score=$avg_score" \
        "top_type=$top_type"
}

# ─── AC2: Correlate error quality with next-iteration fix success ───────────
# Reads error.quality + loop.iteration_complete events from events.jsonl.
# An error.quality at iteration N (job J) is "fixed" when iteration N+1 of the
# same job completed with test_passed=true.
# Input:  [events_file] [min_sample]
# Output: JSON array [{type, count, avg_score, fixed, fix_rate}] sorted by avg_score asc
eqa_correlate() {
    local events_file="${1:-${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}}"
    local min_sample="${2:-$EQA_MIN_SAMPLE}"

    if [[ ! -f "$events_file" ]] || ! command -v jq >/dev/null 2>&1; then
        echo "[]"
        return 0
    fi

    # Slurp the event stream once; tolerate malformed lines via -R/fromjson?.
    # Build, per error.quality event, a {type, score, fixed} record by joining
    # with the iteration_complete of (job_id, iteration+1).
    jq -R -s '
        [ splits("\n") | select(length > 0) | (fromjson? // empty) ]
        | . as $events
        | ( [ $events[] | select(.type == "loop.iteration_complete") ] ) as $completes
        | [ $events[]
            | select(.type == "error.quality")
            | . as $eq
            | ($completes[]
                | select((.job_id // "") == ($eq.job_id // ""))
                | select((.iteration // -1) == (($eq.iteration // 0) + 1)) ) as $next
            | {
                type: ($eq.top_type // "unknown"),
                score: ($eq.avg_score // 0),
                fixed: (($next.test_passed // "") == "true" or ($next.test_passed // "") == true)
              }
          ]
        | group_by(.type)
        | map({
            type: .[0].type,
            count: length,
            avg_score: ((map(.score) | add) / length | floor),
            fixed: (map(select(.fixed)) | length),
            fix_rate: ((map(select(.fixed)) | length) / length * 100 | floor)
          })
        | map(select(.count >= '"$min_sample"'))
        | sort_by(.avg_score)
    ' "$events_file" 2>/dev/null || echo "[]"
}

# ─── AC5: Bottom-N lowest-actionability error types ─────────────────────────
# Input:  [events_file] [min_sample] [n]
# Output: JSON array of the N lowest-avg_score types (already min_sample-gated)
eqa_top_offenders() {
    local events_file="${1:-${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}}"
    local min_sample="${2:-$EQA_MIN_SAMPLE}"
    local n="${3:-$EQA_TOP_N}"

    local correlated
    correlated=$(eqa_correlate "$events_file" "$min_sample")
    echo "$correlated" | jq --argjson n "$n" '.[0:$n]' 2>/dev/null || echo "[]"
}

# Suggested fix hint per error type — drives template generation.
_eqa_hint_for_type() {
    case "$1" in
        syntax)     echo "Locate the exact file:line and fix the malformed token or unbalanced delimiter." ;;
        type)       echo "Check the expected vs actual type at the call site and coerce or correct it." ;;
        assertion)  echo "Compare expected vs actual values in the failing assertion and adjust code or test." ;;
        runtime)    echo "Inspect the stack/exit signal; guard the crashing call and add bounds/null checks." ;;
        dependency) echo "Verify the module/package is installed and importable; check the import path." ;;
        permission) echo "Check file ownership/mode; ensure the path is writable by the running user." ;;
        network)    echo "Verify connectivity/host/port and retry with a timeout; check the endpoint URL." ;;
        *)          echo "Add the failing file:line, the specific error type, and a concrete next step." ;;
    esac
}

# ─── AC3: Generate improved error templates for low-actionability types ─────
# Writes .claude/error-templates.json (atomic) keyed by error type.
# Input:  [events_file] [min_sample] [n]
# Output: path to the written templates file
eqa_generate_templates() {
    local events_file="${1:-${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}}"
    local min_sample="${2:-$EQA_MIN_SAMPLE}"
    local n="${3:-$EQA_TOP_N}"
    local out_file="${EQA_TEMPLATES_FILE}"

    if ! command -v jq >/dev/null 2>&1; then
        echo "$out_file"
        return 1
    fi

    local offenders
    offenders=$(eqa_top_offenders "$events_file" "$min_sample" "$n")

    # Build a templates array: each offender → an improved, structured template.
    local templates_file
    templates_file=$(mktemp "${TMPDIR:-/tmp}/eqa-tmpl.XXXXXX")
    echo "[]" > "$templates_file"

    local count
    count=$(echo "$offenders" | jq 'length' 2>/dev/null || echo 0)
    local i=0
    while [[ $i -lt ${count:-0} ]]; do
        local etype avg_score hint
        etype=$(echo "$offenders" | jq -r ".[$i].type // \"unknown\"" 2>/dev/null || echo "unknown")
        avg_score=$(echo "$offenders" | jq -r ".[$i].avg_score // 0" 2>/dev/null || echo 0)
        hint=$(_eqa_hint_for_type "$etype")

        local tmpl
        tmpl="[<file>:<line>] ${etype} error: <specific_root_cause>. Try: ${hint}"

        local tmp_acc
        tmp_acc=$(mktemp "${TMPDIR:-/tmp}/eqa-tacc.XXXXXX")
        jq \
            --arg type "$etype" \
            --argjson avg_score "$avg_score" \
            --arg template "$tmpl" \
            --arg guidance "$hint" \
            '. + [{type: $type, avg_actionability: $avg_score, template: $template, guidance: $guidance}]' \
            "$templates_file" > "$tmp_acc" 2>/dev/null && mv "$tmp_acc" "$templates_file" || rm -f "$tmp_acc"
        i=$((i + 1))
    done

    mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
    local tmp_out="${out_file}.tmp.$$"
    jq -n \
        --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")" \
        --argjson min_sample "$min_sample" \
        --slurpfile templates "$templates_file" \
        '{
            generated_at: $generated_at,
            min_sample: $min_sample,
            templates: $templates[0]
        }' > "$tmp_out" 2>/dev/null && mv "$tmp_out" "$out_file" || rm -f "$tmp_out"

    rm -f "$templates_file" 2>/dev/null || true
    echo "$out_file"
}

# ─── Orchestrator: human-readable report + template generation ──────────────
eqa_report() {
    local events_file="${1:-${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}}"
    local min_sample="${2:-$EQA_MIN_SAMPLE}"
    local n="${3:-$EQA_TOP_N}"

    local offenders
    offenders=$(eqa_top_offenders "$events_file" "$min_sample" "$n")
    local count
    count=$(echo "$offenders" | jq 'length' 2>/dev/null || echo 0)

    echo "Error Feedback Loop Quality Report"
    echo "═══════════════════════════════════════════════════"
    echo "Events: $events_file   (min sample: $min_sample)"
    echo ""

    if [[ "${count:-0}" -eq 0 ]]; then
        echo "No error types meet the minimum sample size of $min_sample yet."
        echo "(Quality metrics accumulate as failing iterations emit error.quality events.)"
        return 0
    fi

    printf "%-12s %6s %10s %10s\n" "TYPE" "COUNT" "AVG_SCORE" "FIX_RATE"
    printf "%-12s %6s %10s %10s\n" "----" "-----" "---------" "--------"
    local i=0
    while [[ $i -lt ${count:-0} ]]; do
        local etype cnt avg fix
        etype=$(echo "$offenders" | jq -r ".[$i].type" 2>/dev/null || echo "?")
        cnt=$(echo "$offenders" | jq -r ".[$i].count" 2>/dev/null || echo 0)
        avg=$(echo "$offenders" | jq -r ".[$i].avg_score" 2>/dev/null || echo 0)
        fix=$(echo "$offenders" | jq -r ".[$i].fix_rate" 2>/dev/null || echo 0)
        printf "%-12s %6s %9s%% %9s%%\n" "$etype" "$cnt" "$avg" "$fix"
        i=$((i + 1))
    done

    echo ""
    local tmpl_path
    tmpl_path=$(eqa_generate_templates "$events_file" "$min_sample" "$n")
    echo "Improved templates written to: $tmpl_path"
}
