## Loop State Consistency for Stuck Detection

When detecting forward progress in build loops, state comparisons must be atomic and race-free. This skill guides implementation of reliable state snapshots.

### State Capture
- Snapshot **all signals in one atomic operation**: commit hash, test pass/fail counts, file mtimes. Do not capture sequentially—timing gaps introduce false positives.
- Use `git rev-parse HEAD` (single syscall) not repeated `git log` queries.
- Capture test state from a single parse of test output, not re-running or polling intermediate results.
- For file mtimes: read all at once with `stat` in a subshell, store as JSON for comparison.

### Comparison Logic
- All three signals must be identical to prior iteration to increment the stuck counter.
- If ANY signal changed (even 1 commit, even 1 test flipped), reset stuck counter to 0.
- Document why you chose `AND` (all must be static) vs `OR` (any static = stuck)—the issue specifies `AND`.

### Timing Edge Cases
- Git might be slow on network mounts: allow 1-iteration grace period before flagging no commits.
- Test frameworks may batch output: capture state after test runner fully exits, not mid-run.
- File mtimes may be close but not identical across iterations due to system clock resolution (1-10ms). Compare as `mtime_a >= mtime_b` (time moved forward), not `==`.

### Diagnostics
- Log the monitored state: commits SHA, test delta, files that changed/didn't change.
- On abort, dump the 3 stuck iterations' state snapshots so operators can debug false positives.
- Include command used to capture state (e.g., git, test cmd) so it's reproducible.

### Testing
- Mock stuck scenarios: frozen git HEAD, test output unchanged, file access pattern unchanged.
- Test legitimate pauses: slow git fetch, test framework batching output—verify these do NOT trigger false abort.
- Stress: vary iteration times, clock skew, concurrent file access patterns.
