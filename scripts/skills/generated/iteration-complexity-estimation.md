## Iteration Complexity Estimation for Cost Prediction

### Problem
Predicting pipeline cost requires estimating how many loop iterations (build→test→review→fix cycles) an issue will require. This depends on issue complexity, codebase familiarity, and test failure patterns—none of which are directly observable before the pipeline runs.

### Algorithm Design

**Baseline iteration count = 2 (most issues converge in 2 cycles)**

**Complexity signals (add 1 iteration each if true):**
1. **Issue body length < 100 chars**: Vague requirements → more clarification rounds
2. **Multiple non-standard labels** (not in top 10): Unfamiliar patterns → higher learning curve
3. **Files touched > 10**: Large scope → higher regression risk
4. **Test coverage on changed files < 70%**: Untested areas → more test failures
5. **Similar issue in memory with >2 iterations**: Historical pattern → likely to repeat
6. **Issue complexity label = "complex" or "epic"**: Explicit signal
7. **Codebase has had >3 failed recent runs**: Unstable state → expect more cycles
8. **First-time contributor**: Cold start → assume one extra iteration for onboarding

**Multiplier (apply after baseline + signals):**
- If all signals absent (simple, small, high test coverage, familiar code): **0.8x** (often done in 1 iteration)
- Normal case: **1.0x** (baseline 2)
- High-risk (3+ signals): **1.5x** (expect 3-4 cycles)

**Max cap: 8 iterations.** Anything beyond is a scope problem, not an estimation problem.

### Implementation Checklist

1. **Parse issue body** via GitHub API for word count, code blocks (indicator of specificity)
2. **Query intelligence cache** (`~/.shipwright/intelligence-cache.json`) for file change frequency in this repo
3. **Query memory** (`sw memory show`) for similar issues and their iteration counts
4. **Calculate score**: `iterations = max(1, baseline + signals_sum * multiplier_ratio)`
5. **Cache result** in `.claude/pipeline-artifacts/estimate.json` for actual vs. predicted comparison at end of run
6. **Log to `cost-predictions.jsonl`** with timestamp, estimated iterations, signals triggered, and rationale

### Risk Mitigations

- **Cold start (no history)**: Use conservative baseline (2) + all complexity signals trigger
- **Outliers in memory**: Filter historical issues by recency (last 30 days) and repo similarity (same top 5 languages)
- **False negatives**: If a run actually completes in 1 iteration when predicted 3, investigate: was the issue truly simple, or did the team get lucky? Log both

### Integration Points

- Call this from `sw-predictive.sh` (cost estimation) before pipeline spawn
- Pass `estimate.json` to loop as context (helps loop terminate early if converging faster than predicted)
- Update `cost-predictions.jsonl` after pipeline completes with actual iterations
- Feed accuracy metrics to `sw-self-optimize.sh` for periodic model retraining
