#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-merge-conflict-test — Unit tests for merge-conflict.sh library       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

LIB="$SCRIPT_DIR/lib/merge-conflict.sh"
ORIG_PWD="$(pwd)"

# Each test runs in a fresh ephemeral repo. We avoid `(...)` subshells so the
# PASS/FAIL counters from test-helpers.sh propagate up to print_test_results.
make_repo() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/sw-mc-repo.XXXXXX")
    git -C "$dir" init -q -b main 2>/dev/null || git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
    printf '%s\n' "$dir"
}

reload_lib() {
    unset _MERGE_CONFLICT_LOADED _MC_TRAP_INSTALLED _MC_TEMP_WORKTREES _MC_LAST_WORKTREE
    # shellcheck disable=SC1090
    source "$LIB"
}

cleanup_repo() {
    cd "$ORIG_PWD"
    [[ -n "${1:-}" && -d "$1" ]] && rm -rf "$1"
}

print_test_header "merge-conflict library"

# ─── Test 1: clean merge prediction ──────────────────────────────────────────
test_clean_merge() {
    local repo; repo=$(make_repo)
    cd "$repo"
    echo "hello" > a.txt
    git add a.txt; git commit -q -m "base"
    local default_branch; default_branch=$(git symbolic-ref --short HEAD)
    git branch feat
    echo "world" > b.txt
    git add b.txt; git commit -q -m "default add b"
    git checkout -q feat
    echo "feature" > c.txt
    git add c.txt; git commit -q -m "feat add c"
    reload_lib
    local out="$repo/pred.json"
    local rc=0
    mc_predict "$default_branch" feat --out "$out" >/dev/null 2>&1 || rc=$?
    assert_eq "mc_predict returns 0 on clean merge" "0" "$rc"
    if [[ -f "$out" ]]; then
        assert_eq "prediction.clean=true" "true" "$(jq -r '.clean' "$out")"
        assert_eq "prediction.conflict_count=0" "0" "$(jq -r '.conflict_count' "$out")"
    else
        assert_fail "prediction file written" "missing $out"
    fi
    cleanup_repo "$repo"
}

# ─── Test 2: conflict prediction ─────────────────────────────────────────────
test_conflict_prediction() {
    local repo; repo=$(make_repo)
    cd "$repo"
    printf 'line1\nline2\nline3\n' > x.txt
    git add x.txt; git commit -q -m "base"
    local default_branch; default_branch=$(git symbolic-ref --short HEAD)
    git branch feat
    printf 'CHANGED\nline2\nline3\n' > x.txt
    git add x.txt; git commit -q -m "default change"
    git checkout -q feat
    printf 'OTHER\nline2\nline3\n' > x.txt
    git add x.txt; git commit -q -m "feat change"
    reload_lib
    local out="$repo/pred.json"
    local rc=0
    mc_predict "$default_branch" feat --out "$out" >/dev/null 2>&1 || rc=$?
    assert_eq "mc_predict returns 1 on conflict" "1" "$rc"
    if [[ -f "$out" ]]; then
        assert_eq "prediction.clean=false" "false" "$(jq -r '.clean' "$out")"
        local count=$(($(jq -r '.conflict_count' "$out") + 0))
        if [[ "$count" -ge 1 ]]; then
            assert_pass "prediction.conflict_count >= 1"
        else
            assert_fail "prediction.conflict_count >= 1" "got=$count"
        fi
    fi
    cleanup_repo "$repo"
}

# ─── Test 3: invalid ref returns 2 ───────────────────────────────────────────
test_invalid_ref() {
    local repo; repo=$(make_repo)
    cd "$repo"
    echo "x" > a; git add a; git commit -q -m "init"
    reload_lib
    local rc=0
    mc_predict nonexistent-base nonexistent-head >/dev/null 2>&1 || rc=$?
    assert_eq "mc_predict returns 2 on invalid ref" "2" "$rc"
    cleanup_repo "$repo"
}

# ─── Test 4: auto-resolve recursive (line-disjoint) ──────────────────────────
test_auto_resolve_disjoint() {
    local repo; repo=$(make_repo)
    cd "$repo"
    printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > f.txt
    git add f.txt; git commit -q -m "base"
    local default_branch; default_branch=$(git symbolic-ref --short HEAD)
    git branch feat
    printf 'TOP\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > f.txt
    git add f.txt; git commit -q -m "top"
    git checkout -q feat
    printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nBOTTOM\n' > f.txt
    git add f.txt; git commit -q -m "bottom"
    reload_lib
    local out="$repo/res.json"
    local rc=0
    mc_auto_resolve "$default_branch" feat --strategies "recursive,patience" --out "$out" >/dev/null 2>&1 || rc=$?
    assert_eq "mc_auto_resolve returns 0 on disjoint conflict" "0" "$rc"
    if [[ -f "$out" ]]; then
        assert_eq "resolution.resolved=true" "true" "$(jq -r '.resolved' "$out")"
        local strategy=$(jq -r '.strategy' "$out")
        if [[ -n "$strategy" && "$strategy" != "null" && "$strategy" != "" ]]; then
            assert_pass "resolution.strategy populated ($strategy)"
        else
            assert_fail "resolution.strategy populated" "got=$strategy"
        fi
    fi
    cleanup_repo "$repo"
}

