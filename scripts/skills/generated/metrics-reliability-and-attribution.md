## Metrics Reliability & Attribution

### Define Failure Consistently
- **What counts as a failure?** Choose one: (1) pipeline exits non-zero, (2) any stage fails (abort on first failure), (3) final intended stage didn't complete. Document the choice and apply it uniformly.
- **Partial executions**: Pipelines killed mid-run should be counted separately; don't let them inflate the denominator in success rate calculations.
- **Stage-level failures**: When attributing "stage X failed most often," count only pipelines that reached stage X, not all pipelines ever run.

### Avoid Common Pitfalls
- **Survivorship bias**: Only counting completed pipelines hides failures that killed the run early. Track separately: completed vs killed-early.
- **Simpson's Paradox**: Success rate by template might improve overall but decline within each template when weighted by volume. Break out the volume alongside the rate.
- **Changing denominator**: If the definition of "complexity" changes midway through 90-day window, metrics become incomparable. Lock definitions at metric creation time.
- **Correlation ≠ causation**: "Most failures happen at stage X" doesn't mean stage X caused them; may indicate X is the first stage to detect problems introduced earlier.

### Validate Accuracy
- **Hash-check raw events**: For any aggregation window, compute the metric two ways (fast aggregation vs slow scan of raw events) and verify they match (allow <1% variance for real-time data).
- **Spot-check dimensions**: Pick 2-3 specific combinations (e.g., "Go + standard template + 9am + week of Mar 3") and manually verify the dashboard count equals the raw event count.
- **Monitor drift**: If metrics diverge between two calculation methods, log and alert; stale cache or calculation bug is likely.

### Attribution Best Practices
- Track **failure stage** (where the pipeline stopped), **detection stage** (where we first noticed), and **root cause attribution** (if available) separately.
- For "common error patterns," extract top error messages per stage+template and surface those separately from failure counts.
- When recommending optimizations to the strategic agent, always include confidence (high: >1000 samples, medium: 100-1000, low: <100) to avoid acting on noise.

### JSON Export Contract
- Include metadata: calculation time, data freshness, sample size per dimension, confidence level.
- Use ISO 8601 for timestamps, ISO 639-1 for language codes, consistent enum values for template/stage names.
- Provide both raw counts and rates; strategic agent needs to reason about statistical significance.
