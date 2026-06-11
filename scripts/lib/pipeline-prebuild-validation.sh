#!/usr/bin/env bash
# Module: pipeline-prebuild-validation
# Pre-Build Validation Engine — catch obvious failures (syntax, missing files,
# broken imports, failing smoke tests) in < 60s BEFORE entering the build loop,
# so the pipeline never wastes 10+ iterations on issues a 30s check would flag.
#
# Design: scripts/skills/generated/pre-flight-validation-design.md
# Conventions: bash 3.2 (no associative arrays — checks dispatch by function
# name), degrade-safe (never block a pipeline because validation infra is
# broken), reuses emit_event / _timeout / _smart_int / project_detect_*.

# Module guard - prevent double-sourcing
[[ -n "${_PIPELINE_PREBUILD_VALIDATION_LOADED:-}" ]] && return 0
_PIPELINE_PREBUILD_VALIDATION_LOADED=1

# shellcheck disable=SC2034
VERSION="3.3.0"

# ─── Output Helpers (fallback if not already loaded) ─────────────────────────
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi

# Field separator for structured check results: "status<US>message<US>file".
# Unit Separator (0x1f) cannot appear in file paths or human messages.
_PB_SEP=$'\037'

# ─── Dependency / degrade-safe fallbacks ─────────────────────────────────────
# _timeout: if compat.sh is absent, run without a timeout rather than fail.
if [[ "$(type -t _timeout 2>/dev/null)" != "function" ]]; then
  _timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
  }
fi
# emit_event: no-op fallback so metrics never crash a build.
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() { :; }
fi

# ─── Millisecond clock (bash 3.2 / BSD-date safe) ────────────────────────────
# GNU date supports %N; BSD date does not. Fall back to python3, then to
# whole-second granularity (×1000). Always echoes an integer.
_prebuild_now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  if [[ "$ns" =~ ^[0-9]+$ && "$ns" != *N ]]; then
    echo $(( ns / 1000000 ))
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null && return
  fi
  echo $(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
}

# ─── Configuration readers (env → daemon-config.json → default) ──────────────
_prebuild_cfg_file() {
  echo "${DAEMON_CONFIG:-${STATE_DIR:-${PROJECT_ROOT:-.}/.claude}/daemon-config.json}"
}

# _prebuild_enabled — is validation turned on? Default: true.
_prebuild_enabled() {
  if [[ -n "${VALIDATION_ENABLED:-}" ]]; then
    [[ "$VALIDATION_ENABLED" == "true" || "$VALIDATION_ENABLED" == "1" ]] && return 0 || return 1
  fi
  local cfg val
  cfg=$(_prebuild_cfg_file)
  if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    val=$(jq -r '.validation.enabled // empty' "$cfg" 2>/dev/null || true)
    [[ "$val" == "false" ]] && return 1
  fi
  return 0
}

# _prebuild_timeout — global budget in seconds. Default 60.
_prebuild_timeout() {
  if [[ -n "${VALIDATION_TIMEOUT:-}" && "${VALIDATION_TIMEOUT}" =~ ^[0-9]+$ ]]; then
    echo "$VALIDATION_TIMEOUT"; return
  fi
  local cfg val
  cfg=$(_prebuild_cfg_file)
  if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    val=$(jq -r '.validation.timeout_seconds // empty' "$cfg" 2>/dev/null || true)
    [[ "$val" =~ ^[0-9]+$ ]] && { echo "$val"; return; }
  fi
  echo "60"
}

# _prebuild_on_failure — "skip_build_loop" (default) or "continue".
_prebuild_on_failure() {
  if [[ -n "${VALIDATION_ON_FAILURE:-}" ]]; then echo "$VALIDATION_ON_FAILURE"; return; fi
  local cfg val
  cfg=$(_prebuild_cfg_file)
  if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    val=$(jq -r '.validation.on_failure // empty' "$cfg" 2>/dev/null || true)
    [[ -n "$val" && "$val" != "null" ]] && { echo "$val"; return; }
  fi
  echo "skip_build_loop"
}

