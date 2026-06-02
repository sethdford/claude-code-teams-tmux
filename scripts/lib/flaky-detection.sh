#!/usr/bin/env bash
# Module guard - prevent double-sourcing
[[ -n "${_FLAKY_DETECTION_LOADED:-}" ]] && return 0
_FLAKY_DETECTION_LOADED=1

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  flaky-detection.sh — Flaky Test Detection & Auto-Quarantine             ║
# ║                                                                          ║
# ║  Records per-test pass/fail history, detects tests whose failure rate    ║
# ║  over the last N runs crosses a variance threshold, and quarantines      ║
# ║  them with a reversible framework-appropriate skip annotation.           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# shellcheck disable=SC2034
VERSION="3.3.0"

_FLAKY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Output Helpers (fallback if not already loaded) ─────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
    now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
    now_epoch() { date +%s; }
fi

# DB layer (provides db_record_test_result, db_flaky_candidates, etc.)
# shellcheck source=../sw-db.sh
[[ -f "$_FLAKY_DIR/../sw-db.sh" ]] && source "$_FLAKY_DIR/../sw-db.sh"

# ─── Configuration (env → daemon-config.json → default) ──────────────────────
# Uses _smart_int from compat.sh when available; otherwise plain defaults.
_flaky_cfg_int() {
    local key="$1" default="$2"
    if type _smart_int >/dev/null 2>&1; then
        _smart_int "$key" "$default"
    else
        echo "$default"
    fi
}

flaky_variance_threshold() { _flaky_cfg_int "patrol.flaky_variance_threshold" "20"; }
flaky_window()             { _flaky_cfg_int "patrol.flaky_window" "10"; }
flaky_min_runs()           { _flaky_cfg_int "patrol.flaky_min_runs" "3"; }
flaky_required_failures()  { _flaky_cfg_int "patrol.flaky_required_failures" "2"; }
flaky_max_issues()         { _flaky_cfg_int "patrol.flaky_max_issues" "5"; }
FLAKY_LABEL="${FLAKY_LABEL:-flaky-test}"

