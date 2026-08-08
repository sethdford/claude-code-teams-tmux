#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  failure-class — Identify WHICH build command failed, and what kind      ║
# ║                                                                          ║
# ║  The build loop runs more than tests: lint, type-check and compile all   ║
# ║  travel through --additional-test-cmds. When one of those breaks, the    ║
# ║  next iteration used to be told "tests failed" — or told nothing at all. ║
# ║                                                                          ║
# ║  Provenance comes from recorded exit codes (test-evidence-iter-N.json),  ║
# ║  never from guessing at log prose. Log text is read only to extract the  ║
# ║  error lines of a command already known to have failed.                  ║
# ║                                                                          ║
# ║  Classes: lint | typecheck | compile | test | unknown                    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Module guard
[[ -n "${_MODULE_FAILURE_CLASS_LOADED:-}" ]] && return 0
_MODULE_FAILURE_CLASS_LOADED=1

VERSION="3.3.0"

# Maximum entries recorded in the all_failures array (context budget guard)
FC_MAX_FAILURES=5

# ─────────────────────────────────────────────────────────────────────────────
# classify_command — command string → failure class
#
# Pure: no I/O, never fails, always prints exactly one class.
# Order matters. typecheck is evaluated before compile so that
# `npm run build:types` classifies as typecheck rather than compile.
# ─────────────────────────────────────────────────────────────────────────────
classify_command() {
    local cmd
    cmd="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [[ -z "$cmd" ]] && { echo "unknown"; return 0; }

    case "$cmd" in
        *tsc*|*--noemit*|*mypy*|*pyright*|*type-check*|*typecheck*|*type_check*|*:types*|*flow*check*)
            echo "typecheck"; return 0 ;;
        *eslint*|*biome*|*ruff*|*shellcheck*|*prettier*|*golangci-lint*|*clippy*|*rubocop*|*flake8*|*lint*)
            echo "lint"; return 0 ;;
        # "cargo build" and "pnpm build" already contain "go build"/"npm build"
        # substrings, so the broader patterns cover them.
        *go\ build*|*npm\ run\ build*|*yarn\ build*|*vite\ build*|*webpack*|*esbuild*|*rollup*|*tsup*|*javac*|*gcc*|*g++*|*clang*|*cmake*|*make*|*mvn*|*gradle*)
            echo "compile"; return 0 ;;
        *vitest*|*jest*|*pytest*|*mocha*|*rspec*|*bats*|*npm\ test*|*npm\ run\ test*|*yarn\ test*|*go\ test*|*-test.sh*|*test*)
            echo "test"; return 0 ;;
        *)
            echo "unknown"; return 0 ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# fc_human_class — class → prompt-facing label
# ─────────────────────────────────────────────────────────────────────────────
fc_human_class() {
    case "${1:-}" in
        typecheck) echo "TYPE-CHECK FAILURE" ;;
        lint)      echo "LINT FAILURE" ;;
        compile)   echo "COMPILE FAILURE" ;;
        test)      echo "TEST FAILURE" ;;
        *)         echo "BUILD FAILURE" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# detect_failure_class — evidence file → failing command + class
