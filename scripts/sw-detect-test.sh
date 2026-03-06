#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-detect-test.sh — Project Type Detection Test Suite                   ║
# ║                                                                          ║
# ║  Tests project type auto-detection across 8+ project archetypes.        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
TEST_TMPDIR=""

# ─── Test helpers ───────────────────────────────────────────────────────────
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

assert_contains() {
    local expected="$1" actual="$2" description="${3:-}"
    if echo "$actual" | grep -qF "$expected" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $expected"
        echo "    Actual: $actual"
    fi
}

assert_ge() {
    local threshold="$1" actual="$2" description="${3:-}"
    if [[ "$actual" -ge "$threshold" ]] 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected >= $threshold, got $actual"
    fi
}

assert_lt() {
    local threshold="$1" actual="$2" description="${3:-}"
    if [[ "$actual" -lt "$threshold" ]] 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected < $threshold, got $actual"
    fi
}

# ─── Setup / Teardown ──────────────────────────────────────────────────────
setup() {
    TEST_TMPDIR=$(mktemp -d)
}

teardown() {
    [[ -n "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR" 2>/dev/null || true
}

trap teardown EXIT

# Source the library
source "$SCRIPT_DIR/lib/project-type-detection.sh"

# ─── Mock project builders ─────────────────────────────────────────────────

create_node_web_project() {
    local dir="$1"
    mkdir -p "$dir/src" "$dir/routes" "$dir/public"
    cat > "$dir/package.json" <<'MOCK'
{
  "name": "my-web-app",
  "version": "1.0.0",
  "scripts": { "test": "vitest", "build": "tsc" },
  "dependencies": { "express": "^4.18.0", "cors": "^2.8.0" },
  "devDependencies": { "vitest": "^1.0.0", "typescript": "^5.0.0" }
}
MOCK
    echo "const express = require('express');" > "$dir/src/server.js"
}

create_node_cli_project() {
    local dir="$1"
    mkdir -p "$dir/src"
    cat > "$dir/package.json" <<'MOCK'
{
  "name": "my-cli-tool",
  "version": "1.0.0",
  "bin": { "mycli": "src/cli.js" },
  "scripts": { "test": "jest" },
  "dependencies": { "commander": "^11.0.0" },
  "devDependencies": { "jest": "^29.0.0" }
}
MOCK
    echo "#!/usr/bin/env node" > "$dir/src/cli.js"
}

create_node_library_project() {
    local dir="$1"
    mkdir -p "$dir/src" "$dir/lib"
    cat > "$dir/package.json" <<'MOCK'
{
  "name": "my-library",
  "version": "1.0.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "exports": { ".": "./dist/index.js" },
  "scripts": { "test": "vitest", "build": "tsc" },
  "devDependencies": { "vitest": "^1.0.0", "typescript": "^5.0.0" }
}
MOCK
    echo "export function hello() {}" > "$dir/src/lib.ts"
    cat > "$dir/README.md" <<'MOCK'
# My Library
## Installation
npm install my-library
## Usage
import { hello } from 'my-library'
MOCK
}

create_go_web_project() {
    local dir="$1"
    mkdir -p "$dir/routes"
    cat > "$dir/go.mod" <<'MOCK'
module example.com/web
go 1.21
require github.com/gin-gonic/gin v1.9.0
MOCK
    echo "package main" > "$dir/main.go"
}

create_go_cli_project() {
    local dir="$1"
    mkdir -p "$dir/cmd/root" "$dir/internal"
    cat > "$dir/go.mod" <<'MOCK'
module example.com/cli
go 1.21
require github.com/spf13/cobra v1.8.0
MOCK
    echo "package main" > "$dir/main.go"
}

create_python_web_project() {
    local dir="$1"
    mkdir -p "$dir/templates"
    cat > "$dir/requirements.txt" <<'MOCK'
django>=4.2
djangorestframework>=3.14
MOCK
    echo "# Django project" > "$dir/manage.py"
    echo "<html></html>" > "$dir/templates/index.html"
}

create_python_cli_project() {
    local dir="$1"
    mkdir -p "$dir/src"
    cat > "$dir/pyproject.toml" <<'MOCK'
[project]
name = "my-cli"
[project.scripts]
mycli = "src.cli:main"
[project.optional-dependencies]
dev = ["pytest"]
[tool.setuptools]
console_scripts = ["mycli=src.cli:main"]
MOCK
    cat > "$dir/requirements.txt" <<'MOCK'
click>=8.0
rich>=13.0
MOCK
    echo "import click" > "$dir/src/cli.py"
}

create_rust_library_project() {
    local dir="$1"
    mkdir -p "$dir/src"
    cat > "$dir/Cargo.toml" <<'MOCK'
[package]
name = "my-lib"
version = "0.1.0"
[lib]
name = "my_lib"
MOCK
    echo "pub fn hello() {}" > "$dir/src/lib.rs"
}

create_rust_web_project() {
    local dir="$1"
    mkdir -p "$dir/src"
    cat > "$dir/Cargo.toml" <<'MOCK'
[package]
name = "my-web"
version = "0.1.0"
[dependencies]
actix-web = "4"
MOCK
    echo "use actix_web::HttpServer;" > "$dir/src/main.rs"
}

create_java_web_project() {
    local dir="$1"
    mkdir -p "$dir/src/main/java"
    cat > "$dir/pom.xml" <<'MOCK'
<project>
  <groupId>com.example</groupId>
  <artifactId>my-app</artifactId>
  <packaging>war</packaging>
  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
  </dependencies>
</project>
MOCK
}

create_infrastructure_project() {
    local dir="$1"
    mkdir -p "$dir/terraform" "$dir/k8s" "$dir/.github/workflows"
    cat > "$dir/terraform/main.tf" <<'MOCK'
resource "aws_instance" "web" {
  ami           = "ami-12345"
  instance_type = "t2.micro"
}
MOCK
    echo "apiVersion: v1" > "$dir/k8s/deployment.yaml"
    echo "name: deploy" > "$dir/.github/workflows/deploy.yml"
    echo "deploy:" > "$dir/Makefile"
}

create_ruby_web_project() {
    local dir="$1"
    mkdir -p "$dir/app/controllers" "$dir/app/views" "$dir/public"
    cat > "$dir/Gemfile" <<'MOCK'
source 'https://rubygems.org'
gem 'rails', '~> 7.0'
gem 'rspec-rails'
MOCK
}

create_empty_project() {
    local dir="$1"
    mkdir -p "$dir"
}

create_minimal_project() {
    local dir="$1"
    mkdir -p "$dir"
    echo "# My Project" > "$dir/README.md"
}

# ═══════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════

echo "sw-detect-test.sh"
echo ""

# ─── Test Group: Node.js Projects ──────────────────────────────────────────
echo "  Node.js Projects"

test_node_web() {
    setup
    local dir="$TEST_TMPDIR/node-web"
    create_node_web_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "web" "$(echo "$result" | jq -r '.project_type')" "Node.js Express app detected as web"
    assert_equals "node" "$(echo "$result" | jq -r '.language')" "Language detected as node"
    assert_equals "express" "$(echo "$result" | jq -r '.framework')" "Framework detected as express"
    assert_ge 40 "$(echo "$result" | jq -r '.confidence')" "Confidence >= 40 for Node web app"
    assert_equals "npm" "$(echo "$result" | jq -r '.package_manager')" "Package manager is npm"
    assert_equals "vitest" "$(echo "$result" | jq -r '.test_framework')" "Test framework is vitest"
    teardown
}

test_node_cli() {
    setup
    local dir="$TEST_TMPDIR/node-cli"
    create_node_cli_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "cli" "$(echo "$result" | jq -r '.project_type')" "Node.js CLI tool detected as cli"
    assert_equals "node" "$(echo "$result" | jq -r '.language')" "CLI language detected as node"
    assert_ge 40 "$(echo "$result" | jq -r '.confidence')" "Confidence >= 40 for Node CLI"
    teardown
}

test_node_library() {
    setup
    local dir="$TEST_TMPDIR/node-lib"
    create_node_library_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "library" "$(echo "$result" | jq -r '.project_type')" "Node.js library detected as library"
    assert_equals "node" "$(echo "$result" | jq -r '.language')" "Library language detected as node"
    assert_ge 40 "$(echo "$result" | jq -r '.confidence')" "Confidence >= 40 for Node library"
    teardown
}

test_node_web
test_node_cli
test_node_library

# ─── Test Group: Go Projects ──────────────────────────────────────────────
echo ""
echo "  Go Projects"

test_go_web() {
    setup
    local dir="$TEST_TMPDIR/go-web"
    create_go_web_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "web" "$(echo "$result" | jq -r '.project_type')" "Go web app detected as web"
    assert_equals "go" "$(echo "$result" | jq -r '.language')" "Language detected as go"
    assert_equals "gin" "$(echo "$result" | jq -r '.framework')" "Framework detected as gin"
    teardown
}

test_go_cli() {
    setup
    local dir="$TEST_TMPDIR/go-cli"
    create_go_cli_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "cli" "$(echo "$result" | jq -r '.project_type')" "Go CLI tool detected as cli"
    assert_equals "go" "$(echo "$result" | jq -r '.language')" "CLI language detected as go"
    assert_ge 40 "$(echo "$result" | jq -r '.confidence')" "Confidence >= 40 for Go CLI"
    teardown
}

test_go_web
test_go_cli

# ─── Test Group: Python Projects ──────────────────────────────────────────
echo ""
echo "  Python Projects"

test_python_web() {
    setup
    local dir="$TEST_TMPDIR/python-web"
    create_python_web_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "web" "$(echo "$result" | jq -r '.project_type')" "Python Django app detected as web"
    assert_equals "python" "$(echo "$result" | jq -r '.language')" "Language detected as python"
    assert_equals "django" "$(echo "$result" | jq -r '.framework')" "Framework detected as django"
    teardown
}

test_python_cli() {
    setup
    local dir="$TEST_TMPDIR/python-cli"
    create_python_cli_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "cli" "$(echo "$result" | jq -r '.project_type')" "Python CLI tool detected as cli"
    assert_equals "python" "$(echo "$result" | jq -r '.language')" "CLI language detected as python"
    teardown
}

test_python_web
test_python_cli

# ─── Test Group: Rust Projects ────────────────────────────────────────────
echo ""
echo "  Rust Projects"

test_rust_library() {
    setup
    local dir="$TEST_TMPDIR/rust-lib"
    create_rust_library_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "library" "$(echo "$result" | jq -r '.project_type')" "Rust library detected as library"
    assert_equals "rust" "$(echo "$result" | jq -r '.language')" "Language detected as rust"
    assert_ge 25 "$(echo "$result" | jq -r '.confidence')" "Confidence >= 25 for Rust library"
    teardown
}

test_rust_web() {
    setup
    local dir="$TEST_TMPDIR/rust-web"
    create_rust_web_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "web" "$(echo "$result" | jq -r '.project_type')" "Rust actix-web detected as web"
    assert_equals "actix-web" "$(echo "$result" | jq -r '.framework')" "Framework detected as actix-web"
    teardown
}

test_rust_library
test_rust_web

# ─── Test Group: Java Projects ────────────────────────────────────────────
echo ""
echo "  Java Projects"

test_java_web() {
    setup
    local dir="$TEST_TMPDIR/java-web"
    create_java_web_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "web" "$(echo "$result" | jq -r '.project_type')" "Java Spring Boot app detected as web"
    assert_equals "java" "$(echo "$result" | jq -r '.language')" "Language detected as java"
    assert_equals "spring-boot" "$(echo "$result" | jq -r '.framework')" "Framework detected as spring-boot"
    teardown
}

test_java_web

# ─── Test Group: Ruby Projects ────────────────────────────────────────────
echo ""
echo "  Ruby Projects"

test_ruby_web() {
    setup
    local dir="$TEST_TMPDIR/ruby-web"
    create_ruby_web_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "web" "$(echo "$result" | jq -r '.project_type')" "Ruby Rails app detected as web"
    assert_equals "ruby" "$(echo "$result" | jq -r '.language')" "Language detected as ruby"
    assert_equals "rails" "$(echo "$result" | jq -r '.framework')" "Framework detected as rails"
    teardown
}

test_ruby_web

# ─── Test Group: Infrastructure ──────────────────────────────────────────
echo ""
echo "  Infrastructure Projects"

test_infrastructure() {
    setup
    local dir="$TEST_TMPDIR/infra"
    create_infrastructure_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "infrastructure" "$(echo "$result" | jq -r '.project_type')" "Infrastructure project detected correctly"
    assert_ge 45 "$(echo "$result" | jq -r '.confidence')" "Confidence >= 45 for infrastructure project"
    teardown
}

test_infrastructure

# ─── Test Group: Edge Cases ──────────────────────────────────────────────
echo ""
echo "  Edge Cases"

test_empty_directory() {
    setup
    local dir="$TEST_TMPDIR/empty"
    create_empty_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "unknown" "$(echo "$result" | jq -r '.project_type')" "Empty directory detected as unknown"
    assert_equals "0" "$(echo "$result" | jq -r '.confidence')" "Empty directory has 0 confidence"
    assert_equals "unknown" "$(echo "$result" | jq -r '.language')" "Empty directory language is unknown"
    teardown
}

test_minimal_project() {
    setup
    local dir="$TEST_TMPDIR/minimal"
    create_minimal_project "$dir"
    local result
    result=$(detect_project_type "$dir")
    assert_equals "unknown" "$(echo "$result" | jq -r '.project_type')" "Minimal project detected as unknown"
    assert_lt 40 "$(echo "$result" | jq -r '.confidence')" "Minimal project has low confidence"
    teardown
}

test_ambiguous_project() {
    setup
    local dir="$TEST_TMPDIR/ambiguous"
    mkdir -p "$dir/src" "$dir/routes" "$dir/public"
    cat > "$dir/package.json" <<'MOCK'
{
  "name": "ambiguous",
  "bin": { "mycli": "src/cli.js" },
  "dependencies": { "express": "^4.18.0", "commander": "^11.0.0" }
}
MOCK
    local result
    result=$(detect_project_type "$dir")
    # Should detect both web and CLI signals; web should win (stronger signals with routes/ + public/ dirs)
    local ptype
    ptype=$(echo "$result" | jq -r '.project_type')
    local sec_count
    sec_count=$(echo "$result" | jq '.secondary_types | length')
    if [[ "$ptype" == "web" ]] || [[ "$ptype" == "cli" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m Ambiguous project detected as web or cli (got: $ptype)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Ambiguous project detected as web or cli (got: $ptype)"
    fi
    assert_ge 1 "$sec_count" "Ambiguous project has secondary types"
    teardown
}

test_empty_directory
test_minimal_project
test_ambiguous_project

# ─── Test Group: Template Recommendation ─────────────────────────────────
echo ""
echo "  Template Recommendation"

test_web_template() {
    setup
    local dir="$TEST_TMPDIR/web-tpl"
    create_node_web_project "$dir"
    local detection
    detection=$(detect_project_type "$dir")
    local rec
    rec=$(recommend_template "$detection")
    assert_equals "standard" "$(echo "$rec" | jq -r '.template')" "Web app gets standard template"
    assert_contains "web" "$(echo "$rec" | jq -r '.rationale')" "Rationale mentions web"
    teardown
}

test_cli_template() {
    setup
    local dir="$TEST_TMPDIR/cli-tpl"
    create_node_cli_project "$dir"
    local detection
    detection=$(detect_project_type "$dir")
    local rec
    rec=$(recommend_template "$detection")
    assert_equals "fast" "$(echo "$rec" | jq -r '.template')" "CLI tool gets fast template"
    teardown
}

test_infra_template() {
    setup
    local dir="$TEST_TMPDIR/infra-tpl"
    create_infrastructure_project "$dir"
    local detection
    detection=$(detect_project_type "$dir")
    local rec
    rec=$(recommend_template "$detection")
    assert_equals "full" "$(echo "$rec" | jq -r '.template')" "Infrastructure gets full template"
    teardown
}

test_library_template() {
    setup
    local dir="$TEST_TMPDIR/lib-tpl"
    create_node_library_project "$dir"
    local detection
    detection=$(detect_project_type "$dir")
    local rec
    rec=$(recommend_template "$detection")
    assert_equals "standard" "$(echo "$rec" | jq -r '.template')" "Library gets standard template"
    teardown
}

test_unknown_template() {
    setup
    local dir="$TEST_TMPDIR/unknown-tpl"
    create_empty_project "$dir"
    local detection
    detection=$(detect_project_type "$dir")
    local rec
    rec=$(recommend_template "$detection")
    assert_equals "standard" "$(echo "$rec" | jq -r '.template')" "Unknown gets standard template (safe default)"
    teardown
}

test_web_template
test_cli_template
test_infra_template
test_library_template
test_unknown_template

# ─── Test Group: Config Generation ────────────────────────────────────────
echo ""
echo "  Config Generation"

test_generate_config() {
    setup
    local dir="$TEST_TMPDIR/gen-config"
    create_node_web_project "$dir"
    local detection
    detection=$(detect_project_type "$dir")
    generate_project_config "$dir" "$detection" > /dev/null

    if [[ -f "$dir/.claude/project-detection.json" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m project-detection.json created"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m project-detection.json created"
    fi

    local saved_type
    saved_type=$(jq -r '.project_type' "$dir/.claude/project-detection.json" 2>/dev/null) || saved_type=""
    assert_equals "web" "$saved_type" "Saved detection has correct project type"
    teardown
}

test_generate_idempotent() {
    setup
    local dir="$TEST_TMPDIR/gen-idem"
    create_go_cli_project "$dir"
    local det1 det2
    det1=$(detect_project_type "$dir")
    det2=$(detect_project_type "$dir")
    assert_equals "$det1" "$det2" "Detection is idempotent"
    teardown
}

test_generate_config
test_generate_idempotent

# ─── Test Group: CLI Command ─────────────────────────────────────────────
echo ""
echo "  CLI Command"

test_cli_help() {
    local output
    output=$("$SCRIPT_DIR/sw-detect.sh" --help 2>&1)
    if [[ "$output" =~ "USAGE" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m detect --help shows usage"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m detect --help shows usage"
    fi
}

test_cli_version() {
    local output
    output=$("$SCRIPT_DIR/sw-detect.sh" --version 2>&1)
    if [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m detect --version shows version"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m detect --version shows version"
    fi
}

test_cli_json_output() {
    setup
    local dir="$TEST_TMPDIR/cli-json"
    create_node_web_project "$dir"
    local output
    output=$("$SCRIPT_DIR/sw-detect.sh" --json "$dir" 2>&1)
    local dtype
    dtype=$(echo "$output" | jq -r '.detection.project_type' 2>/dev/null) || dtype=""
    assert_equals "web" "$dtype" "CLI --json outputs valid detection JSON"
    local tpl
    tpl=$(echo "$output" | jq -r '.recommendation.template' 2>/dev/null) || tpl=""
    assert_equals "standard" "$tpl" "CLI --json includes recommendation"
    teardown
}

test_cli_generate() {
    setup
    local dir="$TEST_TMPDIR/cli-gen"
    create_go_web_project "$dir"
    "$SCRIPT_DIR/sw-detect.sh" --generate "$dir" > /dev/null 2>&1
    if [[ -f "$dir/.claude/project-detection.json" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m CLI --generate creates config file"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m CLI --generate creates config file"
    fi
    teardown
}

test_cli_invalid_dir() {
    "$SCRIPT_DIR/sw-detect.sh" "/nonexistent/path" > /dev/null 2>&1 || local exit_code=$?
    assert_equals "1" "${exit_code:-0}" "CLI exits 1 for invalid directory"
}

test_cli_help
test_cli_version
test_cli_json_output
test_cli_generate
test_cli_invalid_dir

# ─── Test Group: Scoring Functions ───────────────────────────────────────
echo ""
echo "  Scoring Functions"

test_web_scoring() {
    setup
    local dir="$TEST_TMPDIR/web-score"
    create_node_web_project "$dir"
    local score
    score=$(_score_web_signals "node" "$dir")
    assert_ge 25 "$score" "Node web project has web score >= 25"
    local cli_score
    cli_score=$(_score_cli_signals "node" "$dir")
    if [[ "$score" -gt "$cli_score" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m Web score > CLI score for web project"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Web score > CLI score for web project (web=$score, cli=$cli_score)"
    fi
    teardown
}

test_cli_scoring() {
    setup
    local dir="$TEST_TMPDIR/cli-score"
    create_node_cli_project "$dir"
    local score
    score=$(_score_cli_signals "node" "$dir")
    assert_ge 25 "$score" "Node CLI project has CLI score >= 25"
    teardown
}

test_infra_scoring() {
    setup
    local dir="$TEST_TMPDIR/infra-score"
    create_infrastructure_project "$dir"
    local score
    score=$(_score_infrastructure_signals "unknown" "$dir")
    assert_ge 45 "$score" "Infrastructure project has infra score >= 45"
    teardown
}

test_web_scoring
test_cli_scoring
test_infra_scoring

# ─── Test Group: Metadata Detection ──────────────────────────────────────
echo ""
echo "  Metadata Detection"

test_detect_language() {
    setup
    local dir
    dir="$TEST_TMPDIR/lang-node"; mkdir -p "$dir"; echo '{}' > "$dir/package.json"
    assert_equals "node" "$(_detect_language "$dir")" "Detect node from package.json"
    dir="$TEST_TMPDIR/lang-go"; mkdir -p "$dir"; echo 'module x' > "$dir/go.mod"
    assert_equals "go" "$(_detect_language "$dir")" "Detect go from go.mod"
    dir="$TEST_TMPDIR/lang-rust"; mkdir -p "$dir"; echo '[package]' > "$dir/Cargo.toml"
    assert_equals "rust" "$(_detect_language "$dir")" "Detect rust from Cargo.toml"
    dir="$TEST_TMPDIR/lang-python"; mkdir -p "$dir"; touch "$dir/requirements.txt"
    assert_equals "python" "$(_detect_language "$dir")" "Detect python from requirements.txt"
    dir="$TEST_TMPDIR/lang-java"; mkdir -p "$dir"; echo '<project/>' > "$dir/pom.xml"
    assert_equals "java" "$(_detect_language "$dir")" "Detect java from pom.xml"
    dir="$TEST_TMPDIR/lang-ruby"; mkdir -p "$dir"; echo "source 'https://rubygems.org'" > "$dir/Gemfile"
    assert_equals "ruby" "$(_detect_language "$dir")" "Detect ruby from Gemfile"
    dir="$TEST_TMPDIR/lang-unknown"; mkdir -p "$dir"
    assert_equals "unknown" "$(_detect_language "$dir")" "Detect unknown for empty dir"
    teardown
}

test_detect_package_manager() {
    setup
    local dir
    dir="$TEST_TMPDIR/pm-npm"; mkdir -p "$dir"; echo '{}' > "$dir/package.json"
    assert_equals "npm" "$(_detect_pkg_manager "node" "$dir")" "Detect npm"
    dir="$TEST_TMPDIR/pm-yarn"; mkdir -p "$dir"; echo '{}' > "$dir/package.json"; touch "$dir/yarn.lock"
    assert_equals "yarn" "$(_detect_pkg_manager "node" "$dir")" "Detect yarn"
    dir="$TEST_TMPDIR/pm-pnpm"; mkdir -p "$dir"; echo '{}' > "$dir/package.json"; touch "$dir/pnpm-lock.yaml"
    assert_equals "pnpm" "$(_detect_pkg_manager "node" "$dir")" "Detect pnpm"
    assert_equals "cargo" "$(_detect_pkg_manager "rust" "$dir")" "Detect cargo for rust"
    assert_equals "pip" "$(_detect_pkg_manager "python" "$dir")" "Detect pip for python"
    teardown
}

test_detect_language
test_detect_package_manager

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
