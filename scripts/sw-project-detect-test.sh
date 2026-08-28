#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright project-detect test — Unit tests for project detection       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Project Detect Tests"

setup_test_env "sw-project-detect-test"
trap cleanup_test_env EXIT

source "$SCRIPT_DIR/lib/project-detect.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════

# Create a Node.js project structure
create_nodejs_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/package.json" <<'EOF'
{
  "name": "test-app",
  "version": "1.0.0",
  "description": "Test app",
  "main": "index.js",
  "scripts": {
    "test": "jest",
    "build": "next build",
    "dev": "next dev"
  },
  "dependencies": {
    "next": "^14.0.0",
    "react": "^18.0.0",
    "jest": "^29.0.0"
  }
}
EOF
}

# Create a Python project structure
create_python_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/pyproject.toml" <<'EOF'
[project]
name = "test-app"
version = "1.0.0"

[build-system]
requires = ["setuptools"]

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
    mkdir -p "$dir/tests"
    cat > "$dir/tests/test_example.py" <<'EOF'
def test_example():
    assert True
EOF
}

# Create a Go project structure
create_golang_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/go.mod" <<'EOF'
module github.com/example/app

go 1.21

require github.com/gin-gonic/gin v1.9.0
EOF
}

# Create a Rust project structure
create_rust_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/Cargo.toml" <<'EOF'
[package]
name = "test-app"
version = "0.1.0"
edition = "2021"

[dependencies]
actix-web = "4"
EOF
}

# Create a Ruby Rails project
create_ruby_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/Gemfile" <<'EOF'
source 'https://rubygems.org'

gem 'rails', '~> 7.0'
gem 'rspec-rails'
EOF
}

# Create a Java/Maven project
create_java_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/pom.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project>
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.example</groupId>
    <artifactId>test-app</artifactId>
    <version>1.0.0</version>
    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
    </dependencies>
</project>
EOF
}

# Create a small bash project
create_bash_project() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/test.sh" <<'EOF'
#!/bin/bash
echo "Hello"
EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_detect_type with Node.js
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_detect_type — Node.js"

test_proj="$TEST_TEMP_DIR/nodejs-project"
create_nodejs_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects nodejs type" "$result" ".type" "nodejs"
assert_json_key "Detects next framework" "$result" ".framework" "next"
assert_json_key "Detects npm build tool" "$result" ".build_tool" "npm"
assert_json_key "Detects jest test runner" "$result" ".test_runner" "jest"

# ─── Test: project_detect_type with Python ───────────────────────────────────
print_test_section "project_detect_type — Python"

test_proj="$TEST_TEMP_DIR/python-project"
create_python_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects python type" "$result" ".type" "python"
assert_json_key "Detects pip build tool" "$result" ".build_tool" "pip"
assert_json_key "Detects pytest runner" "$result" ".test_runner" "pytest"

# ─── Test: project_detect_type with Golang ────────────────────────────────────
print_test_section "project_detect_type — Golang"

test_proj="$TEST_TEMP_DIR/golang-project"
create_golang_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects golang type" "$result" ".type" "golang"
assert_json_key "Detects gin framework" "$result" ".framework" "gin"
assert_json_key "Detects go build tool" "$result" ".build_tool" "go"

# ─── Test: project_detect_type with Rust ──────────────────────────────────────
print_test_section "project_detect_type — Rust"

test_proj="$TEST_TEMP_DIR/rust-project"
create_rust_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects rust type" "$result" ".type" "rust"
assert_json_key "Detects actix-web framework" "$result" ".framework" "actix-web"
assert_json_key "Detects cargo build tool" "$result" ".build_tool" "cargo"

# ─── Test: project_detect_type with Ruby ──────────────────────────────────────
print_test_section "project_detect_type — Ruby"

test_proj="$TEST_TEMP_DIR/ruby-project"
create_ruby_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects ruby type" "$result" ".type" "ruby"
assert_json_key "Detects bundler build tool" "$result" ".build_tool" "bundler"