#
# Args:  $1 evidence JSON path, $2 fallback log path
# Print: "<class>\t<command>\t<log_path>"
#
# Selects the FIRST entry with a non-zero exit code — deterministic, and the
# earliest failure is usually the causal one. Falls back to TEST_CMD when
# TEST_PASSED=false but no evidence exists, then to unknown.
# Never fails; a broken error summary must not break the build it describes.
# ─────────────────────────────────────────────────────────────────────────────
detect_failure_class() {
    local evidence_file="${1:-}"
    local fallback_log="${2:-}"
    local evidence_dir=""
    [[ -n "$evidence_file" ]] && evidence_dir="$(dirname "$evidence_file")"

    if [[ -n "$evidence_file" ]] && [[ -f "$evidence_file" ]] && command -v jq >/dev/null 2>&1; then
        local entry cmd log
        entry="$(jq -r '[.[]? | select((.exit_code // 0) != 0)][0] // empty
                        | "\(.command // "")\t\(.log // "")"' \
                 "$evidence_file" 2>/dev/null || true)"
        if [[ -n "$entry" ]]; then
            cmd="${entry%%$'\t'*}"
            log="${entry#*$'\t'}"
            # Evidence records log basenames; resolve against the evidence dir.
            if [[ -n "$log" ]] && [[ "$log" != /* ]] && [[ -n "$evidence_dir" ]]; then
                log="$evidence_dir/$log"
            fi
            [[ -z "$log" ]] && log="$fallback_log"
            printf '%s\t%s\t%s\n' "$(classify_command "$cmd")" "$cmd" "$log"
            return 0
        fi
        # Evidence exists and every command exited zero — no failure to report.
        # Only the caller knows whether some other signal (TEST_PASSED) still
        # warrants a summary, so fall through to the TEST_CMD path below.
    fi

    if [[ "${TEST_PASSED:-}" == "false" ]] && [[ -n "${TEST_CMD:-}" ]]; then
        printf '%s\t%s\t%s\n' "$(classify_command "$TEST_CMD")" "$TEST_CMD" "$fallback_log"
        return 0
    fi

    printf 'unknown\t\t%s\n' "$fallback_log"
}

# ─────────────────────────────────────────────────────────────────────────────
# fc_class_pattern — class → grep -E pattern tuned to that toolchain
# ─────────────────────────────────────────────────────────────────────────────
fc_class_pattern() {
    case "${1:-}" in
        typecheck) echo 'error TS[0-9]+|: error:|Cannot find|is not assignable|has no exported member|error\[' ;;
        lint)      echo '[0-9]+:[0-9]+[[:space:]]+(error|warning)|✖|problems?[[:space:]]*\(|error[[:space:]]+.*[[:space:]]+[a-z-]+/[a-z-]+$' ;;
        compile)   echo 'error\[E[0-9]+\]|undefined reference|cannot find package|Module not found|No such file or directory|: error:|error:' ;;
        *)         echo '' ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# fc_pattern_matched — did any error pattern match, or would we fall back?
#
# Args:   $1 log path, $2 class
# Return: 0 when the class-specific or generic pattern matched
#         1 when extract_error_lines would return the last N lines instead
#
# A queryable predicate rather than a global set by extract_error_lines:
# callers read that function through $( ), and a global set in a subshell
# never reaches them.
# ─────────────────────────────────────────────────────────────────────────────
fc_pattern_matched() {
    local log="${1:-}"
    local cls="${2:-unknown}"
    [[ -z "$log" || ! -f "$log" || ! -s "$log" ]] && return 1

    local tail_window pattern
    tail_window="$(tail -80 "$log" 2>/dev/null || true)"
    [[ -z "$tail_window" ]] && return 1

    pattern="$(fc_class_pattern "$cls")"
    if [[ -n "$pattern" ]] && printf '%s\n' "$tail_window" | grep -qE "$pattern"; then
        return 0
    fi
    printf '%s\n' "$tail_window" \
        | grep -qiE '(error|fail|assert|exception|panic|TypeError|ReferenceError|SyntaxError)'
}

# ─────────────────────────────────────────────────────────────────────────────
# extract_error_lines — log + class → error lines
#
# Args:  $1 log path, $2 class, $3 max lines (default 10)
# Print: newline-joined error lines ("" only when the log is missing/empty)
#
# Tries the class-specific pattern, then the generic pattern, then the last N
# lines of the log. Ask fc_pattern_matched() whether that last fallback was
# taken — a summary that fell back should say so rather than imply precision.
# ─────────────────────────────────────────────────────────────────────────────
extract_error_lines() {
    local log="${1:-}"
    local cls="${2:-unknown}"
    local max="${3:-10}"

    [[ -z "$log" || ! -f "$log" || ! -s "$log" ]] && return 0

    local tail_window
    tail_window="$(tail -80 "$log" 2>/dev/null || true)"
    [[ -z "$tail_window" ]] && return 0

    local pattern lines=""
    pattern="$(fc_class_pattern "$cls")"
    if [[ -n "$pattern" ]]; then
        lines="$(printf '%s\n' "$tail_window" | grep -E "$pattern" | head -"$max" || true)"
    fi

    if [[ -z "$lines" ]]; then
        lines="$(printf '%s\n' "$tail_window" \
            | grep -iE '(error|fail|assert|exception|panic|TypeError|ReferenceError|SyntaxError)' \
            | head -"$max" || true)"
    fi

    if [[ -z "$lines" ]]; then
        lines="$(printf '%s\n' "$tail_window" | tail -"$max" || true)"
    fi

    printf '%s\n' "$lines"
}

# ─────────────────────────────────────────────────────────────────────────────
# fc_json_array — newline-separated lines → JSON array literal, without jq
#
# For the degraded no-jq path only. Escapes backslash and quote, drops control
# characters (build output carries ANSI escapes), and never emits a trailing
# comma. Printing error_count: 1 next to error_lines: [] is worse than a
# hand-rolled escape — the reader cannot tell what the error was.
# ─────────────────────────────────────────────────────────────────────────────
fc_json_array() {
    local input="${1:-}"
    [[ -z "$input" ]] && { printf '[]'; return 0; }

    local out="" line first=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        line="$(printf '%s' "$line" \
            | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g')"
        if [[ "$first" -eq 1 ]]; then
            out="\"${line}\""
            first=0
        else
            out="${out},\"${line}\""
        fi
    done <<< "$input"

    printf '[%s]' "$out"
}

# ─────────────────────────────────────────────────────────────────────────────
# collect_all_failures — evidence file → JSON array of every failing command
#
# A typecheck break must not hide a concurrent lint break. Capped at
# FC_MAX_FAILURES entries so the summary stays inside the context budget.
# Prints "[]" on any error.
# ─────────────────────────────────────────────────────────────────────────────
collect_all_failures() {
    local evidence_file="${1:-}"
    if [[ -z "$evidence_file" ]] || [[ ! -f "$evidence_file" ]] || ! command -v jq >/dev/null 2>&1; then
        echo "[]"
        return 0
    fi

    local evidence_dir failures="[]"
    evidence_dir="$(dirname "$evidence_file")"

    local count=0
    while IFS=$'\t' read -r cmd exit_code log; do
        [[ -z "$cmd$exit_code" ]] && continue
        [[ "$count" -ge "$FC_MAX_FAILURES" ]] && break
        count=$((count + 1))

        if [[ -n "$log" ]] && [[ "$log" != /* ]]; then
            log="$evidence_dir/$log"
        fi
        local cls err_count=0 err_lines
        cls="$(classify_command "$cmd")"
        err_lines="$(extract_error_lines "$log" "$cls" 10)"
        [[ -n "$err_lines" ]] && err_count=$(printf '%s\n' "$err_lines" | grep -c . || true)

        failures="$(printf '%s' "$failures" | jq \
            --arg cls "$cls" --arg cmd "$cmd" \
            --argjson exit "${exit_code:-1}" --argjson n "${err_count:-0}" \
            '. + [{failure_class: $cls, command: $cmd, exit_code: $exit, error_count: $n}]' \
            2>/dev/null || printf '%s' "$failures")"
    done < <(jq -r '.[]? | select((.exit_code // 0) != 0)
                    | "\(.command // "")\t\(.exit_code // 1)\t\(.log // "")"' \
             "$evidence_file" 2>/dev/null || true)

    printf '%s\n' "$failures"
}
