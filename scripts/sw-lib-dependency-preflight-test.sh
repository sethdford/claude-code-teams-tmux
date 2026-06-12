#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/dependency-preflight test — Pre-flight dependency engine   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: dependency-preflight Tests"

setup_test_env "sw-lib-dependency-preflight-test"
trap cleanup_test_env EXIT

# Source the engine (and its deps).
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/compat.sh"
_DEPENDENCY_PREFLIGHT_LOADED=""
source "$SCRIPT_DIR/lib/dependency-preflight.sh"

# Isolate events to the test dir so emit_event doesn't touch real state.
export EVENTS_FILE="$TEST_TEMP_DIR/events.jsonl"
: > "$EVENTS_FILE"

# ─── Mock package managers on a controlled PATH ──────────────────────────────
# Each mock records its invocation to $MOCK_LOG and succeeds (or fails) per env.
MOCK_BIN="$TEST_TEMP_DIR/mockbin"
MOCK_LOG="$TEST_TEMP_DIR/mock-invocations.log"
mkdir -p "$MOCK_BIN"
: > "$MOCK_LOG"

make_mock() {
    local name="$1" exit_code="${2:-0}"
    cat > "$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$*" >> "$MOCK_LOG"
exit $exit_code
EOF
    chmod +x "$MOCK_BIN/$name"
}

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "_smart_bool helper"
# ═══════════════════════════════════════════════════════════════════════════════

unset SW_TESTBOOL_KEY 2>/dev/null || true
assert_eq "_smart_bool default true when unset" "true" "$(_smart_bool testbool.key true)"
assert_eq "_smart_bool default false when unset" "false" "$(_smart_bool testbool.key false)"

export SW_TESTBOOL_KEY="false"
assert_eq "_smart_bool env override wins (false)" "false" "$(_smart_bool testbool.key true)"
export SW_TESTBOOL_KEY="yes"
assert_eq "_smart_bool truthy 'yes' → true" "true" "$(_smart_bool testbool.key false)"
export SW_TESTBOOL_KEY="1"
assert_eq "_smart_bool truthy '1' → true" "true" "$(_smart_bool testbool.key false)"
export SW_TESTBOOL_KEY="garbage"
assert_eq "_smart_bool non-truthy → false" "false" "$(_smart_bool testbool.key true)"
unset SW_TESTBOOL_KEY

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_detect_manifests — per-manager detection"
# ═══════════════════════════════════════════════════════════════════════════════

PROJ="$TEST_TEMP_DIR/proj-detect"
mkdir -p "$PROJ"
echo '{"dependencies":{}}' > "$PROJ/package.json"
echo "flask" > "$PROJ/requirements.txt"
echo "module x" > "$PROJ/go.mod"
echo "source 'https://rubygems.org'" > "$PROJ/Gemfile"
echo "<project/>" > "$PROJ/pom.xml"

detected="$(dep_detect_manifests "$PROJ")"
assert_contains "detects npm/package.json" "$detected" "npm	$PROJ/package.json"
assert_contains "detects pip/requirements.txt" "$detected" "pip	$PROJ/requirements.txt"
assert_contains "detects go/go.mod" "$detected" "go	$PROJ/go.mod"
assert_contains "detects bundle/Gemfile" "$detected" "bundle	$PROJ/Gemfile"
assert_contains "detects maven/pom.xml" "$detected" "maven	$PROJ/pom.xml"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_detect_manifests — excludes node_modules/vendor (monorepo)"
# ═══════════════════════════════════════════════════════════════════════════════

MONO="$TEST_TEMP_DIR/mono"
mkdir -p "$MONO/packages/api" "$MONO/node_modules/some-dep" "$MONO/vendor/bundle/gems"
echo '{}' > "$MONO/package.json"
echo '{}' > "$MONO/packages/api/package.json"
echo '{}' > "$MONO/node_modules/some-dep/package.json"   # must be excluded
echo "x" > "$MONO/vendor/bundle/gems/Gemfile"            # must be excluded