# ─── Test: project_detect_type with Java ──────────────────────────────────────
print_test_section "project_detect_type — Java"

test_proj="$TEST_TEMP_DIR/java-project"
create_java_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects java type" "$result" ".type" "java"
assert_json_key "Detects maven build tool" "$result" ".build_tool" "maven"

# ─── Test: project_detect_type with Bash ──────────────────────────────────────
print_test_section "project_detect_type — Bash"

test_proj="$TEST_TEMP_DIR/bash-project"
create_bash_project "$test_proj"
result=$(project_detect_type "$test_proj") || true

assert_json_key "Detects bash type" "$result" ".type" "bash"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_detect_test_cmd
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_detect_test_cmd — Node.js"

test_proj="$TEST_TEMP_DIR/nodejs-tests"
create_nodejs_project "$test_proj"
result=$(project_detect_test_cmd "$test_proj" "nodejs")

assert_eq "Node.js test command" "npm test" "$result"

# ─── Test: project_detect_test_cmd with Python ────────────────────────────────
print_test_section "project_detect_test_cmd — Python"

test_proj="$TEST_TEMP_DIR/python-tests"
create_python_project "$test_proj"
result=$(project_detect_test_cmd "$test_proj" "python")

assert_eq "Python test command" "pytest" "$result"

# ─── Test: project_detect_test_cmd with Rust ──────────────────────────────────
print_test_section "project_detect_test_cmd — Rust"

test_proj="$TEST_TEMP_DIR/rust-tests"
create_rust_project "$test_proj"
result=$(project_detect_test_cmd "$test_proj" "rust")

assert_eq "Rust test command" "cargo test" "$result"

# ─── Test: project_detect_test_cmd with Go ────────────────────────────────────
print_test_section "project_detect_test_cmd — Golang"

test_proj="$TEST_TEMP_DIR/golang-tests"
create_golang_project "$test_proj"
result=$(project_detect_test_cmd "$test_proj" "golang")

assert_eq "Go test command" "go test ./..." "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_detect_build_cmd
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_detect_build_cmd — Node.js"

test_proj="$TEST_TEMP_DIR/nodejs-build"
create_nodejs_project "$test_proj"
result=$(project_detect_build_cmd "$test_proj" "nodejs")

assert_eq "Node.js build command" "npm run build" "$result"

# ─── Test: project_detect_build_cmd with Rust ─────────────────────────────────
print_test_section "project_detect_build_cmd — Rust"

test_proj="$TEST_TEMP_DIR/rust-build"
create_rust_project "$test_proj"
result=$(project_detect_build_cmd "$test_proj" "rust")

assert_eq "Rust build command" "cargo build" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_recommend_template
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_recommend_template — Small project"

test_proj="$TEST_TEMP_DIR/small-project"
create_nodejs_project "$test_proj"
result=$(project_recommend_template "$test_proj") || true

# Small project should get "fast" template
assert_json_key "Small project recommends fast" "$result" ".template" "fast"

# ─── Test: project_recommend_template with Docker ────────────────────────────
print_test_section "project_recommend_template — Deployment project"

test_proj="$TEST_TEMP_DIR/deploy-project"
mkdir -p "$test_proj"

# Create Dockerfile first (before detection)
cat > "$test_proj/Dockerfile" <<'EOF'
FROM node:18
WORKDIR /app
COPY . .
RUN npm install
CMD ["npm", "start"]
EOF

# Then create minimal project files
cat > "$test_proj/package.json" <<'EOF'
{"name": "test", "scripts": {"test": "jest"}}
EOF

result=$(project_recommend_template "$test_proj") || true

# Project with Dockerfile should get "deployed" template
assert_json_key "Deployment project recommends deployed" "$result" ".template" "deployed"

# ─── Test: project_recommend_template returns JSON with reason ──────────────────
print_test_section "project_recommend_template — JSON structure"

