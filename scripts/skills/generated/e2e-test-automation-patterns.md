## E2E Test Automation Patterns for Git/File Operations

### Test Environment Isolation
- Create a temporary test directory for each test run; use `mktemp -d` and trap-based cleanup
- Initialize git repos with test data in the temp dir; never modify the actual repo or user home
- Use `git init` and `git config user.email/name` in the temp environment—do not rely on global config
- Verify cleanup with `test -d "$tmpdir" && rm -rf "$tmpdir"` to prevent orphaned files

### Idempotency & State Reset
- Each test must be runnable N times in sequence with identical results
- Reset Git state between assertions: use `git reset --hard HEAD` to discard uncommitted changes
- Verify no files exist before test starts: `test ! -f $file || rm $file`
- Document which files/branches/commits are created and destroyed during the test

### Mock vs. Real Decisions
- Use real Git operations (`git init`, `git commit`, `git push` to a temp bare repo) for E2E tests—mocking undermines the "end-to-end" intent
- Mock only external services (GitHub API, network calls) if the test must run offline
- For tests that modify the working tree, create a pristine clone in the temp dir: `git clone --depth 1 . $tmpdir/test-repo`

### Error Path Validation
- Test failure scenarios: `git commit` with no changes, `git push` to non-existent remote, file permissions errors
- Capture exit codes and stderr; assert on both: `cmd || { ec=$?; [[ $ec -eq 2 ]] || fail; }`
- Ensure tests fail loudly (exit 1 or higher) when setup fails—don't silently skip assertions

### Test Harness Structure
- Follow Shipwright's `scripts/<name>-test.sh` skeleton: sourced `lib/compat.sh`, `trap cleanup EXIT`, PASS/FAIL counters
- Use `info()`, `success()`, `fail()` helpers for consistent output
- Name tests descriptively: `test_adds_comment_to_readme_with_git_commit` not `test_1`
- Log each test's setup, assertions, and cleanup for debugging

### Cleanup Strategy
- Always use `trap "cleanup" EXIT` to delete temp dirs even if test fails
- Close file descriptors: `exec 3>&-` after use
- Kill background processes: `jobs -p | xargs -r kill` in cleanup
- Verify remote repos are torn down: `test -d $bare_repo && rm -rf $bare_repo`
