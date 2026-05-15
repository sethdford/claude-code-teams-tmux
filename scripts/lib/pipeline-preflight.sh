#!/usr/bin/env bash
# pipeline-preflight.sh — Pre-Flight Issue Feasibility Validator (#488)
#
# Runs BEFORE any pipeline stage executes. Rejects pipelines that would
# obviously fail (dirty git, missing deps, vague issue, broken test command,
# concurrent pipeline on same issue) so we don't burn budget on doomed work.
#
# Distinct from pipeline-feasibility.sh (which runs AFTER intake and scores
# issue clarity). This module runs ahead of intake to gate spawning.
#
# Public API:
#   preflight_validate <issue|"">  <goal|""> <artifacts_dir>
#       → exit 0 = PASS or WARN, 1 = BLOCK
#       → writes preflight.json and preflight-report.md
#
#   preflight_log_rejection <issue> <verdict> <reasons_json>
#       → appends to ~/.shipwright/memory/preflight-rejections.jsonl
#
# Env / config:
#   SW_PREFLIGHT_ENABLED=false       skip validator (returns PASS)
#   SW_PREFLIGHT_FORCE=true          run checks but always return PASS
#   SW_PREFLIGHT_MIN_CLARITY=20      minimum issue-clarity score (0-100)
#   NO_GITHUB=true                   skip github label/comment side effects

[[ -n "${_PIPELINE_PREFLIGHT_LOADED:-}" ]] && return 0
_PIPELINE_PREFLIGHT_LOADED=1

VERSION="3.3.0"

_PREFLIGHT_MEMORY_FILE="${PREFLIGHT_MEMORY_FILE:-$HOME/.shipwright/memory/preflight-rejections.jsonl}"

# Fallback helpers when sourced standalone (in tests, CLI)
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { :; }
[[ "$(type -t info 2>/dev/null)"        == "function" ]] || info()        { echo "$*"; }
[[ "$(type -t warn 2>/dev/null)"        == "function" ]] || warn()        { echo "$*" >&2; }
[[ "$(type -t error 2>/dev/null)"       == "function" ]] || error()       { echo "$*" >&2; }

# ─── Individual checks ──────────────────────────────────────────────────────
# Each check writes one line on stdout: "<status>\t<name>\t<message>\t<fix>"
# Status: ok | warn | block

_pf_check_git_state() {
    local name="git_state"
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'block\t%s\tNot inside a git repository\tRun shipwright from a git repo or use --no-github\n' "$name"
        return
    fi
    local dirty
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${dirty:-0}" -gt 50 ]]; then
        printf 'block\t%s\tWorking tree has %s uncommitted change(s)\tCommit/stash changes or use --skip-gates to auto-stash\n' "$name" "$dirty"
        return
    fi
    if [[ "${dirty:-0}" -gt 0 ]]; then
        printf 'warn\t%s\t%s uncommitted change(s) — may be auto-stashed\tCommit/stash before starting for safety\n' "$name" "$dirty"
        return
    fi
    printf 'ok\t%s\tWorking tree clean\t\n' "$name"
}

