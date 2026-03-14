# Tasks — Refactor - Decompose sw-loop.sh into Modular lib/loop-*.sh Components

## Status: In Progress
Pipeline: standard | Branch: refactor/refactor-decompose-sw-loop-sh-into-modul-276

## Checklist
- [ ] Task 1: Create `lib/loop-tokens.sh` — extract token tracking, cost, adaptive model, budget gate functions
- [ ] Task 2: Create `lib/loop-error-feedback.sh` — extract diagnose_failure, run_test_gate, write_error_summary
- [ ] Task 3: Create `lib/loop-quality.sh` — extract audit agent, quality gates, DoD, guard_completion, holistic gate, compose_audit_* functions
- [ ] Task 4: Create `lib/loop-git.sh` — extract git helpers and validate_claude_output
- [ ] Task 5: Create `lib/loop-multi-agent.sh` — extract worktree setup, worker script generation, multi-agent launch/wait/cleanup
- [ ] Task 6: Create `lib/loop-display.sh` — extract show_banner and show_summary
- [ ] Task 7: Update `sw-loop.sh` — remove extracted functions, add source statements for new modules, verify < 800 lines
- [ ] Task 8: Run existing `sw-loop-test.sh` to verify zero regressions
- [ ] Task 9: Create unit test files for all 6 new modules
- [ ] Task 10: Register new test suites in `package.json`
- [ ] Task 11: Update CLAUDE.md architecture section with new module structure
- [ ] Task 12: Run full test suite (`npm test`) — all tests pass
- [ ] `sw-loop.sh` is under 800 lines (target) — orchestration only
- [ ] All 6 new `lib/loop-*.sh` modules exist with module guards
- [ ] Every function previously in sw-loop.sh is in exactly one module (no duplication)
- [ ] Existing `sw-loop-test.sh` passes with zero modifications
- [ ] 6 new test files created and registered in `package.json`
- [ ] All new tests pass
- [ ] `npm test` (full suite) passes
- [ ] No behavior change — pure refactor (identical function signatures and global variable usage)

## Notes
- Generated from pipeline plan at 2026-03-14T22:06:36Z
- Pipeline will update status as tasks complete
