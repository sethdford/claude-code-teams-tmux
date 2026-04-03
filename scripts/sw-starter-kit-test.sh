#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-starter-kit-test.sh — Starter Kit Generator Test Suite               ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if echo "$haystack" | grep -q "$needle"; then
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
    if ! echo "$haystack" | grep -q "$needle"; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected NOT to contain: $needle"
    fi
}

assert_file_exists() {
    local filepath="$1" description="${2:-}"
    if [[ -f "$filepath" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    File not found: $filepath"
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
        echo "    Expected exit code: $expected, got: $actual"
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
        echo "    Invalid JSON: $json"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Source the library directly
source "$SCRIPT_DIR/lib/starter-kit.sh"

echo "sw-starter-kit-test.sh"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Section 1: Library function existence
# ═══════════════════════════════════════════════════════════════════════════
echo "Section 1: Library loading"

for fn in starter_kit_best_practices starter_kit_quality_checks starter_kit_pitfalls starter_kit_example_issues _sk_validate_type_framework; do
    if [[ "$(type -t "$fn" 2>/dev/null)" == "function" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m Function $fn exists"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Function $fn missing"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════
# Section 2: Type/framework validation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 2: Type/framework validation"

result=$(_sk_validate_type_framework "nodejs" "express")
assert_contains "$result" "nodejs express" "nodejs+express is valid"

result=$(_sk_validate_type_framework "nodejs" "django")
assert_contains "$result" "nodejs unknown" "nodejs+django resets to unknown"

result=$(_sk_validate_type_framework "python" "fastapi")
assert_contains "$result" "python fastapi" "python+fastapi is valid"

result=$(_sk_validate_type_framework "golang" "gin")
assert_contains "$result" "golang gin" "golang+gin is valid"

result=$(_sk_validate_type_framework "rust" "axum")
assert_contains "$result" "rust axum" "rust+axum is valid"

result=$(_sk_validate_type_framework "ruby" "rails")
assert_contains "$result" "ruby rails" "ruby+rails is valid"

result=$(_sk_validate_type_framework "foobar" "whatever")
assert_contains "$result" "unknown unknown" "unknown type resets both"

# ═══════════════════════════════════════════════════════════════════════════
# Section 3: Best practices for each framework
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 3: Best practices per framework"

output=$(starter_kit_best_practices "nodejs" "next")
assert_contains "$output" "App Router" "Node.js/Next.js mentions App Router"
assert_contains "$output" "Server Components" "Node.js/Next.js mentions Server Components"

output=$(starter_kit_best_practices "nodejs" "express")
assert_contains "$output" "middleware" "Node.js/Express mentions middleware"
assert_contains "$output" "Error-handling" "Node.js/Express mentions error handling"

output=$(starter_kit_best_practices "nodejs" "unknown")
assert_contains "$output" "ES modules" "Node.js generic mentions ES modules"

output=$(starter_kit_best_practices "python" "django")
assert_contains "$output" "Django" "Python/Django mentions Django"
assert_contains "$output" "migrations" "Python/Django mentions migrations"

output=$(starter_kit_best_practices "python" "fastapi")
assert_contains "$output" "Pydantic" "Python/FastAPI mentions Pydantic"

output=$(starter_kit_best_practices "python" "unknown")
assert_contains "$output" "PEP 8" "Python generic mentions PEP 8"

output=$(starter_kit_best_practices "golang" "gin")
assert_contains "$output" "Gin" "Go/Gin mentions Gin"

output=$(starter_kit_best_practices "golang" "unknown")
assert_contains "$output" "cmd/" "Go generic mentions cmd/ layout"

output=$(starter_kit_best_practices "rust" "axum")
assert_contains "$output" "Axum" "Rust/Axum mentions Axum"

output=$(starter_kit_best_practices "rust" "unknown")
assert_contains "$output" "clippy" "Rust generic mentions clippy"

output=$(starter_kit_best_practices "ruby" "rails")
assert_contains "$output" "Rails" "Ruby/Rails mentions Rails"
assert_contains "$output" "ActiveRecord" "Ruby/Rails mentions ActiveRecord"

output=$(starter_kit_best_practices "ruby" "unknown")
assert_contains "$output" "RuboCop" "Ruby generic mentions RuboCop"

output=$(starter_kit_best_practices "unknown" "unknown")
assert_contains "$output" "single responsibility" "Unknown returns generic practices"

# ═══════════════════════════════════════════════════════════════════════════
# Section 4: Quality checks per framework
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 4: Quality checks per framework"

# Node.js with TypeScript
mkdir -p "$TMP_DIR/ts_project"
echo '{}' > "$TMP_DIR/ts_project/tsconfig.json"
output=$(starter_kit_quality_checks "nodejs" "unknown" "$TMP_DIR/ts_project")
assert_json_valid "$output" "Node.js quality checks is valid JSON"
assert_contains "$output" "tsc --noEmit" "Node.js+TS includes tsc check"

# Node.js without TypeScript
mkdir -p "$TMP_DIR/js_project"
output=$(starter_kit_quality_checks "nodejs" "unknown" "$TMP_DIR/js_project")
assert_not_contains "$output" "tsc" "Node.js without TS excludes tsc check"

output=$(starter_kit_quality_checks "python" "django" ".")
assert_json_valid "$output" "Python/Django quality checks is valid JSON"
assert_contains "$output" "manage.py test" "Django includes manage.py test"
assert_contains "$output" "ruff" "Django includes ruff"

output=$(starter_kit_quality_checks "python" "unknown" ".")
assert_contains "$output" "pytest" "Python generic includes pytest"

output=$(starter_kit_quality_checks "golang" "unknown" ".")
assert_json_valid "$output" "Go quality checks is valid JSON"
assert_contains "$output" "go vet" "Go includes go vet"
assert_contains "$output" "golangci-lint" "Go includes golangci-lint"

output=$(starter_kit_quality_checks "rust" "unknown" ".")
assert_json_valid "$output" "Rust quality checks is valid JSON"
assert_contains "$output" "cargo clippy" "Rust includes clippy"
assert_contains "$output" "cargo fmt" "Rust includes cargo fmt"

output=$(starter_kit_quality_checks "ruby" "rails" ".")
assert_json_valid "$output" "Ruby/Rails quality checks is valid JSON"
assert_contains "$output" "rubocop" "Rails includes rubocop"

output=$(starter_kit_quality_checks "unknown" "unknown" ".")
assert_json_valid "$output" "Unknown quality checks is valid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# Section 5: Pitfalls per framework
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 5: Pitfalls per framework"

output=$(starter_kit_pitfalls "nodejs" "express")
assert_contains "$output" "promise" "Node.js pitfalls mention promises"

output=$(starter_kit_pitfalls "python" "django")
assert_contains "$output" "Circular imports" "Python pitfalls mention circular imports"

output=$(starter_kit_pitfalls "golang" "unknown")
assert_contains "$output" "Goroutine leaks" "Go pitfalls mention goroutine leaks"

output=$(starter_kit_pitfalls "rust" "unknown")
assert_contains "$output" "Lifetime" "Rust pitfalls mention lifetimes"

output=$(starter_kit_pitfalls "ruby" "rails")
assert_contains "$output" "N+1" "Ruby pitfalls mention N+1 queries"

output=$(starter_kit_pitfalls "unknown" "unknown")
assert_contains "$output" "error" "Unknown pitfalls mention errors"

# ═══════════════════════════════════════════════════════════════════════════
# Section 6: Example issue generation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 6: Example issue templates"

output=$(starter_kit_example_issues "nodejs" "next" "npm test" ".")
assert_contains "$output" "dependency-update.md" "Node.js issues include dependency-update"
assert_contains "$output" "test-coverage.md" "Node.js issues include test-coverage"
assert_contains "$output" "bug-fix.md" "Node.js issues include bug-fix"
assert_contains "$output" "typescript-strict.md" "Node.js issues include TS-specific template"
assert_contains "$output" "npm outdated" "Node.js dependency update uses npm"

output=$(starter_kit_example_issues "python" "django" "pytest" ".")
assert_contains "$output" "type-hints.md" "Python issues include type-hints"

output=$(starter_kit_example_issues "golang" "unknown" "go test ./..." ".")
assert_contains "$output" "linter-setup.md" "Go issues include linter-setup"

output=$(starter_kit_example_issues "rust" "axum" "cargo test" ".")
assert_contains "$output" "clippy-strict.md" "Rust issues include clippy-strict"

output=$(starter_kit_example_issues "ruby" "rails" "bundle exec rspec" ".")
assert_contains "$output" "rubocop-setup.md" "Ruby issues include rubocop-setup"

# ═══════════════════════════════════════════════════════════════════════════
# Section 7: CLI integration
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 7: CLI integration"

# Help flag
output=$("$SCRIPT_DIR/sw-starter-kit.sh" --help 2>&1)
assert_contains "$output" "USAGE" "CLI --help shows usage"
assert_contains "$output" "generate" "CLI help mentions generate"
assert_contains "$output" "issues" "CLI help mentions issues"
assert_contains "$output" "check" "CLI help mentions check"

# Version flag
output=$("$SCRIPT_DIR/sw-starter-kit.sh" --version 2>&1)
if [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    PASS=$((PASS + 1))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m CLI --version returns version"
else
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m CLI --version returns version"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 8: Full generate flow (dry-run)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 8: Full generate flow (dry-run)"

# Create a mock Node.js project
MOCK_PROJECT="$TMP_DIR/mock-nodejs"
mkdir -p "$MOCK_PROJECT/.claude"
echo '{"name": "test", "dependencies": {"express": "4.18.0"}, "scripts": {"test": "jest"}, "devDependencies": {"jest": "29.0.0"}}' > "$MOCK_PROJECT/package.json"
touch "$MOCK_PROJECT/.claude/CLAUDE.md"

output=$("$SCRIPT_DIR/sw-starter-kit.sh" generate --root "$MOCK_PROJECT" --dry-run 2>&1)
assert_contains "$output" "Detected:" "Dry run shows detection"
assert_contains "$output" "Dry run" "Dry run flag acknowledged"

# ═══════════════════════════════════════════════════════════════════════════
# Section 9: Full generate flow (actual write)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 9: Full generate flow (write)"

MOCK_PROJECT2="$TMP_DIR/mock-python"
mkdir -p "$MOCK_PROJECT2/.claude"
touch "$MOCK_PROJECT2/.claude/CLAUDE.md"
echo -e "[project]\nname = \"myapp\"\n[project.dependencies]\ndjango = \">=4.0\"" > "$MOCK_PROJECT2/pyproject.toml"

output=$("$SCRIPT_DIR/sw-starter-kit.sh" generate --root "$MOCK_PROJECT2" 2>&1)
assert_contains "$output" "python" "Generate detects Python project"

assert_file_exists "$MOCK_PROJECT2/.claude/quality-checks.json" "Quality checks file created"
assert_file_exists "$MOCK_PROJECT2/.claude/CLAUDE.md" "CLAUDE.md exists"

# Check CLAUDE.md has starter kit markers
claude_content=$(cat "$MOCK_PROJECT2/.claude/CLAUDE.md")
assert_contains "$claude_content" "sw:starter-kit-start" "CLAUDE.md has start marker"
assert_contains "$claude_content" "sw:starter-kit-end" "CLAUDE.md has end marker"
assert_contains "$claude_content" "Django" "CLAUDE.md mentions Django"

# Check issue templates were created
if [[ -d "$MOCK_PROJECT2/.github/ISSUE_TEMPLATE" ]]; then
    local_count=$(find "$MOCK_PROJECT2/.github/ISSUE_TEMPLATE" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$local_count" -ge 3 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m At least 3 issue templates created ($local_count found)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Expected at least 3 issue templates, got $local_count"
    fi
else
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m .github/ISSUE_TEMPLATE directory not created"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 10: Idempotency — run generate twice
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 10: Idempotency"

content_before=$(cat "$MOCK_PROJECT2/.claude/CLAUDE.md")
"$SCRIPT_DIR/sw-starter-kit.sh" generate --root "$MOCK_PROJECT2" --force > /dev/null 2>&1
content_after=$(cat "$MOCK_PROJECT2/.claude/CLAUDE.md")

# Count occurrences of start marker — should be exactly 1
start_count=$(grep -c "sw:starter-kit-start" "$MOCK_PROJECT2/.claude/CLAUDE.md" || true)
if [[ "$start_count" -eq 1 ]]; then
    PASS=$((PASS + 1))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m Idempotent: exactly 1 start marker after re-run"
else
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Expected 1 start marker, found $start_count"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 11: Check subcommand
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 11: Check subcommand"

# Project with full setup should pass some checks
output=$("$SCRIPT_DIR/sw-starter-kit.sh" check --root "$MOCK_PROJECT2" 2>&1) || true
assert_contains "$output" "CLAUDE.md exists" "Check reports CLAUDE.md exists"
assert_contains "$output" "Starter kit section present" "Check reports starter kit section"
assert_contains "$output" "Quality checks configured" "Check reports quality checks"

# Empty project should report gaps
EMPTY_PROJECT="$TMP_DIR/empty"
mkdir -p "$EMPTY_PROJECT"
output=$("$SCRIPT_DIR/sw-starter-kit.sh" check --root "$EMPTY_PROJECT" 2>&1) || true
assert_contains "$output" "Missing" "Check reports missing items for empty project"

# ═══════════════════════════════════════════════════════════════════════════
# Section 12: Issues-only subcommand
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 12: Issues-only subcommand"

ISSUES_PROJECT="$TMP_DIR/issues-only"
mkdir -p "$ISSUES_PROJECT"
echo '{"name": "test", "dependencies": {"express": "4.0"}}' > "$ISSUES_PROJECT/package.json"

output=$("$SCRIPT_DIR/sw-starter-kit.sh" issues --root "$ISSUES_PROJECT" 2>&1)
assert_contains "$output" "Generated" "Issues command reports generation"

if [[ -d "$ISSUES_PROJECT/.github/ISSUE_TEMPLATE" ]]; then
    PASS=$((PASS + 1))
    echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m Issue templates directory created"
else
    FAIL=$((FAIL + 1))
    echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Issue templates directory not created"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Section 13: Go project generate
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 13: Go project generate"

GO_PROJECT="$TMP_DIR/mock-go"
mkdir -p "$GO_PROJECT/.claude"
touch "$GO_PROJECT/.claude/CLAUDE.md"
echo -e "module example.com/myapp\n\ngo 1.21\n\nrequire github.com/gin-gonic/gin v1.9.0" > "$GO_PROJECT/go.mod"

output=$("$SCRIPT_DIR/sw-starter-kit.sh" generate --root "$GO_PROJECT" 2>&1)
assert_contains "$output" "golang" "Go project detected"

claude_content=$(cat "$GO_PROJECT/.claude/CLAUDE.md")
assert_contains "$claude_content" "Gin" "Go/Gin practices in CLAUDE.md"
assert_contains "$claude_content" "Goroutine" "Go pitfalls in CLAUDE.md"

# ═══════════════════════════════════════════════════════════════════════════
# Section 14: Rust project generate
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 14: Rust project generate"

RUST_PROJECT="$TMP_DIR/mock-rust"
mkdir -p "$RUST_PROJECT/.claude"
touch "$RUST_PROJECT/.claude/CLAUDE.md"
cat > "$RUST_PROJECT/Cargo.toml" <<'TOML'
[package]
name = "myapp"
version = "0.1.0"

[dependencies]
axum = "0.7"
TOML

output=$("$SCRIPT_DIR/sw-starter-kit.sh" generate --root "$RUST_PROJECT" 2>&1)
assert_contains "$output" "rust" "Rust project detected"

claude_content=$(cat "$RUST_PROJECT/.claude/CLAUDE.md")
assert_contains "$claude_content" "Axum" "Rust/Axum practices in CLAUDE.md"

# ═══════════════════════════════════════════════════════════════════════════
# Section 15: Ruby project generate
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 15: Ruby project generate"

RUBY_PROJECT="$TMP_DIR/mock-ruby"
mkdir -p "$RUBY_PROJECT/.claude"
touch "$RUBY_PROJECT/.claude/CLAUDE.md"
cat > "$RUBY_PROJECT/Gemfile" <<'GEMFILE'
source 'https://rubygems.org'
gem 'rails', '~> 7.0'
gem 'rspec-rails'
GEMFILE

output=$("$SCRIPT_DIR/sw-starter-kit.sh" generate --root "$RUBY_PROJECT" 2>&1)
assert_contains "$output" "ruby" "Ruby project detected"

claude_content=$(cat "$RUBY_PROJECT/.claude/CLAUDE.md")
assert_contains "$claude_content" "Rails" "Ruby/Rails practices in CLAUDE.md"

# ═══════════════════════════════════════════════════════════════════════════
# Section 16: Framework override
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 16: Framework override"

OVERRIDE_PROJECT="$TMP_DIR/mock-override"
mkdir -p "$OVERRIDE_PROJECT/.claude"
touch "$OVERRIDE_PROJECT/.claude/CLAUDE.md"
echo '{"name": "test", "dependencies": {"express": "4.0"}}' > "$OVERRIDE_PROJECT/package.json"

output=$("$SCRIPT_DIR/sw-starter-kit.sh" generate --root "$OVERRIDE_PROJECT" --framework next 2>&1)
assert_contains "$output" "framework=next" "Framework override applied"

# ═══════════════════════════════════════════════════════════════════════════
# Section 17: Bash 3.2 compliance
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Section 17: Bash 3.2 compliance"

for script in "$SCRIPT_DIR/lib/starter-kit.sh" "$SCRIPT_DIR/sw-starter-kit.sh"; do
    local_name=$(basename "$script")

    # Check for associative arrays
    if grep -q 'declare -A' "$script" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $local_name uses declare -A (bash 3.2 incompatible)"
    else
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $local_name has no declare -A"
    fi

    # Check for readarray
    if grep -q 'readarray' "$script" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $local_name uses readarray (bash 3.2 incompatible)"
    else
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $local_name has no readarray"
    fi

    # Syntax check
    if bash -n "$script" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $local_name passes bash -n syntax check"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $local_name fails bash -n syntax check"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
