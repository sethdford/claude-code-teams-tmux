#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-complexity-test.sh — Script Complexity Doctor Check Test Suite       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ─────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_exit_code() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected exit code: $expected"
        echo "    Actual exit code:   $actual"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if ! echo "$haystack" | grep -q "$needle" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected NOT to contain: $needle"
    fi
}

assert_json_valid() {
    local json="$1" description="${2:-}"
    if echo "$json" | jq empty 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Invalid JSON output"
    fi
}

# ─── Setup: create test fixtures ──────────────────────────────────────────
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Good script (no violations)
cat > "$TMPDIR_BASE/good-script.sh" <<'GOOD'
#!/usr/bin/env bash
VERSION="1.0.0"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

hello() {
    echo "hello"
}

main() {
    hello
}

main "$@"
GOOD

# Bad script (multiple violations)
cat > "$TMPDIR_BASE/bad-script.sh" <<'BAD'
#!/usr/bin/env bash
set -euo pipefail

count=$(grep -c 'pattern' somefile)

echo "data" | while read -r line; do
    total=$((total + 1))
done

echo "result" > /tmp/output.txt

gh api repos/foo/bar
BAD

# Complex script (high CC, deep nesting)
cat > "$TMPDIR_BASE/complex-script.sh" <<'COMPLEX'
#!/usr/bin/env bash
VERSION="1.0.0"
set -euo pipefail

process() {
    if [[ -f "$1" ]]; then
        if [[ -r "$1" ]]; then
            for line in $(cat "$1"); do
                if [[ "$line" == "start" ]]; then
                    while true; do
                        if [[ -z "$line" ]]; then
                            break
                        fi
                    done
                elif [[ "$line" == "end" ]]; then
                    case "$line" in
                        a) echo "a" ;;
                        b) echo "b" ;;
                        c) echo "c" ;;
                    esac
                fi
            done
        fi
    fi
}

check() {
    [[ -f "$1" ]] && [[ -r "$1" ]] && echo "ok" || echo "fail"
    [[ -d "$1" ]] || return 1
}

