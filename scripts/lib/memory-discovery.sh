#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  Memory Discovery — pattern capture & cross-pipeline learning         ║
# ║  Captures failures · Records fix outcomes · Aggregates global memory  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# Extracted from sw-memory.sh — pure move, no behavior change.
# Sourced by sw-memory.sh, which supplies the shared memory primitives this
# module calls at runtime: repo_hash(), repo_name(), repo_memory_dir(),
# ensure_memory_dir(), MEMORY_ROOT, GLOBAL_MEMORY.

# Module guard
[[ -n "${_MEMDISC_LOADED:-}" ]] && return 0
_MEMDISC_LOADED=1

VERSION="3.3.0"

# ─── Helpers (loaded from parent context) ───────────────────────────────────
# Expects: info(), success(), warn(), error(), emit_event(), now_iso().
# Fallbacks keep the module usable when sourced without sw-memory.sh's preamble.
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }

if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift
    mkdir -p "${HOME}/.shipwright" 2>/dev/null || return 0
    local payload="{\"ts\":\"$(now_iso)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do
      local key="${1%%=*}" val="${1#*=}"
      payload="${payload},\"${key}\":\"${val}\""
      shift
    done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Memory Capture Functions ──────────────────────────────────────────────

# memory_capture_pipeline <state_file> <artifacts_dir>
# Called after every pipeline completes. Reads state + artifacts → writes learnings.
memory_capture_pipeline() {
    local state_file="${1:-}"
    local artifacts_dir="${2:-}"

    if [[ -z "$state_file" || ! -f "$state_file" ]]; then
        warn "State file not found: ${state_file:-<empty>}"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"

    local repo
    repo="$(repo_name)"
    local captured_at
    captured_at="$(now_iso)"

    info "Capturing pipeline learnings for ${CYAN}${repo}${RESET}..."

    # Extract pipeline result from state file
    local pipeline_status=""
    pipeline_status=$(sed -n 's/^status: *//p' "$state_file" | head -1)

    local goal=""
    goal=$(sed -n 's/^goal: *"*\([^"]*\)"*/\1/p' "$state_file" | head -1)

    # Capture stage results
    local stages_section=""
    stages_section=$(sed -n '/^stages:/,/^---/p' "$state_file" 2>/dev/null || true)

    # Track which stages passed/failed
    local passed_stages=""
    local failed_stages=""
    if [[ -n "$stages_section" ]]; then
        passed_stages=$(echo "$stages_section" | grep "complete" | sed 's/: *complete//' | tr -d ' ' | tr '\n' ',' | sed 's/,$//' || true)
        failed_stages=$(echo "$stages_section" | grep "failed" | sed 's/: *failed//' | tr -d ' ' | tr '\n' ',' | sed 's/,$//' || true)
    fi

    # Capture test failures if test artifacts exist
    if [[ -n "$artifacts_dir" && -f "$artifacts_dir/test-results.log" ]]; then
        local test_output
        test_output=$(cat "$artifacts_dir/test-results.log" 2>/dev/null || true)
        if echo "$test_output" | grep -qiE "FAIL|ERROR|failed"; then
            memory_capture_failure "test" "$test_output"
        fi
    fi

    # Capture review feedback patterns
    if [[ -n "$artifacts_dir" && -f "$artifacts_dir/review.md" ]]; then
        local review_output
        review_output=$(cat "$artifacts_dir/review.md" 2>/dev/null || true)
        local bug_count warning_count
        bug_count=$(echo "$review_output" | grep -ciE '\*\*\[Bug\]' || true)
        warning_count=$(echo "$review_output" | grep -ciE '\*\*\[Warning\]' || true)

        if [[ "${bug_count:-0}" -gt 0 || "${warning_count:-0}" -gt 0 ]]; then
            # Record review patterns to global memory for cross-repo learning
            local tmp_global
            tmp_global=$(mktemp)
    # shellcheck disable=SC2064
            trap "rm -f '$tmp_global'" RETURN
            jq --arg repo "$repo" \
               --arg ts "$captured_at" \
               --argjson bugs "${bug_count:-0}" \
               --argjson warns "${warning_count:-0}" \
               '.cross_repo_learnings += [{
                   repo: $repo,
                   type: "review_feedback",
                   bugs: $bugs,
                   warnings: $warns,
                   captured_at: $ts
               }] | .cross_repo_learnings = (.cross_repo_learnings | .[-50:])' \
               "$GLOBAL_MEMORY" > "$tmp_global" && mv "$tmp_global" "$GLOBAL_MEMORY"
        fi
    fi

    emit_event "memory.capture" \
        "repo=${repo}" \
        "result=${pipeline_status}" \
        "passed_stages=${passed_stages}" \
        "failed_stages=${failed_stages}"

    success "Captured pipeline learnings (status: ${pipeline_status})"
}

