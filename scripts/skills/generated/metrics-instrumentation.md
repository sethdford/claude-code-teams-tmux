# Metrics Instrumentation for Platform Health

## Goal
Instrument the platform to collect technical-debt signals (TODOs, hardcoded constants, script sizes, fallback uses) without performance impact or false positives.

## Instrumentation Principles

### 1. Reliable Collection
- **Deduplicate by content hash**: Count unique TODOs, not repeated greps; prevents false inflation
- **Parse syntax correctly**: Use AST parsing or robust regex (don't count TODOs in strings, comments, or disabled code)
- **Handle encoding edge cases**: UTF-8 BOM, mixed line endings, large files
- **Atomic snapshots**: Collect all metrics in one pass to avoid inconsistent deltas

### 2. Performance Constraints
- **Cap scan time**: Full collection should complete in <30 seconds (suitable for scheduled job or CI)
- **Stream large files**: Don't load entire 5MB scripts into memory; process line-by-line
- **Cache intermediate results**: Store previous scan results; only re-scan files modified since last scan
- **Avoid nested loops**: O(n) file scanning + O(m) TODO parsing; avoid O(n*m) cross-file analysis

### 3. Data Accuracy Validation
- **Spot-check samples**: Randomly verify 10 collected metrics match reality (e.g., pick a script, manually count TODOs, compare to collected count)
- **Trend monotonicity**: Flag if debt_count decreases without corresponding PR (signal collection error)
- **Ground-truth registry**: Maintain hardcoded-values list in code to validate collection (e.g., `// METRIC: hardcoded=42` comments)
- **Test with synthetic data**: Unit tests create files with N TODOs, verify collector finds all N

### 4. Threshold Tuning
- **Start conservative**: Set thresholds 20% above current max (e.g., current_max=2800 → threshold=3000) to establish baseline
- **Gradual tightening**: Decrease threshold 5-10% per month as platform improves
- **Per-script exceptions**: Allow exemptions for generated or vendored code (add METRIC-SKIP marker)
- **Feedback loop**: Track false-positive issues; if >20% issues closed as "not actionable," adjust threshold

### 5. Multi-Source Aggregation
- **TODO/FIXME/HACK**: `grep -r 'TODO\|FIXME\|HACK'` with filtering for comments only
- **Hardcoded values**: Scan for string/number literals outside of loops (regex pattern: `= (".*"|\d+)`); categorize by type
- **Fallback usage**: Count function calls like `fallback()`, `default_to()`, `|| fallback` patterns
- **Script sizes**: `wc -l` on all `.sh` files; track top 10 by size
- **Test coverage gaps**: Parse test output (vitest/jest) to extract coverage percentages

### 6. Trend Calculation
- **Rolling window**: Store daily snapshots for 7 days (recent) and 30 days (trend); calculate deltas
- **Smoothing**: Use exponential moving average (EMA) to filter noise; prevents false alerts on single-day spikes
- **Direction detection**: Flag if 7-day delta > +5 (increasing debt) or > -3 (decreasing, good)
- **Anomaly threshold**: Alert if today's count is >3σ from 30-day mean (signal collection or code change)

## Implementation Checklist

- [ ] Metrics collector runs in isolated subprocess (no impact if it hangs)
- [ ] Results stored in versioned JSON; schema includes collection_time, git_commit, metrics, errors
- [ ] Dry-run mode: collect metrics but don't store; useful for threshold validation
- [ ] Error summary: if scan fails, log specific error (file not readable, grep timeout) for debugging
- [ ] Integration test: fixture with synthetic code, verify metrics match expectations
- [ ] Performance test: verify scan completes in <30s on real codebase
- [ ] Validation: Compare collected metrics to manual spot-checks; must match 100%
