#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pre-build-validate test — fast-fail dependency health check    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

# Stub pipeline helpers the module expects (normally from helpers.sh).
info()    { :; }
success() { :; }
warn()    { :; }
error()   { :; }
emit_event() { :; }

# Source the module under test.
source "$SCRIPT_DIR/lib/pipeline-stages-prebuild.sh"

trap cleanup_test_env EXIT

print_test_header "Shipwright Pre-Build Validate Tests"

# Fresh fixture repo per test; returns its path.
new_repo() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/pbv-repo.XXXXXX")
    echo "$d"
}

# Helper: run a single check fn, capture return code without tripping set -e.
run_check() {
    _PBV_FINDINGS=()
    local rc=0
    "$@" || rc=$?
    echo "$rc"
}

# ─── Check 1: manifest syntax ─────────────────────────────────────────────────
print_test_section "Manifest syntax"

repo=$(new_repo)
echo '{"name":"x","version":"1.0.0"}' > "$repo/package.json"
rc=$(run_check _pbv_manifest "$repo")
[[ "$rc" == "0" ]] && assert_pass "valid package.json → pass (0)" || assert_fail "valid package.json → pass (0)" "got rc=$rc"

repo=$(new_repo)
printf '{"name": "x", \n  "version": }\n' > "$repo/package.json"
_PBV_FINDINGS=(); rc=0; _pbv_manifest "$repo" || rc=$?
[[ "$rc" == "1" ]] && assert_pass "malformed package.json → fail (1)" || assert_fail "malformed package.json → fail (1)" "got rc=$rc"
[[ "${_PBV_FINDINGS[0]}" == *'"location":"package.json'* ]] && assert_pass "malformed manifest reports a location" || assert_fail "malformed manifest reports a location" "${_PBV_FINDINGS[0]:-none}"

repo=$(new_repo)
rc=$(run_check _pbv_manifest "$repo")
[[ "$rc" == "2" ]] && assert_pass "no manifest → not-applicable (2)" || assert_fail "no manifest → not-applicable (2)" "got rc=$rc"

repo=$(new_repo)
printf 'requests==2.0\nflask>=1.0  # ok comment\n' > "$repo/requirements.txt"
rc=$(run_check _pbv_manifest "$repo")
[[ "$rc" == "0" ]] && assert_pass "valid requirements.txt → pass (0)" || assert_fail "valid requirements.txt → pass (0)" "got rc=$rc"

repo=$(new_repo)
printf 'requests == 2.0 extra junk here\n' > "$repo/requirements.txt"
_PBV_FINDINGS=(); rc=0; _pbv_manifest "$repo" || rc=$?
[[ "$rc" == "1" ]] && assert_pass "malformed requirements.txt → fail (1)" || assert_fail "malformed requirements.txt → fail (1)" "got rc=$rc"

# ─── Check 2: lock file ───────────────────────────────────────────────────────
print_test_section "Lock file integrity"

repo=$(new_repo)
echo '{"name":"x"}' > "$repo/package.json"
echo '{"lockfileVersion":3}' > "$repo/package-lock.json"
rc=$(run_check _pbv_lockfile "$repo")
[[ "$rc" == "0" ]] && assert_pass "valid package-lock.json → pass (0)" || assert_fail "valid package-lock.json → pass (0)" "got rc=$rc"

repo=$(new_repo)
echo '{"name":"x"}' > "$repo/package.json"
rc=$(run_check _pbv_lockfile "$repo")
[[ "$rc" == "2" ]] && assert_pass "manifest without lock → skipped (2, non-blocking)" || assert_fail "manifest without lock → skipped (2)" "got rc=$rc"

repo=$(new_repo)
echo '{"name":"x"}' > "$repo/package.json"
echo 'not json {' > "$repo/package-lock.json"
_PBV_FINDINGS=(); rc=0; _pbv_lockfile "$repo" || rc=$?
[[ "$rc" == "1" ]] && assert_pass "corrupt package-lock.json → fail (1)" || assert_fail "corrupt package-lock.json → fail (1)" "got rc=$rc"

repo=$(new_repo)
echo '{"name":"x"}' > "$repo/package.json"
: > "$repo/yarn.lock"
_PBV_FINDINGS=(); rc=0; _pbv_lockfile "$repo" || rc=$?
[[ "$rc" == "1" ]] && assert_pass "empty yarn.lock → fail (1)" || assert_fail "empty yarn.lock → fail (1)" "got rc=$rc"

# ─── Check 3: test runner ─────────────────────────────────────────────────────
print_test_section "Test command discoverability"

repo=$(new_repo)
rc=$(TEST_CMD="bash -c true" run_check _pbv_test_runner "$repo")
[[ "$rc" == "0" ]] && assert_pass "runner in PATH (bash) → pass (0)" || assert_fail "runner in PATH → pass (0)" "got rc=$rc"