test_proj="$TEST_TEMP_DIR/struct-project"
create_nodejs_project "$test_proj"
result=$(project_recommend_template "$test_proj") || true

assert_contains "Has template field" "$result" '"template":'
assert_contains "Has confidence field" "$result" '"confidence":'
assert_contains "Has reason field" "$result" '"reason":'


# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_recommend_template — rule ladder
# Each recommendable template gets a test naming the RULE that produced it, so a
# reordering that lands on the right template for the wrong reason still fails.
# ═══════════════════════════════════════════════════════════════════════════════

source "$SCRIPT_DIR/lib/project-signals.sh"

# Build a signals object directly: the policy layer is being tested here, not
# the detectors (those have their own suite).
make_signals() {
    local monorepo="${1:-false}" workspaces="${2:-0}" ci="${3:-false}" workflows="${4:-0}"
    local maturity="${5:-none}" tests="${6:-0}" ratio="${7:-0}"
    local size="${8:-unknown}" files="${9:-0}" lines="${10:-0}" deploy="${11:-false}"
    jq -n \
        --argjson monorepo "$monorepo" --argjson workspaces "$workspaces" \
        --argjson ci "$ci" --argjson workflows "$workflows" \
        --arg maturity "$maturity" --argjson tests "$tests" --argjson ratio "$ratio" \
        --arg size "$size" --argjson files "$files" --argjson lines "$lines" \
        --argjson deploy "$deploy" \
        '{monorepo:{is_monorepo:$monorepo, workspace_count:$workspaces, type:"npm"},
          ci:{has_ci:$ci, workflow_count:$workflows, ci_types:[]},
          test:{maturity:$maturity, test_file_count:$tests, test_ratio:$ratio},
          size:{size_category:$size, file_count:$files, src_lines:$lines},
          activity:{is_active:true, days_since_last_commit:1},
          deploy:{has_deploy:$deploy, targets:(if $deploy then ["docker"] else [] end)}}'
}

print_test_section "project_recommend_template — rule: deploy_infrastructure"
result=$(project_recommend_template "$(make_signals true 4 true 6 mature 90 60 large 900 90000 true)")
assert_json_key "deploy infra outranks every other signal" "$result" ".template" "deployed"
assert_json_key "deploy rule id" "$result" ".rule" "deploy_infrastructure"
assert_contains "deploy rationale names the deploy config" "$result" "deployment config"

print_test_section "project_recommend_template — rule: monorepo_with_ci"
result=$(project_recommend_template "$(make_signals true 4 true 6 established 40 30 medium 300 4000 false)")
assert_json_key "monorepo with CI recommends full" "$result" ".template" "full"
assert_json_key "monorepo rule id" "$result" ".rule" "monorepo_with_ci"
assert_contains "monorepo rationale names the monorepo" "$result" "monorepo"

# A monorepo without CI must not reach the monorepo rule — one signal is not
# enough to justify the fullest pipeline.
result=$(project_recommend_template "$(make_signals true 4 false 0 established 40 30 medium 300 400 false)")
assert_json_key "monorepo without CI does not trigger full" "$result" ".rule" "default"

print_test_section "project_recommend_template — rule: large_codebase"
result=$(project_recommend_template "$(make_signals false 0 false 0 established 200 30 large 5000 90000 false)")
assert_json_key "large codebase recommends full" "$result" ".template" "full"
assert_json_key "large codebase rule id" "$result" ".rule" "large_codebase"
assert_contains "large rationale names the size" "$result" "large codebase"

print_test_section "project_recommend_template — rule: small_well_tested"
result=$(project_recommend_template "$(make_signals false 0 false 0 mature 60 80 small 120 3000 false)")
assert_json_key "small well-tested project recommends fast" "$result" ".template" "fast"
assert_json_key "small well-tested rule id" "$result" ".rule" "small_well_tested"
assert_contains "fast rationale names the tests" "$result" "tests"

