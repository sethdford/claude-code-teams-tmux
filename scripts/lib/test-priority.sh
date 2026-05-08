#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  test-priority — Orchestrate intelligent test prioritization              ║
# ║                                                                            ║
# ║  Combines:                                                                 ║
# ║    test-dep-map  — which tests cover which source files                    ║
# ║    test-optimizer — discovery, ordering, fast-fail execution               ║
# ║    sw-memory      — historical failure rates                               ║
# ║                                                                            ║
# ║  Scoring: 60% affected-files + 40% historical failure rate                 ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
[[ -n "${_TEST_PRIORITY_LOADED:-}" ]] && return 0; _TEST_PRIORITY_LOADED=1

TP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=test-dep-map.sh
source "$TP_LIB_DIR/test-dep-map.sh"
# shellcheck source=test-optimizer.sh
source "$TP_LIB_DIR/test-optimizer.sh"

# Defaults — overridden by daemon-config.json if present
TP_ENABLED="${TP_ENABLED:-false}"
TP_FAST_FAIL_MODE="${TP_FAST_FAIL_MODE:-true}"
TP_HISTORY_WINDOW="${TP_HISTORY_WINDOW:-50}"
TP_AFFECTED_ONLY="${TP_AFFECTED_ONLY:-false}"
TP_MAX_TESTS="${TP_MAX_TESTS:-0}"  # 0 = no cap
TP_AFFECTED_WEIGHT="${TP_AFFECTED_WEIGHT:-60}"
TP_FAILRATE_WEIGHT="${TP_FAILRATE_WEIGHT:-40}"

# Last-run stats — surfaced to dashboard via emit_event
TP_TESTS_TOTAL=0
TP_TESTS_RUN=0
TP_TESTS_SKIPPED=0
TP_TIME_SAVED_S=0
TP_EARLY_ABORT="false"

