#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  loop-test-summarizer test suite                                        ║
# ║  Tests error extraction, categorization, clustering, prioritization,    ║
# ║  and focused prompt generation across multiple test frameworks          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: loop-test-summarizer Tests"

setup_test_env "sw-loop-test-summarizer-test"
trap cleanup_test_env EXIT

# Source the library
source "$SCRIPT_DIR/lib/loop-test-summarizer.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Mock test outputs for different frameworks
# ═══════════════════════════════════════════════════════════════════════════════

VITEST_OUTPUT_SMALL='FAIL src/auth/login.test.ts > Login > should validate credentials
AssertionError: expected true to be false
  at Object.<anonymous> (src/auth/login.test.ts:45:3)

FAIL src/auth/login.test.ts > Login > should hash password
TypeError: hashPassword is not a function
  at Object.<anonymous> (src/auth/login.test.ts:62:10)

FAIL src/utils/format.test.ts > Format > should format dates
AssertionError: expected "2024-01-01" to equal "01/01/2024"
  at Object.<anonymous> (src/utils/format.test.ts:18:5)'

JEST_OUTPUT='FAIL src/api/users.test.js
  Error: Users API > GET /users > should return 200
    expect(received).toBe(expected)
    Expected: 200
    Received: 404
      at Object.<anonymous> (src/api/users.test.js:23:29)

  TypeError: Cannot read properties of undefined (reading "name")
      at createUser (src/api/users.js:15:22)
      at Object.<anonymous> (src/api/users.test.js:45:5)'

PYTEST_OUTPUT='FAILED tests/test_auth.py::test_login_valid - AssertionError: assert 401 == 200
FAILED tests/test_auth.py::test_login_invalid - AssertionError: assert 200 == 401
FAILED tests/test_db.py::test_connection - ConnectionRefusedError: [Errno 111] Connection refused
E   AssertionError: assert 401 == 200
E   assert response.status_code == 200'

GO_TEST_OUTPUT='--- FAIL: TestUserCreate (0.01s)
    user_test.go:45: expected "admin", got ""
--- FAIL: TestUserDelete (0.00s)
    user_test.go:89: permission denied: cannot delete user
--- FAIL: TestDBConnect (0.05s)
panic: runtime error: invalid memory address or nil pointer dereference
    goroutine 1 [running]:
    main.connectDB(0x0)
        db.go:23 +0x1a'

BASH_TEST_OUTPUT='FAIL: test_cleanup_removes_files - Expected 0 files, found 3
FAIL: test_cleanup_handles_missing_dir - Expected exit 0, got exit 1
FAIL: test_init_creates_config - File .claude/config.json not found'

SYNTAX_ERROR_OUTPUT='SyntaxError: Unexpected token } at src/parser.ts:45
    at Module._compile (node:internal/modules/cjs/loader:1241:14)
SyntaxError: Unexpected end of input at src/lexer.ts:102
    at Module._compile (node:internal/modules/cjs/loader:1241:14)'

DEPENDENCY_ERROR_OUTPUT='Error: Cannot find module "express"
    at Function.Module._resolveFilename (node:internal/modules/cjs/loader:1075:15)
Error: Cannot find module "lodash/fp"
    at Function.Module._resolveFilename (node:internal/modules/cjs/loader:1075:15)
Error: Cannot find module "express"
    at another place'

RUNTIME_ERROR_OUTPUT='panic: runtime error: index out of range [5] with length 3
    goroutine 1 [running]:
    main.process(0xc000014080)
        main.go:42 +0x1a
fatal error: out of memory
    runtime: memory limit reached'

# Build large mixed output
MIXED_LARGE_OUTPUT=""
for i in $(seq 1 25); do
    MIXED_LARGE_OUTPUT+="FAIL src/module${i}.test.ts > Test${i} > should work
AssertionError: expected ${i} to be 0
  at Object.<anonymous> (src/module${i}.test.ts:${i}:3)
