## Adaptive Fallback Learning System Design

### Core Challenge
Fallback policies (timeouts, retry counts, circuit breaker thresholds) are typically hardcoded or static config. This skill guides design of systems that learn from runtime behavior and adapt automatically—without oscillation, feedback loops, or silent failures.

### Design Principles

1. **Separate learning from override precedence**
   - Config schema: `{ "fallback_name": { "static": value, "adaptive_range": [min, max], "learning_enabled": bool } }`
   - Precedence: manual override > adaptive override > config static > hardcoded
   - Never let learning violate system invariants (e.g., timeouts can't go to 0, retry count can't go negative)

2. **Measure before tuning**
   - Define what "better" means for each fallback (e.g., timeout: minimize `(p99_latency + timeout_errors * penalty)`, retry_count: minimize `(failures + cost_per_retry)`)
   - Capture baseline metrics before enabling learning
   - Use SLO-aware tuning: prioritize SLO violations over micro-optimizations

3. **Prevent feedback loops**
   - Add hysteresis: don't update a fallback unless new value is 5%+ better *and* confidence interval doesn't overlap prior estimate
   - Limit update frequency (e.g., once per hour minimum) to avoid thrashing
   - Track update history; alert if a fallback oscillates more than 3 times in 24h

4. **Handle drift and decay**
   - Adaptive tuning decays over time as code changes—decay learning weight by 50% per major version
   - Flag overrides that outlive their context (e.g., a timeout tuned for slow CI is now wrong)

### Implementation Checklist

- [ ] Design `adaptive_overrides` table in `~/.shipwright/` (SQLite or JSON)
- [ ] Add `--learning-window` param to daemon (how far back to look for metrics)
- [ ] Implement score function: takes metrics → proposed fallback value with confidence
- [ ] Add `shipwright adaptive tune --fallback <name>` to manually trigger one learning cycle
- [ ] Gate behind `config.adaptive_learning.enabled` (default false for GA)
- [ ] Log every override decision (audit trail for incident review)
- [ ] Add `shipwright memory show` section for learned fallback patterns

### Anti-Patterns

- **No learning without metrics**: require at least 10 observations before tuning
- **No unbounded ranges**: always set min/max bounds matching real constraints
- **No learning on new systems**: wait 24h before enabling adaptive tuning (let steady-state establish)
- **No per-pipeline tuning**: share adaptive overrides across all pipelines (ensemble learning)

### Example: Timeout Fallback

```json
{
  "fallback_policy": {
    "timeout_default": {
      "static": 30,
      "adaptive_range": [10, 120],
      "learning_enabled": true,
      "metric_source": "pipeline_vitals.p99_latency",
      "score_function": "min(p99_latency + timeout_errors*10)",
      "learning_window_hours": 72,
      "update_frequency_hours": 1,
      "confidence_threshold": 0.85
    }
  }
}
```

Learning engine reads p99_latency and timeout error count over last 72h, computes optimal timeout, and applies if confidence ≥ 0.85 and improvement ≥ 5%.