print_test_section "project_recommend_template — rule: minimal_project"
result=$(project_recommend_template "$(make_signals false 0 false 0 none 0 0 tiny 8 200 false)")
assert_json_key "minimal project recommends fast" "$result" ".template" "fast"
assert_json_key "minimal project rule id" "$result" ".rule" "minimal_project"

print_test_section "project_recommend_template — rule: ci_present"
result=$(project_recommend_template "$(make_signals false 0 true 3 new 30 10 medium 300 4000 false)")
assert_json_key "CI without other signals recommends standard" "$result" ".template" "standard"
assert_json_key "ci_present rule id" "$result" ".rule" "ci_present"

print_test_section "project_recommend_template — rule: no_tests"
result=$(project_recommend_template "$(make_signals false 0 false 0 none 0 0 medium 300 4000 false)")
assert_json_key "untested project recommends standard" "$result" ".template" "standard"
assert_json_key "no_tests rule id" "$result" ".rule" "no_tests"

print_test_section "project_recommend_template — rule: low_test_ratio"
result=$(project_recommend_template "$(make_signals false 0 false 0 new 20 8 medium 300 4000 false)")
assert_json_key "thin test suite recommends standard" "$result" ".template" "standard"
assert_json_key "low_test_ratio rule id" "$result" ".rule" "low_test_ratio"

print_test_section "project_recommend_template — degraded signals"
result=$(project_recommend_template '{}')
assert_json_key "empty signals fall back to standard" "$result" ".template" "standard"
result=$(project_recommend_template 'not json at all')
assert_json_key "garbage input falls back to standard" "$result" ".template" "standard"
assert_json_key "garbage input is marked as a fallback" "$result" ".rule" "fallback"

# A shallow clone (the CI checkout default) must never be read as a tiny repo
# with a fast pipeline. size_category "unknown" keeps the fast rule from firing.
result=$(project_recommend_template "$(make_signals false 0 false 0 mature 200 80 unknown 400 20000 false)")
assert_json_key "unknown size does not yield the small_well_tested rule" "$result" ".template" "full"

print_test_section "project_recommend_template — output contract"
# The recommended template must be one the pipeline can actually resolve.
# Asserted as membership of templates/pipelines/, so adding a template file
# cannot silently break the contract.
templates_dir="$(cd "$SCRIPT_DIR/.." && pwd)/templates/pipelines"
for signals_case in \
    "$(make_signals false 0 false 0 none 0 0 tiny 8 200 true)" \
    "$(make_signals true 4 true 6 established 40 30 medium 300 4000 false)" \
    "$(make_signals false 0 false 0 mature 60 80 small 120 3000 false)" \
    "$(make_signals false 0 true 3 new 30 10 medium 300 4000 false)"; do
    tpl=$(project_recommend_template "$signals_case" | jq -r '.template')
    if [[ -f "$templates_dir/${tpl}.json" ]]; then
        assert_pass "recommended template '$tpl' exists in templates/pipelines/"
    else
        assert_fail "recommended template '$tpl' exists in templates/pipelines/" \
            "no such file: $templates_dir/${tpl}.json"
    fi
done

# Situational and governance templates are never recommended from repo shape.
for tpl_never in hotfix enterprise autonomous cost-aware tdd; do
    found=0
    for signals_case in \
        "$(make_signals false 0 false 0 none 0 0 tiny 8 200 true)" \
        "$(make_signals true 4 true 6 established 40 30 medium 300 4000 false)" \
        "$(make_signals false 0 false 0 mature 60 80 small 120 3000 false)" \
        "$(make_signals false 0 false 0 none 0 0 medium 300 4000 false)" \
        "$(make_signals false 0 true 3 new 30 10 large 900 90000 false)"; do
        [[ "$(project_recommend_template "$signals_case" | jq -r '.template')" == "$tpl_never" ]] && found=1
    done
    assert_eq "never recommends '$tpl_never' from repo shape" "0" "$found"
done

