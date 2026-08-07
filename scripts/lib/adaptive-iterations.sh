#!/usr/bin/env bash
# adaptive-iterations.sh — Adaptive Build-Loop Iteration Budget from Historical Outcomes
# Source from sw-loop.sh. Requires SCRIPT_DIR and helpers (info, warn, error, emit_event).
# Tracks historical iteration counts and suggests budgets based on cohort similarity.

[[ -n "${_ADAPTIVE_ITERATIONS_LOADED:-}" ]] && return 0
_ADAPTIVE_ITERATIONS_LOADED=1

# Module version for debugging
# shellcheck disable=SC2034
VERSION="3.3.0"

# ─── Configuration ──────────────────────────────────────────────────────────

# Adaptive iteration constraints
ITERATIONS_MIN=1
ITERATIONS_MAX=50  # Absolute ceiling to prevent runaway loops
ITERATIONS_DEFAULT=20

# Historical data thresholds
# shellcheck disable=SC2034
ITERATIONS_MIN_SAMPLES=3  # Require N samples before using adaptive budget
# shellcheck disable=SC2034
ITERATIONS_LOOKBACK=100   # Use last N samples for percentile calculation
# shellcheck disable=SC2034
ITERATIONS_COHORT_THRESHOLD=0.6  # Minimum similarity score to match a cohort (0-1)
# shellcheck disable=SC2034
ITERATIONS_HIGH_CONFIDENCE_THRESHOLD=0.7  # Score for high-confidence recommendation

# Paths
ITERATIONS_HISTORY_FILE="${HOME}/.shipwright/events.jsonl"

# ─── Utility: Cohort Key Generation ────────────────────────────────────────

# adaptive_iterations_cohort() — Generate a cohort key from issue metadata.
# A cohort is a group of similar issues (same complexity, labels, etc.).
# This function returns a string key that groups similar issues together.
# Always returns a non-empty key (falls back to "default" if needed).
# $1: complexity level (low/medium/high/unknown) or empty
# $2: labels (comma-separated) or empty
# Returns: cohort key (e.g., "high-feature,auth", "default")
adaptive_iterations_cohort() {
    local complexity="${1:-unknown}"
    local labels="${2:-}"

    # Normalize complexity
    case "$complexity" in
        low|medium|high) ;;
        *) complexity="unknown" ;;
    esac

    # Build cohort key: complexity + sorted labels
    local key="$complexity"

    if [[ -n "$labels" ]]; then
        # Sort labels for consistency (use tr to split, sort, and rejoin)
        labels=$(echo "$labels" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
        key="${key}-${labels}"
    fi

    # Fallback to "default" if empty
    [[ -z "$key" ]] && key="default"
    echo "$key"
}

# ─── Utility: Extract Samples for a Cohort ─────────────────────────────────

# _iter_samples_for_cohort() — Extract iteration counts from events.jsonl for a cohort.
# Reads loop.iteration_complete events and groups by cohort key.
# Handles malformed JSON gracefully (skip bad lines).
# $1: cohort key
# $2: events file (default: ITERATIONS_HISTORY_FILE)
# Returns: newline-separated iteration counts (or empty if no data)
_iter_samples_for_cohort() {
    local cohort="$1"
    local events_file="${2:-$ITERATIONS_HISTORY_FILE}"

    [[ -f "$events_file" ]] || return 0
    [[ -z "$cohort" ]] && cohort="default"

    # Read events line-by-line to tolerate malformed JSON
    # Process each line as raw string, parse with jq, skip errors
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "$line" | jq -r "select(.type == \"loop.iteration_complete\" and (.cohort // \"default\") == \"$cohort\") | .iteration // empty" 2>/dev/null || true
    done < "$events_file"
}

# ─── Utility: Global Samples (All Cohorts) ───────────────────────────────────

# _iter_samples_global() — Extract all iteration counts from events.jsonl.
# Used as fallback when no cohort-specific data exists.
# Groups by job_id and counts iterations per job.
# $1: events file (default: ITERATIONS_HISTORY_FILE)
# Returns: newline-separated iteration counts
# shellcheck disable=SC2120
_iter_samples_global() {
    local events_file="${1:-$ITERATIONS_HISTORY_FILE}"

    [[ -f "$events_file" ]] || return 0

    # Group by job_id, count iterations, emit max iteration per job
    # (assuming iteration is 1..N per job)
    jq -r "select(.type == \"loop.iteration_complete\") | .job_id + \":\" + (.iteration | tostring)" \
        "$events_file" 2>/dev/null \
        | awk -F: '{max[$1] = ($2 > max[$1]) ? $2 : max[$1]} END {for (job in max) print max[job]}' \
        || true
}

# ─── Utility: Percentile Calculation ────────────────────────────────────────

