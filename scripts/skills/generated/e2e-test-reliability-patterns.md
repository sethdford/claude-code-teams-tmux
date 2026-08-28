## E2E Test Reliability Patterns

E2E tests exercise real system interactions and are more fragile than unit tests. Reliability requires deliberate architectural patterns:

### Isolation and State Management
- **Clean slate per test**: Each E2E test must start with a pristine environment (fresh repo clone, empty state, no leftover artifacts). Use setup fixtures that create isolated test data.
- **Guaranteed cleanup**: Cleanup must execute even if the test fails. Use try/finally patterns or defer cleanup logic to ensure all resources are released, temp files deleted, and state rolled back.
- **No test ordering dependencies**: Tests must be runnable in any order, in parallel, and individually. Never assume test X ran before test Y.
- **Immutable fixtures**: Use read-only test data so tests cannot corrupt shared state. Allocate fresh temp directories per test run.

### Timing and Flakiness Prevention
- **No hard sleeps**: Replace fixed `sleep` commands with polling (loop with timeout and exponential backoff). Hard sleeps either cause tests to hang or be non-deterministic across machines.
- **Retry logic for I/O**: File writes, process spawns, and network operations are sometimes slow. Wrap with exponential backoff (0.1s → 0.2s → 0.4s ... up to timeout).
- **Explicit timeouts**: Set upper bounds so hung tests fail quickly instead of blocking the test suite. Capture diagnostics before timeout.

### Assertions and Diagnostics
- **Outcome-based assertions**: Assert the user-visible result (comment added to README, PR created) not implementation details (did function X execute?).
- **Rich failure diagnostics**: When a test fails, capture full system state: git log, file contents, process output, logs, timing traces. Failures without diagnostics are unfixable.
- **Test the actual failure**: Intentionally run the test with known failures (delete the expected file, mock a timeout) to verify the test catches real problems. A test that passes when the feature is broken is worse than intermittent flakiness.

### Monitoring Flakiness
- **Track pass rates across runs**: Log PASS/FAIL/SKIP counts. If a test shows <98% pass rate in 100 runs, it's flaky and needs investigation.
- **Correlate failures**: Group failures by error message or timing. "Fails after 5pm" or "Fails on Windows" reveals the root cause faster than random reruns.
- **Capture full traces on failure**: Save logs, state dumps, and execution timeline so post-mortem analysis is possible without reproducing the issue.
