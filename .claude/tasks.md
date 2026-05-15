# Tasks — Cross-Pipeline A/B Testing Framework for Intelligence Feature Validation

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-486

## Checklist
- [ ] Task 1: Create `scripts/lib/ab-test.sh` with primitives + concurrency-safe append
- [ ] Task 2: Create `scripts/sw-abtest.sh` CLI wrapper
- [ ] Task 3: Create `scripts/sw-abtest-test.sh` test suite (≥15 assertions, mock RANDOM seeded, concurrency test)
- [ ] Task 4: Refactor `memory_ab_*` in `sw-memory.sh` to delegate to `lib/ab-test.sh`; dual-write legacy path
- [ ] Task 5: Add `abtest`/`ab` subcommand to `scripts/sw` router
- [ ] Task 6: Add `intelligence.experiments[]` schema + parse logic in `sw-daemon.sh` config init
- [ ] Task 7: Wire `ab_assign` + `SW_AB_*` env exports at pipeline spawn
- [ ] Task 8: Add `SW_AB_*` override guards in adversarial / architecture / simulation / composer / predictive entry points
- [ ] Task 9: Wire `ab_record_result` at pipeline completion path
- [ ] Task 10: Register new test in `package.json`; run `npm test`; fix regressions
- [ ] Task 11: Run `shipwright docs sync` + add `abtest` row to CLAUDE.md command table
- [ ] Task 12: Manual smoke: configure 2 experiments, run 6 mock pipelines, verify `sw abtest report adversarial` shows ~3/3 split with non-zero metrics
- [ ] `scripts/lib/ab-test.sh` exists, sourceable, all functions documented
- [ ] `sw abtest --help` lists 5 subcommands
- [ ] `sw abtest report memory` produces identical statistics to `sw memory ab-report` (parity)
- [ ] At least one new experiment (e.g., `adversarial`) wired end-to-end and verified by mock pipeline
- [ ] `npm test` passes with new `sw-abtest-test.sh` suite registered (≥15 PASS, 0 FAIL)
- [ ] `sw-memory-test.sh` continues to pass without modification
- [ ] Existing `intelligence.ab_test_ratio` config key still honored (back-compat)
- [ ] `.claude/CLAUDE.md` AUTO sections regenerated and include new files

## Notes
- Generated from pipeline plan at 2026-05-15T13:15:54Z
- Pipeline will update status as tasks complete
