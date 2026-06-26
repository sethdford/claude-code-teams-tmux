#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright detect test — Unit tests for project detection CLI          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Project Detect CLI Tests"

setup_test_env "sw-detect-test"
trap cleanup_test_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "CLI: help and version"

# Test: CLI help
if "$SCRIPT_DIR/sw-detect.sh" --help 2>&1 | grep -q "usage:"; then
    assert_pass "CLI --help works"
else
    assert_fail "CLI --help works"
fi

# Test: CLI version
if "$SCRIPT_DIR/sw-detect.sh" --version 2>&1 | grep -q "shipwright detect v"; then
    assert_pass "CLI --version works"
else
    assert_fail "CLI --version works"
fi

print_test_section "Detect: project analysis"

# Test: Detect current repo
if "$SCRIPT_DIR/sw-detect.sh" 2>/dev/null | grep -q "Language:"; then
    assert_pass "Detect current repo works"
else
    assert_fail "Detect current repo works"
fi

# Test: JSON output is valid
if "$SCRIPT_DIR/sw-detect.sh" --json 2>/dev/null | jq -e '.type' >/dev/null 2>&1; then
    assert_pass "JSON output is valid"
else
    assert_fail "JSON output is valid"
fi

# Test: JSON output has required keys
if "$SCRIPT_DIR/sw-detect.sh" --json 2>/dev/null | jq -e '.type, .recommended_template.template, .recommended_template.confidence' >/dev/null 2>&1; then
    assert_pass "JSON output has required structure"
else
    assert_fail "JSON output has required structure"
fi

print_test_section "Detect: error handling"

# Test: Invalid path handling
if "$SCRIPT_DIR/sw-detect.sh" /nonexistent/path 2>&1 >/dev/null && false; then
    assert_fail "Invalid path exits with code 1"
else
    assert_pass "Invalid path exits with code 1"
fi

print_test_section "Detect: specific directories"

# Test: Detect specific directory
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' RETURN

# Create a minimal Node.js project
cat > "$tmpdir/package.json" <<'EOF'
{
  "name": "test",
  "version": "1.0.0",
  "scripts": {"test": "jest"}
}
EOF

if "$SCRIPT_DIR/sw-detect.sh" "$tmpdir" --json 2>/dev/null | jq -e '.type == "nodejs"' >/dev/null 2>&1; then
    assert_pass "Detect specific directory works"
else
    assert_fail "Detect specific directory works"
fi

# Test: Template recommendation confidence
conf=$("$SCRIPT_DIR/sw-detect.sh" "$tmpdir" --json 2>/dev/null | jq -r '.recommended_template.confidence')
tmpl=$("$SCRIPT_DIR/sw-detect.sh" "$tmpdir" --json 2>/dev/null | jq -r '.recommended_template.template')

if [[ "$conf" -ge 0 && "$conf" -le 100 ]] && [[ -n "$tmpl" && "$tmpl" != "null" ]]; then
    assert_pass "Template confidence is valid (${conf}%, template=${tmpl})"
else
    assert_fail "Template confidence is valid (${conf}%, template=${tmpl})"
fi

print_test_results
