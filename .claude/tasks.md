# Tasks — Test Command Validation and Auto-Repair Engine Before Build Loop Start

## Status: In Progress
Pipeline: standard | Branch: feat/test-command-validation-and-auto-repair-406

## Checklist
- [ ] Task 1: Create `scripts/lib/test-validator.sh` scaffold with loader guard, VERSION, `set -euo pipefail`
- [ ] Task 2: Implement `_probe_test_cmd` with bounded timeout and stderr capture
- [ ] Task 3: Implement `classify_test_cmd_failure` with regex dispatch (6 classes)
- [ ] Task 4: Implement `attempt_auto_repair` for node/python/ruby/rust/go
- [ ] Task 5: Implement `write_validation_report` with `jq --arg` and atomic `mv`
- [ ] Task 6: Implement `preflight_validate_test_cmd` orchestrator with event emission
- [ ] Task 7: Wire preflight into `sw-loop.sh main()` before `run_loop_with_restarts`
- [ ] Task 8: Add `--skip-preflight` flag and `SW_PREFLIGHT_ENABLED` env override
- [ ] Task 9: Create `sw-lib-test-validator-test.sh` with mock PATH + isolated cwd
- [ ] Task 10: Test — classifies `command not found` stderr correctly
- [ ] Task 11: Test — `nodejs` path invokes `npm install` via stubbed `npm`
- [ ] Task 12: Test — aborts with exit 2 when repair fails twice
- [ ] Task 13: Test — writes well-formed JSON report atomically
- [ ] Task 14: Register test in package.json; verify `npm test` runs it
- [ ] Task 15: Verify existing `sw-loop-test.sh` still passes (pass `--skip-preflight` where needed)
- [ ] `scripts/lib/test-validator.sh` exists, passes `shellcheck`, bash 3.2 compatible, idempotent loader.
- [ ] Preflight runs before first build iteration; `loop.preflight_complete` event emitted.
- [ ] `SW_PREFLIGHT_ENABLED=false` and `--skip-preflight` both disable it.
- [ ] Failed validation aborts with exit 2; JSON report at `.claude/pipeline-artifacts/test-validation.json`.
- [ ] `sw-lib-test-validator-test.sh` registered in package.json and passing.

## Notes
- Generated from pipeline plan at 2026-04-23T18:46:50Z
- Pipeline will update status as tasks complete
