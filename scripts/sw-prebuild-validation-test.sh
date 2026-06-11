#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-prebuild-validation-test.sh — Pre-Build Validation Engine Test Suite ║
# ║  Unit + integration tests for catch-failures-before-build validation     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/pipeline-prebuild-validation.sh"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"; echo "    Actual:   $actual"
    fi
}

assert_contains() {
    local needle="$1" haystack="$2" description="${3:-}"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"; echo "    Actual: $haystack"
    fi
}

assert_status() {  # assert the leading "status<US>..." token of a check result
    local expected="$1" result="$2" description="${3:-}"
    local sep=$'\037'
    local actual="${result%%${sep}*}"
    assert_equals "$expected" "$actual" "$description"
}

# ─── Mock project factory ───────────────────────────────────────────────────
# Creates an isolated git repo so the changed-file scope is deterministic and
# tests never interfere with one another.
make_project() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/sw-pbv-XXXXXX")"
    (
        cd "$dir"
        git init -q
        git config user.email "t@t.co"
        git config user.name "test"
        echo '{"name":"mock"}' > package.json
        mkdir -p .claude
        git add -A && git commit -qm init
    )
    echo "$dir"
}

# Run a check function in a project dir with given env, echo its raw result.
run_check_in() {
    local dir="$1" check_fn="$2"; shift 2
    (
        cd "$dir"
        export PROJECT_ROOT="$dir" STATE_DIR="$dir/.claude" BASE_BRANCH="nonexistent-base"
        # Remaining args are KEY=VAL env overrides.
        local kv
        for kv in "$@"; do export "$kv"; done
        # shellcheck disable=SC1090
        source "$LIB"
        # Unquoted on purpose: check_fn may carry args (e.g. "_prebuild_run_check syntax 30").
        # shellcheck disable=SC2086
        $check_fn
    )
}

run_validate_in() {
    local dir="$1"; shift
    (
        cd "$dir"
        export PROJECT_ROOT="$dir" STATE_DIR="$dir/.claude" BASE_BRANCH="nonexistent-base" BUILD_TEST_RETRIES=2
        local kv
        for kv in "$@"; do export "$kv"; done
        # shellcheck disable=SC1090
        source "$LIB"
        prebuild_validate >/dev/null 2>&1
        echo "RC=$?"
    )
}

echo ""
echo "═══ Pre-Build Validation Engine Test Suite ═══"
echo ""

# ─── 1. Library loads & exposes the public contract ─────────────────────────
echo "▸ Library structure"
( source "$LIB"
  type prebuild_validate >/dev/null 2>&1 && echo "ORCH_OK"
  type _prebuild_run_check >/dev/null 2>&1 && echo "RUN_OK"
  type _prebuild_write_report >/dev/null 2>&1 && echo "REPORT_OK" ) > /tmp/sw-pbv-struct.$$ 2>&1
assert_contains "ORCH_OK"   "$(cat /tmp/sw-pbv-struct.$$)" "prebuild_validate is defined"
assert_contains "RUN_OK"    "$(cat /tmp/sw-pbv-struct.$$)" "_prebuild_run_check is defined"
assert_contains "REPORT_OK" "$(cat /tmp/sw-pbv-struct.$$)" "_prebuild_write_report is defined"
rm -f /tmp/sw-pbv-struct.$$

# Double-source guard.
( source "$LIB"; source "$LIB"; echo "GUARD_OK" ) > /tmp/sw-pbv-guard.$$ 2>&1
assert_contains "GUARD_OK" "$(cat /tmp/sw-pbv-guard.$$)" "module guard allows double-source"
rm -f /tmp/sw-pbv-guard.$$

# ─── 2. Millisecond clock ───────────────────────────────────────────────────
echo "▸ Millisecond clock"
MS=$( source "$LIB"; _prebuild_now_ms )
assert_equals "0" "$(echo "$MS" | grep -cvE '^[0-9]+$')" "_prebuild_now_ms emits an integer"
[[ "$MS" -gt 1000000000000 ]] && assert_equals "ok" "ok" "_prebuild_now_ms is in ms range" \
    || assert_equals "ms-range" "$MS" "_prebuild_now_ms is in ms range"

