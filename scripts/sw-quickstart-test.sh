#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright quickstart test — Test suite for one-command setup           ║
# ║  Tests project type detection, phase orchestration, and idempotency      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# ─── Test Counters ────────────────────────────────────────────────────────
PASS=0
FAIL=0
TESTS_RUN=0

# ─── Colors ───────────────────────────────────────────────────────────────
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
CYAN='\033[38;2;0;212;255m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Test Framework ───────────────────────────────────────────────────────

test_case() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo -e "${CYAN}${BOLD}Test ${TESTS_RUN}: ${test_name}${RESET}"
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Expected exit code $expected, got $actual}"

    if [[ "$actual" -eq "$expected" ]]; then
        echo -e "  ${GREEN}✓${RESET} $msg"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${RESET} $msg"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-Output should contain '$needle'}"

    if echo "$haystack" | grep -q "$needle"; then
        echo -e "  ${GREEN}✓${RESET} $msg"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${RESET} $msg"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local msg="${2:-File should exist: $file}"

    if [[ -f "$file" ]]; then
        echo -e "  ${GREEN}✓${RESET} $msg"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${RESET} $msg"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-Output should not contain '$needle'}"

    if ! echo "$haystack" | grep -q "$needle"; then
        echo -e "  ${GREEN}✓${RESET} $msg"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}✗${RESET} $msg"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

# ─── Setup and Cleanup ─────────────────────────────────────────────────────

setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-quickstart-test.XXXXXX")
    mkdir -p "$TEST_TEMP_DIR/home"
    cd "$TEST_TEMP_DIR"
}

cleanup_test_env() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        cd /
        rm -rf "$TEST_TEMP_DIR"
    fi
}

trap cleanup_test_env EXIT

# ─── Mock Helper for Testing ──────────────────────────────────────────────

# Create minimal mock scripts for init, prep, doctor
setup_mock_scripts() {
    local mock_dir="$1"
    mkdir -p "$mock_dir"

    # Mock init
    cat > "$mock_dir/sw-init.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p .claude
echo "Mock init completed"
exit 0
EOF
    chmod +x "$mock_dir/sw-init.sh"

    # Mock prep
    cat > "$mock_dir/sw-prep.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Not in a git repo, skipping prep" >&2
    exit 1
fi
echo "Mock prep completed"
exit 0
EOF
    chmod +x "$mock_dir/sw-prep.sh"

    # Mock doctor
    cat > "$mock_dir/sw-doctor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Mock doctor completed"
exit 0
EOF
    chmod +x "$mock_dir/sw-doctor.sh"
}

# ─────────────────────────────────────────────────────────────────────────
# TEST SUITE
# ─────────────────────────────────────────────────────────────────────────

# Test 1: Help text
test_case "show_help returns 0"
setup_test_env
output=$("$SCRIPT_DIR/sw-quickstart.sh" --help 2>&1)
exit_code=$?
assert_exit_code 0 $exit_code "Help should exit with 0"
assert_contains "$output" "DESCRIPTION" "Help should contain DESCRIPTION"
assert_contains "$output" "USAGE" "Help should contain USAGE"
cleanup_test_env

# Test 2: Version
test_case "show_version returns 0"
setup_test_env
output=$("$SCRIPT_DIR/sw-quickstart.sh" --version 2>&1)
exit_code=$?
assert_exit_code 0 $exit_code "Version should exit with 0"
assert_contains "$output" "quickstart" "Output should contain 'quickstart'"
cleanup_test_env

# Test 3: Detect Node.js project
test_case "detect_project_type: Node.js (package.json)"
setup_test_env
echo '{}' > package.json
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
assert_contains "$output" "nodejs" "Should detect Node.js project"
cleanup_test_env

# Test 4: Detect Python project
test_case "detect_project_type: Python (requirements.txt)"
setup_test_env
touch requirements.txt
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
assert_contains "$output" "python" "Should detect Python project"
cleanup_test_env

# Test 5: Detect Go project
test_case "detect_project_type: Go (go.mod)"
setup_test_env
touch go.mod
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
assert_contains "$output" "go" "Should detect Go project"
cleanup_test_env