"
done
for i in $(seq 1 15); do
    MIXED_LARGE_OUTPUT+="TypeError: fn${i} is not a function at src/helpers.ts:${i}
  at Object.<anonymous> (src/helpers.test.ts:${i}:5)
"
done
for i in $(seq 1 10); do
    MIXED_LARGE_OUTPUT+="SyntaxError: Unexpected token at src/parser${i}.ts:${i}
"
done

# ═══════════════════════════════════════════════════════════════════════════════
# Error Extraction Tests
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Error Extraction"

blocks=$(_lts_extract_error_blocks "$VITEST_OUTPUT_SMALL")
count=$(echo "$blocks" | grep -c "." || true)
if [[ $count -ge 3 ]]; then
    assert_pass "extract vitest errors (got $count)"
else
    assert_fail "extract vitest errors" "expected >=3, got $count"
fi

blocks=$(_lts_extract_error_blocks "$JEST_OUTPUT")
count=$(echo "$blocks" | grep -c "." || true)
if [[ $count -ge 2 ]]; then
    assert_pass "extract jest errors (got $count)"
else
    assert_fail "extract jest errors" "expected >=2, got $count"
fi

blocks=$(_lts_extract_error_blocks "$PYTEST_OUTPUT")
count=$(echo "$blocks" | grep -c "." || true)
if [[ $count -ge 2 ]]; then
    assert_pass "extract pytest errors (got $count)"
else
    assert_fail "extract pytest errors" "expected >=2, got $count"
fi

blocks=$(_lts_extract_error_blocks "$GO_TEST_OUTPUT")
count=$(echo "$blocks" | grep -c "." || true)
if [[ $count -ge 2 ]]; then
    assert_pass "extract go test errors (got $count)"
else
    assert_fail "extract go test errors" "expected >=2, got $count"
fi

blocks=$(_lts_extract_error_blocks "$BASH_TEST_OUTPUT")
count=$(echo "$blocks" | grep -c "." || true)
if [[ $count -ge 2 ]]; then
    assert_pass "extract bash test errors (got $count)"
else
    assert_fail "extract bash test errors" "expected >=2, got $count"
fi

blocks=$(_lts_extract_error_blocks "")
if [[ -z "$blocks" ]]; then
    assert_pass "extract: empty input returns nothing"
else
    assert_fail "extract: empty input returns nothing" "got output"
fi