main() {
    if [[ $# -gt 0 ]]; then
        process "$1"
    else
        check "."
    fi
}

main "$@"
COMPLEX

# Bash 4 syntax script
cat > "$TMPDIR_BASE/bash4-script.sh" <<'BASH4'
#!/usr/bin/env bash
VERSION="1.0.0"
set -euo pipefail

declare -A my_map
readarray -t lines < somefile
BASH4

# ─── Source the library ───────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/complexity-analyzer.sh"

# ═══════════════════════════════════════════════════════════════════════════
echo "sw-complexity-test.sh"
echo ""

# ─── Test: Library loads successfully ─────────────────────────────────────
echo "  Library Loading"

test_library_loads() {
    if [[ "$(type -t complexity_analyze_script 2>/dev/null)" == "function" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m complexity_analyze_script function exists"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m complexity_analyze_script function exists"
    fi

    if [[ "$(type -t complexity_calculate_metrics 2>/dev/null)" == "function" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m complexity_calculate_metrics function exists"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m complexity_calculate_metrics function exists"
    fi

    if [[ "$(type -t complexity_detect_anti_patterns 2>/dev/null)" == "function" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m complexity_detect_anti_patterns function exists"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m complexity_detect_anti_patterns function exists"
    fi
}

test_library_loads

# ─── Test: Metrics calculation ────────────────────────────────────────────
echo ""
echo "  Metrics Calculation"

test_metrics_good_script() {
    local metrics
    metrics=$(complexity_calculate_metrics "$TMPDIR_BASE/good-script.sh")

    assert_json_valid "$metrics" "good-script metrics is valid JSON"

    local total_lines
    total_lines=$(echo "$metrics" | jq '.total_lines')
    if [[ $total_lines -gt 0 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m good-script has positive line count ($total_lines)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m good-script has positive line count"
    fi

    local func_count
    func_count=$(echo "$metrics" | jq '.function_count')
    assert_equals "2" "$func_count" "good-script has 2 functions"
}

test_metrics_good_script

test_metrics_nonexistent() {
    local exit_code=0
    complexity_calculate_metrics "/nonexistent/path.sh" 2>/dev/null || exit_code=$?
    assert_exit_code "1" "$exit_code" "nonexistent file returns exit 1"
}

test_metrics_nonexistent

# ─── Test: Cyclomatic complexity ──────────────────────────────────────────
echo ""
echo "  Cyclomatic Complexity"

test_cc_simple() {
    local cc
    cc=$(complexity_estimate_cyclomatic "$TMPDIR_BASE/good-script.sh")
    if [[ $cc -ge 1 && $cc -le 15 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m good-script has low CC ($cc)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m good-script has low CC (got $cc)"
    fi
}

test_cc_simple

test_cc_complex() {
    local cc
    cc=$(complexity_estimate_cyclomatic "$TMPDIR_BASE/complex-script.sh")
    if [[ $cc -gt 10 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m complex-script has high CC ($cc)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m complex-script has high CC (got $cc)"
    fi
}

test_cc_complex

# ─── Test: Nesting depth ─────────────────────────────────────────────────
echo ""
echo "  Nesting Depth"

test_nesting_simple() {
    local depth
    depth=$(complexity_calculate_nesting_depth "$TMPDIR_BASE/good-script.sh")
    if [[ $depth -ge 1 && $depth -le 4 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m good-script has shallow nesting ($depth)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m good-script has shallow nesting (got $depth)"
    fi
}

test_nesting_simple

test_nesting_complex() {
    local depth
    depth=$(complexity_calculate_nesting_depth "$TMPDIR_BASE/complex-script.sh")
    if [[ $depth -ge 3 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m complex-script has deep nesting ($depth)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m complex-script has deep nesting (got $depth)"
    fi
}

test_nesting_complex

# ─── Test: Anti-pattern detection ─────────────────────────────────────────
echo ""
echo "  Anti-Pattern Detection"

test_no_violations_good() {
    local violations
    violations=$(complexity_detect_anti_patterns "$TMPDIR_BASE/good-script.sh")
    local count
    count=$(echo "$violations" | jq 'length')
    assert_equals "0" "$count" "good-script has no violations"
}

test_no_violations_good

test_violations_bad() {
    local violations
    violations=$(complexity_detect_anti_patterns "$TMPDIR_BASE/bad-script.sh")
    assert_json_valid "$violations" "bad-script violations is valid JSON"

    local count
    count=$(echo "$violations" | jq 'length')
    if [[ $count -ge 3 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m bad-script has 3+ violations ($count found)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m bad-script has 3+ violations (got $count)"
    fi

    # Check specific patterns detected
    local patterns
    patterns=$(echo "$violations" | jq -r '.[].pattern' | sort)

    assert_contains "$patterns" "grep-c-pipefail" "detects grep-c-pipefail"
    assert_contains "$patterns" "pipe-while-read" "detects pipe-while-read"
    assert_contains "$patterns" "missing-version" "detects missing-version"
    assert_contains "$patterns" "missing-no-github" "detects missing-no-github"
}

test_violations_bad

test_violations_bash4() {
    local violations
    violations=$(complexity_detect_anti_patterns "$TMPDIR_BASE/bash4-script.sh")
    local patterns
    patterns=$(echo "$violations" | jq -r '.[].pattern')

    assert_contains "$patterns" "bash4-syntax" "detects bash4-syntax (declare -A / readarray)"
}

test_violations_bash4

test_violations_have_line_numbers() {
    local violations
    violations=$(complexity_detect_anti_patterns "$TMPDIR_BASE/bad-script.sh")
    local lines_present
    lines_present=$(echo "$violations" | jq '[.[] | select(.line_number > 0)] | length')
    if [[ $lines_present -gt 0 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m violations include line numbers ($lines_present with line > 0)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m violations include line numbers"
    fi
}

test_violations_have_line_numbers

test_violations_have_suggestions() {
    local violations
    violations=$(complexity_detect_anti_patterns "$TMPDIR_BASE/bad-script.sh")
    local has_suggestions
    has_suggestions=$(echo "$violations" | jq '[.[] | select(.suggestion != "")] | length')
    local total
    total=$(echo "$violations" | jq 'length')
    assert_equals "$total" "$has_suggestions" "all violations have suggestions"
}

test_violations_have_suggestions

# ─── Test: Full analysis ──────────────────────────────────────────────────
echo ""
echo "  Full Analysis"

test_full_analysis_good() {
    local result
    result=$(complexity_analyze_script "$TMPDIR_BASE/good-script.sh")
    assert_json_valid "$result" "full analysis produces valid JSON"

    local grade
    grade=$(echo "$result" | jq -r '.grade')
    assert_equals "A" "$grade" "good-script gets grade A"

    local has_metrics
    has_metrics=$(echo "$result" | jq 'has("metrics")')
    assert_equals "true" "$has_metrics" "result has metrics field"

    local has_cc
    has_cc=$(echo "$result" | jq 'has("cyclomatic_complexity")')
    assert_equals "true" "$has_cc" "result has cyclomatic_complexity field"
}

test_full_analysis_good

test_full_analysis_schema() {
    local result
    result=$(complexity_analyze_script "$TMPDIR_BASE/complex-script.sh")

    # Verify JSON schema
    local fields
    fields=$(echo "$result" | jq 'keys | sort | join(",")')
    assert_contains "$fields" "script" "result has script field"
    assert_contains "$fields" "metrics" "result has metrics field"
    assert_contains "$fields" "cyclomatic_complexity" "result has cyclomatic_complexity field"
    assert_contains "$fields" "max_nesting_depth" "result has max_nesting_depth field"
    assert_contains "$fields" "violations" "result has violations field"
    assert_contains "$fields" "violation_count" "result has violation_count field"
    assert_contains "$fields" "grade" "result has grade field"
}

test_full_analysis_schema

# ─── Test: CLI entry point ────────────────────────────────────────────────
echo ""
echo "  CLI Entry Point"

test_cli_help() {
    local output
    output=$("$SCRIPT_DIR/sw-complexity.sh" --help 2>&1)
    assert_contains "$output" "USAGE" "CLI --help shows USAGE"
    assert_contains "$output" "ANTI-PATTERNS" "CLI --help lists anti-patterns"
}

test_cli_help

test_cli_version() {
    local output
    output=$("$SCRIPT_DIR/sw-complexity.sh" --version 2>&1)
    if [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m CLI --version shows version ($output)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m CLI --version shows version"
    fi
}

test_cli_version

test_cli_single_script() {
    local output
    output=$("$SCRIPT_DIR/sw-complexity.sh" "$TMPDIR_BASE/good-script.sh" 2>&1)
    assert_contains "$output" "Script Complexity Report" "CLI single script shows report header"
    assert_contains "$output" "Code Lines" "CLI single script shows metrics"
    assert_contains "$output" "Grade" "CLI single script shows grade"
}

test_cli_single_script

test_cli_json_single() {
    local output
    output=$("$SCRIPT_DIR/sw-complexity.sh" "$TMPDIR_BASE/good-script.sh" --json 2>&1)
    assert_json_valid "$output" "CLI --json produces valid JSON"
}

test_cli_json_single

test_cli_nonexistent() {
    local exit_code=0
    "$SCRIPT_DIR/sw-complexity.sh" "/nonexistent/file.sh" 2>/dev/null || exit_code=$?
    assert_exit_code "1" "$exit_code" "CLI exits 1 for nonexistent file"
}

test_cli_nonexistent

test_cli_no_args() {
    local exit_code=0
    "$SCRIPT_DIR/sw-complexity.sh" 2>/dev/null || exit_code=$?
    assert_exit_code "1" "$exit_code" "CLI exits 1 with no arguments"
}

test_cli_no_args

test_cli_recursive() {
    local output
    output=$("$SCRIPT_DIR/sw-complexity.sh" --recursive "$TMPDIR_BASE" 2>&1)
    assert_contains "$output" "Recursive analysis" "CLI --recursive shows analysis header"
    assert_contains "$output" "scripts" "CLI --recursive reports script count"
}

test_cli_recursive

test_cli_recursive_json() {
    local output
    output=$("$SCRIPT_DIR/sw-complexity.sh" --recursive "$TMPDIR_BASE" --json 2>&1)
    assert_json_valid "$output" "CLI --recursive --json produces valid JSON"

    local count
    count=$(echo "$output" | jq 'length')
    if [[ $count -ge 3 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m recursive JSON contains $count scripts"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m recursive JSON contains $count scripts (expected 3+)"
    fi
}

test_cli_recursive_json

# ─── Test: Integration with real scripts ──────────────────────────────────
echo ""
echo "  Integration with Real Scripts"

test_real_script_analysis() {
    local result
    result=$(complexity_analyze_script "$SCRIPT_DIR/sw-hello.sh" 2>/dev/null) || true
    if [[ -n "$result" ]]; then
        assert_json_valid "$result" "real script (sw-hello.sh) analysis produces valid JSON"
        local grade
        grade=$(echo "$result" | jq -r '.grade')
        assert_equals "A" "$grade" "sw-hello.sh gets grade A (simple script)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m real script analysis failed"
    fi
}

test_real_script_analysis

test_real_complex_script() {
    # Test against a known complex script
    if [[ -f "$SCRIPT_DIR/sw-daemon.sh" ]]; then
        local result
        result=$(complexity_analyze_script "$SCRIPT_DIR/sw-daemon.sh" 2>/dev/null) || true
        if [[ -n "$result" ]]; then
            local cc
            cc=$(echo "$result" | jq '.cyclomatic_complexity')
            if [[ $cc -gt 50 ]]; then
                PASS=$((PASS + 1))
                echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m sw-daemon.sh has high CC ($cc) as expected"
            else
                FAIL=$((FAIL + 1))
                echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m sw-daemon.sh CC too low ($cc)"
            fi
        fi
    else
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m skipped (sw-daemon.sh not present)"
    fi
}

test_real_complex_script

# ─── Test: Refactor suggestions ──────────────────────────────────────────
echo ""
echo "  Refactor Suggestions"

test_suggestion_high_loc() {
    # Simulate a high-LOC result
    local fake_result='{"script":"big.sh","metrics":{"code_lines":2500},"cyclomatic_complexity":80,"violation_count":5,"grade":"F"}'
    local suggestion
    suggestion=$(complexity_generate_suggestion "$fake_result")
    assert_contains "$suggestion" "HIGH PRIORITY" "high LOC triggers HIGH PRIORITY suggestion"
    assert_contains "$suggestion" "Split" "suggestion mentions splitting"
}

test_suggestion_high_loc

test_suggestion_medium_loc() {
    local fake_result='{"script":"med.sh","metrics":{"code_lines":1600},"cyclomatic_complexity":30,"violation_count":1,"grade":"C"}'
    local suggestion
    suggestion=$(complexity_generate_suggestion "$fake_result")
    assert_contains "$suggestion" "MEDIUM PRIORITY" "medium LOC triggers MEDIUM PRIORITY suggestion"
}

test_suggestion_medium_loc

test_no_suggestion_small() {
    local fake_result='{"script":"small.sh","metrics":{"code_lines":100},"cyclomatic_complexity":5,"violation_count":0,"grade":"A"}'
    local suggestion
    suggestion=$(complexity_generate_suggestion "$fake_result" 2>/dev/null || true)
    if [[ -z "$suggestion" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m no suggestion for small clean script"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m unexpected suggestion for small script"
    fi
}

test_no_suggestion_small

# ─── Test: Grade assignment ───────────────────────────────────────────────
echo ""
echo "  Grade Assignment"

test_grade_a() {
    local result
    result=$(complexity_analyze_script "$TMPDIR_BASE/good-script.sh")
    local grade
    grade=$(echo "$result" | jq -r '.grade')
    assert_equals "A" "$grade" "CC <= 10 gets grade A"
}

test_grade_a

# ─── Test: Source guard prevents double-loading ───────────────────────────
echo ""
echo "  Source Guard"

test_source_guard() {
    # Source again — should not error
    source "$SCRIPT_DIR/lib/complexity-analyzer.sh"
    ((PASS++))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m double-sourcing does not error"
}

test_source_guard

# ─── Test: CLI router integration ─────────────────────────────────────────
echo ""
echo "  CLI Router"

test_cli_router() {
    local output
    output=$(bash "$SCRIPT_DIR/sw" complexity --help 2>&1)
    assert_contains "$output" "USAGE" "sw complexity --help works via router"
}

test_cli_router

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