# ─── 3. Config readers (env → config → default) ─────────────────────────────
echo "▸ Config readers"
assert_equals "60" "$( source "$LIB"; STATE_DIR=/nonexistent _prebuild_timeout )" "timeout defaults to 60"
assert_equals "120" "$( source "$LIB"; VALIDATION_TIMEOUT=120 _prebuild_timeout )" "VALIDATION_TIMEOUT env override"
assert_equals "skip_build_loop" "$( source "$LIB"; STATE_DIR=/nonexistent _prebuild_on_failure )" "on_failure defaults to skip_build_loop"
assert_equals "continue" "$( source "$LIB"; VALIDATION_ON_FAILURE=continue _prebuild_on_failure )" "on_failure env override"

ENABLED_RC=$( source "$LIB"; STATE_DIR=/nonexistent; if _prebuild_enabled; then echo 0; else echo 1; fi )
assert_equals "0" "$ENABLED_RC" "validation enabled by default"
DISABLED_RC=$( source "$LIB"; if VALIDATION_ENABLED=false _prebuild_enabled; then echo 0; else echo 1; fi )
assert_equals "1" "$DISABLED_RC" "VALIDATION_ENABLED=false disables"

CHECKS_ENV=$( source "$LIB"; VALIDATION_CHECKS="syntax,imports" _prebuild_checks | tr '\n' ' ' )
assert_equals "syntax imports " "$CHECKS_ENV" "VALIDATION_CHECKS env override wins, order preserved"
CHECKS_DEFAULT=$( source "$LIB"; STATE_DIR=/nonexistent _prebuild_checks | tr '\n' ' ' )
assert_equals "required_files syntax imports smoke_test " "$CHECKS_DEFAULT" "default checks are cheap→expensive"

# ─── 4. Criticality map ─────────────────────────────────────────────────────
echo "▸ Criticality"
for c in required_files syntax imports; do
    RC=$( source "$LIB"; if _prebuild_is_critical "$c"; then echo crit; else echo soft; fi )
    assert_equals "crit" "$RC" "$c is critical"
done
RC=$( source "$LIB"; if _prebuild_is_critical smoke_test; then echo crit; else echo soft; fi )
assert_equals "soft" "$RC" "smoke_test is soft"

# ─── 5. required_files check ────────────────────────────────────────────────
echo "▸ required_files check"
PROJ=$(make_project)
RES=$(run_check_in "$PROJ" _prebuild_check_required_files)
assert_status "pass" "$RES" "passes when package.json present (default)"
# Configure a missing required file.
cat > "$PROJ/.claude/daemon-config.json" <<'JSON'
{"validation":{"checks":[{"type":"required_files","files":["GONE.txt","package.json"]}]}}
JSON
RES=$(run_check_in "$PROJ" _prebuild_check_required_files)
assert_status "fail" "$RES" "fails when a required file is missing"
assert_contains "GONE.txt" "$RES" "names the missing file"
rm -rf "$PROJ"

# ─── 6. syntax check (positive / negative / skip / multi-lang) ──────────────
echo "▸ syntax check"
PROJ=$(make_project)
(cd "$PROJ"; echo 'const a = 1; console.log(a);' > ok.js; git add -A)
RES=$(run_check_in "$PROJ" _prebuild_check_syntax)
assert_status "pass" "$RES" "valid JS passes (positive)"
(cd "$PROJ"; echo 'const b = ;' > broken.js; git add -A)
RES=$(run_check_in "$PROJ" _prebuild_check_syntax)
assert_status "fail" "$RES" "invalid JS fails (negative)"
assert_contains "broken.js" "$RES" "syntax failure names the file"
rm -rf "$PROJ"

# Bash syntax detection.
PROJ=$(make_project)
(cd "$PROJ"; printf 'if [ 1 ]; then\n' > broken.sh; git add -A)   # unterminated if
RES=$(run_check_in "$PROJ" _prebuild_check_syntax)
assert_status "fail" "$RES" "invalid bash fails"
rm -rf "$PROJ"

# Skip when no changed source files.
PROJ=$(make_project)
RES=$(run_check_in "$PROJ" _prebuild_check_syntax)
assert_status "skip" "$RES" "skips when nothing changed"
rm -rf "$PROJ"

# Edge case: empty file is valid.
PROJ=$(make_project)
(cd "$PROJ"; : > empty.js; git add -A)
RES=$(run_check_in "$PROJ" _prebuild_check_syntax)
assert_status "pass" "$RES" "empty JS file is valid (edge case)"
rm -rf "$PROJ"

# ─── 7. imports check (resolve / break / skip) ──────────────────────────────
echo "▸ imports check"
PROJ=$(make_project)
(cd "$PROJ"
 echo 'module.exports = {};' > util.js
 echo "const u = require('./util');" > main.js
 git add -A)