mono_detected="$(dep_detect_manifests "$MONO")"
assert_contains "monorepo: root manifest detected" "$mono_detected" "npm	$MONO/package.json"
assert_contains "monorepo: nested package detected" "$mono_detected" "npm	$MONO/packages/api/package.json"
if echo "$mono_detected" | grep -q "node_modules"; then
    assert_fail "monorepo: node_modules excluded" "found node_modules manifest"
else
    assert_pass "monorepo: node_modules excluded"
fi
if echo "$mono_detected" | grep -q "vendor"; then
    assert_fail "monorepo: vendor excluded" "found vendor manifest"
else
    assert_pass "monorepo: vendor excluded"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_manager_available"
# ═══════════════════════════════════════════════════════════════════════════════

make_mock npm 0
( export PATH="$MOCK_BIN:$PATH"; dep_manager_available npm ) \
    && assert_pass "manager available when binary present" \
    || assert_fail "manager available when binary present"

# Empty PATH → npm missing
( export PATH="$TEST_TEMP_DIR/emptybin"; mkdir -p "$TEST_TEMP_DIR/emptybin"; dep_manager_available npm ) \
    && assert_fail "manager missing when absent" "reported available" \
    || assert_pass "manager missing when absent"

assert_exit_code "unknown manager → unavailable" 1 "$(dep_manager_available bogusmgr; echo $?)"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_is_installed heuristics"
# ═══════════════════════════════════════════════════════════════════════════════

INST="$TEST_TEMP_DIR/inst"
mkdir -p "$INST"
dep_is_installed npm "$INST" && assert_fail "npm not installed (no node_modules)" "reported installed" || assert_pass "npm not installed (no node_modules)"
mkdir -p "$INST/node_modules"
dep_is_installed npm "$INST" && assert_pass "npm installed (node_modules present)" || assert_fail "npm installed (node_modules present)"

dep_is_installed pip "$INST" && assert_fail "pip not installed (no venv)" "reported installed" || assert_pass "pip not installed (no venv)"
mkdir -p "$INST/.venv"
dep_is_installed pip "$INST" && assert_pass "pip installed (.venv present)" || assert_fail "pip installed (.venv present)"

dep_is_installed maven "$INST" && assert_fail "maven not installed (no target)" "reported installed" || assert_pass "maven not installed (no target)"
mkdir -p "$INST/target"
dep_is_installed maven "$INST" && assert_pass "maven installed (target present)" || assert_fail "maven installed (target present)"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_preflight_run — disabled flag is a no-op"
# ═══════════════════════════════════════════════════════════════════════════════

: > "$EVENTS_FILE"
DIS="$TEST_TEMP_DIR/disabled"
mkdir -p "$DIS"
echo '{"dependencies":{"x":"1"}}' > "$DIS/package.json"
( export SW_DEPENDENCY_PREFLIGHT_AUTO_INSTALL="false"
  export PATH="$MOCK_BIN:$PATH"
  dep_preflight_run "$DIS" )
assert_exit_code "disabled run returns 0" 0 "$( export SW_DEPENDENCY_PREFLIGHT_AUTO_INSTALL=false; export PATH="$MOCK_BIN:$PATH"; dep_preflight_run "$DIS"; echo $? )"
assert_contains "disabled emits status=disabled" "$(cat "$EVENTS_FILE")" "disabled"
if grep -q "npm install\|npm ci" "$MOCK_LOG"; then
    assert_fail "disabled: no install attempted" "install ran"
else
    assert_pass "disabled: no install attempted"
fi

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_preflight_run — integration: missing deps trigger install"
# ═══════════════════════════════════════════════════════════════════════════════

: > "$EVENTS_FILE"
: > "$MOCK_LOG"
make_mock npm 0
NODE_PROJ="$TEST_TEMP_DIR/node-missing"
mkdir -p "$NODE_PROJ"
echo '{"dependencies":{"left-pad":"1.0.0","chalk":"5.0.0"}}' > "$NODE_PROJ/package.json"
# No node_modules → deps are missing.

ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"
( export PATH="$MOCK_BIN:$PATH"; export ARTIFACTS_DIR; dep_preflight_run "$NODE_PROJ" )

