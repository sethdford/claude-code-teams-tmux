# Tasks — Cost Attribution & Budget Tracking per Pipeline Run

## Status: In Progress
Pipeline: standard | Branch: feat/cost-attribution-budget-tracking-per-pip-613

## Checklist
- [ ] **T1**: Create `scripts/lib/cost-attribution.sh` with core functions (record_stage_cost, write_cost_artifact, parse_cost_from_pipeline_state)
- [ ] **T2**: Extend `scripts/lib/pipeline-state.sh` to track cost metadata per stage
- [ ] **T3**: Design `.claude/pipeline-artifacts/cost.json` schema and validation
- [ ] **T4**: Extend `scripts/sw-db.sh` with pipeline_costs and stage_costs tables
- [ ] **T5**: Integrate cost tracking hook into `scripts/sw-pipeline.sh` (call cost-attribution after each stage)
- [ ] **T6**: Implement atomic write for cost artifact (tmp → mv)
- [ ] **T7**: Add `shipwright cost show --pipeline <issue>` CLI command
- [ ] **T8**: Add `shipwright cost history` and `shipwright cost forecast` commands
- [ ] **T9**: Update `scripts/sw-cost.sh` with per-pipeline query functions
- [ ] **T10**: Add `/api/costs/pipeline`, `/api/costs/trends`, `/api/costs/forecast` endpoints to dashboard
- [ ] **T11**: Build dashboard frontend components: cost trends chart, stage breakdown, model distribution
- [ ] **T12**: Add WebSocket event emission for cost updates
- [ ] **T13**: Integrate cost data into intelligence cache (sw-intelligence.sh)
- [ ] **T14**: Create `scripts/sw-cost-attribution-test.sh` with unit tests
- [ ] **T15**: Write integration test: run sample pipeline, verify cost artifact, check DB inserts
- [ ] **T16**: Update `.claude/CLAUDE.md` with cost tracking design documentation
- [ ] **T17**: Add cost-tracking config section to daemon-config.json schema
- [ ] **T18**: Update README with cost attribution feature summary and examples
- [ ] **T19**: End-to-end manual test: run pipeline with `shipwright cost show`, verify dashboard display
- [ ] **T20**: Performance validation: ensure cost tracking adds <5% pipeline overhead

## Notes
- Generated from pipeline plan at 2026-06-10T14:00:15Z
- Pipeline will update status as tasks complete
