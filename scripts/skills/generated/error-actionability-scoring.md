## Error Actionability Scoring

Measure how well error messages guide agents toward fixes. Actionability combines specificity, clarity, and correlation with outcomes.

### Metrics

**Specificity Score** (0–1):
- Presence of file:line reference (+0.3)
- Function/method name (+0.2)
- Specific error type or code (+0.2)
- Line-of-code context or snippet (+0.15)
- Exact root cause identified (+0.15)

**Clarity Score** (0–1):
- Stack trace present and legible (+0.25)
- Error message under 200 chars (+0.25)
- Actionable suggestion included (+0.25)
- No duplicate/repetitive info (+0.25)

**Outcome Correlation** (0–1):
- Measure: Did agents fix the issue in the iteration following this error?
- Window: Look ahead 1–3 iterations (config-driven)
- Baseline: If 80%+ of errors are followed by fixes, all errors score 0.5–0.8 (poor signal)
- Only correlate when signal is clear (>30% variance in fix rate by error type)

**Composite Quality Score**: `(0.6 × specificity + 0.3 × clarity + 0.1 × outcome) / 1.0`

### Template Generation

For error types with lowest quality (bottom quartile):
1. Cluster similar errors by root cause pattern (use fuzzy matching, 80%+ similarity)
2. Extract common context: file types, failure modes, agent response patterns
3. Generate improved template: `[file:line] [error_type]: [specific_root_cause]. Try: [actionable_suggestion]`
4. Validate template against historical errors: does it subsume the 3+ lowest-quality errors?

### Implementation Notes

- Store scores per error_id in events.jsonl; aggregate by error_type
- Emit after iteration completion: error metadata + quality metrics
- Top 5 lowest-quality error types go to stdout (human review)
- Generated templates saved to `.claude/error-templates.json` for injection into future iterations
- Correlation window is configurable (default: 2 iterations ahead)
- Minimum sample size: 10 observations per error type before scoring (avoid noise)
