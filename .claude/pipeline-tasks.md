# Pipeline Tasks — Intelligence Layer Full-Stack Integration and Orchestration Engine

## Implementation Checklist
- [ ] Task 1: Add `intelligence_orchestrate()` function to `sw-intelligence.sh` (~200 lines) -- Core orchestration: score -> compose -> predict -> route -> monitor with shared context enrichment
- [ ] Task 2: Add `_orchestrate_read_report()` helper to `sw-intelligence.sh` -- Small utility for reading report fields
- [ ] Task 3: Modify `pipeline_start()` in `pipeline-commands.sh` to call orchestrator -- Replace/augment `generate_reasoning_trace()` with orchestrator call
- [ ] Task 4: Add per-stage model routing in `pipeline-execution.sh` -- Read `intelligence-report.json` during stage iteration for model selection
- [ ] Task 5: Create `sw-intelligence-orchestrator-test.sh` with 12 tests -- Full test coverage of orchestration sequence, degradation, data flow
- [ ] Task 6: Register test in `package.json` -- Add to npm test suite
- [ ] Task 7: Run full test suite (`npm test`) and fix any regressions -- Verify existing tests still pass
- [ ] Task 8: Validate with `sw-pipeline-test.sh` -- E2E pipeline test to confirm orchestrator integrates correctly

## Context
- Pipeline: standard
- Branch: feat/intelligence-layer-full-stack-integratio-339
- Issue: #339
- Generated: 2026-04-03T18:48:31Z