repo=$(new_repo)
PIPELINE_CONFIG=""; _PBV_FINDINGS=(); rc=0
TEST_CMD="definitely-not-a-real-binary-xyz test" _pbv_test_runner "$repo" || rc=$?
[[ "$rc" == "1" ]] && assert_pass "missing runner → fail (1)" || assert_fail "missing runner → fail (1)" "got rc=$rc"

repo=$(new_repo)
PIPELINE_CONFIG=""; rc=$(TEST_CMD="" run_check _pbv_test_runner "$repo")
[[ "$rc" == "2" ]] && assert_pass "no test command → not-applicable (2)" || assert_fail "no test command → not-applicable (2)" "got rc=$rc"

# ─── Check 4: lint (opt-in) ───────────────────────────────────────────────────
print_test_section "Lint (opt-in)"

repo=$(new_repo)
echo '{"name":"x"}' > "$repo/package.json"
rc=$(run_check _pbv_lint "$repo" "false")
[[ "$rc" == "2" ]] && assert_pass "lint disabled → skipped (2)" || assert_fail "lint disabled → skipped (2)" "got rc=$rc"

repo=$(new_repo)
echo '{"name":"x","scripts":{"build":"true"}}' > "$repo/package.json"
rc=$(run_check _pbv_lint "$repo" "true")
[[ "$rc" == "2" ]] && assert_pass "lint enabled but no lint script → skipped (2)" || assert_fail "lint enabled, no script → skipped (2)" "got rc=$rc"

# ─── Check 5: git state ───────────────────────────────────────────────────────
print_test_section "Git state"

repo=$(new_repo)
rc=$(run_check _pbv_git_state "$repo" "false")
[[ "$rc" == "2" ]] && assert_pass "non-git dir → not-applicable (2)" || assert_fail "non-git dir → not-applicable (2)" "got rc=$rc"

if command -v git >/dev/null 2>&1; then
    repo=$(new_repo)
    ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && echo "clean" > a.txt && git add a.txt && git commit -qm init )
    rc=$(run_check _pbv_git_state "$repo" "false")
    [[ "$rc" == "0" ]] && assert_pass "clean tracked repo → pass (0)" || assert_fail "clean repo → pass (0)" "got rc=$rc"

    repo=$(new_repo)
    ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t
      printf 'line\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> branch\n' > conflict.txt
      git add conflict.txt && git commit -qm init )
    _PBV_FINDINGS=(); rc=0; _pbv_git_state "$repo" "false" || rc=$?
    [[ "$rc" == "1" ]] && assert_pass "tracked conflict markers → fail (1)" || assert_fail "conflict markers → fail (1)" "got rc=$rc"

    repo=$(new_repo)
    ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t
      echo "v1" > a.txt && git add a.txt && git commit -qm init && echo "v2" > a.txt )
    rc=$(run_check _pbv_git_state "$repo" "false")
    [[ "$rc" == "0" ]] && assert_pass "dirty worktree, fail_on_dirty=false → pass (0)" || assert_fail "dirty + flag false → pass" "got rc=$rc"
    _PBV_FINDINGS=(); rc=0; _pbv_git_state "$repo" "true" || rc=$?
    [[ "$rc" == "1" ]] && assert_pass "dirty worktree, fail_on_dirty=true → fail (1)" || assert_fail "dirty + flag true → fail" "got rc=$rc"
else
    warn "git not available — skipping git-state assertions"
fi

# ─── Check 6: required env vars ───────────────────────────────────────────────
print_test_section "Required env vars"

repo=$(new_repo)
rc=$(run_check _pbv_env_required "$repo" ".env.required")
[[ "$rc" == "2" ]] && assert_pass "no .env.required → not-applicable (2)" || assert_fail "no env file → not-applicable (2)" "got rc=$rc"

repo=$(new_repo)
printf 'PBV_TEST_PRESENT\n# a comment\n' > "$repo/.env.required"
rc=$(PBV_TEST_PRESENT=yes run_check _pbv_env_required "$repo" ".env.required")
[[ "$rc" == "0" ]] && assert_pass "present env var → pass (0)" || assert_fail "present env var → pass (0)" "got rc=$rc"

repo=$(new_repo)
printf 'PBV_TEST_MISSING_XYZ\n' > "$repo/.env.required"
unset PBV_TEST_MISSING_XYZ 2>/dev/null || true   # PBV_TEST_MISSING_XYZ is never set in this env
_PBV_FINDINGS=(); rc=0; _pbv_env_required "$repo" ".env.required" || rc=$?
[[ "$rc" == "1" ]] && assert_pass "missing env var → fail (1)" || assert_fail "missing env var → fail (1)" "got rc=$rc"
# Secret-safety: only the NAME appears, never a value (findings buffer from the call above).
[[ "${_PBV_FINDINGS[0]:-}" == *"PBV_TEST_MISSING_XYZ"* ]] && assert_pass "missing-var finding lists the name" || assert_fail "missing-var finding lists the name" "${_PBV_FINDINGS[0]:-none}"

