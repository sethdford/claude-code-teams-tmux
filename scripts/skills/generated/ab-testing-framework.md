## A/B Testing Framework for Pattern Injection

### Design Principles

**Deterministic Randomization**: Use a hash of (issue ID + date) modulo 100 to assign builds to control/treatment arms. This ensures:
- Same issue always gets same treatment (no mid-week reroll)
- Uniform distribution across arms
- Reproducible results for debugging

**Sample Size & Duration**:
- Minimum 100 builds per arm before declaring significance
- Run for at least 1 week to capture typical variation
- If baseline success rate is 70%, need ~350 builds per arm to detect 5% improvement at p < 0.05

**Success Metric Definition**:
- Primary: "pipeline merge outcome" (MERGED = success, BLOCKED/FAILED = failure)
- Secondary: "iterations to success" (lower is better, measure only on successful builds)
- Do NOT use: commit volume, test coverage, or other proxies—measure actual merge outcome

**Confounding Variables to Control**:
- Issue complexity (control: stratify by issue score)
- Time-of-day effects (control: measure across all hours)
- Pattern library freshness (control: use same snapshot for full test duration)
- Iteration budget changes (control: lock loop settings for test period)

### Implementation Checklist

1. **Log treatment assignment**: Write `{issue_id, arm: 'control'|'treatment', date, pattern_injected: boolean}` to test manifest
2. **Validate randomization**: Post-test, chi-square test that arm distribution is uniform (~50/50 ± 5%)
3. **Calculate effect size**: Cohen's h for proportions (success rate difference)
4. **Statistical test**: Two-proportion z-test; report p-value and 95% confidence interval
5. **Interpretation**: If p < 0.05 AND effect size > 2%, pattern injection is statistically significant
6. **Guardrails**: If success rate drops in treatment arm, immediately suspend and investigate

### Monitoring During Test

- Daily: Plot cumulative success rate per arm. If one arm diverges >10% by day 3, investigate immediately.
- Track pattern usage: log which patterns were injected, how often they matched new issues.
- Failure mode tracking: if treatment arm has new failure signatures, capture to error log.

### Post-Test Reporting

Output JSON with fields:
```json
{
  "test_duration_days": 7,
  "control_builds": 320,
  "treatment_builds": 315,
  "control_success_rate": 0.72,
  "treatment_success_rate": 0.78,
  "effect_size": 0.065,
  "p_value": 0.042,
  "confidence_interval_95": [0.008, 0.122],
  "conclusion": "Pattern injection improved success rate by 6.5% (statistically significant at p=0.042)"
}
```