blocks=$(_lts_extract_error_blocks "PASS src/utils.test.ts
  Tests: 2 passed, 2 total")
if [[ -z "$blocks" ]]; then
    assert_pass "extract: clean output returns nothing"
else
    assert_fail "extract: clean output returns nothing" "got output"
fi

blocks=$(_lts_extract_error_blocks "$MIXED_LARGE_OUTPUT")
count=$(echo "$blocks" | grep -c "." || true)
if [[ $count -ge 30 ]]; then
    assert_pass "extract: large output (got $count blocks)"
else
    assert_fail "extract: large output" "expected >=30, got $count"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Categorization Tests
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Categorization"

cat_result=$(_lts_categorize_error "SyntaxError: Unexpected token } at parser.ts:45")
assert_eq "categorize: syntax error" "syntax" "$cat_result"

cat_result=$(_lts_categorize_error "TypeError: hashPassword is not a function")
assert_eq "categorize: type error" "type" "$cat_result"

cat_result=$(_lts_categorize_error "AssertionError: expected true to be false")
assert_eq "categorize: assertion failure" "assertion" "$cat_result"

cat_result=$(_lts_categorize_error "panic: runtime error: index out of range [5] with length 3")
assert_eq "categorize: runtime error (panic)" "runtime" "$cat_result"

cat_result=$(_lts_categorize_error "fatal error: out of memory allocator")
assert_eq "categorize: runtime error (OOM)" "runtime" "$cat_result"

cat_result=$(_lts_categorize_error 'Error: Cannot find module "express"')
assert_eq "categorize: dependency error" "dependency" "$cat_result"

cat_result=$(_lts_categorize_error "Error: connect ECONNREFUSED 127.0.0.1:5432")
assert_eq "categorize: integration error" "integration" "$cat_result"

cat_result=$(_lts_categorize_error "Something went wrong somewhere")
assert_eq "categorize: unknown error" "unknown" "$cat_result"

# ═══════════════════════════════════════════════════════════════════════════════
# Priority Scoring Tests
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Priority Scoring"

p=$(_lts_category_priority "syntax")
assert_eq "priority: syntax is 100" "100" "$p"

pr=$(_lts_category_priority "runtime")
pt=$(_lts_category_priority "type")
if [[ $pr -gt $pt ]]; then
    assert_pass "priority: runtime > type"
else
    assert_fail "priority: runtime > type" "runtime=$pr, type=$pt"
fi

pt=$(_lts_category_priority "type")
pd=$(_lts_category_priority "dependency")
if [[ $pt -gt $pd ]]; then
    assert_pass "priority: type > dependency"
else
    assert_fail "priority: type > dependency" "type=$pt, dep=$pd"
fi

pd=$(_lts_category_priority "dependency")
pa=$(_lts_category_priority "assertion")
if [[ $pd -gt $pa ]]; then
    assert_pass "priority: dependency > assertion"
else
    assert_fail "priority: dependency > assertion" "dep=$pd, assertion=$pa"
fi

pa=$(_lts_category_priority "assertion")
pi=$(_lts_category_priority "integration")
if [[ $pa -gt $pi ]]; then
    assert_pass "priority: assertion > integration"
else
    assert_fail "priority: assertion > integration" "assertion=$pa, integration=$pi"
fi

pu=$(_lts_category_priority "unknown")
assert_eq "priority: unknown is 20" "20" "$pu"

# ═══════════════════════════════════════════════════════════════════════════════
# File Extraction Tests
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "File Extraction"

f=$(_lts_extract_file "Error at src/auth/login.test.ts:45:3")
assert_eq "file: extract ts" "src/auth/login.test.ts" "$f"

f=$(_lts_extract_file 'File "tests/test_auth.py", line 23')
assert_eq "file: extract python" "tests/test_auth.py" "$f"

f=$(_lts_extract_file "    user_test.go:45: expected admin")
assert_eq "file: extract go" "user_test.go" "$f"

f=$(_lts_extract_file "Error at ./src/utils.ts:10")
assert_eq "file: strip leading ./" "src/utils.ts" "$f"

f=$(_lts_extract_file "Something went wrong")
assert_eq "file: empty on no file" "" "$f"

# ═══════════════════════════════════════════════════════════════════════════════
# Clustering Tests
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Clustering"

clusters=$(_lts_cluster_errors "")
assert_eq "cluster: empty input returns []" "[]" "$clusters"

blocks=$(_lts_extract_error_blocks "$VITEST_OUTPUT_SMALL")
clusters=$(_lts_cluster_errors "$blocks")
cluster_count=$(echo "$clusters" | jq "length" 2>/dev/null || echo "0")
if [[ $cluster_count -ge 1 ]] && [[ $cluster_count -le 6 ]]; then
    assert_pass "cluster: vitest groups (got $cluster_count clusters from 6 blocks)"
else
    assert_fail "cluster: vitest groups" "expected 1-6 clusters, got $cluster_count"
fi

blocks=$(_lts_extract_error_blocks "$DEPENDENCY_ERROR_OUTPUT")
clusters=$(_lts_cluster_errors "$blocks")
dep_clusters=$(echo "$clusters" | jq '[.[] | select(.category=="dependency")] | length' 2>/dev/null || echo "0")
if [[ $dep_clusters -ge 1 ]]; then
    assert_pass "cluster: dependency errors cluster together ($dep_clusters clusters)"
else
    assert_fail "cluster: dependency errors cluster together" "got $dep_clusters"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Prioritization (Sorting) Tests
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Prioritization"

mixed_input="SyntaxError: Unexpected token at parser.ts:1
AssertionError: expected true to be false at test.ts:5
TypeError: x is not a function at util.ts:10"
blocks=$(_lts_extract_error_blocks "$mixed_input")
clusters=$(_lts_cluster_errors "$blocks")
sorted=$(_lts_prioritize_clusters "$clusters")
first_cat=$(echo "$sorted" | jq -r '.[0].category' 2>/dev/null || echo "unknown")
assert_eq "prioritize: syntax first" "syntax" "$first_cat"

sorted=$(_lts_prioritize_clusters "[]")
assert_eq "prioritize: empty returns []" "[]" "$sorted"

# ═══════════════════════════════════════════════════════════════════════════════
# Focused Prompt Generation Tests
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Focused Prompt Generation"

blocks=$(_lts_extract_error_blocks "$VITEST_OUTPUT_SMALL")
clusters=$(_lts_cluster_errors "$blocks")
sorted=$(_lts_prioritize_clusters "$clusters")
prompt=$(_lts_generate_focused_prompt "$sorted" 3)
assert_contains "prompt: has header" "$prompt" "Intelligent Error Summary"
assert_contains "prompt: has fix order" "$prompt" "Fix in this order"

blocks=$(_lts_extract_error_blocks "$SYNTAX_ERROR_OUTPUT")
clusters=$(_lts_cluster_errors "$blocks")
sorted=$(_lts_prioritize_clusters "$clusters")
prompt=$(_lts_generate_focused_prompt "$sorted" 2)
assert_contains "prompt: has SYNTAX ERROR label" "$prompt" "SYNTAX ERROR"

blocks=$(_lts_extract_error_blocks "$DEPENDENCY_ERROR_OUTPUT")
clusters=$(_lts_cluster_errors "$blocks")
sorted=$(_lts_prioritize_clusters "$clusters")
prompt=$(_lts_generate_focused_prompt "$sorted" 3)
assert_contains "prompt: has MISSING DEPENDENCY label" "$prompt" "MISSING DEPENDENCY"

# Test max cluster limit
blocks=$(_lts_extract_error_blocks "$MIXED_LARGE_OUTPUT")
clusters=$(_lts_cluster_errors "$blocks")
sorted=$(_lts_prioritize_clusters "$clusters")
prompt=$(_lts_generate_focused_prompt "$sorted" 50 3)
header_count=$(echo "$prompt" | grep -c "^### " || true)
if [[ $header_count -le 3 ]]; then
    assert_pass "prompt: limits to max clusters ($header_count)"
else
    assert_fail "prompt: limits to max clusters" "expected <=3, got $header_count"
fi

cluster_count=$(echo "$clusters" | jq "length" 2>/dev/null || echo "0")
if [[ $cluster_count -gt 3 ]]; then
    assert_contains "prompt: shows remainder count" "$prompt" "more error cluster"
fi

prompt=$(_lts_generate_focused_prompt "[]" 0)
if [[ -z "$prompt" ]]; then
    assert_pass "prompt: empty clusters produces no output"
else
    assert_fail "prompt: empty clusters produces no output" "got output"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Full Pipeline (summarize_test_output) Tests
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Full Pipeline (summarize_test_output)"

out_dir="$TEST_TEMP_DIR/full-vitest"
mkdir -p "$out_dir"
summarize_test_output "$VITEST_OUTPUT_SMALL" "$out_dir" 1 >/dev/null
if [[ -f "$out_dir/test-summary.json" ]]; then
    assert_pass "full: vitest output writes JSON"
else
    assert_fail "full: vitest output writes JSON"
fi

out_dir="$TEST_TEMP_DIR/full-fields"
mkdir -p "$out_dir"
summarize_test_output "$VITEST_OUTPUT_SMALL" "$out_dir" 5 >/dev/null
json=$(cat "$out_dir/test-summary.json")
if echo "$json" | jq -e '.iteration and .timestamp and .total_errors and .cluster_count and .clusters and .focused_prompt' >/dev/null 2>&1; then
    assert_pass "full: JSON has all required fields"
else
    assert_fail "full: JSON has all required fields"
fi

out_dir="$TEST_TEMP_DIR/full-iter"
mkdir -p "$out_dir"
summarize_test_output "$VITEST_OUTPUT_SMALL" "$out_dir" 7 >/dev/null
iter=$(jq ".iteration" "$out_dir/test-summary.json")
assert_eq "full: iteration number preserved" "7" "$iter"

out_dir="$TEST_TEMP_DIR/full-empty"
mkdir -p "$out_dir"
echo "{}" > "$out_dir/test-summary.json"
summarize_test_output "" "$out_dir" 1 >/dev/null
if [[ ! -f "$out_dir/test-summary.json" ]]; then
    assert_pass "full: empty input cleans up"
else
    assert_fail "full: empty input cleans up"
fi

out_dir="$TEST_TEMP_DIR/full-clean"
mkdir -p "$out_dir"
echo "{}" > "$out_dir/test-summary.json"
summarize_test_output "PASS all tests passed" "$out_dir" 1 >/dev/null
if [[ ! -f "$out_dir/test-summary.json" ]]; then
    assert_pass "full: clean output cleans up"
else
    assert_fail "full: clean output cleans up"
fi

out_dir="$TEST_TEMP_DIR/full-go"
mkdir -p "$out_dir"
summarize_test_output "$GO_TEST_OUTPUT" "$out_dir" 1 >/dev/null
if [[ -f "$out_dir/test-summary.json" ]]; then
    go_count=$(jq ".total_errors" "$out_dir/test-summary.json")
    if [[ $go_count -ge 2 ]]; then
        assert_pass "full: go test output ($go_count errors)"
    else
        assert_fail "full: go test output" "expected >=2, got $go_count"
    fi
else
    assert_fail "full: go test output" "no JSON written"
fi

out_dir="$TEST_TEMP_DIR/full-pytest"
mkdir -p "$out_dir"
summarize_test_output "$PYTEST_OUTPUT" "$out_dir" 1 >/dev/null
if [[ -f "$out_dir/test-summary.json" ]]; then
    py_count=$(jq ".total_errors" "$out_dir/test-summary.json")
    if [[ $py_count -ge 2 ]]; then
        assert_pass "full: pytest output ($py_count errors)"
    else
        assert_fail "full: pytest output" "expected >=2, got $py_count"
    fi
else
    assert_fail "full: pytest output" "no JSON written"
fi

out_dir="$TEST_TEMP_DIR/full-bash"
mkdir -p "$out_dir"
summarize_test_output "$BASH_TEST_OUTPUT" "$out_dir" 1 >/dev/null
if [[ -f "$out_dir/test-summary.json" ]]; then
    assert_pass "full: bash test output"
else
    assert_fail "full: bash test output"
fi

out_dir="$TEST_TEMP_DIR/full-large"
mkdir -p "$out_dir"
summarize_test_output "$MIXED_LARGE_OUTPUT" "$out_dir" 1 >/dev/null
if [[ -f "$out_dir/test-summary.json" ]]; then
    total=$(jq ".total_errors" "$out_dir/test-summary.json")
    cc=$(jq ".cluster_count" "$out_dir/test-summary.json")
    if [[ $total -ge 30 ]] && [[ $cc -lt $total ]]; then
        assert_pass "full: 50+ errors clustered ($total errors -> $cc clusters)"
    else
        assert_fail "full: 50+ errors clustered" "total=$total, clusters=$cc"
    fi
else
    assert_fail "full: 50+ errors" "no JSON written"
fi

out_dir="$TEST_TEMP_DIR/full-large-pri"
mkdir -p "$out_dir"
summarize_test_output "$MIXED_LARGE_OUTPUT" "$out_dir" 1 >/dev/null
first_cat=$(jq -r '.clusters[0].category' "$out_dir/test-summary.json")
assert_eq "full: syntax errors prioritized first" "syntax" "$first_cat"

out_dir="$TEST_TEMP_DIR/full-stdout"
mkdir -p "$out_dir"
output=$(summarize_test_output "$VITEST_OUTPUT_SMALL" "$out_dir" 1)
assert_contains "full: stdout has focused prompt" "$output" "Intelligent Error Summary"

out_dir="$TEST_TEMP_DIR/full-atomic"
mkdir -p "$out_dir"
summarize_test_output "$VITEST_OUTPUT_SMALL" "$out_dir" 1 >/dev/null
if jq "." "$out_dir/test-summary.json" >/dev/null 2>&1; then
    tmp_count=$(find "$out_dir" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d " ")
    assert_eq "full: atomic write (no tmp files)" "0" "$tmp_count"
else
    assert_fail "full: atomic write" "invalid JSON"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Edge Cases
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Edge Cases"

out_dir="$TEST_TEMP_DIR/edge-single"
mkdir -p "$out_dir"
summarize_test_output "TypeError: x is not a function at src/util.ts:10" "$out_dir" 1 >/dev/null
if [[ -f "$out_dir/test-summary.json" ]]; then
    total=$(jq ".total_errors" "$out_dir/test-summary.json")
    assert_eq "edge: single error" "1" "$total"
else
    assert_fail "edge: single error" "no JSON written"
fi

# Repeated identical errors should cluster
repeated=""
for i in $(seq 1 10); do
    repeated+='Error: Cannot find module "express"
  at Function.Module._resolveFilename
'
done
blocks=$(_lts_extract_error_blocks "$repeated")
clusters=$(_lts_cluster_errors "$blocks")
cluster_count=$(echo "$clusters" | jq "length" 2>/dev/null || echo "0")
if [[ $cluster_count -le 2 ]]; then
    assert_pass "edge: 10 identical errors cluster ($cluster_count clusters)"
else
    assert_fail "edge: 10 identical errors cluster" "expected <=2, got $cluster_count"
fi

# Mixed frameworks
mixed="${VITEST_OUTPUT_SMALL}
${GO_TEST_OUTPUT}"
blocks=$(_lts_extract_error_blocks "$mixed")
count=$(echo "$blocks" | grep -c "." || true)
if [[ $count -ge 4 ]]; then
    assert_pass "edge: mixed frameworks ($count blocks)"
else
    assert_fail "edge: mixed frameworks" "expected >=4, got $count"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Stress Test: 100 errors
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Stress Test"

huge=""
for i in $(seq 1 40); do
    huge+="FAIL src/mod${i}.test.ts > should work
AssertionError: expected ${i} to be 0
  at Object.<anonymous> (src/mod${i}.test.ts:${i}:3)
"
done
for i in $(seq 1 30); do
    huge+="TypeError: fn${i} is not a function at src/lib${i}.ts:${i}
"
done
for i in $(seq 1 20); do
    huge+="SyntaxError: Unexpected token at src/parse${i}.ts:${i}
"
done
for i in $(seq 1 10); do
    huge+="Error: Cannot find module \"pkg-${i}\"
"
done
out_dir="$TEST_TEMP_DIR/stress-100"
mkdir -p "$out_dir"
summarize_test_output "$huge" "$out_dir" 1 >/dev/null
if [[ -f "$out_dir/test-summary.json" ]]; then
    total=$(jq ".total_errors" "$out_dir/test-summary.json")
    cc=$(jq ".cluster_count" "$out_dir/test-summary.json")
    if [[ $total -ge 50 ]] && [[ $cc -lt $total ]]; then
        assert_pass "stress: 100 errors -> $cc clusters (from $total)"
    else
        assert_fail "stress: 100 errors" "total=$total, clusters=$cc"
    fi
else
    assert_fail "stress: 100 errors" "no JSON written"
fi

# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
