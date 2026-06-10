# Pipeline Tasks — Cost Attribution & Budget Tracking per Pipeline Run

## Implementation Checklist

- [x] **T1**: Create `scripts/lib/cost-attribution.sh` with core functions (cost_attribution_aggregate, write_cost_artifact, cost_attribution_forecast)
- [ ] **T2**: Extend `scripts/lib/pipeline-state.sh` to track cost metadata per stage
- [x] **T3**: Design `.claude/pipeline-artifacts/cost.json` schema and validation (schema_version 1, embedded in cost-attribution.sh)
- [ ] **T4**: Extend `scripts/sw-db.sh` with pipeline_costs and stage_costs tables
- [ ] **T5**: Integrate cost tracking hook into `scripts/sw-pipeline.sh` (call cost-attribution after each stage)
- [x] **T6**: Implement atomic write for cost artifact (tmp → mv, with JSON validation before swap)
- [ ] **T7**: Add `shipwright cost show --pipeline <issue>` CLI command
- [ ] **T8**: Add `shipwright cost history` and `shipwright cost forecast` commands
- [ ] **T9**: Update `scripts/sw-cost.sh` with per-pipeline query functions
- [ ] **T10**: Add `/api/costs/pipeline`, `/api/costs/trends`, `/api/costs/forecast` endpoints to dashboard
- [ ] **T11**: Build dashboard frontend components: cost trends chart, stage breakdown, model distribution
- [ ] **T12**: Add WebSocket event emission for cost updates
- [ ] **T13**: Integrate cost data into intelligence cache (sw-intelligence.sh)
- [x] **T14**: Create `scripts/sw-cost-attribution-test.sh` with unit tests (31 tests, registered in package.json)
- [ ] **T15**: Write integration test: run sample pipeline, verify cost artifact, check DB inserts
- [ ] **T16**: Update `.claude/CLAUDE.md` with cost tracking design documentation
- [ ] **T17**: Add cost-tracking config section to daemon-config.json schema
- [ ] **T18**: Update README with cost attribution feature summary and examples
- [ ] **T19**: End-to-end manual test: run pipeline with `shipwright cost show`, verify dashboard display
- [ ] **T20**: Performance validation: ensure cost tracking adds <5% pipeline overhead

## Context

- Pipeline: standard
- Branch: feat/cost-attribution-budget-tracking-per-pip-613
- Issue: #613
- Generated: 2026-06-10T14:00:14Z
