#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-showcase-test.sh — Showcase Generator Test Suite                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWCASE="$SCRIPT_DIR/sw-showcase.sh"
PASS=0
FAIL=0

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { ((PASS++)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $1"; }
fail() { ((FAIL++)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $1"; }

assert_file() {
    local f="$1" desc="$2"
    [[ -f "$f" ]] && pass "$desc" || fail "$desc (missing: $f)"
}

# Test 1: --help works
test_help() {
    local out
    out=$("$SHOWCASE" --help 2>&1)
    [[ "$out" =~ USAGE ]] && pass "--help shows usage" || fail "--help shows usage"
}

# Test 2: --version works
test_version() {
    local out
    out=$("$SHOWCASE" --version)
    [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && pass "--version prints semver" || fail "--version prints semver"
}

# Test 3: missing --stack fails
test_missing_stack() {
    if "$SHOWCASE" --out "$TMP_ROOT/x" >/dev/null 2>&1; then
        fail "missing --stack should fail"
    else
        pass "missing --stack fails with non-zero exit"
    fi
}

# Test 4: invalid stack fails
test_invalid_stack() {
    if "$SHOWCASE" --stack ruby --out "$TMP_ROOT/ruby" >/dev/null 2>&1; then
        fail "invalid stack should fail"
    else
        pass "invalid stack fails"
    fi
}

# Test 5: node generation produces expected files
test_node() {
    local d="$TMP_ROOT/node-demo"
    "$SHOWCASE" --stack node --out "$d" >/dev/null 2>&1 || { fail "node generation"; return; }
    assert_file "$d/README.md" "node: README.md"
    assert_file "$d/package.json" "node: package.json"
    assert_file "$d/src/index.js" "node: src/index.js"
    assert_file "$d/test/index.test.js" "node: test/index.test.js"
    assert_file "$d/.claude/CLAUDE.md" "node: .claude/CLAUDE.md"
    assert_file "$d/.claude/daemon-config.json" "node: .claude/daemon-config.json"
    if jq -e . "$d/package.json" >/dev/null 2>&1; then
        pass "node: package.json is valid JSON"
    else
        fail "node: package.json is valid JSON"
    fi
    if jq -e . "$d/.claude/daemon-config.json" >/dev/null 2>&1; then
        pass "node: daemon-config.json is valid JSON"
    else
        fail "node: daemon-config.json is valid JSON"
    fi
}

# Test 6: python generation
test_python() {
    local d="$TMP_ROOT/py-demo"
    "$SHOWCASE" --stack python --out "$d" >/dev/null 2>&1 || { fail "python generation"; return; }
    assert_file "$d/pyproject.toml" "python: pyproject.toml"
    assert_file "$d/src/showcase/__init__.py" "python: src/showcase/__init__.py"
    assert_file "$d/tests/test_showcase.py" "python: tests/test_showcase.py"
}

# Test 7: go generation
test_go() {
    local d="$TMP_ROOT/go-demo"
    "$SHOWCASE" --stack go --out "$d" >/dev/null 2>&1 || { fail "go generation"; return; }
    assert_file "$d/go.mod" "go: go.mod"
    assert_file "$d/main.go" "go: main.go"
    assert_file "$d/main_test.go" "go: main_test.go"
}

# Test 8: refuses to overwrite without --force
test_no_overwrite() {
    local d="$TMP_ROOT/existing"
    mkdir -p "$d"
    echo "preexisting" > "$d/keep.txt"
    if "$SHOWCASE" --stack node --out "$d" >/dev/null 2>&1; then
        fail "should refuse overwrite without --force"
    else
        pass "refuses overwrite without --force"
    fi
    [[ -f "$d/keep.txt" ]] && pass "preexisting file preserved" || fail "preexisting file preserved"
}

# Test 9: --force allows overwrite
test_force_overwrite() {
    local d="$TMP_ROOT/forceit"
    mkdir -p "$d"
    echo "old" > "$d/old.txt"
    if "$SHOWCASE" --stack node --out "$d" --force >/dev/null 2>&1; then
        pass "--force allows overwrite"
    else
        fail "--force allows overwrite"
    fi
    assert_file "$d/package.json" "force: package.json written"
}

# Test 10: unknown option fails
test_unknown_option() {
    if "$SHOWCASE" --bogus >/dev/null 2>&1; then
        fail "unknown option should fail"
    else
        pass "unknown option fails"
    fi
}

echo "sw-showcase-test.sh"
test_help
test_version
test_missing_stack
test_invalid_stack
test_node
test_python
test_go
test_no_overwrite
test_force_overwrite
test_unknown_option

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
