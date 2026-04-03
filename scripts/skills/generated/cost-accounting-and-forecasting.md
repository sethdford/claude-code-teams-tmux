## Cost Accounting and Forecasting

### Financial Data Integrity

1. **Cost Attribution Accuracy**
   - Every cost must map to exactly one issue + stage + iteration, preventing double-booking
   - Timestamps matter: record when cost was incurred (token generation), not when billed
   - Handle concurrent pipeline runs on same issue: cost the stage in isolation, not the whole run
   - Rounding rule: always round towards business (overestimate cost, underestimate savings)

2. **Schema Design Patterns**
   - Foreign keys to `pipeline_runs(id)` and `issues(id)`, not loose issue numbers
   - Denormalize complexity/template/label into cost_attributions for fast ROI queries (avoid expensive joins)
   - Track model used (haiku/sonnet/opus) per cost row—routing decisions depend on per-model breakdown
   - Partition by date for large datasets (cost tables grow fast—optimize for range queries)

3. **Missing Data Handling**
   - If a stage runs without token tracking, record `NULL` cost, not `0`—alerts on silent data loss
   - When backfilling historical data, mark source as `backfilled` vs. `live` for accuracy reporting
   - Forecasting must handle sparse historical data: require N successful runs before predicting

### Forecasting Patterns

1. **Pre-Pipeline Cost Estimation**
   - Group historical data by (complexity, template, label) — find the median cost for this cohort
   - Use median (not mean) to resist outliers (one $50 experimental run ruins the average)
   - Confidence intervals: show cost_min..cost_max from historical range, not point estimates
   - Fallback to global baseline if cohort has <5 runs

2. **Forecast Signals**
   - Higher complexity → higher predicted cost (exponential, not linear)
   - Some templates are inherently pricier: `full` review template costs 3x `fast`
   - Labels like `infrastructure` or `security` often trigger extra review iterations

3. **Validation**
   - After pipeline completes, compare actual vs. forecasted cost; store delta
   - Track forecast accuracy over time (was our estimate within 20%?)
   - Alert on forecast misses (actual cost >2σ from prediction) — signals data corruption or a new cohort pattern

### Dashboard & CLI Design

1. **ROI Calculation**
   ```
   ROI = (PRs merged in template X / Total attempts in template X) / (Avg cost per attempt in template X)
   ```
   Higher ROI = lower cost per successful merge

2. **Drill-Down Paths**
   - By template: which pipeline yields best ROI?
   - By label: does security work cost more than features?
   - By model: is opus worth the cost for design stage vs. sonnet?
   - By stage: which stages have runaway costs (review loops, test retries)?

3. **CLI Output Format**
   ```
   shipwright cost analyze --issue 123 --breakdown
   Issue #123 (feat: auth)
   ├─ intake:        $0.12 (1 iteration, haiku)
   ├─ design:        $2.45 (2 iterations, opus)
   ├─ build:         $0.98 (1 iteration, sonnet)
   ├─ test:          $1.23 (3 iterations, haiku+sonnet)
   └─ review:        $0.89 (1 iteration, haiku)
   Total:            $5.67 (template: standard, complexity: medium)
   ```

### Testing Financial Logic

1. **Unit Tests for Calculations**
   - Cost = tokens_input×rate_in + tokens_output×rate_out: test exact arithmetic
   - ROI formula: test division by zero, empty cohorts, tie-breaking
   - Rounding: test boundary conditions (e.g., 0.005 rounds to 0.01)

2. **Integration Tests**
   - Create mock pipeline runs with known costs; validate attribution
   - Verify forecast accuracy on historical test dataset
   - Test schema constraints (foreign keys, no NULL issue_ids)

3. **Data Quality Tests**
   - All costs are positive (bug if negative)
   - No orphaned cost rows (every row has valid issue_id)
   - Cost sum per pipeline matches total of stage costs (no leaks)
   - Forecasts never go negative