# _prebuild_checks — ordered cheap→expensive list of enabled check types.
# Env override VALIDATION_CHECKS=syntax,imports wins. Config disables per-check
# via {"type":"x","enabled":false}. Default: all four, fixed cheap→expensive.
_prebuild_checks() {
  if [[ -n "${VALIDATION_CHECKS:-}" ]]; then
    echo "$VALIDATION_CHECKS" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$' || true
    return
  fi
  local cfg
  cfg=$(_prebuild_cfg_file)
  local default_order="required_files syntax imports smoke_test"
  if [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1; then
    local has_checks
    has_checks=$(jq -r '.validation.checks // empty | length' "$cfg" 2>/dev/null || true)
    if [[ "$has_checks" =~ ^[0-9]+$ && "$has_checks" -gt 0 ]]; then
      # Keep canonical cheap→expensive order, filter to enabled types present.
      local t
      for t in $default_order; do
        local en
        en=$(jq -r --arg t "$t" '.validation.checks[] | select(.type==$t) | (.enabled // true)' "$cfg" 2>/dev/null | head -1 || true)
        # Present and not explicitly disabled → include.
        [[ "$en" == "false" ]] || { [[ -z "$en" ]] || echo "$t"; }
      done
      return
    fi
  fi
  echo "$default_order" | tr ' ' '\n'
}

# _prebuild_cfg_files_for <check_type> — read .files array (required_files) or
# .cmd (smoke_test) from config for a given check.
_prebuild_cfg_value() {
  local check_type="$1" field="$2"
  local cfg
  cfg=$(_prebuild_cfg_file)
  [[ -f "$cfg" ]] && command -v jq >/dev/null 2>&1 || return 0
  # -c keeps arrays on a single line so a downstream `head -1` doesn't truncate
  # a multi-line pretty-printed array down to just "[".
  jq -rc --arg t "$check_type" --arg f "$field" \
    '.validation.checks[] | select(.type==$t) | .[$f] // empty' "$cfg" 2>/dev/null | head -1 || true
}

# ─── Changed-file scope ──────────────────────────────────────────────────────
# Compute the set of files to validate: diff against the base branch when
# available, else uncommitted+last-commit changes. Capped to avoid scanning a
# whole repo. Echoes one path per line (existing files only).
_prebuild_changed_files() {
  local cap="${1:-200}"
  local base="${BASE_BRANCH:-main}"
  local files=""

  # Prefer merge-base diff against the base branch (real PR scope).
  if git rev-parse --verify "origin/${base}" >/dev/null 2>&1; then
    files=$(git diff --name-only "origin/${base}...HEAD" 2>/dev/null || true)
  elif git rev-parse --verify "$base" >/dev/null 2>&1; then
    files=$(git diff --name-only "${base}...HEAD" 2>/dev/null || true)
  fi

  # Fallback / augment: uncommitted changes + last commit.
  local working
  working=$(git diff --name-only HEAD 2>/dev/null || true)
  local staged
  staged=$(git diff --name-only --cached 2>/dev/null || true)
  files=$(printf '%s\n%s\n%s\n' "$files" "$working" "$staged")

  # Dedupe, keep only existing regular files, cap.
  printf '%s\n' "$files" \
    | grep -v '^$' \
    | sort -u \
    | while IFS= read -r f; do [[ -f "$f" ]] && echo "$f"; done \
    | head -n "$cap"
}

# ─── Individual checks ───────────────────────────────────────────────────────
# Contract: each echoes ONE line "status<US>message<US>file".
#   status ∈ pass | fail | skip
#   Criticality is decided by the orchestrator, not the check.

# required_files: every configured required file must exist. Critical.
_prebuild_check_required_files() {
  local required
  required=$(_prebuild_cfg_value "required_files" "files")
  if [[ -z "$required" ]]; then
    # Sensible default per project type.
    if [[ -f package.json ]]; then required="package.json"
    else
      echo "skip${_PB_SEP}no required_files configured${_PB_SEP}"
      return 0
    fi
  fi
  local missing="" f
  # Config stores files as a JSON array; cfg_value already flattened first match
  # via jq .files (returns array text). Normalise both array-JSON and CSV.
  local list
  if [[ "$required" == "["* ]] && command -v jq >/dev/null 2>&1; then
    list=$(echo "$required" | jq -r '.[]?' 2>/dev/null || true)
  else
    list=$(echo "$required" | tr ',' '\n')
  fi
  while IFS= read -r f; do
    f=$(echo "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$f" ]] && continue
    [[ -e "$f" ]] || missing="${missing}${missing:+, }${f}"
  done <<EOF
$list
EOF
  if [[ -n "$missing" ]]; then
    echo "fail${_PB_SEP}missing required file(s): ${missing}${_PB_SEP}${missing%%,*}"
    return 0
  fi
  echo "pass${_PB_SEP}all required files present${_PB_SEP}"
}

