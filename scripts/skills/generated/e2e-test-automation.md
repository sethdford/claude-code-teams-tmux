## E2E Test Automation for File Modification

### Test Isolation & Git State
File-modifying E2E tests must use worktrees or isolated temp directories to avoid polluting the main working tree. Always:
- Create a fresh worktree or temp directory per test run
- Verify git state is clean before starting
- Use `git reset --hard` or cleanup hooks to restore state after test completion
- Never rely on test execution order for cleanup

### Idempotency & Repeatability
- Run the test twice in succession; both runs must succeed with identical results
- If your test modifies a file, the second run must detect that modification and either skip or validate existing state
- Avoid hardcoding line numbers or positions—use markers (`<!-- AUTO:section-id -->`) to find insertion points

### Assertion Patterns
- Assert on file *content* (use `grep` or content comparison), not just file *existence*
- Verify git diff output to confirm the modification is what you expected
- Check that git can track the change (no binary files, encoding issues, or CRLF conflicts)

### Failure Diagnosis
- Log the full `git status`, `git diff`, and file content on assertion failure
- Capture the diff so reviewers can see exactly what was supposed to change
- If cleanup fails, fail the test loudly—don't silently leave state behind

### README-Specific Patterns
When testing README modifications:
- Preserve existing content and comments; only add new sections or markers
- Use HTML comment markers (`<!-- AUTO:section -->`) to delineate auto-managed sections
- Validate markdown syntax after modification (check for broken links, mismatched brackets)
- Test both initial addition and update scenarios (section doesn't exist vs. already exists)
