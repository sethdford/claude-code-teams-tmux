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
ITERATIONS_MIN_COHORT_SAMPLES=5  # Samples required before trusting cohort-specific data
ITERATIONS_MIN_SAMPLES=3         # Samples required before trusting global data
ITERATIONS_LOOKBACK=100          # Use at most the last N samples for the percentile
ITERATIONS_SCAN_LINES=20000      # Only scan the last N lines of events.jsonl

# Percentile used to derive a budget from historical iteration counts.
ITERATIONS_PERCENTILE=90

# Paths
ITERATIONS_HISTORY_FILE="${HOME}/.shipwright/events.jsonl"

# ─── Outputs set by adaptive_iterations_suggest() ───────────────────────────
# suggest() both prints the budget and records how it got there. Read these
# *after* calling it — and call it directly, not in a command substitution, or
# the assignments are lost to the subshell (ADAPTIVE_SUGGESTED exists so callers
# that need the number and the reason can avoid `$(...)` entirely).
ADAPTIVE_TIER="fallback"   # cohort | global | fallback
ADAPTIVE_SAMPLES=0         # number of samples the winning tier saw
ADAPTIVE_SUGGESTED=0       # the budget suggest() last returned

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
# Reads loop.iteration_complete events and keeps those matching the cohort key.
#
# A single `jq -R` pass handles the whole file: `fromjson?` drops malformed lines
# without aborting, so one corrupt event does not blind the whole history. The
# cohort is passed via --arg (never interpolated into the jq program) so labels
# containing quotes, backslashes, `$` or backticks cannot alter the filter.
# Scanning is bounded by ITERATIONS_SCAN_LINES (input) and ITERATIONS_LOOKBACK
# (output) so an events.jsonl that grows without limit stays O(1) to read.
#
# $1: cohort key
# $2: events file (default: ITERATIONS_HISTORY_FILE)
# Returns: newline-separated iteration counts, most recent last (or empty)
_iter_samples_for_cohort() {
    local cohort="${1:-default}"
    local events_file="${2:-$ITERATIONS_HISTORY_FILE}"

    [[ -f "$events_file" ]] || return 0
    [[ -z "$cohort" ]] && cohort="default"

    tail -n "$ITERATIONS_SCAN_LINES" "$events_file" 2>/dev/null \
        | jq -R -r --arg cohort "$cohort" '
            (fromjson? // empty)
            | select(.type == "loop.iteration_complete")
            | select((.cohort // "default") == $cohort)
            | (.iteration // empty)
            | tostring
            | select(test("^[0-9]+$"))
          ' 2>/dev/null \
        | tail -n "$ITERATIONS_LOOKBACK" || true
}

# ─── Utility: Global Samples (All Cohorts) ───────────────────────────────────

# _iter_samples_global() — Extract all iteration counts from events.jsonl.
# Used as fallback when no cohort-specific data exists. Each job contributes one
# sample: the highest iteration number it reached.
#
# Same single-pass `jq -R` + `fromjson?` shape as the cohort reader, so a
# malformed line cannot abort the scan. job_id and iteration are joined with a
# tab (job ids may legitimately contain ':'), and the awk max is taken
# numerically so "10" does not compare below "9".
#
# $1: events file (default: ITERATIONS_HISTORY_FILE)
# Returns: newline-separated iteration counts, one per job
# shellcheck disable=SC2120
_iter_samples_global() {
    local events_file="${1:-$ITERATIONS_HISTORY_FILE}"

    [[ -f "$events_file" ]] || return 0

    tail -n "$ITERATIONS_SCAN_LINES" "$events_file" 2>/dev/null \
        | jq -R -r '
            (fromjson? // empty)
            | select(.type == "loop.iteration_complete")
            | select(.job_id != null and .iteration != null)
            | "\(.job_id)\t\(.iteration)"
          ' 2>/dev/null \
        | awk -F'\t' '
            $2 ~ /^[0-9]+$/ {
                if (!($1 in max) || ($2 + 0) > (max[$1] + 0)) max[$1] = $2
            }
            END { for (job in max) print max[job] }
          ' \
        | tail -n "$ITERATIONS_LOOKBACK" || true
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
                # Nearest-rank percentile: ceil(p/100 * count).
                # Rounding instead of ceiling drops the rank by one for many
                # sample counts (6-9, 16-19, 26-29, ... at p=90), which discards
                # exactly the slow tail the budget exists to cover.
                rank = (p / 100.0) * count
                idx = int(rank)
                if (rank > idx) idx = idx + 1
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
#   1. Cohort-specific data (≥ ITERATIONS_MIN_COHORT_SAMPLES samples)
#   2. Global data           (≥ ITERATIONS_MIN_SAMPLES samples)
#   3. Static default
# Also sets ADAPTIVE_TIER and ADAPTIVE_SAMPLES so the caller can log/emit the
# reason a budget was chosen, not just the number.
# $1: complexity (low/medium/high/unknown) or empty
# $2: labels (comma-separated) or empty
# Returns: suggested iteration count
adaptive_iterations_suggest() {
    local complexity="${1:-}"
    local labels="${2:-}"

    ADAPTIVE_TIER="fallback"
    ADAPTIVE_SAMPLES=0
    ADAPTIVE_SUGGESTED="$ITERATIONS_DEFAULT"

    local cohort
    cohort=$(adaptive_iterations_cohort "$complexity" "$labels")

    # Tier 1: Cohort-specific data (high confidence)
    local cohort_samples cohort_count
    # shellcheck disable=SC2119
    cohort_samples=$(_iter_samples_for_cohort "$cohort")
    cohort_count=$(echo "$cohort_samples" | awk 'NF {count++} END {print count+0}')

    if [[ "$cohort_count" -ge "$ITERATIONS_MIN_COHORT_SAMPLES" ]]; then
        local p_cohort
        p_cohort=$(echo "$cohort_samples" | _iter_percentile "$ITERATIONS_PERCENTILE")
        if [[ "$p_cohort" =~ ^[0-9]+$ ]] && [[ "$p_cohort" -gt 0 ]]; then
            ADAPTIVE_TIER="cohort"
            ADAPTIVE_SAMPLES="$cohort_count"
            _iter_clamp $((p_cohort + 1))
            return 0
        fi
    fi

    # Tier 2: Global data (medium confidence)
    local global_samples global_count
    # shellcheck disable=SC2119
    global_samples=$(_iter_samples_global)
    global_count=$(echo "$global_samples" | awk 'NF {count++} END {print count+0}')

    if [[ "$global_count" -ge "$ITERATIONS_MIN_SAMPLES" ]]; then
        local p_global
        p_global=$(echo "$global_samples" | _iter_percentile "$ITERATIONS_PERCENTILE")
        if [[ "$p_global" =~ ^[0-9]+$ ]] && [[ "$p_global" -gt 0 ]]; then
            # shellcheck disable=SC2034  # read by the sourcing script (sw-loop.sh)
            ADAPTIVE_TIER="global"
            # shellcheck disable=SC2034  # read by the sourcing script (sw-loop.sh)
            ADAPTIVE_SAMPLES="$global_count"
            _iter_clamp $((p_global + 1))
            return 0
        fi
    fi

    # Tier 3: Static default
    echo "$ITERATIONS_DEFAULT"
}

# _iter_clamp() — Record and print $1 clamped into [ITERATIONS_MIN, ITERATIONS_MAX].
# The +1 applied by callers avoids starvation: if every past run needed exactly
# N iterations, a budget of N leaves no room for the run that needs N+1.
_iter_clamp() {
    local value="$1"
    [[ "$value" -gt "$ITERATIONS_MAX" ]] && value="$ITERATIONS_MAX"
    [[ "$value" -lt "$ITERATIONS_MIN" ]] && value="$ITERATIONS_MIN"
    # shellcheck disable=SC2034  # read by the sourcing script (sw-loop.sh)
    ADAPTIVE_SUGGESTED="$value"
    echo "$value"
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
