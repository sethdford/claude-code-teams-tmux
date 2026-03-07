# Adaptive Parameter Tuning for Autonomous Systems

Auto-tuning system parameters based on observed metrics is a high-leverage pattern but risky without guardrails. Apply these principles:

## Core Pattern

1. **Measurement Window**: Collect baseline metrics over 2-4 weeks before calculating targets. Start with conservative percentiles (P90) before moving to P95.
2. **Adjustment Strategy**: Calculate target once per week, not continuously. Compare new target against current; only change if delta > threshold (e.g., ±15%) to avoid thrashing.
3. **Bounds Checking**: Always enforce min/max thresholds. For timeouts: `timeout = clamp(P95 * 1.2, min_threshold, max_threshold)`. Never let auto-tuning violate safety invariants.
4. **Backwards Compatibility**: Manual overrides (user-set timeouts) must always take precedence. Auto-tuning is opt-in per pipeline template; existing pipelines keep current timeouts until explicitly enabled.

## Failure Modes & Safeguards

| Failure Mode | Safeguard |
|---|---|
| Insufficient data (< 10 samples) | Use all available data; log warning; don't adjust yet |
| Measurement drift (outliers skew percentile) | Use robust percentile (e.g., winsorize at ±3σ) or IQR clipping |
| Oscillation (timeout keeps bouncing) | Require N consecutive agreeing measurements before change |
| Metric corruption/gaps | Validate input data; skip adjustment window if > 20% data missing |
| Cascading failures (auto-tuning masks root cause) | Alert if P95 increases > 2x in one week; trigger incident review |
| Slow drift (timeouts creep up unnoticed) | Dashboard shows 30-day timeout trend; monitor for gradual increase |

## Testing the Tuner

- **Unit tests**: Percentile calculations correct at boundaries (0, 1, 10, 100 samples)
- **Simulation**: Feed synthetic duration distributions (normal, bimodal, heavy-tailed); verify P95 is accurate
- **Regression**: Run against 30 days of production duration data; compare calculated P95 against manually-verified ground truth
- **Integration**: Deploy to canary pipelines first; monitor timeout changes before rolling to prod; require dashboard approval for large changes (> 20%)

## Rollout Strategy

1. **Feature flag**: `"auto_adjust_timeouts": false` by default; opt-in per daemon
2. **Dry-run mode**: Calculate timeout but don't apply; log what would change; monitor alignment with manual review
3. **Gradual enable**: Start on 10% of pipelines, then 50%, then 100% over 2-3 weeks
4. **Easy disable**: Single config flag to shut off auto-tuning and fall back to current timeouts
5. **Dashboard**: Show current timeout, recommended P95, trend over 30 days, adjustment history with reasons

## Metrics & Validation

- **timeouts_avoided**: Count of failures caught by P95-based timeout before they hit default (e.g., caught runaway at 45min instead of 60min default)
- **false_timeouts_prevented**: Count of successes that would have timed out under old fixed timeout but succeeded under P95-based timeout
- **adjustment_frequency**: How often timeout changes; alert if adjusting every day (sign of instability)
- **cost_impact**: Total compute hours saved by faster fail-fast + total extra failures from new shorter timeouts; net must be positive

## Edge Cases

- **Initialization**: First 7 days with no history → use defaults + collect baseline. Don't adjust in first 30-day window.
- **Low activity**: < 5 pipeline runs in 30 days → skip adjustment; keep current timeout
- **Seasonal spikes**: Concurrent builds surge; P95 jumps. Require 2 consecutive adjustment windows before applying.
- **Manual override during auto-tuning**: User sets custom timeout. Auto-tuning pauses for that pipeline until override is removed.