# syntax: parse-check changed source files by language. Critical.
_prebuild_check_syntax() {
  local files
  files=$(_prebuild_changed_files)
  if [[ -z "$files" ]]; then
    echo "skip${_PB_SEP}no changed source files${_PB_SEP}"
    return 0
  fi
  local checked=0 bad_file="" bad_msg="" f ext
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    ext="${f##*.}"
    case "$ext" in
      js|jsx|mjs|cjs)
        if command -v node >/dev/null 2>&1; then
          checked=$((checked + 1))
          local out
          if ! out=$(node --check "$f" 2>&1); then
            bad_file="$f"; bad_msg=$(echo "$out" | head -1); break
          fi
        fi
        ;;
      sh|bash)
        if command -v bash >/dev/null 2>&1; then
          checked=$((checked + 1))
          local out
          if ! out=$(bash -n "$f" 2>&1); then
            bad_file="$f"; bad_msg=$(echo "$out" | head -1); break
          fi
        fi
        ;;
      py)
        if command -v python3 >/dev/null 2>&1; then
          checked=$((checked + 1))
          local out
          if ! out=$(python3 -m py_compile "$f" 2>&1); then
            bad_file="$f"; bad_msg=$(echo "$out" | head -1); break
          fi
        fi
        ;;
      *) : ;;  # Unknown extension — not our job.
    esac
  done <<EOF
$files
EOF
  if [[ -n "$bad_file" ]]; then
    echo "fail${_PB_SEP}syntax error: ${bad_msg}${_PB_SEP}${bad_file}"
    return 0
  fi
  if [[ "$checked" -eq 0 ]]; then
    echo "skip${_PB_SEP}no parseable source files (missing node/python3?)${_PB_SEP}"
    return 0
  fi
  echo "pass${_PB_SEP}${checked} file(s) parse cleanly${_PB_SEP}"
}

# imports: resolve relative import/require specifiers in changed JS/TS files.
# Heuristic (skips bare package imports) so it's critical only for clear breaks.
_prebuild_check_imports() {
  local files
  files=$(_prebuild_changed_files)
  [[ -z "$files" ]] && { echo "skip${_PB_SEP}no changed files${_PB_SEP}"; return 0; }

  local scanned=0 broken_file="" broken_spec="" f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "${f##*.}" in js|jsx|mjs|cjs|ts|tsx) ;; *) continue ;; esac
    scanned=$((scanned + 1))
    local dir spec
    dir=$(dirname "$f")
    # Extract relative specifiers from import ... from '...' and require('...').
    local specs
    specs=$(grep -oE "(from|require\()[[:space:]]*['\"](\.[^'\"]+)['\"]" "$f" 2>/dev/null \
      | grep -oE "['\"]\.[^'\"]+['\"]" | tr -d "'\"" | sort -u || true)
    while IFS= read -r spec; do
      [[ -z "$spec" ]] && continue
      local base="${dir}/${spec}"
      # Resolve common forms: exact, .js/.ts/.jsx/.tsx, index.*, directory.
      if [[ -e "$base" || -f "${base}.js" || -f "${base}.ts" || -f "${base}.jsx" \
            || -f "${base}.tsx" || -f "${base}.mjs" || -f "${base}.cjs" \
            || -f "${base}/index.js" || -f "${base}/index.ts" \
            || -d "$base" ]]; then
        continue
      fi
      broken_file="$f"; broken_spec="$spec"; break
    done <<EOF
