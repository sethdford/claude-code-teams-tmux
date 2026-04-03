# Tasks — Cost-Per-Issue Attribution Engine with ROI Dashboard and Budget Forecasting

## Status: In Progress
Pipeline: standard | Branch: feat/cost-per-issue-attribution-engine-with-r-345

## Checklist
- [ ] Task 1: Add `cost_attributions` table schema + indexes to `sw-db.sh` `init_schema()`
- [ ] Task 2: Add v6->v7 migration to `sw-db.sh` `migrate_schema()` and bump SCHEMA_VERSION to 7
- [ ] Task 3: Add `db_record_attribution()` and query functions to `sw-db.sh`
- [ ] Task 4: Create `scripts/lib/cost-attribution.sh` with recording, ROI, and forecasting functions
- [ ] Task 5: Integrate attribution recording into `scripts/lib/pipeline-commands.sh`
- [ ] Task 6: Integrate iteration-level attribution into `scripts/sw-loop.sh`
- [ ] Task 7: Add `analyze` and `forecast` CLI commands to `scripts/sw-cost.sh`
- [ ] Task 8: Add dashboard API endpoints to `dashboard/server.ts`
- [ ] Task 9: Create `scripts/sw-cost-attribution-test.sh` test suite
- [ ] Task 10: Extend `scripts/sw-db-test.sh` with attribution table tests
- [ ] Task 11: Register new test suite in `package.json` and run full test suite
- [ ] `cost_attributions` table exists in schema v7 with FK to `pipeline_runs`
- [ ] Pipeline stages record attribution after each stage completes
- [ ] Loop iterations record attribution after each iteration
- [ ] `shipwright cost analyze --issue N --breakdown` shows per-stage cost breakdown
- [ ] `shipwright cost analyze --roi` shows cost/success by template and complexity
- [ ] `shipwright cost forecast --template T --complexity C` returns estimated cost with confidence
- [ ] Dashboard serves `/api/costs/roi`, `/api/costs/forecast`, `/api/costs/attribution`
- [ ] All 17 new tests pass in `sw-cost-attribution-test.sh`
- [ ] Existing test suites still pass

## Notes
- Generated from pipeline plan at 2026-04-03T18:40:19Z
- Pipeline will update status as tasks complete
