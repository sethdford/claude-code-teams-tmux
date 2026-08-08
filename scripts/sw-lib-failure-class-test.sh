#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  failure-class test suite                                                ║
# ║  Command classification, failure detection, error-line extraction        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: failure-class Tests"

setup_test_env "sw-lib-failure-class-test"
trap cleanup_test_env EXIT

source "$SCRIPT_DIR/lib/failure-class.sh"

LOGS="$TEST_TEMP_DIR/logs"
mkdir -p "$LOGS"

# ═══════════════════════════════════════════════════════════════════════════════
# classify_command — command string → failure class
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}classify_command${RESET}"

assert_eq "tsc --noEmit → typecheck"   "typecheck" "$(classify_command 'npx tsc --noEmit')"
assert_eq "mypy → typecheck"           "typecheck" "$(classify_command 'mypy src/')"
assert_eq "npm run lint → lint"        "lint"      "$(classify_command 'npm run lint')"
assert_eq "eslint → lint"              "lint"      "$(classify_command 'eslint . --max-warnings 0')"
assert_eq "shellcheck → lint"          "lint"      "$(classify_command 'shellcheck scripts/*.sh')"
assert_eq "go build → compile"         "compile"   "$(classify_command 'go build ./...')"
assert_eq "cargo build → compile"      "compile"   "$(classify_command 'cargo build --release')"
assert_eq "npm run build → compile"    "compile"   "$(classify_command 'npm run build')"
assert_eq "npm test → test"            "test"      "$(classify_command 'npm test')"
assert_eq "vitest run → test"          "test"      "$(classify_command 'vitest run')"
assert_eq "go test → test"             "test"      "$(classify_command 'go test ./...')"
# Ordering assertions: typecheck must win over compile, lint over test
assert_eq "build:types → typecheck"    "typecheck" "$(classify_command 'npm run build:types')"
assert_eq "npm run typecheck → typecheck" "typecheck" "$(classify_command 'npm run typecheck')"
assert_eq "test:lint → lint"           "lint"      "$(classify_command 'npm run test:lint')"
assert_eq "uppercase TSC → typecheck"  "typecheck" "$(classify_command 'TSC --noEmit')"
assert_eq "empty → unknown"            "unknown"   "$(classify_command '')"
assert_eq "no args → unknown"          "unknown"   "$(classify_command)"
assert_eq "unrecognized → unknown"     "unknown"   "$(classify_command 'frobnicate --widgets')"

# ═══════════════════════════════════════════════════════════════════════════════
# detect_failure_class — evidence file → class + command + log
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}detect_failure_class${RESET}"

write_evidence() { printf '%s\n' "$2" > "$LOGS/$1"; }

# Single lint failure while tests pass
write_evidence "ev-lint.json" '[
  {"command":"npm test","exit_code":0,"duration_s":3,"log":"tests-iter-1.log"},
  {"command":"npm run lint","exit_code":1,"duration_s":2,"log":"tests-extra-iter-1-0.log"}
]'
result=$(detect_failure_class "$LOGS/ev-lint.json" "$LOGS/iteration-1.log")
assert_eq "lint failure class"   "lint" "$(printf '%s' "$result" | cut -f1)"
assert_eq "lint failure command" "npm run lint" "$(printf '%s' "$result" | cut -f2)"
assert_eq "log resolved against evidence dir" "$LOGS/tests-extra-iter-1-0.log" "$(printf '%s' "$result" | cut -f3)"

# First non-zero entry wins when several fail
write_evidence "ev-multi.json" '[
  {"command":"npx tsc --noEmit","exit_code":2,"duration_s":5,"log":"a.log"},
  {"command":"npm run lint","exit_code":1,"duration_s":2,"log":"b.log"}
]'
result=$(detect_failure_class "$LOGS/ev-multi.json" "$LOGS/iteration-1.log")
assert_eq "first non-zero entry wins" "typecheck" "$(printf '%s' "$result" | cut -f1)"

# All commands pass → falls through to unknown (caller decides)
write_evidence "ev-clean.json" '[{"command":"npm test","exit_code":0,"duration_s":3,"log":"t.log"}]'
result=$(TEST_PASSED="true" TEST_CMD="npm test" detect_failure_class "$LOGS/ev-clean.json" "$LOGS/iteration-1.log")
assert_eq "all-zero evidence → unknown" "unknown" "$(printf '%s' "$result" | cut -f1)"