# memory_capture_failure <stage> <error_output>
# Captures and deduplicates failure patterns.
memory_capture_failure() {
    local stage="${1:-unknown}"
    local error_output="${2:-}"

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    # Extract a short pattern from the error (first significant line)
    local pattern=""
    pattern=$(echo "$error_output" \
        | grep -iE "error|fail|cannot|not found|undefined|exception|missing" \
        | head -1 \
        | sed 's/^[[:space:]]*//' \
        | cut -c1-200)

    if [[ -z "$pattern" ]]; then
        pattern=$(echo "$error_output" | head -1 | cut -c1-200)
    fi

    if [[ -z "$pattern" ]]; then
        warn "Memory capture: empty error pattern — skipping"
        return 0
    fi

    # Check for duplicate — increment seen_count if pattern already exists
    local existing_idx
    existing_idx=$(jq --arg pat "$pattern" \
        '[.failures[]] | to_entries | map(select(.value.pattern == $pat)) | .[0].key // -1' \
        "$failures_file" 2>/dev/null || echo "-1")

    (
        if command -v flock >/dev/null 2>&1; then
            flock -w 10 200 2>/dev/null || { warn "Memory lock timeout"; return 1; }
        fi
        local tmp_file
        tmp_file=$(mktemp "${failures_file}.tmp.XXXXXX")
    # shellcheck disable=SC2064
        trap "rm -f '$tmp_file'" EXIT

        if [[ "$existing_idx" != "-1" && "$existing_idx" != "null" ]]; then
            # Update existing entry
            jq --argjson idx "$existing_idx" \
               --arg ts "$(now_iso)" \
               '.failures[$idx].seen_count += 1 | .failures[$idx].last_seen = $ts' \
               "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file" || rm -f "$tmp_file"
        else
            # Add new failure entry
            jq --arg stage "$stage" \
               --arg pattern "$pattern" \
               --arg ts "$(now_iso)" \
               '.failures += [{
                   stage: $stage,
                   pattern: $pattern,
                   root_cause: "",
                   fix: "",
                   seen_count: 1,
                   last_seen: $ts
               }] | .failures = (.failures | .[-100:])' \
               "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file" || rm -f "$tmp_file"
        fi
    ) 200>"${failures_file}.lock"

    # Dual-write to DB
    if type db_record_failure >/dev/null 2>&1; then
        local rhash
        rhash="$(repo_hash)"
        db_record_failure "$rhash" "unknown" "$pattern" "" "" "" "$stage" 2>/dev/null || true
    fi

    memory_store_for_embedding "failure" "$pattern" "$(repo_hash)" 2>/dev/null || true

    emit_event "memory.failure" "stage=${stage}" "pattern=${pattern:0:80}"
}