# ─── Test 5: aggressive strategy skipped on lockfile ─────────────────────────
test_lockfile_skip() {
    local repo; repo=$(make_repo)
    cd "$repo"
    echo '{"v":1}' > package-lock.json
    git add package-lock.json; git commit -q -m "base"
    local default_branch; default_branch=$(git symbolic-ref --short HEAD)
    git branch feat
    echo '{"v":2}' > package-lock.json
    git add package-lock.json; git commit -q -m "default"
    git checkout -q feat
    echo '{"v":3}' > package-lock.json
    git add package-lock.json; git commit -q -m "feat"
    reload_lib
    local out="$repo/res.json"
    mc_auto_resolve "$default_branch" feat --strategies "ours,theirs" --out "$out" >/dev/null 2>&1 || true
    local skipped=$(jq -r '[.attempts[] | select(.status=="skipped" and .reason=="unsafe_for_aggressive")] | length' "$out")
    if [[ "${skipped:-0}" -ge 1 ]]; then
        assert_pass "lockfile triggers skip of aggressive strategies"
    else
        assert_fail "lockfile triggers skip" "skipped=$skipped"
    fi
    cleanup_repo "$repo"
}

# ─── Test 6: legacy fallback path via MC_FORCE_LEGACY=1 ──────────────────────
test_legacy_fallback() {
    local repo; repo=$(make_repo)
    cd "$repo"
    echo "v1" > z.txt
    git add z.txt; git commit -q -m "base"
    local default_branch; default_branch=$(git symbolic-ref --short HEAD)
    git branch feat
    echo "default-side" > z.txt
    git add z.txt; git commit -q -m "default"
    git checkout -q feat
    echo "feat-side" > z.txt
    git add z.txt; git commit -q -m "feat"
    export MC_FORCE_LEGACY=1
    reload_lib
    local out="$repo/pred.json"
    local rc=0
    mc_predict "$default_branch" feat --out "$out" >/dev/null 2>&1 || rc=$?
    unset MC_FORCE_LEGACY
    assert_eq "legacy path returns 1 on conflict" "1" "$rc"
    if [[ -f "$out" ]]; then
        assert_eq "method=legacy-worktree" "legacy-worktree" "$(jq -r '.method' "$out")"
    fi
    cleanup_repo "$repo"
}

# ─── Test 7: report and guided fallback artifact generation ──────────────────
test_report_and_guided() {
    local repo; repo=$(make_repo)
    cd "$repo"
    echo "a" > p.txt
    git add p.txt; git commit -q -m "base"
    local default_branch; default_branch=$(git symbolic-ref --short HEAD)
    git branch feat
    echo "x" > p.txt; git add p.txt; git commit -q -m "default"
    git checkout -q feat
    echo "y" > p.txt; git add p.txt; git commit -q -m "feat"
    reload_lib
    local pred="$repo/pred.json" res="$repo/res.json"
    mc_predict "$default_branch" feat --out "$pred" >/dev/null 2>&1 || true
    mc_auto_resolve "$default_branch" feat --strategies "recursive" --out "$res" >/dev/null 2>&1 || true

    local rep="$repo/report.json"
    mc_report "$pred" "$res" --out "$rep" >/dev/null 2>&1
    if [[ -s "$rep" ]] && jq -e '.summary' "$rep" >/dev/null 2>&1; then
        assert_pass "mc_report writes valid JSON with .summary"
    else
        assert_fail "mc_report writes JSON" "no .summary"
    fi

    local guide="$repo/guide.md"
    mc_guided_fallback "$pred" --out "$guide" >/dev/null 2>&1
    if [[ -s "$guide" ]] && grep -q "Guided Merge" "$guide"; then
        assert_pass "mc_guided_fallback writes markdown"
    else
        assert_fail "mc_guided_fallback markdown" "missing or empty"
    fi
    cleanup_repo "$repo"
}

# ─── Test 8: working tree stays clean after operations ───────────────────────
test_working_tree_clean() {
    local repo; repo=$(make_repo)
    cd "$repo"
    echo "a" > q.txt
    git add q.txt; git commit -q -m "base"
    local default_branch; default_branch=$(git symbolic-ref --short HEAD)
    git branch feat
    echo "DEFAULT" > q.txt; git add q.txt; git commit -q -m "default"
    git checkout -q feat
    echo "FEAT" > q.txt; git add q.txt; git commit -q -m "feat"
    reload_lib
    mc_predict "$default_branch" feat >/dev/null 2>&1 || true
    mc_auto_resolve "$default_branch" feat --strategies recursive >/dev/null 2>&1 || true
    _mc_cleanup_worktrees
    local status=$(git status --porcelain)
    if [[ -z "$status" ]]; then
        assert_pass "working tree clean after mc_* calls"
    else
        assert_fail "working tree clean" "status=$status"
    fi
    cleanup_repo "$repo"
}

test_clean_merge
test_conflict_prediction
test_invalid_ref
test_auto_resolve_disjoint
test_lockfile_skip
test_legacy_fallback
test_report_and_guided
test_working_tree_clean

print_test_results
