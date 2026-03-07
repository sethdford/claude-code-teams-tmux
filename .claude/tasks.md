# Tasks — Platform Self-Improvement Health Dashboard and Auto-Issue Generator

## Status: In Progress
Pipeline: standard | Branch: feat/platform-self-improvement-health-dashboa-207

## Checklist
- [ ] Task 1: Create `sw-platform-health.sh` with `platform_health_scan` and `platform_health_snapshot` functions
- [ ] Task 2: Add `platform_health_trends` and `platform_health_alerts` for 7/30 day deltas and threshold checking
- [ ] Task 3: Add `platform_health_auto_issue` with GitHub dedup and `NO_GITHUB` gating
- [ ] Task 4: Add CLI subcommands (`scan`, `show`, `json`, `auto-issue`, `history`) and terminal display
- [ ] Task 5: Add `GET /api/platform-health` endpoint to `dashboard/server.ts`
- [ ] Task 6: Add "Platform Health" tab with charts to `dashboard/public/index.html`
- [ ] Task 7: Integrate auto-issue into `sw-patrol-meta.sh` patrol cycle
- [ ] Task 8: Feed platform health snapshot into `sw-strategic.sh` context
- [ ] Task 9: Add `platform-health` route in `scripts/sw` CLI router and register test in `package.json`
- [ ] Task 10: Write comprehensive test suite `sw-platform-health-test.sh`
- [ ] Task 11: Run `npm test` and fix any test failures
- [ ] `shipwright platform-health scan` outputs valid JSON with hardcoded_count, fallback_count, todo/fixme/hack counts, top 10 scripts
- [ ] `shipwright platform-health show` displays formatted terminal output
- [ ] `GET /api/platform-health` returns JSON matching the endpoint spec (tested with curl)
- [ ] Dashboard "Platform Health" tab renders with debt trend chart, script size table, alert cards
- [ ] Auto-issue generator creates GitHub issues when thresholds exceeded (hardcoded > 50, script > 3000 lines, debt_trend_7d > +5)
- [ ] Issues have title "Platform Self-Improvement: [area]", labels `platform`, `technical-debt`
- [ ] Dedup prevents duplicate issues for same alert condition
- [ ] `NO_GITHUB=true` gracefully skips issue creation
- [ ] Platform health data appears in strategic agent context

## Notes
- Generated from pipeline plan at 2026-03-07T03:09:21Z
- Pipeline will update status as tasks complete
