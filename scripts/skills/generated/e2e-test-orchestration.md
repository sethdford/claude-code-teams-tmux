## E2E Test Orchestration for Shipwright

E2E tests in Shipwright must isolate state, mock GitHub, and integrate with the existing test harness (`scripts/sw-*-test.sh` pattern).

### Test Isolation

- Use temporary directories or git worktrees to avoid cross-test contamination
- Clean up all artifacts (temp files, stashed commits, test branches) in trap handlers
- Verify no heartbeat files, state files, or lock files leak into next test

### GitHub Mocking

- Mock GitHub API calls with local functions or stub binaries in test's temp directory
- Stub `gh` CLI if used, or intercept HTTP calls via environment variables (`GH_HOST`, `GITHUB_TOKEN`)
- Verify mocked API contracts match actual GitHub API expectations (field names, response structures)

### Test Harness Integration

- Follow established pattern: `source scripts/lib/compat.sh`, define test functions, emit PASS/FAIL counters
- Use `assert_equal "expected" "actual" "test-case-name"` helpers for readable failure output
- Register test in `package.json` scripts so `npm test` discovers it

### Idempotence & Cleanup

- Each test must produce the same result on repeated runs (no file permission issues, no stale state)
- `trap "cleanup" EXIT` must remove all temporary state without failing
- Avoid hardcoded paths—use `${TMPDIR:-/tmp}` for portability

### Assertion Patterns

- Assert on file contents (use `grep`, `jq`, or `diff` to avoid brittle string matching)
- Assert on exit codes, not just stdout (tests can produce output and still fail)
- Verify side effects: did the commit get made? Does the branch exist? Check git state directly.