# Test 6: Detect Rust project
test_case "detect_project_type: Rust (Cargo.toml)"
setup_test_env
touch Cargo.toml
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
assert_contains "$output" "rust" "Should detect Rust project"
cleanup_test_env

# Test 7: Detect Ruby project
test_case "detect_project_type: Ruby (Gemfile)"
setup_test_env
touch Gemfile
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
assert_contains "$output" "ruby" "Should detect Ruby project"
cleanup_test_env

# Test 8: Detect Java project
test_case "detect_project_type: Java (pom.xml)"
setup_test_env
touch pom.xml
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
assert_contains "$output" "java" "Should detect Java project"
cleanup_test_env

# Test 9: Unknown project type
test_case "detect_project_type: unknown (no markers)"
setup_test_env
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
assert_contains "$output" "unknown" "Should detect unknown project type"
cleanup_test_env

# Test 10: --skip-init flag
test_case "--skip-init skips init phase"
setup_test_env
mkdir -p .claude  # Pre-create to satisfy skip-init logic
setup_mock_scripts "$SCRIPT_DIR"
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
# No phases should run when all are skipped, but script should exit cleanly
assert_exit_code 0 $exit_code "All skip flags should exit with 0"
assert_not_contains "$output" "Mock init" "Init should not run when skipped"
cleanup_test_env

# Test 11: --skip-prep flag
test_case "--skip-prep skips prep phase"
setup_test_env
mkdir -p .claude
setup_mock_scripts "$SCRIPT_DIR"
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
assert_not_contains "$output" "Mock prep" "Prep should not run"
cleanup_test_env

# Test 12: --skip-doctor flag
test_case "--skip-doctor skips doctor phase"
setup_test_env
mkdir -p .claude
setup_mock_scripts "$SCRIPT_DIR"
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
assert_not_contains "$output" "Mock doctor" "Doctor should not run"
cleanup_test_env

# Test 13: --force flag triggers init
test_case "--force flag triggers init even when .claude exists"
setup_test_env
mkdir -p .claude
setup_mock_scripts "$SCRIPT_DIR"
output=$("$SCRIPT_DIR/sw-quickstart.sh" --force --skip-prep --skip-doctor 2>&1)
exit_code=$?
# With --force, init should run even if .claude exists
if echo "$output" | grep -q "init\|Mock init"; then
    echo -e "  ${GREEN}✓${RESET} Init should run with --force"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}✗${RESET} Init should run with --force"
    FAIL=$((FAIL + 1))
fi
cleanup_test_env

# Test 14: Unknown option exits with error
test_case "unknown option returns non-zero exit code"
setup_test_env
exit_code=0
output=$("$SCRIPT_DIR/sw-quickstart.sh" --unknown-flag 2>&1) || exit_code=$?
assert_exit_code 1 $exit_code "Unknown flag should exit with 1"
assert_contains "$output" "Unknown option" "Error message should be shown"
cleanup_test_env

# Test 15: No phases to run when all skipped
test_case "no phases when all --skip flags set"
setup_test_env
mkdir -p .claude
setup_mock_scripts "$SCRIPT_DIR"
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-init --skip-prep --skip-doctor 2>&1)
exit_code=$?
# Should return 0 because skipping all is valid
assert_exit_code 0 $exit_code "All skip flags should exit with 0"
cleanup_test_env

# Test 16: Idempotent: skips init when .claude exists
test_case "idempotent: skips init when .claude exists (no --force)"
setup_test_env
mkdir -p .claude
setup_mock_scripts "$SCRIPT_DIR"
output=$("$SCRIPT_DIR/sw-quickstart.sh" --skip-prep --skip-doctor 2>&1)
exit_code=$?
# Without --force and .claude exists, init should be skipped
assert_not_contains "$output" "Mock init" "Init should not run when .claude exists"
cleanup_test_env

# ─────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────

echo ""
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}Test Summary${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo -e "Tests run: ${CYAN}${TESTS_RUN}${RESET}"
echo -e "Passed:    ${GREEN}${PASS}${RESET}"
echo -e "Failed:    ${RED}${FAIL}${RESET}"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✓ All tests passed!${RESET}"
    exit 0
else
    echo -e "${RED}${BOLD}✗ Some tests failed.${RESET}"
    exit 1
fi
