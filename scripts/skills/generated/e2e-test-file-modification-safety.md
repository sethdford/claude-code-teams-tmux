## E2E Test File Modification Safety

Tests that modify files (README comments, config updates, etc.) face unique challenges: concurrent execution, state pollution, timing-dependent assertions, and cleanup failures. This skill prevents flakiness.

### Test Isolation Pattern

**Unique Identifiers**
- Generate a test-scoped UUID (e.g., `test-run-$(date +%s%N)-$(echo $RANDOM | md5sum | cut -c1-8)`)
- Include this UUID in all test artifacts (README comments, temp files, git branches)
- Prevents collisions when tests run in parallel

**Cleanup Determinism**
- Cleanup runs in `afterEach()` **before** the test reports success, not after
- Use git to revert changes (`git checkout -- README.md`), not manual string parsing
- Verify file state after cleanup: `git diff` should show no changes
- If cleanup fails, the test fails (don't silently skip it)

**File Lock Pattern** (for shared files)
```bash
# Atomic read-modify-write
{
  flock -x 200
  # Read current content
  # Append comment with UUID
  # Write atomically
} 200>README.md.lock
rm -f README.md.lock
```

### Assertion Patterns

**Content Verification**
- After modification, re-read the file and verify exact content
- Use git diff to show what changed: `git diff README.md | grep '+.*<comment>'`
- Line numbers and indentation matter—assert both
- Compare against snapshots, but trim non-deterministic data (timestamps, UUIDs from git log)

**Fail-Fast Semantics**
- Check file permissions before operations: fail if not writable
- Verify git status before/after: fail if untracked changes
- Read file after write and verify—don't trust the write succeeded

### Concurrency & Environment

**Parallel Safety Checklist**
- [ ] Run test 10x concurrently: `for i in {1..10}; do npm test & done; wait`
- [ ] All pass with zero flakes
- [ ] Git status is clean after all runs
- [ ] README is unchanged (cleanup worked)

**Environment Independence**
- Use `process.cwd()` not hardcoded `/repo/` paths
- Detect CI environment and adjust timeouts (CI is slower, may have file system lag)
- Don't assume umask or file permissions—set them explicitly

### Common Pitfalls

❌ **Timing-based assertions**: `expect(fs.readFileSync("README.md")).toContain(comment)` — file system writes may be buffered

✅ **Fix**: Force a sync and re-read: `fs.fsyncSync(fd); expect(fs.readFileSync("README.md")).toContain(comment)`

❌ **Vague substring matching**: Misses indentation/formatting regressions

✅ **Fix**: Use snapshots or line-by-line comparison

❌ **Cleanup in finally without verification**: Leaves repo in bad state if cleanup fails

✅ **Fix**: Verify cleanup worked via git status; fail the test if it didn't

### Monitoring & Debugging

- Log file state at each step: `echo "Before: $(cat README.md | md5sum)" // ...modify... // echo "After: $(cat README.md | md5sum)"`
- When assertions fail, dump the full file diff: `git diff -U10 README.md`
- Track flake rate over time—if >5%, revert and investigate
