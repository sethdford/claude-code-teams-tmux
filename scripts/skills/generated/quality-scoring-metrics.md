## Quality Scoring Metrics for Build Loop

Design a composable, normalizable metric system that feeds the model routing decision engine.

### Metric Dimensions

**1. Test Quality**
- Signal: Test pass/fail status after each iteration
- Calculation: `test_score = 1.0 if all_tests_pass else 0.0`
- Edge case: If no tests run yet, use 0.5 (neutral) to avoid biasing toward downshift
- Observation: This is binary, but use 0.5 for "unknown" to prevent false confidence

**2. Diff Quality (Code Churn)**
- Signal: Lines added/removed, number of files changed
- Calculation: `diff_score = 1.0 - min(total_lines_changed / 500, 1.0)`
  - 0 lines = 1.0 (perfect, no breaking changes)
  - 250 lines = 0.5 (moderate churn, some risk)
  - 500+ lines = 0.0 (high churn, model should stay on Opus)
- Rationale: Sonnet performs well on targeted fixes but struggles with broad refactoring
- Edge case: If diff is empty (no changes), use 1.0 but don't downshift (convergence issue)

**3. Convergence Health**
- Signal: Error count trend (are we fixing errors or introducing new ones?)
- Calculation: `convergence = 1.0 - (error_delta / max(prior_error_count, 1.0))`
  - `error_delta = max(0, new_errors - fixed_errors)` (net change)
  - If error_delta < 0 (we're fixing), score is >1.0, clamp to 1.0
  - If error_delta > prior error count, score is ≤0, clamp to 0.0
- Rationale: Downshift only if we're actively reducing errors, not introducing them
- Edge case: First iteration has no prior errors; use error count from prior run if available, else use 0.0

**4. Iteration Health (Composite)**
- Calculation: `iteration_score = 0.5 * test_quality + 0.25 * diff_quality + 0.25 * convergence`
- Why this weighting: Test results are primary signal (50%), diff/convergence are secondary guards (25% each)
- Boundary: Score >0.8 = "high quality, candidate for downshift"; <0.5 = "degraded, escalate"

### Temporal Aggregation

For the "2 consecutive high-quality iterations" rule:
- Keep a rolling window: `high_scores = deque(maxlen=3)` of recent iteration scores
- Downshift trigger: `len([s for s in high_scores if s > 0.8]) >= 2`
- Escalation trigger: `score < 0.5 or (test_status changed from pass to fail)`

### Logging & Observability

After each iteration, append to `.claude/build-loop-quality-log.jsonl`:
```json
{
  "iteration": 5,
  "timestamp": "2026-06-11T13:35:18Z",
  "model_used": "opus",
  "test_passed": true,
  "diff_lines": 87,
  "error_count": 2,
  "prior_error_count": 4,
  "test_quality": 1.0,
  "diff_quality": 0.83,
  "convergence": 0.50,
  "iteration_score": 0.71,
  "routing_decision": "stay_on_opus",
  "tokens_used": 142000
}
```

Summarize in loop output:
```
Quality Scoring Summary:
  Iteration 1–2: Opus (locked)     [scores: 0.65, 0.72]
  Iteration 3–5: Sonnet (downshift) [scores: 0.85, 0.87, 0.81]  Cost: -28%
  Iteration 6–7: Opus (escalate)    [scores: 0.45, 0.68]  Reason: test failure in iteration 5
  Total cost: $2.14 (vs $2.97 baseline = 28% savings)
```

### Anti-Patterns

1. **Asymmetric weighting**: Don't weight all metrics equally; test results matter more than diff size
2. **Single-iteration decisions**: Require 2+ iterations before downshifting; one good iteration isn't enough
3. **Ignoring metric variance**: A single high score in a sea of low scores doesn't justify downshift
4. **Missing context**: If convergence is unknown (first iteration), don't interpret that as high quality
