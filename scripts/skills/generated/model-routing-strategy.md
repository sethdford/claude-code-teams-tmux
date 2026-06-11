## Model Routing Strategy for Adaptive Build Loop

Implement a stateful model router that tracks code quality across consecutive iterations and makes escalation/de-escalation decisions.

### State Machine

Track state as: `(current_model, iterations_in_state, consecutive_high_scores, last_score, previous_test_status)`

**Transitions:**
- **Downshift (Opus → Sonnet)**: Only after 2+ consecutive high-quality iterations (score >0.8) AND not in first 2 iterations AND error count not increasing
- **Escalate (Sonnet → Opus)**: On quality degradation (score <0.5 OR test failure after prior pass) OR first occurrence of new error type
- **Locked**: First 2 iterations always use Opus, regardless of quality

### Scoring Function Design

Normalize metrics to [0, 1] range, then combine:
```
score = 0.5 * test_quality + 0.25 * diff_quality + 0.25 * convergence_health
where:
  test_quality = [pass=1.0, fail=0.0]
  diff_quality = 1.0 - min(lines_changed / 500, 1.0)  # penalize large diffs
  convergence_health = 1.0 - (error_count / prior_error_count)  # penalize new errors
```

Handle edge cases:
- If all metrics missing: score = 0.5 (neutral, don't route)
- If any single metric is missing: use 2/3 weighted average of remaining metrics
- New error types always trigger escalation, even if overall score is high

### State Persistence

When loop restarts (context exhaustion): restore routing state from `.claude/build-loop-routing-state.json`. On init, create state with Opus locked until iteration 2.

### Anti-Patterns to Avoid

1. **Model thrashing**: Don't escalate/downshift on every iteration. Require N consecutive iterations at target quality level.
2. **Metric blindness**: Don't ignore error count increases just because total score is high. Track error vector: new_errors vs. fixed_errors.
3. **Cost over safety**: Never downshift during risky phases (first 2 iterations, active test failures, increasing complexity).
4. **State loss**: Always persist routing state to disk after each iteration, not just in memory.

### Testing Strategy

- **Downshift scenario**: Start with Opus, achieve 2 high scores, verify switch to Sonnet, log cost savings
- **Escalation scenario**: In Sonnet, trigger a test failure, verify immediate escalation back to Opus
- **Safety constraints**: Verify first 2 iterations always use Opus regardless of quality
- **Error tracking**: Verify new error types trigger escalation even with high overall score
- **State recovery**: Simulate context exhaustion, restart loop, verify routing state is restored
- **Metric robustness**: Feed incomplete metrics (missing diff data, no test results), verify score calculation handles gracefully
