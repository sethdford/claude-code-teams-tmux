## Memory-Driven Optimization: Designing Learnable Systems

When building features that improve over time using historical data, follow these patterns:

### 1. Data Model Design
- **Schema clarity**: Define what you're tracking (test name, failure rate, file coverage, timestamp, runner context)
- **Versioning**: Memory entries may evolve—include a schema version so future code can migrate
- **Granularity**: Track at the right level (per-test, per-file, per-commit-range). Too fine-grained = storage bloat; too coarse = loss of signal
- **Retention policy**: Decide how long historical data matters (e.g., failure rates from 6 months ago may not predict today)

### 2. Integration with Shipwright Memory
- Use `shipwright memory show` format for human-readability
- Store structured data in `.claude/intelligence-cache.json` or daemon state for fast queries
- Include provenance (which pipeline run, which agent) so memory entries can be audited
- Implement atomic writes (tmp file + `mv`) to prevent corruption during concurrent updates

### 3. Learning Algorithm
- **Bootstrapping**: What happens on first run when there's no history? (Fall back to heuristic: run slow tests last, run tests covering changed files first)
- **Decay/refresh**: Old history can be stale; implement exponential decay or time windows
- **Confidence scoring**: Not all historical data is equally predictive. Low-confidence entries should be ignored
- **Validation**: Cross-check learned patterns against reality ("we predicted this test fails 80% but it passed"—adjust confidence)

### 4. Measurement & Feedback Loop
- Emit events for every learning iteration (test scheduled, result observed, pattern updated)
- Dashboard metrics must show: confidence in current ordering, actual time saved vs. predicted
- Use A/B testing if possible ("run tests in smart order 80% of time, random order 20%" to measure baseline)

### 5. Edge Cases
- **New tests**: No history yet. Start with neutral/low priority, then refine based on first few runs
- **Deleted tests**: Prune historical entries periodically
- **Flaky tests**: High variance in failure rate. Flag as unreliable for ordering purposes
- **Conflicting signals**: File A changed but tests for A have low failure rate historically, while tests for B have high rate. Resolve with weighted scoring

### 6. Transparency
- Expose the learned model in a readable format ("top 10 high-risk tests", "tests that predict this file change")
- Allow manual overrides ("force this test first", "skip history for this test")
- Log ordering decisions so humans can debug why tests run in this order