_pf_check_issue_clarity() {
    local name="issue_clarity"
    local issue="${1:-}" goal="${2:-}"
    local min="${SW_PREFLIGHT_MIN_CLARITY:-20}"
    [[ "$min" =~ ^[0-9]+$ ]] || min=20

    local title="" body=""
    if [[ -n "$issue" && "${NO_GITHUB:-}" != "true" ]] && command -v gh >/dev/null 2>&1; then
        local payload
        payload=$(gh issue view "$issue" --json title,body 2>/dev/null || echo "")
        if [[ -n "$payload" ]]; then
            title=$(echo "$payload" | jq -r '.title // ""' 2>/dev/null || echo "")
            body=$(echo "$payload" | jq -r '.body  // ""' 2>/dev/null || echo "")
        fi
    fi
    [[ -z "$title" && -n "$goal" ]] && title="$goal"

    if [[ -z "$title" && -z "$body" ]]; then
        printf 'warn\t%s\tNo issue/goal content available to score\tProvide --goal or a reachable --issue\n' "$name"
        return
    fi

    local title_len=${#title}
    local body_words
    body_words=$(printf '%s' "$body" | wc -w | tr -d ' ')
    [[ "$body_words" =~ ^[0-9]+$ ]] || body_words=0
    local criteria_count
    criteria_count=$(printf '%s' "$body" | grep -ciE '^[[:space:]]*[-*][[:space:]]*\[[ x]\]' 2>/dev/null || echo 0)
    [[ "$criteria_count" =~ ^[0-9]+$ ]] || criteria_count=0

    local score=$(( title_len + body_words + criteria_count * 3 ))
    if (( score < min )); then
        printf 'block\t%s\tIssue too vague (clarity=%d < %d)\tAdd acceptance criteria or expand the description before retrying\n' "$name" "$score" "$min"
        return
    fi
    if (( score < min * 2 )); then
        printf 'warn\t%s\tIssue clarity marginal (clarity=%d)\tConsider adding acceptance criteria\n' "$name" "$score"
        return
    fi
    printf 'ok\t%s\tIssue clarity acceptable (clarity=%d)\t\n' "$name" "$score"
}

_pf_check_dependencies() {
    local name="dependencies"
    local missing=""
    for tool in git jq; do
        command -v "$tool" >/dev/null 2>&1 || missing="${missing}${missing:+, }${tool}"
    done
    if [[ -n "$missing" ]]; then
        printf 'block\t%s\tMissing required tools: %s\tInstall: brew/apt install %s\n' "$name" "$missing" "$missing"
        return
    fi

    if [[ -f package.json ]]; then
        if ! jq empty package.json 2>/dev/null; then
            printf 'block\t%s\tpackage.json is not valid JSON\tFix syntax errors in package.json\n' "$name"
            return
        fi
    fi
    printf 'ok\t%s\tRequired tools present\t\n' "$name"
}

_pf_check_test_command() {
    local name="test_command"
    local override="${TEST_CMD:-}"
    if [[ -n "$override" ]]; then
        local bin="${override%% *}"
        if [[ "$bin" == */* ]]; then
            [[ -x "$bin" ]] || { printf 'warn\t%s\tTest command path not executable: %s\tEnsure %s exists and is executable\n' "$name" "$bin" "$bin"; return; }
        fi
        printf 'ok\t%s\tTest command override accepted: %s\t\n' "$name" "$override"
        return
    fi

    if [[ -f package.json ]]; then
        # jq -e validates JSON shape AND that .scripts.test is a non-empty string.
        # If jq can parse it cleanly, npm/node will accept it too.
        local script
        if ! script=$(jq -er '.scripts.test // empty' package.json 2>/dev/null) || [[ -z "$script" ]]; then
            printf 'warn\t%s\tNo "test" script in package.json\tAdd "scripts.test" or pass --test-cmd\n' "$name"
            return
        fi
        printf 'ok\t%s\tnpm test script present\t\n' "$name"
        return
    fi
    printf 'warn\t%s\tNo package.json — test command cannot be auto-detected\tProvide --test-cmd explicitly\n' "$name"
}

_pf_check_no_conflicts() {
    local name="no_conflicts"
    local issue="${1:-}"
    [[ -z "$issue" ]] && { printf 'ok\t%s\tNo issue scope — concurrency check skipped\t\n' "$name"; return; }

    local hb_dir="$HOME/.shipwright/heartbeats"
    if [[ -d "$hb_dir" ]]; then
        local f
        for f in "$hb_dir"/*.json; do
            [[ -f "$f" ]] || continue
            local hb_issue hb_pid
            hb_issue=$(jq -r '.issue // ""' "$f" 2>/dev/null || echo "")
            hb_pid=$(jq -r '.pid // ""' "$f" 2>/dev/null || echo "")
            if [[ "$hb_issue" == "$issue" ]]; then
                if [[ -n "$hb_pid" ]] && kill -0 "$hb_pid" 2>/dev/null; then
                    printf 'block\t%s\tAnother pipeline (pid=%s) is already running for issue #%s\tWait for it to finish, or remove stale heartbeat: %s\n' "$name" "$hb_pid" "$issue" "$f"
                    return
                fi
            fi
        done
    fi

    # Use POSIX-friendly anchors: end-of-line or a path/word separator.
    # Avoids \b (GNU-only) so we work the same on BSD grep (macOS).
    if git worktree list 2>/dev/null | grep -E "(daemon-issue-${issue}|/issue-${issue})([^0-9]|$)" >/dev/null; then
        printf 'warn\t%s\tA worktree already exists for issue #%s\tRemove with: git worktree remove daemon-issue-%s --force\n' "$name" "$issue" "$issue"
        return
    fi
    printf 'ok\t%s\tNo concurrent pipeline detected\t\n' "$name"
}

# ─── Aggregator ────────────────────────────────────────────────────────────
# preflight_validate <issue> <goal> <artifacts_dir>
preflight_validate() {
    local issue="${1:-}"
    local goal="${2:-}"
    local artifacts_dir="${3:-${ARTIFACTS_DIR:-.claude/pipeline-artifacts}}"

    if [[ "${SW_PREFLIGHT_ENABLED:-}" == "false" || "${SW_PREFLIGHT_ENABLED:-}" == "0" ]]; then
        emit_event "preflight.skip" "issue=${issue:-0}" "reason=disabled" 2>/dev/null || true
        return 0
    fi

    mkdir -p "$artifacts_dir" 2>/dev/null || true

    local checks_json="[]"
    local block_count=0 warn_count=0 ok_count=0

    local raw
    while IFS=$'\t' read -r status cname cmsg cfix; do
        [[ -z "$status" ]] && continue
        case "$status" in
            block) block_count=$(( block_count + 1 )) ;;
            warn)  warn_count=$(( warn_count + 1 ))   ;;
            ok)    ok_count=$(( ok_count + 1 ))       ;;
        esac
        checks_json=$(echo "$checks_json" | jq \
            --arg s "$status" --arg n "$cname" --arg m "$cmsg" --arg f "$cfix" \
            '. + [{name:$n, status:$s, message:$m, fix:$f}]' 2>/dev/null || echo "$checks_json")
    done < <(
        _pf_check_git_state
        _pf_check_issue_clarity "$issue" "$goal"
        _pf_check_dependencies
        _pf_check_test_command
        _pf_check_no_conflicts "$issue"
    )

    local verdict
    if (( block_count > 0 )); then verdict="BLOCK"
    elif (( warn_count > 0 )); then verdict="WARN"
    else verdict="PASS"
    fi

    # --force / SW_PREFLIGHT_FORCE downgrades BLOCK→WARN but keeps the report
    local forced=false
    if [[ "${SW_PREFLIGHT_FORCE:-}" == "true" && "$verdict" == "BLOCK" ]]; then
        verdict="WARN"
        forced=true
    fi

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local out_json="$artifacts_dir/preflight.json"
    local out_md="$artifacts_dir/preflight-report.md"
    local tmp_json
    tmp_json=$(mktemp "${TMPDIR:-/tmp}/preflight.XXXXXX")

    jq -n \
        --arg ts "$timestamp" \
        --arg issue "$issue" \
        --arg goal "$goal" \
        --arg verdict "$verdict" \
        --argjson forced "$forced" \
        --argjson checks "$checks_json" \
        '{
            timestamp: $ts,
            issue: $issue,
            goal: $goal,
            verdict: $verdict,
            forced: $forced,
            checks: $checks
        }' > "$tmp_json" 2>/dev/null || echo '{"verdict":"PASS","checks":[]}' > "$tmp_json"
    mv "$tmp_json" "$out_json"

    _pf_write_report "$out_json" "$out_md" "$verdict"

    emit_event "preflight.$(echo "$verdict" | tr '[:upper:]' '[:lower:]')" \
        "issue=${issue:-0}" "blocks=${block_count}" "warns=${warn_count}" "forced=${forced}" 2>/dev/null || true

    if [[ "$verdict" == "BLOCK" ]]; then
        preflight_log_rejection "$issue" "$verdict" "$checks_json" 2>/dev/null || true
        _pf_github_label "$issue" 2>/dev/null || true
        warn "Preflight BLOCK — see ${out_md}"
        return 1
    fi
    return 0
}

_pf_write_report() {
    local json="$1" out="$2" verdict="$3"
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/preflight-md.XXXXXX")
    {
        echo "# Pre-Flight Validation Report"
        echo
        echo "- **Verdict**: \`${verdict}\`"
        echo "- **Generated**: $(jq -r '.timestamp' "$json" 2>/dev/null)"
        echo
        echo "## Checks"
        echo
        echo "| Check | Status | Message | Fix |"
        echo "|---|---|---|---|"
        jq -r '.checks[] | "| \(.name) | \(.status) | \(.message) | \(.fix) |"' "$json" 2>/dev/null
        echo
        if [[ "$verdict" == "BLOCK" ]]; then
            echo "## Why this matters"
            echo
            echo "The pipeline was rejected before consuming budget/time because at least one"
            echo "check failed. Fix the items marked \`block\` above and retry, or override with"
            echo "\`--force\` / \`SW_PREFLIGHT_FORCE=true\`."
        fi
    } > "$tmp"
    mkdir -p "$(dirname "$out")" 2>/dev/null || true
    mv "$tmp" "$out"
}

preflight_log_rejection() {
    local issue="${1:-}"
    local verdict="${2:-BLOCK}"
    local checks_json="${3:-[]}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$_PREFLIGHT_MEMORY_FILE")" 2>/dev/null || true
    local line
    line=$(jq -nc \
        --arg ts "$ts" \
        --arg issue "$issue" \
        --arg verdict "$verdict" \
        --argjson checks "$checks_json" \
        '{timestamp:$ts, issue:$issue, verdict:$verdict, checks:$checks}' 2>/dev/null || echo "")
    [[ -n "$line" ]] && printf '%s\n' "$line" >> "$_PREFLIGHT_MEMORY_FILE"
}

_pf_github_label() {
    local issue="${1:-}"
    [[ -z "$issue" || "${NO_GITHUB:-}" == "true" ]] && return 0
    command -v gh >/dev/null 2>&1 || return 0
    gh issue edit "$issue" --add-label "pipeline/preflight-rejected" >/dev/null 2>&1 || true
}
