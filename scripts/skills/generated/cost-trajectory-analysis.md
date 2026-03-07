## Cost-Trajectory Analysis for Build Loop Optimization

Burst mode decisions require analyzing three trajectory signals in real time:

### 1. Progress Scoring (0-100)
Track test pass/fail trend over last 3 iterations:
- **Strong progress** (80+): Tests passing, few regressions
- **Stalled progress** (30-50): Tests oscillating, slow convergence
- **No progress** (<30): Repeated failures

Calculate as: `(passing_tests / total_tests × 100) + (iteration_trend_bonus × 10)` capped at 100.

### 2. Iteration Runway
- **Plenty left** (>5): Wait, don't burst
- **Running low** (3-5): Burst *if* progress is strong (≥70) and budget allows
- **Critical** (<3): Final chance; burst only if progress ≥70 and cost-to-complete < cost-of-restart

### 3. Budget Runway
Estimate remaining cost to completion using: `(avg_cost_per_iteration × iterations_remaining)`.
- Burst is only justified if: `budget_remaining ≥ 2 × cost_to_complete`
- This 2x margin ensures we can recover from one burst failure and restart if needed.

### Decision Logic
```
Burst recommended when:
  progress_score ≥ 70
  AND iterations_remaining ≤ 3
  AND budget_remaining ≥ 2 × estimated_cost_to_complete
  AND (cost_of_burst_iteration + cost_of_recovery) < cost_of_restart
```

### Fallback & Learning
- If burst iteration fails: revert to original model, log the failure
- Track burst outcomes in costs.json: `{timestamp, triggered, progress_score, budget_before, cost_actual, result}`
- Periodically retune thresholds using historical data: Did bursts in range [65-75] progress score actually complete faster?

### Implementation Checklist
1. Parse `progress.md` to extract: test results, iteration count, current cost
2. Calculate progress_score, iterations_remaining, budget_remaining
3. Check all three conditions; recommend burst only if all true
4. Inject `ANTHROPIC_MODEL=claude-opus-4-6` for next iteration (not current)
5. Log decision to costs.json with reason and outcome
6. On fallback, clear $ANTHROPIC_MODEL and log failure reason