# No evidence file, but the test gate reported failure
result=$(TEST_PASSED="false" TEST_CMD="npm test" detect_failure_class "$LOGS/missing.json" "$LOGS/iteration-1.log")
assert_eq "TEST_CMD fallback class"   "test" "$(printf '%s' "$result" | cut -f1)"
assert_eq "TEST_CMD fallback command" "npm test" "$(printf '%s' "$result" | cut -f2)"
assert_eq "TEST_CMD fallback log"     "$LOGS/iteration-1.log" "$(printf '%s' "$result" | cut -f3)"

# Malformed JSON must not break the loop
printf 'not json at all {{{\n' > "$LOGS/ev-bad.json"
result=$(detect_failure_class "$LOGS/ev-bad.json" "$LOGS/iteration-1.log")
assert_eq "malformed evidence → unknown" "unknown" "$(printf '%s' "$result" | cut -f1)"
assert_eq "malformed evidence → fallback log" "$LOGS/iteration-1.log" "$(printf '%s' "$result" | cut -f3)"

# Missing log field falls back to the supplied log
write_evidence "ev-nolog.json" '[{"command":"npm run lint","exit_code":1,"duration_s":1}]'
result=$(detect_failure_class "$LOGS/ev-nolog.json" "$LOGS/iteration-1.log")
assert_eq "missing log field → fallback log" "$LOGS/iteration-1.log" "$(printf '%s' "$result" | cut -f3)"

# Empty evidence array
write_evidence "ev-empty.json" '[]'
result=$(detect_failure_class "$LOGS/ev-empty.json" "$LOGS/iteration-1.log")
assert_eq "empty evidence → unknown" "unknown" "$(printf '%s' "$result" | cut -f1)"

# ═══════════════════════════════════════════════════════════════════════════════
# extract_error_lines — log + class → error lines
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}extract_error_lines${RESET}"

cat > "$LOGS/tsc.log" <<'EOF'
> tsc --noEmit
src/a.ts(12,5): error TS2345: Argument of type 'string' is not assignable to parameter of type 'number'.
src/b.ts(3,1): error TS2304: Cannot find name 'foo'.
Found 2 errors.
EOF
lines="$(extract_error_lines "$LOGS/tsc.log" "typecheck")"
assert_contains "typecheck pattern finds TS code" "$lines" "error TS2345"
assert_eq "typecheck line count" "2" "$(printf '%s\n' "$lines" | grep -c 'error TS' || true)"
if fc_pattern_matched "$LOGS/tsc.log" "typecheck"; then
    assert_pass "typecheck not a truncated fallback"
else
    assert_fail "typecheck not a truncated fallback"
fi

cat > "$LOGS/lint.log" <<'EOF'
/repo/src/index.js
  12:7  error  'x' is assigned a value but never used  no-unused-vars
  40:1  error  Unexpected console statement            no-console
✖ 2 problems (2 errors, 0 warnings)
EOF
lines="$(extract_error_lines "$LOGS/lint.log" "lint")"
assert_contains "lint pattern finds rule violation" "$lines" "no-unused-vars"

cat > "$LOGS/compile.log" <<'EOF'
main.go:14:2: cannot find package "github.com/nope/nope"
build failed
EOF
lines="$(extract_error_lines "$LOGS/compile.log" "compile")"
assert_contains "compile pattern finds missing package" "$lines" "cannot find package"

# Generic fallback: class pattern misses, generic error pattern hits
cat > "$LOGS/generic.log" <<'EOF'
Running suite
AssertionError: expected 1 to equal 2
done
EOF
lines="$(extract_error_lines "$LOGS/generic.log" "typecheck")"
assert_contains "generic fallback catches assertion" "$lines" "AssertionError"
if fc_pattern_matched "$LOGS/generic.log" "typecheck"; then
    assert_pass "generic fallback is not truncated"
else
    assert_fail "generic fallback is not truncated"
fi

# Last-N fallback: nothing matches any pattern
cat > "$LOGS/quiet.log" <<'EOF'
step one complete
step two complete
exiting with status 1
EOF
lines="$(extract_error_lines "$LOGS/quiet.log" "compile")"
assert_gt "last-N fallback still returns lines" "$(printf '%s\n' "$lines" | grep -c . || true)" "0"
if fc_pattern_matched "$LOGS/quiet.log" "compile"; then
    assert_fail "last-N fallback flagged"