RES=$(run_check_in "$PROJ" _prebuild_check_imports)
assert_status "pass" "$RES" "resolves a valid relative require"
(cd "$PROJ"; echo "const m = require('./ghost');" > bad.js; git add -A)
RES=$(run_check_in "$PROJ" _prebuild_check_imports)
assert_status "fail" "$RES" "fails on unresolved relative import"
assert_contains "ghost" "$RES" "names the broken specifier"
rm -rf "$PROJ"

# Bare package imports are ignored (not our job).
PROJ=$(make_project)
(cd "$PROJ"; echo "const fs = require('fs'); const x = require('lodash');" > pkg.js; git add -A)
RES=$(run_check_in "$PROJ" _prebuild_check_imports)
assert_status "pass" "$RES" "bare package imports are ignored"
rm -rf "$PROJ"

# Directory + index resolution.
PROJ=$(make_project)
(cd "$PROJ"
 mkdir -p lib
 echo 'module.exports = 1;' > lib/index.js
 echo "const l = require('./lib');" > uses-dir.js
 git add -A)
RES=$(run_check_in "$PROJ" _prebuild_check_imports)
assert_status "pass" "$RES" "resolves directory/index.js imports (edge case)"
rm -rf "$PROJ"

# ─── 8. smoke_test check (pass / fail / skip / no-eval safety) ───────────────
echo "▸ smoke_test check"
PROJ=$(make_project)
RES=$(run_check_in "$PROJ" _prebuild_check_smoke_test "VALIDATION_SMOKE_CMD=true")
assert_status "pass" "$RES" "passing smoke cmd → pass"
RES=$(run_check_in "$PROJ" _prebuild_check_smoke_test "VALIDATION_SMOKE_CMD=exit 7")
assert_status "fail" "$RES" "failing smoke cmd → fail"
RES=$(run_check_in "$PROJ" _prebuild_check_smoke_test)
assert_status "skip" "$RES" "no smoke cmd configured → skip"
# Injection safety: a cmd with shell metachars runs in sh -c, not eval'd into us.
RES=$(run_check_in "$PROJ" _prebuild_check_smoke_test "VALIDATION_SMOKE_CMD=echo hi && true")
assert_status "pass" "$RES" "compound smoke cmd executes safely"
rm -rf "$PROJ"

# ─── 9. _prebuild_run_check (timing + timeout) ──────────────────────────────
echo "▸ per-check runner"
PROJ=$(make_project)
(cd "$PROJ"; echo 'const a=1;console.log(a);' > ok.js; git add -A)
RES=$(run_check_in "$PROJ" "_prebuild_run_check syntax 30")
# result: status<US>msg<US>file<US>dur — last field must be an integer.
SEP=$'\037'; DUR="${RES##*${SEP}}"
assert_equals "0" "$(echo "$DUR" | grep -cvE '^[0-9]+$')" "run_check appends an integer duration"
assert_status "pass" "$RES" "run_check wraps a passing check"
# Unknown check → skip, never crash.
RES=$(run_check_in "$PROJ" "_prebuild_run_check totally_unknown 5")
assert_status "skip" "$RES" "unknown check type is skipped, not fatal"
rm -rf "$PROJ"

# ─── 10. Report writer (atomic, well-formed) ────────────────────────────────
echo "▸ report writer"
PROJ=$(make_project)
OUT=$(
  cd "$PROJ"
  export STATE_DIR="$PROJ/.claude"
  source "$LIB"
  _prebuild_write_report "failed" 3 1 1 1 1234 '[{"type":"syntax","message":"x","file":"a.js"}]' "~120 seconds"
)
assert_contains "validation-report.json" "$OUT" "report path returned"
assert_equals "failed" "$(jq -r .status "$PROJ/.claude/validation-report.json")" "report status field"
assert_equals "3" "$(jq -r .checks_run "$PROJ/.claude/validation-report.json")" "report checks_run field"
assert_equals "1234" "$(jq -r .total_duration_ms "$PROJ/.claude/validation-report.json")" "report duration field"
assert_equals "syntax" "$(jq -r '.failed_checks[0].type' "$PROJ/.claude/validation-report.json")" "report failed_checks populated"
# No leftover temp file.
assert_equals "0" "$(ls "$PROJ/.claude/"*.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "atomic write leaves no temp file"
rm -rf "$PROJ"

