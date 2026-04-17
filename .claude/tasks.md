# Tasks — Cost-Per-Issue Attribution Dashboard with Optimization Recommendations

## Status: In Progress
Pipeline: standard | Branch: feat/cost-per-issue-attribution-dashboard-wit-389

## Checklist
- [ ] T1: Bump VERSION→3.4.0
- [ ] T2: `_cost_detect_repo` helper *(blocks T3)*
- [ ] T3: Extend `cost_record` with `repo` arg *(blocks T4–T9)*
- [ ] T4: `cost_breakdown` jq grouping *(blocks T8)*
- [ ] T5: `cost_outliers` awk mean/stddev *(blocks T8)*
- [ ] T6: `cost_recommendations` rules *(blocks T8)*
- [ ] T7: `cost_trend` sparkline *(blocks T8)*
- [ ] T8: `cost_attribution_rollup` atomic write
- [ ] T9: `cost_budget_type_alerts` emission
- [ ] T10: `breakdown` subcommand + help *(depends T4–T9)*
- [ ] T11: Unit + integration tests *(depends T3–T10)*
- [ ] T12: Run test suites green
- [ ] T13: Manual smoke
- [ ] `cost_record` accepts optional `repo`, auto-detected
- [ ] `shipwright cost breakdown` with all options works
- [ ] `cost-attribution.json` written atomically, matches schema
- [ ] Outliers flagged at >2σ
- [ ] Recommendations per rules table (advisory only)
- [ ] 30-day sparkline renders
- [ ] `cost_budget_alert` emits at ≥80% cap

## Notes
- Generated from pipeline plan at 2026-04-17T12:51:35Z
- Pipeline will update status as tasks complete
