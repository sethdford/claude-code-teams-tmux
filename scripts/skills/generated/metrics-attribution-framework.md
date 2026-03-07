## Metrics Attribution Framework

Define what constitutes pipeline success and failure—and crucially, which stage caused a failure—in a way that enables strategic reasoning. This framework prevents metrics from being misleading or unmeasurable.

### Definition Decisions

**Pipeline-level success**: All stages completed with exit code 0. Consider:
- Should retries reset the "success" flag? (Usually yes—final outcome matters.)
- User abort vs. timeout vs. code failure—all pipeline failures, but different root causes.
- Partial completion (stage 5 of 12) should be *incomplete*, not *failed*.

**Stage-level success**: Stage ran and exited 0. Capture separately:
- Stage started but timed out → timeout failure, not code failure.
- Stage not reached (aborted upstream) → *skipped*, not *failed*.
- Stage passed but downstream used stale cache → propagate to dependent stages.

**Failure attribution**: Map each failure to a single stage and root cause category:
- `code_failure`: Exit non-zero, test assertion failed, build failed.
- `timeout`: Exceeded stage timeout (separate from test timeout).
- `infrastructure`: External service unavailable, disk full, OOM.
- `abort`: User cancelled mid-pipeline.
- `skipped`: Never ran because upstream failed.
- `flaky`: Passed on retry (for success rate, count as eventual success).

### Metrics Schema

For each pipeline execution, emit:
```json
{
  "pipeline_id": "abc123",
  "status": "success|failure|incomplete",
  "root_cause_stage": "design|build|test|review",  // First failed stage, null if success
  "root_cause_category": "code_failure|timeout|infrastructure|abort",
  "template": "standard|fast|full",
  "repo_type": "go|python|typescript|...",
  "complexity": "low|medium|high",
  "duration_seconds": 245,
  "timestamp": "2026-03-07T10:00:00Z",
  "stages_completed": 5,
  "stages_total": 12
}
```

### Success Rate Calculations

**By template**: `(success count) / (success + failure)` per template type. Exclude incomplete.

**By stage**: For each stage, `(stage passed) / (stage reached)`. A stage "reached" if any upstream stage completed.

**By repo language**: Group pipelines by primary language (inferred from `.gitattributes` or file extensions), calculate success rate per language.

**By complexity**: Group by issue complexity label or estimated from description length, file change count. Calculate success rate per tier.

**By time of day**: Bucket timestamps by hour (UTC), calculate success rate per hour. Useful for detecting cascade failures during peak load.

**Trend windows**: For 7/30/90 day windows, calculate success rate as a rolling average to smooth noise. Alongside success rate, emit `std_dev` so outliers are visible.

### Handling Edge Cases

- **Incomplete pipelines**: Don't include in success rate calculation. Track separately as `in_progress` or `abandoned` for alerting.
- **Retried pipelines**: Count only the final attempt. If pipeline failed, then user re-triggered and succeeded, mark as success (human judgment overrides).
- **Multi-stage aborts**: First `abort` signal terminates the pipeline. All downstream stages are `skipped`.
- **Cascading timeouts**: If stage A times out and stage B also times out (because A never finished), attribute failure to A only.

### Consumption

**Strategic Agent**: Receives JSON with success rates by dimension. Agent queries: "Which template has lowest success rate this week?" → Design experiment to improve it.

**Dashboard**: Visualize success rate as a gauge per template/stage/language, with drill-down to individual failed pipelines and their root causes.

**Alerts**: If success rate for a template drops >10% vs. last week, alert ops (possible regression or environment issue).
