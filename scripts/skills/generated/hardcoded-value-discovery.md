## Hardcoded Value Discovery for Bash Scripts

Systematically identify and classify hardcoded values in bash scripts to enable data-driven configuration.

### Discovery Patterns

**Numeric Values in Common Contexts:**
- Timeouts: `sleep 30`, `timeout 60`, `TIMEOUT=120` → migrate to config.timeouts
- Retry/Loop Limits: `for ((i=0; i<5; i++))`, `MAX_RETRIES=3` → config.limits
- Thresholds: `if [[ $count -gt 100 ]]`, `THRESHOLD=500` → config.thresholds
- Delays/Intervals: `--interval 5`, `POLL_SECONDS=10` → config.intervals

**Fallback Patterns:**
- `${VAR:-default}` → classify as conditional fallback (low priority)
- `|| echo "fallback"` → classify as error fallback (medium priority)
- `cmd || true` → classify as error suppression (assess risk)
- `if [[ -z $VAR ]]; then ... fi` → classify as missing-value fallback

### Confidence Scoring

Rank migrations 1-5 (highest ROI first):
- **Score 5 (Migrate First)**: High-variance values that adaptive tuner can optimize (timeouts, poll intervals, retry counts). Low risk of correctness impact.
- **Score 4**: Well-scoped values with clear semantics. Easy to validate migrated behavior matches hardcoded baseline.
- **Score 3**: Values that affect performance but not correctness. Medium risk; need good monitoring.
- **Score 2**: Values with ambiguous semantics or used in multiple contexts. Risky; consider per-context overrides.
- **Score 1**: Security-critical values or values with subtle interactions. Migrate only with extensive testing.

### Implementation Checklist

- [ ] Build regex library for each pattern (timeouts, retry limits, thresholds, intervals)
- [ ] For each match: extract value + 2 lines of context (to understand purpose)
- [ ] Classify by type + context
- [ ] Assign confidence score based on safety profile
- [ ] Group by semantic domain (auth timeouts vs. polling intervals)
- [ ] Generate config schema stub
- [ ] Flag values with multiple conflicting definitions (same variable set to different values)
- [ ] Flag values in critical paths (retry logic, deployment steps)
- [ ] Output discovery report: [filename:line] [value] [type] [context] [score]