# ─── 11. Orchestrator integration (the acceptance criteria) ─────────────────
echo "▸ orchestrator integration"
# Critical failure → return 1, report written, build skipped.
PROJ=$(make_project)
(cd "$PROJ"; echo 'const z = ;' > broken.js; git add -A)
RC=$(run_validate_in "$PROJ" "VALIDATION_CHECKS=syntax")
assert_equals "RC=1" "$RC" "critical syntax failure → return 1 (skip build)"
assert_equals "failed" "$(jq -r .status "$PROJ/.claude/validation-report.json")" "report marks failed on critical"
assert_contains "validation: failed" "$(cat "$PROJ/.claude/pipeline-state.md" 2>/dev/null)" "logs summary to pipeline-state.md"
rm -rf "$PROJ"

# All-pass → return 0.
PROJ=$(make_project)
(cd "$PROJ"; echo 'const a=1;console.log(a);' > ok.js; git add -A)
RC=$(run_validate_in "$PROJ" "VALIDATION_CHECKS=syntax,imports")
assert_equals "RC=0" "$RC" "all checks pass → return 0 (proceed to build)"
rm -rf "$PROJ"

# Disabled → return 0, degrade-safe.
PROJ=$(make_project)
(cd "$PROJ"; echo 'const z = ;' > broken.js; git add -A)
RC=$(run_validate_in "$PROJ" "VALIDATION_ENABLED=false")
assert_equals "RC=0" "$RC" "disabled validation proceeds (degrade-safe)"
rm -rf "$PROJ"

# Soft failure + on_failure=continue → return 0.
PROJ=$(make_project)
RC=$(run_validate_in "$PROJ" "VALIDATION_CHECKS=smoke_test" "VALIDATION_SMOKE_CMD=exit 4" "VALIDATION_ON_FAILURE=continue")
assert_equals "RC=0" "$RC" "soft failure with on_failure=continue proceeds"
rm -rf "$PROJ"

# Soft failure + on_failure=skip_build_loop → return 1.
PROJ=$(make_project)
RC=$(run_validate_in "$PROJ" "VALIDATION_CHECKS=smoke_test" "VALIDATION_SMOKE_CMD=exit 4" "VALIDATION_ON_FAILURE=skip_build_loop")
assert_equals "RC=1" "$RC" "soft failure with skip_build_loop blocks build"
rm -rf "$PROJ"

# ─── 11b. Real event emission (with helpers.sh loaded) ──────────────────────
echo "▸ event emission (events.jsonl)"
PROJ=$(make_project)
(cd "$PROJ"; echo 'const z = ;' > broken.js; git add -A)
EVENTS_TMP="$PROJ/events.jsonl"
(
  cd "$PROJ"
  export PROJECT_ROOT="$PROJ" STATE_DIR="$PROJ/.claude" BASE_BRANCH="nonexistent-base" \
         BUILD_TEST_RETRIES=2 VALIDATION_CHECKS=syntax EVENTS_FILE="$EVENTS_TMP"
  # shellcheck disable=SC1090
  [[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
  [[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
  source "$LIB"
  prebuild_validate >/dev/null 2>&1 || true
)
assert_contains "validation.complete" "$(cat "$EVENTS_TMP" 2>/dev/null)" "emits validation.complete event"
assert_contains "validation.check" "$(cat "$EVENTS_TMP" 2>/dev/null)" "emits per-check validation.check event"
rm -rf "$PROJ"

# ─── 12. Performance: validation completes well within budget ───────────────
echo "▸ performance"
PROJ=$(make_project)
(cd "$PROJ"; for i in 1 2 3 4 5; do echo "const v$i=$i;console.log(v$i);" > "f$i.js"; done; git add -A)
START=$( source "$LIB"; _prebuild_now_ms )
run_validate_in "$PROJ" "VALIDATION_CHECKS=syntax,imports" >/dev/null
END=$( source "$LIB"; _prebuild_now_ms )
ELAPSED=$(( END - START ))
[[ "$ELAPSED" -lt 60000 ]] && assert_equals "ok" "ok" "validation finishes < 60s budget (${ELAPSED}ms)" \
    || assert_equals "<60000ms" "${ELAPSED}ms" "validation finishes < 60s budget"
rm -rf "$PROJ"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo -e "  \033[38;2;74;222;128m\033[1mPASS: $PASS\033[0m    \033[38;2;248;113;113m\033[1mFAIL: $FAIL\033[0m"
echo "═══════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