$specs
EOF
    [[ -n "$broken_file" ]] && break
  done <<EOF
$files
EOF
  if [[ -n "$broken_file" ]]; then
    echo "fail${_PB_SEP}unresolved relative import '${broken_spec}'${_PB_SEP}${broken_file}"
    return 0
  fi
  if [[ "$scanned" -eq 0 ]]; then
    echo "skip${_PB_SEP}no JS/TS files to scan${_PB_SEP}"
    return 0
  fi
  echo "pass${_PB_SEP}${scanned} file(s), imports resolve${_PB_SEP}"
}

# smoke_test: run a configured fast command. Soft by default (infra-ish).
_prebuild_check_smoke_test() {
  local cmd
  cmd=$(_prebuild_cfg_value "smoke_test" "cmd")
  [[ -z "$cmd" && -n "${VALIDATION_SMOKE_CMD:-}" ]] && cmd="$VALIDATION_SMOKE_CMD"
  if [[ -z "$cmd" ]]; then
    echo "skip${_PB_SEP}no smoke_test cmd configured${_PB_SEP}"
    return 0
  fi
  # Run via the shell, but DO NOT eval the configured string into our own
  # context — execute it as an argument to `sh -c` in a subshell.
  local out rc
  out=$(sh -c "$cmd" 2>&1); rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "fail${_PB_SEP}smoke test exited ${rc}: $(echo "$out" | tail -1)${_PB_SEP}"
    return 0
  fi
  echo "pass${_PB_SEP}smoke test passed${_PB_SEP}"
}

# ─── Criticality map (bash 3.2: case, not associative array) ─────────────────
# Critical failures stop validation and (by default) skip the build loop.
# Soft failures are logged; they only skip the loop if on_failure != continue.
_prebuild_is_critical() {
  case "$1" in
    required_files|syntax|imports) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── Per-check runner (timeout + ms timing) ──────────────────────────────────
# Echoes "status<US>message<US>file<US>duration_ms". Timeout → status "timeout".
_prebuild_run_check() {
  local check_type="$1" budget="${2:-30}"
  local fn="_prebuild_check_${check_type}"
  if [[ "$(type -t "$fn" 2>/dev/null)" != "function" ]]; then
    echo "skip${_PB_SEP}unknown check '${check_type}'${_PB_SEP}${_PB_SEP}0"
    return 0
  fi
  local start end dur result rc
  start=$(_prebuild_now_ms)
  # Run in a subshell with a per-check timeout. On timeout, _timeout returns 124.
  # Export pipeline context so the freshly-sourced check sees the same config,
  # base branch, and cwd-relative scope as the orchestrator.
  result=$(
    export STATE_DIR PROJECT_ROOT BASE_BRANCH DAEMON_CONFIG ISSUE_NUMBER \
           BUILD_TEST_RETRIES VALIDATION_ENABLED VALIDATION_TIMEOUT \
           VALIDATION_CHECKS VALIDATION_ON_FAILURE VALIDATION_SMOKE_CMD 2>/dev/null || true
    _timeout "$budget" bash -c "source '${BASH_SOURCE[0]}'; $fn" 2>/dev/null
  )
  rc=$?
  end=$(_prebuild_now_ms)
  dur=$(( end - start ))
  [[ "$dur" -lt 0 ]] && dur=0
  if [[ "$rc" -eq 124 ]]; then
    echo "timeout${_PB_SEP}check exceeded ${budget}s budget${_PB_SEP}${_PB_SEP}${dur}"
    return 0
  fi
  if [[ -z "$result" ]]; then
    echo "skip${_PB_SEP}check produced no result${_PB_SEP}${_PB_SEP}${dur}"
    return 0
  fi
  echo "${result}${_PB_SEP}${dur}"
}

