# Cost-Aware Pipeline Design

## Prediction Model

Build cost estimator on historical data: (template, complexity_score) → estimated_cost.

**Data collection**: Capture at pipeline end: template name, issue complexity score (0-100), actual token cost, wall-clock time, success/failure. Store in `.claude/pipeline-artifacts/cost-history.jsonl`.

**Algorithm**: For each template, group by complexity_score (±5 bands). Use median actual cost + 25th/75th percentiles as "low/high" estimates. Show user: "Estimated: $X (range: $Y–$Z)" with confidence interval. Fallback to global median if template has <3 historical runs.

**Accuracy**: Track |estimated - actual| / actual. Target <30% mean error. Flag algorithm for retraining if error >50% for a template over last 10 runs.

## Budget Recommendation

If estimate > remaining_budget: (1) Suggest next-cheaper template that meets success_rate threshold (e.g., "fast" template has 85% success rate; "standard" has 92%), (2) Show cost delta ("saves $X"), (3) Allow user to override. If no template meets threshold, warn "insufficient budget for any template" and exit.

**Auto-template flag** (`--auto-template`): Automatically pick cheapest template with ≥threshold success rate for this complexity band. Log choice to `chosen-template.txt` for audit.

## Data Freshness

Historical cost data becomes stale as pipeline changes. Decay data older than 30 days: weight = 1.0 for <7d old, 0.8 for 7-14d, 0.6 for 14-30d, discard >30d. This prevents old high costs from inflating new estimates post-optimization.

## Dashboard Integration

Cost preview card: template dropdown → live cost estimate updates. Show chart of last 10 runs: estimated vs actual (scatter plot, color-coded by template). Export cost report at pipeline end.

## Feedback Loop

After pipeline completes, compare estimate to actual. If error >40%, investigate: Did issue complexity change mid-pipeline? Did template execute differently? Log outliers to `cost-outliers.jsonl` for manual audit.
