#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright project-signals test — Unit tests for repo-shape detectors   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Project Signals Tests"

setup_test_env "sw-project-signals-test"
trap cleanup_test_env EXIT

source "$SCRIPT_DIR/lib/project-signals.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Fixtures
# ═══════════════════════════════════════════════════════════════════════════

# A real git repo — the detectors read commit history, so mocking git would
# only test the mock.
make_git_repo() {
    local dir="$1" commits="${2:-1}"
    mkdir -p "$dir"
    git -C "$dir" init -q 2>/dev/null
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    local i=1
    while [[ "$i" -le "$commits" ]]; do
        echo "$i" > "$dir/commit-$i.txt"
        git -C "$dir" add -A
        git -C "$dir" commit -q -m "commit $i" --no-verify
        i=$((i + 1))
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# detect_monorepo
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "detect_monorepo"

proj="$TEST_TEMP_DIR/mono-npm"
mkdir -p "$proj/packages/api" "$proj/packages/web" "$proj/packages/empty-dir"
echo '{"name":"root","workspaces":["packages/*"]}' > "$proj/package.json"
echo '{"name":"api"}' > "$proj/packages/api/package.json"
echo '{"name":"web"}' > "$proj/packages/web/package.json"
result=$(detect_monorepo "$proj")
assert_json_key "npm workspaces detected as monorepo" "$result" ".is_monorepo" "true"
assert_json_key "npm workspace type" "$result" ".type" "npm"
assert_json_key "counts only dirs with a manifest" "$result" ".workspace_count" "2"

proj="$TEST_TEMP_DIR/mono-yarn"
mkdir -p "$proj/packages/a"
echo '{"name":"root","workspaces":{"packages":["packages/*"]}}' > "$proj/package.json"
echo '{"name":"a"}' > "$proj/packages/a/package.json"
touch "$proj/yarn.lock"
result=$(detect_monorepo "$proj")
assert_json_key "yarn object-form workspaces detected" "$result" ".is_monorepo" "true"
assert_json_key "yarn workspace type" "$result" ".type" "yarn"

proj="$TEST_TEMP_DIR/mono-pnpm"
mkdir -p "$proj/apps/one" "$proj/apps/two"
printf 'packages:\n  - "apps/*"\n' > "$proj/pnpm-workspace.yaml"
echo '{"name":"one"}' > "$proj/apps/one/package.json"
echo '{"name":"two"}' > "$proj/apps/two/package.json"
result=$(detect_monorepo "$proj")
assert_json_key "pnpm workspace detected" "$result" ".type" "pnpm"
assert_json_key "pnpm workspace count" "$result" ".workspace_count" "2"

proj="$TEST_TEMP_DIR/mono-cargo"
mkdir -p "$proj/crates/core"
printf '[workspace]\nmembers = ["crates/core"]\n' > "$proj/Cargo.toml"
printf '[package]\nname = "core"\n' > "$proj/crates/core/Cargo.toml"
result=$(detect_monorepo "$proj")
assert_json_key "cargo workspace detected" "$result" ".type" "cargo"
assert_json_key "cargo workspace count" "$result" ".workspace_count" "1"

proj="$TEST_TEMP_DIR/mono-go"
mkdir -p "$proj/svc"
printf 'go 1.22\n\nuse (\n\t./svc\n)\n' > "$proj/go.work"
printf 'module svc\n' > "$proj/svc/go.mod"
result=$(detect_monorepo "$proj")
assert_json_key "go workspace detected" "$result" ".type" "go"
assert_json_key "go workspace count" "$result" ".workspace_count" "1"

proj="$TEST_TEMP_DIR/mono-lerna"
mkdir -p "$proj/pkgs/x"
echo '{"packages":["pkgs/*"]}' > "$proj/lerna.json"
echo '{"name":"x"}' > "$proj/pkgs/x/package.json"
result=$(detect_monorepo "$proj")
assert_json_key "lerna workspace detected" "$result" ".type" "lerna"

proj="$TEST_TEMP_DIR/single-pkg"
mkdir -p "$proj"
echo '{"name":"solo","version":"1.0.0"}' > "$proj/package.json"
result=$(detect_monorepo "$proj")
assert_json_key "single package is not a monorepo" "$result" ".is_monorepo" "false"
assert_json_key "single package workspace type" "$result" ".type" "none"

proj="$TEST_TEMP_DIR/bad-json"
mkdir -p "$proj"
echo '{invalid' > "$proj/package.json"
result=$(detect_monorepo "$proj")
assert_json_key "malformed package.json degrades to not-a-monorepo" "$result" ".is_monorepo" "false"

result=$(detect_monorepo "$TEST_TEMP_DIR/does-not-exist")
assert_json_key "missing dir reports detection_skipped" "$result" ".reason" "detection_skipped"

# ═══════════════════════════════════════════════════════════════════════════
# detect_ci_maturity
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "detect_ci_maturity"

proj="$TEST_TEMP_DIR/ci-none"
mkdir -p "$proj"
result=$(detect_ci_maturity "$proj")
assert_json_key "no CI config → has_ci false" "$result" ".has_ci" "false"
assert_json_key "no CI config → maturity none" "$result" ".maturity" "none"

proj="$TEST_TEMP_DIR/ci-gha"
mkdir -p "$proj/.github/workflows"
touch "$proj/.github/workflows/ci.yml" "$proj/.github/workflows/release.yaml"
result=$(detect_ci_maturity "$proj")
assert_json_key "GitHub Actions detected" "$result" ".has_ci" "true"
assert_json_key "two workflows → minimal maturity" "$result" ".maturity" "minimal"
assert_contains "ci_types names github_actions" "$result" "github_actions"

proj="$TEST_TEMP_DIR/ci-empty-dir"
mkdir -p "$proj/.github/workflows"
result=$(detect_ci_maturity "$proj")
assert_json_key "empty workflows dir is not CI" "$result" ".has_ci" "false"

proj="$TEST_TEMP_DIR/ci-many"
mkdir -p "$proj/.github/workflows"
for n in 1 2 3 4 5 6; do touch "$proj/.github/workflows/w$n.yml"; done
result=$(detect_ci_maturity "$proj")
assert_json_key "six workflows → mature" "$result" ".maturity" "mature"

proj="$TEST_TEMP_DIR/ci-mixed"
mkdir -p "$proj/.circleci"
touch "$proj/.circleci/config.yml" "$proj/.gitlab-ci.yml" "$proj/Jenkinsfile"
result=$(detect_ci_maturity "$proj")
assert_json_key "non-GitHub CI providers detected" "$result" ".has_ci" "true"
assert_json_key "three providers → standard maturity" "$result" ".maturity" "standard"
assert_contains "circleci in ci_types" "$result" "circleci"
assert_contains "gitlab in ci_types" "$result" "gitlab"

result=$(detect_ci_maturity "$TEST_TEMP_DIR/does-not-exist")
assert_json_key "missing dir CI reports detection_skipped" "$result" ".reason" "detection_skipped"

# ═══════════════════════════════════════════════════════════════════════════
# detect_test_maturity
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "detect_test_maturity"

proj="$TEST_TEMP_DIR/tests-none"
mkdir -p "$proj"
result=$(detect_test_maturity "$proj" "jest" 40 0)
assert_json_key "no tests → maturity none" "$result" ".maturity" "none"
assert_json_key "no tests → ratio 0" "$result" ".test_ratio" "0"
assert_json_key "framework echoed back" "$result" ".framework" "jest"

result=$(detect_test_maturity "$proj" "jest" 100 10)
assert_json_key "10% ratio → new" "$result" ".maturity" "new"
assert_json_key "ratio is a percentage" "$result" ".test_ratio" "10"

result=$(detect_test_maturity "$proj" "jest" 100 30)
assert_json_key "30% ratio → established" "$result" ".maturity" "established"

result=$(detect_test_maturity "$proj" "vitest" 100 60)
assert_json_key "60% ratio → mature" "$result" ".maturity" "mature"

result=$(detect_test_maturity "$proj" "" 0 0)
assert_json_key "zero sources does not divide by zero" "$result" ".test_ratio" "0"

proj="$TEST_TEMP_DIR/tests-cov"
mkdir -p "$proj"
touch "$proj/codecov.yml"
result=$(detect_test_maturity "$proj" "jest" 100 10)
assert_json_key "coverage config detected" "$result" ".has_coverage_config" "true"
assert_json_key "coverage config lifts new → established" "$result" ".maturity" "established"

proj="$TEST_TEMP_DIR/tests-counted"
mkdir -p "$proj/src"
touch "$proj/src/a.js" "$proj/src/b.js" "$proj/src/a.test.js"
result=$(detect_test_maturity "$proj" "" "" "")
assert_json_key "counts test files when not injected" "$result" ".test_file_count" "1"

result=$(detect_test_maturity "$TEST_TEMP_DIR/does-not-exist" "jest" 1 1)
assert_json_key "missing dir test maturity is none" "$result" ".maturity" "none"

# ═══════════════════════════════════════════════════════════════════════════
# detect_repo_size
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "detect_repo_size"

proj="$TEST_TEMP_DIR/size-tiny"
make_git_repo "$proj" 2
result=$(detect_repo_size "$proj" 5)
assert_json_key "2 commits → tiny" "$result" ".size_category" "tiny"
assert_json_key "commit count reported" "$result" ".commit_count" "2"
assert_json_key "injected file count is used verbatim" "$result" ".file_count" "5"

proj="$TEST_TEMP_DIR/size-nongit"
mkdir -p "$proj"
result=$(detect_repo_size "$proj" 3)
assert_json_key "non-git dir → unknown" "$result" ".size_category" "unknown"
assert_json_key "non-git dir → commit_count -1" "$result" ".commit_count" "-1"

# Shallow clones are the CI checkout default. Reporting them as "tiny" would
# make every CI-run prep recommend the fast template.
proj="$TEST_TEMP_DIR/size-source"
make_git_repo "$proj" 3
shallow="$TEST_TEMP_DIR/size-shallow"
if git clone -q --depth 1 "file://$proj" "$shallow" 2>/dev/null; then
    result=$(detect_repo_size "$shallow" 5)
    assert_json_key "shallow clone → unknown, not tiny" "$result" ".size_category" "unknown"
    assert_contains "shallow clone reason names the shallow clone" "$result" "shallow"
else
    assert_fail "shallow clone → unknown, not tiny" "git clone --depth 1 unavailable"
fi

result=$(detect_repo_size "$TEST_TEMP_DIR/does-not-exist" "")
assert_json_key "missing dir size reports detection_skipped" "$result" ".reason" "detection_skipped"

# ═══════════════════════════════════════════════════════════════════════════
# detect_activity_level
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "detect_activity_level"

proj="$TEST_TEMP_DIR/activity-fresh"
make_git_repo "$proj" 1
result=$(detect_activity_level "$proj")
assert_json_key "fresh commit → active" "$result" ".is_active" "true"
assert_json_key "fresh commit → 0 days" "$result" ".days_since_last_commit" "0"

proj="$TEST_TEMP_DIR/activity-stale"
mkdir -p "$proj"
git -C "$proj" init -q
git -C "$proj" config user.email "test@example.com"
git -C "$proj" config user.name "Test"
echo hi > "$proj/f.txt"
git -C "$proj" add -A
GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" \
    git -C "$proj" commit -q -m old --no-verify
result=$(detect_activity_level "$proj")
assert_json_key "old commit → inactive" "$result" ".is_active" "false"

proj="$TEST_TEMP_DIR/activity-nongit"
mkdir -p "$proj"
result=$(detect_activity_level "$proj")
assert_json_key "non-git dir → not active" "$result" ".is_active" "false"
assert_json_key "non-git dir → -1 days" "$result" ".days_since_last_commit" "-1"

# ═══════════════════════════════════════════════════════════════════════════
# project_collect_signals — totality
# ═══════════════════════════════════════════════════════════════════════════
print_test_section "project_collect_signals"

proj="$TEST_TEMP_DIR/collect-full"
make_git_repo "$proj" 2
mkdir -p "$proj/.github/workflows" "$proj/packages/a"
touch "$proj/.github/workflows/ci.yml"
echo '{"name":"root","workspaces":["packages/*"]}' > "$proj/package.json"
echo '{"name":"a"}' > "$proj/packages/a/package.json"
result=$(project_collect_signals "$proj" "vitest" 40 20)
assert_json_key "signals include monorepo" "$result" ".monorepo.is_monorepo" "true"
assert_json_key "signals include ci" "$result" ".ci.has_ci" "true"
assert_json_key "signals include test" "$result" ".test.framework" "vitest"
assert_json_key "signals include size" "$result" ".size.size_category" "tiny"
assert_json_key "signals include activity" "$result" ".activity.is_active" "true"
assert_contains "signals carry a timestamp" "$result" "collected_at"

# Every detector must be total: valid JSON and exit 0 on hostile inputs.
for hostile in "$TEST_TEMP_DIR/does-not-exist" "/dev/null" "$TEST_TEMP_DIR/bad-json"; do
    if out=$(project_collect_signals "$hostile" "" "" "" 2>/dev/null) && \
       echo "$out" | jq -e . >/dev/null 2>&1; then
        assert_pass "collect_signals is total for: $(basename "$hostile")"
    else
        assert_fail "collect_signals is total for: $(basename "$hostile")" "$out"
    fi
done

# Non-numeric injected counts must not crash the arithmetic.
if out=$(project_collect_signals "$TEST_TEMP_DIR/collect-full" "jest" "not-a-number" "-7" 2>/dev/null) && \
   echo "$out" | jq -e . >/dev/null 2>&1; then
    assert_pass "collect_signals survives non-numeric counts"
else
    assert_fail "collect_signals survives non-numeric counts" "$out"
fi

# Idempotence: same tree, same signals (timestamp excluded).
a=$(project_collect_signals "$TEST_TEMP_DIR/collect-full" "vitest" 40 20 | jq -S 'del(.collected_at)')
b=$(project_collect_signals "$TEST_TEMP_DIR/collect-full" "vitest" 40 20 | jq -S 'del(.collected_at)')
assert_eq "signals are deterministic across runs" "$a" "$b"

print_test_results
