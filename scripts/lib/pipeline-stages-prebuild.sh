# pipeline-stages-prebuild.sh — pre_build_validate stage (fast-fail dependency health check)
# Source from pipeline-stages.sh. Requires pipeline globals (PROJECT_ROOT, PIPELINE_CONFIG,
# ARTIFACTS_DIR, TEST_CMD) and helpers (info/warn/error/success, emit_event).
#
# Runs BEFORE build to catch broken dependency manifests, missing test runners, and
# unresolved merge conflicts before an expensive build loop spins up. All checks are
# designed to finish in well under 30 seconds. A blocking failure returns 1, which the
# execution engine classifies as a "configuration" error → fast-fail, no retry.
#
# Distinct from stage_validate (pipeline-stages-monitor.sh), which runs post-deploy
# smoke tests. Do not conflate the two; the SKIP_PREBUILD_VALIDATE flag affects ONLY
# this stage.
[[ -n "${_PIPELINE_STAGES_PREBUILD_LOADED:-}" ]] && return 0
_PIPELINE_STAGES_PREBUILD_LOADED=1

VERSION="3.3.0"

# Findings buffer — one JSON object per check (bash 3.2: plain indexed array, no assoc).
_PBV_FINDINGS=()

# _pbv_add_finding <id> <status> <blocking> <message> [location]
# Appends a JSON check object to the findings buffer. Message/location are JSON-escaped.
_pbv_add_finding() {
    local id="$1" status="$2" blocking="$3" message="$4" location="${5:-}"
    # JSON-escape (backslash, then quote, then newline/tab) — matches emit_event convention.
    local m="$message"
    m="${m//\\/\\\\}"; m="${m//\"/\\\"}"; m="${m//$'\n'/\\n}"; m="${m//$'\t'/\\t}"
    local loc_json=""
    if [[ -n "$location" ]]; then
        local l="$location"
        l="${l//\\/\\\\}"; l="${l//\"/\\\"}"; l="${l//$'\n'/\\n}"; l="${l//$'\t'/\\t}"
        loc_json=",\"location\":\"${l}\""
    fi
    _PBV_FINDINGS+=("{\"id\":\"${id}\",\"status\":\"${status}\",\"blocking\":${blocking},\"message\":\"${m}\"${loc_json}}")
}

