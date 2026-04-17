#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  conflict-predictor unit tests                                            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-conflict-predictor-test.XXXXXX")
    # Build a fake git repo so git ls-files has something to return.
    (
        cd "$TEST_DIR"
        git init -q
        mkdir -p scripts/lib
        : > scripts/sw-cost.sh
        : > scripts/lib/file-locks.sh
        : > README.md
        git add -A >/dev/null 2>&1
        git -c user.email=t@t.co -c user.name=test commit -qm init >/dev/null 2>&1
    )
    cd "$TEST_DIR"
    unset _CONFLICT_PREDICTOR_LOADED _PREDICTOR_TRACKED_CACHE
    source "$SCRIPT_DIR/lib/conflict-predictor.sh"
}

cleanup_env() {
    cd /
    [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}
trap cleanup_env EXIT

setup_env

echo "═══ conflict-predictor unit tests ═══"

# Test 1: exact tracked path is returned
out=$(predict_pipeline_files "Fix scripts/sw-cost.sh bug" "")
assert_contains "exact_path_matched" "scripts/sw-cost.sh" "$out"

# Test 2: basename match resolves to tracked path
out=$(predict_pipeline_files "Fix file-locks.sh" "update logic")
assert_contains "basename_matched" "scripts/lib/file-locks.sh" "$out"

# Test 3: unknown paths are dropped
out=$(predict_pipeline_files "Fix totally/made/up/path.sh" "" || true)
if [[ -z "$out" ]]; then
    assert_pass "unknown_path_dropped"
else
    assert_fail "unknown_path_dropped" "got: $out"
fi

# Test 4: empty input returns empty output
out=$(predict_pipeline_files "" "" || true)
if [[ -z "$out" ]]; then
    assert_pass "empty_input_empty_output"
else
    assert_fail "empty_input_empty_output" "got: $out"
fi

# Test 5: output is sorted
out=$(predict_pipeline_files "Touch README.md and scripts/sw-cost.sh and scripts/lib/file-locks.sh" "")
sorted=$(printf '%s' "$out" | sort -c 2>&1 || echo "unsorted")
assert_eq "output_sorted" "" "$sorted"

# Test 6: extractor is safe on noisy text with URLs
out=$(predict_pipeline_files "See https://example.com/foo.sh for details and fix scripts/sw-cost.sh" "")
assert_contains "noise_resilient" "scripts/sw-cost.sh" "$out"
if printf '%s' "$out" | grep -q "example.com"; then
    assert_fail "urls_dropped" "URL leaked: $out"
else
    assert_pass "urls_dropped"
fi

# Test 7: MAX_FILES cap respected
export CONFLICT_PREDICT_MAX_FILES=1
out=$(predict_pipeline_files "Touch README.md scripts/sw-cost.sh scripts/lib/file-locks.sh" "")
count=$(printf '%s' "$out" | grep -c . || echo 0)
assert_eq "max_files_cap" "1" "$count"
unset CONFLICT_PREDICT_MAX_FILES

print_test_results
