#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright setup-auto test — Unit tests for intelligent-defaults core     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Setup-Auto (Intelligent Defaults) Tests"

setup_test_env "sw-setup-auto-test"
trap cleanup_test_env EXIT

source "$SCRIPT_DIR/lib/setup-auto.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Fixtures
# ═══════════════════════════════════════════════════════════════════════════

# A tiny single-file project (low complexity).
create_tiny_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/package.json" <<'EOF'
{ "name": "tiny", "version": "1.0.0", "scripts": { "test": "vitest" } }
EOF
    echo "console.log('hi');" > "$dir/index.js"
}

# A larger project with tests, Docker, and CI (high complexity).
create_large_project() {
    local dir="$1"
    mkdir -p "$dir/src" "$dir/.github/workflows"
    cat > "$dir/package.json" <<'EOF'
{ "name": "big", "version": "1.0.0", "scripts": { "test": "jest" } }
EOF
    local i
    for i in $(seq 1 220); do
        # 200 src files saturate the file-count component; lines add depth.
        seq 1 120 | sed 's/^/const v = /' > "$dir/src/mod${i}.js"
    done
    for i in $(seq 1 40); do
        echo "test('x', () => {});" > "$dir/src/mod${i}.test.js"
    done
    echo "FROM node:20" > "$dir/Dockerfile"
    echo "name: ci" > "$dir/.github/workflows/ci.yml"
}

# A Python project for agent generation.
create_python_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/pyproject.toml" <<'EOF'
[project]
name = "py"
version = "1.0.0"
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "Complexity scoring"
# ═══════════════════════════════════════════════════════════════════════════

TINY="$TEST_TEMP_DIR/tiny"
create_tiny_project "$TINY"
TINY_CX=$(setup_auto_complexity_score "$TINY")

if echo "$TINY_CX" | jq -e 'has("score")' >/dev/null; then
    assert_pass "tiny project produces a score"
else
    assert_fail "tiny project produces a score"
fi
TINY_SCORE=$(echo "$TINY_CX" | jq -r '.score')
TINY_BAND=$(echo "$TINY_CX" | jq -r '.band')
assert_eq "tiny project is band=low" "low" "$TINY_BAND"
if [[ "$TINY_SCORE" -lt 30 ]]; then assert_pass "tiny score < 30 ($TINY_SCORE)"; else assert_fail "tiny score < 30 (got $TINY_SCORE)"; fi

LARGE="$TEST_TEMP_DIR/large"
create_large_project "$LARGE"
LARGE_CX=$(setup_auto_complexity_score "$LARGE")
LARGE_SCORE=$(echo "$LARGE_CX" | jq -r '.score')
LARGE_BAND=$(echo "$LARGE_CX" | jq -r '.band')
assert_eq "large project is band=high" "high" "$LARGE_BAND"
assert_gt "large score exceeds tiny score" "$LARGE_SCORE" "$TINY_SCORE"
assert_eq "large project detects deploy infra" "true" "$(echo "$LARGE_CX" | jq -r '.has_deploy')"
assert_eq "large project detects CI" "true" "$(echo "$LARGE_CX" | jq -r '.has_ci')"

if [[ "$LARGE_SCORE" -le 100 ]]; then assert_pass "score clamped <= 100 ($LARGE_SCORE)"; else assert_fail "score not clamped (got $LARGE_SCORE)"; fi

# Band boundaries.
assert_eq "band(0)=low" "low" "$(setup_auto_complexity_band 0)"
assert_eq "band(29)=low" "low" "$(setup_auto_complexity_band 29)"
assert_eq "band(30)=medium" "medium" "$(setup_auto_complexity_band 30)"
assert_eq "band(69)=medium" "medium" "$(setup_auto_complexity_band 69)"
assert_eq "band(70)=high" "high" "$(setup_auto_complexity_band 70)"
assert_eq "band(100)=high" "high" "$(setup_auto_complexity_band 100)"

# Missing directory fails cleanly.
if setup_auto_complexity_score "$TEST_TEMP_DIR/does-not-exist" >/dev/null 2>&1; then
    assert_fail "complexity score on missing dir should fail"
else
    assert_pass "complexity score on missing dir fails cleanly"
fi

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "Config generation"
# ═══════════════════════════════════════════════════════════════════════════

# Low-complexity project → fast template, low parallelism.
LOW_CFG=$(setup_auto_generate_config "$TINY")
assert_file_exists "config file written for tiny project" "$LOW_CFG"
assert_eq "low band → fast template" "fast" "$(jq -r '.pipeline_template' "$LOW_CFG")"
assert_eq "low band → max_parallel=1" "1" "$(jq -r '.max_parallel' "$LOW_CFG")"
assert_eq "config records complexity band" "low" "$(jq -r '.complexity.band' "$LOW_CFG")"
assert_json_key "config has loop section" "$(cat "$LOW_CFG")" ".loop | type" "object"
assert_json_key "config has effort_levels" "$(cat "$LOW_CFG")" ".effort_levels | type" "object"
assert_json_key "config has model_routing" "$(cat "$LOW_CFG")" ".model_routing | type" "object"