# Signals are echoed back so a recommendation can be debugged after the fact.
result=$(project_recommend_template "$(make_signals true 4 true 6 established 40 30 medium 300 4000 false)")
assert_json_key "signals echoed back for debugging" "$result" ".signals.monorepo.workspace_count" "4"
# ═══════════════════════════════════════════════════════════════════════════════
# Test: project_detect_all
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "project_detect_all — Full detection"

test_proj="$TEST_TEMP_DIR/full-detect"
create_nodejs_project "$test_proj"

result=$(project_detect_all "$test_proj") || true

assert_contains "Full detection includes type" "$result" '"type":'
assert_contains "Full detection includes framework" "$result" '"framework":'
assert_contains "Full detection includes build_tool" "$result" '"build_tool":'
assert_contains "Full detection includes test_runner" "$result" '"test_runner":'
assert_contains "Full detection includes test_cmd" "$result" '"test_cmd":'
assert_contains "Full detection includes recommended_template" "$result" '"recommended_template":'
assert_contains "Full detection includes cache timestamp" "$result" '"cached_at":'

# ─── Test: project_detect_all caching ──────────────────────────────────────────
print_test_section "project_detect_all — Cache behavior"

test_proj="$TEST_TEMP_DIR/cache-project"
create_nodejs_project "$test_proj"

# First call creates cache
result1=$(project_detect_all "$test_proj")

# Cache file should exist
if [[ -f "$test_proj/.claude/project-detection.json" ]]; then
    assert_pass "Cache file created at .claude/project-detection.json"
else
    assert_fail "Cache file created at .claude/project-detection.json"
fi

# Second call should use cache
result2=$(project_detect_all "$test_proj")

if [[ "$result1" == "$result2" ]]; then
    assert_pass "Cached detection returns same result"
else
    assert_fail "Cached detection returns same result"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Edge cases
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Edge cases"

# Project with yarn
test_proj="$TEST_TEMP_DIR/yarn-project"
mkdir -p "$test_proj"
cat > "$test_proj/package.json" <<'EOF'
{"name": "test", "scripts": {"test": "jest"}}
EOF
touch "$test_proj/yarn.lock"
result=$(project_detect_type "$test_proj") || true
assert_json_key "Detects yarn lock" "$result" ".build_tool" "yarn"

# Project with pnpm
test_proj="$TEST_TEMP_DIR/pnpm-project"
mkdir -p "$test_proj"
cat > "$test_proj/package.json" <<'EOF'
{"name": "test", "scripts": {"test": "jest"}}
EOF
touch "$test_proj/pnpm-lock.yaml"
result=$(project_detect_type "$test_proj") || true
assert_json_key "Detects pnpm lock" "$result" ".build_tool" "pnpm"

# Project with multiple frameworks detected (Express)
test_proj="$TEST_TEMP_DIR/express-project"
mkdir -p "$test_proj"
cat > "$test_proj/package.json" <<'EOF'
{"name": "test", "dependencies": {"express": "^4.0"}}
EOF
result=$(project_detect_type "$test_proj") || true
assert_json_key "Detects express framework" "$result" ".framework" "express"

# Project with both Python and Node (Node should win)
test_proj="$TEST_TEMP_DIR/mixed-project"
mkdir -p "$test_proj"
cat > "$test_proj/package.json" <<'EOF'
{"name": "test"}
EOF
cat > "$test_proj/requirements.txt" <<'EOF'
requests==2.0
EOF
result=$(project_detect_type "$test_proj") || true
assert_json_key "package.json takes precedence over requirements.txt" "$result" ".type" "nodejs"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Type detection without explicit type parameter
# ═══════════════════════════════════════════════════════════════════════════════

print_test_section "Auto-detection (type parameter omitted)"

test_proj="$TEST_TEMP_DIR/auto-detect-project"
create_python_project "$test_proj"

# Call without type parameter
result=$(project_detect_test_cmd "$test_proj")

assert_eq "Auto-detect Python test command" "pytest" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

print_test_results
