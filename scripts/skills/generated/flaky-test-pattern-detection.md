## Flaky Test Pattern Detection & Quarantine Strategy

### Core Algorithm Design

**Variance Calculation**: Calculate failure rate variance over the last 10 test runs. A test is flagged if:
- Failure rate variance > 20% (e.g., passes 8/10 runs, fails 2/10 = 20% failure rate)
- Minimum 3 runs in the window to avoid noise
- Use the coefficient of variation (std dev / mean) for normalized scoring across tests with different execution counts

**Sliding Window**: Store last 10 pipeline runs per test. Query structure:
```sql
SELECT test_name, 
  COUNT(CASE WHEN status='FAIL' THEN 1 END) * 100.0 / COUNT(*) as failure_rate
FROM test_results 
WHERE test_name = ? AND pipeline_id IN (
  SELECT pipeline_id FROM pipelines ORDER BY run_at DESC LIMIT 10
)
GROUP BY test_name
HAVING failure_rate > 20
```

### Cross-Framework Skip Annotations

Different test frameworks use different skip mechanisms. Implement a plugin system:

1. **Vitest**: `.skip()` method on test/describe blocks
2. **Jest**: `.skip()` method or `xit()` alias
3. **Mocha**: `.skip()` method
4. **Generic**: Add comment annotation `// QUARANTINED: flaky test` above test declaration

For each detected test, append a skip annotation that includes:
- Failure rate percentage
- Issue URL for investigation
- Timestamp of quarantine

Example:
```javascript
// QUARANTINED: flaky test (25% failure rate)
// See: https://github.com/owner/repo/issues/XXXX
test.skip('should handle concurrent writes', async () => { ... })
```

### False Positive Prevention

1. **Require multiple failures**: Only flag if >2 failures in the 10-run window (eliminates single flakes)
2. **Trend analysis**: Check if failure rate is improving/degrading; improving trends = likely fixed, don't quarantine
3. **Manual override**: Allow developers to mark tests as "false positive" to remove from quarantine
4. **Cooldown period**: Don't re-quarantine a test that was fixed (dev had to un-skip it) for at least 5 successful runs

### GitHub Issue Creation

Create issues with:
- Title: `[Flaky Test] test_name (25% failure rate)`
- Body: failure pattern data (last 10 results, failure distribution, timestamps)
- Label: `flaky-test`
- Assignee: original test author (via git blame)
- Deduplication: Check for existing `flaky-test` issue for this test_name; update if exists, create if new

### Database Schema

```sql
CREATE TABLE test_results (
  id INTEGER PRIMARY KEY,
  pipeline_id TEXT NOT NULL,
  test_name TEXT NOT NULL,
  status TEXT CHECK(status IN ('PASS', 'FAIL', 'SKIP')),
  duration_ms INTEGER,
  timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(pipeline_id, test_name)
);

CREATE TABLE quarantined_tests (
  id INTEGER PRIMARY KEY,
  test_name TEXT UNIQUE NOT NULL,
  failure_rate REAL NOT NULL,
  github_issue_url TEXT,
  quarantine_date DATETIME DEFAULT CURRENT_TIMESTAMP,
  is_active BOOLEAN DEFAULT 1
);

CREATE INDEX idx_test_results_name_date 
  ON test_results(test_name, timestamp DESC);
```

### Integration with Daemon Patrol

Run weekly flaky detection as a patrol job:
1. Calculate variance for all tests with >10 runs
2. Identify newly-flaky tests (not in quarantined_tests)
3. Auto-skip them in source code (file mutation)
4. Create GitHub issues
5. Update dashboard metrics

Daemon config:
```json
{
  "patrol": {
    "flaky_detection_enabled": true,
    "flaky_detection_schedule": "0 2 * * 0",
    "flaky_variance_threshold": 20,
    "flaky_min_runs": 3,
    "flaky_required_failures": 2
  }
}
```
