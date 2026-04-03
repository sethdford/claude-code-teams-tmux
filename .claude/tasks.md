# Tasks — Success Pattern Library with Automatic Pattern Replay Engine

## Status: In Progress
Pipeline: standard | Branch: feat/success-pattern-library-with-automatic-p-338

## Checklist
- [ ] Task 1: Create `scripts/lib/success-patterns.sh` with capture, match, inject, export functions
- [ ] Task 2: Add A/B testing functions (assign, record, report) to success-patterns.sh
- [ ] Task 3: Source the module in `scripts/sw-memory.sh` and hook into `memory_finalize_pipeline()`
- [ ] Task 4: Add success pattern section to `memory_inject_context("build")` in sw-memory.sh
- [ ] Task 5: Add success pattern injection to prompt composition in `scripts/lib/loop-iteration.sh`
- [ ] Task 6: Pass additional metadata in `scripts/lib/pipeline-commands.sh` success path
- [ ] Task 7: Add `/api/success-patterns` endpoints to `dashboard/server.ts`
- [ ] Task 8: Add `fetchSuccessPatterns` to `dashboard/src/core/api.ts` and types to `api.ts`
- [ ] Task 9: Add Success Patterns section to `dashboard/src/views/insights.ts`
- [ ] Task 10: Create `scripts/sw-success-patterns-test.sh` test suite
- [ ] Task 11: Register test suite in `package.json`
- [ ] Task 12: Run full test suite to verify no regressions
- [x] No secrets in code
- [x] No user input executed as code
- [x] File paths validated (no directory traversal — uses `repo_memory_dir()`)
- [x] JSON built via jq --arg (injection-safe)
- [x] File permissions inherit from ~/.shipwright/ directory

## Notes
- Generated from pipeline plan at 2026-04-03T18:32:46Z
- Pipeline will update status as tasks complete
