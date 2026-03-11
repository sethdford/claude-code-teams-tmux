# Tasks — Pipeline Outcome Tracking Dashboard with 7d/30d Success Rate Trend and Alert Threshold

## Status: In Progress
Pipeline: standard | Branch: feat/pipeline-outcome-tracking-dashboard-with-252

## Checklist
- [ ] Task 1: Add `SuccessRateInfo` interface to `dashboard/types/index.ts` and `dashboard/src/types/api.ts`, extend FleetState
- [ ] Task 2: Implement `computeSuccessRate()` function in `dashboard/server.ts`
- [ ] Task 3: Wire `computeSuccessRate()` into `getFleetState()` return value
- [ ] Task 4: Add success rate widget HTML container to `dashboard/public/index.html`
- [ ] Task 5: Add CSS styles for success rate widget, trend arrows, alert badge, and breakdown panel
- [ ] Task 6: Implement `renderSuccessRate()` in `dashboard/src/views/overview.ts`
- [ ] Task 7: Add breakdown drill-down (click to expand per-template table)
- [ ] Task 8: Build the TypeScript bundle (`dashboard/public/dist/main.js`)
- [ ] Task 9: Write test suite for success rate computation and widget behavior
- [ ] Task 10: Manual verification — simulate pipeline outcomes, verify widget updates and alert triggers
- [ ] Overview tab shows success rate widget with 7d and 30d rates
- [ ] Trend indicator shows correct arrow (up/down/stable) based on ±5% threshold
- [ ] Color coding: green >80%, amber 60-80%, rose <60%
- [ ] Alert badge appears when `rate_7d < (rate_30d - 20%)` OR `rate_7d == 0%` with activity
- [ ] Consecutive failure count displayed
- [ ] Widget updates in real-time via WebSocket (no manual refresh)
- [ ] Click shows breakdown by template with success/fail counts
- [ ] All tests pass (`npm test`)
- [ ] TypeScript compiles without errors

## Notes
- Generated from pipeline plan at 2026-03-11T00:48:30Z
- Pipeline will update status as tasks complete