# ─── Orchestrator ─────────────────────────────────────────────────────────────
print_test_section "Orchestrator (stage_pre_build_validate)"

# Dispatch convention: the function the engine calls must exist.
type stage_pre_build_validate >/dev/null 2>&1 && assert_pass "stage_pre_build_validate is defined" || assert_fail "stage_pre_build_validate is defined"

# Happy path: valid project → exit 0, artifact verdict pass.
repo=$(new_repo)
echo '{"name":"x","version":"1.0.0"}' > "$repo/package.json"
echo '{"lockfileVersion":3}' > "$repo/package-lock.json"
art="$repo/.claude/pipeline-artifacts"
rc=0
( PROJECT_ROOT="$repo" ARTIFACTS_DIR="$art" PIPELINE_CONFIG="" TEST_CMD="bash -c true" SKIP_PREBUILD_VALIDATE=false \
  stage_pre_build_validate ) || rc=$?
[[ "$rc" == "0" ]] && assert_pass "happy path → exit 0" || assert_fail "happy path → exit 0" "got rc=$rc"
if [[ -f "$art/prebuild-validate.json" ]]; then
    v=$(jq -r '.verdict' "$art/prebuild-validate.json" 2>/dev/null || echo "?")
    [[ "$v" == "pass" ]] && assert_pass "artifact verdict=pass" || assert_fail "artifact verdict=pass" "got $v"
    jq empty "$art/prebuild-validate.json" 2>/dev/null && assert_pass "artifact is valid JSON" || assert_fail "artifact is valid JSON"
else
    assert_fail "artifact written" "missing $art/prebuild-validate.json"
fi

# Fast-fail: malformed manifest → exit 1, verdict fail.
repo=$(new_repo)
printf '{ bad json\n' > "$repo/package.json"
art="$repo/.claude/pipeline-artifacts"
rc=0
( PROJECT_ROOT="$repo" ARTIFACTS_DIR="$art" PIPELINE_CONFIG="" TEST_CMD="bash -c true" SKIP_PREBUILD_VALIDATE=false \
  stage_pre_build_validate ) || rc=$?
[[ "$rc" == "1" ]] && assert_pass "malformed manifest → exit 1 (fast-fail)" || assert_fail "malformed manifest → exit 1" "got rc=$rc"
[[ "$(jq -r '.verdict' "$art/prebuild-validate.json" 2>/dev/null)" == "fail" ]] && assert_pass "fast-fail artifact verdict=fail" || assert_fail "fast-fail artifact verdict=fail"

# Skip flag: SKIP_PREBUILD_VALIDATE=true → exit 0, verdict skipped, no checks.
repo=$(new_repo)
printf '{ bad json\n' > "$repo/package.json"   # would fail, but skipped
art="$repo/.claude/pipeline-artifacts"
rc=0
( PROJECT_ROOT="$repo" ARTIFACTS_DIR="$art" PIPELINE_CONFIG="" SKIP_PREBUILD_VALIDATE=true \
  stage_pre_build_validate ) || rc=$?
[[ "$rc" == "0" ]] && assert_pass "skip flag → exit 0 despite broken manifest" || assert_fail "skip flag → exit 0" "got rc=$rc"
[[ "$(jq -r '.verdict' "$art/prebuild-validate.json" 2>/dev/null)" == "skipped" ]] && assert_pass "skip flag artifact verdict=skipped" || assert_fail "skip flag verdict=skipped"

# Edge: empty repo (no manifest) → exit 0 (no false fail).
repo=$(new_repo)
art="$repo/.claude/pipeline-artifacts"
rc=0
( PROJECT_ROOT="$repo" ARTIFACTS_DIR="$art" PIPELINE_CONFIG="" TEST_CMD="" SKIP_PREBUILD_VALIDATE=false \
  stage_pre_build_validate ) || rc=$?
[[ "$rc" == "0" ]] && assert_pass "empty repo → exit 0 (no false fail)" || assert_fail "empty repo → exit 0" "got rc=$rc"

# Performance: stage well under 30s budget (artifact durationMs).
[[ -f "$art/prebuild-validate.json" ]] && {
    dur=$(jq -r '.durationMs' "$art/prebuild-validate.json" 2>/dev/null || echo 0)
    [[ "$dur" =~ ^[0-9]+$ && "$dur" -lt 30000 ]] && assert_pass "stage completes in <30s (${dur}ms)" || assert_fail "stage <30s" "durationMs=$dur"
}

# Bash 3.2 hygiene: no forbidden constructs in the module.
mod="$SCRIPT_DIR/lib/pipeline-stages-prebuild.sh"
! grep -qE 'declare -A|readarray|\$\{[a-zA-Z_]+,,\}|\$\{[a-zA-Z_]+\^\^\}' "$mod" \
  && assert_pass "module is bash 3.2 compatible (no declare -A/readarray/case-conv)" \
  || assert_fail "module is bash 3.2 compatible"
bash -n "$mod" && assert_pass "module passes bash -n" || assert_fail "module passes bash -n"

print_test_results