[[ "$(type -t info 2>/dev/null)" == "function" ]] || info() { echo -e "▸ $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]] || warn() { echo -e "⚠ $*" >&2; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }

# Load configuration from daemon-config.json (if present).
tp_load_config() {
    local cfg="${1:-.claude/daemon-config.json}"
    [[ ! -f "$cfg" ]] && return 0
    command -v jq >/dev/null 2>&1 || return 0

    local block
    block=$(jq -c '.test_prioritization // {}' "$cfg" 2>/dev/null || echo '{}')
    [[ "$block" == "null" || "$block" == "{}" ]] && return 0

    # Use `if has(...)` rather than `// default` because jq's // treats literal
    # `false` as the alternative trigger, which would silently flip a configured
    # `false` back to the default.
    TP_ENABLED=$(echo "$block"            | jq -r 'if has("enabled")             then .enabled             else false end')
    TP_FAST_FAIL_MODE=$(echo "$block"     | jq -r 'if has("fast_fail_mode")      then .fast_fail_mode      else true  end')
    TP_HISTORY_WINDOW=$(echo "$block"     | jq -r 'if has("history_window_runs") then .history_window_runs else 50    end')
    TP_AFFECTED_ONLY=$(echo "$block"      | jq -r 'if has("affected_only")       then .affected_only       else false end')
    TP_MAX_TESTS=$(echo "$block"          | jq -r 'if has("max_priority_tests")  then .max_priority_tests  else 0     end')
    TP_AFFECTED_WEIGHT=$(echo "$block"    | jq -r 'if has("affected_weight")     then .affected_weight     else 60    end')
    TP_FAILRATE_WEIGHT=$(echo "$block"    | jq -r 'if has("failrate_weight")     then .failrate_weight     else 40    end')
}

# Score a single test: blend of affected-membership and historical fail rate.
# Echoes integer score (higher = run earlier).
_tp_score_test() {
    local test_file="$1"
    local is_affected="$2"   # 1 or 0
    local fail_rate           # 0.0..1.0

    if [[ "$(type -t memory_get_test_failure_rate 2>/dev/null)" == "function" ]]; then
        fail_rate=$(memory_get_test_failure_rate "$test_file" "$TP_HISTORY_WINDOW" 2>/dev/null || echo "0.0")
    else
        fail_rate="0.0"
    fi

    awk -v aff="$is_affected" \
        -v fr="$fail_rate" \
        -v aw="$TP_AFFECTED_WEIGHT" \
        -v fw="$TP_FAILRATE_WEIGHT" \
        'BEGIN { printf "%d", (aff * aw) + (fr * fw) }'
}

# Order tests: affected first, then by historical fail rate. Echoes ordered list.
# tp_order_tests <changed_file...>
tp_order_tests() {
    local -a changed=("$@")

    # Build current dep-map (cheap; cached)
    tdm_build_map "." 2>/dev/null || true

    # Identify affected tests
    local -a affected=()
    if [[ ${#changed[@]} -gt 0 ]]; then
        while IFS= read -r t; do
            [[ -n "$t" ]] && affected+=("$t")
        done < <(tdm_tests_for_changed "${changed[@]}" 2>/dev/null || true)
    fi

    # Discover all tests
    testopt_discover_tests "." >/dev/null 2>&1 || true

    # In affected_only mode with non-empty affected set, restrict pool
    local -a pool=()
    if [[ "$TP_AFFECTED_ONLY" == "true" && ${#affected[@]} -gt 0 ]]; then
        pool=("${affected[@]}")
    else
        pool=("${DISCOVERED_TESTS[@]:-}")
    fi

    # Build affected lookup
    local affected_set=" "
    for a in "${affected[@]:-}"; do affected_set+="$a "; done

    # Score each test → "<score> <path>" lines
    local tmp
    tmp=$(mktemp)
    trap "rm -f '$tmp'" RETURN
    for tf in "${pool[@]:-}"; do
        [[ -z "$tf" ]] && continue
        local is_aff=0
        [[ "$affected_set" == *" $tf "* ]] && is_aff=1
        local score
        score=$(_tp_score_test "$tf" "$is_aff")
        printf '%s %s\n' "$score" "$tf" >> "$tmp"
    done

    # Sort desc, optionally cap
    if [[ "$TP_MAX_TESTS" -gt 0 ]]; then
        sort -rn "$tmp" | head -n "$TP_MAX_TESTS" | awk '{print $2}'
    else
        sort -rn "$tmp" | awk '{print $2}'
    fi
}

# Run tests in priority order, recording outcomes to memory.
# tp_run_prioritized <changed_files_csv>
# Returns: 0 on all-pass, 1 on any failure.
tp_run_prioritized() {
    local changed_csv="${1:-}"
    local -a changed=()
    if [[ -n "$changed_csv" ]]; then
        IFS=',' read -ra changed <<< "$changed_csv"
    fi

    local -a ordered=()
    while IFS= read -r t; do
        [[ -n "$t" ]] && ordered+=("$t")
    done < <(tp_order_tests "${changed[@]:-}")

    TP_TESTS_TOTAL=${#ordered[@]}
    TP_TESTS_RUN=0
    TP_TESTS_SKIPPED=0
    TP_TIME_SAVED_S=0
    TP_EARLY_ABORT="false"

    if [[ ${#ordered[@]} -eq 0 ]]; then
        info "test-priority: no tests to run"
        emit_event "test_priority_run_complete" "tests_total=0" "tests_run=0" "early_abort=false"
        return 0
    fi

    info "test-priority: running ${#ordered[@]} test(s) (fast_fail=$TP_FAST_FAIL_MODE)"

    local all_passed=true
    local total_remaining_duration=0
    for tf in "${ordered[@]}"; do
        TP_TESTS_RUN=$((TP_TESTS_RUN + 1))
        local start_ts duration exit_code=0
        start_ts=$(date +%s)
        bash "$tf" >/dev/null 2>&1 || exit_code=$?
        duration=$(( $(date +%s) - start_ts ))

        local result="pass"
        [[ "$exit_code" -ne 0 ]] && result="fail"

        if [[ "$(type -t memory_record_test_outcome 2>/dev/null)" == "function" ]]; then
            memory_record_test_outcome "$tf" "$result" "$duration" "$changed_csv" 2>/dev/null || true
        fi

        if [[ "$result" == "fail" ]]; then
            all_passed=false
            if [[ "$TP_FAST_FAIL_MODE" == "true" ]]; then
                TP_TESTS_SKIPPED=$(( TP_TESTS_TOTAL - TP_TESTS_RUN ))
                # Estimate time saved using historical avg duration of remaining tests
                if command -v jq >/dev/null 2>&1; then
                    local i=0
                    for tf2 in "${ordered[@]}"; do
                        i=$((i + 1))
                        [[ $i -le $TP_TESTS_RUN ]] && continue
                        local d
                        d=$(testopt_get_historical_duration "$tf2" 2>/dev/null || echo 0)
                        total_remaining_duration=$(( total_remaining_duration + ${d%.*} ))
                    done
                    TP_TIME_SAVED_S="$total_remaining_duration"
                fi
                TP_EARLY_ABORT="true"
                break
            fi
        fi
    done

    emit_event "test_priority_run_complete" \
        "tests_total=$TP_TESTS_TOTAL" \
        "tests_run=$TP_TESTS_RUN" \
        "tests_skipped=$TP_TESTS_SKIPPED" \
        "time_saved_s=$TP_TIME_SAVED_S" \
        "early_abort=$TP_EARLY_ABORT"

    [[ "$all_passed" == "true" ]] && return 0 || return 1
}