# _iter_percentile() — Calculate Nth percentile from sorted values.
# $1: percentile (0-100)
# Reads stdin: newline-separated integers (or numbers)
# Returns: the Nth percentile value
_iter_percentile() {
    local percentile="${1:-50}"

    # Use awk to sort and compute percentile (no `sort` pipeline)
    awk \
        -v p="$percentile" \
        '
        NR == 1 {arr[1] = $1; count = 1; next}
        {
            # Simple insertion sort (ok for <= 100 samples)
            j = count
            while (j > 0 && arr[j] > $1) {
                arr[j+1] = arr[j]
                j--
            }
            arr[j+1] = $1
            count++
        }
        END {
            if (count == 0) {
                print "NaN"
            } else if (count == 1) {
                print arr[1]
            } else {
                # Nearest-rank percentile: ceil(p/100 * count)
                idx = int((p / 100.0) * count + 0.5)
                if (idx < 1) idx = 1
                if (idx > count) idx = count
                print arr[idx]
            }
        }
        '
}

# ─── Main: Suggest Iteration Budget ────────────────────────────────────────

# adaptive_iterations_suggest() — Suggest a max iteration budget from historical data.
# 3-tier fallback:
#   1. Cohort-specific data (if ≥ 5 samples and high confidence score)
#   2. Global data (if ≥ 3 samples)
#   3. Static default
# $1: complexity (low/medium/high/unknown) or empty
# $2: labels (comma-separated) or empty
# Returns: suggested iteration count
adaptive_iterations_suggest() {
    local complexity="${1:-}"
    local labels="${2:-}"

    local cohort
    cohort=$(adaptive_iterations_cohort "$complexity" "$labels")

    # Tier 1: Cohort-specific data (high confidence)
    local cohort_samples
    cohort_samples=$(_iter_samples_for_cohort "$cohort")
    local cohort_count
    cohort_count=$(echo "$cohort_samples" | awk 'NF {count++} END {print count+0}')

    if [[ "$cohort_count" -ge 5 ]]; then
        local p90
        p90=$(echo "$cohort_samples" | _iter_percentile 90)
        if [[ "$p90" =~ ^[0-9]+$ ]] && [[ "$p90" -gt 0 ]]; then
            # Add 1 to avoid starvation (edge case: all past runs used 5, clamp to 6)
            local suggested=$((p90 + 1))
            [[ "$suggested" -gt "$ITERATIONS_MAX" ]] && suggested="$ITERATIONS_MAX"
            [[ "$suggested" -lt "$ITERATIONS_MIN" ]] && suggested="$ITERATIONS_MIN"
            echo "$suggested"
            return 0
        fi
    fi

    # Tier 2: Global data (medium confidence)
    local global_samples
    # shellcheck disable=SC2119
    global_samples=$(_iter_samples_global)
    local global_count
    global_count=$(echo "$global_samples" | awk 'NF {count++} END {print count+0}')

    if [[ "$global_count" -ge 3 ]]; then
        local p90_global
        p90_global=$(echo "$global_samples" | _iter_percentile 90)
        if [[ "$p90_global" =~ ^[0-9]+$ ]] && [[ "$p90_global" -gt 0 ]]; then
            local suggested_global=$((p90_global + 1))
            [[ "$suggested_global" -gt "$ITERATIONS_MAX" ]] && suggested_global="$ITERATIONS_MAX"
            [[ "$suggested_global" -lt "$ITERATIONS_MIN" ]] && suggested_global="$ITERATIONS_MIN"
            echo "$suggested_global"
            return 0
        fi
    fi

    # Tier 3: Static default
    echo "$ITERATIONS_DEFAULT"
}

# ─── Recording: Outcome Tracking ────────────────────────────────────────────

# adaptive_iterations_record_outcome() — Record the actual iterations used.
# Emits loop.budget_outcome event with cohort, iteration count, and convergence info.
# $1: cohort key
# $2: actual iterations used (number)
# $3: converged? (true/false)
# $4: budget (what was recommended)
# Returns: 0 on success
adaptive_iterations_record_outcome() {
    local cohort="${1:-default}"
    local iterations="${2:-0}"
    local converged="${3:-false}"
    local budget="${4:-0}"

    emit_event "loop.budget_outcome" \
        "cohort=$cohort" \
        "iterations=$iterations" \
        "converged=$converged" \
        "budget=$budget"
}

# ─── Explanation: Why Was This Budget Chosen? ──────────────────────────────

# adaptive_iterations_explain() — Explain the budget decision (for logging).
# Returns: human-readable explanation string
adaptive_iterations_explain() {
    local cohort="${1:-default}"
    local budget="${2:-0}"
    local source_tier="${3:-fallback}"
    local sample_count="${4:-0}"

    case "$source_tier" in
        cohort)
            echo "Cohort '$cohort' ($sample_count samples): budget $budget iterations"
            ;;
        global)
            echo "Global history ($sample_count samples): budget $budget iterations"
            ;;
        *)
            echo "No sufficient history: using static default ($budget iterations)"
            ;;
    esac
}
