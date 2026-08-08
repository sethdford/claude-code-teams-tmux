## E2E Test Idempotency & Isolation

Automated E2E tests that modify shared resources (documentation, configuration, version files) must be designed for safe, repeatable execution across multiple runs and parallel execution. Poor isolation creates flaky tests, documentation pollution, and masked failures.

### Design Principles

**1. Idempotent Operations**
- Test must succeed identically whether run once or 100 times
- Use unique markers/IDs for each test run to distinguish test-added content from production content
- Example: add comments with `<!-- TEST_RUN_<UUID> -->` markers, validate by UUID on re-run
- Verify: `git diff` is empty after test cleanup; re-running test produces identical changes

**2. Cleanup Strategy**
- Define explicit teardown that removes all test artifacts by ID/marker
- Use git branches or temp files when possible instead of modifying shared files
- If modifying shared files (e.g., README), use `git stash` or `git restore` for cleanup, not manual deletion
- Validate: `git status --porcelain` shows no untracked or modified files after test completes
- **Critical**: Cleanup must run even if test assertions fail (use finally blocks or trap handlers)

**3. Isolation from Concurrent Tests**
- Assign each test run a unique identifier (UUID, timestamp, process ID)
- Use test-ID in comments, branch names, and artifact paths
- Don't assume tests run serially or in a specific order
- Validate: tests pass identically when run in parallel and in random order

**4. Detecting Real Failures**
- Assert on specific content: exact string match, regex pattern, or structure validation (YAML/JSON well-formed)
- Catch subtle corruption: wrong line endings, encoding issues, comment formatting broken
- Test both happy path ('comment added correctly') and sad path ('malformed content rejected')
- Validate: deliberately introduce a corruption (bad encoding, malformed format) and confirm test fails

**5. Git State Safety**
- Document assumptions: assumes clean working tree, specific branch, no uncommitted changes
- Validate pre-conditions: fail early with clear message if repo is in unexpected state
- Handle edge cases: concurrent git operations, merge conflicts in README, force pushes
- Example: check `git status --porcelain` is empty before test starts

### Checklist

- [ ] Test generates and uses a unique run ID (UUID or `${test_id}_${timestamp}`)
- [ ] Test markers appear in comments/diffs (e.g., `<!-- TEST_RUN_<ID> -->`)
- [ ] Teardown explicitly removes artifacts by ID, runs even on failure
- [ ] Test passes identically on 3+ consecutive runs
- [ ] Test validates specific content (exact string or regex), not just 'file modified'
- [ ] `git status --porcelain` is empty after test cleanup
- [ ] Test can run in parallel with other instances without collision
- [ ] Test failure produces actionable error (not timeout, not flaky race)
- [ ] Pre-conditions documented and validated (git state, file permissions, etc.)
- [ ] Documentation explains what the test validates and integration point in pipeline