# ─── Report writer (atomic) ──────────────────────────────────────────────────
# Args: status run passed failed skipped total_ms failed_json time_saved
_prebuild_write_report() {
  local status="$1" run="$2" passed="$3" failed="$4" skipped="$5"
  local total_ms="$6" failed_json="$7" time_saved="$8"
  local out="${STATE_DIR:-${PROJECT_ROOT:-.}/.claude}/validation-report.json"
  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  local tmp="${out}.tmp.$$"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg ts "$(now_iso)" --arg st "$status" \
      --argjson run "$run" --argjson passed "$passed" \
      --argjson failed "$failed" --argjson skipped "$skipped" \
      --argjson dur "$total_ms" --argjson fc "${failed_json:-[]}" \
      --arg saved "$time_saved" \
      '{timestamp:$ts, status:$st, checks_run:$run, checks_passed:$passed,
        checks_failed:$failed, checks_skipped:$skipped,
        total_duration_ms:$dur, failed_checks:$fc, time_saved:$saved}' \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    printf '{"timestamp":"%s","status":"%s","checks_run":%s,"checks_passed":%s,"checks_failed":%s,"checks_skipped":%s,"total_duration_ms":%s,"time_saved":"%s"}\n' \
      "$(now_iso)" "$status" "$run" "$passed" "$failed" "$skipped" "$total_ms" "$time_saved" \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
  echo "$out"
}

# ─── Metrics emitter ─────────────────────────────────────────────────────────
_prebuild_emit_metrics() {
  local status="$1" run="$2" passed="$3" failed="$4" total_ms="$5" time_saved_s="$6"
  emit_event "validation.complete" \
    "issue=${ISSUE_NUMBER:-0}" \
    "status=${status}" \
    "checks_run=${run}" \
    "checks_passed=${passed}" \
    "checks_failed=${failed}" \
    "duration_ms=${total_ms}" \
    "time_saved_s=${time_saved_s}" 2>/dev/null || true
  # Append a one-line summary to pipeline state for human/replay visibility.
  local state="${STATE_FILE:-${STATE_DIR:-${PROJECT_ROOT:-.}/.claude}/pipeline-state.md}"
  if [[ -w "$(dirname "$state")" ]] 2>/dev/null; then
    printf 'validation: %s (run=%s pass=%s fail=%s %sms, time_saved~%ss)\n' \
      "$status" "$run" "$passed" "$failed" "$total_ms" "$time_saved_s" \
      >> "$state" 2>/dev/null || true
  fi
}

# ─── Orchestrator ────────────────────────────────────────────────────────────
# prebuild_validate
#   Returns 0 → proceed to build loop (passed, degraded, or soft-fail+continue).
#   Returns 1 → skip build loop (critical failure, on_failure=skip_build_loop).
# Degrade-safe: any infra problem (no jq, no git, disabled) returns 0.
prebuild_validate() {
  if ! _prebuild_enabled; then
    info "Pre-build validation disabled — proceeding to build."
    return 0
  fi

  local checks
  checks=$(_prebuild_checks)
  if [[ -z "$checks" ]]; then
    info "No pre-build checks configured — proceeding to build."
    return 0
  fi

  local budget on_failure
  budget=$(_prebuild_timeout)
  on_failure=$(_prebuild_on_failure)

  echo ""
  echo -e "\033[38;2;0;212;255m\033[1m▸ Pre-Build Validation\033[0m \033[2m(budget ${budget}s)\033[0m"

  local global_start now elapsed
  global_start=$(_prebuild_now_ms)

  local run=0 passed=0 failed=0 skipped=0 total_ms=0
  local critical_hit="" failed_json="[]"
  local per_check_budget=$(( budget / 2 ))
  [[ "$per_check_budget" -lt 5 ]] && per_check_budget=5

  local check line status message file dur
  while IFS= read -r check; do
    [[ -z "$check" ]] && continue

    # Respect the global budget — stop launching checks once it's blown.
    now=$(_prebuild_now_ms); elapsed=$(( (now - global_start) / 1000 ))
    if [[ "$elapsed" -ge "$budget" ]]; then
      warn "Validation budget (${budget}s) reached — skipping remaining checks."
      break
    fi

    line=$(_prebuild_run_check "$check" "$per_check_budget")
    status="${line%%${_PB_SEP}*}"
    local rest="${line#*${_PB_SEP}}"
    message="${rest%%${_PB_SEP}*}"
    rest="${rest#*${_PB_SEP}}"
    file="${rest%%${_PB_SEP}*}"
    dur="${rest##*${_PB_SEP}}"
    [[ "$dur" =~ ^[0-9]+$ ]] || dur=0
    total_ms=$(( total_ms + dur ))
    run=$(( run + 1 ))

    emit_event "validation.check" \
      "issue=${ISSUE_NUMBER:-0}" "check=${check}" "status=${status}" \
      "duration_ms=${dur}" "message=${message}" 2>/dev/null || true

    case "$status" in
      pass)
        passed=$(( passed + 1 ))
        success "  ${check}: ${message} \033[2m(${dur}ms)\033[0m"
        ;;
      skip)
        skipped=$(( skipped + 1 ))
        echo -e "  \033[2m○ ${check}: ${message}\033[0m"
        ;;
      timeout)
        # Degraded: infra/perf issue, not a code defect. Don't block.
        skipped=$(( skipped + 1 ))
        warn "  ${check}: ${message} (degraded — not blocking)"
        ;;
      fail)
        failed=$(( failed + 1 ))
        # Append to failed_checks JSON array.
        if command -v jq >/dev/null 2>&1; then
          failed_json=$(echo "$failed_json" | jq -c \
            --arg t "$check" --arg m "$message" --arg f "$file" \
            '. + [{type:$t, message:$m, file:$f}]' 2>/dev/null || echo "$failed_json")
        fi
        if _prebuild_is_critical "$check"; then
          error "  ${check}: ${message}${file:+ (${file})}"
          critical_hit="$check"
          break  # Stop on first critical failure.
        else
          warn "  ${check}: ${message} (soft)"
        fi
        ;;
    esac
  done <<EOF
