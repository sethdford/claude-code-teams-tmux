# Tasks — Build Loop Intelligent Session Restart Briefing System

## Status: In Progress
Pipeline: standard | Branch: feat/build-loop-intelligent-session-restart-b-273

## Checklist
- [ ] Task 1: Create `scripts/lib/loop-restart-briefing.sh` with module boilerplate and `briefing_categorize_changes()`
- [ ] Task 2: Implement `briefing_extract_error_patterns()` with cross-iteration aggregation and deduplication
- [ ] Task 3: Implement `briefing_summarize_iterations()` reading archived session data
- [ ] Task 4: Implement `briefing_recommend_next_steps()` with context-aware recommendations
- [ ] Task 5: Implement `briefing_generate_enhanced()` main entry point composing all sections
- [ ] Task 6: Modify `session-restart.sh` `restart_generate_briefing()` to call enhanced generator with fallback
- [ ] Task 7: Add source line in `sw-loop.sh` for the new module
- [ ] Task 8: Create `scripts/sw-loop-restart-briefing-test.sh` test suite (~14 tests)
- [ ] Task 9: Add 2 integration tests to `scripts/sw-session-restart-test.sh`
- [ ] Task 10: Register new test in `package.json`
- [ ] Task 11: Update `.claude/CLAUDE.md` Build Loop Capabilities documentation
- [ ] Task 12: Run test suite and fix any failures
- [ ] `scripts/lib/loop-restart-briefing.sh` exists with 5 public functions
- [ ] Git diff categorization correctly separates source/test/config/docs files
- [ ] Error patterns deduplicated and ranked by frequency across all iterations
- [ ] Iteration history summarizes approaches tried and outcomes per session
- [ ] Next-step recommendations are context-aware (different for stuck_loop vs context_exhaustion vs tests_passing)
- [ ] `restart_generate_briefing()` uses enhanced briefing when available, falls back to basic
- [ ] `sw-loop.sh` sources the new module
- [ ] All new tests pass: `./scripts/sw-loop-restart-briefing-test.sh`

## Notes
- Generated from pipeline plan at 2026-03-15T08:09:51Z
- Pipeline will update status as tasks complete
