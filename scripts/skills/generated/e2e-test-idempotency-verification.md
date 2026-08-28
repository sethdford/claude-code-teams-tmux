## E2E Test Idempotency for File-Modifying Operations

When E2E tests modify shared files (README, config, docs), idempotency becomes critical. A test that adds a comment to README must not break subsequent test runs or leave the repo in a polluted state.

### Three Idempotency Rules

**1. Deterministic Starting State**
- Reset file to known baseline before test: `git checkout -- README.md` or revert added section
- If test depends on prior state, explicitly set it up (don't assume previous test cleaned up)
- Verify starting state matches expectation (check line count, git status is clean)
- Why: CI environments run tests in sequence; cleanup failures from prior tests cascade

**2. Atomic & Isolated Changes**
- Write to temp file first, then atomic move to target: write to `.README.tmp`, then `mv .README.tmp README.md`
- Use unique markers for this test run (timestamp or UUID) to distinguish comments from other tests/agents
- Scope changes to isolated section (e.g., README `<!-- E2E-TEST-COMMENT -->` markers for cleanup)
- Why: Partial writes during process failure leave corrupt state; uniqueness prevents cross-test pollution

**3. Guaranteed Cleanup (Even on Failure)**
```bash
cleanup() {
  git checkout -- README.md  # Always restore original
  [ -f .README.tmp ] && rm .README.tmp  # Clean temp files
}
trap cleanup EXIT  # Runs even on test failure or timeout
```
- Cleanup must run on test success, failure, timeout, and script exit
- Use `trap` to guarantee execution
- Verify cleanup worked: `git status --porcelain | grep -q README && exit 1`

### Idempotency Checklist
- [ ] Test can run 10 times in a row without failure (state isolation works)
- [ ] `git status --porcelain` is clean after test completes
- [ ] No leftover `.README.tmp`, `.README.bak`, or temp files in repo root
- [ ] README content is identical to pre-test state (git diff shows no changes)
- [ ] Test passes when run in parallel with other tests (no shared file locks)
- [ ] Cleanup executes even if assertions fail or timeout occurs
- [ ] Test documents what it verifies and why the change is necessary

### Red Flags in E2E Test Reviews
- Missing `trap cleanup EXIT` handler
- Hardcoded file paths without cleanup markers
- Test that creates comment but never deletes it
- Cleanup that only runs on success (fails on test failure)
- No verification that cleanup actually worked
