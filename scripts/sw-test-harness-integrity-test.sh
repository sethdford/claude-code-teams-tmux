#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright test-harness integrity — Guards the shared assert contract    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Test Harness Integrity"

# ─────────────────────────────────────────────────────────────────────────────
# Why this suite exists
#
# 39 suites once carried a copy-pasted assert_pass/assert_fail that shadowed
# lib/test-helpers.sh. The copies dropped the PASS/FAIL/TOTAL increments, so
# print_test_results — which ends in `exit "$FAIL"` — always saw FAIL=0. Those
# suites printed red ✗ marks and still exited 0: CI was green on red tests.
#
# Shadowing is only safe if the override still maintains the counters, since
# the exit status is derived from them.
# ─────────────────────────────────────────────────────────────────────────────

print_test_section "no suite shadows the harness asserts without counters"

offenders=""
for suite in "$SCRIPT_DIR"/*-test.sh; do
    [[ "$(basename "$suite")" == "$(basename "${BASH_SOURCE[0]}")" ]] && continue
    grep -q 'lib/test-helpers.sh' "$suite" || continue

    for fn in assert_pass assert_fail; do
        # Function-block bodies for this name, at column 0 (heredoc fixture
        # lines in e.g. sw-dod-scorecard-test.sh are indented or one-liners,
        # so the `^name() {` + `^}` anchoring skips them).
        body=$(awk -v fn="$fn" '
            $0 == fn "() {" { inblock = 1 }
            inblock         { print }
            inblock && /^}/ { inblock = 0 }
        ' "$suite")
        [[ -n "$body" ]] || continue

        counter=$([[ "$fn" == "assert_pass" ]] && echo PASS || echo FAIL)
        if ! echo "$body" | grep -q "$counter=\$((\|$counter=\$(( "; then
            offenders="${offenders}$(basename "$suite"):${fn} "
        fi
    done
done

if [[ -z "$offenders" ]]; then
    assert_pass "no suite overrides assert_pass/assert_fail without counters"
else
    assert_fail "no suite overrides assert_pass/assert_fail without counters" \
        "offenders: $offenders"
fi

print_test_section "harness asserts drive the exit status"

# Behavioural check: build a throwaway suite that fails one assertion and
# confirm the harness both counts it and exits non-zero. This is what the
# shadowed copies silently broke.
probe="$TEST_TEMP_DIR/probe-test.sh"
cat > "$probe" <<PROBE
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT_DIR/lib/test-helpers.sh"
assert_pass "ok"
assert_fail "deliberate" "detail arg present"
print_test_results
PROBE

probe_out=$(bash "$probe" 2>&1) && probe_rc=0 || probe_rc=$?

assert_eq "a failing assertion exits non-zero" "1" "$probe_rc"
assert_contains "results report the failure" "$probe_out" "1 of 2 tests failed"

# A failing assert with no detail argument must not abort the run early: the
# trailing `[[ -n "$detail" ]] && echo` returns 1, which under `set -e` used to
# kill the suite before print_test_results could report anything.
probe2="$TEST_TEMP_DIR/probe2-test.sh"
cat > "$probe2" <<PROBE2
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT_DIR/lib/test-helpers.sh"
assert_fail "deliberate, no detail"
print_test_results
PROBE2

probe2_out=$(bash "$probe2" 2>&1) && probe2_rc=0 || probe2_rc=$?

assert_eq "detail-less failure still reaches the summary" "1" "$probe2_rc"
assert_contains "detail-less failure is counted" "$probe2_out" "1 of 1 tests failed"

print_test_results
