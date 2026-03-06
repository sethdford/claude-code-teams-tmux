# Tasks — sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library

## Status: In Progress
Pipeline: standard | Branch: refactor/sw-pipeline-sh-modular-decomposition-ext-189

## Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-utils.sh` — extract utility functions (coverage, cost, duration, error classification, notifications)
- [ ] Task 2: Create `scripts/lib/pipeline-execution.sh` — extract retry logic, self-healing loop, auto-rebase
- [ ] Task 3: Create `scripts/lib/pipeline-lifecycle.sh` — extract all pipeline subcommands and lifecycle management
- [ ] Task 4: Update `scripts/sw-pipeline.sh` — remove extracted code, add source lines, verify <1,500 lines
- [ ] Task 5: Run existing test suite to verify no regressions
- [ ] Task 6: Create `scripts/sw-lib-pipeline-utils-test.sh` — unit tests for utility functions
- [ ] Task 7: Create `scripts/sw-lib-pipeline-execution-test.sh` — unit tests for execution logic
- [ ] Task 8: Create `scripts/sw-lib-pipeline-lifecycle-test.sh` — unit tests for lifecycle functions
- [ ] Task 9: Register new test suites in `package.json`
- [ ] Task 10: Run full test suite and fix any issues
- [ ] Task 11: Update CLAUDE.md documentation with new library entries
- [ ] `scripts/sw-pipeline.sh` is under 1,500 lines
- [ ] All 3 new library files exist with include guards and correct function signatures
- [ ] `npm test` passes with zero regressions (all existing 102+ test suites pass)
- [ ] New unit test suites exist for each extracted library
- [ ] Each extracted function is independently testable by sourcing its library file
- [ ] CLAUDE.md Shared Libraries table updated with new files
- [ ] No functional change — pipeline behavior is identical before and after

## Notes
- Generated from pipeline plan at 2026-03-06T06:33:12Z
- Pipeline will update status as tasks complete
