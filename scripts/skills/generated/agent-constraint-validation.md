## Agent Constraint Validation

Validating that strategic agent constraints actually work requires testing at three levels:

### 1. Prompt Compliance Testing

- Run the strategic agent with success_rate_7d=0% and verify suggestions include only fast/trivial complexity tasks (no refactors, no architectural changes).
- Run with success_rate_7d=50% and verify no refactoring or meta-feature suggestions.
- Run with success_rate_7d=85% and verify all complexity levels are possible.
- Check that recent failed task titles appear in the agent's input context (verify via agent logs/traces).

### 2. Behavior Drift Detection

- Collect 20 suggestion runs at each success rate tier and cluster by complexity/category.
- Verify that complexity distribution shifts appropriately (mean complexity lower at <30% success rate).
- Detect if agent begins ignoring constraints after N iterations (agent learns to work around them—watch for this in logs).

### 3. Failure Pattern Avoidance

- Seed recent failures: "Refactor logger module (failed)", "Add async caching (failed)", "Upgrade dependencies (failed)".
- Run 10 strategic suggestions and verify zero overlap with recent failure titles/patterns.
- Watch for near-misses: agent suggesting "Refactor logging utils" when "Refactor logger module" was a recent failure—may need fuzzy matching.

### 4. Calibration Checks

- Plot success_rate vs. average suggestion complexity across a week of runs.
- Verify the relationship is monotonic (higher success rate → higher allowed complexity).
- Alert if a success rate drop causes agent to over-correct (all trivial suggestions for days when rate dips briefly).

### 5. Feedback Loop Health

- After deploying constraints, compare next-week success_rate to baseline.
- If success_rate improves, constraint system is working.
- If success_rate stays flat or worsens, constraints may be too restrictive or thresholds incorrectly calibrated—revisit.
- Track time-to-recovery: how quickly does agent suggest useful tasks again once success_rate rebounds?