else
    assert_pass "last-N fallback flagged"
fi
if fc_pattern_matched "$LOGS/does-not-exist.log" "lint"; then
    assert_fail "missing log reports no match"
else
    assert_pass "missing log reports no match"
fi

# Max-lines cap
: > "$LOGS/many.log"
for i in $(seq 1 30); do echo "error: problem $i" >> "$LOGS/many.log"; done
lines="$(extract_error_lines "$LOGS/many.log" "compile" 4)"
assert_eq "max lines honored" "4" "$(printf '%s\n' "$lines" | grep -c . || true)"

# Missing / empty logs
assert_eq "missing log → empty" "" "$(extract_error_lines "$LOGS/does-not-exist.log" "lint")"
: > "$LOGS/empty.log"
assert_eq "empty log → empty" "" "$(extract_error_lines "$LOGS/empty.log" "lint")"

# ═══════════════════════════════════════════════════════════════════════════════
# collect_all_failures — every failing command, capped
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}collect_all_failures${RESET}"

cp "$LOGS/tsc.log" "$LOGS/a.log"
cp "$LOGS/lint.log" "$LOGS/b.log"
failures="$(collect_all_failures "$LOGS/ev-multi.json")"
assert_eq "two failures collected" "2" "$(printf '%s' "$failures" | jq 'length')"
assert_json_key "primary is typecheck" "$failures" '.[0].failure_class' "typecheck"
assert_json_key "secondary is lint"    "$failures" '.[1].failure_class' "lint"
assert_json_key "exit code preserved"  "$failures" '.[0].exit_code' "2"
assert_gt "typecheck error count > 0" "$(printf '%s' "$failures" | jq -r '.[0].error_count')" "0"

assert_eq "clean evidence → empty array" "[]" "$(collect_all_failures "$LOGS/ev-clean.json" | tr -d ' \n')"
assert_eq "missing evidence → empty array" "[]" "$(collect_all_failures "$LOGS/missing.json" | tr -d ' \n')"
assert_eq "malformed evidence → empty array" "[]" "$(collect_all_failures "$LOGS/ev-bad.json" | tr -d ' \n')"

# Cap at FC_MAX_FAILURES
big='[]'
for i in $(seq 1 8); do
    big="$(printf '%s' "$big" | jq --arg c "cmd$i" '. + [{command:$c,exit_code:1,duration_s:1,log:"none.log"}]')"
done
printf '%s\n' "$big" > "$LOGS/ev-big.json"
assert_eq "failure list capped" "$FC_MAX_FAILURES" "$(collect_all_failures "$LOGS/ev-big.json" | jq 'length')"

# ═══════════════════════════════════════════════════════════════════════════════
# fc_json_array — hand-rolled JSON escaping for the no-jq path
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}fc_json_array${RESET}"

assert_eq "empty input → empty array" "[]" "$(fc_json_array "")"
assert_eq "single line" '["one"]' "$(fc_json_array "one")"
assert_eq "two lines" '["one","two"]' "$(fc_json_array "one
two")"
assert_eq "blank lines skipped" '["one","two"]' "$(fc_json_array "one

two")"
assert_eq "quotes escaped" '["say \"hi\""]' "$(fc_json_array 'say "hi"')"
assert_eq "backslashes escaped" '["a\\b"]' "$(fc_json_array 'a\b')"

# Everything it emits must survive a real JSON parser
out="$(fc_json_array 'error: expected "a\b" at /x/y
  9:1  warning  quote'"'"'s')"
if printf '%s' "$out" | jq -e 'type == "array" and length == 2' >/dev/null 2>&1; then
    assert_pass "escaped output parses as JSON"
else
    assert_fail "escaped output parses as JSON" "$out"
fi

# ANSI escapes are routine in build output and are not valid raw JSON
out="$(fc_json_array "$(printf 'error\033[0m: red')")"
if printf '%s' "$out" | jq -e '.[0] | contains("error")' >/dev/null 2>&1; then
    assert_pass "control characters stripped"
else
    assert_fail "control characters stripped" "$out"
fi

print_test_results
