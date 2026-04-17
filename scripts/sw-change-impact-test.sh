#!/usr/bin/env bash
# sw-change-impact-test.sh — Unit tests for change-impact.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/change-impact.sh"

PASS=0
FAIL=0
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
RESET='\033[0m'

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${RESET} $1"; [[ -n "${2:-}" ]] && echo "    $2"; }
assert_eq() {
    if [[ "$1" == "$2" ]]; then pass "$3"
    else fail "$3" "expected=$1 actual=$2"; fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Create a fake "git" that emits a controlled file list.
# We make a PATH-shim and set it for each scenario.
_setup_scenario() {
    local scenario_dir="$TMPROOT/$1"
    local files="$2"
    mkdir -p "$scenario_dir/bin" "$scenario_dir/artifacts"
    cat > "$scenario_dir/bin/git" <<EOF
#!/usr/bin/env bash
# Mock git — respond to diff --name-only
if [[ "\$1" == "diff" && "\$2" == "--name-only" ]]; then
    printf '%s\n' $files
    exit 0
fi
exit 0
EOF
    chmod +x "$scenario_dir/bin/git"
    echo "$scenario_dir"
}

_run_classify() {
    local dir="$1"
    (
        export PATH="$dir/bin:$PATH"
        export ARTIFACTS_DIR="$dir/artifacts"
        export BASE_BRANCH="main"
        # shellcheck disable=SC1090
        source "$LIB"
        classify_change_impact main
    )
}

# ─── T1: docs-only ───
sc=$(_setup_scenario docs '"README.md" "docs/guide.md"')
cat=$(_run_classify "$sc")
assert_eq "docs" "$cat" "docs-only → category=docs"

# ─── T2: tests-only ───
sc=$(_setup_scenario tests '"scripts/sw-foo-test.sh" "tests/unit.js"')
cat=$(_run_classify "$sc")
assert_eq "tests" "$cat" "tests-only → category=tests"

# ─── T3: config-only ───
sc=$(_setup_scenario config '"package.json" ".github/workflows/ci.yml"')
cat=$(_run_classify "$sc")
assert_eq "config" "$cat" "config-only → category=config"

# ─── T4: code-only ───
sc=$(_setup_scenario code '"scripts/sw-foo.sh" "src/index.js"')
cat=$(_run_classify "$sc")
assert_eq "code" "$cat" "code-only → category=code"

# ─── T5: mixed ───
sc=$(_setup_scenario mixed '"README.md" "src/index.js"')
cat=$(_run_classify "$sc")
assert_eq "mixed" "$cat" "docs+code → category=mixed"

# ─── T6: empty diff ───
sc=$(_setup_scenario empty '')
cat=$(_run_classify "$sc")
assert_eq "unknown" "$cat" "empty diff → category=unknown"

# ─── T7: JSON artifact written ───
sc=$(_setup_scenario artifact '"docs/a.md"')
_run_classify "$sc" > /dev/null
if [[ -f "$sc/artifacts/change-impact.json" ]] && \
   [[ "$(jq -r .category "$sc/artifacts/change-impact.json")" == "docs" ]]; then
    pass "change-impact.json written atomically with correct category"
else
    fail "change-impact.json written atomically with correct category"
fi

# ─── Helpers for should_skip tests ───
_run_should_skip() {
    local dir="$1" stage="$2" env_line="${3:-}"
    (
        export PATH="$dir/bin:$PATH"
        export ARTIFACTS_DIR="$dir/artifacts"
        export BASE_BRANCH="main"
        [[ -n "$env_line" ]] && eval "$env_line"
        # shellcheck disable=SC1090
        source "$LIB"
        classify_change_impact main > /dev/null
        change_impact_should_skip "$stage"
    )
}

# ─── T8: docs → skip test stage ───
sc=$(_setup_scenario docs_skip '"README.md"')
reason=$(_run_should_skip "$sc" test || true)
assert_eq "change-impact:docs" "$reason" "docs category skips 'test' stage"

# ─── T9: code → never skip any stage ───
sc=$(_setup_scenario code_noskip '"src/index.js"')
if ! _run_should_skip "$sc" test > /dev/null 2>&1; then
    pass "code category does not skip test stage"
else
    fail "code category does not skip test stage"
fi

# ─── T10: intake never skipped ───
sc=$(_setup_scenario intake_guard '"README.md"')
if ! _run_should_skip "$sc" intake > /dev/null 2>&1; then
    pass "intake stage is never skipped (hardcoded guard)"
else
    fail "intake stage is never skipped (hardcoded guard)"
fi

# ─── T11: build never skipped ───
sc=$(_setup_scenario build_guard '"README.md"')
if ! _run_should_skip "$sc" build > /dev/null 2>&1; then
    pass "build stage is never skipped (hardcoded guard)"
else
    fail "build stage is never skipped (hardcoded guard)"
fi

# ─── T12: SW_NO_SKIP=1 kill switch ───
sc=$(_setup_scenario killswitch '"README.md"')
if ! _run_should_skip "$sc" test 'export SW_NO_SKIP=1' > /dev/null 2>&1; then
    pass "SW_NO_SKIP=1 disables all skipping"
else
    fail "SW_NO_SKIP=1 disables all skipping"
fi

# ─── T13: mixed → no skip ───
sc=$(_setup_scenario mixed_noskip '"README.md" "src/index.js"')
if ! _run_should_skip "$sc" test > /dev/null 2>&1; then
    pass "mixed category does not skip any stage"
else
    fail "mixed category does not skip any stage"
fi

# ─── T14: tests category skips deploy ───
sc=$(_setup_scenario tests_skip_deploy '"scripts/sw-x-test.sh"')
reason=$(_run_should_skip "$sc" deploy || true)
assert_eq "change-impact:tests" "$reason" "tests category skips 'deploy' stage"

# ─── T15: tests category does not skip 'test' stage ───
sc=$(_setup_scenario tests_noskip_test '"scripts/sw-x-test.sh"')
if ! _run_should_skip "$sc" test > /dev/null 2>&1; then
    pass "tests category does not skip 'test' stage (tests must run)"
else
    fail "tests category does not skip 'test' stage"
fi

# ─── Summary ───
echo ""
echo "─────────────────────────────────────────────────────────"
echo -e "  ${GREEN}PASS: $PASS${RESET}    ${RED}FAIL: $FAIL${RESET}"
echo "─────────────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