# High-complexity project → full template, high parallelism.
HIGH_CFG=$(setup_auto_generate_config "$LARGE")
assert_eq "high band → full template" "full" "$(jq -r '.pipeline_template' "$HIGH_CFG")"
assert_eq "high band → max_parallel=4" "4" "$(jq -r '.max_parallel' "$HIGH_CFG")"
assert_eq "high band → opus default model" "opus" "$(jq -r '.model_routing.default' "$HIGH_CFG")"
assert_eq "high band → review effort high" "high" "$(jq -r '.effort_levels.review' "$HIGH_CFG")"

# Explicit score override is honored.
MED="$TEST_TEMP_DIR/med"
create_tiny_project "$MED"
MED_CFG=$(setup_auto_generate_config "$MED" 50)
assert_eq "explicit score=50 → standard template" "standard" "$(jq -r '.pipeline_template' "$MED_CFG")"
assert_eq "explicit score recorded in config" "50" "$(jq -r '.complexity.score' "$MED_CFG")"

# Generated config is valid JSON.
if jq empty "$LOW_CFG" 2>/dev/null; then assert_pass "generated config is valid JSON"; else assert_fail "generated config invalid JSON"; fi

# ── Idempotency / merge: user settings must survive a re-run ──
IDEM="$TEST_TEMP_DIR/idem"
create_tiny_project "$IDEM"
mkdir -p "$IDEM/.claude"
cat > "$IDEM/.claude/daemon-config.json" <<'EOF'
{ "max_parallel": 7, "watch_label": "custom-label", "pipeline_template": "enterprise" }
EOF
IDEM_CFG=$(setup_auto_generate_config "$IDEM")
assert_eq "existing max_parallel preserved" "7" "$(jq -r '.max_parallel' "$IDEM_CFG")"
assert_eq "existing custom key preserved" "custom-label" "$(jq -r '.watch_label' "$IDEM_CFG")"
assert_eq "existing template preserved" "enterprise" "$(jq -r '.pipeline_template' "$IDEM_CFG")"
assert_json_key "new keys still added during merge" "$(cat "$IDEM_CFG")" ".loop | type" "object"

# Re-running twice produces identical output (stable).
RUN1=$(cat "$IDEM_CFG")
setup_auto_generate_config "$IDEM" >/dev/null
RUN2=$(cat "$IDEM_CFG")
assert_eq "config generation is stable across re-runs" "$RUN1" "$RUN2"

# ═══════════════════════════════════════════════════════════════════════════
print_test_section "Agent generation"
# ═══════════════════════════════════════════════════════════════════════════

# Node project → node-specialist.
setup_auto_generate_agents "$TINY" >/dev/null
assert_file_exists "node specialist generated" "$TINY/.claude/agents/node-specialist.md"
assert_contains "agent has frontmatter name" "$(cat "$TINY/.claude/agents/node-specialist.md")" "name: node-specialist"
assert_contains "node agent mentions TypeScript" "$(cat "$TINY/.claude/agents/node-specialist.md")" "TypeScript"

# Explicit type override → python specialist.
PY="$TEST_TEMP_DIR/py"
create_python_project "$PY"
setup_auto_generate_agents "$PY" "python" >/dev/null
assert_file_exists "python specialist generated" "$PY/.claude/agents/python-specialist.md"
assert_contains "python agent mentions PEP 8" "$(cat "$PY/.claude/agents/python-specialist.md")" "PEP 8"

# Go and Rust templates exist.
GO="$TEST_TEMP_DIR/go"; mkdir -p "$GO"
setup_auto_generate_agents "$GO" "golang" >/dev/null
assert_file_exists "go specialist generated" "$GO/.claude/agents/go-specialist.md"
RUST="$TEST_TEMP_DIR/rust"; mkdir -p "$RUST"
setup_auto_generate_agents "$RUST" "rust" >/dev/null
assert_file_exists "rust specialist generated" "$RUST/.claude/agents/rust-specialist.md"

# Unsupported type → no file, clean exit.
UNK="$TEST_TEMP_DIR/unk"; mkdir -p "$UNK"
setup_auto_generate_agents "$UNK" "cobol" >/dev/null
assert_file_not_exists "unsupported type generates no agent" "$UNK/.claude/agents/cobol-specialist.md"

# Idempotency: user edits to an agent are never overwritten.
echo "USER EDITED CONTENT" > "$TINY/.claude/agents/node-specialist.md"
setup_auto_generate_agents "$TINY" "nodejs" >/dev/null
assert_contains "existing agent not overwritten" "$(cat "$TINY/.claude/agents/node-specialist.md")" "USER EDITED CONTENT"

print_test_results
