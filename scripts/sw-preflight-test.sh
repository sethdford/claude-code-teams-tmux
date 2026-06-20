#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-preflight-test.sh — Pre-Flight Health Validator Test Suite            ║
# ║                                                                          ║
# ║  Tests the environment health validator with MOCKED conditions only —    ║
# ║  no real disk consumption, no real GitHub API calls, no network I/O.     ║
# ║  Mocks are installed by overriding the lib's _preflight_* probe getters. ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# errexit intentionally OFF: many tests assert that a check returns non-zero.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# Isolate event log writes to a temp dir (no pollution of ~/.shipwright).
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sw-preflight-test.XXXXXX")"
export HOME="$TEST_TMP"
export EVENTS_FILE="$TEST_TMP/events.jsonl"
trap 'rm -rf "$TEST_TMP"' EXIT

# ─── Test helpers ───────────────────────────────────────────────────────────
ok()   { PASS=$((PASS+1)); echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $1"; }
no()   { FAIL=$((FAIL+1)); echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $1"; }

assert_pass() { if [[ "$1" -eq 0 ]]; then ok "$2"; else no "$2 (expected pass, got $1)"; fi; }
assert_fail() { if [[ "$1" -ne 0 ]]; then ok "$2"; else no "$2 (expected fail, got $1)"; fi; }
assert_contains() {
    if [[ "$1" == *"$2"* ]]; then ok "$3"; else no "$3 (missing: $2)"; fi
}

# Source the lib under test. Quiet output keeps the test log readable.
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/pipeline-preflight.sh"
PREFLIGHT_QUIET=true

# Sensible default mocks: a healthy environment. Each test overrides as needed.
reset_mocks() {
    _preflight_disk_free_kb()    { echo $(( 50 * 1024 * 1024 )); }  # 50 GB
    _preflight_has_tmux()        { return 0; }
    _preflight_has_curl()        { return 0; }
    _preflight_has_gh()          { return 0; }
    _preflight_claude_ok()       { return 0; }
    _preflight_network_ok()      { return 0; }
    _preflight_github_rate_json(){ echo '{"resources":{"core":{"remaining":4999,"limit":5000,"reset":9999999999}}}'; }
    NO_GITHUB=false
    SHIPWRIGHT_LOCAL=0
    OFFLINE=false
    unset SHIPWRIGHT_PREFLIGHT_MIN_DISK_GB 2>/dev/null || true
}

# ─── Disk space checks ──────────────────────────────────────────────────────
test_disk_healthy() {
    reset_mocks
    check_disk_space; assert_pass $? "disk: 50GB free passes (need 5GB)"
}
test_disk_low() {
    reset_mocks
    _preflight_disk_free_kb() { echo $(( 1 * 1024 * 1024 )); }  # 1 GB
    check_disk_space; assert_fail $? "disk: 1GB free fails (need 5GB)"
}
test_disk_low_message() {
    reset_mocks
    _preflight_disk_free_kb() { echo $(( 1 * 1024 * 1024 )); }
    PREFLIGHT_REASONS=()
    check_disk_space || true
    assert_contains "${PREFLIGHT_REASONS[*]}" "Low disk space" "disk: low-disk reason is actionable"
}
test_disk_nonnumeric_failopen() {
    reset_mocks
    _preflight_disk_free_kb() { echo "n/a"; }
    check_disk_space; assert_pass $? "disk: non-numeric df output fails open (no block)"
}
test_disk_config_override() {
    reset_mocks
    _preflight_disk_free_kb() { echo $(( 3 * 1024 * 1024 )); }  # 3 GB
    SHIPWRIGHT_PREFLIGHT_MIN_DISK_GB=2  # require only 2GB via env override
    check_disk_space; assert_pass $? "disk: config override lowers threshold to 2GB"
    unset SHIPWRIGHT_PREFLIGHT_MIN_DISK_GB
}

# ─── tmux checks (warn-only) ────────────────────────────────────────────────
test_tmux_present() {
    reset_mocks
    check_tmux; assert_pass $? "tmux: present passes"
}
test_tmux_missing_nonblocking() {
    reset_mocks
    _preflight_has_tmux() { return 1; }
    check_tmux; assert_pass $? "tmux: missing is warn-only (never blocks)"
}

# ─── Network checks ─────────────────────────────────────────────────────────
test_network_up() {
    reset_mocks
    check_network; assert_pass $? "network: reachable passes"
}
test_network_down() {
    reset_mocks
    _preflight_network_ok() { return 1; }
    check_network; assert_fail $? "network: unreachable fails"
}
test_network_skipped_local() {
    reset_mocks
    _preflight_network_ok() { return 1; }  # would fail, but local mode skips
    NO_GITHUB=true
    check_network; assert_pass $? "network: skipped in --local/--no-github mode"
}
test_network_no_curl() {
    reset_mocks
    _preflight_has_curl() { return 1; }
    check_network; assert_pass $? "network: missing curl warns (no block)"
}

# ─── GitHub rate-limit checks ───────────────────────────────────────────────
test_github_healthy() {
    reset_mocks
    check_github_rate_limit; assert_pass $? "github: 4999 remaining passes"
}
test_github_rate_limited() {
    reset_mocks
    _preflight_github_rate_json() { echo '{"resources":{"core":{"remaining":3,"limit":5000,"reset":9999999999}}}'; }
    check_github_rate_limit; assert_fail $? "github: 3 remaining fails (threshold 10)"
}
test_github_rate_limited_message() {
    reset_mocks
    _preflight_github_rate_json() { echo '{"resources":{"core":{"remaining":3,"limit":5000,"reset":9999999999}}}'; }
    PREFLIGHT_REASONS=()
    check_github_rate_limit || true
    assert_contains "${PREFLIGHT_REASONS[*]}" "retry in" "github: rate-limit reason has retry-in-N-minutes"
}
test_github_failopen_empty() {
    reset_mocks
    _preflight_github_rate_json() { echo ""; }
    check_github_rate_limit; assert_pass $? "github: empty response fails open (no block)"
}
test_github_failopen_garbage() {
    reset_mocks
    _preflight_github_rate_json() { echo '{"unexpected":true}'; }
    check_github_rate_limit; assert_pass $? "github: garbage response fails open (no block)"
}
test_github_skipped_nogithub() {
    reset_mocks
    NO_GITHUB=true
    check_github_rate_limit; assert_pass $? "github: skipped when NO_GITHUB=true"
}
test_github_no_gh_cli() {
    reset_mocks
    _preflight_has_gh() { return 1; }
    check_github_rate_limit; assert_pass $? "github: missing gh CLI warns (no block)"
}

# ─── Claude auth checks ─────────────────────────────────────────────────────
test_claude_present() {
    reset_mocks
    check_claude_auth; assert_pass $? "claude: present passes"
}
test_claude_missing() {
    reset_mocks
    _preflight_claude_ok() { return 1; }
    check_claude_auth; assert_fail $? "claude: missing fails (blocking)"
}

# ─── Orchestrator checks ────────────────────────────────────────────────────
test_orchestrator_healthy() {
    reset_mocks
    preflight_health_check; assert_pass $? "orchestrator: all-healthy passes"
}
test_orchestrator_blocks_on_disk() {
    reset_mocks
    _preflight_disk_free_kb() { echo $(( 1 * 1024 * 1024 )); }
    preflight_health_check; assert_fail $? "orchestrator: blocks on low disk"
}
test_orchestrator_emits_failed_event() {
    reset_mocks
    _preflight_claude_ok() { return 1; }
    : > "$EVENTS_FILE"
    preflight_health_check || true
    local content; content=$(cat "$EVENTS_FILE" 2>/dev/null || echo "")
    assert_contains "$content" "preflight.failed" "orchestrator: emits preflight.failed event"
}
test_orchestrator_emits_passed_event() {
    reset_mocks
    : > "$EVENTS_FILE"
    preflight_health_check || true
    local content; content=$(cat "$EVENTS_FILE" 2>/dev/null || echo "")
    assert_contains "$content" "preflight.passed" "orchestrator: emits preflight.passed event"
}
test_orchestrator_skips_github_when_network_down() {
    reset_mocks
    _preflight_network_ok() { return 1; }
    # GitHub mock would pass, but network-down should short-circuit it.
    preflight_health_check; assert_fail $? "orchestrator: network-down blocks and skips github check"
}

# ─── CLI surface ────────────────────────────────────────────────────────────
test_cli_help() {
    local out; out=$("$SCRIPT_DIR/sw-preflight.sh" --help)
    assert_contains "$out" "USAGE" "cli: --help shows usage"
}
test_cli_version() {
    local out; out=$("$SCRIPT_DIR/sw-preflight.sh" --version)
    if [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then ok "cli: --version shows semver"; else no "cli: --version shows semver"; fi
}
test_cli_unknown_option() {
    local code=0
    "$SCRIPT_DIR/sw-preflight.sh" --bogus >/dev/null 2>&1 || code=$?
    assert_fail "$code" "cli: unknown option exits non-zero"
}
test_cli_json_offline() {
    # In offline/local + missing-tools-tolerant env this should produce JSON.
    local out
    out=$(NO_GITHUB=true SHIPWRIGHT_LOCAL=1 "$SCRIPT_DIR/sw-preflight.sh" --json 2>/dev/null || true)
    assert_contains "$out" '"status"' "cli: --json emits status field"
}

# ─── Run ────────────────────────────────────────────────────────────────────
echo "sw-preflight-test.sh"
test_disk_healthy
test_disk_low
test_disk_low_message
test_disk_nonnumeric_failopen
test_disk_config_override
test_tmux_present
test_tmux_missing_nonblocking
test_network_up
test_network_down
test_network_skipped_local
test_network_no_curl
test_github_healthy
test_github_rate_limited
test_github_rate_limited_message
test_github_failopen_empty
test_github_failopen_garbage
test_github_skipped_nogithub
test_github_no_gh_cli
test_claude_present
test_claude_missing
test_orchestrator_healthy
test_orchestrator_blocks_on_disk
test_orchestrator_emits_failed_event
test_orchestrator_emits_passed_event
test_orchestrator_skips_github_when_network_down
test_cli_help
test_cli_version
test_cli_unknown_option
test_cli_json_offline

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