assert_contains "integration: npm install invoked" "$(cat "$MOCK_LOG")" "npm install"
assert_contains "integration: success event emitted" "$(cat "$EVENTS_FILE")" "dependencies.installed"
assert_contains "integration: count of 2 deps recorded" "$(cat "$EVENTS_FILE")" "\"count\":2"
assert_file_exists "integration: advisory marker written" "$ARTIFACTS_DIR/dep-preflight.json"
assert_contains "integration: marker says not preinstalled" "$(cat "$ARTIFACTS_DIR/dep-preflight.json")" "false"

# SW_DEPS_PREINSTALLED is exported as 0 inside the run; verify via subshell capture.
result_pre="$( export PATH="$MOCK_BIN:$PATH"; dep_preflight_run "$NODE_PROJ" >/dev/null; echo "$SW_DEPS_PREINSTALLED" )"
assert_eq "integration: SW_DEPS_PREINSTALLED=0 when install needed" "0" "$result_pre"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_preflight_run — all installed → SW_DEPS_PREINSTALLED=1"
# ═══════════════════════════════════════════════════════════════════════════════

: > "$EVENTS_FILE"
: > "$MOCK_LOG"
make_mock npm 0
READY="$TEST_TEMP_DIR/node-ready"
mkdir -p "$READY/node_modules"
echo '{"dependencies":{"x":"1"}}' > "$READY/package.json"
result_pre2="$( export PATH="$MOCK_BIN:$PATH"; dep_preflight_run "$READY" >/dev/null; echo "$SW_DEPS_PREINSTALLED" )"
assert_eq "all-installed: SW_DEPS_PREINSTALLED=1" "1" "$result_pre2"
if grep -q "npm install\|npm ci" "$MOCK_LOG"; then
    assert_fail "all-installed: no install attempted" "install ran"
else
    assert_pass "all-installed: no install attempted"
fi
assert_contains "all-installed: status=present emitted" "$(cat "$EVENTS_FILE")" "present"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_preflight_run — install failure is non-fatal"
# ═══════════════════════════════════════════════════════════════════════════════

: > "$EVENTS_FILE"
: > "$MOCK_LOG"
make_mock npm 1   # npm now fails
FAIL_PROJ="$TEST_TEMP_DIR/node-fail"
mkdir -p "$FAIL_PROJ"
echo '{"dependencies":{"x":"1"}}' > "$FAIL_PROJ/package.json"
rc="$( export PATH="$MOCK_BIN:$PATH"; dep_preflight_run "$FAIL_PROJ" >/dev/null 2>&1; echo $? )"
assert_eq "install failure: run still returns 0 (non-fatal)" "0" "$rc"
assert_contains "install failure: status=failed emitted" "$(cat "$EVENTS_FILE")" "failed"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_preflight_run — manager missing is skipped gracefully"
# ═══════════════════════════════════════════════════════════════════════════════

: > "$EVENTS_FILE"
SKIP_PROJ="$TEST_TEMP_DIR/node-skip"
mkdir -p "$SKIP_PROJ"
echo '{"dependencies":{"x":"1"}}' > "$SKIP_PROJ/package.json"
# Shadow dep_manager_available in a subshell to deterministically simulate an
# absent package manager without breaking coreutils on PATH.
rc2="$(
    dep_manager_available() { return 1; }
    dep_preflight_run "$SKIP_PROJ" >/dev/null 2>&1
    echo $?
)"
assert_eq "manager missing: run returns 0" "0" "$rc2"
assert_contains "manager missing: status=skipped emitted" "$(cat "$EVENTS_FILE")" "skipped"

# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "dep_preflight_run — no manifests is a clean no-op"
# ═══════════════════════════════════════════════════════════════════════════════

EMPTY_PROJ="$TEST_TEMP_DIR/empty-proj"
mkdir -p "$EMPTY_PROJ"
rc3="$( dep_preflight_run "$EMPTY_PROJ"; echo $? )"
assert_eq "no manifests: returns 0" "0" "$rc3"

print_test_results
