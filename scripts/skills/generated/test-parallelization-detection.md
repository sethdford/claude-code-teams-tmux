## Test Parallelization Detection & Coordination

### Problem
Test parallelization is dangerous: undetected shared state (temp files, global state, database connections) causes race conditions and flaky failures. This skill provides a systematic approach to detect parallelizable test suites and coordinate their execution safely.

### Shared State Detection Heuristics

**Static Analysis (file scanning):**
- Scan test file imports for singleton patterns (db connections, file handles, global state modules)
- Detect hardcoded file paths (temp dirs) and network ports — tests using fixed resources conflict
- Check for `beforeAll`/`afterAll` hooks that modify global state
- Identify test files importing shared fixtures/setup modules

**Dynamic Analysis (test execution):**
- Run test suite with `--detectOpenHandles` (Node.js) or equivalent to catch file/port leaks
- Track temp directory usage per test file — any overlap = unsafe to parallelize
- Monitor for test isolation violations (tests passing in isolation but failing when run together)

**Safety Levels:**
- **Green (parallelizable)**: No shared state detected, no fixture conflicts, passes isolation tests
- **Yellow (conditional)**: Shared fixtures but isolated datasets, parallel execution with coordination (e.g., separate DB schemas)
- **Red (sequential)**: Database transaction rollback, process spawning, hardware resource contention — must run serially

### Affected-Test Detection via Git Diff

**Module Dependency Tracking:**
1. Build module-to-test mapping (which tests exercise which modules)
2. On each commit, run `git diff --name-only HEAD~1` to identify changed modules
3. Find all tests that import/test those modules
4. Prioritize affected tests first in execution order (fail-fast on functionality regression)
5. Cache mapping per commit to avoid re-scanning on retries

**False Negatives to Handle:**
- Integration tests that cross module boundaries (require broader analysis)
- Tests that exercise shared utilities or base classes (conservative: mark as affected if any parent module changed)
- Dynamic imports and string-based test discovery (fallback: scan test code for patterns)

### Parallel Execution Coordination

**Scheduler:**
- Detect CPU core count, default to `cores - 1` (reserve 1 for OS)
- Group parallelizable tests into batches, run batches in parallel
- Within each batch, respect test file order (some test runners depend on execution order)
- Run non-parallelizable (red) tests serially, either before or after parallel batches (configurable)

**Fast-Fail Policy:**
- Critical failures: assertion errors, uncaught exceptions → abort immediately
- Flaky failures: timeout, process exit, known-flaky markers → retry up to N times before aborting
- Aggregate results across parallel workers before reporting
- Time tracking: measure wall-clock time for each batch, report parallelization efficiency (theoretical vs actual speedup)

### Dashboard Integration

- Display parallel execution summary: N tests in M workers, X% speedup
- Visualize test dependency graph (which tests block which)
- Alert on shared-state violations (test passed alone, failed in parallel)
- Trend: parallelization efficiency over time (detect regressions where new tests add serial bottlenecks)

### Key Decisions for This Issue

1. **Minimum Parallelization Threshold**: What's the smallest safe granularity? (per file, per suite, per test?)
2. **Flaky Detection**: How many retries before marking as critical failure? (recommend 3)
3. **Shared-State Confidence**: Are heuristics sufficient, or require explicit opt-in per test file?
4. **Fast-Fail Behavior**: Abort on first critical failure globally, or let all workers finish for faster feedback iteration?
5. **Fallback**: If parallelization detection is uncertain, run serial — safety over speed.
