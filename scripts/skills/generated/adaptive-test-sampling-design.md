## Adaptive Test Sampling for Build Loop Optimization

**Core Strategy**

Smoke test mode targets <30s by running: (1) top N fastest tests for baseline coverage, (2) top M historically failing tests for reliability signal. Full mode runs all tests ordered by (failure_rate × execution_time) to fail-fast.

**Implementation Priorities**

1. **Atomic Data Collection**: Track per-test execution time (ms), pass/fail counts, and pass rate. Store in test-stats.json with rolling window (e.g., last 30 runs). Update atomically after every test run. Handle new tests conservatively (assume median speed + 50% pass rate until ≥30 runs).

2. **Sampling Algorithm**: Use stratified sampling by test speed, then within each stratum, prioritize by failure_rate. Ensure at least one test per module is sampled (no module fully skipped). Seed RNG with commit SHA for reproducibility.

3. **Integration Safety**: Opt-in via --fast-test-cmd flag. Graceful degradation: if test-stats.json is missing/corrupted, run all tests. Test the optimizer itself with unit tests for sampling logic and integration tests with sw-loop.sh.

4. **Validation Metrics**:
   - Failure detection rate: % of failures in full suite caught by smoke suite (target: ≥95%)
   - False negative rate: % of failures missed in smoke (target: <5%, trigger alerts)
   - Wall-clock improvement: smoke <30s, full suite unaffected
   - Flaky test handling: tests with 0.4–0.7 pass rate weighted higher in samples

5. **Risk Scenarios**:
   - Stale stats after test refactoring → graceful fallback to full suite
   - Sampling misses integration tests → monitor false negative rate
   - Test infrastructure changes break sampler → safeguard with feature flag
   - Optimizer overhead >1s → negate time savings

Display on dashboard: execution time histogram, failure hotspots, false negative trend, and time savings % over time.