$checks
EOF

  local global_end final_ms
  global_end=$(_prebuild_now_ms)
  final_ms=$(( global_end - global_start ))
  [[ "$final_ms" -lt "$total_ms" ]] && final_ms="$total_ms"

  # Decide outcome.
  local overall="passed" skip_build=1 time_saved_s=0
  if [[ -n "$critical_hit" ]]; then
    overall="failed"
    # Estimate time saved: avg build/test cycle × remaining iterations avoided.
    # Conservative: 60s/iteration × (BUILD_TEST_RETRIES+1) cycles.
    local avg_iter="${VALIDATION_AVG_ITER_S:-60}"
    local cycles=$(( ${BUILD_TEST_RETRIES:-2} + 1 ))
    time_saved_s=$(( avg_iter * cycles ))
    skip_build=1  # critical → recommend skip
  elif [[ "$failed" -gt 0 ]]; then
    # Soft failures only.
    if [[ "$on_failure" == "continue" ]]; then
      overall="degraded"; skip_build=0
    else
      overall="failed"; skip_build=1
      time_saved_s=$(( ${VALIDATION_AVG_ITER_S:-60} * ( ${BUILD_TEST_RETRIES:-2} + 1 ) ))
    fi
  else
    overall="passed"; skip_build=0
  fi

  local time_saved_str="0 seconds"
  [[ "$time_saved_s" -gt 0 ]] && time_saved_str="~${time_saved_s} seconds ($(( time_saved_s / 60 )) min of wasted iterations avoided)"

  _prebuild_write_report "$overall" "$run" "$passed" "$failed" "$skipped" \
    "$final_ms" "$failed_json" "$time_saved_str" >/dev/null
  _prebuild_emit_metrics "$overall" "$run" "$passed" "$failed" "$final_ms" "$time_saved_s"

  if [[ "$skip_build" -eq 1 && ( -n "$critical_hit" || ( "$failed" -gt 0 && "$on_failure" != "continue" ) ) ]]; then
    echo ""
    error "Pre-build validation FAILED — skipping build loop (saved ${time_saved_str})."
    info "Report: ${STATE_DIR:-${PROJECT_ROOT:-.}/.claude}/validation-report.json"
    return 1
  fi

  success "Pre-build validation passed (${passed}/${run}, ${final_ms}ms) — entering build."
  return 0
}
