## Cost-Optimized Model Selection Patterns

When implementing cost-aware model routing in agent loops, follow these patterns:

### 1. Per-Iteration Routing Decision Table

Define routing as a function of iteration count and total iterations, not just arbitrary logic. Example:

```
Iteration  | % of Loop | Model  | Rationale
1-2        | 0-20%     | haiku  | Planning + initial draft (fast feedback)
3 to N-20% | 20-80%    | sonnet | Main development work (good balance)
Final 20%  | 80-100%   | opus   | Edge cases + bug fixes (most capable)
```

Store in configuration as `loop_model_strategy` (e.g., "default", "aggressive", "conservative") rather than hardcoding, allowing tuning without code changes.

### 2. Cost Accounting Within the Loop

Track cost at two levels:
- **Per-tier**: Count tokens + cost for each model tier; write to a structured log (JSON) after each iteration
- **Per-loop**: Aggregate tier costs into a loop-level cost summary in the loop completion artifact

This enables post-hoc analysis: "Haiku iterations cost $0.02, Sonnet cost $0.15, Opus cost $0.30; total $0.47 for this loop."

### 3. Stuck Detection & Escalation

Implement as a heuristic scoring function:
1. Track convergence score from the loop's existing progress metrics (test pass rate, error count, etc.)
2. Detect no progress if the score hasn't improved for N consecutive iterations (default N=3)
3. Escalate to the next model tier: haiku→sonnet, sonnet→opus
4. Log escalations with reason (iteration count + convergence score) for debugging

Risk: False positives (escalate when not stuck) waste budget. Tune the window size and score threshold based on production data.

### 4. Graceful Fallback

If escalation tries to use a model that hits rate limits or is unavailable, fall back to the current tier (don't fail the loop). Log the fallback attempt.

### 5. Configuration Schema

Add to daemon-config.json under a `loop` object:

```json
{
  "loop": {
    "model_strategy": "default",
    "stuck_detection_window": 3,
    "cost_tracking_enabled": true
  }
}
```

Enable cost tracking by default; allow opt-out for cost-sensitive environments.

### 6. Integration with Existing Model Router

sw-model-router.sh handles global model selection (which model for which stage). This feature is more granular: which model for which iteration within the build stage. Call sw-model-router.sh with a new flag `--loop-tier` to get the model name for the current tier, allowing the two systems to compose cleanly.

### 7. Test Coverage

- **Unit tests**: Routing function returns correct model for (iteration_count, total_iterations, strategy) tuple
- **Integration tests**: Loop respects routing decisions; cost is tracked correctly
- **Scenario tests**: Stuck detection fires at the right time; false positives are rare

### 8. Observability

Emit structured events (via the event bus) for each routing decision and escalation:
- Event type: `loop_model_selected` or `loop_model_escalated`
- Payload: iteration, model, reason, cost_so_far

This enables dashboards to show "cost per model tier" and detect runaway escalations.
