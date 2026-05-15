# Tasks — Pipeline Stage Parallel Execution Engine with Dependency DAG Resolver

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-484

## Checklist
- [ ] Task 1: Audit shared-state writers; add `flock`/atomic-write where missing.
- [ ] Task 2: Extract `_run_one_stage()` from `run_pipeline()` with zero behavior change.
- [ ] Task 3: Implement `scripts/lib/pipeline-dag.sh` (build, validate, next_wave, mark_done, skip_descendants).
- [ ] Task 4: Implement `scripts/lib/pipeline-parallel.sh` with bounded concurrency, gate-serial guard, and process-group trap.
- [ ] Task 5: Wire `PIPELINE_PARALLEL_ENABLED` branch into `run_pipeline()`.
- [ ] Task 6: Annotate `templates/pipelines/standard.json` with linear-equivalent `depends_on`.
- [ ] Task 7: Write `scripts/sw-pipeline-dag-test.sh` (waves, cycle, unknown dep).
- [ ] Task 8: Write `scripts/sw-pipeline-parallel-test.sh` (concurrency, failure propagation, gate serial).
- [ ] Task 9: Register new test suites in `package.json`.
- [ ] Task 10: Run `./scripts/sw-pipeline-test.sh` flag-off (regression) and flag-on (smoke).
- [ ] Task 11: Update `.claude/CLAUDE.md` env-vars table (manual section, not AUTO).
- [ ] Task 12: Run `npm test` and resolve any breakage.
- [ ] All 102 existing test suites pass with the flag off.
- [ ] All 102 existing test suites plus 2 new suites pass with the flag on
- [ ] A cycle in a template prints a readable error naming the cycle nodes and
- [ ] A failed stage marks descendants `skipped:upstream_failed`; in-wave
- [ ] `shellcheck` clean on the two new libs and their tests.
- [ ] `VERSION` constant at top of every new script.
- [ ] No `declare -A`, `readarray`, `${var,,}`, or `${var^^}` in new code.
- [ ] No `cd` outside subshells in new helpers.

## Notes
- Generated from pipeline plan at 2026-05-15T13:16:15Z
- Pipeline will update status as tasks complete
