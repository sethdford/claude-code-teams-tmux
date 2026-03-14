# Tasks — Shipwright Quickstart - One-Command Setup for Standard Projects

## Status: In Progress
Pipeline: standard | Branch: feat/shipwright-quickstart-one-command-setup-269

## Checklist
- [ ] Task 1: Create `scripts/sw-quickstart.sh` with boilerplate (shebang, VERSION, helpers, show_help, main)
- [ ] Task 2: Implement `detect_project_type()` function with all 6 project type detectors
- [ ] Task 3: Implement `check_init_needed()` function
- [ ] Task 4: Implement `run_phase()` timing wrapper and phase orchestration in `main()`
- [ ] Task 5: Implement summary output with total elapsed time and phase results
- [ ] Task 6: Add `quickstart` routing to `scripts/sw` CLI router
- [ ] Task 7: Add `quickstart` to help text in `scripts/sw`
- [ ] Task 8: Create `scripts/sw-quickstart-test.sh` with all test cases
- [ ] Task 9: Register test in `package.json` test chain
- [ ] Task 10: Run test suite and fix any failures
- [ ] Task 11: Add quickstart entry to CLAUDE.md command tables
- [ ] `shipwright quickstart` runs all 3 phases (init → prep → doctor) end-to-end
- [ ] Auto-detects Node.js, Python, Go, Rust, Ruby, Java projects
- [ ] Idempotent — skips init if already set up
- [ ] Handles non-git-repo gracefully (runs init only)
- [ ] Shows progress indicators and timing for each phase
- [ ] `--help`, `--version`, `--skip-init`, `--skip-prep`, `--skip-doctor`, `--force` flags work
- [ ] Test suite passes with all 16 tests green
- [ ] CLI router dispatches `shipwright quickstart` correctly
- [ ] Completes in <5 minutes on standard repos (init skipped if present)

## Notes
- Generated from pipeline plan at 2026-03-14T21:37:43Z
- Pipeline will update status as tasks complete