# ─── Check 1: dependency manifest syntax ──────────────────────────────────────
# package.json must parse as JSON; requirements.txt lines must be well-formed.
# return: 0 pass · 1 fail (malformed) · 2 n/a (no manifest present)
_pbv_manifest() {
    local root="$1"
    local found=0
    if [[ -f "$root/package.json" ]]; then
        found=1
        local jq_err
        if ! jq_err=$(jq empty "$root/package.json" 2>&1); then
            # Extract a line number if jq reported one (e.g. "at line 14, column 3").
            local line
            line=$(echo "$jq_err" | grep -oE 'line [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
            local loc="package.json"
            [[ -n "$line" ]] && loc="package.json:${line}"
            _pbv_add_finding "manifest" "fail" "true" \
                "package.json has invalid JSON syntax" "$loc"
            return 1
        fi
    fi
    if [[ -f "$root/requirements.txt" ]]; then
        found=1
        # A malformed requirement is a line that is non-empty, not a comment, and
        # contains whitespace inside the package spec (e.g. "foo == 1.0 extra junk").
        local lineno=0 bad_line=0
        while IFS= read -r rline || [[ -n "$rline" ]]; do
            lineno=$((lineno + 1))
            local trimmed="${rline#"${rline%%[![:space:]]*}"}"   # ltrim
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"     # rtrim
            [[ -z "$trimmed" ]] && continue
            [[ "$trimmed" == \#* ]] && continue
            [[ "$trimmed" == -* ]] && continue                   # -r / -e / --flags
            # Strip pip inline comments (whitespace + '#') before structural checks.
            case "$trimmed" in
                *" #"*) trimmed="${trimmed%% #*}" ;;
            esac
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"     # rtrim again
            # Reject embedded whitespace within the spec (no environment markers ';').
            if [[ "$trimmed" != *";"* && "$trimmed" == *[[:space:]]* ]]; then
                bad_line=$lineno
                break
            fi
        done < "$root/requirements.txt"
        if [[ $bad_line -gt 0 ]]; then
            _pbv_add_finding "manifest" "fail" "true" \
                "requirements.txt has a malformed requirement" "requirements.txt:${bad_line}"
            return 1
        fi
    fi
    if [[ $found -eq 0 ]]; then
        _pbv_add_finding "manifest" "skipped" "false" "no dependency manifest found"
        return 2
    fi
    _pbv_add_finding "manifest" "pass" "true" "dependency manifest syntax valid"
    return 0
}

# ─── Check 2: lock file integrity ─────────────────────────────────────────────
# If a manifest is present, a matching lock file should exist and be non-empty/structured.
# return: 0 pass · 1 fail · 2 n/a
_pbv_lockfile() {
    local root="$1"
    if [[ -f "$root/package.json" ]]; then
        local lock=""
        for cand in package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml; do
            [[ -f "$root/$cand" ]] && { lock="$cand"; break; }
        done
        if [[ -z "$lock" ]]; then
            _pbv_add_finding "lockfile" "skipped" "false" \
                "no lock file present (package-lock.json/yarn.lock/pnpm-lock.yaml)"
            return 2
        fi
        # JSON locks must parse; non-JSON locks must simply be non-empty.
        if [[ "$lock" == *.json ]]; then
            if ! jq empty "$root/$lock" 2>/dev/null; then
                _pbv_add_finding "lockfile" "fail" "true" \
                    "${lock} is present but not valid JSON (corrupt lock file)" "$lock"
                return 1
            fi
        elif [[ ! -s "$root/$lock" ]]; then
            _pbv_add_finding "lockfile" "fail" "true" "${lock} is empty (corrupt lock file)" "$lock"
            return 1
        fi
        _pbv_add_finding "lockfile" "pass" "true" "lock file ${lock} present and structured"
        return 0
    fi
    if [[ -f "$root/requirements.txt" ]] || [[ -f "$root/pyproject.toml" ]]; then
        # Python lock files are optional; presence is informational, never blocking.
        _pbv_add_finding "lockfile" "skipped" "false" "python project — lock file not required"
        return 2
    fi
    _pbv_add_finding "lockfile" "skipped" "false" "no manifest — lock check not applicable"
    return 2
}

# ─── Check 3: test command discoverability ────────────────────────────────────
# The first token of the resolved test command must resolve to an executable in PATH.
# return: 0 pass · 1 fail · 2 n/a (no test command configured)
_pbv_test_runner() {
    local root="$1"
    local test_cmd="${TEST_CMD:-}"
    if [[ -z "$test_cmd" && -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/nonexistent}" ]]; then
        test_cmd=$(jq -r '(.stages[] | select(.id == "build") | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$test_cmd" == "null" ]] && test_cmd=""
    fi
    if [[ -z "$test_cmd" ]]; then
        _pbv_add_finding "test_runner" "skipped" "false" "no test command configured"
        return 2
    fi
    # First token is the runner binary (e.g. "npm", "pytest", "go").
    local runner="${test_cmd%%[[:space:]]*}"
    if command -v "$runner" >/dev/null 2>&1; then
        _pbv_add_finding "test_runner" "pass" "true" "test runner '${runner}' found in PATH"
        return 0
    fi
    _pbv_add_finding "test_runner" "fail" "true" \
        "test runner '${runner}' not found in PATH (test command: ${test_cmd})"
    return 1
}

# ─── Check 4: lint (opt-in) ───────────────────────────────────────────────────
# Only runs when config.lint=true AND a lint/typecheck script exists in package.json.
# Non-blocking by default — surfaces issues without gating the build.
# return: 0 pass · 1 fail · 2 n/a (not opted in / no script)
_pbv_lint() {
    local root="$1" lint_enabled="$2"
    if [[ "$lint_enabled" != "true" ]]; then
        _pbv_add_finding "lint" "skipped" "false" "lint check not enabled"
        return 2
    fi
    if [[ ! -f "$root/package.json" ]]; then
        _pbv_add_finding "lint" "skipped" "false" "no package.json — lint not applicable"
        return 2
    fi
    local script=""
    for cand in lint typecheck; do
        if jq -e --arg s "$cand" '.scripts[$s] // empty' "$root/package.json" >/dev/null 2>&1; then
            script="$cand"; break
        fi
    done
    if [[ -z "$script" ]]; then
        _pbv_add_finding "lint" "skipped" "false" "no lint/typecheck script in package.json"
        return 2
    fi
    if (cd "$root" && npm run "$script" >/dev/null 2>&1); then
        _pbv_add_finding "lint" "pass" "false" "npm run ${script} passed"
        return 0
    fi
    _pbv_add_finding "lint" "fail" "false" "npm run ${script} reported issues"
    return 1
}

# ─── Check 5: git state (conflict markers) ────────────────────────────────────
# Detects unresolved merge-conflict markers in tracked source files (always blocking)
# and, when fail_on_dirty_worktree=true, an uncommitted working tree.
# return: 0 pass · 1 fail · 2 n/a (not a git repo)
_pbv_git_state() {
    local root="$1" fail_on_dirty="$2"
    if ! (cd "$root" && git rev-parse --git-dir >/dev/null 2>&1); then
        _pbv_add_finding "git_state" "skipped" "false" "not a git repository"
        return 2
    fi
    # Conflict markers: scan tracked files via git grep (catches both committed markers
    # and working-tree changes), excluding the pipeline artifacts dir. The leading-marker
    # regex (start-of-line '<<<<<<< ' / '>>>>>>> ' with trailing content) is specific
    # enough to avoid false positives on '=======' rules in markdown/source.
    local conflict_hit
    conflict_hit=$( (cd "$root" && git grep -nE '^(<<<<<<< |>>>>>>> )' -- ':!.claude/' 2>/dev/null) | head -1 || true )
    if [[ -n "$conflict_hit" ]]; then
        local loc="${conflict_hit%%:*}"
        local rest="${conflict_hit#*:}"
        local cline="${rest%%:*}"
        local location="$loc"
        [[ "$cline" =~ ^[0-9]+$ ]] && location="${loc}:${cline}"
        _pbv_add_finding "git_state" "fail" "true" \
            "unresolved merge conflict marker in tracked file" "$location"
        return 1
    fi
    if [[ "$fail_on_dirty" == "true" ]]; then
        local dirty
        dirty=$( (cd "$root" && git status --porcelain 2>/dev/null) | head -1 || true )
        if [[ -n "$dirty" ]]; then
            _pbv_add_finding "git_state" "fail" "true" \
                "working tree has uncommitted changes (fail_on_dirty_worktree=true)"
            return 1
        fi
    fi
    _pbv_add_finding "git_state" "pass" "true" "no conflict markers in tracked files"
    return 0
}

# ─── Check 6: required env vars ───────────────────────────────────────────────
# Reads variable NAMES from env_required_file (one per line, KEY or KEY=ignored) and
# verifies each is set in the environment. Reports missing NAMES only — never values.
# return: 0 pass · 1 fail (missing) · 2 n/a (no file)
_pbv_env_required() {
    local root="$1" env_file="$2"
    local path="$root/$env_file"
    if [[ ! -f "$path" ]]; then
        _pbv_add_finding "env_required" "skipped" "false" "no ${env_file} file"
        return 2
    fi
    local missing=""
    while IFS= read -r eline || [[ -n "$eline" ]]; do
        local name="${eline%%=*}"
        name="${name#"${name%%[![:space:]]*}"}"   # ltrim
        name="${name%"${name##*[![:space:]]}"}"    # rtrim
        [[ -z "$name" ]] && continue
        [[ "$name" == \#* ]] && continue
        # Indirect existence check (set-but-empty counts as missing).
        if [[ -z "${!name:-}" ]]; then
            missing="${missing:+$missing, }${name}"
        fi
    done < "$path"
    if [[ -n "$missing" ]]; then
        _pbv_add_finding "env_required" "fail" "true" "missing required env var(s): ${missing}"
        return 1
    fi
    _pbv_add_finding "env_required" "pass" "true" "all required env vars present"
    return 0
}

# ─── Orchestrator ─────────────────────────────────────────────────────────────
stage_pre_build_validate() {
    CURRENT_STAGE_ID="pre_build_validate"
    local root="${PROJECT_ROOT:-$(pwd)}"
    local artifacts="${ARTIFACTS_DIR:-.claude/pipeline-artifacts}"
    local result_file="${artifacts}/prebuild-validate.json"
    mkdir -p "$artifacts" 2>/dev/null || true

    # Skip flag — affects ONLY this stage, not the post-deploy validate stage.
    if [[ "${SKIP_PREBUILD_VALIDATE:-false}" == "true" ]]; then
        info "Pre-build validation skipped (SKIP_PREBUILD_VALIDATE=true)"
        _pbv_write_result "$result_file" "skipped" 0
        emit_event "prebuild.skipped" "issue=${ISSUE_NUMBER:-0}" "reason=flag"
        return 0
    fi

    info "Pre-build validation — fast-fail dependency health check"

    # Read config (all optional, safe defaults).
    local fail_on_dirty="false" lint_enabled="false" env_file=".env.required"
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/nonexistent}" ]]; then
        local v
        v=$(jq -r '(.stages[] | select(.id=="pre_build_validate") | .config.fail_on_dirty_worktree) // "false"' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$v" == "true" ]] && fail_on_dirty="true"
        v=$(jq -r '(.stages[] | select(.id=="pre_build_validate") | .config.lint) // "false"' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$v" == "true" ]] && lint_enabled="true"
        v=$(jq -r '(.stages[] | select(.id=="pre_build_validate") | .config.env_required_file) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -n "$v" && "$v" != "null" ]] && env_file="$v"
    fi

    _PBV_FINDINGS=()
    local start_ms now_ms
    start_ms=$(_pbv_now_ms)

    # Run all six checks. Each appends a finding; a blocking failure flips the verdict.
    # Continue running the rest so the report is complete (don't stop at first failure).
    local verdict="pass"
    _pbv_manifest "$root"      || { [[ $? -eq 1 ]] && verdict="fail"; }
    _pbv_lockfile "$root"      || { [[ $? -eq 1 ]] && verdict="fail"; }
    _pbv_test_runner "$root"   || { [[ $? -eq 1 ]] && verdict="fail"; }
    _pbv_lint "$root" "$lint_enabled" || { [[ $? -eq 1 ]] && true; }   # lint is non-blocking
    _pbv_git_state "$root" "$fail_on_dirty" || { [[ $? -eq 1 ]] && verdict="fail"; }
    _pbv_env_required "$root" "$env_file"   || { [[ $? -eq 1 ]] && verdict="fail"; }

    now_ms=$(_pbv_now_ms)
    local duration_ms=$((now_ms - start_ms))
    [[ $duration_ms -lt 0 ]] && duration_ms=0

    _pbv_write_result "$result_file" "$verdict" "$duration_ms"

    # Surface each finding to the operator.
    local f
    for f in "${_PBV_FINDINGS[@]}"; do
        local fid fstatus fmsg floc
        fid=$(echo "$f" | jq -r '.id' 2>/dev/null || echo "?")
        fstatus=$(echo "$f" | jq -r '.status' 2>/dev/null || echo "?")
        fmsg=$(echo "$f" | jq -r '.message' 2>/dev/null || echo "")
        floc=$(echo "$f" | jq -r '.location // ""' 2>/dev/null || echo "")
        local loc_suffix=""
        [[ -n "$floc" ]] && loc_suffix=" (${floc})"
        case "$fstatus" in
            pass)    success "  ${fid}: ${fmsg}${loc_suffix}" ;;
            fail)    error   "  ${fid}: ${fmsg}${loc_suffix}" ;;
            skipped) info    "  ${fid}: ${fmsg}" ;;
        esac
    done

    if [[ "$verdict" == "fail" ]]; then
        error "Pre-build validation FAILED in ${duration_ms}ms — halting before build (fast-fail)"
        emit_event "prebuild.failed" "issue=${ISSUE_NUMBER:-0}" "duration_ms=${duration_ms}"
        return 1
    fi

    success "Pre-build validation passed in ${duration_ms}ms"
    emit_event "prebuild.passed" "issue=${ISSUE_NUMBER:-0}" "duration_ms=${duration_ms}"
    return 0
}

# Milliseconds since epoch. Falls back to seconds*1000 if %N is unsupported (macOS date).
_pbv_now_ms() {
    local ns
    ns=$(date +%s%N 2>/dev/null || echo "")
    if [[ "$ns" =~ ^[0-9]+$ && ${#ns} -gt 10 ]]; then
        echo $((ns / 1000000))
    else
        echo $(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
    fi
}

# Atomic write of the result artifact (tmp + mv).
_pbv_write_result() {
    local out="$1" verdict="$2" duration_ms="$3"
    local checks_json="[]"
    if [[ ${#_PBV_FINDINGS[@]} -gt 0 ]]; then
        local joined=""
        local f
        for f in "${_PBV_FINDINGS[@]}"; do
            joined="${joined:+$joined,}${f}"
        done
        checks_json="[${joined}]"
    fi
    local tmp="${out}.tmp.$$"
    cat > "$tmp" <<EOF
{
  "stage": "pre_build_validate",
  "verdict": "${verdict}",
  "durationMs": ${duration_ms},
  "checks": ${checks_json}
}
EOF
    # Validate before committing; if jq is unavailable, commit as-is.
    if command -v jq >/dev/null 2>&1; then
        if jq empty "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp"
        else
            rm -f "$tmp"
        fi
    else
        mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp"
    fi
}
