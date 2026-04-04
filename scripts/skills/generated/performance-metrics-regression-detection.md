## Performance Metrics & Regression Detection

Build observability systems that detect performance regressions and identify bottlenecks in distributed pipelines using time-series analysis and statistical thresholds.

### Data Model

- **Time-series schema**: `(stage_id, run_id, timestamp, duration_ms, run_context)` with indexes on (stage_id, timestamp) for efficient historical queries
- **Percentile calculation**: Use online streaming percentile algorithms (T-Digest, sorted arrays) to avoid materializing full history
- **Baseline periods**: Calculate separate P50/P95 baselines per stage for each week/month to account for seasonal variations

### Regression Detection

- **Threshold tuning**: >20% regression signals real slowdown (typical noise floor ~5-10%); validate threshold against historical variance per stage before deploying
- **Sample size requirement**: Require ≥10 baseline samples before comparing new run; early pipelines naturally have variance
- **Change detection**: Use CUSUM (cumulative sum control chart) to detect sustained slowdowns vs one-off outliers
- **False positive filter**: Don't alert on regressions in <100ms absolute delta (system noise floor)

### Bottleneck Identification

- **Rank by impact**: Sort stages by `(current_duration - baseline) × frequency_per_week` to surface high-impact slowdowns
- **Consistent vs transient**: Flag stages exceeding timeout in ≥70% of recent runs vs one-off failures
- **Cascade analysis**: Detect if slow stage is blocking subsequent stages or if slowdown is isolated

### Integration Patterns

- **Adaptive timeout engine**: Export `(stage_id, recommended_timeout_ms, confidence_score)` based on P95 + buffer; engine consumes for dynamic timeout adjustment
- **Dashboard widget**: Query `(stage, p50_historical, p95_historical, latest_3_runs)` for sparkline trends
- **Alert API**: Simple endpoint: `POST /alerts/{pipeline_id}` with structured alert payload (stage, severity, regression%, recommendation)

### Implementation Considerations

- **Profiler overhead**: Use clock sampling or hardware counters, not instrumentation; profile the profiler itself to ensure <2% CPU overhead
- **Storage bounds**: Append-only log with automatic rollover (daily or 100M rows); retention policy (keep 90 days raw, 2 years aggregated)
- **Statistical rigor**: Validate percentile calculations against ground truth monthly; document assumptions about stage duration independence