# ─── Result Parsing ──────────────────────────────────────────────────────────
# _flaky_parse_results — read test output on stdin, emit "STATUS<TAB>test_name".
# Supports two framework-agnostic formats:
#   • TAP (vitest --reporter=tap, jest-tap-reporter, tape, node --test):
#       ok 1 - name        → PASS
#       not ok 2 - name    → FAIL
#       ok 3 - name # SKIP  → SKIP
#   • Symbol reporters (vitest/jest/mocha default pretty output):
#       ✓ / √  name        → PASS
#       ✗ / ✕ / ×  name    → FAIL
#       ↓ / - / ○  name    → SKIP (skipped/todo)
# Lines that match neither are ignored. Test names are trimmed and de-duped
# keeping the LAST occurrence (final status wins within a single run).
_flaky_parse_results() {
    awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
        line = $0
        status = ""
        name = ""

        # ── TAP ──
        if (line ~ /^[ \t]*not ok[ \t]+[0-9]+/) {
            status = "FAIL"
            sub(/^[ \t]*not ok[ \t]+[0-9]+[ \t]*-?[ \t]*/, "", line)
            name = line
        } else if (line ~ /^[ \t]*ok[ \t]+[0-9]+/) {
            status = "PASS"
            sub(/^[ \t]*ok[ \t]+[0-9]+[ \t]*-?[ \t]*/, "", line)
            name = line
            if (name ~ /#[ \t]*([Ss][Kk][Ii][Pp]|[Tt][Oo][Dd][Oo])/) status = "SKIP"
            sub(/[ \t]*#.*$/, "", name)  # strip TAP directive
        }
        # ── Symbol reporters ──
        else if (line ~ /[✓√]/) {
            status = "PASS"; sub(/^.*[✓√][ \t]*/, "", line); name = line
        } else if (line ~ /[✗✕×]/) {
            status = "FAIL"; sub(/^.*[✗✕×][ \t]*/, "", line); name = line
        } else if (line ~ /[↓○]/) {
            status = "SKIP"; sub(/^.*[↓○][ \t]*/, "", line); name = line
        } else {
            next
        }

        # strip trailing duration annotations like "(5ms)" or "12ms"
        sub(/[ \t]*\([0-9]+[ \t]*m?s\)[ \t]*$/, "", name)
        name = trim(name)
        if (name == "") next

        last[name] = status
        order[name] = NR
    }
    END {
        for (n in last) print last[n] "\t" n
    }
    '
}

# flaky_record_results <pipeline_id> <results_file>
# Parses a test-output file and records each test result transactionally.
# Guarded: no-op (return 0) when DB unavailable so callers stay safe in CI.
flaky_record_results() {
    local pipeline_id="$1" results_file="$2"
    if [[ -z "$pipeline_id" || -z "$results_file" ]]; then
        error "flaky_record_results: pipeline_id and results_file required"
        return 1
    fi
    if [[ ! -f "$results_file" ]]; then
        error "flaky_record_results: no such file: $results_file"
        return 1
    fi
    if ! type db_available >/dev/null 2>&1 || ! db_available; then
        return 0
    fi

    local recorded=0 status name
    while IFS=$'\t' read -r status name; do
        [[ -z "$name" ]] && continue
        db_record_test_result "$pipeline_id" "$name" "$status" && recorded=$((recorded + 1))
    done < <(_flaky_parse_results < "$results_file")

    if type emit_event >/dev/null 2>&1; then
        emit_event "flaky.results_recorded" "pipeline_id=$pipeline_id" "count=$recorded"
    fi
    [[ "$recorded" -gt 0 ]] && info "Recorded $recorded test result(s) for pipeline $pipeline_id"
    return 0
}

# flaky_detect [--json]
# Returns tests exceeding the variance threshold over the last N runs.
flaky_detect() {
    local as_json=false
    [[ "${1:-}" == "--json" ]] && as_json=true

    local threshold window min_runs req_fail
    threshold=$(flaky_variance_threshold)
    window=$(flaky_window)
    min_runs=$(flaky_min_runs)
    req_fail=$(flaky_required_failures)

    if ! type db_available >/dev/null 2>&1 || ! db_available; then
        $as_json && echo "[]" || warn "Database unavailable — cannot detect flaky tests"
        return 0
    fi

    local candidates
    candidates=$(db_flaky_candidates "$threshold" "$window" "$min_runs" "$req_fail")
    [[ -z "$candidates" ]] && candidates="[]"

    if type emit_event >/dev/null 2>&1; then
        local n
        n=$(echo "$candidates" | jq 'length' 2>/dev/null || echo 0)
        emit_event "flaky.detected" "count=$n" "threshold=$threshold"
    fi

    if $as_json; then
        echo "$candidates"
        return 0
    fi

    local count
    count=$(echo "$candidates" | jq 'length' 2>/dev/null || echo 0)
    if [[ "${count:-0}" -eq 0 ]]; then
        success "No flaky tests detected (threshold ${threshold}% over last ${window} runs)"
        return 0
    fi
    warn "Detected ${count} flaky test(s) (>= ${threshold}% failure over last ${window} runs):"
    echo "$candidates" | jq -r '.[] | "  • \(.test_name) — \(.failure_rate)% (\(.failures)/\(.runs) runs)"' 2>/dev/null
    return 0
}

# ─── Quarantine (source mutation) ────────────────────────────────────────────
# _flaky_test_title <test_name> — extract the leaf test title from a recorded
# name like "test/foo.test.js > describe > should do x" → "should do x".
_flaky_test_title() {
    local n="$1"
    n="${n##* > }"   # drop everything up to the last " > "
    echo "$n"
}

# flaky_quarantine_test <test_name> [test_file] [issue_url]
# Adds a reversible `.skip` annotation + QUARANTINED comment above the test
# declaration. Only mutates source when exactly ONE unambiguous declaration
# line is found; otherwise it records the quarantine and returns 2 (caller
# should file an issue for manual handling). Records the quarantine in the DB
# regardless so the dashboard and detection cooldown reflect it.
flaky_quarantine_test() {
    local test_name="$1" test_file="${2:-}" issue_url="${3:-}"
    [[ -z "$test_name" ]] && { error "flaky_quarantine_test: test_name required"; return 1; }

    local failure_rate=0 runs=0
    if type db_available >/dev/null 2>&1 && db_available; then
        local hist
        hist=$(db_query_test_history "$test_name" "$(flaky_window)")
        runs=$(echo "$hist" | jq '[.[] | select(.status=="PASS" or .status=="FAIL")] | length' 2>/dev/null || echo 0)
        local fails
        fails=$(echo "$hist" | jq '[.[] | select(.status=="FAIL")] | length' 2>/dev/null || echo 0)
        if [[ "${runs:-0}" -gt 0 ]]; then
            failure_rate=$(awk -v f="$fails" -v r="$runs" 'BEGIN{printf "%.2f", f*100.0/r}')
        fi
    fi

    local title
    title=$(_flaky_test_title "$test_name")

    # Locate the test file if not provided: search the leaf title in test dirs.
    if [[ -z "$test_file" ]]; then
        test_file=$(grep -rlF "$title" test/ tests/ src/ 2>/dev/null \
            | grep -E '\.(test|spec)\.(js|ts|jsx|tsx|mjs|cjs)$' | head -1 || true)
    fi

    local mutated=false
    if [[ -n "$test_file" && -f "$test_file" ]]; then
        if _flaky_apply_skip "$test_file" "$title" "$failure_rate" "$issue_url"; then
            mutated=true
        fi
    fi

    # Always record the quarantine so dashboard / cooldown stay accurate.
    if type db_record_quarantine >/dev/null 2>&1; then
        db_record_quarantine "$test_name" "$failure_rate" "$runs" "$issue_url" "$test_file" || true
    fi
    if type emit_event >/dev/null 2>&1; then
        emit_event "flaky.quarantined" "test=$test_name" "mutated=$mutated" "failure_rate=$failure_rate"
    fi

    if $mutated; then
        success "Quarantined ${title} in ${test_file} (${failure_rate}% failure)"
        return 0
    fi
    warn "Recorded quarantine for ${title} but could not safely edit source (ambiguous or not found) — manual skip needed"
    return 2
}

# _flaky_apply_skip <file> <title> <failure_rate> <issue_url>
# Idempotent, atomic source mutation. Converts `test(`/`it(` to `.skip(` for an
# unambiguous declaration of <title>. Returns 1 (no change) if the title is
# ambiguous, missing, or already quarantined.
_flaky_apply_skip() {
    local file="$1" title="$2" failure_rate="$3" issue_url="$4"
    [[ -f "$file" ]] || return 1

    # Escape title for use in a fixed-string grep.
    local matches
    matches=$(grep -nE "(test|it)(\.[a-zA-Z]+)?\(['\"\`]" "$file" 2>/dev/null \
        | grep -F "$title" || true)
    local match_count
    match_count=$(printf '%s\n' "$matches" | grep -c . || true)
    [[ "${match_count:-0}" -ne 1 ]] && return 1   # ambiguous or not found

    local lineno
    lineno=$(printf '%s\n' "$matches" | head -1 | cut -d: -f1)
    [[ "$lineno" =~ ^[0-9]+$ ]] || return 1

    local line
    line=$(sed -n "${lineno}p" "$file")
    # Already quarantined?
    echo "$line" | grep -qE "(test|it)\.skip\(" && return 1

    # Build replacement: test( → test.skip(   it( → it.skip(
    local newline
    newline=$(echo "$line" | sed -E 's/\b(test|it)\(/\1.skip(/')
    [[ "$newline" == "$line" ]] && return 1   # nothing changed → bail safely

    local indent comment
    indent=$(printf '%s\n' "$line" | sed -E 's/[^ \t].*$//')
    comment="${indent}// QUARANTINED: flaky test (${failure_rate}% failure rate)"
    [[ -n "$issue_url" ]] && comment="${comment}\n${indent}// See: ${issue_url}"

    # Atomic write via temp file + mv.
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/flaky.XXXXXX") || return 1
    awk -v ln="$lineno" -v cmt="$comment" -v repl="$newline" '
        NR==ln { printf "%s\n", cmt; print repl; next }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    return 0
}

# ─── GitHub Issue Filing ─────────────────────────────────────────────────────
# flaky_create_issue <test_name> <failure_rate> <runs> [failures]
# De-duped against existing `flaky-test` issues, capped at flaky_max_issues per
# run, NO_GITHUB-guarded. Echoes the issue URL on success (empty otherwise).
flaky_create_issue() {
    local test_name="$1" failure_rate="${2:-0}" runs="${3:-0}" failures="${4:-0}"
    [[ -z "$test_name" ]] && return 1

    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        return 0
    fi

    local title="[Flaky Test] ${test_name} (${failure_rate}% failure rate)"

    # Dedup: existing open flaky-test issue mentioning this test name?
    local existing
    existing=$(gh issue list --label "$FLAKY_LABEL" --state open \
        --search "$test_name in:title" --json url -q '.[0].url' 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        echo "$existing"
        return 0
    fi

    # Build a failure-pattern table from recent history.
    local history_table="(history unavailable)"
    if type db_query_test_history >/dev/null 2>&1; then
        local hist
        hist=$(db_query_test_history "$test_name" "$(flaky_window)")
        history_table=$(echo "$hist" | jq -r '
            "| When | Status | Pipeline |\n|------|--------|----------|",
            (.[] | "| \(.created_at) | \(.status) | \(.pipeline_id) |")' 2>/dev/null \
            || echo "(history unavailable)")
    fi

    local body
    body=$(cat <<EOF
## Flaky Test Detected

A test has been flagged as flaky by \`shipwright flaky detect\` and auto-quarantined.

| Field | Value |
|-------|-------|
| Test | \`${test_name}\` |
| Failure rate | **${failure_rate}%** |
| Window | last ${runs} run(s) |
| Failures | ${failures} |
| Detected | $(now_iso) |

### Recent history

${history_table}

### Next steps

- Investigate the root cause (timing, shared state, ordering, external deps).
- Once fixed, un-skip the test and run \`shipwright flaky lift ${test_name}\`.

_Auto-filed by Shipwright flaky-test detection._
EOF
)

    local url
    url=$(gh issue create --title "$title" --body "$body" --label "$FLAKY_LABEL" 2>/dev/null \
        | grep -Eo 'https://[^ ]+' | head -1 || true)
    if [[ -n "$url" ]]; then
        if type emit_event >/dev/null 2>&1; then
            emit_event "flaky.issue_created" "test=$test_name" "url=$url"
        fi
        echo "$url"
    fi
    return 0
}