# memory_record_fix_outcome <failure_hash_or_pattern> <fix_applied:bool> <fix_resolved:bool>
# Tracks whether suggested fixes actually worked. Builds effectiveness data
# so future memory injection can prioritize high-success-rate fixes.
memory_record_fix_outcome() {
    local pattern_match="${1:-}"
    local fix_applied="${2:-false}"
    local fix_resolved="${3:-false}"

    [[ -z "$pattern_match" ]] && return 1

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    [[ ! -f "$failures_file" ]] && return 1

    # Find matching failure by pattern substring
    local match_idx
    match_idx=$(jq --arg pat "$pattern_match" \
        '[.failures[]] | to_entries | map(select(.value.pattern | contains($pat))) | .[0].key // -1' \
        "$failures_file" 2>/dev/null || echo "-1")

    if [[ "$match_idx" == "-1" || "$match_idx" == "null" ]]; then
        warn "No matching failure found for: ${pattern_match:0:60}"
        return 1
    fi

    # Update fix outcome tracking fields
    local applied_inc=0 resolved_inc=0
    [[ "$fix_applied" == "true" ]] && applied_inc=1
    [[ "$fix_resolved" == "true" ]] && resolved_inc=1

    (
        if command -v flock >/dev/null 2>&1; then
            flock -w 10 200 2>/dev/null || { warn "Memory lock timeout"; return 1; }
        fi
        local tmp_file
        tmp_file=$(mktemp "${failures_file}.tmp.XXXXXX")
    # shellcheck disable=SC2064
        trap "rm -f '$tmp_file'" EXIT

        jq --argjson idx "$match_idx" \
           --argjson app "$applied_inc" \
           --argjson res "$resolved_inc" \
           --arg ts "$(now_iso)" \
           '.failures[$idx].times_fix_suggested = ((.failures[$idx].times_fix_suggested // 0) + 1) |
            .failures[$idx].times_fix_applied = ((.failures[$idx].times_fix_applied // 0) + $app) |
            .failures[$idx].times_fix_resolved = ((.failures[$idx].times_fix_resolved // 0) + $res) |
            .failures[$idx].fix_effectiveness_rate = (
                if ((.failures[$idx].times_fix_applied // 0) + $app) > 0 then
                    (((.failures[$idx].times_fix_resolved // 0) + $res) * 100 /
                     ((.failures[$idx].times_fix_applied // 0) + $app))
                else 0 end
            ) |
            .failures[$idx].last_outcome_at = $ts' \
           "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file" || rm -f "$tmp_file"
    ) 200>"${failures_file}.lock"

    emit_event "memory.fix_outcome" \
        "pattern=${pattern_match:0:60}" \
        "applied=${fix_applied}" \
        "resolved=${fix_resolved}"
}

# memory_track_fix <error_sig> <success_bool>
# Convenience wrapper for memory_record_fix_outcome
memory_track_fix() {
    local error_sig="${1:-}"
    local success="${2:-false}"
    [[ -z "$error_sig" ]] && return 0
    memory_record_fix_outcome "$error_sig" "true" "$success" 2>/dev/null || true
}

# memory_query_fix_for_error <error_pattern>
# Searches failure memory for known fixes matching the given error pattern.
# Returns JSON with the best fix (highest effectiveness rate) or empty.
memory_query_fix_for_error() {
    local error_pattern="$1"
    [[ -z "$error_pattern" ]] && return 0

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    [[ ! -f "$failures_file" ]] && return 0

    # Search for matching failures with successful fixes
    local matches
    matches=$(jq -r --arg pat "$error_pattern" '
        [.failures[]
        | select(.pattern != null and .pattern != "")
        | select(.pattern | test($pat; "i") // false)
        | select(.fix != null and .fix != "")
        | select((.fix_effectiveness_rate // 0) > 30)
        | {fix, fix_effectiveness_rate, seen_count, category, stage, pattern}]
        | sort_by(-.fix_effectiveness_rate)
        | .[0] // null
    ' "$failures_file" 2>/dev/null) || true

    if [[ -n "$matches" && "$matches" != "null" ]]; then
        echo "$matches"
    fi
}

# memory_closed_loop_inject <error_sig>
# Combines error → memory → fix into injectable text for build retries.
# Returns a one-line summary suitable for goal augmentation.
memory_closed_loop_inject() {
    local error_sig="$1"
    [[ -z "$error_sig" ]] && return 0

    local fix_json
    fix_json=$(memory_query_fix_for_error "$error_sig") || true
    [[ -z "$fix_json" || "$fix_json" == "null" ]] && return 0

    local fix_text success_rate category
    fix_text=$(echo "$fix_json" | jq -r '.fix // ""')
    success_rate=$(echo "$fix_json" | jq -r '.fix_effectiveness_rate // 0')
    category=$(echo "$fix_json" | jq -r '.category // "unknown"')

    [[ -z "$fix_text" ]] && return 0

    echo "[$category, ${success_rate}% success rate] $fix_text"
}

memory_capture_failure_from_log() {
    local artifacts_dir="${1:-}"
    local error_log="${artifacts_dir}/error-log.jsonl"
    [[ ! -f "$error_log" ]] && return 0

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    # Read last 50 entries
    local entries
    entries=$(tail -50 "$error_log" 2>/dev/null) || return 0
    [[ -z "$entries" ]] && return 0

    local captured=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local err_type err_text
        err_type=$(echo "$line" | jq -r '.type // "unknown"' 2>/dev/null) || continue
        err_text=$(echo "$line" | jq -r '.error // ""' 2>/dev/null) || continue
        [[ -z "$err_text" ]] && continue

        # Deduplicate: skip if this exact pattern already exists in failures
        local pattern_short
        pattern_short=$(echo "$err_text" | head -1 | cut -c1-200)
        local already_exists
        already_exists=$(jq --arg pat "$pattern_short" \
            '[.failures[] | select(.pattern == $pat)] | length' \
            "$failures_file" 2>/dev/null || echo "0")
        if [[ "${already_exists:-0}" -gt 0 ]]; then
            continue
        fi

        # Feed into memory_capture_failure with the error type as stage
        memory_capture_failure "$err_type" "$err_text" 2>/dev/null || true
        captured=$((captured + 1))
    done <<< "$entries"

    if [[ "$captured" -gt 0 ]]; then
        emit_event "memory.error_log_processed" "captured=$captured"
    fi
}

# _memory_aggregate_global
# Promotes high-frequency failure patterns to global.json for cross-repo learning
_memory_aggregate_global() {
    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"
    [[ ! -f "$failures_file" ]] && return 0

    local global_file="$GLOBAL_MEMORY"
    [[ ! -f "$global_file" ]] && return 0

    # Find patterns with seen_count >= 3
    local frequent_patterns
    frequent_patterns=$(jq -r '.failures[] | select(.seen_count >= 3) | .pattern' \
        "$failures_file" 2>/dev/null) || return 0
    [[ -z "$frequent_patterns" ]] && return 0

    local promoted=0
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue

        # Check if already in global
        local exists
        exists=$(jq --arg p "$pattern" \
            '[.common_patterns[] | select(.pattern == $p)] | length' \
            "$global_file" 2>/dev/null || echo "0")
        if [[ "${exists:-0}" -gt 0 ]]; then
            continue
        fi

        # Add to global, cap at 100 entries
        local tmp_global
        tmp_global=$(mktemp "${global_file}.tmp.XXXXXX")
    # shellcheck disable=SC2064
        trap "rm -f '$tmp_global'" RETURN
        jq --arg p "$pattern" \
           --arg ts "$(now_iso)" \
           --arg cat "general" \
           '.common_patterns += [{pattern: $p, promoted_at: $ts, category: $cat, source: "aggregate"}] |
            .common_patterns = (.common_patterns | .[-100:])' \
           "$global_file" > "$tmp_global" && mv "$tmp_global" "$global_file" || rm -f "$tmp_global"
        promoted=$((promoted + 1))
    done <<< "$frequent_patterns"

    if [[ "$promoted" -gt 0 ]]; then
        emit_event "memory.global_aggregated" "promoted=$promoted"
    fi
}

# memory_finalize_pipeline <state_file> <artifacts_dir>
# Single call that closes multiple feedback loops at pipeline completion
memory_finalize_pipeline() {
    local state_file="${1:-}"
    local artifacts_dir="${2:-}"
    [[ -z "$state_file" || ! -f "$state_file" ]] && return 0

    # Step 1: Capture pipeline-level learnings
    memory_capture_pipeline "$state_file" "$artifacts_dir" 2>/dev/null || true

    # Step 2: Process error log into failures.json
    memory_capture_failure_from_log "$artifacts_dir" 2>/dev/null || true

    # Step 3: Aggregate high-frequency patterns to global memory
    _memory_aggregate_global 2>/dev/null || true
}

# memory_analyze_failure <log_file> <stage>
# Uses Claude to analyze a pipeline failure and fill in root_cause/fix/category.
memory_analyze_failure() {
    local log_file="${1:-}"
    local stage="${2:-unknown}"

    if [[ -z "$log_file" ]]; then
        warn "No log file specified for failure analysis"
        return 1
    fi

    # Gather log context — use the specific log file if it exists,
    # otherwise glob for any logs in the artifacts directory
    local log_tail=""
    if [[ -f "$log_file" ]]; then
        log_tail=$(tail -200 "$log_file" 2>/dev/null || true)
    else
        # Try to find stage-specific logs in the same directory
        local log_dir
        log_dir=$(dirname "$log_file" 2>/dev/null || echo ".")
        log_tail=$(tail -200 "$log_dir"/*.log 2>/dev/null || true)
    fi

    if [[ -z "$log_tail" ]]; then
        warn "No log content found for analysis"
        return 1
    fi

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    # Check that failures.json has at least one entry
    local entry_count
    entry_count=$(jq '.failures | length' "$failures_file" 2>/dev/null || echo "0")
    if [[ "$entry_count" -eq 0 ]]; then
        warn "No failure entries to analyze"
        return 0
    fi

    local last_pattern
    last_pattern=$(jq -r '.failures[-1].pattern // ""' "$failures_file" 2>/dev/null)

    info "Analyzing failure in ${CYAN}${stage}${RESET} stage..."

    # Gather past successful analyses for the same stage/category as examples
    local past_examples=""
    if [[ -f "$failures_file" ]]; then
        past_examples=$(jq -r --arg stg "$stage" \
            '[.failures[] | select(.stage == $stg and .root_cause != "" and .fix != "")] |
             sort_by(-.fix_effectiveness_rate // 0) | .[:2][] |
             "- Pattern: \(.pattern[:80])\n  Root cause: \(.root_cause)\n  Fix: \(.fix)"' \
            "$failures_file" 2>/dev/null || true)
    fi

    # Build valid categories list (from compat.sh if available, else built-in defaults)
    local valid_cats="test_failure, build_error, lint_error, timeout, dependency, flaky, config"
    if [[ -n "${SW_ERROR_CATEGORIES:-}" ]]; then
        valid_cats=$(echo "$SW_ERROR_CATEGORIES" | tr ' ' ', ')
    fi

    # Build the analysis prompt
    local prompt
    prompt="Analyze this pipeline failure. The stage was: ${stage}.
The error pattern is: ${last_pattern}

Log output (last 200 lines):
${log_tail}"

    if [[ -n "$past_examples" ]]; then
        prompt="${prompt}

Here are examples of how similar failures were diagnosed in this repo:
${past_examples}"
    fi

    prompt="${prompt}

Return ONLY a JSON object with exactly these fields:
{\"root_cause\": \"one-line root cause\", \"fix\": \"one-line fix suggestion\", \"category\": \"one of: ${valid_cats}\"}

Return JSON only, no markdown fences, no explanation."

    # Call Claude for analysis
    local analysis
    analysis=$(claude -p "$prompt" --model sonnet 2>/dev/null) || {
        warn "Claude analysis failed"
        return 1
    }

    # Extract JSON — strip markdown fences if present
    analysis=$(echo "$analysis" | sed 's/^```json//; s/^```//; s/```$//' | tr -d '\n')

    # Parse the fields
    local root_cause fix category
    root_cause=$(echo "$analysis" | jq -r '.root_cause // ""' 2>/dev/null) || root_cause=""
    fix=$(echo "$analysis" | jq -r '.fix // ""' 2>/dev/null) || fix=""
    category=$(echo "$analysis" | jq -r '.category // "unknown"' 2>/dev/null) || category="unknown"

    if [[ -z "$root_cause" || "$root_cause" == "null" ]]; then
        warn "Could not parse analysis response"
        return 1
    fi

    # Validate category against shared taxonomy (compat.sh) or built-in list
    if type sw_valid_error_category >/dev/null 2>&1; then
        if ! sw_valid_error_category "$category"; then
            category="unknown"
        fi
    else
        case "$category" in
            test_failure|build_error|lint_error|timeout|dependency|flaky|config) ;;
            *) category="unknown" ;;
        esac
    fi

    # Update the most recent failure entry with root_cause, fix, category
    local tmp_file
    tmp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN
    jq --arg rc "$root_cause" \
       --arg fix "$fix" \
       --arg cat "$category" \
       '.failures[-1].root_cause = $rc | .failures[-1].fix = $fix | .failures[-1].category = $cat' \
       "$failures_file" > "$tmp_file" && mv "$tmp_file" "$failures_file"

    emit_event "memory.analyze" "stage=${stage}" "category=${category}"

    success "Failure analyzed: ${PURPLE}[${category}]${RESET} ${root_cause}"
}

# memory_capture_pattern <pattern_type> <pattern_data_json>
# Records codebase patterns (project type, framework, conventions).
memory_capture_pattern() {
    local pattern_type="${1:-}"
    local pattern_data="${2:-}"

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local patterns_file="$mem_dir/patterns.json"

    local repo
    repo="$(repo_name)"
    local captured_at
    captured_at="$(now_iso)"

    local tmp_file
    tmp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN

    case "$pattern_type" in
        project)
            # Detect project attributes
            local proj_type="unknown" framework="" test_runner="" pkg_mgr="" language=""

            if [[ -f "package.json" ]]; then
                proj_type="node"
                pkg_mgr="npm"
                [[ -f "pnpm-lock.yaml" ]] && pkg_mgr="pnpm"
                [[ -f "yarn.lock" ]] && pkg_mgr="yarn"
                [[ -f "bun.lockb" ]] && pkg_mgr="bun"

                framework=$(jq -r '
                    if .dependencies.next then "next"
                    elif .dependencies.express then "express"
                    elif .dependencies.fastify then "fastify"
                    elif .dependencies.react then "react"
                    elif .dependencies.vue then "vue"
                    elif .dependencies.svelte then "svelte"
                    else ""
                    end' package.json 2>/dev/null || echo "")

                test_runner=$(jq -r '
                    if .devDependencies.jest then "jest"
                    elif .devDependencies.vitest then "vitest"
                    elif .devDependencies.mocha then "mocha"
                    else ""
                    end' package.json 2>/dev/null || echo "")

                [[ -f "tsconfig.json" ]] && language="typescript" || language="javascript"
            elif [[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]]; then
                proj_type="python"
                language="python"
                [[ -f "pyproject.toml" ]] && pkg_mgr="poetry" || pkg_mgr="pip"
                test_runner="pytest"
            elif [[ -f "go.mod" ]]; then
                proj_type="go"
                language="go"
                test_runner="go test"
            elif [[ -f "Cargo.toml" ]]; then
                proj_type="rust"
                language="rust"
                test_runner="cargo test"
                pkg_mgr="cargo"
            fi

            local source_dir=""
            [[ -d "src" ]] && source_dir="src/"
            [[ -d "lib" ]] && source_dir="lib/"
            [[ -d "app" ]] && source_dir="app/"

            local test_pattern=""
            if [[ -n "$(find . -maxdepth 3 -name '*.test.ts' 2>/dev/null | head -1)" ]]; then
                test_pattern="*.test.ts"
            elif [[ -n "$(find . -maxdepth 3 -name '*.test.js' 2>/dev/null | head -1)" ]]; then
                test_pattern="*.test.js"
            elif [[ -n "$(find . -maxdepth 3 -name '*_test.go' 2>/dev/null | head -1)" ]]; then
                test_pattern="*_test.go"
            elif [[ -n "$(find . -maxdepth 3 -name 'test_*.py' 2>/dev/null | head -1)" ]]; then
                test_pattern="test_*.py"
            fi

            local import_style="commonjs"
            if [[ -f "package.json" ]]; then
                local pkg_type
                pkg_type=$(jq -r '.type // "commonjs"' package.json 2>/dev/null || echo "commonjs")
                [[ "$pkg_type" == "module" ]] && import_style="esm"
            fi

            jq --arg repo "$repo" \
               --arg ts "$captured_at" \
               --arg type "$proj_type" \
               --arg fw "$framework" \
               --arg tr "$test_runner" \
               --arg pm "$pkg_mgr" \
               --arg lang "$language" \
               --arg sd "$source_dir" \
               --arg tp "$test_pattern" \
               --arg is "$import_style" \
               '. + {
                   repo: $repo,
                   captured_at: $ts,
                   project: {
                       type: $type,
                       framework: $fw,
                       test_runner: $tr,
                       package_manager: $pm,
                       language: $lang
                   },
                   conventions: {
                       source_dir: $sd,
                       test_pattern: $tp,
                       import_style: $is
                   }
               }' "$patterns_file" > "$tmp_file" && mv "$tmp_file" "$patterns_file"

            # Dual-write to DB
            if type db_save_pattern >/dev/null 2>&1; then
                local rhash proj_desc
                rhash="$(repo_hash)"
                proj_desc="type=$proj_type,framework=$framework,test_runner=$test_runner,package_manager=$pkg_mgr,language=$language"
                db_save_pattern "$rhash" "project" "project" "$proj_desc" "" 2>/dev/null || true
            fi
            memory_store_for_embedding "pattern" "project: $proj_type/$framework, $pkg_mgr, $language" "$(repo_hash)" 2>/dev/null || true
            emit_event "memory.pattern" "type=project" "proj_type=${proj_type}" "framework=${framework}"
            success "Captured project patterns (${proj_type}/${framework:-none})"
            ;;

        known_issue)
            # pattern_data is the issue description string
            if [[ -n "$pattern_data" ]]; then
                jq --arg issue "$pattern_data" \
                   'if .known_issues then
                        if (.known_issues | index($issue)) then .
                        else .known_issues += [$issue]
                        end
                    else . + {known_issues: [$issue]}
                    end | .known_issues = (.known_issues | .[-50:])' \
                   "$patterns_file" > "$tmp_file" && mv "$tmp_file" "$patterns_file"
                # Dual-write to DB
                if type db_save_pattern >/dev/null 2>&1; then
                    local rhash issue_key
                    rhash="$(repo_hash)"
                    issue_key=$(echo -n "$pattern_data" | shasum -a 256 | cut -c1-16)
                    db_save_pattern "$rhash" "known_issue" "$issue_key" "$pattern_data" "" 2>/dev/null || true
                fi
                memory_store_for_embedding "pattern" "known_issue: $pattern_data" "$(repo_hash)" 2>/dev/null || true
                emit_event "memory.pattern" "type=known_issue"
            fi
            ;;

        *)
            warn "Unknown pattern type: ${pattern_type}"
            return 1
            ;;
    esac
}

# memory_get_actionable_failures [threshold]
# Returns JSON array of failure patterns with seen_count >= threshold.
# Used by daemon patrol to detect recurring failures worth fixing.
memory_get_actionable_failures() {
    local threshold="${1:-3}"

    ensure_memory_dir
    local mem_dir
    mem_dir="$(repo_memory_dir)"
    local failures_file="$mem_dir/failures.json"

    if [[ ! -f "$failures_file" ]]; then
        echo "[]"
        return 0
    fi

    jq --argjson t "$threshold" \
        '[.failures[] | select(.seen_count >= $t)] | sort_by(-.seen_count)' \
        "$failures_file" 2>/dev/null || echo "[]"
}
