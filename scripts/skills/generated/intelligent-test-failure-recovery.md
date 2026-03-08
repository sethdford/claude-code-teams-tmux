## Intelligent Test Failure Recovery

When tests fail in a build loop, smart detection and recovery saves iterations without creating false positives. This skill guides robust implementation of failure detection, abort heuristics, and context injection.

### Test Output Parsing Strategy

**Handle 4+ test framework formats:**
- **Jest**: Extract test names from FAIL blocks or JSON reporter: `FAIL  src/auth.test.js › login` → `src/auth.test.js › login`
- **Pytest**: Parse pytest output or pytest-json-report: `FAILED tests/test_auth.py::test_login` → `tests/test_auth.py::test_login`
- **Go test**: Extract from `FAIL: TestName` lines
- **npm test**: Framework-agnostic—pass through framework detector first (jest, mocha, vitest)
- **Fallback**: Extract lines matching `(FAIL|ERROR|✗).*test.*` but mark as low-confidence

Store test names as filesystem-safe identifiers. Never assume format—validate parsing against real output samples from each framework. Use escape-safe regex to handle special characters (colons, spaces, slashes).

### Failure State Tracking

**State structure in `.claude/loop-state.json`:**
```json
{
  "iteration": 5,
  "failed_tests": {
    "src/auth.test.js::login": [3, 4, 5],
    "tests/api.test.py::test_endpoint": [4, 5]
  },
  "last_updated": "2026-03-08T12:34:56Z",
  "abort_reason": null
}
```

Maintain iteration history for each test. Detect when a test appears in 3+ **consecutive** iterations (e.g., [3,4,5] or [4,5,6]). Update on every iteration, even on success, to reset the streak counter.

### Abort Logic & Heuristics

**Conservative thresholds prevent false positives on flaky tests:**
- Require 3+ consecutive iterations with same test failing (not just any 3 failures)
- Don't abort on iterations 1-2 (environment setup phase)
- Exclude tests marked flaky in CI config (if available)
- Log abort reason clearly: "test X failed in iterations 3, 4, 5 (3 consecutive)"

**Context injection format (compact, max 5 tests):**
```
Previously failed tests (aborting after 3 consecutive failures):
- src/auth.test.js::login (iterations 3→4→5)
- tests/api.test.py::endpoint (iterations 4→5)

Focus on these tests: likely code errors, not transient failures.
```

Limit to 5 tests max to avoid context bloat. If >5 tests fail, pick 5 most recent. Omit iteration numbers if output is too long.

### Risk Mitigation

**False positives (aborting on flaky tests):**
- Log all abort decisions with full failure history to `error-log.jsonl`
- Monitor abort rate in daemon metrics—if >15%, review thresholds
- Document threshold decision (3 consecutive) in ADR and test comments
- Consider grace period: don't abort if total iterations < 6

**Malformed test output:**
- Validate regex patterns against common edge cases: multi-line names, Unicode, special chars
- Implement safe fallback: if parsing fails, skip update and continue loop
- Log parse errors but don't abort—assume transient formatter issue
- Test with intentionally corrupted output samples

**State consistency:**
- Use atomic writes (tmp file + mv) for loop-state.json to prevent corruption
- Validate JSON on read—if invalid, reset to empty state and log warning
- Include version field in state for future schema migrations

**Context window pollution:**
- Measure context tokens after injection—warn if >5% increase
- Implement pagination for large test lists (use most recent failures)

### Testing Pattern

**Unit test: Parser correctness with real samples**
```bash
# Jest
echo 'FAIL  __tests__/login.test.js' | extract_test_name
# → __tests__/login.test.js

# Pytest
echo 'FAILED tests/test_auth.py::test_login - AssertionError' | extract_test_name
# → tests/test_auth.py::test_login
```

**Integration test: Abort detection**
- Simulate 5 iterations: test fails at iterations 3, 4, 5 only
- Verify abort triggers at iteration 5
- Verify state.json shows [3,4,5] for that test
- Verify context injection includes test name

**Chaos test: Malformed & edge cases**
- Empty test output → no abort, continue
- Partial/truncated JSON → log warning, continue
- Flaky test failing at iterations 1,3,5 (non-consecutive) → no abort
- Many tests (20+) → abort but only inject top 5
