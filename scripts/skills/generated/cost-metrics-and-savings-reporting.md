## Cost Metrics & Savings Reporting

### When to Use
When implementing model routing, cost optimization, or any feature that promises efficiency gains that must be measured and reported.

### Metrics Design

**Per-iteration tracking**:
- Record model used per iteration (Opus|Sonnet|Haiku) and its cost-per-token
- Calculate token count from loop step output (count actual tokens, don't estimate)
- Store in `model-routing.jsonl` with timestamp, iteration #, quality score, model, cost delta
- Cost delta = (cost if Opus) - (cost if actual model) to show savings opportunity per iteration

**Aggregation over a loop run**:
- Sum cost deltas across all iterations
- Calculate % savings = (total cost delta / total cost if all Opus) × 100
- Report actual cost (what was charged) vs. projected cost (if all high-quality iterations used Sonnet)

**Safety baseline**:
- Always track whether quality metric correlated with success (did high-score iterations pass tests?)
- Flag if success rate dropped vs. baseline (Opus-only runs)
- Cost savings mean nothing if you're saving pennies to lose millions in failed loops

### Implementation Checklist

1. **Atomic cost tracking**: Write model routing decisions and costs together in one JSON line—never lose sync between decision and cost
2. **Token counting**: Use Claude's native token counting (API or `token-counter` npm package), not estimates
3. **Baseline comparison**: Record the "all Opus" cost for the same loop (or estimate from historical data) to calculate % savings
4. **Alerting thresholds**: If savings > 30% AND success rate < 95%, that's a signal the scorer is too aggressive
5. **Report clarity**: Loop summary shows model breakdown (`70% Sonnet, 30% Opus`), cost breakdown, and % savings—reviewers must see the trade-off
